import AppKit
import WebKit

/// Measurement fixture, not a suite: with the parent page focused after a real keypress, can script focus an editable
/// element inside a child frame? One case per run (`BAM_FOCUS_CASE` = `<frame>:<pattern>`): frame `so` (same-origin),
/// `xo` (cross-origin, localhost vs 127.0.0.1) or `ex` (an original web-accessible extension page); pattern `p1` (child
/// focuses its input 17 ms after "show", the HUD pattern), `p2` (parent `iframe.focus()`, child focuses from its window
/// focus listener registered at load), `p3` (parent `iframe.focus()`, child 17 ms timer), `p4` (parent
/// `contentWindow.focus()`, child timer), or `c` (pointer-click positive control). Real keys and clicks are root's only.
/// Page-side evidence is passive and reaches the host only through a run-unique host-world script message handler; the
/// host evaluates no page JavaScript. Results are observations; nothing here attributes a cause to WebKit or Bam.
@available(macOS 15.4, *)
@MainActor final class ExtensionFocusProbe {
    private static var current: ExtensionFocusProbe?
    typealias Rules = ExtensionFocusProbeRules
    static let budget: TimeInterval = 60
    static let marker = "bam-focus-probe"
    static let stateAttribute = "data-bam-focus-probe"
    static let hostMessageName = "bamFocusProbeHost"

    static func start(pageURL: URL) {
        let probe = ExtensionFocusProbe()
        current = probe
        probe.begin(pageURL)
    }

    // MARK: Original package

