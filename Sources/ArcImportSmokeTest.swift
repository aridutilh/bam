import AppKit
import WebKit

/// File > Import from Arc… end to end in the app under test (`--arc-import-test`).
/// Drives the real ArcImportController sheet and the asynchronous
/// BrowserController.commitArcImport against the repository's original synthetic
/// Tests/Fixtures/arc/StorableSidebar.json, served by the runtime loopback
/// server. It never reads the user's Arc layout and prints no fixture content.
/// Website data stays in non-persistent stores; a real SessionWriter targets a
/// temporary file, so the commit's verified save and undo paths are real.
@MainActor final class ArcImportSmokeTest {
    private var controller: BrowserController!
    private var window: NSWindow!
    private var importer: ArcImportController?
    private var checks = 0
    private var watchdog: Timer?
    private var finished = false
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bam-arc-import-\(UUID().uuidString)", isDirectory: true)
    private var sessionFile: URL { directory.appendingPathComponent("session.json") }
    private static let gammaAddress = "https://board.example.com/g"
    enum Failure: Error { case assertion(String) }
    struct WriteRefused: Error {}
    /// commitArcImport's two failure outcomes: the undo was saved, or it wasn't.
    static let confirmedUndo = "Bam couldn’t save the imported layout, so the import was undone and nothing was added. Check free disk space and try again."
    static let unconfirmedUndo = "Bam couldn’t save to disk. The import was undone in this window, but Bam can’t confirm your tabs are saved — free up disk space before quitting."
    /// Ordered outcomes of an injected writer, recorded on its serial queue.
    final class WriteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ event: String) { lock.lock(); entries.append(event); lock.unlock() }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func start() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        Task { @MainActor in
            do {
                try await run()
                finish(true, "\(checks) checks through the real Import from Arc sheet and callbacks: preview/cancel without mutation, options, locked controls while saving, verified success and dismissal, preview-equals-commit counts, one blank landing with and without Today, Spaces/emoji/profiles, nested folders, Splits, per-profile Favorites and overflow, dormancy, verified save and reload, repeat without duplication, unconfirmed and confirmed undo after failed saves, locked sheet during a slow write, incremental re-import")
            } catch { finish(false, String(describing: error)) }
        }
    }

    // MARK: Helpers

    private func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
        checks += 1
    }
    private func wait(_ message: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure.assertion("Timeout: \(message)") }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks += 1
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    /// What an import may add or must leave alone: not selection, counters or
    /// per-tab runtime state such as sleep snapshots and live titles.
    private struct Layout: Encodable {
        struct Tab: Encodable { let id: UUID, address: String, space: Int, folderID: UUID?, saved: SavedTabState? }
        let tabs: [Tab], folders: [BrowserFolder], spaces: [BrowserSpace], profiles: [BrowserProfile]
        let splits: [BrowserSplit]?, importLinks: [String: String]?
        init(_ s: BrowserSession) {
            tabs = s.tabs.map { Tab(id: $0.id, address: $0.address, space: $0.space, folderID: $0.folderID, saved: $0.saved) }
            folders = s.folders; spaces = s.spaces; profiles = s.profiles; splits = s.splits; importLinks = s.importLinks
        }
    }
    /// One commit through the sheet: controls lock while saving, the sheet
    /// closes on verified success, and the window lands on exactly one new
    /// blank tab while every newly imported tab stays without a page.
    private func commitThroughSheet(_ sheet: ArcImportController, _ label: String) async throws -> (planned: ArcImport.Report, added: [BrowserTab]) {
        guard let planned = sheet.report else { throw Failure.assertion("\(label): preview exists") }
        let before = controller.session
        let linkedBefore = importedTabIDs(before)
        sheet.importButton.performClick(nil)
        try check(sheet.isCommitting && !sheet.importButton.isEnabled && !sheet.cancelButton.isEnabled,
                  "\(label): controls lock while the import saves")
        try await waitForDismissal(sheet, label)
        let after = controller.session
        let newlyImported = importedTabIDs(after).subtracting(linkedBefore)
        let added = after.tabs.filter { tab in !before.tabs.contains { $0.id == tab.id } }
        let landing = added.filter { !newlyImported.contains($0.id) }
        try check(newlyImported.count == planned.importedTabs && added.count == planned.importedTabs + 1,
                  "\(label): adds exactly the previewed tabs (\(newlyImported.count)/\(planned.importedTabs)) plus one landing tab")
        try check(landing.count == 1 && landing[0].id == after.activeID && landing[0].isHome && !landing[0].isSaved
                  && landing[0].space == planned.firstSpaceID,
                  "\(label): lands on exactly one new blank tab in the first imported Space")
        try check(importedTabIDs(after).isDisjoint(with: controller.browsers.keys), "\(label): no imported tab has a page")
        try check(after.folders.count - before.folders.count == planned.importedFolders, "\(label): adds exactly the previewed folders")
        return (planned, added)
    }
    private func layout(_ session: BrowserSession) throws -> Data { try encoded(Layout(session)) }
    /// Tabs created by an import, by provenance rather than by novelty.
    private func importedTabIDs(_ session: BrowserSession) -> Set<UUID> {
        Set((session.importLinks ?? [:]).values.compactMap { $0.hasPrefix("tab:") ? UUID(uuidString: String($0.dropFirst(4))) : nil })
    }
    private func rows(_ session: BrowserSession, _ space: Int) -> [String] {
        session.keptLayout(in: space).map { entry in
            let name = entry.isFolder ? "[" + (session.folder(entry.id)?.name ?? "?") + "]"
                : session.tabs.first { $0.id == entry.id }.map(\.displayTitle) ?? "?"
            return String(repeating: "  ", count: entry.depth) + name
        }
    }

    /// The real File ▸ Import from Arc… sheet with its real preview, commit and
    /// dismiss callbacks. A nil initial source opens it empty, so no personal
    /// Arc layout is read; each step then loads the synthetic fixture.
    private func presentImporter() async throws -> ArcImportController {
        guard let sheet = controller.presentArcImport(initialSourceURL: nil) else {
            throw Failure.assertion("Import from Arc opens its sheet")
        }
        importer = sheet
        try check(controller.arcImporter === sheet && sheet.source == nil, "The sheet opens empty, reading no layout")
        try await wait("Import sheet attaches to the browser window") { window.attachedSheet === sheet.window }
        return sheet
    }
    /// The sheet's error line, once a commit has finished with a failure.
    private func sheetError(_ sheet: ArcImportController) -> String? {
        guard !sheet.isCommitting, !sheet.status.isHidden, sheet.status.textColor == .systemRed,
              !sheet.status.stringValue.isEmpty else { return nil }
        return sheet.status.stringValue
    }
    private func waitForDismissal(_ sheet: ArcImportController, _ label: String) async throws {
        let deadline = Date().addingTimeInterval(40)
        while controller.arcImporter != nil || window.attachedSheet != nil {
            guard Date() < deadline else {
                throw Failure.assertion("Timeout: \(label): sheet dismissed (committing: \(sheet.isCommitting), error: \(sheetError(sheet) ?? "none"))")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks += 1
        importer = nil
    }
    private func commitDirectly(_ source: ArcImport.Source) async -> String? {
        await withCheckedContinuation { continuation in
            controller.commitArcImport(source, options: ArcImport.Options()) { continuation.resume(returning: $0) }
        }
    }
    /// The fixture plus one new kept tab after “Beta Board” in “Projects”.
    private func grownFixture(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sidebar = root["sidebar"] as? [String: Any], var containers = sidebar["containers"] as? [Any],
              containers.count > 1, var main = containers[1] as? [String: Any], var items = main["items"] as? [Any],
              let index = items.firstIndex(where: { ($0 as? [String: Any])?["title"] as? String == "Projects" }),
              var projects = items[index] as? [String: Any], let projectsID = projects["id"] as? String,
              let children = projects["childrenIds"] as? [String] else { throw Failure.assertion("Fixture has a Projects folder") }
        let id = "00000000-0000-4000-8000-999999999999"
        projects["childrenIds"] = children + [id]; items[index] = projects
        let gamma: [String: Any] = ["id": id, "childrenIds": [String](), "parentID": projectsID, "title": NSNull(),
                                    "createdAt": 0.0, "isUnread": false, "originatingDevice": "fixture",
                                    "data": ["tab": ["savedURL": Self.gammaAddress, "savedTitle": "Gamma Board", "timeLastActiveAt": 0.0]]]
        items += [id, gamma]
        main["items"] = items; containers[1] = main; sidebar["containers"] = containers; root["sidebar"] = sidebar
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: Run

    private func run() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"], let page = URLInput.directURL(raw),
              let remote = URL(string: "arc/StorableSidebar.json", relativeTo: page)?.absoluteURL else {
            throw Failure.assertion("Set BAM_TEST_URL to the runtime loopback fixture")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (data, response) = try await URLSession.shared.data(from: remote)
        try check((response as? HTTPURLResponse)?.statusCode == 200, "Loopback server serves the repository Arc fixture")
        let fixture = directory.appendingPathComponent(ArcImport.sourceFileName)
        try data.write(to: fixture)
        let source = try ArcImport.load(from: fixture)
        try check(source.spaces.map(\.title) == ["Work", "Home", "Side"], "Repository fixture is the original synthetic layout")

        // A browser with one existing loopback tab. Non-persistent stores; a
        // real writer on a temporary file, as TabResourceSmokeTest does.
        controller = BrowserController(sessionURL: sessionFile, ephemeral: true)
        let existing = BrowserTab(title: "Existing", address: page.absoluteString, space: 0)
        controller.session = BrowserSession(tabs: [existing], activeID: existing.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bam Arc import fixture"; window.isReleasedWhenClosed = false
        window.contentViewController = controller; window.setContentSize(NSSize(width: 1100, height: 720))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("Fixture browser window is key") { NSApp.isActive && window.isKeyWindow }
        try await wait("Existing tab loads") { controller.activeWebView.map { !$0.isLoading && $0.url != nil } ?? false }
        let writer = SessionWriter(url: sessionFile)
        controller.privateMode = false; controller.sessionWriter = writer
        controller.save()
        try check(await writer.flushAsync(timeout: 5), "Writer saves the pre-import session")
        let original = controller.session
        let originalLayout = try layout(original)

        // 1. Preview, options and Cancel change nothing.
        var sheet = try await presentImporter()
        try check(!sheet.importButton.isEnabled, "Import is disabled until a layout is chosen")
        sheet.load(fixture)
        guard let preview = sheet.report else { throw Failure.assertion("Choosing the fixture produces a preview") }
        try check(preview.refusal == nil && !preview.isEmpty && sheet.importButton.isEnabled, "Preview enables Import")
        try check(preview.spaces.map(\.title) == ["Work", "Home", "Side"] && preview.spaces.allSatisfy(\.isNew), "Preview lists three new Spaces")
        try check(preview.easels == 1 && preview.liveFolders == 1 && preview.invalidAddresses == 1 && preview.oversizedSplits == 1
                  && preview.favoriteOverflow == 2 && preview.unattachedProfiles == 1 && preview.flattenedTodayFolders == 1,
                  "Preview reports every approximation the fixture contains")
        let todayInPreview = preview.spaces.reduce(0) { $0 + $1.todayTabs }
        try check(todayInPreview > 0, "Preview counts Today tabs")
        sheet.todayBox.performClick(nil)
        try check(sheet.report?.spaces.reduce(0, { $0 + $1.todayTabs }) == 0
                  && sheet.report?.importedTabs == preview.importedTabs - todayInPreview, "Excluding Today updates the preview")
        sheet.todayBox.performClick(nil)
        try check(sheet.report == preview, "Re-including Today restores the original preview")
        try check(try layout(controller.session) == originalLayout && controller.session.space == original.space,
                  "Previewing never mutates the browser session")
        sheet.cancelButton.performClick(nil)
        try await waitForDismissal(sheet, "Cancel")
        try check(try layout(controller.session) == originalLayout, "Cancelled import leaves the session unchanged")
        try check(SessionFile.load(sessionFile).importLinks == nil, "Cancelled import writes nothing imported")

        // 2a. Commit through the sheet with Today excluded.
        sheet = try await presentImporter()
        sheet.load(fixture)
        sheet.todayBox.performClick(nil)
        let first = try await commitThroughSheet(sheet, "Import without Today")
        try check(first.planned.spaces.allSatisfy { $0.todayTabs == 0 } && first.planned.importedTabs == preview.importedTabs - todayInPreview,
                  "Import without Today previews no Today tabs")
        guard let work = controller.session.spaces.first(where: { $0.name == "Work" }),
              let home = controller.session.spaces.first(where: { $0.name == "Home" }),
              let side = controller.session.spaces.first(where: { $0.name == "Side" }) else { throw Failure.assertion("Imported Spaces exist") }
        try check(controller.session.space == work.id && first.planned.firstSpaceID == work.id, "Commit shows the first imported Space")
        try check(!controller.session.tabs.contains { importedTabIDs(controller.session).contains($0.id) && !$0.isSaved },
                  "No Today tab is imported when Today is excluded")

        // 2b. Re-import with Today: only Today tabs are added, again landing on one blank tab.
        sheet = try await presentImporter()
        sheet.load(fixture)
        let second = try await commitThroughSheet(sheet, "Import Today afterwards")
        try check(second.planned.importedTabs == todayInPreview && second.planned.importedFolders == 0
                  && second.planned.spaces.allSatisfy { !$0.isNew }, "Second import adds only the Today tabs to existing Spaces")
        let session = controller.session
        let importedIDs = importedTabIDs(session)
        let imported = session.tabs.filter { importedIDs.contains($0.id) }
        try check(imported.count == preview.importedTabs, "Both imports together add exactly the full preview (\(imported.count)/\(preview.importedTabs))")
        try check(original.tabs.allSatisfy { tab in session.tabs.contains { $0.id == tab.id && $0.address == tab.address && $0.space == tab.space && $0.saved == tab.saved } },
                  "Existing tabs survive unchanged")
        try check(work.emoji == "💼" && home.emoji == "🏠" && side.emoji == "🧪", "Space emoji preserved")

        // Profiles: default Arc profile -> Bam default; custom -> its own new profile.
        try check(work.profileID == BrowserProfile.defaultID && side.profileID == BrowserProfile.defaultID, "Default Arc profile maps to Bam's default")
        try check(home.profileID != BrowserProfile.defaultID && session.profiles.contains { $0.id == home.profileID }
                  && !original.profiles.contains { $0.id == home.profileID } && first.planned.newProfiles.count == 1,
                  "Custom Arc profile becomes one new Bam login profile")

        // Hierarchy: nested folders, empty folder, duplicate URL, Splits, overflow.
        let workRows = rows(session, work.id)
        let expected = ["[More Favorites]", "  Fav 13", "  Fav 14", "Team Docs", "[Projects]", "  Alpha Board", "  [Alpha]",
                        "    [Level 2]", "      [Level 3]", "        [Level 4]", "          Deep Page", "  Beta Board",
                        "[Empty]", "Alpha Board copy", "Left Pane", "[Pull Requests]", "  PR 1", "Wide 1", "Wide 3"]
        try check(workRows == expected, "Work kept hierarchy matches Arc order (\(workRows.count) rows)")
        try check(session.folders.map { session.folderDepth($0.id) }.max() == 4, "Five-level folder nesting is represented")
        guard let left = imported.first(where: { $0.title == "Left Pane" }), let right = imported.first(where: { $0.title == "Right Pane" }),
              let wide = imported.first(where: { $0.title == "Wide 1" }) else { throw Failure.assertion("Split panes imported") }
        try check(session.split(for: left.id) == BrowserSplit(primaryID: left.id, secondaryID: right.id), "Arc Split becomes a Bam Split")
        try check(imported.contains { $0.title == "Wide 2" } && session.split(for: wide.id) != nil, "Oversized Split keeps two panes and its extra pane")

        // Favorites stay per profile.
        try check(session.favorites(in: BrowserProfile.defaultID).count == 12, "Twelve default-profile Favorites")
        try check(session.favorites(in: home.profileID).map(\.title) == ["Home Mail"], "Custom profile keeps its own Favorite")
        try check(!session.tabs.contains { $0.title.hasPrefix("Other ") }, "Unattached profile Favorites are not imported by default")

        // Dormancy: no imported page exists until the user selects one.
        try check(imported.filter(\.isSaved).allSatisfy(\.isUnloaded), "Imported kept tabs and Favorites are dormant")
        try check(importedIDs.isDisjoint(with: controller.browsers.keys), "No imported tab has a page after import")
        try check(Set(imported.filter { !$0.isSaved }.map(\.title)).isSuperset(of: ["Today One", "Today Two", "Loose Today"]),
                  "Today tabs stay ordinary tabs; Today folders flatten")

        // 3. Persisted through the real writer and reloaded as at launch.
        try check(writer.isLatestSnapshotSaved, "Commit confirmed the import reached disk")
        let reloaded = SessionFile.load(sessionFile)
        try check(try layout(reloaded) == layout(session), "Reloaded session keeps imported tabs, folders, Spaces, profiles, Splits and provenance")
        try check(rows(reloaded, work.id) == expected, "Reloaded hierarchy is identical")
        try check(reloaded.tabs.filter { importedIDs.contains($0.id) && $0.isSaved }.allSatisfy(\.isUnloaded), "Reloaded imported tabs are still dormant")

        // 4. Repeat import of the same layout adds nothing and cannot commit.
        let committedLayout = try layout(controller.session)
        sheet = try await presentImporter()
        sheet.load(fixture)
        guard let repeated = sheet.report else { throw Failure.assertion("Repeat preview") }
        try check(repeated.isEmpty && repeated.alreadyImported > 0 && !sheet.importButton.isEnabled, "Repeat preview finds everything already imported")
        try check(await commitDirectly(source) == repeated.emptyReason, "A forced repeat commit is refused with the preview's reason")
        try check(try layout(controller.session) == committedLayout, "Repeat import leaves the session unchanged")
        sheet.cancelButton.performClick(nil)
        try await waitForDismissal(sheet, "Repeat cancel")

        // 5. One new Arc item, imported three times in the same sheet:
        //    a) every write fails, so the undo can't be confirmed and says so;
        //    b) only the import's write fails, so the undo is written and confirmed;
        //    c) the write is slow but succeeds, so the sheet waits, then closes.
        let grown = directory.appendingPathComponent("Grown.json")
        try grownFixture(data).write(to: grown)
        let beforeFailureLayout = try layout(controller.session)
        let address = Self.gammaAddress
        sheet = try await presentImporter()
        sheet.load(grown)
        try check(sheet.report?.importedTabs == 1 && sheet.report?.spaces.allSatisfy({ !$0.isNew }) == true,
                  "Preview finds exactly the one new Arc item in existing Spaces")

        // a) Disk refuses everything.
        let refusing = SessionWriter(url: sessionFile) { _, _ in throw WriteRefused() }
        controller.sessionWriter = refusing
        sheet.importButton.performClick(nil)
        try check(sheet.isCommitting, "Import starts saving")
        try await wait("Unconfirmed undo is reported", timeout: 75) { self.sheetError(sheet) != nil }
        try check(sheetError(sheet) == Self.unconfirmedUndo, "An unsaved undo says it can't confirm the tabs are saved")
        try check(window.attachedSheet === sheet.window && controller.arcImporter === sheet && sheet.cancelButton.isEnabled,
                  "Sheet stays open and usable after a failed save")
        try check(try layout(controller.session) == beforeFailureLayout && !refusing.isLatestSnapshotSaved,
                  "The import is undone in the window although the undo is not on disk")
        try check(!controller.session.tabs.contains { $0.address == address }
                  && controller.browsers.keys.allSatisfy { id in controller.session.tabs.contains { $0.id == id } },
                  "Undo leaves no imported tab or orphan page")

        // b) Only snapshots holding the new item fail. The file is removed
        //    first, so its reappearance proves the undo itself was written.
        let log = WriteLog()
        controller.sessionWriter = SessionWriter(url: sessionFile) { snapshot, url in
            if snapshot.tabs.contains(where: { $0.address == address }) { log.record("refused"); throw WriteRefused() }
            try SessionFile.save(snapshot, to: url); log.record("saved")
        }
        try FileManager.default.removeItem(at: sessionFile)
        try check(sheet.report?.importedTabs == 1 && sheet.importButton.isEnabled, "The same item can be imported again")
        sheet.importButton.performClick(nil)
        try await wait("Confirmed undo is reported", timeout: 75) { self.sheetError(sheet) != nil }
        try check(sheetError(sheet) == Self.confirmedUndo, "A saved undo says nothing was added")
        let events = log.events
        try check(events.first == "refused" && events.dropFirst().contains("saved"),
                  "The import's write failed, then the undo was written (\(events))")
        try check(FileManager.default.fileExists(atPath: sessionFile.path)
                  && (try layout(SessionFile.load(sessionFile))) == beforeFailureLayout, "The written undo matches the layout before the import")
        try check(try layout(controller.session) == beforeFailureLayout, "The window matches the saved undo")

        // c) A slow but successful write keeps the sheet waiting, locked.
        controller.sessionWriter = SessionWriter(url: sessionFile) { snapshot, url in
            Thread.sleep(forTimeInterval: 1.5); try SessionFile.save(snapshot, to: url)
        }
        try check(sheet.importButton.isEnabled, "Import is available after a confirmed undo")
        sheet.importButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(800))
        try check(sheet.isCommitting && window.attachedSheet === sheet.window && !sheet.cancelButton.isEnabled && sheetError(sheet) == nil,
                  "The sheet stays open and locked while the write is in flight")
        try await waitForDismissal(sheet, "Slow successful import")
        controller.sessionWriter = writer
        let merged = rows(controller.session, work.id)
        try check(controller.session.tabs.filter { $0.address == address }.count == 1
                  && importedTabIDs(controller.session).count == importedIDs.count + 1, "Retry adds only the new item")
        try check(merged.firstIndex(of: "  Gamma Board") == merged.firstIndex(of: "  Beta Board").map { $0 + 1 }, "New item lands after its source sibling")
        try check(merged.filter { $0 != "  Gamma Board" } == expected, "Existing imported layout is untouched")
        try check(SessionFile.load(sessionFile).tabs.filter { $0.address == address }.count == 1, "Retry reaches disk")
        try check(importedTabIDs(controller.session).isDisjoint(with: controller.browsers.keys), "Re-imported item is dormant too")
    }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        watchdog?.invalidate(); watchdog = nil
        if let sheet = importer?.window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        controller?.sessionWriter = nil; controller?.privateMode = true
        controller?.prepareToClose(); window?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
        print("\(success ? "PASS" : "FAIL"): Arc import — \(message)"); fflush(stdout)
        exit(success ? 0 : 1)
    }
}
