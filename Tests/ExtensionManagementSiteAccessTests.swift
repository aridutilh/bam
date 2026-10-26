import AppKit
import Foundation

/// Manage Extensions ↔ Site Access binding: the real ExtensionManagement with a temporary registry and a fake engine
/// behind ExtensionSiteAccessSource. Offscreen: the editor's presenter shows nothing and no window is ordered front.
@main @MainActor enum ExtensionManagementSiteAccessTests {
    struct Failure: Error { let message: String }
    static func main() {
        guard #available(macOS 15.4, *) else { print("SKIP: Extension management requires macOS 15.4"); return }
        do { print("PASS: Extension management site access — \(try run()) checks") }
        catch { fputs("FAIL: Extension management site access: \((error as? Failure)?.message ?? "\(error)")\n", stderr); exit(1) }
    }

    /// The engine, as the binding sees it. Records every call; behaviors are scripted per test.
    @available(macOS 15.4, *)
    final class FakeEngine: ExtensionSiteAccessSource {
        var snapshots: [UUID: BrowserExtensionSiteAccessSnapshot] = [:]
        var calls: [(id: UUID, profile: UUID, revision: BrowserExtensionSiteAccessSnapshot.Revision, displayed: ExtensionSiteAccess.Declarations, change: BrowserExtensionSiteAccessChange)] = []
        var during: (() -> Void)?          // runs inside performSiteAccess (the engine's changed()/reload alert)
        var after: (() -> Void)?           // runs inside performSiteAccess after the answer is stored (a later change)
        var failure: BrowserExtensionSiteAccessFailure?
        var answer: ((BrowserExtensionSiteAccessSnapshot) -> BrowserExtensionSiteAccessSnapshot)?
        func siteAccess(id: UUID) -> BrowserExtensionSiteAccessSnapshot? { snapshots[id] }
        func performSiteAccess(id: UUID, profileID: UUID, revision: BrowserExtensionSiteAccessSnapshot.Revision,
                               displayed: ExtensionSiteAccess.Declarations, change: BrowserExtensionSiteAccessChange) throws -> BrowserExtensionSiteAccessSnapshot {
            calls.append((id, profileID, revision, displayed, change))
            during?()
            if let failure { throw failure }
            guard let current = snapshots[id] else { throw BrowserExtensionSiteAccessFailure.failed("gone") }
            let next = answer?(current) ?? current
            snapshots[id] = next
            after?()
            return next
        }
    }

