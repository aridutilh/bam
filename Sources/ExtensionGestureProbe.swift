import AppKit
import WebKit

/// Measurement fixture, not a suite: after a real click on a button inside a web page, relayed by a content script
/// to the extension's service worker, does WebKit treat the tab as having an active user gesture for the extension?
/// Compared with no click and with the toolbar action. Opt-in (`--extension-test --extension-gesture-probe`) in
/// canonical Bam Preview, on the loopback fixture page only. The page click must be a real pointer click (root, via
/// the approved computer-use path); the probe never synthesises it, and reports untrusted clicks without counting them.
/// Original MV3 package in a run-owned folder; no API permission is granted (every optional prompt is denied).
/// Everything, cleanup included, fits a 60 s budget. Output is evidence, not a pass/fail verdict on WebKit.
@available(macOS 15.4, *)
@MainActor final class ExtensionGestureProbe {
    private static var current: ExtensionGestureProbe?
    static let budget: TimeInterval = 60
    static let marker = ExtensionGestureProbeRules.marker
    static let optionalPermission = "alarms"

    static func start(pageURL: URL) {
        let probe = ExtensionGestureProbe()
        current = probe
        probe.begin(pageURL)
    }

    // MARK: Original package

    static func manifest(matches: [String]) -> [String: Any] {
        ["manifest_version": 3, "name": "Bam gesture probe fixture", "version": "1.0",
         "description": "Original fixture: measures whether a page click relayed to the worker is a user gesture",
         "background": ["service_worker": "worker.js"],
         "action": ["default_title": "Bam gesture probe", "default_icon": ["32": "icon.png"]],
         "icons": ["32": "icon.png"],
         "optional_permissions": [optionalPermission],
         "content_scripts": [["matches": matches, "js": ["content.js"], "run_at": "document_idle"]]]
    }
    /// The gesture-gated call runs first and synchronously in the listener, with nothing awaited before it; the
    /// per-tab badge then signals arrival to the host (B = baseline, C = click, T = toolbar, plus a sequence number).
    static let workerScript = #"""
    const api = globalThis.chrome;
    let sequence = 0;
    const text = (error) => String((error && error.message) || error).slice(0, 300);
    function attempt(kind, tabId, details) {
      const n = ++sequence, receivedAt = Date.now();
      let request;
      try {
        request = Promise.resolve(api.permissions.request({permissions: ["\#(optionalPermission)"]}))
          .then((granted) => ({outcome: "resolved", granted: granted === true}), (error) => ({outcome: "rejected", error: text(error)}));
      } catch (error) { request = Promise.resolve({outcome: "threw", error: text(error)}); }
      const badge = kind.charAt(0).toUpperCase() + n;
      try { Promise.resolve(api.action.setBadgeText(typeof tabId === "number" ? {tabId, text: badge} : {text: badge})).catch(() => {}); } catch (error) {}
      return request.then((result) => ({kind, sequence: n, badge, receivedAt, settledAt: Date.now(), request: result, details: details || null}));
    }
    api.runtime.onMessage.addListener((message, sender, sendResponse) => {
      if (!message || (message.kind !== "baseline" && message.kind !== "click")) return undefined;
      attempt(message.kind, sender && sender.tab && sender.tab.id, message).then(sendResponse);
      return true;
    });
    api.action.onClicked.addListener((tab) => {
      attempt("toolbar", tab && tab.id, null).then((result) => {
        if (tab && typeof tab.id === "number") Promise.resolve(api.tabs.sendMessage(tab.id, {kind: "toolbar-result", result})).catch(() => {});
      });
    });
    """#
    /// Adds one visible, labelled button on the probe page only. Untrusted (synthetic) clicks are counted, never relayed.
    static let contentScript = #"""
    (() => {
      if (!new URLSearchParams(location.search).has("\#(marker)") || document.getElementById("\#(marker)")) return;
      const api = globalThis.chrome;
      const results = [];
      let untrustedClicks = 0, earlyClicks = 0;
      const publish = () => { document.documentElement.dataset.bamGestureProbe = JSON.stringify({results, untrustedClicks, earlyClicks}); };
      const text = (error) => String((error && error.message) || error).slice(0, 300);
      const activation = () => navigator.userActivation ? {isActive: navigator.userActivation.isActive, hasBeenActive: navigator.userActivation.hasBeenActive} : null;
      const send = (kind, details) => {
        const entry = {kind, sentAt: Date.now(), details};
        results.push(entry); publish();
        let reply;
        try { reply = Promise.resolve(api.runtime.sendMessage(Object.assign({kind}, details))); } catch (error) { reply = Promise.reject(error); }
        reply.then((response) => { entry.response = response === undefined ? null : response; publish(); },
                   (error) => { entry.error = text(error); publish(); });
      };
      const button = document.createElement("button");
      button.id = "\#(marker)"; button.type = "button"; button.textContent = "Bam gesture probe";
      button.setAttribute("aria-label", "Bam gesture probe");
      button.style.cssText = "position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:2147483647;" +
        "font:600 24px -apple-system,system-ui,sans-serif;padding:28px 40px;border-radius:14px;border:2px solid #222;" +
        "background:#ffd84d;color:#111;cursor:pointer";
      let relayed = false;
      button.addEventListener("click", (event) => {
        if (event.isTrusted !== true) { untrustedClicks += 1; publish(); return; }
        // The host arms the button when it prints READY; earlier clicks would precede the baseline phase.
        if (document.documentElement.dataset.bamGestureArmed !== "1") { earlyClicks += 1; publish(); return; }
        if (relayed) return;
        relayed = true;
        send("click", {trusted: true, userActivation: activation(),
                       pointerType: typeof event.pointerType === "string" ? event.pointerType : null, detail: event.detail});
        button.textContent = "Bam gesture probe: click received";
      });
      (document.body || document.documentElement).append(button);
      api.runtime.onMessage.addListener((message) => {
        if (message && message.kind === "toolbar-result") { results.push({kind: "toolbar", response: message.result}); publish(); }
      });
      // A short delay so the host is sampling the tab before the baseline arrives.
      setTimeout(() => send("baseline", {trusted: null, userActivation: activation()}), 1500);
    })();
    """#
    static func iconPNG() -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 28, height: 28), xRadius: 7, yRadius: 7).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 11, y: 11, width: 10, height: 10)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
    static func writePackage(to folder: URL, matches: [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: manifest(matches: matches), options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data(workerScript.utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data(contentScript.utf8).write(to: folder.appendingPathComponent("content.js"))
        guard let icon = iconPNG() else { throw BrowserExtensions.failure("Could not draw the fixture icon") }
        try icon.write(to: folder.appendingPathComponent("icon.png"))
    }

    // MARK: Run state

    private var started = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var observations: [String: Any] = [:]
    private var phases: [String: String] = [:]
    private var timeline: [[String: Any]] = []
    private var arrivals: [[String: Any]] = []
    private var prompts: [[String: Any]] = []
    private var delayed: [(badge: String, due: TimeInterval)] = []
    private var lastGesture: Bool?
    private var lastBadge = ""
    private var runDirectory: URL?
    private var controller: BrowserController?
    private var window: NSWindow?
    private var extensionID: UUID?
    private var hostStorage: URL?
    private var measuredContext: WKWebExtensionContext?
    private var measuredTab: (any WKWebExtensionTab)?
    private var tabID: UUID?
    private var pageResults: [String: Any] = [:]
    /// Diagnostic: the page's transient activation as the host itself can read it (public evaluateJavaScript in a
    /// probe-owned content world, not the extension's world), at each arrival and later. Read-only; grants nothing.
    private let hostWorld = WKContentWorld.world(name: "bam-gesture-probe-host")
    private var activationChecks: [(badge: String, due: TimeInterval, key: String)] = []

    /// Bam's prompt answers deny, which WebKit remembers as an explicit denial; a remembered denial could answer the
    /// next phase's request without consulting the gesture. Back to unknown (never to granted), recorded per phase.
    private func resetOptionalPermission(_ context: WKWebExtensionContext, before phase: String) {
        let permission = WKWebExtension.Permission(rawValue: Self.optionalPermission)
        let before = context.permissionStatus(for: permission)
        context.setPermissionStatus(.unknown, for: permission)
        let after = context.permissionStatus(for: permission)
        observations["optional_permission_reset_before_\(phase)"] = ["from": before.rawValue, "to": after.rawValue,
                                                                     "granted_after": context.hasPermission(permission)]
    }
    private func ms() -> Int { Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()) }
    private func gestureNow() -> Bool? {
        guard let context = measuredContext, let tab = measuredTab else { return nil }
        return context.hasActiveUserGesture(in: tab)
    }

    private func begin(_ page: URL) {
        started = ProcessInfo.processInfo.systemUptime
        observations["scope"] = "original MV3 fixture on the loopback page; real Bam window, tab and sidebar action; ephemeral profile; no API permission granted (optional prompts denied); measurement only, no WebKit verdict"
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.budget - 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(complete: false, reason: "budget reached before every phase was measured") }
        }
        // Last resort if the main actor stalls: never outlive the budget.
        let hardLimit = Self.budget
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + hardLimit - 0.5) {
            print("MEASUREMENT incomplete: hard \(Int(hardLimit)) s limit; cleanup unconfirmed"); fflush(stdout); exit(1)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.run(page) } catch is CancellationError {} catch {
                self.finish(complete: false, reason: String(describing: error))
            }
        }
    }

    /// Samples the gesture, the per-tab badge (arrival signal) and due one-second-later samples.
    private func sample() {
        guard let context = measuredContext, let tab = measuredTab else { return }
        let gesture = context.hasActiveUserGesture(in: tab)
        if gesture != lastGesture { timeline.append(["t_ms": ms(), "active": gesture]); lastGesture = gesture }
        let badge = context.action(for: tab)?.badgeText ?? ""
        if badge != lastBadge {
            lastBadge = badge
            if !badge.isEmpty {
                arrivals.append(["badge": badge, "t_ms": ms(), "gesture_at_detection": gesture])
                delayed.append((badge, ProcessInfo.processInfo.systemUptime + 1))
                let now = ProcessInfo.processInfo.systemUptime
                activationChecks += [(badge, now, "host_world_activation_at_detection"), (badge, now + 1, "host_world_activation_after_1s"),
                                     (badge, now + 3, "host_world_activation_after_3s")]
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for item in delayed where item.due <= now {
            if let index = arrivals.lastIndex(where: { $0["badge"] as? String == item.badge }) { arrivals[index]["gesture_after_1s"] = gesture }
        }
        delayed.removeAll { $0.due <= now }
    }
    /// `navigator.userActivation` of the tab's main frame, read from the probe's own content world.
    private func hostWorldActivation() async -> Any {
        guard let id = tabID, let web = controller?.browsers[id] else { return "no tab" }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let value = try await web.evaluateJavaScript(
                "navigator.userActivation ? {isActive: navigator.userActivation.isActive, hasBeenActive: navigator.userActivation.hasBeenActive} : null",
                in: nil, contentWorld: hostWorld)
            var result: [String: Any] = (value as? [String: Any]) ?? ["unavailable": true]
            result["read_ms"] = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
            return result
        } catch { return "error: \(String(describing: error).prefix(200))" }
    }
    private func runActivationChecks() async {
        let now = ProcessInfo.processInfo.systemUptime
        let due = activationChecks.filter { $0.due <= now }
        activationChecks.removeAll { $0.due <= now }
        for check in due {
            let value = await hostWorldActivation()
            if let index = arrivals.lastIndex(where: { $0["badge"] as? String == check.badge }) { arrivals[index][check.key] = value }
        }
    }
    private func readPage() async {
        guard let id = tabID, let web = controller?.browsers[id],
              let text = try? await web.evaluateJavaScript("document.documentElement.dataset.bamGestureProbe || ''") as? String,
              let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        pageResults = value
    }
    /// The phase's page entry, classified; nil until something answered.
    private func reply(_ kind: String) -> ExtensionGestureProbeRules.Reply? {
        ExtensionGestureProbeRules.reply((pageResults["results"] as? [[String: Any]])?.first { $0["kind"] as? String == kind }, kind: kind)
    }
    /// Records the phase's verdict: measured only for a well-formed reply whose arrival was observed.
    @discardableResult private func record(_ phase: String, kind: String) -> Bool {
        let observed = Set(arrivals.compactMap { $0["badge"] as? String })
        let verdict = ExtensionGestureProbeRules.phaseVerdict(reply(kind), observedBadges: observed)
        phases[phase] = verdict
        return ExtensionGestureProbeRules.isMeasured(verdict)
    }
    /// Polls every 20 ms (page every 200 ms) until `done` holds or the deadline passes.
    private func poll(until deadline: TimeInterval, _ done: () -> Bool) async throws -> Bool {
        var tick = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            sample()
            if !activationChecks.isEmpty { await runActivationChecks() }
            if tick % 10 == 0 { await readPage() }
            tick += 1
            if done() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        sample(); await readPage()
        return done()
    }
    private func settle(_ seconds: TimeInterval) async throws {
        _ = try await poll(until: ProcessInfo.processInfo.systemUptime + seconds) { false }
    }

    private func run(_ page: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        // Runner identity invariant: only the canonical Bam Preview app runs this fixture.
        guard VendorProbeIsolation.allowsNormalMode(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            throw BrowserExtensions.failure("The gesture probe runs only in canonical Bam Preview (\(VendorProbeIsolation.canonicalPreviewBundleIdentifier))")
        }
        observations["bundle_identifier"] = Bundle.main.bundleIdentifier ?? ""
        guard ExtensionGestureProbeRules.isLoopback(page), let probePage = ExtensionGestureProbeRules.probeURL(page) else { throw BrowserExtensions.failure("The fixture page is not on loopback") }
        guard let toolbar = ExtensionGestureProbeRules.toolbarMode(env["BAM_GESTURE_TOOLBAR"]) else { throw BrowserExtensions.failure("BAM_GESTURE_TOOLBAR must be button, real or off") }
        let clickSeconds = ExtensionGestureProbeRules.clickSeconds(env["BAM_GESTURE_CLICK_SECONDS"])
        observations["toolbar_mode"] = toolbar.rawValue
        observations["click_wait_seconds"] = clickSeconds

        // Run-owned folder: the original package and the (unused, ephemeral) session path.
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("bam-gesture-probe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        runDirectory = directory
        let package = directory.appendingPathComponent("package", isDirectory: true)
        let matches = ExtensionGestureProbeRules.matchPatterns(for: page)
        try Self.writePackage(to: package, matches: matches)

        let home = BrowserTab(title: "Gesture probe", address: "orbit://newtab", space: 0)
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), ephemeral: true)
        browser.session = BrowserSession(tabs: [home], activeID: home.id)
        browser.automaticallyShowsVideo = false
        controller = browser
        let main = NSWindow(contentRect: NSRect(x: 140, y: 120, width: 900, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.title = "Bam gesture probe \(UUID().uuidString.prefix(8))"
        main.contentViewController = browser
        main.setContentSize(NSSize(width: 900, height: 640))
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window = main; main.makeKeyAndOrderFront(nil)
        browser.layoutBrowser(); browser.view.layoutSubtreeIfNeeded()
        observations["window_title"] = main.title

        let host = browser.browserExtensions
        host.onReloadNeeded = nil
        hostStorage = host.storageURL
        host.permissionPrompt = { [weak self] review in
            guard let self else { return false }
            let allowed = ExtensionGestureProbeRules.allowsInstall(permissions: review.permissions, unsupported: review.unsupported, websites: review.websites, isOptional: review.isOptional)
            self.prompts.append(["t_ms": self.ms(), "optional": review.isOptional, "permissions": review.permissions, "unsupported": review.unsupported,
                                 "websites": review.websites, "gesture_at_prompt": self.gestureNow() as Any, "answer": allowed ? "approved (install, loopback only)" : "denied"])
            return allowed
        }
        let profile = browser.session.currentProfileID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = browser.profileStores.store(for: profile)
        host.configure(configuration, profileID: profile)
        await host.ready(profileID: profile)
        let id = try await host.importPackage(at: package, profileID: profile)
        extensionID = id
        guard let context = host.context(for: id) else {
            throw BrowserExtensions.failure(host.errors[id] ?? host.lastError ?? "The fixture did not load an extension context")
        }
        observations["granted_permissions"] = context.grantedPermissions.keys.map(\.rawValue).sorted()
        observations["optional_permission_status_before"] = context.permissionStatus(for: WKWebExtension.Permission(rawValue: Self.optionalPermission)).rawValue
        phases["install"] = "done"

        guard let opened = browser.openProfileTab(probePage, profileID: profile, active: true) else { throw BrowserExtensions.failure("Could not open the loopback probe tab") }
        tabID = opened
        browser.select(opened); browser.refresh()
        let setupDeadline = started + 15
        guard try await poll(until: setupDeadline, { browser.browsers[opened]?.url == probePage && browser.browsers[opened]?.isLoading == false }) else {
            throw BrowserExtensions.failure("The loopback probe page did not load")
        }
        host.reconcile(); browser.refreshExtensionActions()
        let runtime = context.webExtensionController?.delegate as? BrowserExtensionRuntime
        guard try await poll(until: setupDeadline, { host.reconcile(); return runtime?.tabs[opened] != nil }), let tab = runtime?.tabs[opened] else {
            throw BrowserExtensions.failure("The probe tab has no extension tab adapter")
        }
        measuredContext = context; measuredTab = tab
        observations["gesture_at_page_load"] = context.hasActiveUserGesture(in: tab)

        // Baseline: the content script's message without any click.
        // A phase counts only with a well-formed worker reply for it and an observed arrival; failures are kept as such.
        _ = try await poll(until: setupDeadline) { self.reply("baseline") != nil }
        try await settle(1.1)
        guard record("baseline", kind: "baseline") else {
            throw BrowserExtensions.failure("Baseline not measured: \(phases["baseline"] ?? "no reply")")
        }

        // Real page click (root, pointer). The probe only waits. The earlier denial is reset first, so the click's
        // request is not answered by a remembered refusal instead of by its gesture state.
        resetOptionalPermission(context, before: "page_click")
        main.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        browser.select(opened)
        // Host-world reading before any click: the comparison point for the arrival readings.
        observations["host_world_activation_at_ready"] = await hostWorldActivation()
        // Arm the button only now: clicks before READY are counted, never relayed, so phase order holds.
        _ = try? await controller?.browsers[opened]?.evaluateJavaScript("document.documentElement.dataset.bamGestureArmed = '1'; true")
        print("EXTENSION_GESTURE_READY click \"Bam gesture probe\" in window \"\(main.title)\" within \(Int(clickSeconds)) s"); fflush(stdout)
        let clickDeadline = min(ProcessInfo.processInfo.systemUptime + clickSeconds, started + 47)
        let clicked = try await poll(until: clickDeadline) { self.reply("click") != nil }
        if clicked {
            try await settle(1.1)
            record("page_click", kind: "click")
        } else { phases["page_click"] = "no real click received" }

        // Toolbar: a fresh state first, so the click's gesture can't be credited to the toolbar.
        observations["gesture_before_toolbar_clear"] = context.hasActiveUserGesture(in: tab)
        context.clearUserGesture(in: tab)
        observations["gesture_after_clear"] = context.hasActiveUserGesture(in: tab)
        resetOptionalPermission(context, before: "toolbar")
        switch toolbar {
        case .off:
            phases["toolbar"] = "off"
        case .button, .real:
            browser.select(opened); host.reconcile(); browser.refreshExtensionActions()
            browser.layoutBrowser(); browser.view.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let button = descendants(browser.sidebar).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "extension-action-\(id.uuidString)" && !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled
            }
            observations["toolbar_button_visible"] = button != nil
            if toolbar == .button {
                guard let button else { phases["toolbar"] = "sidebar action button not found"; break }
                observations["toolbar_trigger"] = "AppKit performClick on the real sidebar action button (production performAction path; not a pointer event)"
                button.performClick(nil)
            } else {
                observations["toolbar_trigger"] = "real pointer click by root"
                print("EXTENSION_GESTURE_READY click the Bam gesture probe toolbar button in window \"\(main.title)\" within 8 s"); fflush(stdout)
            }
            // Ends with its 1.1 s settle before the 55 s watchdog.
            let toolbarDeadline = min(ProcessInfo.processInfo.systemUptime + (toolbar == .real ? 8 : 5), started + 52.5)
            let answered = try await poll(until: toolbarDeadline) { self.reply("toolbar") != nil }
            if answered {
                try await settle(1.1)
                record("toolbar", kind: "toolbar")
            } else { phases["toolbar"] = "no toolbar result" }
        }
        let requested = ["install", "baseline", "page_click"] + (toolbar == .off ? [] : ["toolbar"])
        let complete = requested.allSatisfy { phases[$0] == "done" || ExtensionGestureProbeRules.isMeasured(phases[$0]) }
        finish(complete: complete, reason: complete ? "every requested phase measured" : "phases: \(phases)")
    }

    // MARK: Finish, cleanup, output

    private func finish(complete: Bool, reason: String) {
        guard !finished else { return }
        finished = true
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        sample()
        observations["phases"] = phases
        observations["gesture_timeline"] = timeline
        observations["arrivals"] = arrivals
        observations["permission_prompts"] = prompts
        observations["page"] = pageResults
        if let context = measuredContext {
            observations["optional_permission_status_after"] = context.permissionStatus(for: WKWebExtension.Permission(rawValue: Self.optionalPermission)).rawValue
        }
        Task { @MainActor in
            let cleanup = await self.cleanUp()
            self.observations["cleanup"] = cleanup.report
            let ok = complete && cleanup.clean
            self.observations["measurement_complete"] = ok
            if let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(self.observations), options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("EXTENSION_GESTURE \(text)") }
            else { print("EXTENSION_GESTURE {\"measurement_complete\":false}") }
            let removalNote = cleanup.report["fixture_removed"] as? Bool == false
                ? "; explicit fixture removal unconfirmed (extensions were shut down and the owned temporary storage removed)" : ""
            print("MEASUREMENT \(ok ? "complete" : "incomplete"): \(reason)\(cleanup.clean ? "" : "; cleanup incomplete")\(removalNote)")
            fflush(stdout); exit(ok ? 0 : 1)
        }
    }
    /// Bounded (about 4 s): remove the fixture, close the window and controller, confirm the ephemeral host's
    /// temporary storage and the run folder are gone. Removes nothing outside those two paths.
    private func cleanUp() async -> (clean: Bool, report: [String: Any]) {
        var report: [String: Any] = [:]
        var clean = true
        measuredTab = nil; measuredContext = nil
        if let id = extensionID, let browser = controller {
            final class Outcome { var done = false; var error: String? }
            let outcome = Outcome()
            let removal = Task { @MainActor in
                do { try await browser.browserExtensions.remove(id: id) } catch { outcome.error = String(describing: error) }
                outcome.done = true
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !outcome.done, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if !outcome.done { removal.cancel(); report["fixture_removal_timed_out"] = true }
            if let error = outcome.error { report["fixture_removal_error"] = error }
            // Reported precisely, not assumed: the host no longer lists or loads the fixture. Not part of `clean`:
            // shutdown below unloads every context, and the owned temporary storage holding the package is removed and checked.
            let host = browser.browserExtensions
            report["fixture_removed"] = outcome.done && outcome.error == nil && host.context(for: id) == nil
                && !host.items(profileID: browser.session.currentProfileID).contains { $0.id == id }
        }
        controller?.prepareToClose(persistSession: false)
        window?.contentViewController = nil; window?.orderOut(nil); window?.close()
        controller = nil; window = nil
        let fm = FileManager.default
        if let storage = hostStorage {
            if storage.standardizedFileURL.path.hasPrefix(fm.temporaryDirectory.standardizedFileURL.path + "/") {
                if fm.fileExists(atPath: storage.path) { try? fm.removeItem(at: storage) }
                let gone = !fm.fileExists(atPath: storage.path)
                report["host_temporary_storage_removed"] = gone; clean = clean && gone
            } else {
                report["host_temporary_storage_removed"] = "not a temporary path; left untouched"; clean = false
            }
        } else {
            report["host_temporary_storage_removed"] = "no host was created"
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
