import AppKit
import WebKit

/// Controller-level native tests using bundled Home pages, real Space buttons,
/// and the same event-routing path as the local trackpad monitor.
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
        window.title = "Ark — local interaction smoke test"
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
            self.controller.changeSpace(1)
            self.waitUntil("space change completion", condition: {
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
    }

    private var localPageIsReady: Bool {
        guard let web = controller.activeWebView else { return false }
        return !web.isLoading && web.url?.isFileURL == true && web.url?.lastPathComponent == "Home.html" && controller.tabErrors[controller.session.activeID] == nil
    }
    private var pagingIsClear: Bool {
        !controller.pagingAnimator.isRunning && controller.pagingTarget == nil && abs(controller.pagingOffset) < 0.001 && !controller.sidebar.isPaging && !controller.trackingSwipe
    }

    private func beginInterruptibleChange(_ action: @escaping () -> Void) {
        if reduceMotion {
            // With Reduce Motion, real animation commits synchronously. Verify
            // the same cancellation entry points against pending preview state,
            // while reporting that timed-animation interruption was not tested.
            skippedInterruptions += 1
            controller.sidebar.beginPaging(tabs: controller.sidebarItems(for: 2), space: 2, direction: 1)
            controller.pagingTarget = 2; controller.pagingOffset = -40
            controller.sidebar.setPagingOffset(-40)
            action()
        } else {
            controller.changeSpace(2)
            after(0.025) {
                guard self.check(self.controller.session.space == 1 && self.controller.pagingAnimator.isRunning, "Expected an in-flight Space transition") else { return }
                action()
            }
        }
    }

    private func testAddressInterrupt() {
        beginInterruptibleChange {
            self.controller.openAddress(newTab: false, empty: true)
            guard self.check(self.pagingIsClear && self.controller.addressOverlay != nil && self.controller.session.space == 1, "Opening address did not cancel paging") else { return }
            self.after(0.8) {
                guard self.check(self.controller.session.space == 1 && self.controller.session.activeID == self.selectedSpaceOneTab && self.pagingIsClear, "Cancelled address transition committed later") else { return }
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
            guard self.check(self.pagingIsClear && self.controller.session.space == 1 && self.controller.session.tabs.count == oldCount && self.controller.addressOverlay != nil, "New tab palette must cancel paging without creating a tab") else { return }
            self.after(0.8) {
                guard self.check(self.controller.session.space == 1 && self.controller.session.activeID == newID && self.pagingIsClear && self.controller.activeWebView?.superview === self.controller.webHost, "Cancelled new-tab transition committed later") else { return }
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
            guard self.check(self.controller.pagingAnimator.isRunning && self.controller.pagingOffset < 0,
                             "Expected a settling Space before the vertical-touch regression") else { return }
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
                let note = self.skippedInterruptions == 0 ? "" : "; \(self.skippedInterruptions) timed interruption cases used preview cancellation or synchronous selection because Reduce Motion is enabled"
                self.finish(true, "\(self.checks) checks: rendered Space change, address/selection/new-tab cancellation, rapid sidebar toggles, resize/collapse/reset, continuous toolbar geometry, trackpad capture/end/momentum, unphased fallback, ignored webpage/wheel events, interruption/queued commands, and native Space buttons\(note)")
            }
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
