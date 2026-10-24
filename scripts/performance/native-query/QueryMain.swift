import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor final class QueryDelegate: NSObject, NSApplicationDelegate {
    struct Failure: Error, CustomStringConvertible { let description: String }
    var watchdog: Timer?
    var controller: BrowserController?
    var window: NSWindow?
    var finished = false
    var checks = 0
    var rows: [[String: Any]] = []
    var queryEvents: [[String: Any]] = []
    var output: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        watchdog = Timer.scheduledTimer(withTimeInterval: 360, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(error: "Overall 360-second watchdog expired") }
        }
        Task { @MainActor in
            do { try await run(); finish(error: nil) }
            catch { finish(error: String(describing: error)) }
        }
    }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }; checks += 1
    }
    func wait(_ message: String, timeout: TimeInterval = 15, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw Failure(description: message)
    }
    func expected(_ controller: BrowserController, profile: UUID) -> [[String: Any]] {
        controller.session.tabs.filter { controller.session.profileID(for: $0) == profile }.enumerated().map { index, tab in
            ["index": index, "title": tab.displayTitle, "url": tab.address,
             "active": controller.session.currentProfileID == profile && controller.focusedTabID == tab.id,
             "pinned": tab.isSaved]
        }
    }
    func query(_ web: WKWebView, controller: BrowserController, profile: UUID,
               activeOnly: Bool = false, includeRows: Bool = false, phase: String = "correctness") async throws -> [String: Any] {
        let attempt = queryEvents.count
        queryEvents.append(["attempt": attempt, "phase": phase, "expected_profile_count": expected(controller, profile: profile).count, "status": "started"])
        try write(error: nil)
        let result = try await web.callAsyncJavaScript(
            "return await window.bamQuery(expected, activeOnly, includeRows)",
            arguments: ["expected": expected(controller, profile: profile), "activeOnly": activeOnly, "includeRows": includeRows],
            in: nil, contentWorld: .page)
        guard let text = result as? String, let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = result["errors"] as? [String], let elapsed = result["elapsed_ms"] as? Double else {
            throw Failure(description: "Owned extension query returned malformed data")
        }
        queryEvents[attempt]["status"] = "completed"
        queryEvents[attempt]["result"] = result
        try write(error: nil)
        try require(errors.isEmpty, "Query correctness failed: \(errors)")
        try require(elapsed.isFinite && elapsed >= 0, "Invalid query timer")
        return result
    }
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["BAM_QUERY_OUTPUT"], let resource = Bundle.main.resourceURL else {
            throw Failure(description: "BAM_QUERY_OUTPUT and a packaged fixture are required")
        }
        output = URL(fileURLWithPath: destination)
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-query-\(UUID()).json"), ephemeral: true)
        self.controller = controller
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false; controller.automaticTabSleeping = false
        let profile = controller.session.currentProfileID, space = controller.session.space
        guard let foreign = controller.session.createProfile(name: "Query isolation sentinel"),
              let foreignSpace = controller.session.createSpace(name: "Foreign", symbol: "briefcase", colorIndex: 1, profileID: foreign) else {
            throw Failure(description: "Could not create disposable foreign profile")
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.window = window; window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700)); controller.view.layoutSubtreeIfNeeded()
        try require(controller.view.bounds.width >= 990 && controller.view.bounds.height >= 690, "Native controller did not receive the requested content bounds")
        window.title = "Bam private extension query fixture"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(config, profileID: profile)
        try require(!config.websiteDataStore.isPersistent && config.webExtensionController?.configuration.isPersistent == false, "Fixture store or extension controller is persistent")
        let id = try await host.importPackage(at: resource.appendingPathComponent("QueryFixture"), profileID: profile)
        guard let context = host.context(for: id), context.hasPermission(.tabs),
              let benchID = controller.openProfileTab(context.baseURL.appendingPathComponent("bench.html"), profileID: profile, active: true),
              let web = controller.browsers[benchID] else { throw Failure(description: "Owned query page did not open") }
        try await wait("Owned extension script did not initialize") { (try? await web.evaluateJavaScript("window.bamQueryReady === true")) as? Bool == true }
        guard let spareID = controller.openProfileTab(context.baseURL.appendingPathComponent("spare.html"), profileID: profile, active: false),
              let spare = controller.browsers[spareID] else { throw Failure(description: "Owned spare page did not open") }
        try await wait("Spare extension page did not initialize") { spare.title == "Bam original spare fixture" && !spare.isLoading }
        controller.select(benchID); window.makeFirstResponder(web)
        window.title = "Bam Query " + (environment["BAM_QUERY_LABEL"] ?? "pilot") + " — " + (environment["BAM_QUERY_BLOCK"] ?? "pilot")
        print("WAITING: query foreground gate, PID \(ProcessInfo.processInfo.processIdentifier), window \(window.title), 45 seconds")
        fflush(stdout)
        try await wait("Benchmark app/window/page did not become active, key, visible and unoccluded", timeout: 45) {
            guard NSApp.isActive, window.isKeyWindow, window.isVisible, window.occlusionState.contains(.visible) else { return false }
            return (try? await web.evaluateJavaScript("document.hasFocus() && document.visibilityState === 'visible'")) as? Bool == true
        }
        try require(web.window === window && web.bounds.width > 400 && web.bounds.height > 300, "Owned page has invalid native geometry")
        let bench = controller.session.tabs.first { $0.id == benchID }!, other = controller.session.tabs.first { $0.id == spareID }!
        let foreignTabs = (0..<3).map { BrowserTab(title: "Foreign sentinel \($0)", address: "orbit://newtab?foreign=\($0)", space: foreignSpace) }
        for count in [100, 500, 1000] {
            let metadata = (0..<(count - 2)).map { index in
                BrowserTab(title: "Metadata tab \(index)", address: context.baseURL.appendingPathComponent("unloaded-\(index).html").absoluteString, space: space)
            }
            controller.session.tabs = metadata + [other, bench] + foreignTabs
            controller.session.select(benchID)
            controller.refresh(); host.reconcile()
            // Discard setup/KVO/notification work before timing a real query.
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(controller.browsers.count == 2 && controller.browsers[benchID] === web && controller.browsers[spareID] === spare,
                        "Metadata setup materialized or replaced a renderer")
            try require(controller.session.tabs.filter { controller.session.profileID(for: $0) == profile }.count == count, "Wrong profile-local metadata count")
            let first = try await query(web, controller: controller, profile: profile, includeRows: true, phase: "first_after_setup")
            var samples: [[String: Any]] = []
            for _ in 0..<5 {
                try require(NSApp.isActive && window.isKeyWindow && window.isVisible && window.occlusionState.contains(.visible), "Timed query lost native foreground")
                let sample = try await query(web, controller: controller, profile: profile, phase: "steady")
                try require(sample["focused"] as? Bool == true && sample["visibility"] as? String == "visible" && sample["foreground_epoch_changed"] as? Bool == false, "Timed query lost foreground")
                samples.append(sample)
            }
            // Actual native selection; both owned pages already exist, so no extra view or network is created.
            controller.select(spareID); host.reconcile()
            let active = try await query(web, controller: controller, profile: profile, activeOnly: true)
            controller.select(benchID); host.reconcile()
            try await Task.sleep(nanoseconds: 200_000_000)
            controller.extensionRefreshWork?.cancel(); controller.extensionRefreshWork = nil
            // Exercise live profile authority before any reconciliation: only model mutation, then query.
            // Cancel only the already-queued notification refresh above. Keep existing ordered IDs;
            // filtering must reject a now-foreign member before the next explicit reconciliation.
            let movedID = metadata[0].id
            let movedIndex = controller.session.tabs.firstIndex { $0.id == movedID }!
            controller.session.tabs[movedIndex].space = foreignSpace
            let moved = try await query(web, controller: controller, profile: profile)
            try require(moved["count"] as? Int == count - 1, "Profile move leaked before reconcile")
            controller.session.tabs[movedIndex].space = space
            host.reconcile()
            // Stale title/order changes are also checked against the current session after normal publication.
            controller.session.tabs[movedIndex].title = "Retitled after query"
            controller.session.tabs.swapAt(0, 1)
            host.reconcile()
            let reordered = try await query(web, controller: controller, profile: profile)
            try require(controller.browsers.count == 2, "Queries materialized metadata renderers")
            try require(!web.configuration.websiteDataStore.isPersistent && context.isLoaded, "Query fixture lost private ownership")
            rows.append(["profile_listed_tabs": count, "total_listed_tabs_including_foreign": count + 3,
                         "loaded_webviews": controller.browsers.count, "first_query_after_setup": first,
                         "steady_queries": samples, "active_query_after_native_selection": active,
                         "query_after_profile_move_before_reconcile": moved, "query_after_title_and_order_change": reordered])
            // Native output is outside every timed promise; retain each completed stage even on later failure.
            try write(error: nil)
        }
        try require(!FileManager.default.fileExists(atPath: controller.sessionURL.path), "Ephemeral benchmark wrote a session file")
    }
    func write(error: String?) throws {
        guard let output else { return }
        let result: [String: Any] = ["harness": "original-extension-query-v1", "candidate": ProcessInfo.processInfo.environment["BAM_QUERY_LABEL"] ?? "unspecified",
            "block": ProcessInfo.processInfo.environment["BAM_QUERY_BLOCK"] ?? "pilot", "checks": checks, "stages": rows, "query_events": queryEvents,
            "error": error as Any? ?? NSNull(), "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Original extension browser.tabs.query promise completion in an actual BrowserController; private store, one native window, exactly two owned extension WKWebViews, unloaded metadata and three foreign-profile sentinels. Steady samples exclude setup, native dispatch, result validation/serialization and native retrieval. No external network or vendor extension."]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: output, options: .atomic)
    }
    func finish(error: String?) {
        guard !finished else { return }; finished = true
        watchdog?.invalidate(); watchdog = nil
        var failure = error
        do { try write(error: error) } catch { failure = "Could not save query evidence: \(error)" }
        controller?.prepareToClose(persistSession: false); window?.orderOut(nil); window?.close()
        print("\(failure == nil ? "PASS" : "FAIL"): actual extension query — \(checks) checks\(failure.map { ": " + $0 } ?? "")")
        fflush(stdout); exit(failure == nil ? 0 : 1)
    }
}
@main enum QueryMain {
    @MainActor static func main() {
        guard #available(macOS 15.4, *) else { print("SKIP: macOS 15.4 required"); exit(0) }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = QueryDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
