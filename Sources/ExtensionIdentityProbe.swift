import AppKit
import WebKit

/// Measurement fixture, not a suite: what does an extension see as `chrome.runtime.id` in Bam, and can a
/// page or the prepared worker observe a fixture-only alias, either through an own getter on the native
/// runtime object or through a global facade that keeps native receivers? Also measures native getURL,
/// property descriptors, normal native calls, self-targeted messaging (no ID, native UUID, alias) and sender
/// IDs. Content scripts are reported as pending, not measured.
///
/// Opt-in (`--extension-test --extension-identity-probe`), canonical Bam Preview only. An original MV3
/// package in a run-owned folder; a private, disposable extension host; nonpersistent website data. Nothing
/// changes `uniqueIdentifier`, `baseURL`, stores, ownership gates or any product API; every override is made
/// and restored inside the fixture's own contexts, and all of them are disposed. Output is evidence, not a
/// compatibility claim. Everything, cleanup included, fits the 45 s budget.
@available(macOS 15.4, *)
@MainActor final class ExtensionIdentityProbe {
    private static var current: ExtensionIdentityProbe?
    typealias Rules = ExtensionIdentityProbeRules

    static func start() {
        let probe = ExtensionIdentityProbe()
        current = probe
        probe.begin()
    }

    static func writePackage(to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: Rules.manifest(), options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data(Rules.workerScript.utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data(Rules.pageHTML.utf8).write(to: folder.appendingPathComponent(Rules.pagePath))
        try Data(Rules.pageScript(alias: Rules.alias).utf8).write(to: folder.appendingPathComponent("identity.js"))
    }

    private var started = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var observations: [String: Any] = [:]
    private var runDirectory: URL?
    private var host: BrowserExtensions?
    private var extensionID: UUID?
    private var window: NSWindow?
    private var page: WKWebView?
    private var reviews: [[String: Any]] = []

    private func begin() {
        started = ProcessInfo.processInfo.systemUptime
        observations["scope"] = "original MV3 fixture (storage only, no content scripts or host access); private disposable host; extension page + Bam-prepared service worker; measurement only, not a compatibility claim"
        observations["alias"] = Rules.alias
        observations["alias_is_made_up_fixture_string"] = !Rules.isChromeStyleID(Rules.alias) && UUID(uuidString: Rules.alias) == nil
        observations["content_scripts"] = "pending: not measured in this checkpoint"
        watchdog = Timer.scheduledTimer(withTimeInterval: Rules.budget - 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(complete: false, reason: "budget reached before the measurement finished") }
        }
        let hardLimit = Rules.budget
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + hardLimit - 0.5) {
            print("MEASUREMENT incomplete: hard \(Int(hardLimit)) s limit; cleanup unconfirmed"); fflush(stdout); exit(1)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.run() } catch is CancellationError {} catch { self.finish(complete: false, reason: String(describing: error)) }
        }
    }

    private func run() async throws {
        // Runner identity invariant: only canonical Bam Preview runs this fixture.
        guard Bundle.main.bundleIdentifier == PreviewProfile.bundleIdentifier else {
            throw BrowserExtensions.failure("The identity probe runs only in canonical Bam Preview (\(PreviewProfile.bundleIdentifier))")
        }
        observations["bundle_identifier"] = Bundle.main.bundleIdentifier ?? ""
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("bam-identity-probe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        runDirectory = directory
        let package = directory.appendingPathComponent("package", isDirectory: true)
        try Self.writePackage(to: package)

        let host = BrowserExtensions(storageURL: nil, isPrivate: true)
        self.host = host
        observations["host_private"] = true
        host.permissionPrompt = { [weak self] review in
            // Only this fixture's own install: no websites, nothing optional.
            let allowed = review.name == Rules.fixtureName && review.websites.isEmpty && !review.isOptional
            self?.reviews.append(["name": review.name, "permissions": review.permissions, "websites": review.websites,
                                  "unsupported": review.unsupported, "optional": review.isOptional, "answer": allowed ? "approved" : "denied"])
            return allowed
        }
        let profile = UUID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.configure(configuration, profileID: profile)
        await host.ready(profileID: profile)
        let id = try await host.importPackage(at: package, profileID: profile)
        extensionID = id
        guard let context = host.context(for: id) else {
            throw BrowserExtensions.failure(host.errors[id] ?? host.lastError ?? "The fixture did not load an extension context")
        }
        // Native identity facts, read from the host side.
        observations["native"] = [
            "record_id": id.uuidString,
            "context_unique_identifier": context.uniqueIdentifier,
            "unique_identifier_equals_record_id": context.uniqueIdentifier.lowercased() == id.uuidString.lowercased(),
            "base_url": context.baseURL.absoluteString,
            "base_url_host_equals_record_id": context.baseURL.host?.lowercased() == id.uuidString.lowercased(),
            "worker_prepared": ExtensionServiceWorkerPreparation.isPrepared(manifest: context.webExtension.manifest),
            "granted_permissions": context.grantedPermissions.keys.map(\.rawValue).sorted()
        ]

        let pageURL = context.baseURL.appendingPathComponent(Rules.pagePath)
        guard let pageConfiguration = host.configuration(forExtensionURL: pageURL, profileID: profile) else {
            throw BrowserExtensions.failure("The fixture page has no extension configuration")
        }
        let frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let web = WKWebView(frame: frame, configuration: pageConfiguration)
        let probeWindow = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false
        probeWindow.title = "Bam identity probe \(UUID().uuidString.prefix(8))"
        probeWindow.contentView = web
        probeWindow.orderFront(nil)
        window = probeWindow; page = web
        web.load(URLRequest(url: pageURL))

        let deadline = started + Rules.budget - 10
        var result: [String: Any]?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let text = try? await web.evaluateJavaScript("document.documentElement.dataset.\(Rules.marker) || ''") as? String,
               !text.isEmpty, let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = value; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let result else { throw BrowserExtensions.failure("The fixture page produced no measurement") }
        observations["page_location"] = web.url?.absoluteString ?? ""
        observations["measurement"] = result
        let pageReading = Rules.read(result["page"] as? [String: Any])
        let workerValue = (result["worker"] as? [String: Any])?["value"] as? [String: Any]
        let workerReading = Rules.read(workerValue)
        observations["reading"] = ["page": Rules.summary(pageReading), "worker": Rules.summary(workerReading),
                                   "content_scripts": "pending"]
        let measured = pageReading.ownGetterObserved != nil && pageReading.facadeInstalled != nil && workerValue != nil
        finish(complete: measured, reason: measured ? "page and worker measured; content scripts pending"
                                                    : "page or worker evidence missing (see measurement)")
    }

    private func finish(complete: Bool, reason: String) {
        guard !finished else { return }
        finished = true
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        observations["permission_reviews"] = reviews
        Task { @MainActor in
            let cleanup = await self.cleanUp()
            self.observations["cleanup"] = cleanup.report
            let ok = complete && cleanup.clean
            self.observations["measurement_complete"] = ok
            if let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(self.observations), options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("EXTENSION_IDENTITY \(text)") }
            else { print("EXTENSION_IDENTITY {\"measurement_complete\":false}") }
            print("MEASUREMENT \(ok ? "complete" : "incomplete"): \(reason)\(cleanup.clean ? "" : "; cleanup incomplete")")
            fflush(stdout); exit(ok ? 0 : 1)
        }
    }

    /// Bounded (about 4 s): dispose the page and window, remove the fixture, shut the host down, then confirm the
    /// host's own temporary storage and the run folder are gone. Removes nothing outside those two paths.
    private func cleanUp() async -> (clean: Bool, report: [String: Any]) {
        var report: [String: Any] = [:]
        var clean = true
        page?.stopLoading(); page?.removeFromSuperview(); page = nil
        window?.contentView = nil; window?.orderOut(nil); window?.close(); window = nil
        if let host, let id = extensionID {
            final class Outcome { var done = false; var error: String? }
            let outcome = Outcome()
            let removal = Task { @MainActor in
                do { try await host.remove(id: id) } catch { outcome.error = String(describing: error) }
                outcome.done = true
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !outcome.done, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if !outcome.done { removal.cancel(); report["fixture_removal_timed_out"] = true }
            if let error = outcome.error { report["fixture_removal_error"] = error }
            report["fixture_removed"] = outcome.done && outcome.error == nil && host.context(for: id) == nil
        }
        let storage = host?.storageURL
        host?.shutdown(); host = nil
        let fm = FileManager.default
        if let storage {
            if storage.standardizedFileURL.path.hasPrefix(fm.temporaryDirectory.standardizedFileURL.path + "/") {
                if fm.fileExists(atPath: storage.path) { try? fm.removeItem(at: storage) }
                let gone = !fm.fileExists(atPath: storage.path)
                report["host_temporary_storage_removed"] = gone; clean = clean && gone
            } else {
                report["host_temporary_storage_removed"] = "not a temporary path; left untouched"; clean = false
            }
        }
        if let directory = runDirectory {
            if fm.fileExists(atPath: directory.path) { try? fm.removeItem(at: directory) }
            let gone = !fm.fileExists(atPath: directory.path)
            report["run_directory_removed"] = gone; clean = clean && gone
        }
        return (clean, report)
    }

    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(jsonSafe)
        case let array as [Any]: return array.map(jsonSafe)
        case let string as String: return String(string.prefix(2_000))
        case is NSNumber, is NSNull: return value
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional { return mirror.children.first.map { jsonSafe($0.value) } ?? NSNull() }
            return String(String(describing: value).prefix(2_000))
        }
    }
}
