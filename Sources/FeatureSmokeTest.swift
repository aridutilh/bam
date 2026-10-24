import AppKit
import WebKit

@MainActor final class FeatureSmokeTest {
    var controller: BrowserController!
    var window: NSWindow!
    var checks = 0
    enum Failure: Error { case assertion(String) }
    func start() {
        Task { @MainActor in
            do { try await run(); finish(true, "\(checks) checks: per-tab Peek, same-page promotion, Little Bam, cross-window Find, preview history, split focus/navigation, persisted groups, close/reopen, unsplit and focused-page copy/hard refresh") }
            catch { finish(false, String(describing: error)) }
        }
    }
    func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure.assertion(message) }; checks += 1 }
    func pause(_ seconds: Double = 0.08) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { checks += 1; return }; await pause() }
        throw Failure.assertion("Timed out: \(message)")
    }
    /// Establishes only the fixture's requested key-window precondition.
    /// Find routing is checked afterwards without repairing its result.
    func establishKeyWindow(_ target: NSWindow, label: String) async throws {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        target.orderFront(nil)
        // Unlike cooperative activate(), this setup request activates even
        // when a different application is frontmost. Still await actual state.
        NSApp.activate(ignoringOtherApps: true)
        do {
            try await wait("\(label): application active") { NSApp.isActive }
            target.makeKeyAndOrderFront(nil)
            try await wait("\(label): target key window") {
                NSApp.isActive && NSApp.keyWindow === target && target.isKeyWindow
            }
        } catch {
            let frontmost = NSWorkspace.shared.frontmostApplication
            throw Failure.assertion("Focus setup \(label) failed (\(error)): appActive=\(NSApp.isActive), appHidden=\(NSApp.isHidden), policy=\(NSApp.activationPolicy().rawValue), pid=\(ProcessInfo.processInfo.processIdentifier), frontmostPID=\(String(describing: frontmost?.processIdentifier)), frontmostBundle=\(frontmost?.bundleIdentifier ?? "nil"), targetNumber=\(target.windowNumber), keyNumber=\(String(describing: NSApp.keyWindow?.windowNumber)), targetKey=\(target.isKeyWindow), targetVisible=\(target.isVisible), targetMiniaturized=\(target.isMiniaturized), targetCanKey=\(target.canBecomeKey)")
        }
    }
    func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    func run() async throws {
        guard let raw = (ProcessInfo.processInfo.environment["BAM_TEST_URL"] ?? ProcessInfo.processInfo.environment["ARK_TEST_URL"] ?? ProcessInfo.processInfo.environment["ORBIT_TEST_URL"]), let url = URLInput.directURL(raw) else { throw Failure.assertion("Set BAM_TEST_URL (or ARK_TEST_URL / ORBIT_TEST_URL) to a local fixture") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Ark-feature-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let downloadManager = DownloadCoordinator(destinationChooser: { _, _, completion in completion(destination) })
        controller = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/orbit-unused-features.json"), ephemeral: true, downloadCoordinator: downloadManager)
        let first = BrowserTab(title: "First", address: url.absoluteString, space: 0)
        let second = BrowserTab(title: "Second", address: "orbit://newtab", space: 0)
        controller.session = BrowserSession(tabs: [first, second], activeID: first.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 720), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentViewController = controller; window.setContentSize(NSSize(width: 1150, height: 720))
        try await establishKeyWindow(window, label: "initial feature browser")
        let original = controller.activeWebView!
        try await wait("original fixture") { !original.isLoading && original.title == "Orbit Feature Fixture" }
        _ = try await js(original, "window.savedOriginal=41; true")
        var previewComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        previewComponents.queryItems = [URLQueryItem(name: "ark_preview_visit", value: "1")]
        let previewURL = previewComponents.url!
        controller.openPeek(previewURL)
        guard let peek = controller.peeks[first.id], let preview = peek.webView else { throw Failure.assertion("Peek created") }
        try await wait("peek fixture") { !preview.isLoading && preview.title == "Orbit Feature Fixture" }
        try await wait("Peek visit enters history") { self.controller.library.history.contains { $0.address == previewURL.absoluteString } }
        _ = try await js(preview, "window.savedPreview=42; document.querySelector('input').value='kept'; true")
        controller.zoomIn(nil)
        try check(preview.pageZoom > 1 && original.pageZoom == 1, "Peek commands target preview rather than parent")
        controller.findInPage(nil); controller.findBar.searchText = "alpha"
        try await wait("Find in Peek") { self.controller.findBar.matchFound == true }
        controller.findBar.hide()
        controller.select(second.id)
        try check(controller.peeks[first.id] === peek && preview.window == nil || preview.isHiddenOrHasHiddenAncestor, "Peek hides while retaining owner")
        controller.select(first.id)
        try check(controller.peeks[first.id] === peek && !preview.isHiddenOrHasHiddenAncestor, "Peek returns with owner")
        let splitURL = try await js(preview, "history.pushState(null,'','?ark_split_promoted=1'); location.href") as! String
        try await wait("split preview address updated") { preview.url?.absoluteString == splitURL }
        peek.openInSplitView()
        guard let group = controller.session.split(for: first.id), let split = controller.splitCoordinators[first.id] else { throw Failure.assertion("Peek promoted into split") }
        try check(controller.browsers[group.secondaryID] === preview && controller.browsers[first.id] === original, "Split owns the original two WKWebViews")
        try check((try await js(preview, "savedPreview===42 && document.querySelector('input').value==='kept'")) as? Bool == true, "Promotion preserves page and form state")
        try check(controller.peeks[first.id] == nil && controller.session.visibleTabs.count == 2, "Peek removed and split is one sidebar row")
        try check(controller.session.tabs.first(where: { $0.id == group.secondaryID })?.address == splitURL, "Split promotion persists the settled pushState URL")
        await pause()
        try check(controller.focusedTabID == group.secondaryID && controller.activeWebView === preview, "New split keeps final AppKit focus on the promoted pane")
        split.setFocusedSide(.left)
        try check(controller.activeWebView === original, "Left focus routes browser commands")
        controller.select(second.id); controller.select(first.id)
        try check(controller.browsers[group.secondaryID] === preview && preview.isDescendant(of: split.view), "Returning to split reuses both views")
        let data = try JSONEncoder().encode(controller.session)
        var restored = try JSONDecoder().decode(BrowserSession.self, from: data); restored.sanitize()
        try check(restored.split(for: first.id) == group && restored.visibleTabs.count == 2, "Split survives saved-session round trip")
        controller.unsplit(first.id)
        try check(controller.session.split(for: first.id) == nil && controller.session.visibleTabs.count == 3, "Unsplit restores both sidebar tabs")
        controller.select(group.secondaryID)
        let preservedAfterUnsplit = (try await js(preview, "savedPreview===42")) as? Bool == true
        try check(controller.activeWebView === preview && preservedAfterUnsplit, "Unsplit preserves live page")
        controller.openPeek(url)
        guard let littlePreview = controller.peeks[group.secondaryID], let littleWeb = littlePreview.webView else { throw Failure.assertion("Little preview") }
        try await wait("little fixture") { !littleWeb.isLoading && littleWeb.title == "Orbit Feature Fixture" }
        littlePreview.openInLittleOrbit()
        guard let little = controller.littleWindows.values.first else { throw Failure.assertion("Little window retained") }
        try check(little.webView === littleWeb && controller.peeks[group.secondaryID] == nil, "Peek transfers to Little Bam")
        var littleComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        littleComponents.queryItems = [URLQueryItem(name: "ark_little_visit", value: "1")]
        let littleURL = littleComponents.url!
        try check(little.open(url: littleURL), "Little Bam accepts its local visit fixture")
        try await wait("Little Bam visit finishes") { !littleWeb.isLoading && littleWeb.url == littleURL }
        try await wait("Little Bam visit enters history") { self.controller.library.history.contains { $0.address == littleURL.absoluteString } }
        _ = try await js(littleWeb, "window.littleSentinel=43; document.body.insertAdjacentHTML('beforeend','<p>OnlyInLittleArk</p>'); true")
        guard let littleWindow = little.window else { throw Failure.assertion("Little Bam has a native window") }
        try await establishKeyWindow(littleWindow, label: "Little Bam before Find")
        controller.findInPage(nil); controller.findBar.searchText = "OnlyInLittleArk"
        try await wait("Little Bam find match") { self.controller.findBar.matchFound == true }
        try await establishKeyWindow(window, label: "main browser before Find Next")
        controller.findNext(nil)
        try await wait("Find Next changes page and host") { self.controller.findBar.matchFound == false && self.controller.findBar.view.window === self.window }
        try await establishKeyWindow(littleWindow, label: "Little Bam before Find Previous")
        controller.findPrevious(nil)
        try await wait("Find Previous changes page and host") { self.controller.findBar.matchFound == true && self.controller.findBar.view.window === little.window }
        controller.findBar.hide()
        let promotedURL = try await js(littleWeb, "history.pushState(null,'','?ark_tab_promoted=1'); location.href") as! String
        try await wait("Little Bam address updated") { littleWeb.url?.absoluteString == promotedURL }
        little.promoteToOrbit()
        try check(controller.littleWindows.isEmpty && controller.activeWebView === littleWeb, "Little Bam promotes same view and cleans up window")
        try check(controller.session.active?.address == promotedURL, "Tab promotion persists the settled pushState URL")
        try check((try await js(littleWeb, "littleSentinel===43")) as? Bool == true, "Little promotion preserves script state")
        controller.splitWithNewPage(nil)
        guard let secondGroup = controller.session.split(for: controller.session.activeID) else { throw Failure.assertion("Menu split created") }
        let count = controller.session.tabs.count
        controller.close(secondGroup.primaryID)
        try check(controller.session.tabs.count == count-2 && controller.browsers[secondGroup.primaryID] == nil && controller.browsers[secondGroup.secondaryID] == nil, "Closing group removes both browser caches")
        controller.reopenTab(nil)
        try check(controller.session.tabs.count == count && controller.session.split(for: controller.session.activeID) != nil, "Reopen restores grouped tab pair")
        let reopened = controller.session.split(for: controller.session.activeID)!
        controller.closeSplitPane(reopened.primaryID)
        try check(controller.session.activeID == reopened.secondaryID && controller.session.split(for: reopened.secondaryID) == nil && controller.session.tabs.count == count-1, "Closing left pane preserves right as active tab")
        let beforePalette = controller.session.tabs.count
        controller.newTab(nil)
        try check(controller.session.tabs.count == beforePalette && controller.addressOverlay != nil, "New tab command defers allocation")
        controller.dismissAddress()
        try check(controller.session.tabs.count == beforePalette, "Escape leaves no empty tab")
        controller.newTab(nil); controller.addressField?.stringValue = url.absoluteString; controller.refreshPaletteResults(); controller.submitAddress(nil)
        try check(controller.session.tabs.count == beforePalette+1 && controller.addressOverlay == nil && controller.session.active?.address == url.absoluteString, "Submitting palette opens new tab exactly once")
        let target = BrowserTab(title: "Palette target", address: "orbit://newtab", space: 2)
        controller.session.tabs.append(target)
        let countBeforeSwitch = controller.session.tabs.count
        controller.newTab(nil); controller.addressField?.stringValue = "Palette target"; controller.refreshPaletteResults()
        controller.tabSearchResults?.moveSelection(delta: 1); controller.submitAddress(nil)
        try check(controller.session.activeID == target.id && controller.session.space == 2 && controller.session.tabs.count == countBeforeSwitch, "Palette switches across Spaces without creating a tab")
        controller.openPeek(url)
        guard let pendingPeek = controller.peeks[target.id], let pendingWeb = pendingPeek.webView else { throw Failure.assertion("Pending preview created") }
        pendingPeek.promoteToTab()
        try check(controller.activeWebView === pendingWeb && controller.session.active?.address == url.absoluteString, "Immediate promotion preserves requested URL")
        try await wait("immediately promoted page") { !pendingWeb.isLoading && pendingWeb.title == "Orbit Feature Fixture" }
        _ = try await js(pendingWeb, "var downloadLink=document.createElement('a'); downloadLink.href='/sample.bin'; downloadLink.download='sample.bin'; document.body.append(downloadLink); downloadLink.click(); true")
        try await wait("download completes through page navigation delegate") { downloadManager.snapshots.first?.status == .finished }
        try check((try Data(contentsOf: destination)) == Data("Orbit local download fixture".utf8), "Download delegate saves exact local payload")
        try check(controller.library.history.contains(where: { $0.address == url.absoluteString }), "Completed normal navigation enters history")
        try check(!controller.library.closedRecords.isEmpty, "Closed tabs remain in archive")
        try await runPageCommands()
    }
    func finish(_ success: Bool, _ detail: String) {
        controller?.prepareToClose()
        print("\(success ? "PASS" : "FAIL"): Features — \(detail)"); fflush(stdout); exit(success ? 0 : 1)
    }
}