    @available(macOS 15.4, *)
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-site-access-manage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), otherProfile = UUID(), docsID = UUID(), mailID = UUID(), offID = UUID()
        let records = [
            BrowserExtensionRecord(id: docsID, profileID: profile, name: "Docs Helper", version: "1.0", packageName: "package", enabled: true),
            BrowserExtensionRecord(id: mailID, profileID: profile, name: "Mail Helper", version: "1.0", packageName: "package", enabled: true),
            BrowserExtensionRecord(id: offID, profileID: profile, name: "Disabled Helper", version: "1.0", packageName: "package")]
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("registry.json"))
        let host = BrowserExtensions(storageURL: root)
        defer { host.shutdown() }
        let manager = ExtensionManagement(host: host)
        let engine = FakeEngine()
        manager.siteAccessSource = engine
        var presented: [ExtensionSiteAccessPanel.Snapshot] = []
        manager.presentSiteAccess = { _, snapshot, _ in presented.append(snapshot) }   // nothing on screen

        let declarations = ExtensionSiteAccess.Declarations(requested: ["https://*.docs.example/*", "*://mail.example/*"], optional: ["https://optional.example/*"])
        func snapshot(_ id: UUID, state: ExtensionSiteAccess.State, declarations: ExtensionSiteAccess.Declarations?, version: String = "1.0",
                      timed: ExtensionSiteAccessEngine.Timed = .init(), profile: UUID = profile) -> BrowserExtensionSiteAccessSnapshot {
            let revision = BrowserExtensionSiteAccessSnapshot.Revision(stored: try? JSONEncoder().encode(state), timed: timed, patterns: [:], version: version,
                                                                       enabled: declarations != nil, context: declarations == nil ? nil : 7, declarations: declarations)
            return BrowserExtensionSiteAccessSnapshot(id: id, profileID: profile, revision: revision, state: state, declarations: declarations,
                                                      timed: timed, effective: [], oneTimeAccess: false)
        }
        var timed = ExtensionSiteAccessEngine.Timed()
        timed.optional["https://optional.example/*"] = Date(timeIntervalSinceNow: 3_600)
        engine.snapshots[docsID] = snapshot(docsID, state: .withheld(), declarations: declarations, timed: timed)
        engine.snapshots[mailID] = snapshot(mailID, state: .allRequested(approving: declarations), declarations: declarations)
        engine.snapshots[offID] = snapshot(offID, state: .withheld(), declarations: nil)
        manager.load(profileID: profile)
        func select(_ id: UUID) { if let row = manager.items(for: id) { manager.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }; manager.refresh() }

        // MARK: The action path and its honest disabled state.
        select(offID)
        try check(!manager.siteAccessButton.isEnabled && manager.siteAccessButton.toolTip == "Enable the extension to change its site access."
                  && manager.siteAccessButton.accessibilityLabel() == "Site access for Disabled Helper", "An unloaded extension can't open Site Access, and says why")
        manager.openSiteAccess()
        try check(manager.siteAccess == nil && presented.isEmpty, "Opening for an unloaded extension shows nothing")
        select(docsID)
        try check(manager.siteAccessButton.isEnabled, "A loaded extension's Site Access is available")
        manager.openSiteAccess()
        guard let binding = manager.siteAccess, let shown = presented.last else { throw Failure(message: "Site Access did not open") }
        try check(binding.extensionID == docsID && binding.profileID == profile && binding.engine == engine.snapshots[docsID] && binding.displayRevision == 1
                  && shown.revision == 1 && shown.extensionID == docsID && shown.declarations == declarations,
                  "The binding keeps the exact engine snapshot and starts display revision 1")
        try check(shown.timedGrants == [.init(pattern: "https://optional.example/*", expires: timed.optional["https://optional.example/*"]!, separatelyApproved: true)],
                  "Time-limited optional grants reach the panel with their end and provenance")
        try check(!manager.siteAccessButton.isEnabled, "Only one editor at a time")
        select(mailID)
        try check(manager.siteAccess === binding && binding.extensionID == docsID, "The editor stays bound to its record when the table selection changes")

        // MARK: Requests carry the exact engine revision and the displayed declarations.
        engine.answer = { current in snapshot(docsID, state: .allRequested(approving: declarations), declarations: declarations, version: current.revision.version) }
        func pick(_ tag: Int) { binding.panel.modeMenu.selectItem(withTag: tag); _ = binding.panel.modeMenu.sendAction(binding.panel.modeMenu.action, to: binding.panel.modeMenu.target) }
        let before = binding.engine
        pick(2)
        try check(engine.calls.count == 1 && engine.calls[0].revision == before.revision && engine.calls[0].displayed == declarations
                  && engine.calls[0].change == .choose(.allRequested) && engine.calls[0].id == docsID && engine.calls[0].profile == profile,
                  "The engine gets the retained full Revision and the declarations the user saw")
        try check(binding.displayRevision == 2 && binding.engine.state.mode == .allRequested && binding.panel.snapshot.revision == 2
                  && binding.panel.snapshot.state.mode == .allRequested, "Success advances the display revision and shows the engine's answer")

        // MARK: Requests that don't match are refused before the engine.
        var answered: Result<ExtensionSiteAccessPanel.Snapshot, ExtensionSiteAccessPanel.Failure>?
        let stale = ExtensionSiteAccessPanel.Request(extensionID: docsID, profileID: profile, revision: 1, displayed: declarations, action: .choose(.withheld))
        binding.panel.perform?(stale) { answered = $0 }
        try check(engine.calls.count == 1, "An old display revision never reaches the engine")
        if case .failure(.failed(let text))? = answered { try check(text.contains("changed"), "It answers with the stale message") } else { throw Failure(message: "Stale request not refused") }
        let unseen = ExtensionSiteAccessPanel.Request(extensionID: docsID, profileID: profile, revision: binding.displayRevision,
                                                      displayed: .init(requested: ["*://mail.example/*"]), action: .choose(.allRequested))
        binding.panel.perform?(unseen) { answered = $0 }
        let foreign = ExtensionSiteAccessPanel.Request(extensionID: mailID, profileID: profile, revision: binding.displayRevision, displayed: declarations, action: .choose(.withheld))
        binding.panel.perform?(foreign) { answered = $0 }
        try check(engine.calls.count == 1, "Different displayed declarations or another extension never reach the engine")
        try check(binding.displayRevision == 5 && binding.panel.feedbackLabel.stringValue.contains("changed"),
                  "Each refused request re-shows the current snapshot (new display revision) with the stale message")

        // MARK: The engine's stale refusal resets to the current snapshot with the message.
        engine.failure = .stale
        engine.snapshots[docsID] = snapshot(docsID, state: .withheld(), declarations: declarations, version: "2.0")   // an update happened
        let beforeStale = binding.displayRevision
        pick(0)
        try check(engine.calls.count == 2 && binding.engine.revision.version == "2.0" && binding.panel.snapshot.state.mode == .withheld
                  && binding.panel.feedbackLabel.stringValue.contains("changed") && binding.displayRevision == beforeStale + 1,
                  "A stale refusal shows the message and the current engine state; nothing was approved: calls=\(engine.calls.count) version=\(binding.engine.revision.version) mode=\(binding.panel.snapshot.state.mode) feedback=\(binding.panel.feedbackLabel.stringValue) display=\(binding.displayRevision)")
        engine.failure = nil

        // MARK: Reentry: the engine notifies (refresh) while applying; the answer isn't dropped.
        engine.answer = { _ in snapshot(docsID, state: .allRequested(approving: declarations), declarations: declarations, version: "2.0") }
        engine.during = { [weak manager] in manager?.refresh() }                          // changed() → manager.refresh()
        engine.after = { [weak manager] in                                                 // and something else changed too
            engine.snapshots[docsID] = snapshot(docsID, state: .withheld(), declarations: declarations, version: "2.1")
            manager?.refresh()
        }
        let beforeReentry = binding.displayRevision
        pick(2)
        engine.during = nil; engine.after = nil
        try check(binding.engine.revision.version == "2.1" && binding.panel.snapshot.state.mode == .withheld && binding.displayRevision == beforeReentry + 2
                  && binding.panel.busy == false, "The answer landed, then the deferred refresh showed the later engine change")
        let steady = binding.displayRevision
        manager.refresh(); manager.refresh()
        try check(binding.displayRevision == steady, "An unchanged engine snapshot doesn't re-render")

        // MARK: Closing: unloaded, removed, profile change, window close; then reopening.
        engine.snapshots[docsID] = snapshot(docsID, state: .withheld(), declarations: nil)
        manager.refresh()
        try check(manager.siteAccess == nil && manager.status.string.contains("Site Access closed because Docs Helper was disabled, removed or reloaded"),
                  "An extension that stops being loaded closes its editor, with a status line")
        let closedPanel = binding.panel
        answered = nil
        closedPanel.perform?(ExtensionSiteAccessPanel.Request(extensionID: docsID, profileID: profile, revision: binding.displayRevision, displayed: declarations,
                                                              action: .choose(.allRequested))) { answered = $0 }
        try check(engine.calls.count == 3, "A closed editor's request never reaches the engine")
        engine.snapshots[docsID] = snapshot(docsID, state: .withheld(), declarations: declarations)
        select(docsID); manager.openSiteAccess()
        try check(manager.siteAccess != nil && manager.siteAccess !== binding, "Reopening creates a fresh binding")
        engine.snapshots[docsID] = nil
        manager.refresh()
        try check(manager.siteAccess == nil, "A removed extension closes its editor")
        engine.snapshots[docsID] = snapshot(docsID, state: .withheld(), declarations: declarations)
        select(docsID); manager.openSiteAccess()
        manager.load(profileID: otherProfile)
        try check(manager.siteAccess == nil && manager.status.string.contains("profile changed"), "Switching profile closes the editor")
        manager.load(profileID: profile); select(docsID); manager.openSiteAccess()
        try check(manager.siteAccess != nil, "Fixture: open again")
        manager.window?.close()   // the red close button / performClose route posts the same willClose
        try check(manager.siteAccess == nil, "Closing the Manage window by any route ends the editor")
        select(docsID); manager.openSiteAccess()
        try check(manager.siteAccess != nil, "Fixture: open after closing the window")
        manager.close()
        try check(manager.siteAccess == nil, "Closing the manager ends the editor")

        // MARK: Revoke Permissions is transactional: a failed save changes nothing (owned temporary registry only).
        guard let revokeIndex = host.records.firstIndex(where: { $0.id == mailID }) else { throw Failure(message: "fixture record missing") }
        let beforeRevoke = host.records[revokeIndex]
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // this test's own directory
        var revokeFailure: String?
        do { try host.revokePermissions(id: mailID) } catch BrowserExtensionSiteAccessFailure.failed(let message) { revokeFailure = message }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try check(revokeFailure?.contains("couldn’t be saved, so nothing changed") == true, "A failed revoke save must say nothing changed: \(revokeFailure ?? "no error")")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try check(try encoder.encode(host.records.first(where: { $0.id == mailID })) == (try encoder.encode(beforeRevoke)), "A failed revoke save must leave the record exactly as it was")
        try host.revokePermissions(id: mailID)
        let revokedRecord = host.records.first(where: { $0.id == mailID })
        try check(revokedRecord?.patterns.isEmpty == true && (try? ExtensionSiteAccessEngine.decode(revokedRecord?.siteAccess))??.mode == .withheld,
                  "With storage writable again, revoke saves withheld")

        // MARK: A stopped extension's message (restart load failure), with and without a failed disable save.
        struct Reason: LocalizedError { var errorDescription: String? { "load refused" } }
        struct SaveFailure: LocalizedError { var errorDescription: String? { "disk full" } }
        let plain = BrowserExtensions.stoppedMessage(name: "Docs Helper", reason: Reason(), disableSaveError: nil)
        try check(plain.contains("stopped and couldn’t restart") && plain.contains("load refused") && plain.contains("Enable it again"), "Stopped message: \(plain)")
        let unsaved = BrowserExtensions.stoppedMessage(name: "Docs Helper", reason: Reason(), disableSaveError: SaveFailure())
        try check(unsaved.contains("couldn’t save that it’s stopped (disk full)") && unsaved.contains("may load again the next time Bam opens")
                  && unsaved.contains("saved, reduced site access") && !unsaved.contains("Enable it again in Manage Extensions."),
                  "A failed disable save is reported, not hidden behind manual-only recovery: \(unsaved)")
        // When the reduced access itself wasn't saved (the engine's failed-save native path), nothing claims it was.
        let accessUnsaved = BrowserExtensions.stoppedMessage(name: "Docs Helper", reason: Reason(), disableSaveError: nil, accessSaved: false)
        try check(accessUnsaved.contains("couldn’t be saved") && accessUnsaved.contains("may restore the access last saved") && !accessUnsaved.contains("saved, reduced"),
                  "An unsaved reduction is reported honestly: \(accessUnsaved)")
        let bothUnsaved = BrowserExtensions.stoppedMessage(name: "Docs Helper", reason: Reason(), disableSaveError: SaveFailure(), accessSaved: false)
        try check(bothUnsaved.contains("which may be broader") && !bothUnsaved.contains("saved, reduced"), "No saved-reduction claim after two failed saves: \(bothUnsaved)")
        // Fail-closed release timeout: "stays off" only when that was saved.
        let timeout = BrowserExtensions.releaseTimeoutMessage(name: "Docs Helper", disableSaveError: nil, accessSaved: true)
        try check(timeout.contains("couldn’t finish restarting") && timeout.contains("stays off"), "Timeout message: \(timeout)")
        let timeoutUnsaved = BrowserExtensions.releaseTimeoutMessage(name: "Docs Helper", disableSaveError: SaveFailure(), accessSaved: true)
        try check(!timeoutUnsaved.contains("stays off") && timeoutUnsaved.contains("couldn’t save that it’s off (disk full)") && timeoutUnsaved.contains("may load again")
                  && timeoutUnsaved.contains("saved, reduced"), "A timeout whose disable wasn't saved must not claim it stays off: \(timeoutUnsaved)")
        let timeoutBoth = BrowserExtensions.releaseTimeoutMessage(name: "Docs Helper", disableSaveError: SaveFailure(), accessSaved: false)
        try check(timeoutBoth.contains("which may be broader") && !timeoutBoth.contains("saved, reduced"), "Timeout after an unsaved reduction: \(timeoutBoth)")
        // Update rollback turned off: the cause alone when saved; disclosed when saving "off" failed.
        try check(BrowserExtensions.offAfterFailureMessage("Cause.", disableSaveError: nil) == "Cause.", "A saved off state adds nothing")
        let offUnsaved = BrowserExtensions.offAfterFailureMessage("Cause.", disableSaveError: SaveFailure())
        try check(offUnsaved.contains("off for now") && offUnsaved.contains("couldn’t save that it’s off (disk full)") && offUnsaved.contains("may load again"),
                  "A failed save of off after an update rollback is disclosed: \(offUnsaved)")

        // MARK: The engine source is weak (the host owns the manager).
        do {
            let temporary = FakeEngine()
            manager.siteAccessSource = temporary
        }
        try check(manager.siteAccessSource == nil, "The manager doesn't retain its engine source")
        return checks
    }
}
