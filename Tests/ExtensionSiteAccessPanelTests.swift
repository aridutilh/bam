import AppKit
import WebKit

/// The site-access editor against a fake engine built on the real ExtensionSiteAccess model. Offscreen: the panel's
/// window is never ordered front, no modal runs (the pending review is substituted) and no input is posted.
@main enum ExtensionSiteAccessPanelTests {
    static func main() {
        _ = NSApplication.shared
        guard #available(macOS 15.4, *) else { print("SKIP: needs macOS 15.4"); return }
        MainActor.assumeIsolated { run() }
    }

    @available(macOS 15.4, *) @MainActor static func run() {
        typealias Access = ExtensionSiteAccess
        typealias Panel = ExtensionSiteAccessPanel
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let docs = Access.Declarations(requested: ["https://*.docs.example/*", "*://mail.example/*"], optional: ["https://optional.example/*"])
        let optionalGrant = "https://optional.example/*"

        /// The engine side of the contract, on the real model: it alone decides and answers.
        @MainActor final class FakeEngine {
            var snapshot: Panel.Snapshot
            var actions: [Panel.Action] = []
            var deferred: ((Result<Panel.Snapshot, Panel.Failure>) -> Void)?
            var holdNext = false
            init(_ snapshot: Panel.Snapshot) { self.snapshot = snapshot }
            func perform(_ action: Panel.Action, _ completion: @escaping @MainActor (Result<Panel.Snapshot, Panel.Failure>) -> Void) {
                actions.append(action)
                var state = snapshot.state
                let decl = snapshot.declarations
                switch action {
                case .choose(.withheld): state = .withheld(optionalGrants: state.optionalGrants)
                case .choose(.allRequested): state = .allRequested(approving: decl, optionalGrants: state.optionalGrants)
                case .choose(.specific): completion(.failure(.failed("Specific sites start with a site"))); return
                case .addSite(let input, let subdomains):
                    let from: Access.Mode = { if case .specific = state.mode { return state.mode }; return .withheld }()
                    switch Access.addSite(input, includeSubdomains: subdomains, to: from, declarations: decl) {
                    case .failure(let refusal): completion(.failure(.refused(refusal))); return
                    case .success(.specific(let sites)): state = .specific(sites, optionalGrants: state.optionalGrants)
                    case .success: break
                    }
                case .removeSite(let site):
                    if case .specific(let sites) = Access.removeSite(site, from: state.mode) { state = .specific(sites, optionalGrants: state.optionalGrants) }
                    else { state = .withheld(optionalGrants: state.optionalGrants) }
                case .acceptPending(let sites): state = Access.accepting(sites, in: state, declarations: decl)
                }
                snapshot.state = state
                let answer = snapshot
                if holdNext { holdNext = false; deferred = { completion($0) } } else { completion(.success(answer)) }
            }
        }
        @MainActor func make(_ state: Access.State, declarations: Access.Declarations = docs, oneTime: Bool = false) -> (Panel, FakeEngine) {
            let snapshot = Panel.Snapshot(extensionName: "Docs Helper", profileName: "Work", state: state, declarations: declarations, oneTimeAccess: oneTime)
            let engine = FakeEngine(snapshot), panel = Panel(snapshot: snapshot)
            panel.perform = { action, completion in engine.perform(action, completion) }
            return (panel, engine)
        }
        @MainActor func titles(_ panel: Panel) -> [String] { panel.modeMenu.itemArray.map(\.title) }
        @MainActor func pick(_ panel: Panel, tag: Int) { panel.modeMenu.selectItem(withTag: tag); _ = panel.modeMenu.sendAction(panel.modeMenu.action, to: panel.modeMenu.target) }
        @MainActor func visible(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

        // MARK: Honest wording: "On click" only with one-time access.
        let (withheldPanel, withheldEngine) = make(.withheld(optionalGrants: [optionalGrant]))
        require(titles(withheldPanel) == ["On no sites", "On specific sites", "On all requested sites"] && withheldPanel.modeMenu.selectedTag() == 0,
                "Without activeTab, withheld is 'On no sites', never 'On click': \(titles(withheldPanel))")
        require(withheldPanel.modeHelp.stringValue.contains("doesn’t support one-time access"), "The help says why: \(withheldPanel.modeHelp.stringValue)")
        let (clickPanel, _) = make(.withheld(), oneTime: true)
        require(titles(clickPanel).first == "On click" && clickPanel.modeHelp.stringValue.contains("Click the extension’s button"),
                "With activeTab the same mode is 'On click'")
        let (allSitesPanel, _) = make(.allRequested(approving: .init(requested: ["<all_urls>"])), declarations: .init(requested: ["<all_urls>"]))
        require(titles(allSitesPanel).last == "On all sites" && allSitesPanel.modeMenu.selectedTag() == 2, "All-hosts requests are worded 'On all sites'")

        // MARK: Optional grants are shown separately, never as revoked.
        require(visible(withheldPanel.optionalLabel) && withheldPanel.optionalLabel.stringValue.contains(optionalGrant)
                && withheldPanel.optionalLabel.stringValue.contains("not changed by this setting")
                && !withheldPanel.optionalLabel.stringValue.lowercased().contains("revoked"), "Optional grant listed as still allowed under On no sites")
        require(withheldPanel.requestedLabel.stringValue.contains("mail.example") && withheldPanel.requestedLabel.stringValue.contains("docs.example"),
                "The requested sites are listed")
        require(!visible(withheldPanel.siteField) && !visible(withheldPanel.reloadNotice) && !visible(withheldPanel.pendingButton),
                "No site editor, notice or pending review at rest")

        // MARK: Choosing specific sites opens a draft; nothing changes until a site is added.
        pick(withheldPanel, tag: 1)
        require(withheldEngine.actions.isEmpty && withheldPanel.draftingSites && visible(withheldPanel.siteField)
                && withheldPanel.snapshot.state.mode == .withheld && withheldPanel.modeHelp.stringValue.contains("access stays as it is"),
                "Picking 'On specific sites' sends nothing and changes nothing until the first site")
        withheldPanel.siteField.stringValue = "elsewhere.example"
        withheldPanel.addButton.performClick(nil)
        require(withheldPanel.feedbackLabel.stringValue.contains("doesn’t request that site") && withheldPanel.siteField.stringValue == "elsewhere.example"
                && withheldPanel.snapshot.state.mode == .withheld && !visible(withheldPanel.reloadNotice),
                "An unrequested site is refused inline with the engine's reason; text kept; nothing changed, no notice")
        withheldPanel.siteField.stringValue = "  "
        withheldPanel.addButton.performClick(nil)
        require(withheldEngine.actions.count == 1 && withheldPanel.feedbackLabel.stringValue.contains("Type a site"), "An empty entry isn't sent")
        withheldPanel.siteField.stringValue = "api.docs.example"
        withheldPanel.addButton.performClick(nil)
        require(withheldEngine.actions.last == .addSite(input: "api.docs.example", includeSubdomains: false)
                && withheldPanel.snapshot.state.mode == .specific(["https://api.docs.example/*"]) && !withheldPanel.draftingSites
                && withheldPanel.sitesTable.numberOfRows == 1 && withheldPanel.siteField.stringValue.isEmpty && visible(withheldPanel.reloadNotice)
                && withheldPanel.feedbackLabel.stringValue.isEmpty,
                "Adding a requested site: the engine's answer is rendered, the field clears, and the reload notice appears (access changed)")
        require(withheldPanel.snapshot.state.optionalGrants == [optionalGrant] && visible(withheldPanel.optionalLabel), "The optional grant is untouched")

        // MARK: Reload notice only on an actual change.
        withheldPanel.reset(to: withheldEngine.snapshot)
        require(!visible(withheldPanel.reloadNotice) && withheldPanel.sitesTable.numberOfRows == 1, "Reopening clears the notice and shows the list")
        withheldPanel.siteField.stringValue = "https://api.docs.example/again"
        withheldPanel.addButton.performClick(nil)
        require(withheldEngine.actions.count == 3 && withheldPanel.snapshot.state.mode == .specific(["https://api.docs.example/*"])
                && !visible(withheldPanel.reloadNotice), "Adding a site already listed changes nothing, so no reload notice")

        // MARK: Removing the last site withholds.
        withheldPanel.sitesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        require(withheldPanel.removeButton.isEnabled, "Remove is enabled for a selected site")
        withheldPanel.removeButton.performClick(nil)
        require(withheldEngine.actions.last == .removeSite("https://api.docs.example/*") && withheldPanel.snapshot.state.mode == .withheld
                && !visible(withheldPanel.siteField) && visible(withheldPanel.reloadNotice) && withheldPanel.modeMenu.selectedTag() == 0,
                "Removing the last site: withheld, editor closes, notice shows")

        // MARK: Choosing All requested and back.
        pick(withheldPanel, tag: 2)
        require(withheldEngine.actions.last == .choose(.allRequested) && withheldPanel.snapshot.state.mode == .allRequested
                && withheldPanel.modeMenu.selectedTag() == 2, "Choosing All requested is sent as the user's explicit choice")
        let actionCount = withheldEngine.actions.count
        pick(withheldPanel, tag: 2)
        require(withheldEngine.actions.count == actionCount, "Re-picking the current choice sends nothing")
        pick(withheldPanel, tag: 0)
        require(withheldEngine.actions.last == .choose(.withheld) && withheldPanel.snapshot.state.mode == .withheld, "Choosing withheld")

        // MARK: Pending requests need an explicit review of exactly those sites.
        let widened = Access.Declarations(requested: docs.requested + ["https://new.example/*"], optional: docs.optional)
        let (pendingPanel, pendingEngine) = make(.allRequested(approving: docs), declarations: widened)
        require(visible(pendingPanel.pendingButton) && pendingPanel.pendingLabel.stringValue.contains("https://new.example/*")
                && pendingPanel.pendingLabel.stringValue.contains("Not allowed yet"), "Pending sites are shown as not allowed yet")
        var reviewed: [[String]] = []
        pendingPanel.confirmPending = { sites, _ in reviewed.append(sites); return false }
        pendingPanel.pendingButton.performClick(nil)
        require(reviewed == [["https://new.example/*"]] && pendingEngine.actions.isEmpty && visible(pendingPanel.pendingButton),
                "Declining the review sends nothing; the sites stay pending")
        pendingPanel.confirmPending = { sites, _ in reviewed.append(sites); return true }
        pendingPanel.pendingButton.performClick(nil)
        require(pendingEngine.actions == [.acceptPending(["https://new.example/*"])] && !visible(pendingPanel.pendingButton) && visible(pendingPanel.reloadNotice),
                "Allowing sends exactly the reviewed sites; the engine's answer has none pending")

        // MARK: The panel never decides: no engine, no change; while the engine works, controls wait.
        let (orphan, _) = make(.withheld())
        orphan.perform = nil
        pick(orphan, tag: 2)
        require(orphan.snapshot.state.mode == .withheld && !visible(orphan.reloadNotice), "Without an engine nothing changes")
        let (slowPanel, slowEngine) = make(.withheld())
        slowEngine.holdNext = true
        pick(slowPanel, tag: 2)
        require(slowPanel.busy && !slowPanel.modeMenu.isEnabled && slowPanel.snapshot.state.mode == .withheld,
                "Until the engine answers, the old snapshot shows and controls are disabled")
        slowEngine.deferred?(.success(slowEngine.snapshot))
        require(!slowPanel.busy && slowPanel.modeMenu.isEnabled && slowPanel.snapshot.state.mode == .allRequested && visible(slowPanel.reloadNotice),
                "The engine's later answer is rendered")
        let (failingPanel, failingEngine) = make(.withheld())
        failingEngine.holdNext = true
        pick(failingPanel, tag: 2)
        failingEngine.deferred?(.failure(.failed("Couldn’t save the change.")))
        require(failingPanel.snapshot.state.mode == .withheld && failingPanel.feedbackLabel.stringValue == "Couldn’t save the change."
                && failingPanel.modeMenu.selectedTag() == 0 && !visible(failingPanel.reloadNotice), "A failure keeps the authoritative state and says so")

        // MARK: Nothing requested; engine messages; accessibility and close.
        let (nothing, _) = make(.allRequested(approving: .init(requested: [])), declarations: .init(requested: []))
        require(!nothing.modeMenu.isEnabled && nothing.modeHelp.stringValue.contains("doesn’t request access to websites") && !visible(nothing.siteField),
                "An extension requesting no sites has nothing to choose")
        var withMessage = withheldEngine.snapshot; withMessage.message = "Access was changed in another window."
        withheldPanel.reset(to: withMessage)
        require(withheldPanel.feedbackLabel.stringValue == "Access was changed in another window." && visible(withheldPanel.feedbackLabel), "Engine messages show")
        require(withheldPanel.modeMenu.accessibilityLabel() == "Site access for Docs Helper" && withheldPanel.sitesTable.accessibilityLabel() == "Allowed sites"
                && withheldPanel.siteField.accessibilityLabel() == "Site to allow" && withheldPanel.removeButton.accessibilityLabel() == "Remove selected site",
                "Controls are labelled for VoiceOver")
        require(withheldPanel.doneButton.keyEquivalent == "\u{1b}" && withheldPanel.siteField.action != nil, "Escape closes; Return in the field adds")
        var closed = 0
        withheldPanel.onClose = { closed += 1 }
        withheldPanel.done()
        require(closed == 1, "Done closes and tells the owner")
        withheldPanel.siteField.stringValue = "typed"; pick(withheldPanel, tag: 1)
        withheldPanel.reset(to: withheldEngine.snapshot)
        require(withheldPanel.siteField.stringValue.isEmpty && !withheldPanel.draftingSites && !visible(withheldPanel.siteField), "Reopening drops a draft and typed text")
        for label in [Panel.describe(.empty), Panel.describe(.invalid), Panel.describe(.unsupportedScheme("ftp")), Panel.describe(.allSites), Panel.describe(.notRequested)] {
            require(!label.isEmpty && !label.contains("Refusal"), "Every refusal has plain wording: \(label)")
        }

        print("PASS: \(checks) extension site access panel checks")
    }
}
