import AppKit
import WebKit

/// Separate process entry point: original local fixtures and disposable stores only.
@MainActor final class ExtensionRuntimeSmokeTest {
    private var watchdog: Timer?
    private var finished = false
    private var task: Task<Void, Never>?
    /// Each focused selector reports under its own label, so a diagnostic can never read as a full Extensions pass.
    private var suiteName: String {
        let arguments = CommandLine.arguments
        if arguments.contains("--extension-site-access-only") { return "Extension site access diagnostic" }
        if arguments.contains("--extension-fetch-only") { return "Extension fetch diagnostic" }
        if arguments.contains("--extension-metadata-only") { return "Extension metadata diagnostic" }
        return "Extensions"
    }

    func start() {
        guard #available(macOS 15.4, *) else {
            print("SKIP: \(suiteName) — macOS 15.4 or later is required")
            fflush(stdout); exit(0)
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let environment = ProcessInfo.processInfo.environment
                guard let raw = environment["BAM_TEST_URL"] ?? environment["ARK_TEST_URL"] ?? environment["ORBIT_TEST_URL"],
                      let base = URL(string: raw), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
                      ["127.0.0.1", "localhost", "::1", "[::1]"].contains(base.host?.lowercased() ?? ""),
                      base.user == nil, base.password == nil else {
                    throw ExtensionSmokeTest.Failure(description: "Set BAM_TEST_URL to the isolated loopback fixture server")
                }
                guard let resources = Bundle.main.resourceURL else {
                    throw ExtensionSmokeTest.Failure(description: "The packaged extension fixture resource directory is missing")
                }
                let fixture = resources.appendingPathComponent("ExtensionFixture", isDirectory: true)
                guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("manifest.json").path) else {
                    throw ExtensionSmokeTest.Failure(description: "The packaged original ExtensionFixture/manifest.json is missing")
                }
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                components.path = base.deletingLastPathComponent().appendingPathComponent("extension-test.html").path
                components.query = nil; components.fragment = nil
                guard let page = components.url else {
                    throw ExtensionSmokeTest.Failure(description: "Could not construct the local extension test page URL")
                }
                if let index = CommandLine.arguments.firstIndex(of: "--extension-verified-id-phase2") {
                    // Measurement only: prints EXTENSION_VERIFIED_ID_PHASE2 and MEASUREMENT, never a PASS/FAIL Extensions
                    // line. Exit 0 complete, 2 incomplete, 3 refused. Modes: write (creates the run), read --run <dir>
                    // (after a real relaunch; cleans up), cleanup --run <dir> (for a run that stopped early).
                    let arguments = CommandLine.arguments
                    let mode = arguments.indices.contains(index + 1) ? ExtensionVerifiedIDPersistenceProbe.Mode(rawValue: arguments[index + 1]) : nil
                    let run = arguments.firstIndex(of: "--run").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil }
                    guard let mode else { print("MEASUREMENT refused: --extension-verified-id-phase2 needs write, read or cleanup"); fflush(stdout); exit(3) }
                    let code = await ExtensionVerifiedIDPersistenceProbe.run(mode: mode, runDirectory: run, pageURL: page)
                    fflush(stdout); exit(code)
                }
                if CommandLine.arguments.contains("--extension-verified-id-probe") {
                    // Measurement only, not a suite: prints EXTENSION_VERIFIED_ID_PROBE and MEASUREMENT, never a PASS/FAIL
                    // Extensions line. Exit 0 = complete measurement, 2 = incomplete. The runner watchdog stays last resort.
                    let probe = await ExtensionVerifiedIDProbe.run(pageURL: page)
                    fflush(stdout); exit(probe.complete ? 0 : 2)
                }
                if CommandLine.arguments.contains("--extension-favicon-probe") {
                    // Measurement only: complete negative results are not an Extensions suite pass.
                    // Its native deadline and cleanup precede the outer runner watchdog.
                    let probe = await ExtensionFaviconProbe.run(pageURL: page)
                    fflush(stdout); exit(probe.complete ? 0 : 2)
                }
                if CommandLine.arguments.contains("--extension-identity-probe") {
                    // Measurement only, not a suite: the probe owns its 45 s budget, output, cleanup and exit.
                    self.watchdog?.invalidate(); self.watchdog = nil
                    ExtensionIdentityProbe.start()
                    return
                }
                if CommandLine.arguments.contains("--extension-gesture-probe") {
                    // Measurement only, not a suite: the probe owns its 60 s budget, output, cleanup and exit.
                    self.watchdog?.invalidate(); self.watchdog = nil
                    ExtensionGestureProbe.start(pageURL: page)
                    return
                }
                if CommandLine.arguments.contains("--extension-focus-probe") {
                    // Measurement only: one BAM_FOCUS_CASE per run; this probe owns its budget and cleanup.
                    self.watchdog?.invalidate(); self.watchdog = nil
                    ExtensionFocusProbe.start(pageURL: page)
                    return
                }
                // A separately labelled diagnostic; the default full run still includes this fixture.
                if CommandLine.arguments.contains("--extension-site-access-only") {
                    let checks = try await ExtensionSiteAccessSmokeTest.run(pageURL: page)
                    self.finish(true, "\(checks) (site access only; not a full extension run)")
                    return
                }
                // Separately labelled diagnostics, each in a fresh ephemeral controller and extension host; the default
                // full run still includes both fixtures (inside BrowserExtensionSmokeTest).
                if CommandLine.arguments.contains("--extension-fetch-only") {
                    // A brand-new, otherwise empty profile, so the never-granted control is not confounded by other
                    // extensions. Its premises are asserted and the withdrawal stages are measurements: this is a
                    // diagnostic, not security acceptance (the strict withheld-fetch assertion stays in the full run).
                    let checks = try await Self.withFreshHost { controller, host in
                        guard let profile = controller.session.createProfile(name: "Fetch diagnostic"),
                              controller.session.createSpace(name: "Fetch diagnostic", symbol: "briefcase", colorIndex: 1, profileID: profile) != nil else {
                            throw ExtensionSmokeTest.Failure(description: "Could not create the fetch diagnostic profile")
                        }
                        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: profile)
                        host.configure(config, profileID: profile)
                        return try await ExtensionFetchAccessProbe.run(controller: controller, host: host, profile: profile, pageURL: page)
                    }
                    self.finish(true, "\(checks) (fetch diagnostic only: premises asserted, withdrawal stages measured; not security acceptance or a full extension run)")
                    return
                }
                if CommandLine.arguments.contains("--extension-metadata-only") {
                    let checks = try await Self.withFreshHost { controller, host in
                        try await ExtensionTabMetadataSmokeTest.run(controller: controller, host: host, pageURL: page)
                    }
                    self.finish(true, "\(checks) (tab metadata only; not a full extension run)")
                    return
                }
                // Diagnostic modifier: `--extension-test --extension-dnr-only` runs only the
                // declarativeNetRequest suite. The full run (no modifier) always includes it.
                if CommandLine.arguments.contains("--extension-dnr-only") {
                    let dnrChecks = try await ExtensionDeclarativeNetRequestSmokeTest.run(pageURL: page)
                    self.finish(true, "\(dnrChecks) (declarativeNetRequest only; not a full extension run)")
                    return
                }
                let isolatedChecks = try await ExtensionSmokeTest.run(fixtureURL: fixture, pageURL: page)
                let frameChecks = try await ExtensionFrameMessagingSmokeTest.runIntegrated(fixtureURL: fixture, pageURL: page)
                let integratedChecks = try await BrowserExtensionSmokeTest.run(fixtureURL: fixture, pageURL: page)
                let workerChecks = try await ExtensionWorkerSmokeTest.run(pageURL: page)
                let dnrChecks = try await ExtensionDeclarativeNetRequestSmokeTest.run(pageURL: page)
                let safariChecks = try await SafariExtensionSmokeTest.run(pageURL: page)
                let bridgeChecks = try await ExtensionBridgeCapabilityProbe.run()
                let checks = isolatedChecks + frameChecks + integratedChecks + workerChecks + dnrChecks + safariChecks + bridgeChecks
                self.finish(true, "\(checks)")
            } catch { self.finish(false, String(describing: error)) }
        }
    }

    /// A fresh ephemeral browser with a window and its extension host, set up like the integrated fixture, torn down on
    /// every exit. Nothing is persisted.
    @available(macOS 15.4, *)
    private static func withFreshHost<T>(_ body: (BrowserController, BrowserExtensions) async throws -> T) async throws -> T {
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-extension-diagnostic-\(UUID().uuidString).json"), ephemeral: true)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 650))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        defer { controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close() }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: controller.session.currentProfileID)
        host.configure(config, profileID: controller.session.currentProfileID)
        return try await body(controller, host)
    }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }
        finished = true; watchdog?.invalidate(); watchdog = nil
        print("\(success ? "PASS" : "FAIL"): \(suiteName) — \(message)")
        fflush(stdout); exit(success ? 0 : 1)
    }
}
