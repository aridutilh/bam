import AppKit
import WebKit

/// Bounded, disposable observation of one official vendor extension
/// (`--vendor-extension-probe`, BAM_VENDOR_CHROME_ID). It installs exactly as a
/// user would, through Bam's normal Chrome Web Store installer, and requires the
/// CRX3 publisher signature to verify for that ID. By default everything runs in a
/// private controller: non-persistent website data and temporary extension storage
/// that is removed at the end. `BAM_VENDOR_PROFILE=normal` (canonical Bam Preview
/// only) instead uses normal, non-private semantics on a new random profile whose
/// website store is task-owned and removed by API at the end, with a non-persistent
/// extension controller configuration; it measures whether the extension really sees
/// a normal profile and never claims so unmeasured. No vendor files are kept, no
/// native companion is granted, and no account sign-in or vault operation is performed.
/// This is an observation, not a compatibility test. `BAM_VENDOR_QUIET=1` (VendorQuietMode) keeps install, grants and
/// cleanup but performs no host JavaScript evaluation, action invocation or options fallback, so a person's real input can
/// be observed; it reports `quiet-unmeasured` (exit 3), never `completed`.
@MainActor final class VendorExtensionProbe {
    private var watchdog: Timer?
    private var task: Task<Void, Never>?
    private var controller: BrowserController?
    private var window: NSWindow?
    private var extensionID: UUID?
    private var initialized = false
    private var finished = false
    /// Set once a deadline has cancelled the run and is waiting for it to unwind.
    private var expiring = false
    /// Set when the run task has fully returned, so every cleanup in the
    /// installation path (including the installer's staging-folder removal) ran.
    private var runEnded = false
    /// The installer's staging parent for this run only (downloaded archive and
    /// unpacked package). Created and removed by the probe; nothing else is touched.
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("bam-vendor-probe-\(UUID().uuidString)", isDirectory: true)
    private var preparationStarted = ProcessInfo.processInfo.systemUptime
    private var observationStarted: TimeInterval?
    /// True only when the full requested observation period ran.
    private var observationCompleted = false
    private var pages: [String: [String: Any]] = [:]
    private var observations: [String: Any] = ["scope": "official Chrome Web Store CRX, signature verified for the requested ID; fresh private profile and temporary extension storage; no sign-in; no native companion; no compatibility claim"]
    private var blockedNavigations: [[String: Any]] = []
    private var reviewEvents: [[String: Any]] = []
    /// `BAM_VENDOR_QUIET=1`: no host-initiated evaluation, action invocation or options fallback (VendorQuietMode).
    private var quiet = false
    private var plan = VendorQuietMode.plan(quiet: false)
    private var responderSnapshots: [[String: Any]] = []
    /// IDs seeded by BAM_VENDOR_SEED_BOOKMARKS (empty when off), for the no-loaded-views check.
    private var seededBookmarkIDs: [UUID] = []
    /// The two seeded bookmark pages' exact addresses (empty when off): the only non-extension URLs an extension
    /// may open in this probe, and only while the seed is on. Every other external request stays blocked.
    private var seededDestinations: Set<String> = []
    private var seededNavigations: [[String: Any]] = []
    /// Opt-in normal-profile mode (`BAM_VENDOR_PROFILE=normal`): this run's own identities,
    /// directory and isolated website store; nil in today's default private mode.
    private struct NormalRun {
        let ids: VendorProbeIsolation.Identities
        let directory: URL
        let stores: WebsiteProfileStore
    }
    private var normalRun: NormalRun?
    /// Every evaluation round of VendorProbeIsolation.measurementScript: one entry per live extension
    /// document. Positions can change between rounds; documents are matched by their own random ID.
    private var modeRounds: [[[String: Any]]] = []
    private var controllerConfigurationPersistent: Bool?
    /// A weak handle on an owned page; nil once WebKit has released it.
    private final class WeakView { weak var view: WKWebView?; init(_ view: WKWebView) { self.view = view } }
    /// Every action popup page seen during the run, so each one's release can be confirmed before the
    /// owned store is removed.
    private var observedPopups: [WeakView] = []
    private func notePopup(_ view: WKWebView) {
        if !observedPopups.contains(where: { $0.view === view }) { observedPopups.append(WeakView(view)) }
    }
    private static var reservedIdentifiers: Set<UUID> { [BrowserProfile.defaultID, PreviewProfile.defaultStoreIdentifier] }

