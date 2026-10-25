import AppKit
import WebKit

/// File > Import from Arc… end to end in the app under test (`--arc-import-test`).
/// Drives the real ArcImportController sheet and BrowserController.commitArcImport
/// against the repository's original synthetic Tests/Fixtures/arc/StorableSidebar.json,
/// served by the runtime loopback server. It never reads the user's Arc layout,
/// and never prints fixture titles or addresses beyond its own synthetic names.
/// Website data stays in non-persistent stores; the session writer targets a
/// temporary file, so the commit's save, flush and rollback paths are real.
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
    enum Failure: Error { case assertion(String) }
    struct WriteRefused: Error {}

    func start() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        Task { @MainActor in
            do {
                try await run()
                let plumbing = usesActualPlumbing ? "actual importFromArc plumbing"
                    : "mirrored sheet wiring (a personal Arc layout exists at the default path; importFromArc callbacks not exercised)"
                finish(true, "\(checks) checks via \(plumbing): preview/cancel without mutation, options, commit through the sheet, preview-equals-commit counts, Spaces/emoji/profiles, nested folders, Splits, per-profile Favorites and overflow, dormant tabs, persisted reload, repeat without duplication, failed-save rollback and incremental re-import")
            } catch { finish(false, String(describing: error)) }
        }
    }

    // MARK: Helpers

    private func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
        checks += 1
    }
    private func wait(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure.assertion("Timeout: \(message)") }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks += 1
    }
    private func snapshot(_ session: BrowserSession) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session)
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private func button(_ title: String) throws -> NSButton {
        guard let found = views(NSButton.self, in: importer?.window?.contentView).first(where: { $0.title == title }) else {
            throw Failure.assertion("Import sheet has a “\(title)” control")
        }
        return found
    }
    /// Whether the sheet comes from BrowserController.importFromArc itself, so
    /// its real preview/commit/dismiss callbacks are exercised. importFromArc
    /// previews ~/Library/Application Support/Arc/StorableSidebar.json when it
    /// is readable; this fixture never reads a personal layout, so on such a
    /// machine it uses equivalent wiring and says so in its result.
    private var usesActualPlumbing: Bool { !FileManager.default.isReadableFile(atPath: ArcImport.defaultSourceURL().path) }
    private func presentImporter() async throws -> ArcImportController {
        if usesActualPlumbing {
            controller.importFromArc(nil)
            guard let sheet = controller.arcImporter else { throw Failure.assertion("File > Import from Arc… opens the importer") }
            importer = sheet
        } else {
            let sheet = ArcImportController()
            sheet.preview = { [weak controller] source, options in
                guard let controller else { return ArcImport.Report() }
                return ArcImport.apply(source, to: controller.session, options: options).report
            }
            // nil is success; only a missing controller is "closing".
            sheet.onCommit = { [weak controller] source, options in
                guard let controller else { return "Bam is closing." }
                return controller.commitArcImport(source, options: options)
            }
            sheet.onDismiss = { [weak controller] in controller?.arcImporter = nil }
            controller.arcImporter = sheet
            importer = sheet
            sheet.present(on: window)
        }
        guard let sheet = importer else { throw Failure.assertion("Importer exists") }
        try await wait("Import sheet attaches to the browser window") { window.attachedSheet === sheet.window }
        return sheet
    }
    /// Text of the sheet's visible error line, if any.
    private var sheetError: String? {
        views(NSTextField.self, in: importer?.window?.contentView)
            .first { !$0.isHidden && $0.textColor == .systemRed && !$0.stringValue.isEmpty }?.stringValue
    }
    private func waitForDismissal(_ label: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while controller.arcImporter != nil || window.attachedSheet != nil {
            guard Date() < deadline else {
                throw Failure.assertion("Timeout: \(label): sheet dismissed (sheet error: \(sheetError ?? "none"))")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks += 1
        importer = nil
    }
    private func rows(_ session: BrowserSession, _ space: Int) -> [String] {
        session.keptLayout(in: space).map { entry in
            let name = entry.isFolder ? "[" + (session.folder(entry.id)?.name ?? "?") + "]"
                : session.tabs.first { $0.id == entry.id }.map(\.displayTitle) ?? "?"
            return String(repeating: "  ", count: entry.depth) + name
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
                                    "data": ["tab": ["savedURL": "https://board.example.com/g", "savedTitle": "Gamma Board", "timeLastActiveAt": 0.0]]]
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
        controller.privateMode = false; controller.sessionWriter = SessionWriter(url: sessionFile)
        controller.save()
        try check(controller.sessionWriter?.flush(timeout: 5) == true, "Writer saves the pre-import session")
        let original = controller.session
        let originalSnapshot = try snapshot(original)

        // 1. Preview, options and Cancel change nothing.
        var sheet = try await presentImporter()
        try check(!(try button("Import")).isEnabled, "Import is disabled until a layout is chosen")
        sheet.load(fixture)
        guard let preview = sheet.report else { throw Failure.assertion("Choosing the fixture produces a preview") }
        try check(preview.refusal == nil && !preview.isEmpty && (try button("Import")).isEnabled, "Preview enables Import")
        try check(preview.spaces.map(\.title) == ["Work", "Home", "Side"] && preview.spaces.allSatisfy(\.isNew), "Preview lists three new Spaces")
        try check(preview.easels == 1 && preview.liveFolders == 1 && preview.invalidAddresses == 1 && preview.oversizedSplits == 1
                  && preview.favoriteOverflow == 2 && preview.unattachedProfiles == 1 && preview.flattenedTodayFolders == 1,
                  "Preview reports every approximation the fixture contains")
        let todayInPreview = preview.spaces.reduce(0) { $0 + $1.todayTabs }
        try check(todayInPreview > 0, "Preview counts Today tabs")
        (try button("Include Today tabs")).performClick(nil)
        try check(sheet.report?.spaces.reduce(0, { $0 + $1.todayTabs }) == 0
                  && sheet.report?.importedTabs == preview.importedTabs - todayInPreview, "Excluding Today updates the preview")
        (try button("Include Today tabs")).performClick(nil)
        try check(sheet.report == preview, "Re-including Today restores the original preview")
        try check(try snapshot(controller.session) == originalSnapshot, "Previewing never mutates the browser session")
        (try button("Cancel")).performClick(nil)
        try await waitForDismissal("Cancel")
        try check(try snapshot(controller.session) == originalSnapshot, "Cancelled import leaves the session unchanged")
        try check(SessionFile.load(sessionFile).importLinks == nil, "Cancelled import writes nothing imported")
        try check(controller.arcImporter == nil, "Cancel releases the importer")

        // 2. Commit through the sheet.
        sheet = try await presentImporter()
        sheet.load(fixture)
        guard let planned = sheet.report else { throw Failure.assertion("Second preview") }
        (try button("Import")).performClick(nil)
        try await waitForDismissal("Import")
        let session = controller.session
        let addedTabs = session.tabs.filter { tab in !original.tabs.contains { $0.id == tab.id } }
        try check(addedTabs.count == planned.importedTabs, "Commit adds exactly the previewed number of tabs (\(addedTabs.count)/\(planned.importedTabs))")
        try check(session.folders.count - original.folders.count == planned.importedFolders, "Commit adds exactly the previewed folders")
        try check(original.tabs.allSatisfy { tab in session.tabs.contains { $0 == tab } }, "Existing tabs survive unchanged")
        guard let work = session.spaces.first(where: { $0.name == "Work" }), let home = session.spaces.first(where: { $0.name == "Home" }),
              let side = session.spaces.first(where: { $0.name == "Side" }) else { throw Failure.assertion("Imported Spaces exist") }
        try check(session.space == work.id && planned.firstSpaceID == work.id, "Commit shows the first imported Space")
        try check(work.emoji == "💼" && home.emoji == "🏠" && side.emoji == "🧪", "Space emoji preserved")

        // Profiles: default Arc profile -> Bam default; custom -> its own new profile.
        try check(work.profileID == BrowserProfile.defaultID && side.profileID == BrowserProfile.defaultID, "Default Arc profile maps to Bam's default")
        try check(home.profileID != BrowserProfile.defaultID && session.profiles.contains { $0.id == home.profileID }
                  && !original.profiles.contains { $0.id == home.profileID } && planned.newProfiles.count == 1,
                  "Custom Arc profile becomes one new Bam login profile")

        // Hierarchy: nested folders, empty folder, duplicate URL, Splits, overflow.
        let workRows = rows(session, work.id)
        let expected = ["[More Favorites]", "  Fav 13", "  Fav 14", "Team Docs", "[Projects]", "  Alpha Board", "  [Alpha]",
                        "    [Level 2]", "      [Level 3]", "        [Level 4]", "          Deep Page", "  Beta Board",
                        "[Empty]", "Alpha Board copy", "Left Pane", "[Pull Requests]", "  PR 1", "Wide 1", "Wide 3"]
        try check(workRows == expected, "Work kept hierarchy matches Arc order (\(workRows.count) rows)")
        try check(session.folders.map { session.folderDepth($0.id) }.max() == 4, "Five-level folder nesting is represented")
        guard let left = session.tabs.first(where: { $0.title == "Left Pane" }), let right = session.tabs.first(where: { $0.title == "Right Pane" })
        else { throw Failure.assertion("Split panes imported") }
        try check(session.split(for: left.id) == BrowserSplit(primaryID: left.id, secondaryID: right.id), "Arc Split becomes a Bam Split")
        try check(session.tabs.contains { $0.title == "Wide 2" } && session.split(for: session.tabs.first { $0.title == "Wide 1" }!.id) != nil,
                  "Oversized Split keeps two panes and its extra pane")

        // Favorites stay per profile.
        try check(session.favorites(in: BrowserProfile.defaultID).count == 12, "Twelve default-profile Favorites")
        try check(session.favorites(in: home.profileID).map(\.title) == ["Home Mail"], "Custom profile keeps its own Favorite")
        try check(!session.tabs.contains { $0.title.hasPrefix("Other ") }, "Unattached profile Favorites are not imported by default")

        // Dormancy: no imported page loads except what the shown Space selects.
        let importedIDs = Set(addedTabs.map(\.id))
        try check(addedTabs.filter { $0.isSaved }.allSatisfy(\.isUnloaded), "Imported kept tabs and Favorites are dormant")
        let live = importedIDs.intersection(controller.browsers.keys)
        try check(live.isSubset(of: [session.activeID]), "Only the selected tab of the shown Space may have a page (\(live.count) live)")
        try check(Set(addedTabs.filter { !$0.isSaved }.map(\.title)).isSuperset(of: ["Today One", "Today Two", "Loose Today"]),
                  "Today tabs stay ordinary tabs; Today folders flatten")

        // 3. Persisted through the real writer and reloaded as at launch.
        try check(controller.sessionWriter?.isLatestSnapshotSaved == true, "Commit confirmed the import reached disk")
        let reloaded = SessionFile.load(sessionFile)
        try check(reloaded.tabs.map(\.id) == session.tabs.map(\.id) && reloaded.folders == session.folders
                  && reloaded.importLinks == session.importLinks && reloaded.splits == session.splits,
                  "Reloaded session keeps imported tabs, folders, Splits and provenance")
        try check(try encoded(reloaded.spaces) == encoded(session.spaces) && encoded(reloaded.profiles) == encoded(session.profiles),
                  "Reloaded session keeps imported Spaces and profiles")
        try check(rows(reloaded, work.id) == expected, "Reloaded hierarchy is identical")
        try check(reloaded.tabs.filter { importedIDs.contains($0.id) && $0.isSaved }.allSatisfy(\.isUnloaded), "Reloaded imported tabs are still dormant")

        // 4. Repeat import of the same layout adds nothing and cannot commit.
        let committedSnapshot = try snapshot(controller.session)
        sheet = try await presentImporter()
        sheet.load(fixture)
        try check(sheet.report?.isEmpty == true && (sheet.report?.alreadyImported ?? 0) > 0, "Repeat preview finds everything already imported")
        try check(!(try button("Import")).isEnabled, "Repeat import cannot be committed")
        try check(controller.commitArcImport(source, options: ArcImport.Options()) == "Everything in this layout is already in Bam.",
                  "A forced repeat commit is refused")
        try check(try snapshot(controller.session) == committedSnapshot, "Repeat import leaves the session unchanged")
        (try button("Cancel")).performClick(nil)
        try await waitForDismissal("Repeat cancel")

        // 5. A new Arc item with a failing save rolls back and says so; once
        //    saving works, only that item is added beside its source sibling.
        let grown = directory.appendingPathComponent("Grown.json")
        try grownFixture(data).write(to: grown)
        let goodWriter = controller.sessionWriter
        controller.sessionWriter = SessionWriter(url: sessionFile) { _, _ in throw WriteRefused() }
        sheet = try await presentImporter()
        sheet.load(grown)
        try check(sheet.report?.importedTabs == 1, "Preview finds exactly the one new Arc item")
        let beforeFailure = try snapshot(controller.session)
        (try button("Import")).performClick(nil)
        // Wording and sync/async saving belong to the importer; require only a
        // visible error with the sheet still open and nothing changed.
        try await wait("Failed save is reported in the sheet") { self.sheetError != nil }
        try check(window.attachedSheet === sheet.window && controller.arcImporter === sheet, "Sheet stays open after a failed save")
        try check(try snapshot(controller.session) == beforeFailure, "Failed save restores the previous session")
        try check(SessionFile.load(sessionFile).tabs.count == session.tabs.count, "Disk keeps the last good session")
        controller.sessionWriter = goodWriter
        (try button("Import")).performClick(nil)
        try await waitForDismissal("Retry import")
        let merged = rows(controller.session, work.id)
        try check(controller.session.tabs.count == session.tabs.count + 1, "Retry adds only the new item")
        try check(merged.firstIndex(of: "  Gamma Board") == merged.firstIndex(of: "  Beta Board").map { $0 + 1 }, "New item lands after its source sibling")
        try check(merged.filter { $0 != "  Gamma Board" } == expected, "Existing imported layout is untouched")
        try check(SessionFile.load(sessionFile).tabs.count == session.tabs.count + 1, "Retry reaches disk")
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
