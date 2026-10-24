import AppKit
import WebKit

/// Bounded, disposable observation of an explicitly supplied vendor package.
/// This is not a compatibility test: no account sign-in or vault operation is performed.
@MainActor final class VendorExtensionProbe {
    private var watchdog: Timer?
    private var task: Task<Void, Never>?
    private var controller: BrowserController?
    private var window: NSWindow?
    private var extensionID: UUID?
    private var initialized = false
    private var finished = false
    private var pages: [String: [String: Any]] = [:]
    private var observations: [String: Any] = ["scope": "fresh private profile; no sign-in; no compatibility claim"]
    private var blockedNavigations: [[String: Any]] = []
    private var reviewEvents: [[String: Any]] = []

    func start() {
        guard #available(macOS 15.4, *) else {
            finish(false, reason: "WKWebExtension requires macOS 15.4 or later")
            return
        }
        let timer = Timer(timeInterval: Self.observationSeconds + 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.finish(self.initialized, reason: "Overall observation deadline reached")
            }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.run() }
            catch { self.finish(false, reason: error.localizedDescription) }
        }
    }

    /// BAM_VENDOR_SECONDS bounds the observation (default 19, at most 120).
    static var observationSeconds: TimeInterval {
        min(120, max(5, Double(ProcessInfo.processInfo.environment["BAM_VENDOR_SECONDS"] ?? "") ?? 19))
    }
    /// BAM_VENDOR_SITE opens one ordinary HTTP(S) page in the profile so content
    /// scripts can run; BAM_VENDOR_SITE_PROBE is an optional JavaScript expression
    /// evaluated there (the default counts nodes that carry the extension's name).
    private static func siteURL(_ env: [String: String]) -> URL? {
        guard let raw = env["BAM_VENDOR_SITE"], let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private static func siteProbeScript(_ env: [String: String], extensionName: String) -> String {
        if let custom = env["BAM_VENDOR_SITE_PROBE"], !custom.isEmpty { return custom }
        let needle = extensionName.lowercased().replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        func encoded(_ value: String) -> String { String((try? String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)).flatMap { $0.dropFirst().dropLast() } ?? "\"\"") }
        return """
        (() => {
          const needle = \(encoded(needle));
          const alt = needle === "1password" ? "onepassword" : needle;
          let named = 0, shadows = 0, extensionFrames = 0, total = 0;
          const visit = (root) => {
            for (const el of root.querySelectorAll("*")) {
              total++;
              const sig = (el.tagName + " " + el.id + " " + (typeof el.className === "string" ? el.className : "") + " " + Array.from(el.attributes).map(a => a.name + "=" + a.value).join(" ")).toLowerCase();
              if (sig.includes(needle) || sig.includes(alt)) named++;
              if (el.tagName === "IFRAME" && (el.src || "").startsWith("webkit-extension://")) extensionFrames++;
              if (el.shadowRoot) { shadows++; visit(el.shadowRoot); }
            }
          };
          visit(document);
          return { readyState: document.readyState, title: document.title.slice(0, 120), total, named, shadows, extensionFrames,
                   inputs: document.querySelectorAll("input").length };
        })()
        """
    }

    @available(macOS 15.4, *)
    private func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BAM_VENDOR_EXTENSION"], raw.hasPrefix("/") else {
            throw BrowserExtensions.failure("Set BAM_VENDOR_EXTENSION to an absolute unpacked package directory")
        }
        let package = URL(fileURLWithPath: raw, isDirectory: true)
        let metadata = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard metadata.isDirectory == true, metadata.isSymbolicLink != true else {
            throw BrowserExtensions.failure("BAM_VENDOR_EXTENSION must be a real unpacked directory")
        }
        let manifestData = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        guard manifestData.count < 1_048_576,
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw BrowserExtensions.failure("Invalid or oversized manifest")
        }
        observations["manifest_version"] = manifest["manifest_version"]
        observations["package_version"] = manifest["version"]
        observations["package_directory"] = package.lastPathComponent

        let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent("unused-vendor-probe-\(UUID().uuidString).json")
        let browser = BrowserController(sessionURL: sessionURL, ephemeral: true)
        browser.automaticallyShowsVideo = false
        let home = BrowserTab(title: "Vendor observation", address: "orbit://newtab", space: 0)
        browser.session = BrowserSession(tabs: [home], activeID: home.id)
        controller = browser
        let main = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 920, height: 680),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.title = "Bam vendor observation \(UUID().uuidString.prefix(8))"
        main.contentViewController = browser
        window = main; main.orderFront(nil)

        let host = browser.browserExtensions
        host.onReloadNeeded = nil
        host.permissionPrompt = { [weak self] review in
            self?.reviewEvents.append([
                "permissions": review.permissions, "unsupported": review.unsupported,
                "website_patterns": review.websites, "optional": review.isOptional
            ])
            // The production host grants only its supported set. Never pretend to support missing APIs.
            return Set(review.permissions).isSubset(of: BrowserExtensions.supportedPermissions)
        }
        let create = host.createTab
        host.createTab = { [weak self, weak host] url, profile, active in
            guard host?.allowsExtensionURL(url, profileID: profile) == true else {
                self?.recordBlocked(url, operation: "createTab"); return nil
            }
            return create?(url, profile, active)
        }
        let navigate = host.navigateTab
        host.navigateTab = { [weak self, weak host] id, url in
            guard let browser = self?.controller, let tab = browser.session.tabs.first(where: { $0.id == id }),
                  host?.allowsExtensionURL(url, profileID: browser.session.profileID(for: tab)) == true else {
                self?.recordBlocked(url, operation: "navigateTab"); return false
            }
            return navigate?(id, url) ?? false
        }
        let profile = browser.session.currentProfileID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = browser.profileStores.store(for: profile)
        host.configure(configuration, profileID: profile)
        let id = try await host.importPackage(at: package, profileID: profile)
        guard !finished else { return }
        extensionID = id
        guard let context = host.context(for: id) else {
            throw BrowserExtensions.failure(host.errors[id] ?? host.lastError ?? "The host imported the manifest but did not load an extension context")
        }
        initialized = true
        observations["extension_name"] = context.webExtension.displayName ?? ""
        observations["has_background"] = context.webExtension.hasBackgroundContent
        observations["granted_permissions"] = context.grantedPermissions.keys.map(\.rawValue).sorted()
        observations["unsupported_api_policy"] = BrowserExtensions.unsupportedAPIs.sorted()
        observations["compatibility_layer"] = host.items(profileID: profile).first(where: { $0.id == id })?.compatibility ?? []
        let siteURL = Self.siteURL(env)
        var siteTabID: UUID?
        let siteProbe = Self.siteProbeScript(env, extensionName: context.webExtension.displayShortName ?? context.webExtension.displayName ?? "")
        if let siteURL { observations["site"] = sanitizedURL(siteURL) }
        context.loadBackgroundContent { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                self.observations["background_load_callback"] = error.map { self.errorDescription($0) } ?? "completed"
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var actionInvoked = false, fallbackOpened = false, lastSample = -1
        let budget = Self.observationSeconds
        while !finished && ProcessInfo.processInfo.systemUptime - started < budget {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if siteTabID == nil, let siteURL, elapsed >= 1 {
                siteTabID = browser.openProfileTab(siteURL, profileID: profile, active: true)
                observations["site_tab_opened"] = siteTabID != nil
            }
            if !actionInvoked && elapsed >= 2 {
                actionInvoked = true
                observations["action_invoked"] = true
                host.performAction(extensionID: id, tabID: nil, anchor: browser.sidebar)
            }
            if !fallbackOpened && elapsed >= 5 {
                fallbackOpened = true
                let options = manifest["options_ui"] as? [String: Any]
                if let path = env["BAM_VENDOR_PAGE"] ?? (options?["page"] as? String),
                   let local = localPage(path, base: context.baseURL, package: package) {
                    observations["fallback_page"] = sanitizedURL(local)
                    _ = browser.openProfileTab(local, profileID: profile, active: true)
                }
            }
            let sample = Int(elapsed / 3)
            if sample != lastSample {
                lastSample = sample
                observations["context_errors"] = context.errors.prefix(20).map(errorDescription)
                observations["host_error"] = host.errors[id].map { String($0.prefix(800)) }
                if let runtime = context.webExtensionController?.delegate as? BrowserExtensionRuntime {
                    observations["compatibility_diagnostics"] = runtime.compatibility.diagnostics(for: context)
                    if let script = env["BAM_VENDOR_BG_PROBE"], !script.isEmpty, sample >= 4 {
                        observations["background_eval"] = await runtime.compatibility.evaluate(script, for: context)
                    }
                }
                observations["manifest_errors"] = context.webExtension.errors.prefix(20).map(errorDescription)
                observations["context_error_count"] = context.errors.count
                if let action = context.action(for: nil) {
                    observations["action_has_popup"] = action.presentsPopup
                    if let popup = action.popupWebView { samplePage(popup, key: "action_popup", context: context) }
                }
                for (tabID, web) in browser.browsers where web.url.map({ BrowserExtensions.isExtensionURL($0, ownedBy: context) }) == true {
                    samplePage(web, key: "tab_\(tabID.uuidString)", context: context)
                }
                if let siteTabID, let web = browser.browsers[siteTabID], let current = web.url, ["http", "https"].contains(current.scheme?.lowercased() ?? "") {
                    observations["site_has_access"] = context.hasAccess(to: current)
                    observations["site_has_injected_content"] = context.hasInjectedContent(for: current)
                    observations["site_tab_uses_profile_controller"] = web.configuration.webExtensionController === context.webExtensionController
                    sampleSite(web, script: siteProbe, elapsed: elapsed)
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        observations["observation_seconds"] = ProcessInfo.processInfo.systemUptime - started
        finish(true, reason: "Bounded package observation completed; functionality is not certified")
    }

    private func localPage(_ path: String, base: URL, package: URL) -> URL? {
        guard !path.isEmpty, !path.contains("://"), !path.contains("?"), !path.contains("#"),
              !path.split(separator: "/").contains("..") else { return nil }
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent(relative).path) else { return nil }
        return base.appendingPathComponent(relative)
    }

    @available(macOS 15.4, *)
    private func samplePage(_ web: WKWebView, key: String, context: WKWebExtensionContext) {
        guard let url = web.url, BrowserExtensions.isExtensionURL(url, ownedBy: context) else { return }
        var entry: [String: Any] = ["url": sanitizedURL(url), "title": String((web.title ?? "").prefix(200)), "is_loading": web.isLoading]
        if let prior = pages[key]?["document"] { entry["document"] = prior }
        pages[key] = entry
        // Do not inspect form values, storage, cookies or account data. Return text only for
        // a recognizable login/onboarding screen in this newly created private extension.
        let script = """
        (() => {
          const raw = (document.body?.innerText || '').replace(/\\s+/g, ' ').trim();
          const onboarding = /sign\\s*in|log\\s*in|log\\s*on|welcome|get started|create (?:an? )?account|add (?:an? )?account|unlock|try 1password/i.test(raw);
          return {
            readyState: document.readyState,
            textLength: raw.length,
            onboarding: onboarding,
            text: onboarding ? raw.slice(0,800).replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/gi,'[email redacted]') : '[omitted: not identified as login/onboarding]'
          };
        })()
        """
        web.evaluateJavaScript(script) { [weak self, weak web] result, error in
            Task { @MainActor [weak self, weak web] in
                guard let self, !self.finished, let web,
                      let current = web.url, BrowserExtensions.isExtensionURL(current, ownedBy: context) else { return }
                self.pages[key]?["url"] = self.sanitizedURL(current)
                self.pages[key]?["title"] = String((web.title ?? "").prefix(200))
                self.pages[key]?["is_loading"] = web.isLoading
                if let result = result as? [String: Any] { self.pages[key]?["document"] = result }
                if let error { self.pages[key]?["javascript_error"] = self.errorDescription(error) }
            }
        }
    }

    /// Samples the ordinary page in the page world: content-script DOM additions are
    /// visible there, but no form values, storage or cookies are read.
    private func sampleSite(_ web: WKWebView, script: String, elapsed: TimeInterval) {
        web.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.finished, let current = web.url else { return }
                var entry: [String: Any] = ["url": self.sanitizedURL(current), "elapsed": Int(elapsed), "is_loading": web.isLoading]
                if let result { entry["result"] = JSONSerialization.isValidJSONObject([result]) ? result : String(describing: result) }
                if let error { entry["javascript_error"] = self.errorDescription(error) }
                var samples = self.observations["site_samples"] as? [[String: Any]] ?? []
                samples.append(entry); if samples.count > 12 { samples.removeFirst(samples.count - 12) }
                self.observations["site_samples"] = samples
            }
        }
    }

    private func sanitizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil; components?.fragment = nil
        components?.user = nil; components?.password = nil
        return components?.string ?? "[unavailable]"
    }
    private func errorDescription(_ error: Error) -> String {
        let ns = error as NSError
        // URL queries/fragments can contain sign-in state. The probe only reports bounded descriptions.
        let text = ns.localizedDescription.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://[^\s?#]+)[?#][^\s]*"#,
                                                               with: "$1[redacted]", options: .regularExpression)
        return String("\(ns.domain) \(ns.code): \(text)".prefix(1500))
    }
    private func recordBlocked(_ url: URL, operation: String) {
        guard blockedNavigations.count < 20 else { return }
        blockedNavigations.append(["operation": operation, "url": sanitizedURL(url)])
    }

    private func finish(_ success: Bool, reason: String) {
        guard !finished else { return }
        finished = true; watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        observations["completed"] = success
        observations["reason"] = reason
        observations["pages"] = pages
        observations["permission_reviews"] = reviewEvents
        observations["blocked_external_tab_requests"] = blockedNavigations
        if #available(macOS 15.4, *), let browser = controller, let id = extensionID {
            let host = browser.browserExtensions
            if let context = host.context(for: id) {
                observations["context_errors"] = context.errors.prefix(20).map(errorDescription)
                observations["context_error_count"] = context.errors.count
            }
            observations["host_error"] = host.errors[id] ?? host.lastError
        }
        controller?.prepareToClose(persistSession: false)
        window?.orderOut(nil); window?.close()
        controller = nil; window = nil
        if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print("VENDOR_OBSERVATIONS \(output)") }
        print("PROBE \(success ? "completed" : "failed"): \(reason)")
        fflush(stdout); exit(success ? 0 : 1)
    }
}