    /// Normal semantics with only task-owned storage: a non-private controller on a new random profile whose
    /// website data is the run's own persistent store (removed at the end), a non-persistent extension controller
    /// configuration, and session/library/extension files in the run directory. Nothing is created unless every
    /// precondition holds; there is no fallback to the default store mapping or to private controller storage.
    @available(macOS 15.4, *)
    private func makeNormalController(home: BrowserTab) throws -> BrowserController {
        guard VendorProbeIsolation.allowsNormalMode(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            throw BrowserExtensions.failure("Normal-profile mode runs only in canonical Bam Preview (\(VendorProbeIsolation.canonicalPreviewBundleIdentifier))")
        }
        guard let ids = VendorProbeIsolation.makeIdentities(reserved: Self.reservedIdentifiers) else {
            throw BrowserExtensions.failure("Could not generate unreserved identifiers for the run")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bam-vendor-normal-\(ids.run.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let stores = try WebsiteProfileStore(isolated: [ids.profile: ids.store])
        normalRun = NormalRun(ids: ids, directory: directory, stores: stores)
        observations["normal_profile"] = ["run": ids.run.uuidString, "profile": ids.profile.uuidString, "store": ids.store.uuidString]
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), ephemeral: false, profileStores: stores)
        // The session exists in the new profile before any view or page: one Space, one blank tab.
        browser.session = BrowserSession(tabs: [home], activeID: home.id,
                                         spaces: [BrowserSpace(id: 0, name: "Vendor probe", symbol: "puzzlepiece.extension", colorIndex: 0, profileID: ids.profile)],
                                         profiles: BrowserProfile.defaults + [BrowserProfile(id: ids.profile, name: "Vendor probe")])
        // The extension host is built now, before any runtime exists, and must not write controller storage.
        let host = browser.browserExtensions
        guard !host.isPrivate, BrowserExtensions.usesNonPersistentController(isPrivate: host.isPrivate, storage: host.controllerStorage) else {
            throw BrowserExtensions.failure("Normal-profile mode needs a non-private host with non-persistent controller storage; this build doesn't select it (no runtime or controller storage was created)")
        }
        guard host.storageURL.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"),
              browser.session.currentProfileID == ids.profile else {
            throw BrowserExtensions.failure("Normal-profile storage or profile is not the run's own")
        }
        return browser
    }

