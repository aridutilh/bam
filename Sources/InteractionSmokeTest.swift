import AppKit
import WebKit

/// Controller-level native tests. Only bundled Home pages are loaded; gesture
/// recognition itself is covered separately by the pure SpaceSwipe tests.
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
        window.title = "Orbit — local interaction smoke test"
        window.contentViewController = controller
        // AppKit adopts the controller root view’s initial size (1×1 here).
        // Match App.swift by sizing the content after installing the controller.
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.layoutBrowser()
        timeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
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
                let note = self.skippedInterruptions == 0 ? "" : "; \(self.skippedInterruptions) timed interruption checks replaced with preview cancellation because Reduce Motion is enabled"
                self.finish(true, "\(self.checks) checks: rendered Space change, address/selection/new-tab cancellation, rapid sidebar toggles, resize/collapse/reset callbacks\(note)")
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
