import AppKit
import WebKit

/// Separate process entry point: original local fixtures and disposable stores only.
@MainActor final class ExtensionRuntimeSmokeTest {
    private var watchdog: Timer?
    private var finished = false
    private var task: Task<Void, Never>?

    func start() {
        guard #available(macOS 15.4, *) else {
            print("SKIP: Extensions — macOS 15.4 or later is required")
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

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }
        finished = true; watchdog?.invalidate(); watchdog = nil
        print("\(success ? "PASS" : "FAIL"): Extensions — \(message)")
        fflush(stdout); exit(success ? 0 : 1)
    }
}