    func start() {
        guard #available(macOS 15.4, *) else {
            finish(false, reason: "WKWebExtension requires macOS 15.4 or later")
            return
        }
        // Store lookup, download, verification and installation have their own
        // deadline; the observation deadline is armed only when observation begins.
        preparationStarted = ProcessInfo.processInfo.systemUptime
        arm(Self.preparationSeconds, reason: "Preparation deadline reached before observation began")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.run() }
            catch {
                // A deadline that cancelled the run reports once the run has unwound.
                if !self.expiring { self.finish(false, reason: self.errorDescription(error)) }
            }
            self.runEnded = true
        }
    }

    /// BAM_VENDOR_SECONDS bounds the observation (default 19, at most 120).
    static var observationSeconds: TimeInterval {
        min(120, max(5, Double(ProcessInfo.processInfo.environment["BAM_VENDOR_SECONDS"] ?? "") ?? 19))
    }
    /// BAM_VENDOR_PREPARE_SECONDS bounds resolution, download, verification and
    /// installation (default 90, 15–300), separately from the observation.
    static var preparationSeconds: TimeInterval {
        min(300, max(15, Double(ProcessInfo.processInfo.environment["BAM_VENDOR_PREPARE_SECONDS"] ?? "") ?? 90))
    }
    /// How long a deadline waits for the cancelled run to unwind before exiting.
    static let cancellationGrace: TimeInterval = 15

    private func arm(_ seconds: TimeInterval, reason: String) {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.expire(reason) }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
    }
    /// A deadline cancels the run, then waits (bounded) for it to return so the
    /// installer's own cleanup, including removal of its staging folder, completes
    /// before the process exits. Whether it did is reported, never assumed.
    private func expire(_ reason: String) {
        guard !finished, !expiring else { return }
        expiring = true
        observations["deadline"] = reason
        task?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let limit = ProcessInfo.processInfo.systemUptime + Self.cancellationGrace
            while !self.runEnded && ProcessInfo.processInfo.systemUptime < limit {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.observations["cancelled_run_unwound"] = self.runEnded
            let detail = self.runEnded ? "" : "; the cancelled run did not return within \(Int(Self.cancellationGrace)) s, so installer cleanup is unconfirmed"
            // A deadline never counts as completing the requested observation;
            // the phase fields show how far the run got.
            self.finish(false, reason: reason + detail)
        }
    }
    /// BAM_VENDOR_SITE opens one ordinary HTTP(S) page in the profile so content
    /// scripts can run; BAM_VENDOR_SITE_PROBE is an optional JavaScript expression
    /// evaluated there. BAM_VENDOR_MARKER selects the actual DOM marker; the default
    /// uses the full display name and is only a heuristic, especially for localized names.
    private static func siteURL(_ env: [String: String]) -> URL? {
        guard let raw = env["BAM_VENDOR_SITE"], let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private static func siteProbeScript(_ env: [String: String], extensionName: String) -> String {
        if let custom = env["BAM_VENDOR_SITE_PROBE"], !custom.isEmpty { return custom }
        let needle = (env["BAM_VENDOR_MARKER"] ?? extensionName).lowercased().replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
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
              if (needle && (sig.includes(needle) || sig.includes(alt))) named++;
              if (el.tagName === "IFRAME" && (el.src || "").startsWith("webkit-extension://")) extensionFrames++;
              if (el.shadowRoot) { shadows++; visit(el.shadowRoot); }
            }
          };
          visit(document);
          return { marker: needle, readyState: document.readyState, title: document.title.slice(0, 120), total, named, shadows, extensionFrames,
                   inputs: document.querySelectorAll("input").length };
        })()
        """
    }

    @available(macOS 15.4, *)
    private func run() async throws {
        let env = ProcessInfo.processInfo.environment
        // The only intake is Bam's normal store installation: the official
        // Chrome Web Store CRX, whose publisher signature must verify for
        // exactly this ID. No unpacked or locally supplied vendor folders.
        guard let expected = env["BAM_VENDOR_CHROME_ID"]?.trimmingCharacters(in: .whitespaces).lowercased(),
              expected.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else {
            throw BrowserExtensions.failure("Set BAM_VENDOR_CHROME_ID to a 32-letter Chrome Web Store extension ID")
        }
        observations["chrome_web_store_id"] = expected

        guard let mode = VendorProbeIsolation.mode(env["BAM_VENDOR_PROFILE"]) else {
            throw BrowserExtensions.failure("BAM_VENDOR_PROFILE must be private (default) or normal")
        }
        observations["profile_mode"] = mode.rawValue
        // Opt-in quiet mode: decided (and refused if invalid) before anything is created.
        switch VendorQuietMode.decide(env[VendorQuietMode.flag], siteProbe: env["BAM_VENDOR_SITE_PROBE"], backgroundProbe: env["BAM_VENDOR_BG_PROBE"]) {
        case .invalid(let why): throw BrowserExtensions.failure(why)
        case .on: quiet = true
        case .off: quiet = false
        }
        plan = VendorQuietMode.plan(quiet: quiet)
        observations["quiet_mode"] = quiet
        if quiet { observations["quiet_scope"] = VendorQuietMode.quietUnmeasuredText }
        // Opt-in bookmark fixture: decided (and refused) before anything is created or mutated.
        let seedDecision = BookmarkVendorSeed.decide(flag: env[BookmarkVendorSeed.flag], isNormalMode: mode == .normal, site: env["BAM_VENDOR_SITE"])
        if case .refused(let why) = seedDecision { throw BrowserExtensions.failure(why) }
        // Opt-in restore fixture: also decided (and refused) before anything exists. Its start tab is the run's own
        // ordinary today page, so the window holds only ordinary http tabs.
        let restoreDecision = RestoreVendorFixture.decide(flag: env[RestoreVendorFixture.flag], isNormalMode: mode == .normal,
                                                          site: env["BAM_VENDOR_SITE"], seedFlag: env[BookmarkVendorSeed.flag])
        if case .refused(let why) = restoreDecision { throw BrowserExtensions.failure(why) }
        let home: BrowserTab
        if case .on(let today, _) = restoreDecision { home = BrowserTab(title: RestoreVendorFixture.startTitle, address: today, space: 0) }
        else { home = BrowserTab(title: "Vendor observation", address: "orbit://newtab", space: 0) }
        let browser: BrowserController
        if mode == .normal {
            browser = try makeNormalController(home: home)
            // Into the run's own profile and Space, before any view or page exists; the blank tab stays selected.
            if case .seed(let origin) = seedDecision, let run = normalRun {
                let seeded = BookmarkVendorSeed.seed(into: &browser.session, profileID: run.ids.profile, space: 0, origin: origin)
                seededBookmarkIDs = Array(seeded.ids.values)
                seededDestinations = Set(seeded.destinations)
                observations["bookmark_seed"] = ["items": seeded.itemCount, "bookmark_pages": seeded.bookmarkPages,
                                                 "ids": seeded.ids.mapValues(\.uuidString)]
            }
            if case .on = restoreDecision {
                seededDestinations = RestoreVendorFixture.destinations(restoreDecision)
                observations["restore_fixture"] = ["start_tab": "the run's ordinary today page", "allowed_reopen_urls": seededDestinations.count]
            }
            observations["scope"] = "official Chrome Web Store CRX, signature verified for the requested ID; normal (non-private) semantics on a new random profile whose website store is task-owned and removed; non-persistent extension controller configuration; run-directory session and extension storage; no sign-in; no native companion; no compatibility claim"
        } else {
            let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent("unused-vendor-probe-\(UUID().uuidString).json")
            browser = BrowserController(sessionURL: sessionURL, ephemeral: true)
            browser.session = BrowserSession(tabs: [home], activeID: home.id)
        }
        browser.automaticallyShowsVideo = false  // a property set; only the menu toggle writes preferences
        // Quiet: the browser's own automatic page evaluations are off before any page or view loads (property sets only).
        if !plan.faviconDocumentDiscovery { browser.documentFaviconDiscoveryEnabled = false }
        if !plan.automaticTabSleeping { browser.automaticTabSleeping = false }
        controller = browser
        let main = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 920, height: 680),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.title = "Bam vendor observation \(UUID().uuidString.prefix(8))"
        main.contentViewController = browser
        // AppKit may adopt the controller's initially empty root size. Match the
        // app launch path so this probe exercises real, visible browser chrome.
        main.setContentSize(NSSize(width: 920, height: 680))
        browser.view.frame = NSRect(x: 0, y: 0, width: 920, height: 680)
        window = main; main.makeKeyAndOrderFront(nil)
        browser.layoutBrowser(); browser.view.layoutSubtreeIfNeeded()
        if !seededBookmarkIDs.isEmpty {
            observations["bookmark_seed_views_loaded_after_layout"] = seededBookmarkIDs.filter { browser.browsers[$0] != nil }.count
        }

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
            guard let self else { return nil }
            if host?.allowsExtensionURL(url, profileID: profile) == true { return create?(url, profile, active) }
            guard BookmarkVendorSeed.allowsSeededNavigation(url, destinations: self.seededDestinations) else {
                self.recordBlocked(url, operation: "createTab"); return nil
            }
            let tab = create?(url, profile, active)
            self.recordSeededNavigation(url, operation: "createTab", accepted: tab != nil)
            return tab
        }
        let navigate = host.navigateTab
        host.navigateTab = { [weak self, weak host] id, url in
            guard let self, let browser = self.controller, let tab = browser.session.tabs.first(where: { $0.id == id }) else {
                self?.recordBlocked(url, operation: "navigateTab"); return false
            }
            if host?.allowsExtensionURL(url, profileID: browser.session.profileID(for: tab)) == true { return navigate?(id, url) ?? false }
            guard BookmarkVendorSeed.allowsSeededNavigation(url, destinations: self.seededDestinations) else {
                self.recordBlocked(url, operation: "navigateTab"); return false
            }
            let accepted = navigate?(id, url) ?? false
            self.recordSeededNavigation(url, operation: "navigateTab", accepted: accepted)
            return accepted
        }
        let profile = browser.session.currentProfileID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = browser.profileStores.store(for: profile)
        host.configure(configuration, profileID: profile)
        let installer = host.installer
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        installer.stagingRoot = scratch
        let listing = try await installer.chromeWebStore.candidate(for: expected)
        guard listing.source == .chromeWebStore, listing.upstreamID == expected else {
            throw BrowserExtensions.failure("The Chrome Web Store did not resolve \(expected) to that listing")
        }
        let id = try await installer.install(listing, profileID: profile)
        try Task.checkCancellation()
        guard !finished, !expiring else { return }
        extensionID = id
        guard let record = host.items(profileID: profile).first(where: { $0.id == id }), let origin = record.catalog,
              origin.source == .chromeWebStore, origin.upstreamID == expected, origin.verifiedChromeExtensionID == expected else {
            throw BrowserExtensions.failure("The installed package is not a CRX3 publisher-signature-verified build of \(expected)")
        }
        observations["provenance"] = origin.provenance
        observations["package_version"] = record.version
        observations["package_sha256"] = origin.sha256
        observations["installed_into_temporary_storage"] = host.storageURL.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        guard record.nativeHost == nil else { throw BrowserExtensions.failure("A native companion was granted during installation") }
        observations["native_companion_granted"] = false
        guard let context = host.context(for: id) else {
            throw BrowserExtensions.failure(host.errors[id] ?? host.lastError ?? "The host installed the package but did not load an extension context")
        }
        let manifest = context.webExtension.manifest
        let package = host.storageURL.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.packageName, isDirectory: true)
        observations["manifest_version"] = manifest["manifest_version"]
        observations["requests_native_messaging"] = (manifest["permissions"] as? [String] ?? []).contains("nativeMessaging")
        initialized = true
        observations["extension_name"] = context.webExtension.displayName ?? ""
        observations["has_background"] = context.webExtension.hasBackgroundContent
        observations["granted_permissions"] = context.grantedPermissions.keys.map(\.rawValue).sorted()
        observations["unsupported_api_policy"] = context.unsupportedAPIs.sorted()
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
        // Preparation is over: the requested observation budget starts now, with
        // its own backstop deadline, independent of how long installation took.
        let started = ProcessInfo.processInfo.systemUptime
        observationStarted = started
        observations["preparation_seconds"] = (started - preparationStarted).rounded()
        let budget = Self.observationSeconds
        observations["observation_requested_seconds"] = budget
        arm(budget + 10, reason: "Observation backstop deadline reached")
        var actionInvoked = false, fallbackOpened = false, lastSample = -1
        var invokedAction: WKWebExtension.Action?
        observations["action_invoked"] = false
        observations["action_popup_presented"] = false
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        while !finished && !expiring && ProcessInfo.processInfo.systemUptime - started < budget {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if siteTabID == nil, let siteURL, elapsed >= 1 {
                siteTabID = browser.openProfileTab(siteURL, profileID: profile, active: true)
                observations["site_tab_opened"] = siteTabID != nil
            }
            if plan.responderSnapshots, responderSnapshots.count < VendorQuietMode.maximumResponderSnapshots,
               elapsed >= Double(responderSnapshots.count) * VendorQuietMode.responderSnapshotSeconds {
                snapshotResponder(elapsed: elapsed, siteTabID: siteTabID, browser: browser)
            }
            if plan.invokeAction && !actionInvoked && elapsed >= 2 {
                let target = siteTabID ?? home.id
                browser.select(target); browser.refresh()
                host.reconcile(); browser.refreshExtensionActions()
                browser.layoutBrowser(); browser.view.layoutSubtreeIfNeeded()
                let buttons = descendants(browser.sidebar).compactMap { $0 as? NSButton }.filter {
                    $0.identifier?.rawValue.hasPrefix("extension-action-") == true && !$0.isHiddenOrHasHiddenAncestor &&
                        $0.bounds.width > 0 && $0.bounds.height > 0
                }
                let button = buttons.first { $0.identifier?.rawValue == "extension-action-\(id.uuidString)" }
                let item = host.actionItems(profileID: profile, tabID: target).first { $0.id == id }
                let runtime = context.webExtensionController?.delegate as? BrowserExtensionRuntime
                let active = runtime?.currentSurface(target)?.isActive == true
                observations["sidebar_action_count"] = buttons.count
                observations["sidebar_action_visible"] = button != nil
                observations["sidebar_action_has_icon"] = item?.icon != nil
                observations["sidebar_action_enabled"] = button?.isEnabled == true
                observations["action_tab_active"] = active
                if let button, button.isEnabled, active, let tab = runtime?.tabs[target] {
                    invokedAction = context.action(for: tab)
                    actionInvoked = true
                    observations["action_invoked"] = true
                    // Exercise the actual vendor-logo button and its controller
                    // callback, including current-tab/profile resolution.
                    button.performClick(nil)
                }
            }
            if plan.readPopupGetters {
                if invokedAction?.popupPopover?.isShown == true { observations["action_popup_presented"] = true }
                if let popup = invokedAction?.popupWebView { notePopup(popup) }
            }
            if plan.openFallbackPage && !fallbackOpened && elapsed >= 5 {
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
                    if plan.backgroundProbe, let script = env["BAM_VENDOR_BG_PROBE"], !script.isEmpty, sample >= 4 {
                        observations["background_eval"] = await runtime.compatibility.evaluate(script, for: context)
                    }
                    // Mode validity, measured in the extension's own documents (both modes, for comparison). Not in quiet
                    // mode: the strict classifier then sees no rounds and reports unmeasured, as it always would.
                    if plan.documentModeMeasurement, sample >= 2 {
                        recordModeMeasurements(await runtime.compatibility.evaluate(VendorProbeIsolation.measurementScript, for: context))
                    }
                }
                controllerConfigurationPersistent = context.webExtensionController?.configuration.isPersistent
                observations["controller_configuration_persistent"] = controllerConfigurationPersistent
                observations["manifest_errors"] = context.webExtension.errors.prefix(20).map(errorDescription)
                observations["context_error_count"] = context.errors.count
                if plan.readPopupGetters {
                    if let action = invokedAction ?? context.action(for: nil) {
                        observations["action_has_popup"] = action.presentsPopup
                        observations["action_popup_is_shown"] = action.popupPopover?.isShown == true
                        if let popup = action.popupWebView {
                            notePopup(popup)
                            if plan.samplePages { samplePage(popup, key: "action_popup", context: context) }
                        }
                    }
                } else {
                    // Quiet: no WebKit action getter at all (action(for:) is get-or-create; popupPopover/popupWebView create
                    // and load the popup). Popup presence comes from the manifest only.
                    let declared = ((manifest["action"] as? [String: Any])?["default_popup"] as? String).map { !$0.isEmpty } ?? false
                    observations["action_has_popup"] = declared
                    observations["action_has_popup_source"] = "manifest default_popup (quiet; WebKit action not read)"
                    observations["action_popup_is_shown"] = "not read (quiet: the popup getters create and load the popup)"
                }
                for (tabID, web) in browser.browsers where plan.samplePages && web.url.map({ BrowserExtensions.isExtensionURL($0, ownedBy: context) }) == true {
                    samplePage(web, key: "tab_\(tabID.uuidString)", context: context)
                }
                if let siteTabID, let web = browser.browsers[siteTabID], let current = web.url, ["http", "https"].contains(current.scheme?.lowercased() ?? "") {
                    observations["site_has_access"] = context.hasAccess(to: current)
                    observations["site_has_injected_content"] = context.hasInjectedContent(for: current)
                    observations["site_tab_uses_profile_controller"] = web.configuration.webExtensionController === context.webExtensionController
                    if plan.sampleSite { sampleSite(web, script: siteProbe, elapsed: elapsed) }
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !finished, !expiring else { return }
        observationCompleted = true
        finish(true, reason: "Requested observation period completed; functionality is not certified")
    }

    private func localPage(_ path: String, base: URL, package: URL) -> URL? {
        guard !path.isEmpty, !path.contains("://"), !path.contains("?"), !path.contains("#"),
              !path.split(separator: "/").contains("..") else { return nil }
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent(relative).path) else { return nil }
        return base.appendingPathComponent(relative)
    }

    /// Quiet mode, native reads only: key window and first-responder class, and whether it is inside the site tab's web
    /// view (a text-input subview counts as inside). No page, title or personal text.
    private func snapshotResponder(elapsed: TimeInterval, siteTabID: UUID?, browser: BrowserController) {
        var entry: [String: Any] = ["t_s": Int(elapsed.rounded(.down))]
        entry["key_window_is_probe"] = NSApp.keyWindow != nil && NSApp.keyWindow === window
        let responder = window?.firstResponder
        entry["first_responder_class"] = responder.map { String(String(describing: type(of: $0)).prefix(80)) } ?? "none"
        if let siteTabID, let web = browser.browsers[siteTabID] {
            entry["first_responder_inside_site_web_view"] = (responder as? NSView).map { $0 === web || $0.isDescendant(of: web) } ?? false
            entry["site_tab_selected"] = browser.session.activeID == siteTabID
        }
        responderSnapshots.append(entry)
    }

    @available(macOS 15.4, *)
    private func samplePage(_ web: WKWebView, key: String, context: WKWebExtensionContext) {
        guard plan.samplePages else { return }   // quiet: never, whatever the caller
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
        guard plan.sampleSite else { return }   // quiet: never, whatever the caller
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
        return Self.sanitize("\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
    /// The one sanitizer for every string the probe prints. URL user-info,
    /// queries and fragments can carry sign-in state, so they are removed from
    /// anything URL-shaped, and length is bounded. Nothing else is redacted.
    nonisolated static func sanitize(_ text: String, limit: Int = 1500) -> String {
        var clean = text.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^\s/?#@]+@"#, with: "$1", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://[^\s?#]+)[?#][^\s"'<>]*"#, with: "$1[redacted]", options: .regularExpression)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }
    /// Applies `sanitize` to every string inside a JSON-like value, dictionary
    /// keys included (custom probes may key results by URL). Keys are bounded to
    /// 200 characters. If two keys sanitize to the same text, original keys are
    /// taken in sorted order: the first keeps it and later ones get " [2]", " [3]"…
    nonisolated static func scrub(_ value: Any) -> Any {
        switch value {
        case let text as String: return sanitize(text)
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for key in object.keys.sorted() {
                let base = sanitize(key, limit: 200)
                var clean = base, ordinal = 2
                while result[clean] != nil { clean = "\(base) [\(ordinal)]"; ordinal += 1 }
                result[clean] = scrub(object[key]!)
            }
            return result
        case let list as [Any]: return list.map(scrub)
        default: return value
        }
    }
    private func recordSeededNavigation(_ url: URL, operation: String, accepted: Bool) {
        guard seededNavigations.count < 20 else { return }
        seededNavigations.append(["operation": operation, "url": sanitizedURL(url), "accepted": accepted])
    }
    private func recordBlocked(_ url: URL, operation: String) {
        guard blockedNavigations.count < 20 else { return }
        blockedNavigations.append(["operation": operation, "url": sanitizedURL(url)])
    }

    /// Keeps one whole round per evaluation (one JSON string per live document). A document whose result isn't a
    /// parsable object is kept as an unfinished sample, never skipped.
    private func recordModeMeasurements(_ results: [String]) {
        modeRounds.append(results.map { text in
            if let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] { return object }
            return ["state": "unparsed", "raw": String(text.prefix(200))]
        })
    }
    /// After the views are released: remove only the run's own website store (bounded, confirmed by the
    /// store list), then the run directory. Never lists-and-deletes anything else.
    /// `controllerReleased` covers both the BrowserController and the WKWebExtensionController.
    private func cleanUpNormalRun(_ run: NormalRun, controllerReleased: @escaping () -> Bool,
                                  extensionControllerReleased: @escaping () -> Bool,
                                  livePages: @escaping () -> Int) async -> (clean: Bool, report: [String: Any]) {
        var report: [String: Any] = [:]
        // No persistent store can be (re)opened from here on; pages still holding one keep it until released.
        run.stores.releaseStores()
        var released = false, storeRemoved = false
        if run.stores.allowedStoreIdentifiers == [run.ids.store] {
            // WebKit requires every WKWebView using a store to be released before that store is removed:
            // the gate polls the controller and every tracked owned page, and never removes otherwise.
            let gated = await VendorProbeIsolation.removeOwnedStoreAfterRelease(
                run.ids.store, reserved: Self.reservedIdentifiers,
                isReleased: { controllerReleased() && livePages() == 0 }, releaseTimeout: 10, pollInterval: 0.1,
                remove: { id, done in
                    Task { @MainActor in WKWebsiteDataStore.remove(forIdentifier: id) { error in done(error.map { Self.sanitize($0.localizedDescription) }) } }
                },
                list: { done in Task { @MainActor in WKWebsiteDataStore.fetchAllDataStoreIdentifiers { done($0) } } },
                timeout: 10, retryDelay: 1)
            released = gated.released
            storeRemoved = gated.clean
            if let result = gated.removal {
                report["store_removal"] = ["attempts": result.attempts, "error": result.removalError ?? "none", "timed_out": result.removalTimedOut,
                                           "confirmed_absent": result.confirmedAbsent, "refused": result.refused ?? "no"]
            } else {
                report["store_removal"] = ["not_attempted": "the controller or an owned page was still alive after 10 s; store \(run.ids.store.uuidString) left for manual removal"]
            }
        } else {
            report["store_removal"] = ["refused": "the isolated store allowlist is not exactly the run's store"]
        }
        report["controllers_released"] = controllerReleased()
        report["extension_controller_released"] = extensionControllerReleased()
        report["owned_pages_still_alive"] = livePages()
        report["released_before_removal"] = released
        report["store_removed"] = storeRemoved
        let fm = FileManager.default
        if fm.fileExists(atPath: run.directory.path) { try? fm.removeItem(at: run.directory) }
        let directoryClean = !fm.fileExists(atPath: run.directory.path)
        report["run_directory_remaining"] = !directoryClean
        report["extension_controller_storage"] = "non-persistent; nothing on disk to remove"
        // Clean only when the controller and every owned page were released first, the owned store
        // was removed and confirmed absent, and the run directory is gone.
        return (released && storeRemoved && directoryClean, report)
    }

    private func finish(_ requested: Bool, reason raw: String) {
        guard !finished else { return }
        finished = true; watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        observations["phases"] = ["installed_and_initialized": initialized, "observation_started": observationStarted != nil,
                                  "observation_completed": observationCompleted]
        if let observationStarted {
            observations["observation_elapsed_seconds"] = (ProcessInfo.processInfo.systemUptime - observationStarted).rounded()
        }
        let env = ProcessInfo.processInfo.environment
        if env["BAM_VENDOR_SITE_PROBE"]?.isEmpty == false || env["BAM_VENDOR_BG_PROBE"]?.isEmpty == false {
            observations["custom_probe_outputs"] = "BAM_VENDOR_SITE_PROBE / BAM_VENDOR_BG_PROBE results are operator-controlled; only URL user-info, queries and fragments are stripped"
        }
        observations["pages"] = pages
        observations["permission_reviews"] = reviewEvents
        observations["blocked_external_tab_requests"] = blockedNavigations
        // Evidence per document (by the document's own random ID) across every round.
        let rounds: [[Any?]] = modeRounds.map { $0.map { $0 as Any? } }
        observations["incognito_measurement_rounds"] = modeRounds.count
        observations["incognito_measurements"] = modeRounds.last ?? []
        observations["incognito_documents"] = VendorProbeIsolation.documents(fromRounds: rounds).map { doc in
            ["samples": doc.samples, "latest_complete": doc.latest.complete, "ever_incognito": doc.firstIncognito != nil] as [String: Any]
        }
        // Normal mode is only claimed when measured; otherwise it is reported as not normal or unmeasured.
        var modeValid = true
        if !seededBookmarkIDs.isEmpty, let browser = controller {
            // Seeded items stay dormant unless the extension or the operator opens one.
            observations["bookmark_seed_views_loaded_at_end"] = seededBookmarkIDs.filter { browser.browsers[$0] != nil }.count
            // Requests accepted by the gate and live renderer URLs observed at the seeded destinations.
            // URL observation alone does not prove page completion or rendered content.
            observations["bookmark_seed_navigations"] = seededNavigations
            observations["bookmark_seed_page_urls_observed_at_end"] = browser.session.tabs.filter { tab in
                guard browser.browsers[tab.id] != nil else { return false }
                guard let current = browser.browsers[tab.id]?.url?.absoluteString else { return false }
                return seededDestinations.contains(current)
            }.count
        }
        if let run = normalRun {
            observations["opened_persistent_store_ids"] = run.stores.openedPersistentIdentifiers.map(\.uuidString)
            observations["unlisted_profile_requests"] = run.stores.unlistedProfileRequests.map(\.uuidString)
            // Nothing is dropped: an unreadable result counts as an unfinished document of its own.
            let verdict = VendorProbeIsolation.verdict(rounds: rounds,
                                                       controllerConfigurationPersistent: controllerConfigurationPersistent,
                                                       openedStores: run.stores.openedPersistentIdentifiers, expectedStore: run.ids.store,
                                                       refusedProfiles: run.stores.unlistedProfileRequests)
            switch verdict {
            case .normal: observations["normal_mode_verdict"] = "normal"
            case .notNormal(let why): observations["normal_mode_verdict"] = "not normal: \(why)"; modeValid = false
            case .unmeasured(let why): observations["normal_mode_verdict"] = "unmeasured: \(why)"; modeValid = false
            }
        }
        weak let releasedController = controller
        // Every owned page the probe can reach, captured before teardown: tab pages, Little Bam and
        // Peek pages, and the action popup. All must be released before the owned store is removed.
        var ownedViews: [WeakView] = []
        if let browser = controller {
            ownedViews += browser.browsers.values.map(WeakView.init)
            ownedViews += browser.littleWindows.values.compactMap(\.webView).map(WeakView.init)
            ownedViews += browser.peeks.values.compactMap(\.webView).map(WeakView.init)
        }
        var temporaryStorage: URL?
        // The WebKit extension controller itself (public object), captured before host shutdown: its release
        // is the evidence for the background page, which is WebKit-internal and not observed directly.
        weak var extensionController: AnyObject?
        if #available(macOS 15.4, *), let browser = controller {
            let host = browser.browserExtensions
            temporaryStorage = host.storageURL
            if let id = extensionID {
                if let context = host.context(for: id) {
                    // Extension-owned pages reachable before host shutdown: the offscreen document (loading or
                    // open) and the action popups (default and per tab). The background page is WebKit-internal
                    // and not reachable; its release is covered only by the controller's.
                    extensionController = context.webExtensionController
                    let runtime = context.webExtensionController?.delegate as? BrowserExtensionRuntime
                    if let offscreen = runtime?.compatibility.offscreen?.currentDocument(for: context.uniqueIdentifier) {
                        ownedViews.append(WeakView(offscreen))
                    }
                    // Quiet: not read at all (the getter would create and load a popup during teardown). Quiet makes no
                    // claim that no popup exists (a person may open one); any popup is not inspected and, like the
                    // background page, is covered only by the tracked WKWebExtensionController's release.
                    if plan.readPopupGetters, let popup = context.action(for: nil)?.popupWebView { notePopup(popup) }
                    observations["context_errors"] = context.errors.prefix(20).map(errorDescription)
                    observations["context_error_count"] = context.errors.count
                }
                observations["host_error"] = (host.errors[id] ?? host.lastError).map { Self.sanitize($0) }
                observations["native_companion_granted"] = host.items(profileID: browser.session.currentProfileID).first { $0.id == id }?.nativeHost != nil
            }
        }
        ownedViews += observedPopups
        observations["tracked_owned_pages"] = ownedViews.count
        let extensionControllerTracked = extensionController != nil
        observations["extension_controller_tracked"] = extensionControllerTracked
        observations["untracked_owned_pages"] = "the extension background page is WebKit-internal and not observed; release of the WKWebExtensionController (tracked when it existed) is the only evidence for it"
        controller?.prepareToClose(persistSession: false)
        let fm = FileManager.default
        // The private host deletes its temporary package storage on shutdown;
        // confirm that, and remove only that folder if teardown did not.
        var hostStorageClean = true
        if let storage = temporaryStorage, storage.path.hasPrefix(fm.temporaryDirectory.path) {
            let leftover = fm.fileExists(atPath: storage.path)
            if leftover { try? fm.removeItem(at: storage) }
            observations["temporary_storage_removed_by_host"] = !leftover
            hostStorageClean = !fm.fileExists(atPath: storage.path)
            observations["temporary_storage_remaining"] = !hostStorageClean
        }
        // The installer stages downloads and unpacked packages only inside this
        // run's scratch folder. Whatever it left there after returning (or after
        // a cancelled run unwound) is reported, then only this folder is removed.
        let stagedLeft = (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []
        observations["installer_staging_entries_left"] = stagedLeft.count
        observations["installer_staging_removed_by_installer"] = stagedLeft.isEmpty
        if fm.fileExists(atPath: scratch.path) { try? fm.removeItem(at: scratch) }
        let scratchClean = !fm.fileExists(atPath: scratch.path)
        observations["installer_staging_remaining"] = !scratchClean
        window?.contentViewController = nil; window?.orderOut(nil); window?.close()
        controller = nil; window = nil
        // "completed" means the full requested observation ran (not merely that
        // the extension initialized) and no vendor files were left behind.
        var reasonText = raw
        if requested && observationCompleted && !(hostStorageClean && scratchClean) {
            reasonText += "; temporary vendor files could not be removed"
        }
        let base = requested && observationCompleted && hostStorageClean && scratchClean
        if quiet { observations["responder_snapshots"] = responderSnapshots }
        // Quiet: the interval finished with clean cleanup, independent of the (necessarily unmeasured) profile verdict.
        guard let run = normalRun else { emit(base, reasonText, quietIntervalClean: base); return }
        Task { @MainActor in
            let cleanup = await self.cleanUpNormalRun(run, controllerReleased: { releasedController == nil && extensionController == nil },
                                                      extensionControllerReleased: { extensionController == nil },
                                                      livePages: { ownedViews.filter { $0.view != nil }.count })
            self.observations["normal_cleanup"] = cleanup.report
            var text = reasonText
            if !modeValid { text += "; normal-profile mode not established (\(self.observations["normal_mode_verdict"] ?? "unknown"))" }
            if !cleanup.clean { text += "; the run's own website store or directory could not be confirmed removed" }
            self.emit(base && modeValid && cleanup.clean, text, quietIntervalClean: base && cleanup.clean)
        }
    }

    /// Default mode: unchanged (completed → exit 0, otherwise failed → exit 1). Quiet mode never reports completed; a
    /// finished interval with clean cleanup is `quiet-unmeasured` (exit 3), anything else failed (exit 1).
    private func emit(_ success: Bool, _ reasonText: String, quietIntervalClean: Bool) {
        let result = VendorQuietMode.result(quiet: quiet, success: success, quietIntervalClean: quietIntervalClean)
        let reason = Self.sanitize(quiet ? reasonText + "; " + VendorQuietMode.quietUnmeasuredText : reasonText)
        observations["completed"] = result.completed
        if quiet { observations["quiet_status"] = result.status.rawValue }
        observations["reason"] = reason
        // Single output boundary: every string printed passes through `sanitize`.
        let printable = Self.scrub(observations)
        if JSONSerialization.isValidJSONObject(printable),
           let data = try? JSONSerialization.data(withJSONObject: printable, options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print("VENDOR_OBSERVATIONS \(output)") }
        else { print("VENDOR_OBSERVATIONS {\"completed\":false,\"reason\":\"observations were not serializable\"}") }
        print("PROBE \(result.status.rawValue): \(reason)")
        fflush(stdout); exit(result.exitCode)
    }
}
