import AppKit
import WebKit

@MainActor extension FeatureSmokeTest {
    /// Local pages and an ephemeral session exercise the real sheet, controller,
    /// sidebar and retained WebKit views without touching the user's profile.
    func runEditableSpaces() async throws {
        guard let raw = (ProcessInfo.processInfo.environment["BAM_TEST_URL"] ?? ProcessInfo.processInfo.environment["ARK_TEST_URL"] ?? ProcessInfo.processInfo.environment["ORBIT_TEST_URL"]),
              let url = URLInput.directURL(raw) else { throw Failure.assertion("Editable Spaces require the local fixture URL") }
        let beforeChecks = checks
        let definitions = [
            BrowserSpace(id: 10, name: "First", symbol: "sparkles", colorIndex: 0),
            BrowserSpace(id: 40, name: "Second", symbol: "sun.max", colorIndex: 1),
            BrowserSpace(id: 70, name: "Third", symbol: "globe", colorIndex: 2)
        ]
        let first = BrowserTab(title: "Space fixture", address: url.absoluteString, space: 10, pinned: true)
        let second = BrowserTab(title: "Second Home", address: "orbit://newtab", space: 40)
        let third = BrowserTab(title: "Third Home", address: "orbit://newtab", space: 70)
        let browser = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/bam-unused-spaces.json"), ephemeral: true)
        browser.automaticallyShowsVideo = false
        browser.session = BrowserSession(tabs: [first, second, third], activeID: first.id, space: 10, spaces: definitions)
        let fixtureWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        fixtureWindow.isReleasedWhenClosed = false
        fixtureWindow.title = "Bam editable Spaces fixture"
        fixtureWindow.contentViewController = browser
        fixtureWindow.setContentSize(NSSize(width: 1120, height: 720))
        defer { browser.prepareToClose(); fixtureWindow.close() }
        try await establishKeyWindow(fixtureWindow, label: "editable Spaces browser")
        guard let original = browser.activeWebView else { throw Failure.assertion("Editable Spaces initial WKWebView missing") }
        try await wait("editable Spaces original page") { !original.isLoading && original.title == "Orbit Feature Fixture" }
        _ = try await js(original, "window.__bamSpaceSentinel=123; true")

        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func button(_ title: String, in view: NSView) throws -> NSButton {
            guard let result = descendants(view).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == title || $0.accessibilityLabel() == title
            }) else { throw Failure.assertion("Missing editable Spaces native button: \(title)") }
            return result
        }
        func press(_ title: String, in manager: SpaceManagementController) throws {
            guard let content = manager.window?.contentView else { throw Failure.assertion("Space sheet content missing") }
            try button(title, in: content).performClick(nil)
        }
        func fields(_ manager: SpaceManagementController, name: String, symbol: String, color: Int) {
            manager.window?.makeFirstResponder(nil)
            manager.nameField.stringValue = name
            manager.iconPicker.selectItem(at: BrowserSpace.symbols.firstIndex(of: symbol)!)
            manager.colorPicker.selectItem(at: color)
            manager.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: manager.nameField))
        }
        func retained(_ web: WKWebView, marker: Int) async throws -> Bool {
            (try await js(web, "window.__bamSpaceSentinel===\(marker)")) as? Bool == true
        }
        func selectImmediately(_ id: Int) {
            browser.cancelPaging(); browser.session.changeSpace(id); browser.showActive(); browser.view.layoutSubtreeIfNeeded()
        }

        // Cancelling must discard only the sheet draft. A navigation/title update
        // arriving while it is open must not be rolled back to its opening snapshot.
        // The sidebar's Manage Spaces entries since the Arc-like footer (b11ccba): the current Space's heading
        // ("Manage Spaces — <name>"), and Manage Spaces… in the footer Downloads button's menu. The heading is
        // the visible control that is pressed; the menu entry must exist and reach the same action.
        let visible = descendants(browser.sidebar).compactMap { $0 as? NSButton }.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        guard let heading = visible.first(where: { ($0.accessibilityLabel() ?? "").hasPrefix("Manage Spaces — ") }) else {
            throw Failure.assertion("Missing editable Spaces native button: the Space heading's Manage Spaces")
        }
        guard let downloads = visible.first(where: { $0.identifier?.rawValue == "sidebar-library" }),
              let manageItem = downloads.menu?.items.first(where: { $0.title == "Manage Spaces…" }), manageItem.target != nil, manageItem.action != nil else {
            throw Failure.assertion("Missing editable Spaces native menu entry: Archived Tabs ▸ Manage Spaces…")
        }
        try check(!visible.contains { $0.accessibilityLabel() == "Manage Spaces" && $0.frame.minY >= browser.sidebar.bounds.height - 40 },
                  "The removed footer Manage Spaces stack button is back")
        heading.performClick(nil)
        try await wait("Space management sheet attaches") { browser.spaceManager?.window === fixtureWindow.attachedSheet }
        guard let cancelled = browser.spaceManager else { throw Failure.assertion("Manage Spaces action did not retain its sheet") }
        for (title, action) in [("Close Tab", #selector(BrowserController.closeTab(_:))),
                                ("Hard Refresh", #selector(BrowserController.hardReload(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            try check(!browser.validateMenuItem(item), "Space sheet left the background \(title) menu command enabled")
        }
        try check(!browser.routeSpaceScroll(deltaX: -110, deltaY: 0, phase: .began, isMomentum: false,
                    timestamp: 50, isPrecise: true, isInsideSidebar: true, isFromBrowserWindow: true)
                    && !browser.trackingSwipe && browser.session.space == 10,
                  "A sidebar swipe changed or captured a Space while its management sheet was open")
        fields(cancelled, name: "Unsaved name", symbol: "heart", color: 3)
        try press("New Space", in: cancelled)
        try check(cancelled.plan.spaces.count == 4 && browser.session.spaces == definitions,
                  "Unsaved rename/create escaped the Space sheet draft")
        browser.session.tabs[browser.session.tabs.firstIndex(where: { $0.id == first.id })!].title = "Live title while editing"
        try press("Cancel", in: cancelled)
        try await wait("Space sheet cancellation completes") { browser.spaceManager == nil && fixtureWindow.attachedSheet == nil }
        try check(browser.session.spaces == definitions && browser.session.tabs.count == 3,
                  "Cancel changed Space definitions or created a tab")
        try check(browser.session.tabs.first(where: { $0.id == first.id })?.title == "Live title while editing",
                  "Cancel restored a stale session snapshot over a live title update")
        let retainedAfterCancel = try await retained(original, marker: 123)
        try check(browser.browsers[first.id] === original && retainedAfterCancel,
                  "Cancel replaced or reloaded the live page")

        // Reopen through the footer Downloads menu's Manage Spaces… item: it must reach the same real action.
        try check(NSApp.sendAction(manageItem.action!, to: manageItem.target, from: manageItem),
                  "Downloads ▸ Manage Spaces… did not perform its action")
        try await wait("Space management sheet reopens") { browser.spaceManager?.window === fixtureWindow.attachedSheet }
        guard let editor = browser.spaceManager else { throw Failure.assertion("Second Space editor missing") }
        fields(editor, name: "", symbol: "terminal", color: 3)
        try check(try !button("Save Changes", in: editor.window!.contentView!).isEnabled,
                  "Empty Space name left Save Changes enabled")
        fields(editor, name: "Renamed First", symbol: "terminal", color: 3)
        try press("Move Space later", in: editor); try press("Move Space later", in: editor)
        try check(editor.plan.spaces.map(\.id) == [40, 70, 10] && browser.session.spaceIDs == [10, 40, 70],
                  "Draft reorder altered stable IDs or applied before Save")
        try press("New Space", in: editor)
        fields(editor, name: "Created Space", symbol: "heart", color: 4)
        try check((editor.plan.spaces.last?.id ?? 0) < 0 && browser.session.spaces.count == 3,
                  "Unsaved new Space lacked a draft ID or was persisted early")
        browser.session.tabs[browser.session.tabs.firstIndex(where: { $0.id == first.id })!].title = "Latest title before Save"
        try press("Save Changes", in: editor)
        try await wait("Saving Space sheet dismisses it") { browser.spaceManager == nil && fixtureWindow.attachedSheet == nil }
        guard let created = browser.session.spaces.first(where: { $0.name == "Created Space" }) else {
            throw Failure.assertion("Saved new Space definition missing")
        }
        try check(created.id > 70 && browser.session.spaceIDs == [40, 70, 10, created.id],
                  "Save failed to preserve reordered stable IDs or allocate a fresh permanent ID")
        try check(browser.session.spaceDefinition(10)?.name == "Renamed First"
                    && browser.session.spaceDefinition(10)?.symbol == "terminal"
                    && browser.session.spaceDefinition(10)?.colorIndex == 3,
                  "Save lost the edited Space name, symbol or color")
        try check(browser.session.tabs.first(where: { $0.id == first.id })?.title == "Latest title before Save"
                    && browser.session.activeID == first.id && browser.session.space == 10,
                  "Save replaced current tab metadata or changed the active Space")
        let retainedAfterSave = try await retained(original, marker: 123)
        try check(browser.browsers[first.id] === original && retainedAfterSave,
                  "Saving definition edits replaced/reloaded the original WKWebView")
        browser.view.layoutSubtreeIfNeeded()
        try check(descendants(browser.sidebar).contains { $0.accessibilityLabel() == "Manage Spaces — Renamed First" },
                  "Sidebar heading did not update after renaming a Space with unchanged tabs")
        let renamedButton = try button("Switch to Renamed First space", in: browser.sidebar)
        try check(renamedButton.accessibilityValue() as? String == "Selected" && browser.root.space == 3,
                  "Sidebar selected state or canvas accent used the Space ID as a color index")

        browser.nextSpace(nil)
        try check(browser.session.space == created.id, "Next Space ignored edited order or treated ID as an array position")
        browser.previousSpace(nil)
        try check(browser.session.space == 10 && browser.activeWebView === original, "Previous Space did not return to the retained original page")
        browser.previousSpace(nil)
        try check(browser.session.space == 70, "Previous Space failed across noncontiguous IDs")
        browser.selectSpace(at: 0)
        try check(browser.session.space == 40, "Indexed Space shortcut did not resolve through current order")
        selectImmediately(40)
        func scroll(_ x: CGFloat, phase: SpaceSwipeStateMachine.Phase, time: TimeInterval) -> Bool {
            browser.routeSpaceScroll(deltaX: x, deltaY: 0, phase: phase, isMomentum: false,
                timestamp: time, isPrecise: true, isInsideSidebar: true, isFromBrowserWindow: true)
        }
        _ = scroll(0, phase: .began, time: 100)
        _ = scroll(-110, phase: .changed, time: 100.05)
        try check(browser.pagingTarget == 70 && browser.pagingOffset < 0, "Swipe preview did not map the next position to stable Space ID 70")
        _ = scroll(0, phase: .ended, time: 100.08)
        try check(browser.session.space == 70 && browser.session.active?.space == 70,
                  "Committed swipe selected an array index instead of the destination Space ID")

        selectImmediately(10)
        try check(browser.moveTab(first.id, toSpace: created.id), "Controller rejected moving the active tab to a created Space")
        try check(browser.session.space == created.id && browser.session.activeID == first.id
                    && browser.session.active?.pinned == true && browser.activeWebView === original,
                  "Active tab move lost selection, pin state or the original WKWebView")
        try check(try await retained(original, marker: 123), "Active tab move lost JavaScript state")
        let partner = BrowserTab(title: "Split partner", address: url.absoluteString, space: created.id)
        browser.session.tabs.append(partner)
        try check(browser.session.makeSplit(primary: first.id, secondary: partner.id), "Editable Spaces split fixture could not be created")
        browser.showActive()
        guard let partnerWeb = browser.browsers[partner.id], let split = browser.splitCoordinators[first.id] else {
            throw Failure.assertion("Split fixture did not attach both live pages")
        }
        try await wait("editable Spaces split partner") { !partnerWeb.isLoading && partnerWeb.title == "Orbit Feature Fixture" }
        _ = try await js(partnerWeb, "window.__bamSpaceSentinel=456; true")
        try check(browser.moveTab(partner.id, toSpace: 70), "Moving a secondary Split member was rejected")
        try check(browser.session.tabs.filter { [first.id, partner.id].contains($0.id) }.allSatisfy { $0.space == 70 }
                    && browser.session.split(for: first.id)?.secondaryID == partner.id,
                  "Moving a Split member separated the pair or lost its membership")
        try check(browser.browsers[first.id] === original && browser.browsers[partner.id] === partnerWeb
                    && browser.splitCoordinators[first.id] === split,
                  "Split Space move replaced its pages or coordinator")
        let leftRetainedAfterMove = try await retained(original, marker: 123)
        let rightRetainedAfterMove = try await retained(partnerWeb, marker: 456)
        try check(leftRetainedAfterMove && rightRetainedAfterMove,
                  "Split Space move reloaded one of its documents")

        // Exercise the actual row submenu selector, rather than only calling
        // moveTab directly; the current Space remains visibly disabled.
        let rowTitle = "Movable split row"
        browser.session.tabs[browser.session.tabs.firstIndex(where: { $0.id == first.id })!].title = rowTitle
        browser.refresh(); browser.view.layoutSubtreeIfNeeded()
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: fixtureWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
              let rowMenu = descendants(browser.sidebar).filter({ $0.accessibilityLabel()?.hasPrefix(rowTitle + " · ") == true })
                .compactMap({ $0.menu(for: event) }).first(where: { $0.items.contains(where: { $0.title == "Move to" }) }),
              let moveMenu = rowMenu.items.first(where: { $0.title == "Move to" })?.submenu else {
            throw Failure.assertion("Native tab row has no Move to submenu")
        }
        // Arc's "Move to ▸": every Space, then a separator and New Space….
        let spaceEntries = moveMenu.items.filter { !$0.isSeparatorItem && $0.title != "New Space…" }
        try check(rowMenu.items.contains { $0.title == "Unkeep Left Tab" } && spaceEntries.count == browser.session.spaces.count
                    && moveMenu.items.last?.title == "New Space…",
                  "Move menu changed pin semantics or omitted Space destinations")
        try check(moveMenu.items.first(where: { $0.tag == 70 })?.isEnabled == false,
                  "Move menu enabled the current Space")
        guard let moveDestination = moveMenu.items.first(where: { $0.tag == 40 }), let action = moveDestination.action else {
            throw Failure.assertion("Move menu destination 40 missing")
        }
        try check(NSApp.sendAction(action, to: moveDestination.target, from: moveDestination)
                    && browser.session.space == 40 && browser.session.tabs.first(where: { $0.id == partner.id })?.space == 40,
                  "Native Move to Space action did not move the whole Split to its stable destination")

        let removal = SpaceEditPlan(originalIDs: Set(browser.session.spaceIDs),
                                    spaces: browser.session.spaces.filter { $0.id != 40 }, removalDestinations: [40: created.id])
        try check(browser.applySpaceEdits(removal), "Deleting active Space with an explicit destination was rejected")
        try check(browser.session.spaceDefinition(40) == nil && browser.session.space == created.id
                    && browser.session.tabs.first(where: { $0.id == partner.id })?.space == created.id,
                  "Deleting active Space failed to move the active Split and preserve its selection")
        let leftRetainedAfterDelete = try await retained(original, marker: 123)
        let rightRetainedAfterDelete = try await retained(partnerWeb, marker: 456)
        try check(browser.browsers[first.id] === original && browser.browsers[partner.id] === partnerWeb
                    && leftRetainedAfterDelete && rightRetainedAfterDelete,
                  "Deleting a Space replaced/reloaded surviving live Split pages")
        let oldArchiveTabs = [
            BrowserTab(title: "Archived left", address: "orbit://newtab", space: 40, pinned: true),
            BrowserTab(title: "Archived right", address: "orbit://newtab", space: 40)
        ]
        let idsBeforeRestore = Set(browser.session.tabs.map(\.id))
        let definitionsBeforeRestore = browser.session.spaces
        browser.restoreClosed(ClosedRecord(tabs: oldArchiveTabs, split: true))
        let restored = browser.session.tabs.filter { !idsBeforeRestore.contains($0.id) }
        try check(restored.count == 2 && restored.allSatisfy { $0.space == created.id }
                    && browser.session.spaces == definitionsBeforeRestore,
                  "Restoring a deleted-Space archive recreated its ID or chose the wrong fallback")
        try check(browser.session.split(for: browser.session.activeID) != nil && restored.first?.pinned == true,
                  "Deleted-Space archive fallback lost Split membership or pin state")

        // Deletion chains must not merge unrelated destinations, including when
        // every old Space is removed and a temporary holding Space is required.
        let chainDefinitions = (0..<4).map { BrowserSpace(id: $0, name: "Old \($0)", symbol: "globe", colorIndex: $0) }
        let chainTabs = (0..<4).map { BrowserTab(title: "Tab \($0)", address: "orbit://newtab", space: $0, pinned: $0 == 0) }
        let chainSession = BrowserSession(tabs: chainTabs, activeID: chainTabs[0].id, spaces: chainDefinitions)
        let chainPlan = SpaceEditPlan(originalIDs: Set(0..<4), spaces: [
            BrowserSpace(id: -1, name: "Destination A", symbol: "heart", colorIndex: 3),
            BrowserSpace(id: -2, name: "Destination B", symbol: "book", colorIndex: 4)
        ], removalDestinations: [0: 1, 1: -1, 2: 3, 3: -2])
        guard let chained = chainPlan.applying(to: chainSession),
              let destinationA = chained.spaces.first(where: { $0.name == "Destination A" })?.id,
              let destinationB = chained.spaces.first(where: { $0.name == "Destination B" })?.id else {
            throw Failure.assertion("Valid deletion chains into two new Spaces were rejected")
        }
        try check(Set(chained.tabs.filter { $0.space == destinationA }.map(\.id)) == Set(chainTabs.prefix(2).map(\.id)),
                  "First deletion chain lost tabs or mixed in the other destination's tabs")
        try check(Set(chained.tabs.filter { $0.space == destinationB }.map(\.id)) == Set(chainTabs.suffix(2).map(\.id)),
                  "Second deletion chain was collapsed into the temporary holding destination")
        try check(chained.activeID == chainTabs[0].id && chained.space == destinationA && chained.active?.pinned == true,
                  "All-old-Spaces removal lost the original active tab or pin state")
        var cyclic = chainPlan; cyclic.removalDestinations = [0: 1, 1: 0, 2: -2, 3: -2]
        try check(cyclic.applying(to: chainSession) == nil, "A cyclic Space removal destination was accepted")

        let fullDefinitions = (0..<32).map { BrowserSpace(id: $0, name: "Original \($0)", symbol: "globe", colorIndex: $0 % 6) }
        let fullTabs = (0..<32).map { BrowserTab(title: "Original tab \($0)", address: "orbit://newtab", space: $0) }
        let fullSession = BrowserSession(tabs: fullTabs, activeID: fullTabs[16].id, space: 16, spaces: fullDefinitions)
        let replacementDefinitions = (0..<32).map { BrowserSpace(id: -1 - $0, name: "Replacement \($0)", symbol: "leaf", colorIndex: $0 % 6) }
        let fullPlan = SpaceEditPlan(originalIDs: Set(0..<32), spaces: replacementDefinitions,
                                    removalDestinations: Dictionary(uniqueKeysWithValues: (0..<32).map { ($0, -1 - $0) }))
        guard let replaced = fullPlan.applying(to: fullSession) else { throw Failure.assertion("Replacing all 32 Spaces exhausted temporary allocation capacity") }
        try check(replaced.spaces.count == 32 && Set(replaced.spaceIDs).count == 32 && Set(replaced.spaceIDs).isDisjoint(with: Set(0..<32)),
                  "32-for-32 replacement reused a removed ID or changed the final Space count")
        try check(Set(replaced.tabs.map(\.id)) == Set(fullTabs.map(\.id)) && replaced.activeID == fullTabs[16].id,
                  "32-for-32 replacement dropped tabs or replaced the original active tab")
        try check(fullTabs.enumerated().allSatisfy { index, tab in
            replaced.tabs.first(where: { $0.id == tab.id })?.space == replaced.spaces[index].id
        }, "32-for-32 replacement sent one or more tabs to a different explicit destination")
        try check(replaced.space == replaced.spaces[16].id, "32-for-32 replacement selected the temporary holding Space instead of the original active tab's destination")

        // Native sidebar geometry is checked without opening a menu or posting
        // input. The selected ID and overflow entry must remain reachable.
        let many = SidebarView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        many.configureSpaces(replaced.spaces)
        many.update(tabs: [], space: replaced.spaceIDs.last!, canGoBack: false, canGoForward: false, isLoading: false)
        try check(many.subviews.compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel()?.hasPrefix("Switch to ") == true }.count == 32,
                  "Sidebar omitted Space buttons from a 32-Space configuration")
        for width: CGFloat in [164, 228, 500] {
            many.setFrameSize(NSSize(width: width, height: 640)); many.needsLayout = true; many.layoutSubtreeIfNeeded()
            let selected = try button("Switch to Replacement 31 space", in: many)
            let overflow = try button("Choose Space", in: many)
            try check(!selected.isHidden && !overflow.isHidden && many.bounds.contains(selected.frame) && many.bounds.contains(overflow.frame),
                      "Selected/overflow Space controls are hidden or clipped at sidebar width \(width)")
            let visible = many.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.frame.minY > 600 }
            let overlaps = visible.enumerated().contains { index, item in visible.dropFirst(index + 1).contains { $0.frame.intersects(item.frame) } }
            try check(!overlaps, "Footer Space selector overlaps another native action at sidebar width \(width)")
        }
        print("Editable Spaces: \(checks - beforeChecks) checks passed")
    }
}
