import AppKit
import WebKit

/// Uses an isolated data store and loopback pages. No system pressure is created.
@MainActor final class TabResourceSmokeTest {
    var controller: BrowserController!
    var window: NSWindow!
    var checks = 0
    enum Failure: Error { case assertion(String) }
    func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure.assertion(message) }; checks += 1 }
    func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { checks += 1; return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw Failure.assertion("Timeout: \(message)")
    }
    func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    func start() {
        Task { @MainActor in
            do { try await run(); finish(true, "\(checks) checks: static-page sleep, protections, pressure cancellation, current URL/scroll resume and pending-save quit flush") }
            catch { finish(false, String(describing: error)) }
        }
    }
    func run() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"], let base = URL(string: raw)?.deletingLastPathComponent() else { throw Failure.assertion("Missing local fixture URL") }
        let staticURL = base.appendingPathComponent("sleep-static.html").absoluteString
        let tabs = (0..<8).map { i in BrowserTab(title: "Resource \(i)", address: i == 1 ? base.appendingPathComponent("sleep-form.html").absoluteString : i == 2 ? base.appendingPathComponent("sleep-script.html").absoluteString : staticURL + "?page=\(i)", space: 0, pinned: i == 3) }
        controller = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/bam-resource-unused.json"), ephemeral: true)
        controller.automaticallyShowsVideo = false
        controller.session = BrowserSession(tabs: tabs, activeID: tabs[0].id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = controller; window.makeKeyAndOrderFront(nil)
        for tab in tabs {
            controller.select(tab.id)
            try await wait("page loaded") { self.controller.browsers[tab.id]?.isLoading == false && self.controller.browsers[tab.id]?.url?.absoluteString == tab.address && !self.controller.pendingLoads.contains(tab.id) }
        }
        // Bundled pages are ineligible and should not create a separate probe
        // world. The same view must gain its document-start tracker on HTTP navigation.
        let homeID = controller.session.add()
        controller.select(homeID)
        let home = controller.browsers[homeID]!
        try await wait("untracked bundled page") { !home.isLoading && !self.controller.pendingLoads.contains(homeID) }
        try check(!home.configuration.userContentController.userScripts.contains { $0.source == TabActivityProbe.trackerSource }, "Bundled page installed an unnecessary tracker")
        home.load(URLRequest(url: URL(string: staticURL + "?from-home")!)) // exercises policy-only installation
        try await wait("home to HTTP") { !home.isLoading && !self.controller.pendingLoads.contains(homeID) && home.url?.absoluteString == staticURL + "?from-home" }
        let promoted = await controller.tabActivityProbe.inspect(web: home, expectedURL: staticURL + "?from-home")
        try check(promoted != nil && promoted?.evidence.reasons.contains("navigation-history") == true, "HTTP navigation from Home missed tracking or lost history protection")
        controller.close(homeID); controller.select(tabs[7].id)
        let id = tabs[0].id
        let original = controller.browsers[id]!
        _ = try await js(original, "window.scrollTo(0, 900); true")
        let history = controller.browsers[tabs[4].id]!
        _ = try await js(history, "location.hash='retained-history'; true")
        try await wait("history protection") { history.canGoBack }
        let now = ProcessInfo.processInfo.systemUptime
        for (i, tab) in tabs.enumerated() { controller.tabLastUsed[tab.id] = now - 900 + Double(i) }
        try check(await controller.sleepEligibleTabs(pressure: { .normal }) == 0, "Normal pressure slept a tab")
        controller.keepAwakeHosts.insert("127.0.0.1")
        try check(await controller.sleepEligibleTabs(pressure: { .critical }) == 0, "Keep-awake site was slept")
        controller.keepAwakeHosts.remove("127.0.0.1")
        guard let safe = await controller.tabActivityProbe.inspect(web: original, expectedURL: tabs[0].address) else { throw Failure.assertion("No static-page probe") }
        try check(safe.evidence.isSafeToSleep, "Static page falsely unsafe: \(safe.evidence.reasons)")
        try check(abs(safe.scrollY - 900) < 2, "Probe lost scroll position")
        let form = await controller.tabActivityProbe.inspect(web: controller.browsers[tabs[1].id]!, expectedURL: tabs[1].address)
        let script = await controller.tabActivityProbe.inspect(web: controller.browsers[tabs[2].id]!, expectedURL: tabs[2].address)
        try check(form?.evidence.isSafeToSleep == false, "Form page eligible")
        try check(script?.evidence.isSafeToSleep == false, "Script page eligible")
        var pressure = TabResourcePolicy.Pressure.critical
        let cancel = Task { @MainActor in pressure = .normal }
        try check(await controller.sleepEligibleTabs(pressure: { pressure }) == 0, "Pressure recovery did not cancel release")
        await cancel.value
        try check(controller.browsers[id] === original, "Cancelled sleep replaced page")
        let count = await controller.sleepEligibleTabs(pressure: { .critical })
        try check(count == 1, "Expected exactly one eligible static page, got \(count)")
        try check(controller.browsers[id] == nil && controller.session.tabs.first { $0.id == id }?.isSleeping == true, "Sleep did not release view / preserve row")
        try check(controller.session.tabs.count == 8 && controller.session.activeID == tabs[7].id, "Sleep changed tab list or selection")
        try check(controller.browsers.count == 7, "Protected page released")
        let saved = controller.session.tabs.first { $0.id == id }!.sleepState!
        try check(saved.address == tabs[0].address && abs(saved.scrollY - 900) < 2, "Sleep did not persist current address/scroll")
        controller.select(id)
        let resumed = controller.browsers[id]!
        try check(resumed !== original, "Waking reused supposedly released renderer")
        try await wait("wake load") { !resumed.isLoading && resumed.url?.absoluteString == tabs[0].address && self.controller.sleepRestores[id] == nil }
        let restoredY = try await js(resumed, "scrollY") as? Double ?? -1
        try check(abs(restoredY - 900) < 2, "Wake lost scroll position: \(restoredY)")
        try check(controller.session.activeID == id && controller.session.active?.isSleeping == false, "Wake retained sleeping marker")
        // A late navigation cannot consume the prior sleep's scroll restore.
        controller.sleepRestores[id] = saved
        controller.navigate(staticURL + "?new-navigation")
        try check(controller.sleepRestores[id] == nil, "Explicit navigation retained stale scroll restore")
        let postID = tabs[2].id, post = controller.browsers[tabs[2].id]!
        controller.nonGetDocuments.insert(postID)
        controller.pendingNonGetDocuments[postID] = false
        controller.showError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), web: post)
        try check(controller.nonGetDocuments.contains(postID) && controller.pendingNonGetDocuments[postID] == nil, "Failed GET erased POST document protection")
        controller.webViewWebContentProcessDidTerminate(post)
        try check(controller.browsers[postID] === post && controller.tabErrors[postID] != nil, "Terminated POST response was automatically reloaded or slept")
        controller.pendingNonGetDocuments[postID] = false
        controller.webView(post, didCommit: nil)
        try check(!controller.nonGetDocuments.contains(postID), "Committed GET did not update document classification")
        try await verifySessionFlush()
    }
    func verifySessionFlush() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bam-flush-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writer = SessionWriter(url: dir.appendingPathComponent("session.json")) { snapshot, url in
            started.signal(); _ = release.wait(timeout: .now() + 3); try SessionFile.save(snapshot, to: url)
        }
        controller.privateMode = false; controller.sessionWriter = writer
        defer { controller.privateMode = true; controller.sessionWriter = nil }
        controller.save()
        try await wait("writer started and blocked") { started.wait(timeout: .now()) == .success }
        let flush = Task { @MainActor in await self.controller.flushSessionForTermination(timeout: 4) }
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.session.tabs[0].title = "Latest debounced title"
        controller.scheduleSave()
        release.signal(); release.signal(); release.signal()
        try check(await flush.value, "Quit flush did not finish")
        try check(SessionFile.load(dir.appendingPathComponent("session.json")).tabs[0].title == "Latest debounced title", "Quit lost edit made while writer was busy")
    }
    func finish(_ success: Bool, _ message: String) {
        print("\(success ? "PASS: Tab resources — " : "FAIL: Tab resources — ")\(message)")
        controller?.prepareToClose(); window?.orderOut(nil)
        fflush(stdout); exit(success ? 0 : 1)
    }
}
