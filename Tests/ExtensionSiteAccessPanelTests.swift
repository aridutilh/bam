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
            var requests: [Panel.Request] = []
            var deferred: ((Result<Panel.Snapshot, Panel.Failure>) -> Void)?
            var holdNext = false
            init(_ snapshot: Panel.Snapshot) { self.snapshot = snapshot }
            func perform(_ request: Panel.Request, _ completion: @escaping @MainActor (Result<Panel.Snapshot, Panel.Failure>) -> Void) {
                requests.append(request)
                let action = request.action
                actions.append(action)
                // A real engine refuses a proposal made from an old revision, for another extension/profile, or from
                // declarations other than the current ones (a manifest changed between render and click).
                guard request.extensionID == snapshot.extensionID, request.profileID == snapshot.profileID, request.revision == snapshot.revision,
                      request.displayed == snapshot.declarations else {
                    completion(.failure(.failed("Site access changed; showing the current setting."))); return
                }
                var state = snapshot.state
                let decl = snapshot.declarations
                switch action {
                case .choose(.withheld): state = .withheld(optionalGrants: state.optionalGrants)
                case .choose(.allRequested): state = .allRequested(approving: request.displayed, optionalGrants: state.optionalGrants)
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
                if state != snapshot.state { snapshot.revision += 1 }
                snapshot.state = state
                let answer = snapshot
                if holdNext { holdNext = false; deferred = { completion($0) } } else { completion(.success(answer)) }
            }
        }
        @MainActor func make(_ state: Access.State, declarations: Access.Declarations = docs, oneTime: Bool = false) -> (Panel, FakeEngine) {
            let snapshot = Panel.Snapshot(extensionID: UUID(), profileID: UUID(), revision: 1, extensionName: "Docs Helper", profileName: "Work",
                                          state: state, declarations: declarations, oneTimeAccess: oneTime)
            let engine = FakeEngine(snapshot), panel = Panel(snapshot: snapshot)
            panel.perform = { request, completion in engine.perform(request, completion) }
            return (panel, engine)
        }
        @MainActor func titles(_ panel: Panel) -> [String] { panel.modeMenu.itemArray.map(\.title) }
        @MainActor func pick(_ panel: Panel, tag: Int) { panel.modeMenu.selectItem(withTag: tag); _ = panel.modeMenu.sendAction(panel.modeMenu.action, to: panel.modeMenu.target) }
        @MainActor func visible(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

        // MARK: Honest wording: "On click" only with one-time access.
        let (withheldPanel, withheldEngine) = make(.withheld(optionalGrants: [optionalGrant]))
        require(titles(withheldPanel) == ["No requested sites", "On specific sites", "On all requested sites"] && withheldPanel.modeMenu.selectedTag() == 0,
                "Without activeTab, withheld is 'No requested sites', never 'On click': \(titles(withheldPanel))")
        let withheldHelp = withheldPanel.modeHelp.stringValue
        require(withheldHelp.contains("doesn’t support one-time access") && withheldHelp.contains("None of the sites it requests"),
                "The help says why, about requested sites: \(withheldHelp)")
        // Review (3): with an optional grant kept, nothing claims the extension has no site access at all.
        require(withheldHelp.contains("Separately, it still has access to 1 site it asked for") && !withheldHelp.contains("No site is allowed")
                && !titles(withheldPanel).contains("On no sites"), "Withheld wording is scoped to requested sites and states the kept optional access")
        let (clickPanel, _) = make(.withheld(), oneTime: true)
        require(titles(clickPanel).first == "On click" && clickPanel.modeHelp.stringValue.contains("Click the extension’s button")
                && !clickPanel.modeHelp.stringValue.contains("Separately"), "With activeTab the same mode is 'On click'; no optional sentence without optional grants")
        let (allSitesPanel, _) = make(.allRequested(approving: .init(requested: ["<all_urls>"])), declarations: .init(requested: ["<all_urls>"]))
        require(titles(allSitesPanel).last == "On all sites" && allSitesPanel.modeMenu.selectedTag() == 2, "All-hosts requests are worded 'On all sites'")

        // MARK: Optional grants are shown separately, never as revoked.
        require(visible(withheldPanel.optionalLabel) && withheldPanel.optionalLabel.stringValue.contains(optionalGrant)
                && withheldPanel.optionalLabel.stringValue.contains("this setting doesn’t change them")
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
        require(!nothing.modeMenu.isEnabled && nothing.modeHelp.stringValue == "This extension doesn’t require access to any website." && !visible(nothing.siteField),
                "An extension requiring no sites has nothing to choose")
        let (optionalOnly, _) = make(.allRequested(approving: .init(requested: []), optionalGrants: [optionalGrant]),
                                     declarations: .init(requested: [], optional: [optionalGrant]))
        require(optionalOnly.modeHelp.stringValue.contains("doesn’t require access") && optionalOnly.modeHelp.stringValue.contains("Separately, it has access to 1 site")
                && visible(optionalOnly.optionalLabel), "No required sites but an optional grant: worded about required access, optional access stated")
        let (specificOptional, _) = make(.specific(["https://api.docs.example/*"], optionalGrants: [optionalGrant]))
        require(specificOptional.modeHelp.stringValue.contains("Of the sites it requests, it’s allowed only on the 1 site you chose")
                && specificOptional.modeHelp.stringValue.contains("Separately, it still has access to 1 site"), "Specific sites with an optional grant say both")
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

        // MARK: Review (1): a stale answer never lands on a replaced snapshot or a newer request.
        let (stalePanel, staleEngine) = make(.withheld())
        staleEngine.holdNext = true
        pick(stalePanel, tag: 2)                                     // request A, held
        let answerA = staleEngine.deferred
        var other = staleEngine.snapshot                             // reopened for another extension: B
        other.extensionID = UUID(); other.extensionName = "Other"; other.state = .withheld()
        let engineB = FakeEngine(other)
        stalePanel.perform = { request, completion in engineB.perform(request, completion) }
        stalePanel.reset(to: other)
        engineB.holdNext = true
        pick(stalePanel, tag: 2)                                     // request B, held
        require(stalePanel.busy && engineB.requests.last?.extensionID == other.extensionID, "B's request carries B's identity")
        answerA?(.success(staleEngine.snapshot))                     // A answers late
        require(stalePanel.busy && stalePanel.snapshot.extensionName == "Other" && stalePanel.snapshot.state.mode == .withheld
                && !visible(stalePanel.reloadNotice), "A's late success neither overwrites B nor clears B's busy state")
        engineB.deferred?(.success(engineB.snapshot))
        require(!stalePanel.busy && stalePanel.snapshot.state.mode == .allRequested && stalePanel.snapshot.extensionName == "Other", "B's own answer lands")
        let (failPanel, failEngine) = make(.withheld())
        failEngine.holdNext = true
        pick(failPanel, tag: 2)
        failPanel.reset(to: failEngine.snapshot)
        failEngine.deferred?(.failure(.failed("late failure")))
        require(failPanel.feedbackLabel.stringValue.isEmpty && !failPanel.busy, "A late failure after reopening shows nothing")
        let (closePanel, closeEngine) = make(.withheld())
        closeEngine.holdNext = true
        pick(closePanel, tag: 2)
        closePanel.done()
        closeEngine.deferred?(.success(closeEngine.snapshot))
        require(closePanel.snapshot.state.mode == .withheld && !closePanel.busy, "An answer after closing is dropped")
        let (foreignPanel, foreignEngine) = make(.withheld())
        foreignEngine.holdNext = true
        pick(foreignPanel, tag: 2)
        var foreign = foreignEngine.snapshot; foreign.extensionID = UUID()
        foreignEngine.deferred?(.success(foreign))
        require(foreignPanel.snapshot.extensionID != foreign.extensionID && foreignPanel.snapshot.state.mode == .withheld,
                "A snapshot for another extension is never rendered as this one's answer")
        require(staleEngine.requests.first.map { $0.revision == 1 && $0.action == .choose(.allRequested) } == true, "Requests carry the revision they came from")

        // MARK: Review (2): the pending review is bound to what was reviewed and rechecked after the modal.
        let (reentrant, reentrantEngine) = make(.allRequested(approving: docs), declarations: widened)
        var otherPending = reentrantEngine.snapshot
        otherPending.extensionID = UUID(); otherPending.extensionName = "Other"
        otherPending.declarations = Access.Declarations(requested: docs.requested + ["https://other-new.example/*"], optional: docs.optional)
        reentrant.confirmPending = { _, _ in reentrant.reset(to: otherPending); return true }   // rebound while the dialog is up
        reentrant.pendingButton.performClick(nil)
        require(reentrantEngine.actions.isEmpty && reentrant.snapshot.extensionName == "Other", "Approving A's review never approves B's pending sites")
        let (revised, revisedEngine) = make(.allRequested(approving: docs), declarations: widened)
        var newer = revisedEngine.snapshot; newer.revision += 1
        revised.confirmPending = { _, _ in revised.reset(to: newer); return true }               // same extension, changed meanwhile
        revised.pendingButton.performClick(nil)
        require(revisedEngine.actions.isEmpty && revised.feedbackLabel.stringValue.contains("changed while you were reviewing"),
                "A revision change during the review cancels the approval and asks to review again")
        var morePending = revisedEngine.snapshot
        morePending.declarations = Access.Declarations(requested: widened.requested + ["https://more.example/*"], optional: docs.optional)
        let (grown, grownEngine) = make(.allRequested(approving: docs), declarations: widened)
        grown.confirmPending = { _, _ in var next = morePending; next.extensionID = grown.snapshot.extensionID; next.profileID = grown.snapshot.profileID
            next.revision = grown.snapshot.revision; grown.reset(to: next); return true }
        grown.pendingButton.performClick(nil)
        require(grownEngine.actions.isEmpty, "If the pending list itself changed during the review, nothing is approved")
        let (stalePending, stalePendingEngine) = make(.allRequested(approving: docs), declarations: widened)
        stalePendingEngine.snapshot.revision += 1                    // engine moved on without the panel knowing
        stalePending.confirmPending = { _, _ in true }
        stalePending.pendingButton.performClick(nil)
        require(stalePendingEngine.actions == [.acceptPending(["https://new.example/*"])] && stalePendingEngine.snapshot.state == stalePending.snapshot.state
                && stalePending.feedbackLabel.stringValue.contains("changed"), "A stale revision reaches the engine, which refuses it; the panel says so")

        // MARK: Third review: All requested approves exactly what was displayed.
        let (scoped, scopedEngine) = make(.withheld())
        scopedEngine.snapshot.declarations = widened                 // manifest changed after the panel rendered
        pick(scoped, tag: 2)
        require(scopedEngine.requests.last?.displayed == docs && scopedEngine.snapshot.state.mode == .withheld && scoped.snapshot.state.mode == .withheld,
                "A click on All requested carries the displayed declarations; with a newer manifest the engine refuses and nothing is approved")
        let (bound, boundEngine) = make(.withheld())
        pick(bound, tag: 2)
        require(boundEngine.snapshot.state.approvedRequests == docs.requested.sorted()
                && Access.pendingRequests(boundEngine.snapshot.state, declarations: widened) == ["https://new.example/*"],
                "Approving All requested approves exactly the displayed requests; a later addition is pending, not approved")

        // MARK: Third review: long lists never push controls out of reach.
        let many = (0..<60).map { "https://site-\($0).long-requested-domain-name.example/*" }
        let longDecl = Access.Declarations(requested: many + ["https://added-later.example/*"], optional: (0..<30).map { "https://optional-\($0).example/*" })
        let longState = Access.State(mode: .allRequested, optionalGrants: longDecl.optional, approvedRequests: many)
        let (longPanel, _) = make(longState, declarations: longDecl)
        var longSnapshot = longPanel.snapshot; longSnapshot.message = String(repeating: "A long engine message that wraps. ", count: 20)
        longPanel.reset(to: longSnapshot)
        @MainActor func settle(_ panel: Panel) { panel.window?.contentView?.layoutSubtreeIfNeeded(); panel.detailScroll.documentView?.layoutSubtreeIfNeeded() }
        settle(longPanel)
        let content = longPanel.window!.contentView!
        require(content.bounds.height <= 470.5, "The window keeps its bounded size: \(content.bounds)")
        let doneFrame = longPanel.doneButton.convert(longPanel.doneButton.bounds, to: content)
        require(content.bounds.contains(doneFrame) && doneFrame.height > 10, "Done stays inside the window: \(doneFrame) in \(content.bounds)")
        let scrollFrame = longPanel.detailScroll.convert(longPanel.detailScroll.bounds, to: content)
        require(content.bounds.contains(scrollFrame) && !scrollFrame.intersects(doneFrame), "The details region is bounded and above the footer")
        let documentHeight = longPanel.detailScroll.documentView!.frame.height, visibleHeight = longPanel.detailScroll.contentView.bounds.height
        require(documentHeight > visibleHeight + 200, "Long details overflow into the scroll region (\(documentHeight) vs \(visibleHeight))")
        @MainActor func reachable(_ control: NSView, in panel: Panel) -> Bool {
            control.scrollToVisible(control.bounds)
            let clip = panel.detailScroll.contentView
            let inClip = control.convert(control.bounds, to: clip)
            return clip.bounds.contains(inClip) && panel.window!.contentView!.bounds.contains(control.convert(control.bounds, to: panel.window!.contentView!))
        }
        require(visible(longPanel.pendingButton) && reachable(longPanel.pendingButton, in: longPanel), "The pending review button can be scrolled into view")
        require(reachable(longPanel.modeMenu, in: longPanel), "The mode menu can be scrolled back into view")
        pick(longPanel, tag: 1)
        settle(longPanel)
        require(visible(longPanel.addButton) && reachable(longPanel.addButton, in: longPanel) && reachable(longPanel.siteField, in: longPanel),
                "The site editor's field and Add button are reachable with long lists")
        let doneAfter = longPanel.doneButton.convert(longPanel.doneButton.bounds, to: content)
        require(doneAfter == doneFrame, "Done doesn't move while the details scroll")

        print("PASS: \(checks) extension site access panel checks")
    }
}
