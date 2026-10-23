import AppKit
import WebKit

/// Controller-level native tests using bundled Home pages, real Space buttons,
/// and local NSEvent fixtures passed through the actual scroll-event adapter.
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
                let note = self.skippedInterruptions == 0 ? "" : "; \(self.skippedInterruptions) timed interruption cases used preview cancellation or synchronous selection because Reduce Motion is enabled"
                self.finish(true, "\(self.checks) checks: rendered Space change, address/selection/new-tab cancellation, rapid sidebar toggles, resize/collapse/reset, continuous toolbar geometry, capture/end/momentum, unphased fallback, interruption/queued commands, native Space buttons, NSEvent adapter phase/window/flipped-coordinate/noisy-intent coverage, vertical-only list widths/scrolling, and retained scroll position across Spaces\(note)")
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

/// An in-process event object, never dispatched or posted. Overridden properties
/// exercise the production NSEvent adapter without synthesizing system input.
private final class AdapterScrollEvent: NSEvent {
    private weak var sampleWindow: NSWindow?
    private let samplePoint: NSPoint
    private let sampleX: CGFloat
    private let sampleY: CGFloat
    private let samplePhase: NSEvent.Phase
    private let sampleMomentum: NSEvent.Phase
    private let samplePrecise: Bool
    private let sampleTime: TimeInterval

    init(window: NSWindow?, point: NSPoint, x: CGFloat, y: CGFloat,
         phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, time: TimeInterval) {
        sampleWindow = window; samplePoint = point; sampleX = x; sampleY = y
        samplePhase = phase; sampleMomentum = momentum; samplePrecise = precise; sampleTime = time
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Adapter fixture is not decoded") }
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
