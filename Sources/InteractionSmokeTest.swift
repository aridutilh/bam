import AppKit
import WebKit

/// Controller-level native tests using bundled Home pages, real Space buttons,
/// and local NSEvent fixtures passed through the scroll-event adapter and native
/// sidebar receivers. Receiver fixtures exercise in-process delivery, not OS input.
/// Fixtures are never posted to the application or system event queue.
@MainActor final class InteractionSmokeTest {
    private var controller: BrowserController!
    private var window: NSWindow!
    private var timeout: Timer?
    private var completed = false
    private var checks = 0
    private var skippedInterruptions = 0
    private var initialWeb: WKWebView?
    private var selectedSpaceOneTab = UUID()
    private var alternateSpaceOneTab = UUID()
    private var gestureTimestamp: TimeInterval = 100
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    func start() {
        // Ephemeral mode neither loads nor saves this path. Replace the fresh
        // session before loadView so even the default remote pins never load.
        let unusedSession = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/browser-build/interaction-unused-session.json")
        controller = BrowserController(sessionURL: unusedSession, ephemeral: true)
        let zero = BrowserTab(title: "Local zero", address: "orbit://newtab", space: 0)
        let one = BrowserTab(title: "Local one", address: "orbit://newtab", space: 1)
        let alternate = BrowserTab(title: "Local alternate", address: "orbit://newtab", space: 1)
        let two = BrowserTab(title: "Local two", address: "orbit://newtab", space: 2)
        selectedSpaceOneTab = one.id; alternateSpaceOneTab = alternate.id
        controller.session = BrowserSession(tabs: [zero, one, alternate, two], activeID: zero.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bam — local interaction smoke test"
        window.contentViewController = controller
        // AppKit adopts the controller root view’s initial size (1×1 here).
        // Match App.swift by sizing the content after installing the controller.
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.layoutBrowser()
        timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.finish(false, "Controller test timed out") }
        }
        waitUntil("initial local page", condition: { self.localPageIsReady }) {
            self.initialWeb = self.controller.activeWebView
            self.testImmediateSpaceContent { self.testInitialSpaceSwitch() }
        }
    }

    private func testInitialSpaceSwitch() {
        controller.changeSpace(1)
        waitUntil("space change completion", condition: {
            self.controller.session.space == 1 && !self.controller.pagingAnimator.isRunning && self.controller.pagingTarget == nil && self.localPageIsReady
        }) {
            guard self.check(self.controller.session.activeID == self.selectedSpaceOneTab && self.controller.activeWebView !== self.initialWeb && self.controller.activeWebView?.superview === self.controller.webHost && self.pagingIsClear, "Space change did not display the target tab") else { return }
            self.controller.activeWebView?.evaluateJavaScript("document.title") { [weak self] value, error in
                guard let self else { return }
                guard self.check(error == nil && value as? String == "A little space", "Visible target page did not render bundled Home") else { return }
                self.testAddressInterrupt()
            }
        }
    }

    private struct ContentFailure: Error, CustomStringConvertible { let description: String }

    /// Warm documents make a delayed content swap observable independently of
    /// network timing. Immediate assertions run in the same call stack as each
    /// command, before awaiting JavaScript or the sidebar animation.
    private func testImmediateSpaceContent(_ completion: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let automaticVideo = self.controller.automaticallyShowsVideo
            self.controller.automaticallyShowsVideo = false
            defer { self.controller.automaticallyShowsVideo = automaticVideo }
            do {
                @MainActor func require(_ condition: Bool, _ message: String) throws {
                    guard condition else { throw ContentFailure(description: message) }
                    self.checks += 1
                }
                @MainActor func js(_ web: WKWebView, _ source: String) async throws -> Any? {
                    try await withCheckedThrowingContinuation { continuation in
                        web.evaluateJavaScript(source) { value, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: value) }
                        }
                    }
                }
                @MainActor func wait(_ label: String, _ condition: @MainActor () -> Bool) async throws {
                    for _ in 0..<100 {
                        if condition() { return }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    throw ContentFailure(description: "Timed out: \(label)")
                }
                var pages: [Int: WKWebView] = [:]
                var ids: [Int: UUID] = [:]
                var tokens: [Int: String] = [:]
                for space in 0...2 {
                    self.selectSpaceImmediately(space)
                    guard let web = self.controller.activeWebView else { throw ContentFailure(description: "No warm page in Space \(space)") }
                    try await wait("warm Space \(space)") { !web.isLoading && web.title == "A little space" }
                    let token = UUID().uuidString
                    _ = try await js(web, "window.__arkSpaceToken='\(token)'; window.__arkSpaceOrigin=performance.timeOrigin; var f=document.createElement('input'); f.id='ark-space-state'; f.value='kept-\(space)'; document.body.appendChild(f); true")
                    pages[space] = web; ids[space] = self.controller.session.activeID; tokens[space] = token
                }
                let warmIDs = Set(self.controller.browsers.keys)
                @MainActor func displayed(_ space: Int, _ label: String) throws {
                    guard let web = pages[space], let id = ids[space] else { throw ContentFailure(description: "Missing warm target") }
                    try require(self.controller.session.space == space && self.controller.session.activeID == id
                                    && self.controller.displayedTabID == id && self.controller.activeWebView === web,
                                "\(label) delayed the model or live page until sidebar settling")
                    try require(web.superview === self.controller.webHost && web.window === self.window
                                    && !web.isHiddenOrHasHiddenAncestor && web.alphaValue > 0.99,
                                "\(label) did not immediately attach the visible destination WKWebView")
                    try require(self.controller.webHost.subviews.last === web
                                    && abs(web.frame.width - self.controller.webHost.bounds.width) < 0.5
                                    && abs(web.frame.height - self.controller.webHost.bounds.height) < 0.5,
                                "\(label) left a stale content overlay or incorrectly sized destination")
                }
                @MainActor func retained(_ space: Int) async throws {
                    guard let web = pages[space], let token = tokens[space], let id = ids[space] else { throw ContentFailure(description: "Missing warm state") }
                    let state = try await js(web, "window.__arkSpaceToken==='\(token)' && document.getElementById('ark-space-state')?.value==='kept-\(space)' && performance.timeOrigin===window.__arkSpaceOrigin")
                    try require(self.controller.browsers[id] === web && state as? Bool == true,
                                "Space \(space) replaced/reloaded its WKWebView or lost live document state")
                }
                @MainActor func stillSettling(_ label: String) throws {
                    if !self.reduceMotion {
                        try require(self.controller.pagingAnimator.isRunning, "\(label) did not exercise content readiness before sidebar settling")
                    }
                }
                var handoffMilliseconds: [Double] = []
                @MainActor func warmChange(_ space: Int) {
                    let start = ProcessInfo.processInfo.systemUptime
                    self.controller.changeSpace(space)
                    handoffMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                self.selectSpaceImmediately(0)
                warmChange(1)
                try displayed(1, "Direct Space command")
                try stillSettling("Direct Space command")
                // Every latest request must take effect now, including returning
                // to an earlier destination while the previous spring is active.
                for target in [2, 0, 2, 1] {
                    warmChange(target)
                    try displayed(target, "Rapid Space \(target) request")
                }
                self.controller.nextSpace(nil)
                try displayed(2, "Next Space shortcut")
                self.controller.previousSpace(nil)
                try displayed(1, "Previous Space shortcut")
                guard let studio = self.spaceButton(named: "Studio") else { throw ContentFailure(description: "Missing native Studio Space button") }
                studio.performClick(nil)
                try displayed(0, "Native Space button")
                warmChange(1)
                warmChange(0)
                try displayed(0, "Reversed Space command")
                try await wait("rapid content transition settles") { self.pagingIsClear }
                try displayed(0, "Settled reverse request")
                for space in 0...2 { try await retained(space) }
                try require(Set(self.controller.browsers.keys) == warmIDs, "Warm Space switches allocated extra WKWebViews")
                let times = handoffMilliseconds.sorted()
                print(String(format: "Space content handoff: %d warmed synchronous calls, median %.2f ms, maximum %.2f ms (host attachment, not screen presentation)", times.count, times[times.count / 2], times.last ?? 0))
                fflush(stdout)

                // A new horizontal gesture starts from the already committed
                // Space, not the positive offset of its incoming sidebar page.
                warmChange(1)
                _ = self.scroll(phase: .began)
                _ = self.scroll(-70, phase: .changed)
                try displayed(1, "New horizontal gesture during committed sidebar settling")
                try require(self.controller.trackingSwipe && abs(self.controller.pagingOffset + 70) < 0.001,
                            "New horizontal gesture inherited the incoming page offset and reversed its destination")
                _ = self.scroll(phase: .ended)
                try displayed(2, "New horizontal gesture release")
                try await wait("horizontal takeover settles") { self.pagingIsClear }
                try await retained(2)
                self.selectSpaceImmediately(0)

                // A preview has no committed destination. Cancellation must not
                // replace or reload the source, even after its spring completes.
                _ = self.scroll(phase: .began)
                _ = self.scroll(-35, phase: .changed)
                try displayed(0, "Uncommitted swipe preview")
                _ = self.scroll(phase: .cancelled)
                try displayed(0, "Cancelled swipe preview")
                try await wait("cancelled content preview settles") { self.pagingIsClear }
                try displayed(0, "Settled cancelled preview")
                try await retained(0)

                _ = self.scroll(phase: .began)
                _ = self.scroll(-70, phase: .changed)
                try displayed(0, "Swipe before physical release")
                _ = self.scroll(phase: .ended, momentum: true)
                try displayed(1, "Committed swipe release")
                try stillSettling("Committed swipe release")
                _ = self.scroll(-120, phase: .none, momentum: true)
                try displayed(1, "Committed swipe momentum tail")
                try await wait("committed content swipe settles") { self.pagingIsClear }
                try await retained(1)

                // The alternate tab has never been created. Its load must start
                // in the command call itself, not in the spring's completion.
                self.selectSpaceImmediately(0)
                try require(self.controller.browsers[self.alternateSpaceOneTab] == nil, "Cold Space fixture was already loaded")
                self.controller.session.lastSelectedTabIDsBySpace?[1] = self.alternateSpaceOneTab
                self.controller.changeSpace(1)
                guard let cold = self.controller.browsers[self.alternateSpaceOneTab] else { throw ContentFailure(description: "Cold Space load waited for the sidebar animation") }
                try require(self.controller.session.activeID == self.alternateSpaceOneTab
                                && self.controller.displayedTabID == self.alternateSpaceOneTab
                                && self.controller.activeWebView === cold && cold.superview === self.controller.webHost
                                && self.controller.webHost.subviews.last === cold,
                            "Cold Space destination was not attached in the command call")
                try require(self.controller.pendingLoads.contains(self.alternateSpaceOneTab)
                                && self.controller.requestedAddresses[self.alternateSpaceOneTab] == "orbit://newtab",
                            "Cold Space navigation was not requested before sidebar completion")
                try stillSettling("Cold Space navigation")
                try await wait("cold destination renders") { !cold.isLoading && cold.title == "A little space" }
                self.controller.select(self.selectedSpaceOneTab)
                try displayed(1, "Selecting warm tab after cold destination")
                try await retained(1)

                // A warm split is one destination host with two existing live
                // pages. Neither pane may wait for the sidebar spring or sit
                // behind the previous Space's full-page snapshot.
                guard let splitID = ids[2], let splitLeft = pages[2] else { throw ContentFailure(description: "Missing split destination") }
                let rightTab = BrowserTab(title: "Warm split right", address: "orbit://newtab", space: 2)
                self.controller.session.tabs.append(rightTab)
                try require(self.controller.session.makeSplit(primary: splitID, secondary: rightTab.id), "Could not create the split content fixture")
                self.controller.showActive()
                guard let split = self.controller.splitCoordinators[splitID], let right = self.controller.browsers[rightTab.id] else {
                    throw ContentFailure(description: "Split fixture did not attach its two pages")
                }
                try await wait("warm split right") { !right.isLoading && right.title == "A little space" }
                _ = try await js(right, "window.__arkSplitToken='kept'; true")
                self.selectSpaceImmediately(0)
                self.controller.changeSpace(2)
                try require(self.controller.session.activeID == splitID && self.controller.displayedTabID == splitID
                                && self.controller.webHost.subviews.last === split.view && split.view.superview === self.controller.webHost,
                            "Split destination waited for settling or remained behind a stale page overlay")
                try require(splitLeft.isDescendant(of: split.view) && right.isDescendant(of: split.view)
                                && splitLeft.window === self.window && right.window === self.window
                                && !splitLeft.isHiddenOrHasHiddenAncestor && !right.isHiddenOrHasHiddenAncestor,
                            "Split Space command did not immediately attach both existing live panes")
                try stillSettling("Split Space command")
                try await retained(2)
                try require((try await js(right, "window.__arkSplitToken==='kept'")) as? Bool == true,
                            "Switching to a split reloaded its right pane")
                try await wait("split content transition settles") { self.pagingIsClear }
                self.controller.unsplit(splitID)
                self.controller.close(rightTab.id)
                self.selectSpaceImmediately(0)
                completion()
            } catch {
                self.finish(false, String(describing: error))
            }
        }
    }

    private var localPageIsReady: Bool {
        guard let web = controller.activeWebView else { return false }
        return !web.isLoading && web.url?.isFileURL == true && web.url?.lastPathComponent == "Home.html" && controller.tabErrors[controller.session.activeID] == nil
    }
    private var pagingIsClear: Bool {
        !controller.pagingAnimator.isRunning && controller.pagingTarget == nil && abs(controller.pagingOffset) < 0.001 && !controller.sidebar.isPaging && !controller.trackingSwipe
    }

    private func beginInterruptibleChange(_ action: @escaping () -> Void) {
        selectSpaceImmediately(1)
        controller.changeSpace(2)
        if reduceMotion {
            // Selection is already committed; there is no timed animation to
            // interrupt when the system requests Reduce Motion.
            skippedInterruptions += 1
            action()
        } else {
            after(0.025) {
                guard self.check(self.controller.session.space == 2 && self.controller.pagingAnimator.isRunning, "Expected committed content with an in-flight sidebar transition") else { return }
                action()
            }
        }
    }

    private func testAddressInterrupt() {
        beginInterruptibleChange {
            self.controller.openAddress(newTab: false, empty: true)
            guard self.check(self.pagingIsClear && self.controller.addressOverlay != nil && self.controller.session.space == 2, "Opening address did not cancel sidebar paging while retaining the committed Space") else { return }
            let committedID = self.controller.session.activeID
            self.after(0.8) {
                guard self.check(self.controller.session.space == 2 && self.controller.session.activeID == committedID && self.pagingIsClear, "Cancelling sidebar motion rolled back or later replaced committed content") else { return }
                self.controller.dismissAddress()
                self.testSelectionInterrupt()
            }
        }
    }

    private func testSelectionInterrupt() {
        beginInterruptibleChange {
            self.controller.select(self.alternateSpaceOneTab)
            guard self.check(self.pagingIsClear && self.controller.session.space == 1 && self.controller.session.activeID == self.alternateSpaceOneTab, "Selecting a tab did not cancel paging") else { return }
            self.after(0.8) {
                guard self.check(self.controller.session.space == 1 && self.controller.session.activeID == self.alternateSpaceOneTab && self.pagingIsClear && self.controller.activeWebView?.superview === self.controller.webHost, "Cancelled selection transition replaced the selected tab") else { return }
                self.testNewTabInterrupt()
            }
        }
    }

    private func testNewTabInterrupt() {
        let oldCount = controller.session.tabs.count
        beginInterruptibleChange {
            self.controller.newTab(nil)
            let newID = self.controller.session.activeID
            guard self.check(self.pagingIsClear && self.controller.session.space == 2 && self.controller.session.tabs.count == oldCount && self.controller.addressOverlay != nil, "New tab palette must cancel paging, retain the committed Space, and defer tab creation") else { return }
            self.after(0.8) {
                guard self.check(self.controller.session.space == 2 && self.controller.session.activeID == newID && self.pagingIsClear && self.controller.activeWebView?.superview === self.controller.webHost, "New-tab palette cancellation replaced committed content later") else { return }
                self.controller.dismissAddress()
                guard self.check(self.controller.session.tabs.count == oldCount, "Cancelling New Tab created a blank tab") else { return }
                self.testRapidSidebarToggles()
            }
        }
    }

    private var geometryDiagnostic: String {
        "visible=\(controller.session.sidebarVisible), requested=\(controller.session.sidebarWidth), displayed=\(controller.displayedWidth), animator=\(controller.animator.value), hidden=\(controller.sidebar.isHidden), sidebarFrame=\(controller.sidebar.frame), cardFrame=\(controller.card.frame), rootBounds=\(controller.root.bounds), windowFrame=\(window.frame), rootSuperview=\(String(describing: controller.root.superview))"
    }

    private func testRapidSidebarToggles() {
        controller.setSidebar(false)
        after(0.02) {
            self.controller.setSidebar(true)
            self.after(0.02) {
                self.controller.setSidebar(false)
                self.after(0.02) {
                    self.controller.setSidebar(true)
                    self.after(0.2) {
                        guard self.check(self.controller.session.sidebarVisible && abs(self.controller.displayedWidth - 228) < 0.001 && !self.controller.sidebar.isHidden && abs(self.controller.card.frame.minX - 236) < 0.001, "Rapid toggles did not finish at the visible width: \(self.geometryDiagnostic)") else { return }
                        self.controller.setSidebar(false)
                        self.after(0.2) {
                            guard self.check(!self.controller.session.sidebarVisible && abs(self.controller.displayedWidth) < 0.001 && self.controller.sidebar.isHidden, "Sidebar hide did not finish collapsed") else { return }
                            self.controller.setSidebar(true)
                            self.after(0.2) { self.testResizeCallbacks() }
                        }
                    }
                }
            }
        }
    }

    private func testResizeCallbacks() {
        controller.handle.onResize?(310, true)
        guard check(abs(controller.displayedWidth - 310) < 0.001 && controller.session.sidebarWidth == 310 && abs(controller.card.frame.minX - 318) < 0.001, "Resize callback did not synchronize session and layout") else { return }
        controller.handle.onCollapse?()
        after(0.2) {
            guard self.check(!self.controller.session.sidebarVisible && abs(self.controller.displayedWidth) < 0.001 && self.controller.session.sidebarWidth == 310, "Resize collapse did not retain the preferred width") else { return }
            self.controller.resetSidebar(nil)
            self.after(0.2) {
                guard self.check(self.controller.session.sidebarVisible && self.controller.session.sidebarWidth == 228 && abs(self.controller.displayedWidth - 228) < 0.001 && self.pagingIsClear, "Reset did not restore the recovered preferred width") else { return }
                self.testCollapsedToolbarGeometry()
            }
        }
    }

    @discardableResult private func scroll(_ x: CGFloat = 0, y: CGFloat = 0,
        phase: SpaceSwipeStateMachine.Phase, momentum: Bool = false, precise: Bool = true,
        inside: Bool = true, browserWindow: Bool = true) -> Bool {
        gestureTimestamp += 0.02
        return controller.routeSpaceScroll(deltaX: x, deltaY: y, phase: phase,
            isMomentum: momentum, timestamp: gestureTimestamp, isPrecise: precise,
            isInsideSidebar: inside, isFromBrowserWindow: browserWindow)
    }
    private func selectSpaceImmediately(_ space: Int) {
        controller.cancelPaging(); controller.session.changeSpace(space)
        controller.showActive(); controller.view.layoutSubtreeIfNeeded()
    }
    private func spaceButton(named name: String) -> NSButton? {
        controller.sidebar.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Switch to \(name) space"
        }
    }
    private func testCollapsedToolbarGeometry() {
        let savedWidth = controller.displayedWidth
        controller.displayedWidth = 81; controller.layoutBrowser()
        let before = controller.webHost.frame.minY
        controller.displayedWidth = 79; controller.layoutBrowser()
        let after = controller.webHost.frame.minY
        guard check(abs(after - before) < 1 && after > before,
                    "Crossing width 80 abruptly moved webpage content: \(before) → \(after)") else { return }
        controller.displayedWidth = 0; controller.layoutBrowser()
        guard check(abs(controller.webHost.frame.minY - 36) < 0.001 && !controller.topbar.isHidden,
                    "Fully collapsed sidebar did not expose the 36-point toolbar") else { return }
        controller.displayedWidth = savedWidth; controller.layoutBrowser()
        testIgnoredScrollRoutes()
    }
    private func testIgnoredScrollRoutes() {
        selectSpaceImmediately(0)
        let outsideBegin = scroll(phase: .began, inside: false)
        let entered = scroll(-90, phase: .changed, inside: true)
        let outsideEnd = scroll(phase: .ended, inside: true)
        guard check(!outsideBegin && !entered && !outsideEnd && pagingIsClear && controller.session.space == 0,
                    "A gesture beginning over webpage content was captured when the pointer entered the sidebar") else { return }
        let wheel = scroll(-120, phase: .none, precise: false)
        let anotherWindow = scroll(-120, phase: .began, browserWindow: false)
        guard check(!wheel && !anotherWindow && pagingIsClear,
                    "A nonprecise mouse wheel or another window changed sidebar paging") else { return }
        let changedOnly = scroll(-70, phase: .changed)
        guard check(changedOnly && controller.trackingSwipe && abs(controller.pagingOffset + 70) < 0.001,
                    "A changed-only precise stream beginning inside the sidebar was ignored") else { return }
        _ = scroll(phase: .cancelled)
        waitUntil("changed-only cancellation", condition: { self.pagingIsClear }) { self.testSidebarCapture() }
    }
    private func testSidebarCapture() {
        selectSpaceImmediately(0)
        _ = scroll(phase: .mayBegin)
        _ = scroll(phase: .began)
        let first = scroll(-32, phase: .changed)
        let outside = scroll(-38, phase: .changed, inside: false)
        guard check(first && outside && controller.trackingSwipe && abs(controller.pagingOffset + 70) < 0.001,
                    "A sidebar-owned drag stopped following the fingers after pointer exit") else { return }
        let ended = scroll(-100, phase: .ended, momentum: true, inside: false)
        guard check(ended && !controller.trackingSwipe,
                    "A physical finger-up overlapping momentum did not release sidebar capture") else { return }
        let tail = scroll(-180, phase: .none, momentum: true, inside: false)
        guard check(tail, "The captured sidebar gesture leaked its momentum tail to webpage content") else { return }
        waitUntil("captured drag commit", condition: { self.controller.session.space == 1 && self.pagingIsClear }) {
            guard self.check(self.controller.activeWebView?.superview === self.controller.webHost,
                             "A routed swipe committed the Space but failed to attach its webpage") else { return }
            self.testUnphasedRouting()
        }
    }
    private func testUnphasedRouting() {
        selectSpaceImmediately(0)
        let first = scroll(-35, phase: .none)
        let next = scroll(-35, phase: .none, inside: false)
        guard check(first && next && controller.trackingSwipe && abs(controller.pagingOffset + 70) < 0.001,
                    "Precise unphased trackpad deltas did not acquire and retain sidebar capture") else { return }
        after(0.04) {
            guard self.check(self.controller.session.space == 0 && self.controller.trackingSwipe,
                             "Unphased scrolling committed before the quiet period") else { return }
            self.waitUntil("unphased quiet-end commit", condition: {
                self.controller.session.space == 1 && self.pagingIsClear
            }) { self.testVerticalDuringSettling() }
        }
    }
    private func testVerticalDuringSettling() {
        selectSpaceImmediately(0)
        controller.changeSpace(1)
        if reduceMotion {
            skippedInterruptions += 1
            testRapidSpaceTargets()
            return
        }
        after(0.04) {
            guard self.check(self.controller.pagingAnimator.isRunning && self.controller.pagingOffset > 0,
                             "Expected the incoming sidebar to settle after the content committed") else { return }
            let offset = self.controller.pagingOffset
            let target = self.controller.pagingTarget
            let touch = self.scroll(phase: .mayBegin)
            let began = self.scroll(phase: .began)
            let vertical = self.scroll(0, y: 24, phase: .changed)
            guard self.check(!touch && !began && !vertical && self.controller.pagingAnimator.isRunning
                             && self.controller.pagingTarget == target && abs(self.controller.pagingOffset - offset) < 0.001,
                             "Touching or scrolling vertically reset an unrelated Space animation") else { return }
            _ = self.scroll(phase: .ended)
            self.waitUntil("settle after vertical gesture", condition: {
                self.controller.session.space == 1 && self.pagingIsClear
            }) { self.testRapidSpaceTargets() }
        }
    }
    private func testRapidSpaceTargets() {
        selectSpaceImmediately(0)
        controller.changeSpace(1)
        controller.changeSpace(2)
        controller.changeSpace(1)
        if reduceMotion { skippedInterruptions += 1 }
        waitUntil("latest direct Space request", condition: { self.controller.session.space == 1 && self.pagingIsClear }) {
            self.after(0.3) {
                guard self.check(self.controller.session.space == 1 && self.pagingIsClear,
                                 "Selecting 0→1, then 2, then 1 left a stale queued request for Space 2") else { return }
                self.testCommandSupersedesFinger(useButton: false)
            }
        }
    }
    private func testCommandSupersedesFinger(useButton: Bool) {
        selectSpaceImmediately(0)
        _ = scroll(phase: .began)
        _ = scroll(-34, phase: .changed)
        if useButton {
            guard let button = spaceButton(named: "Explore") else {
                finish(false, "Could not find the native Explore Space button by accessibility label"); return
            }
            button.performClick(nil)
        } else { controller.nextSpace(nil) }
        let target = useButton ? 2 : 1
        let commandedOffset = controller.pagingOffset
        let laterFinger = scroll(120, phase: .changed, inside: false)
        guard check(laterFinger && !controller.trackingSwipe && abs(controller.pagingOffset - commandedOffset) < 0.001,
                    "A lingering finger event competed with a \(useButton ? "button" : "keyboard") Space command") else { return }
        let ended = scroll(phase: .ended, inside: false)
        guard check(ended, "The superseded finger stream did not consume its physical end") else { return }
        waitUntil("commanded Space after finger stream", condition: {
            self.controller.session.space == target && self.pagingIsClear
        }) {
            guard self.check(self.controller.session.space == target,
                             "A stale finger completion overrode the requested Space") else { return }
            if useButton {
                self.testUnphasedCommandInterruption()
            } else { self.testCommandSupersedesFinger(useButton: true) }
        }
    }
    private func testUnphasedCommandInterruption() {
        selectSpaceImmediately(0)
        _ = scroll(-34, phase: .none)
        guard let button = spaceButton(named: "Explore") else {
            finish(false, "Could not find Explore for the unphased interruption regression"); return
        }
        button.performClick(nil)
        let offset = controller.pagingOffset
        let superseded = scroll(120, phase: .none, inside: false)
        guard check(superseded && !controller.trackingSwipe && abs(controller.pagingOffset - offset) < 0.001,
                    "Unphased scrolling competed with the native Space button command") else { return }
        // This driver never emits a physical end. Its quiet period must release
        // quarantine so the next genuine precise stream can acquire the sidebar.
        after(0.2) {
            self.waitUntil("unphased command settles", condition: {
                self.controller.session.space == 2 && self.pagingIsClear
            }) {
                let fresh = self.scroll(70, phase: .none)
                guard self.check(fresh && self.controller.trackingSwipe && abs(self.controller.pagingOffset - 70) < 0.001,
                                 "An unphased gesture interrupted by a button permanently disabled subsequent scrolling") else { return }
                self.waitUntil("fresh unphased gesture after quarantine", condition: {
                    self.controller.session.space == 1 && self.pagingIsClear
                }) { self.testRealSpaceButton() }
            }
        }
    }
    private func testRealSpaceButton() {
        guard let button = spaceButton(named: "Studio") else {
            finish(false, "Could not find the native Studio Space button by accessibility label"); return
        }
        button.performClick(nil)
        waitUntil("native Studio Space button", condition: { self.controller.session.space == 0 && self.pagingIsClear }) {
            guard self.check(button.accessibilityValue() as? String == "Selected",
                             "The native Space button action did not update its selected accessibility value") else { return }
            _ = self.scroll(phase: .began)
            let fresh = self.scroll(-70, phase: .changed)
            let ended = self.scroll(phase: .ended)
            guard self.check(fresh && ended,
                             "Ending a superseded gesture left subsequent sidebar swipes disabled") else { return }
            self.waitUntil("fresh swipe after commands", condition: { self.controller.session.space == 1 && self.pagingIsClear }) {
                self.testNativeEventAdapterGuards()
            }
        }
    }

    private func adapterEvent(_ x: CGFloat = 0, y: CGFloat = 0,
        phase: NSEvent.Phase, momentum: NSEvent.Phase = [], precise: Bool = true,
        at sidebarPoint: NSPoint, in eventWindow: NSWindow?) -> AdapterScrollEvent {
        gestureTimestamp += 0.02
        // NSEvent locations use the window's base coordinates. The real adapter
        // must convert this back into the flipped, potentially translated sidebar.
        let point = controller.sidebar.convert(sidebarPoint, to: nil)
        return AdapterScrollEvent(window: eventWindow, point: point, x: x, y: y,
            phase: phase, momentum: momentum, precise: precise, time: gestureTimestamp)
    }
    private func testNativeEventAdapterGuards() {
        selectSpaceImmediately(0)
        let inside = NSPoint(x: 60, y: 240)
        let coarse = adapterEvent(-100, phase: [], precise: false, at: inside, in: window)
        guard check(controller.handleSpaceScroll(coarse) === coarse && pagingIsClear,
                    "Native event adapter swallowed an ordinary mouse-wheel event") else { return }
        let nilWindow = adapterEvent(-100, phase: .began, at: inside, in: nil)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let foreign = adapterEvent(-100, phase: .began, at: inside, in: otherWindow)
        guard check(controller.handleSpaceScroll(nilWindow) === nilWindow
                    && controller.handleSpaceScroll(foreign) === foreign && pagingIsClear,
                    "Native event adapter captured an event without its browser window") else { return }
        let outside = NSPoint(x: controller.sidebar.bounds.maxX + 40, y: 240)
        let began = adapterEvent(phase: .began, at: outside, in: window)
        let changed = adapterEvent(-90, phase: .changed, at: inside, in: window)
        let ended = adapterEvent(phase: .ended, at: inside, in: window)
        guard check(controller.handleSpaceScroll(began) === began
                    && controller.handleSpaceScroll(changed) === changed
                    && controller.handleSpaceScroll(ended) === ended && pagingIsClear,
                    "Native event window coordinates let a webpage gesture enter the sidebar") else { return }
        testNativeEventAdapterRegion(0)
    }
    private func testNativeEventAdapterRegion(_ index: Int) {
        let regions = [("header", NSPoint(x: 120, y: 20)),
                       ("tab rows", NSPoint(x: 60, y: 240)),
                       ("bottom dock", NSPoint(x: 50, y: controller.sidebar.bounds.height - 20))]
        guard index < regions.count else { testNativeEventAdapterCancellation(); return }
        selectSpaceImmediately(0)
        let (name, point) = regions[index]
        let touch = adapterEvent(phase: .mayBegin, at: point, in: window)
        let began = adapterEvent(phase: .began, at: point, in: window)
        guard check(controller.handleSpaceScroll(touch) === touch
                    && controller.handleSpaceScroll(began) === began,
                    "Touch announcements over the \(name) acquired scrolling prematurely") else { return }
        let moved = adapterEvent(-70, phase: .changed, at: point, in: window)
        let stationary = adapterEvent(phase: .stationary, at: point, in: window)
        guard check(controller.handleSpaceScroll(moved) == nil
                    && controller.handleSpaceScroll(stationary) == nil
                    && controller.trackingSwipe && abs(controller.pagingOffset + 70) < 0.001,
                    "Native event decoding/flipped coordinates failed over the \(name)") else { return }
        // End takes precedence when AppKit supplies multiple phase bits; the
        // momentum announcement must not add its displacement to the gesture.
        let ended = adapterEvent(-90, phase: [.ended, .changed], momentum: .began,
                                 precise: false, at: point, in: window)
        let tail = adapterEvent(-150, phase: [], momentum: .changed, at: point, in: window)
        guard check(controller.handleSpaceScroll(ended) == nil
                    && controller.handleSpaceScroll(tail) == nil && !controller.trackingSwipe,
                    "Native ended/momentum decoding stranded or leaked the \(name) gesture") else { return }
        waitUntil("native event commit from \(name)", condition: {
            self.controller.session.space == 1 && self.pagingIsClear
        }) { self.testNativeEventAdapterRegion(index + 1) }
    }
    private func testNativeEventAdapterCancellation() {
        selectSpaceImmediately(0)
        let point = NSPoint(x: 60, y: 240)
        _ = controller.handleSpaceScroll(adapterEvent(phase: .began, at: point, in: window))
        _ = controller.handleSpaceScroll(adapterEvent(-70, phase: .changed, at: point, in: window))
        let cancelled = adapterEvent(phase: [.cancelled, .ended], at: point, in: window)
        guard check(controller.handleSpaceScroll(cancelled) == nil && !controller.trackingSwipe,
                    "Native cancellation did not take precedence over an ended flag") else { return }
        waitUntil("native event cancellation", condition: { self.pagingIsClear }) {
            guard self.check(self.controller.session.space == 0,
                             "A cancelled native event committed a Space") else { return }
            self.testNativeEventNoisyIntent()
        }
    }
    private func testNativeEventNoisyIntent() {
        selectSpaceImmediately(0)
        let point = NSPoint(x: 60, y: 240)
        _ = controller.handleSpaceScroll(adapterEvent(phase: .began, at: point, in: window))
        let diagonal = adapterEvent(-13, y: -12, phase: .changed, at: point, in: window)
        guard check(controller.handleSpaceScroll(diagonal) === diagonal,
                    "Ambiguous diagonal pickup was claimed before horizontal intent") else { return }
        let horizontal = adapterEvent(-52, phase: .changed, at: point, in: window)
        let ended = adapterEvent(phase: .ended, at: point, in: window)
        guard check(controller.handleSpaceScroll(horizontal) == nil
                    && controller.handleSpaceScroll(ended) == nil,
                    "A diagonal pickup permanently blocked the subsequent horizontal swipe") else { return }
        waitUntil("noisy-intent native event commit", condition: {
            self.controller.session.space == 1 && self.pagingIsClear
        }) {
            self.testVerticalTabList()
        }
    }

    private func descendantScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = descendantScroll(in: child) { return scroll }
        }
        return nil
    }
    private func testVerticalTabList() {
        selectSpaceImmediately(0)
        // Only local, ephemeral tab metadata is added. Inactive pages are not
        // loaded; enough rows are needed to test actual vertical overflow.
        controller.session.tabs.append(contentsOf: (1...36).map {
            BrowserTab(title: "Vertical fixture \($0)", address: "orbit://newtab", space: 0)
        })
        controller.refresh()
        for width: CGFloat in [164, 228, 500] {
            controller.session.sidebarWidth = Double(width)
            controller.displayedWidth = width
            controller.layoutBrowser()
            controller.view.layoutSubtreeIfNeeded()
            guard let scroll = descendantScroll(in: controller.sidebar), let document = scroll.documentView else {
                finish(false, "Missing native tab-list scroll view at width \(width)"); return
            }
            scroll.layoutSubtreeIfNeeded()
            let viewport = scroll.contentView.bounds
            let diagnostic = "sidebar=\(width), scroll=\(scroll.frame), viewport=\(viewport), document=\(document.frame)"
            guard check(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller
                        && scroll.horizontalScrollElasticity == .none,
                        "Tab-list scroll configuration permits sideways bounce or disables vertical scrolling: \(diagnostic)") else { return }
            guard check(viewport.width > 0 && abs(document.frame.width - viewport.width) < 0.5
                        && document.frame.height > viewport.height + 160,
                        "Overflowing tab list does not fit its viewport horizontally: \(diagnostic)") else { return }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let start = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
            scroll.reflectScrolledClipView(scroll.contentView)
            let moved = scroll.contentView.bounds.origin
            guard check(abs(start.y) < 0.001 && abs(moved.y - 160) < 0.5 && abs(moved.x) < 0.001,
                        "Native vertical scrolling failed or introduced horizontal movement: start=\(start), end=\(moved); \(diagnostic)") else { return }
        }
        guard let sourceScroll = descendantScroll(in: controller.sidebar) else {
            finish(false, "Missing source scroll view for Space round trip"); return
        }
        let sourceY = sourceScroll.contentView.bounds.origin.y
        controller.changeSpace(1)
        waitUntil("vertical-list departure", condition: {
            self.controller.session.space == 1 && self.pagingIsClear
        }) {
            guard self.check(self.descendantScroll(in: self.controller.sidebar) !== sourceScroll
                             && abs(sourceScroll.contentView.bounds.origin.y - sourceY) < 0.5,
                             "Leaving a Space reused its tab list for the destination or erased its vertical position") else { return }
            self.controller.changeSpace(0)
            self.waitUntil("vertical-list return", condition: {
                self.controller.session.space == 0 && self.pagingIsClear
            }) {
                guard self.check(self.descendantScroll(in: self.controller.sidebar) === sourceScroll
                                 && abs(sourceScroll.contentView.bounds.origin.y - sourceY) < 0.5
                                 && abs(sourceScroll.contentView.bounds.origin.x) < 0.001,
                                 "Returning to a Space replaced its tab list or lost the saved vertical position") else { return }
                self.testNativeScrollReceiverTakeover()
            }
        }
    }

    private func testNativeScrollReceiverTakeover() {
        selectSpaceImmediately(0)
        controller.session.sidebarWidth = 228; controller.displayedWidth = 228
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        guard let receiver = descendantScroll(in: controller.sidebar) else {
            finish(false, "Missing tab-list receiver for native tracking regression"); return
        }
        let point = NSPoint(x: 60, y: 240)
        let began = adapterEvent(-2, phase: .began, at: point, in: window)
        guard check(controller.handleSpaceScroll(began) === began && controller.trackingSwipe
                    && abs(controller.pagingOffset) < 0.001,
                    "Tiny native begin should remain undecided before receiver delivery") else { return }
        // This is the sequence observed in the physical trace: after an
        // unclaimed begin, later packets may bypass the local event monitor.
        // Each packet here is a local object; none is posted to an event queue.
        receiver.scrollWheel(with: began)
        guard check(controller.trackingSwipe && abs(controller.pagingOffset) < 0.001,
                    "Receiving the same undecided begin acquired or lost the gesture") else { return }
        let changed = adapterEvent(-4, phase: .changed, at: point, in: window)
        receiver.scrollWheel(with: changed)
        guard check(controller.trackingSwipe && abs(controller.pagingOffset + 6) < 0.001,
                    "Receiver-only changed packet was lost or counted the tiny begin twice: offset=\(controller.pagingOffset)") else { return }
        let monitoredAgain = controller.handleSpaceScroll(changed)
        controller.sidebar.scrollWheel(with: changed)
        guard check(monitoredAgain == nil && abs(controller.pagingOffset + 6) < 0.001,
                    "Monitor/receiver/responder bubbling applied one NSEvent more than once") else { return }
        receiver.scrollWheel(with: adapterEvent(-64, phase: .changed, at: point, in: window))
        guard check(abs(controller.pagingOffset + 70) < 0.001,
                    "Native receiver did not keep the full horizontal displacement: \(controller.pagingOffset)") else { return }
        let ended = adapterEvent(phase: .ended, at: point, in: window)
        receiver.scrollWheel(with: ended)
        controller.sidebar.scrollWheel(with: ended)
        guard check(!controller.trackingSwipe, "Receiver-only end failed to release native sidebar capture") else { return }
        waitUntil("receiver-only swipe commit", condition: {
            self.controller.session.space == 1 && self.pagingIsClear
        }) {
            guard self.check(self.controller.activeWebView?.superview === self.controller.webHost,
                             "Receiver-only swipe did not display the destination Space") else { return }
            self.testNativeVerticalAfterTakeover(receiver)
        }
    }
    private func testNativeVerticalAfterTakeover(_ original: NSScrollView) {
        // Reuse exactly the same list after takeover, so a stranded native
        // scroll state cannot be hidden by creating a new NSScrollView.
        selectSpaceImmediately(0)
        guard let receiver = descendantScroll(in: controller.sidebar), receiver === original else {
            finish(false, "Receiver takeover regression did not preserve the original native list"); return
        }
        receiver.contentView.scroll(to: NSPoint(x: 0, y: 160))
        receiver.reflectScrolledClipView(receiver.contentView)
        let point = NSPoint(x: 60, y: 240)
        let began = adapterEvent(0, y: -2, phase: .began, at: point, in: window)
        guard check(controller.handleSpaceScroll(began) === began,
                    "Native vertical begin was consumed after horizontal takeover") else { return }
        receiver.scrollWheel(with: began)
        let changed = adapterEvent(0, y: -34, phase: .changed, at: point, in: window)
        receiver.scrollWheel(with: changed)
        let ended = adapterEvent(phase: .ended, at: point, in: window)
        receiver.scrollWheel(with: ended)
        guard check(!controller.trackingSwipe && abs(controller.pagingOffset) < 0.001
                    && controller.session.space == 0,
                    "Vertical receiver stream acquired or stranded Space paging") else { return }
        // AppKit may apply native scrolling during its next layout/display turn.
        waitUntil("native vertical scroll after takeover", condition: {
            receiver.contentView.bounds.origin.y > 170
        }) {
            guard self.check(abs(receiver.contentView.bounds.origin.x) < 0.001,
                             "Vertical receiver scrolling introduced horizontal tab-list movement") else { return }
            let start = receiver.contentView.bounds.origin.y
            let wheel = self.adapterEvent(0, y: -24, phase: [], precise: false, at: point, in: self.window)
            guard self.check(self.controller.handleSpaceScroll(wheel) === wheel,
                             "Receiver regression swallowed a nonprecise mouse wheel") else { return }
            receiver.scrollWheel(with: wheel)
            self.waitUntil("native mouse-wheel forwarding", condition: {
                receiver.contentView.bounds.origin.y > start
            }) {
                guard self.check(self.pagingIsClear && self.controller.session.space == 0,
                                 "Native mouse-wheel forwarding changed Spaces") else { return }
                self.testSidebarResponderRegion(0)
            }
        }
    }
    private func testSidebarResponderRegion(_ index: Int) {
        let regions = [("header", NSPoint(x: 120, y: 20)),
                       ("bottom dock", NSPoint(x: 50, y: controller.sidebar.bounds.height - 20))]
        guard index < regions.count else {
            let note = skippedInterruptions == 0 ? "" : "; \(skippedInterruptions) timed interruption cases used preview cancellation or synchronous selection because Reduce Motion is enabled"
            finish(true, "\(checks) checks: immediate warm/cold Space content, retained live document state, rapid/reversed content commands, committed gesture release and preview cancellation, rendered Space change, address/selection/new-tab cancellation, rapid sidebar toggles, resize/collapse/reset, continuous toolbar geometry, capture/end/momentum, unphased fallback, interruption/queued commands, native Space buttons, NSEvent adapter phase/window/flipped-coordinate/noisy-intent coverage, vertical-only list widths/scrolling, retained scroll position across Spaces, native receiver takeover/deduplication, and vertical/mouse-wheel forwarding\(note)")
            return
        }
        selectSpaceImmediately(0)
        let (name, point) = regions[index]
        controller.sidebar.scrollWheel(with: adapterEvent(-2, phase: .began, at: point, in: window))
        controller.sidebar.scrollWheel(with: adapterEvent(-68, phase: .changed, at: point, in: window))
        guard check(controller.trackingSwipe && abs(controller.pagingOffset + 70) < 0.001,
                    "Direct \(name) responder delivery did not acquire the horizontal gesture") else { return }
        controller.sidebar.scrollWheel(with: adapterEvent(phase: .ended, at: point, in: window))
        waitUntil("direct \(name) responder commit", condition: {
            self.controller.session.space == 1 && self.pagingIsClear
        }) {
            guard self.check(self.controller.activeWebView?.superview === self.controller.webHost,
                             "Direct \(name) responder commit did not attach its destination page") else { return }
            self.testSidebarResponderRegion(index + 1)
        }
    }

    @discardableResult private func check(_ passed: Bool, _ failure: String) -> Bool {
        if !passed { finish(false, failure); return false }
        checks += 1; return true
    }
    private func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.completed else { return }; action()
        }
    }
    private func waitUntil(_ label: String, attempts: Int = 60, condition: @escaping () -> Bool, action: @escaping () -> Void) {
        guard !completed else { return }
        if condition() { action(); return }
        guard attempts > 0 else { finish(false, "Timed out waiting for \(label)"); return }
        after(0.1) { self.waitUntil(label, attempts: attempts - 1, condition: condition, action: action) }
    }
    private func finish(_ success: Bool, _ message: String) {
        guard !completed else { return }
        completed = true; timeout?.invalidate()
        controller?.cancelPaging(); controller?.animator.stop(); controller?.pictureInPicture.restore()
        controller?.saveWork?.cancel()
        print("\(success ? "PASS" : "FAIL"): Controller interactions — \(message)"); fflush(stdout)
        exit(success ? 0 : 1)
    }
}