    /// Shared by the content script (SO/XO children run it in their frame) and the extension child page (EX).
    /// Every listener is passive; the child acts only after the parent's validated hello and show.
    static let childLogic = #"""
    function bamFocusChild() {
      const q = new URLSearchParams(location.search);
      if (!q.has("bam-focus-child") || window.top === window || document.getElementById("bam-focus-input")) return;
      const run = q.get("run"), kase = q.get("case"), role = q.get("role"), parentOrigin = q.get("po");
      if (!run || !kase || !role || !parentOrigin) return;
      // Structure (BAM_FOCUS_STRUCTURE): the child only needs `editable` (focus target) and `channel` (MessageChannel port).
      const structure = new Set(String(q.get("st") || "").split(",").filter(Boolean));
      const editable = structure.has("editable"), channel = structure.has("channel");
      let seq = 0, pattern = null, armed = false, showAt = null, focusedOnce = false, port = null;
      const describe = (el) => !el ? null : (el.id ? el.tagName.toLowerCase() + "#" + el.id : el.tagName.toLowerCase());
      const activation = () => navigator.userActivation
        ? {isActive: navigator.userActivation.isActive, hasBeenActive: navigator.userActivation.hasBeenActive} : null;
      // The focus target: an input, or (editable) a plaintext-only contenteditable span like Vimium's HUD.
      const input = document.createElement(editable ? "span" : "input");
      const valueOf = () => String((editable ? input.textContent : input.value) || "");
      const state = () => ({hasFocus: document.hasFocus(), active: describe(document.activeElement),
                            activeIsInput: document.activeElement === input, activation: activation()});
      const send = (kind, fields) => {
        const message = {bamFocusProbe: 1, run, case: kase, role,
          record: Object.assign({kind, seq: ++seq, t: Math.round(performance.now()), wall: Date.now()}, fields || {})};
        try { if (port) port.postMessage(message); else window.parent.postMessage(message, parentOrigin); } catch (error) {}
      };
      input.id = "bam-focus-input";
      if (editable) {
        try { input.contentEditable = "plaintext-only"; } catch (error) { input.contentEditable = "true"; }
      } else { input.type = "text"; input.autocomplete = "off"; input.spellcheck = false; }
      input.setAttribute("aria-label", "Bam focus probe child input");
      input.style.cssText = "font:600 22px -apple-system,system-ui,sans-serif;padding:10px 14px;width:80%;margin:12px;border:2px solid #222;border-radius:8px";
      // After cssText (which would erase them): a span needs block geometry to be a usable focus/click target.
      if (editable) { input.style.display = "inline-block"; input.style.minWidth = "60%"; input.style.minHeight = "1.4em"; }
      const label = document.createElement("div");
      label.textContent = "Bam focus probe child (" + role + ")";
      label.style.cssText = "font:600 16px -apple-system,system-ui,sans-serif;margin:12px";
      (document.body || document.documentElement).append(label, input);
      const focusInput = (trigger) => {
        send("focus_attempt", Object.assign({trigger}, state()));
        try { input.focus(); } catch (error) { send("focus_error", {error: String((error && error.message) || error).slice(0, 200)}); }
      };
      const passive = {capture: true, passive: true};
      window.addEventListener("focus", (event) => {
        if (event.target !== window) return;
        send("window_focus", state());
        // P2: the first window focus after the handshake (the parent's iframe.focus() can deliver it before "show").
        if (armed && pattern === "p2" && !focusedOnce) { focusedOnce = true; focusInput("window-focus"); }
      }, passive);
      window.addEventListener("blur", (event) => { if (event.target === window) send("window_blur", state()); }, passive);
      input.addEventListener("focus", () => send("input_focus", state()), passive);
      input.addEventListener("blur", () => send("input_blur", state()), passive);
      window.addEventListener("keydown", (event) => send("keydown", {key: String(event.key).slice(0, 12), trusted: event.isTrusted === true,
                                                                      targetIsInput: event.target === input, hasFocus: document.hasFocus()}), passive);
      input.addEventListener("input", (event) => send("input", {value: valueOf().slice(0, 32), trusted: event.isTrusted === true}), passive);
      window.addEventListener("pointerdown", (event) => send("pointer", {trusted: event.isTrusted === true, onInput: event.target === input,
                                                                          activation: activation()}), passive);
      const show = () => {
        if (!armed || showAt !== null) return;
        showAt = performance.now();
        send("show", state());
        for (const after of \#(sampleDelays)) {
          setTimeout(() => send("sample", Object.assign({after_ms: after, actual_ms: Math.round(performance.now() - showAt)}, state())), after);
        }
        if (pattern === "p1" || pattern === "p3" || pattern === "p4") setTimeout(() => focusInput("timer-17ms"), 17);
      };
      const valid = (data) => data && data.bamFocusProbe === 1 && data.run === run && data.case === kase;
      window.addEventListener("message", (event) => {
        if (event.source !== window.parent || event.origin !== parentOrigin) return;
        const data = event.data;
        if (!valid(data)) return;
        if (data.type === "hello" && !armed) {
          // channel: take the transferred port from the validated parent hello; show then arrives only on that port.
          if (channel) {
            if (!event.ports || !event.ports[0]) return;
            port = event.ports[0];
            port.onmessage = (portEvent) => { if (valid(portEvent.data) && portEvent.data.type === "show") show(); };
          }
          pattern = String(data.pattern); armed = true;
          send("ready", Object.assign({pattern, channel: port !== null, targetEditable: input.isContentEditable === true}, state()));
        } else if (data.type === "show" && !channel) { show(); }
      });
      send("child_load", state());
    }
    """#

    /// The parent controller (main frame of the probe page only): builds the child, validates every child message by
    /// `event.source` and `event.origin` plus run/case/role, handshakes before arming, and acts on the trusted trigger key.
    static let parentLogic = #"""
    function bamFocusParent() {
      const q = new URLSearchParams(location.search);
      if (!q.has("\#(marker)") || window.top !== window || document.getElementById("bam-focus-child")) return;
      const run = q.get("run"), kase = q.get("case");
      const parts = String(kase || "").split(":"), role = parts[0], pattern = parts[1];
      if (!run || !["so", "xo", "ex"].includes(role) || !["p1", "p2", "p3", "p4", "c"].includes(pattern)) return;
      const parentOrigin = location.origin;
      // Structure (BAM_FOCUS_STRUCTURE, validated natively; the page only reads the known factor names it is given).
      const structureText = String(q.get("st") || "");
      const structure = new Set(structureText.split(",").filter(Boolean));
      const has = (factor) => structure.has(factor);
      const childQuery = "bam-focus-child=1&run=" + encodeURIComponent(run) + "&case=" + encodeURIComponent(kase) +
                         "&role=" + role + "&po=" + encodeURIComponent(parentOrigin) + "&st=" + encodeURIComponent(structureText);
      let childURL, childOrigin;
      if (role === "so") { childOrigin = parentOrigin; childURL = parentOrigin + location.pathname + "?" + childQuery; }
      else if (role === "xo") { const u = new URL(location.href); u.hostname = "localhost"; childOrigin = u.origin; childURL = childOrigin + location.pathname + "?" + childQuery; }
      else { const base = new URL(chrome.runtime.getURL("child.html")); childOrigin = base.protocol + "//" + base.host; childURL = base.href + "?" + childQuery; }
      const st = {run, case: kase, structure: structureText, childOrigin, armed: false, triggered: false, rejected: 0, records: []};
      let seq = 0;
      const publish = () => { document.documentElement.setAttribute("\#(stateAttribute)", JSON.stringify(st)); };
      const add = (frame, record) => {
        if (st.records.length >= \#(maximumRecords)) return;
        st.records.push(Object.assign({}, record, {frame, run, case: kase, role: frame === "parent" ? "parent" : role}));
        publish();
      };
      const describe = (el) => !el ? null : (el.id ? el.tagName.toLowerCase() + "#" + el.id : el.tagName.toLowerCase());
      const activation = () => navigator.userActivation
        ? {isActive: navigator.userActivation.isActive, hasBeenActive: navigator.userActivation.hasBeenActive} : null;
      const pstate = () => ({hasFocus: document.hasFocus(), active: describe(document.activeElement), activation: activation()});
      const local = (kind, fields) => add("parent", Object.assign({kind, seq: ++seq, t: Math.round(performance.now()), wall: Date.now()}, fields || {}));
      const area = document.createElement("div");
      area.id = "bam-focus-parent-area";
      area.textContent = "Bam focus probe PARENT (" + kase + ")";
      area.style.cssText = "font:600 22px -apple-system,system-ui,sans-serif;padding:28px;margin:12px;background:#eee;border:2px dashed #888;border-radius:10px";
      document.body.append(area);
      // Container: the body, or (shadow) an open shadow root on a wrapper appended to documentElement, as Vimium's UIComponent.
      let container = document.body, styleHost = document.head || document.documentElement, wrapper = null;
      if (has("shadow")) {
        wrapper = document.createElement("div");
        wrapper.id = "bam-focus-shadow-wrapper";
        const shadow = wrapper.attachShadow({mode: "open"});
        document.documentElement.appendChild(wrapper);
        container = shadow; styleHost = shadow;
      }
      let frame = null, parentPort = null, shown = false, suppressing = false, readySeen = false;
      const ports = new Set();
      const bool = (value) => (typeof value === "boolean" ? value : null);
      const childRecord = (data) => {
        if (!data || data.bamFocusProbe !== 1 || data.run !== run || data.case !== kase || data.role !== role ||
            !data.record || typeof data.record !== "object") { st.rejected += 1; publish(); return; }
        const clean = {};
        for (const [name, value] of Object.entries(data.record).slice(0, 16)) {
          if (typeof value === "string") clean[name] = value.slice(0, 64);
          else if (typeof value === "number" || typeof value === "boolean" || value === null) clean[name] = value;
          else if (name === "activation" && value && typeof value === "object")
            clean[name] = {isActive: bool(value.isActive), hasBeenActive: bool(value.hasBeenActive)};
        }
        add("child", clean);
        if (clean.kind === "input_focus") suppressing = false;
        if (clean.kind === "ready") {
          readySeen = true;
          if (!has("lazy") && !st.armed) { st.armed = true; local("armed", pstate()); }
          if (has("lazy") && st.triggered && !shown) performShow();
        }
      };
      window.addEventListener("message", (event) => {
        const data = event.data;
        if (!frame || event.source !== frame.contentWindow || event.origin !== childOrigin) {
          if (data && data.bamFocusProbe === 1) { st.rejected += 1; publish(); }
          return;
        }
        childRecord(data);
      });
      let helloTries = 0;
      const hello = () => {
        if (readySeen || helloTries >= 40 || !frame) return;
        helloTries += 1;
        const message = {bamFocusProbe: 1, run, case: kase, type: "hello", pattern};
        try {
          if (has("channel")) {
            // A fresh channel per attempt; only ports this parent created are listened to.
            const mc = new MessageChannel();
            ports.add(mc.port1);
            mc.port1.onmessage = (event) => { parentPort = mc.port1; childRecord(event.data); };
            frame.contentWindow.postMessage(message, childOrigin, [mc.port2]);
          } else frame.contentWindow.postMessage(message, childOrigin);
          if (helloTries === 1) local("hello_sent", {channel: has("channel")});
        } catch (error) {}
        setTimeout(hello, 250);
      };
      const createFrame = () => {
        // hidden: created with the frame, as Vimium's UIComponent.load: `iframe{display:none}` first, class CSS shortly
        // after (Vimium fetches it from storage); the frame is shown by class toggle right after "show" is posted.
        if (has("hidden")) {
          const style = document.createElement("style");
          style.textContent = "iframe {display: none;}";
          styleHost.appendChild(style);
          setTimeout(() => {
            style.textContent = "iframe.bam-hidden {display: none;} iframe.bam-visible {display: block;}";
            local("style_loaded", {});
          }, 10);
        }
        frame = document.createElement("iframe");
        frame.id = "bam-focus-child"; frame.title = "Bam focus probe child";
        if (has("allow")) frame.allow = "clipboard-read; clipboard-write";
        if (has("hidden")) frame.className = "bam-hidden";
        frame.style.cssText = "width:90%;height:170px;border:3px solid #36c;margin:12px;border-radius:8px";
        frame.src = childURL;
        frame.addEventListener("load", () => { local("child_load", {}); setTimeout(hello, 50); });
        container.appendChild(frame);
        local("frame_created", {lazy: has("lazy"), inShadow: frame.getRootNode() !== document,
                                wrapperParent: wrapper && wrapper.parentNode ? wrapper.parentNode.nodeName.toLowerCase() : null,
                                allow: frame.getAttribute("allow"), className: frame.className});
      };
      const performShow = () => {
        if (shown || !frame) return;
        shown = true;
        const message = {bamFocusProbe: 1, run, case: kase, type: "show"};
        if (has("channel") && parentPort) parentPort.postMessage(message); else frame.contentWindow.postMessage(message, childOrigin);
        const displayBefore = getComputedStyle(frame).display;
        if (has("hidden")) { frame.classList.remove("bam-hidden"); frame.classList.add("bam-visible"); }
        const frameDisplay = getComputedStyle(frame).display;
        const shownAt = performance.now();
        let focusCall = "none", focusError = null;
        try {
          if (pattern === "p2" || pattern === "p3") { focusCall = "iframe.focus"; frame.focus(); }
          else if (pattern === "p4") { focusCall = "contentWindow.focus"; frame.contentWindow.focus(); }
        } catch (error) { focusError = String((error && error.message) || error).slice(0, 200); }
        local("show_sent", Object.assign({pattern, focusCall, focusError, via: has("channel") && parentPort ? "port" : "window",
                                          displayBefore, frameDisplay}, pstate()));
        for (const after of \#(sampleDelays)) {
          setTimeout(() => local("sample", Object.assign({after_ms: after, actual_ms: Math.round(performance.now() - shownAt)}, pstate())), after);
        }
      };
      if (has("lazy")) { st.armed = true; local("armed", Object.assign({lazy: true}, pstate())); }
      else createFrame();
      const passive = {capture: true, passive: true};
      window.addEventListener("focus", (event) => { if (event.target === window) local("window_focus", pstate()); }, passive);
      window.addEventListener("blur", (event) => { if (event.target === window) local("window_blur", pstate()); }, passive);
      window.addEventListener("pointerdown", (event) => local("pointer", Object.assign({trusted: event.isTrusted === true, target: describe(event.target)}, pstate())), passive);
      // Recording listener first (passive), so every parent key is recorded before any suppression below.
      window.addEventListener("keydown", (event) => {
        local("keydown", Object.assign({key: String(event.key).slice(0, 12), trusted: event.isTrusted === true, target: describe(event.target)}, pstate()));
      }, passive);
      window.addEventListener("keydown", (event) => {
        const trusted = event.isTrusted === true, key = String(event.key).slice(0, 12);
        if (suppressing) { event.preventDefault(); event.stopImmediatePropagation(); return; }
        if (!st.armed || st.triggered || !trusted || pattern === "c" || key.toLowerCase() !== "\#(triggerKey)") return;
        st.triggered = true;
        if (has("suppress")) { event.preventDefault(); event.stopImmediatePropagation(); suppressing = true; }
        local("trigger", Object.assign({key: "\#(triggerKey)", trusted, suppressed: event.defaultPrevented === true}, pstate()));
        if (has("lazy")) createFrame(); else performShow();
      }, {capture: true});
      publish();
    }
    """#
    static var sampleDelays: String { "[" + Rules.sampleDelaysMilliseconds.map(String.init).joined(separator: ", ") + "]" }
    static var maximumRecords: Int { Rules.maximumRecords }
    static var triggerKey: String { Rules.triggerKey }
    static var contentScript: String { childLogic + "\n" + parentLogic + "\nbamFocusChild();\nbamFocusParent();\n" }
    static var childPage: String {
        #"<!doctype html><meta charset="utf-8"><title>Bam focus probe child</title><body><script src="child.js"></script></body>"#
    }
    static var childScript: String { childLogic + "\nbamFocusChild();\n" }

    /// Passive host-world observer in a run-unique world (main frame of the probe page only): forwards the parent's
    /// published state on every change. It never dispatches, focuses, prevents or writes.
    static let hostScript = #"""
    (() => {
      if (!new URLSearchParams(location.search).has("\#(marker)")) return;
      const handler = globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\#(hostMessageName);
      if (!handler) return;
      const post = (event, extra) => {
        try { handler.postMessage(Object.assign({event, wall: Date.now(), perf: Math.round(performance.now())}, extra || {})); } catch (error) {}
      };
      const report = () => post("state", {state: (document.documentElement.getAttribute("\#(stateAttribute)") || "").slice(0, 200000)});
      new MutationObserver(report).observe(document.documentElement, {attributes: true, attributeFilter: ["\#(stateAttribute)"]});
      post("ready", {});
    })();
    """#

    static func manifest() -> [String: Any] {
        ["manifest_version": 3, "name": "Bam focus probe fixture", "version": "1.0",
         "description": "Original fixture: measures keyboard focus into same-origin, cross-origin and extension child frames",
         "content_scripts": [["matches": ["http://127.0.0.1/*", "http://localhost/*"], "js": ["content.js"], "all_frames": true, "run_at": "document_idle"]],
         "web_accessible_resources": [["resources": ["child.html", "child.js"], "matches": ["http://127.0.0.1/*"]]]]
    }
    static func writePackage(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: manifest(), options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("manifest.json"))
        try Data(contentScript.utf8).write(to: folder.appendingPathComponent("content.js"))
        try Data(childPage.utf8).write(to: folder.appendingPathComponent("child.html"))
        try Data(childScript.utf8).write(to: folder.appendingPathComponent("child.js"))
    }

    // MARK: Run state

    private var started = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var observations: [String: Any] = [:]
    private var prompts: [[String: Any]] = []
    private var runDirectory: URL?
    private var controller: BrowserController?
    private var window: NSWindow?
    private var extensionID: UUID?
    private var hostStorage: URL?
    private var tabID: UUID?
    private var probeCase: Rules.Case?
    private var structure: Set<Rules.Factor> = []
    private let runToken = UUID().uuidString
    private let hostWorld = WKContentWorld.world(name: "bam-focus-probe-host-\(UUID().uuidString)")
    private weak var observedContent: WKUserContentController?
    private var messageProxy: HostMessages?
    private var hostReady = false
    private var rejectedHostMessages = 0
    private var probePageURL: URL?
    private var pageState: [String: Any] = [:]
    /// Native phase in which each page record (`frame:seq`) was first seen: the phase ledger.
    private var ledger = Rules.PhaseLedger()
    private var currentPhase = "setup"
    private var responders: [[String: Any]] = []
    private final class HostMessages: NSObject, WKScriptMessageHandler {
        weak var owner: ExtensionFocusProbe?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
    }
    private func ms() -> Int { Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()) }

    /// This run's world, main frame, probe tab and exact probe URL, bounded shape; evidence only, nothing is granted.
    private func receive(_ message: WKScriptMessage) {
        guard message.world == hostWorld, message.frameInfo.isMainFrame, let id = tabID, message.webView === controller?.browsers[id],
              let expected = probePageURL, message.frameInfo.request.url?.absoluteString == expected.absoluteString,
              let body = message.body as? [String: Any], body.count <= 6, let event = body["event"] as? String, ["ready", "state"].contains(event),
              body["perf"] is NSNumber, body["wall"] is NSNumber else { rejectedHostMessages += 1; return }
        if event == "ready" { hostReady = true; return }
        guard let text = body["state"] as? String, text.utf8.count <= 200_000, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { rejectedHostMessages += 1; return }
        pageState = value
        // Only records validated for this run, case and role enter the cumulative, capped phase ledger; faults persist.
        guard let probeCase else { return }
        ledger.ingest(state: value, run: runToken, case: probeCase, phase: currentPhase)
    }
    private func records() -> [Rules.Record] {
        guard let probeCase else { return [] }
        return Rules.records(fromState: pageState, run: runToken, case: probeCase, firstSeen: ledger.firstSeen).records
    }
    private func has(_ frame: String, _ kind: String, phase: String? = nil, _ extra: (Rules.Record) -> Bool = { _ in true }) -> Bool {
        records().contains { $0.frame == frame && $0.kind == kind && (phase == nil || $0.hostPhase == phase) && extra($0) }
    }
    /// The key window and the native first responder (class, and whether it is the tab's web view or inside it); a
    /// legitimate text-input subview of the web view counts as inside it, not as a mismatch.
    private func snapshotResponder(_ label: String) {
        var entry: [String: Any] = ["at": label, "t_ms": ms(), "phase": currentPhase]
        let key = NSApp.keyWindow
        entry["key_window_is_probe"] = key != nil && key === window
        let responder = window?.firstResponder
        entry["first_responder_class"] = responder.map { String(describing: type(of: $0)) } ?? "none"
        if let id = tabID, let web = controller?.browsers[id], let view = responder as? NSView {
            entry["first_responder_is_tab_web_view"] = view === web
            entry["first_responder_inside_tab_web_view"] = view === web || view.isDescendant(of: web)
        } else { entry["first_responder_inside_tab_web_view"] = false }
        responders.append(entry)
    }
    private func poll(until deadline: TimeInterval, _ done: () -> Bool) async throws -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if done() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return done()
    }

    private func begin(_ page: URL) {
        started = ProcessInfo.processInfo.systemUptime
        observations["scope"] = "original MV3 fixture (content script and one web-accessible child page; no API permissions) on the loopback page; real Bam window and tab; ephemeral profile; passive page observation through a run-unique host-world script message handler; no page JavaScript evaluated by the host; measurement only, no WebKit or Bam root-cause attribution"
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.budget - 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(reason: "budget reached before every required record was observed") }
        }
        let hardLimit = Self.budget
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + hardLimit - 0.5) {
            print("MEASUREMENT incomplete: hard \(Int(hardLimit)) s limit; cleanup unconfirmed"); fflush(stdout); exit(1)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.run(page) } catch is CancellationError {} catch { self.finish(reason: String(describing: error)) }
        }
    }

    private func run(_ page: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        guard VendorProbeIsolation.allowsNormalMode(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            throw BrowserExtensions.failure("The focus probe runs only in canonical Bam Preview (\(VendorProbeIsolation.canonicalPreviewBundleIdentifier))")
        }
        observations["bundle_identifier"] = Bundle.main.bundleIdentifier ?? ""
        guard let probeCase = Rules.parseCase(env["BAM_FOCUS_CASE"]) else {
            throw BrowserExtensions.failure("Set BAM_FOCUS_CASE to <so|xo|ex>:<p1|p2|p3|p4|c>, one case per run")
        }
        self.probeCase = probeCase
        guard let structure = Rules.parseStructure(env["BAM_FOCUS_STRUCTURE"]) else {
            throw BrowserExtensions.failure("BAM_FOCUS_STRUCTURE must be none, vimium, vimium-minus-<factor> or a comma list of " +
                                            Rules.Factor.allCases.map(\.rawValue).joined(separator: "/"))
        }
        if let refusal = Rules.combinationRefusal(probeCase, structure) { throw BrowserExtensions.failure(refusal) }
        self.structure = structure
        observations["case"] = probeCase.label
        observations["structure"] = Rules.structureLabel(structure)
        observations["run"] = runToken
        // The cross-origin child is http://localhost on the same server, so the parent must be http://127.0.0.1.
        guard page.scheme == "http", page.host == "127.0.0.1", page.user == nil, page.password == nil,
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            throw BrowserExtensions.failure("The focus probe needs the loopback fixture server at http://127.0.0.1")
        }
        components.queryItems = [URLQueryItem(name: Self.marker, value: "1"), URLQueryItem(name: "run", value: runToken),
                                 URLQueryItem(name: "case", value: probeCase.label),
                                 URLQueryItem(name: "st", value: Rules.sortedFactors(structure).map(\.rawValue).joined(separator: ","))]
        components.fragment = nil
        guard let probePage = components.url else { throw BrowserExtensions.failure("Could not build the probe page URL") }
        observations["protocol"] = ["trigger_key": Rules.triggerKey, "typed_text": Rules.typedText, "sample_offsets_ms": Rules.sampleDelaysMilliseconds,
                                    "child_timer_ms": 17, "native_phases": "setup → \(probeCase.pattern == .c ? "pointer" : "trigger") → typing → finish",
                                    "page_evaluation_by_host": "none", "budget_s": Self.budget]

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("bam-focus-probe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        runDirectory = directory
        let package = directory.appendingPathComponent("package", isDirectory: true)
        try Self.writePackage(to: package)

        let home = BrowserTab(title: "Focus probe", address: "orbit://newtab", space: 0)
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), ephemeral: true)
        browser.session = BrowserSession(tabs: [home], activeID: home.id)
        // Bam's own automatic page evaluations are off before any page loads (property sets; nothing written to preferences).
        browser.automaticallyShowsVideo = false
        browser.documentFaviconDiscoveryEnabled = false
        browser.automaticTabSleeping = false
        observations["host_automatic_page_evaluations"] = ["favicon_document_discovery": "disabled", "tab_sleep_activity_inspection": "disabled",
                                                           "automatic_playing_video_pip": "disabled"]
        controller = browser
        let main = NSWindow(contentRect: NSRect(x: 140, y: 120, width: 900, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.title = "Bam focus probe \(probeCase.label) \(runToken.prefix(8))"
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
            let allowed = ExtensionGestureProbeRules.allowsInstall(permissions: review.permissions, unsupported: review.unsupported,
                                                                   websites: review.websites, isOptional: review.isOptional)
            self?.prompts.append(["optional": review.isOptional, "permissions": review.permissions, "unsupported": review.unsupported,
                                  "websites": review.websites, "answer": allowed ? "approved (install, loopback only)" : "denied"])
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

        // The plain page first (no marker: the content script stays inert), then the observer, then the probe page.
        guard let opened = browser.openProfileTab(page, profileID: profile, active: true) else { throw BrowserExtensions.failure("Could not open the loopback tab") }
        tabID = opened
        browser.select(opened); browser.refresh()
        let setupDeadline = started + 15
        guard try await poll(until: setupDeadline, { browser.browsers[opened]?.url == page && browser.browsers[opened]?.isLoading == false }),
              let web = browser.browsers[opened] else { throw BrowserExtensions.failure("The loopback fixture page did not load") }
        let content = web.configuration.userContentController
        let proxy = HostMessages(); proxy.owner = self; messageProxy = proxy; observedContent = content
        content.add(proxy, contentWorld: hostWorld, name: Self.hostMessageName)
        content.addUserScript(WKUserScript(source: Self.hostScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: hostWorld))
        probePageURL = probePage
        browser.navigatePane(opened, address: probePage.absoluteString)

        // Handshake before READY: the child's ready acknowledgement and the parent's armed record, both preloaded. With
        // `lazy` the child is created by the trigger, so only the parent's armed record precedes READY.
        let lazy = structure.contains(.lazy)
        guard try await poll(until: setupDeadline, { self.hostReady && (lazy || self.has("child", "ready")) && self.has("parent", "armed") }) else {
            throw BrowserExtensions.failure(hostReady ? "The child frame did not complete the handshake (\(probeCase.frame.rawValue) child)"
                                                      : "The passive host-world observer did not report from the probe page")
        }
        main.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); browser.select(opened)
        snapshotResponder("ready")

        if probeCase.pattern == .c {
            currentPhase = "pointer"
            print("EXTENSION_FOCUS_READY click inside the blue-framed child input box in window \"\(main.title)\" within 25 s"); fflush(stdout)
            _ = try await poll(until: min(ProcessInfo.processInfo.systemUptime + 25, started + 40)) {
                self.has("child", "pointer", phase: "pointer") { $0.bool("trusted") == true && $0.bool("onInput") == true }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        } else {
            currentPhase = "trigger"
            print("EXTENSION_FOCUS_READY click the grey PARENT box once, then press the f key, in window \"\(main.title)\" within 25 s"); fflush(stdout)
            let triggered = try await poll(until: min(ProcessInfo.processInfo.systemUptime + 25, started + 40)) {
                self.has("parent", "trigger", phase: "trigger") { $0.bool("trusted") == true }
            }
            if triggered {
                // Every scheduled reading in both frames arrives before typing is requested (lazy adds the child's load and
                // handshake before "show").
                let count = Rules.sampleDelaysMilliseconds.count
                _ = try await poll(until: min(ProcessInfo.processInfo.systemUptime + (lazy ? 6 : 2.5), started + 46)) {
                    let samples = self.records().filter { $0.kind == "sample" && $0.hostPhase == "trigger" }
                    return samples.filter { $0.frame == "child" }.count >= count && samples.filter { $0.frame == "parent" }.count >= count
                }
            }
        }
        snapshotResponder("before_typing")
        currentPhase = "typing"
        print("EXTENSION_FOCUS_READY type \(Rules.typedText) now (do not click first) in window \"\(main.title)\" within 12 s"); fflush(stdout)
        _ = try await poll(until: min(ProcessInfo.processInfo.systemUptime + 12, started + 52)) {
            let typed = self.records().filter { $0.kind == "keydown" && $0.hostPhase == "typing" && $0.bool("trusted") == true }
                .compactMap { $0.string("key")?.lowercased() }
            return Rules.typedKeys.allSatisfy(typed.contains)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        snapshotResponder("after_typing")
        currentPhase = "finish"
        finish(reason: nil)
    }

    // MARK: Finish, cleanup, output

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        var problems: [String] = []
        if let probeCase {
            let parsed = Rules.records(fromState: pageState, run: runToken, case: probeCase, firstSeen: ledger.firstSeen)
            let evaluation = Rules.evaluate(parsed.records, case: probeCase, structure: structure)
            problems = evaluation.problems
            if parsed.malformed > 0 { problems.append("\(parsed.malformed) malformed page records") }
            // Ledger faults from any snapshot during the run are permanent and make the measurement incomplete.
            problems += ledger.faults.map { "phase ledger: \($0)" }
            observations["phase_ledger_entries"] = ledger.firstSeen.count
            observations["outcome"] = evaluation.outcome
            observations["records"] = parsed.records.map { record -> [String: Any] in
                record.fields.merging(["host_phase": record.hostPhase ?? "unseen"]) { _, new in new }
            }
            observations["page_rejected_messages"] = pageState["rejected"] ?? NSNull()
        } else { problems.append("no case") }
        if let reason { problems.insert(reason, at: 0) }
        if rejectedHostMessages > 0 { problems.append("\(rejectedHostMessages) host messages rejected") }
        // Assigned only after every validation step, so the JSON lists every reason the summary line uses.
        observations["problems"] = problems
        observations["native_responders"] = responders
        observations["permission_prompts"] = prompts
        observations["host_messages_rejected"] = rejectedHostMessages
        observations["host_world_ready"] = hostReady
        let measured = problems.isEmpty
        Task { @MainActor in
            let cleanup = await self.cleanUp()
            self.observations["cleanup"] = cleanup.report
            let ok = measured && cleanup.clean
            self.observations["measurement_complete"] = ok
            if let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(self.observations), options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("EXTENSION_FOCUS \(text)") }
            else { print("EXTENSION_FOCUS {\"measurement_complete\":false}") }
            let summary = ok ? "every required record observed (the outcome may be negative; see outcome)" : problems.prefix(8).joined(separator: "; ")
            print("MEASUREMENT \(ok ? "complete" : "incomplete"): \(summary)\(cleanup.clean ? "" : "; cleanup incomplete")")
            fflush(stdout); exit(ok ? 0 : 1)
        }
    }
    /// Bounded (about 4 s): remove the fixture, close the window and controller, confirm the ephemeral host's temporary
    /// storage and the run folder are gone. Removes nothing outside those two paths.
    private func cleanUp() async -> (clean: Bool, report: [String: Any]) {
        var report: [String: Any] = [:]
        var clean = true
        if let content = observedContent {
            content.removeScriptMessageHandler(forName: Self.hostMessageName, contentWorld: hostWorld)
            report["host_message_handler_removed"] = true
        }
        messageProxy?.owner = nil; messageProxy = nil
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
            } else { report["host_temporary_storage_removed"] = "not a temporary path; left untouched"; clean = false }
        } else { report["host_temporary_storage_removed"] = "no host was created" }
        if let directory = runDirectory {
            if fm.fileExists(atPath: directory.path) { try? fm.removeItem(at: directory) }
            let gone = !fm.fileExists(atPath: directory.path)
            report["run_directory_removed"] = gone; clean = clean && gone
        }
        // Confirmed fixture removal is required too (no timeout, no error, no longer listed or loaded).
        let confirmed = Rules.cleanupIsClean(report, fixtureInstalled: extensionID != nil)
        report["clean_requires"] = "temporary storage and run folder removed, and confirmed fixture removal"
        return (clean && confirmed, report)
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