/// An in-process event object, never posted. Overridden properties exercise the
/// production adapter and responder methods; a real backing scroll CGEvent lets
/// NSScrollView process its unconsumed vertical packets using native APIs.
private final class AdapterScrollEvent: NSEvent {
    private weak var sampleWindow: NSWindow?
    private let samplePoint: NSPoint
    private let sampleX: CGFloat
    private let sampleY: CGFloat
    private let samplePhase: NSEvent.Phase
    private let sampleMomentum: NSEvent.Phase
    private let samplePrecise: Bool
    private let sampleTime: TimeInterval
    private let backingEvent: NSEvent?

    init(window: NSWindow?, point: NSPoint, x: CGFloat, y: CGFloat,
         phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, time: TimeInterval) {
        sampleWindow = window; samplePoint = point; sampleX = x; sampleY = y
        samplePhase = phase; sampleMomentum = momentum; samplePrecise = precise; sampleTime = time
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                         wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0)
        let cgPhase: Int64
        if phase.contains(.cancelled) { cgPhase = 8 }
        else if phase.contains(.ended) { cgPhase = 4 }
        else if phase.contains(.began) { cgPhase = 1 }
        else if phase.contains(.mayBegin) { cgPhase = 128 }
        else if phase.contains(.changed) { cgPhase = 2 }
        else { cgPhase = 0 }
        let cgMomentum: Int64 = momentum.contains(.ended) ? 3 : momentum.contains(.began) ? 1 : momentum.isEmpty ? 0 : 2
        cg?.setIntegerValueField(.scrollWheelEventScrollPhase, value: cgPhase)
        cg?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: cgMomentum)
        cg?.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg?.timestamp = UInt64(max(0, time) * 1_000_000_000)
        backingEvent = cg.flatMap { NSEvent(cgEvent: $0) }
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Adapter fixture is not decoded") }
    override var cgEvent: CGEvent? { backingEvent?.cgEvent }
    override var eventRef: UnsafeRawPointer? { backingEvent?.eventRef }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { sampleWindow }
    override var windowNumber: Int { sampleWindow?.windowNumber ?? 0 }
    override var locationInWindow: NSPoint { samplePoint }
    override var scrollingDeltaX: CGFloat { sampleX }
    override var scrollingDeltaY: CGFloat { sampleY }
    override var deltaX: CGFloat { sampleX }
    override var deltaY: CGFloat { sampleY }
    override var phase: NSEvent.Phase { samplePhase }
    override var momentumPhase: NSEvent.Phase { sampleMomentum }
    override var hasPreciseScrollingDeltas: Bool { samplePrecise }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var timestamp: TimeInterval { sampleTime }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
