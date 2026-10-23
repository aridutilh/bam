import AppKit
import WebKit
import QuartzCore

/// Ark's own feature: a floating panel rehosts the existing web view and
/// reversibly isolates its HTML5 video. This is not recovered Arc code or AVKit PiP.
@MainActor final class PictureInPictureCoordinator: NSObject, NSWindowDelegate {
    private(set) var activeTabID: UUID?
    var referencedTabID: UUID? { activeTabID ?? pendingTabID }
    var onChange: (() -> Void)?
    /// Explicit user intent only; silent restore/navigation never selects a tab.
    var onReturnToTab: ((UUID) -> Void)?
    private var webView: WKWebView?
    private var pendingWebView: WKWebView?
    private var pendingTabID: UUID?
    private var pendingCompletion: ((Bool) -> Void)?
    private var panel: ArkVideoPanel?
    private var chrome: PiPOverlayView?
    private var mediaTimer: Timer?
    private var pollingToken: UUID?
    private var restorationTokens: [ObjectIdentifier: UUID] = [:]
    private var restorationAlphas: [ObjectIdentifier: CGFloat] = [:]
    private var originalAlpha: CGFloat = 1
    private var restoreView: ((WKWebView) -> Void)?
    private var reportMessage: ((String) -> Void)?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var requestID = UUID()
    private var originalAutoresizing: NSView.AutoresizingMask = []
    private let world = WKContentWorld.world(name: "OrbitPictureInPicture")

    func owns(_ web: WKWebView) -> Bool { webView === web }
    func references(_ web: WKWebView) -> Bool { webView === web || pendingWebView === web }

    func toggle(web: WKWebView, tabID: UUID, restore: @escaping (WKWebView) -> Void, report: @escaping (String) -> Void) {
        if references(web) { self.restore(); return }
        self.restore()
        begin(web: web, tabID: tabID, automatic: false, shouldPresent: { true }, restore: restore, report: report)
    }

    /// Called when leaving a tab. The caller's guard must still allow departure
    /// when asynchronous video discovery returns. A busy PiP is never replaced.
    func automaticallyPresentIfPlaying(web: WKWebView, tabID: UUID, shouldPresent: @escaping () -> Bool, restore: @escaping (WKWebView) -> Void, completion: ((Bool) -> Void)? = nil) {
        guard webView == nil, pendingWebView == nil else { complete(completion, presented: false); return }
        begin(web: web, tabID: tabID, automatic: true, shouldPresent: shouldPresent, restore: restore, report: nil, completion: completion)
    }

    private func begin(web: WKWebView, tabID: UUID, automatic: Bool, shouldPresent: @escaping () -> Bool, restore: @escaping (WKWebView) -> Void, report: ((String) -> Void)?, completion: ((Bool) -> Void)? = nil) {
        guard shouldPresent() else { complete(completion, presented: false); return }
        let identity = ObjectIdentifier(web)
        if let alpha = restorationAlphas.removeValue(forKey: identity) { web.alphaValue = alpha }
        restorationTokens.removeValue(forKey: identity)
        web.layer?.removeAnimation(forKey: "ArkPiPRestoreOpacity")
        let token = UUID()
        requestID = token
        pendingWebView = web
        pendingTabID = tabID
        pendingCompletion = completion
        let startingURL = web.url
        let wasLoading = web.isLoading
        observeNavigation(web, token: token, originalURL: startingURL, report: report)
        let script = Self.isolationScript
            .replacingOccurrences(of: "__ORBIT_TOKEN__", with: token.uuidString)
            .replacingOccurrences(of: "__ORBIT_REQUIRE_PLAYING__", with: automatic ? "true" : "false")
            .replacingOccurrences(of: "__ORBIT_RESTORE_FOCUS__", with: automatic ? "false" : "true")
        web.evaluateJavaScript(script, in: nil, in: world) { [weak self, weak web] result in
            guard let self, let web else { return }
            guard self.requestID == token else { self.removeIsolation(from: web, token: token); return }
            guard shouldPresent(), self.requestID == token else { self.cancelPending(web, token: token); return }
            guard web.url == startingURL, wasLoading || !web.isLoading else {
                self.cancelPending(web, token: token)
                report?("The page changed. Try Picture in Picture again.")
                return
            }
            switch result {
            case .failure:
                self.cancelPending(web, token: token)
                report?("Could not access a video on this page.")
            case .success(let value):
                guard let info = value as? [String: Any], info["found"] as? Bool == true,
                      !automatic || info["playing"] as? Bool == true else {
                    self.cancelPending(web, token: token)
                    report?("No HTML5 video found. Videos inside other sites’ embedded frames may be inaccessible.")
                    return
                }
                self.pendingWebView = nil
                self.pendingTabID = nil
                let completion = self.pendingCompletion
                self.pendingCompletion = nil
                self.present(web: web, tabID: tabID, automatic: automatic,
                             width: (info["width"] as? NSNumber)?.doubleValue ?? 16,
                             height: (info["height"] as? NSNumber)?.doubleValue ?? 9,
                             restore: restore, report: report)
                // The same media element remains alive. Only resume playback
                // that was active when isolation began, if reparenting paused it.
                let resume = "if (globalThis.__orbitPiPState?.token === '\(token.uuidString)') globalThis.__orbitPiPState.resumeIfNeeded(); undefined"
                web.evaluateJavaScript(resume, in: nil, in: self.world) { _ in }
                self.complete(completion, presented: true)
            }
        }
    }

    private func complete(_ callback: ((Bool) -> Void)?, presented: Bool) {
        guard let callback else { return }
        // Deliver once after the state change, avoiding reentrant fallback
        // requests during restore() or an explicit manual toggle.
        DispatchQueue.main.async { callback(presented) }
    }

    private func cancelPending(_ web: WKWebView, token: UUID) {
        var completion: ((Bool) -> Void)?
        if requestID == token {
            requestID = UUID()
            pendingWebView = nil
            pendingTabID = nil
            completion = pendingCompletion
            pendingCompletion = nil
            urlObservation = nil
            loadingObservation = nil
        }
        removeIsolation(from: web, token: token)
        complete(completion, presented: false)
    }

    func returnToTab() {
        guard let id = activeTabID else { restore(); return }
        restore()
        onReturnToTab?(id)
    }

    func restore() {
        let oldToken = requestID
        let completion = pendingCompletion
        pendingCompletion = nil
        requestID = UUID()
        urlObservation = nil
        loadingObservation = nil
        pendingTabID = nil
        mediaTimer?.invalidate(); mediaTimer = nil; pollingToken = nil
        if let pending = pendingWebView {
            pendingWebView = nil
            removeIsolation(from: pending, token: oldToken)
        }
        guard let web = webView else { complete(completion, presented: false); return }
        let callback = restoreView
        let oldPanel = panel
        let identity = ObjectIdentifier(web)
        let alpha = originalAlpha
        webView = nil
        activeTabID = nil
        panel = nil
        chrome?.stop(); chrome = nil
        restoreView = nil
        reportMessage = nil
        // Ownership transfers synchronously. Hide only this view until its
        // isolated DOM has been restored, so a fullscreen video cannot flash
        // across the destination page during the asynchronous JavaScript reply.
        restorationTokens[identity] = oldToken
        restorationAlphas[identity] = alpha
        web.alphaValue = 0
        web.removeFromSuperview()
        web.autoresizingMask = originalAutoresizing
        oldPanel?.delegate = nil
        oldPanel?.onEscape = nil
        oldPanel?.overlay = nil
        oldPanel?.orderOut(nil)
        oldPanel?.close()
        callback?(web)
        onChange?()
        removeIsolation(from: web, token: oldToken) { [weak self, weak web] in
            guard let self, let web, self.restorationTokens[identity] == oldToken else { return }
            self.restorationTokens.removeValue(forKey: identity)
            self.restorationAlphas.removeValue(forKey: identity)
            guard !self.references(web) else { return }
            web.alphaValue = alpha
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = web.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = alpha; fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "ArkPiPRestoreOpacity")
            }
        }
        complete(completion, presented: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { restore(); return false }

    private func observeNavigation(_ web: WKWebView, token: UUID, originalURL: URL?, report: ((String) -> Void)?) {
        let changed: () -> Void = { [weak self, weak web] in
            guard let self, let web, self.requestID == token, self.references(web) else { return }
            self.restore()
            report?("Video returned to its tab because the page changed.")
        }
        urlObservation = web.observe(\.url, options: [.new]) { changedWeb, _ in
            if changedWeb.url != originalURL { DispatchQueue.main.async(execute: changed) }
        }
        // URL observation alone misses a reload to the same address.
        loadingObservation = web.observe(\.isLoading, options: [.new]) { changedWeb, _ in
            if changedWeb.isLoading { DispatchQueue.main.async(execute: changed) }
        }
    }

    private func present(web: WKWebView, tabID: UUID, automatic: Bool, width: Double, height: Double,
                         restore: @escaping (WKWebView) -> Void, report: ((String) -> Void)?) {
        let screen = web.window?.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let measured = width > 0 && height > 0 ? width / height : 16.0 / 9.0
        let ratio = CGFloat(min(4, max(0.25, measured.isFinite ? measured : 16.0 / 9.0)))
        let panelWidth = min(480, min(bounds.width * 0.48, bounds.height * 0.65 * ratio))
        let target = NSRect(x: bounds.maxX - panelWidth - 24, y: bounds.minY + 24,
                            width: panelWidth, height: panelWidth / ratio)
        var style: NSWindow.StyleMask = [.borderless, .resizable]
        if automatic { style.insert(.nonactivatingPanel) }
        let videoPanel = ArkVideoPanel(contentRect: target, styleMask: style, backing: .buffered, defer: false)
        videoPanel.title = "Picture in Picture — Ark"
        videoPanel.setAccessibilityLabel("Picture in Picture")
        let minimumWidth: CGFloat = ratio >= 1 ? 320 : 180
        videoPanel.contentMinSize = NSSize(width: minimumWidth, height: minimumWidth / ratio)
        videoPanel.contentAspectRatio = NSSize(width: ratio, height: 1)
        videoPanel.level = .floating
        videoPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        videoPanel.hidesOnDeactivate = false
        videoPanel.isReleasedWhenClosed = false
        videoPanel.isOpaque = false
        videoPanel.backgroundColor = .clear
        videoPanel.hasShadow = true
        videoPanel.delegate = self
        videoPanel.onEscape = { [weak self] in self?.restore() }
        let host = NSView(frame: NSRect(origin: .zero, size: target.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        videoPanel.contentView = host
        let controls = PiPOverlayView(frame: host.bounds)
        controls.autoresizingMask = [.width, .height]
        controls.onReturn = { [weak self] in self?.returnToTab() }
        controls.onClose = { [weak self] in self?.restore() }
        controls.onCommand = { [weak self] command, value in self?.mediaCommand(command, value: value) }
        videoPanel.overlay = controls
        originalAutoresizing = web.autoresizingMask
        originalAlpha = web.alphaValue
        webView = web
        activeTabID = tabID
        restoreView = restore
        reportMessage = report
        panel = videoPanel
        chrome = controls
        web.removeFromSuperview()
        host.addSubview(web)
        web.frame = host.bounds
        web.autoresizingMask = [.width, .height]
        host.addSubview(controls)
        videoPanel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        if automatic { videoPanel.orderFront(nil) }
        else { videoPanel.makeKeyAndOrderFront(nil); videoPanel.makeFirstResponder(controls) }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let inset = target.size.width * 0.015
            videoPanel.setFrame(target.insetBy(dx: inset, dy: inset / ratio), display: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                videoPanel.animator().setFrame(target, display: true)
                videoPanel.animator().alphaValue = 1
            }
        }
        controls.revealControls()
        updateMediaState()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMediaState() }
        }
        mediaTimer = timer; RunLoop.main.add(timer, forMode: .common)
        onChange?()
    }

    private func mediaCommand(_ command: String, value: Double = 0) {
        guard let web = webView, value.isFinite else { return }
        let token = requestID
        web.callAsyncJavaScript("""
            const state = globalThis.__orbitPiPState;
            if (!state || state.token !== token) return null;
            const video = state.video;
            switch (command) {
            case 'play': if (video.paused || video.ended) await video.play(); else video.pause(); break;
            case 'seek': state.seek(value); break;
            case 'mute': video.muted = !video.muted; break;
            case 'volume': video.volume = Math.min(1, Math.max(0, value)); video.muted = video.volume === 0; break;
            case 'volumeStep': video.volume = Math.min(1, Math.max(0, video.volume + value)); video.muted = video.volume === 0; break;
            }
            return state.snapshot();
            """, arguments: ["token": token.uuidString, "command": command, "value": value], in: nil, in: world) { [weak self] result in
                guard let self, self.requestID == token else { return }
                if case .success(let value) = result, let state = value as? [String: Any] { self.chrome?.update(state) }
        }
    }

    private func updateMediaState() {
        guard let web = webView, pollingToken == nil else { return }
        let token = requestID
        pollingToken = token
        web.evaluateJavaScript("globalThis.__orbitPiPState?.snapshot() ?? null", in: nil, in: world) { [weak self] result in
            guard let self, self.requestID == token else { return }
            self.pollingToken = nil
            if case .success(let value) = result, let state = value as? [String: Any] { self.chrome?.update(state) }
        }
    }

    private func removeIsolation(from web: WKWebView, token: UUID, completion: (() -> Void)? = nil) {
        let script = "if (globalThis.__orbitPiPState?.token === '\(token.uuidString)') { globalThis.__orbitPiPState.restore(); delete globalThis.__orbitPiPState; } undefined"
        web.evaluateJavaScript(script, in: nil, in: world) { _ in completion?() }
    }

    // Isolated JavaScript state cannot collide with a site's own JS globals.
    // Same-origin iframe documents are searched; cross-origin access is caught.
    // No source extraction, video cloning, navigation, or player replacement.
    private static let isolationScript = #"""
    (() => {
      const previous = globalThis.__orbitPiPState;
      if (previous) { previous.restore(); delete globalThis.__orbitPiPState; }
      const requirePlaying = __ORBIT_REQUIRE_PLAYING__;
      const restoreFocus = __ORBIT_RESTORE_FOCUS__;
      const candidates = [];
      const visited = new Set();
      function visit(doc, framePath) {
        if (!doc || visited.has(doc)) return;
        visited.add(doc);
        for (const video of doc.querySelectorAll('video')) {
          const rect = video.getBoundingClientRect();
          const playing = !video.paused && !video.ended && video.readyState >= 2;
          if (requirePlaying && !playing) continue;
          candidates.push({video, framePath, score: (playing ? 1e12 : 0) + (video.readyState > 0 ? 1e9 : 0) + rect.width * rect.height});
        }
        for (const frame of doc.querySelectorAll('iframe, frame')) {
          try { if (frame.contentDocument) visit(frame.contentDocument, [...framePath, frame]); } catch (_) {}
        }
      }
      visit(document, []);
      candidates.sort((a, b) => b.score - a.score);
      if (!candidates.length) return {found: false};
      const {video, framePath} = candidates[0];
      const saved = new Map();
      const styles = [];
      const scrolls = [];
      const originalControls = video.controls;
      const wasPlaying = !video.paused && !video.ended && video.readyState >= 2;
      const originalFocus = document.activeElement;
      function remember(element) {
        if (!saved.has(element)) saved.set(element, element.getAttribute('style'));
      }
      function set(element, values) {
        remember(element);
        for (const [property, value] of Object.entries(values)) element.style.setProperty(property, value, 'important');
      }
      function isolate(element) {
        const doc = element.ownerDocument;
        const win = doc.defaultView;
        scrolls.push([win, win.scrollX, win.scrollY]);
        const style = doc.createElement('style');
        style.textContent = 'html,body{background:#000!important;overflow:hidden!important}body *{visibility:hidden!important}body *::before,body *::after{visibility:hidden!important}';
        (doc.head || doc.documentElement).appendChild(style);
        styles.push(style);
        for (let node = element; node; node = node.parentElement) {
          set(node, {'visibility':'visible','opacity':'1','transform':'none','filter':'none','perspective':'none','clip':'auto','clip-path':'none','contain':'none','content-visibility':'visible','overflow':'visible','position':'static','display':'block','pointer-events':'auto','z-index':'auto'});
        }
        for (const node of [doc.documentElement, doc.body]) {
          if (node) set(node, {'margin':'0','padding':'0','border':'0','width':'100%','height':'100%','min-width':'0','min-height':'0','overflow':'hidden'});
        }
        set(element, {'position':'fixed','inset':'0','width':'100vw','height':'100vh','min-width':'0','min-height':'0','max-width':'none','max-height':'none','margin':'0','padding':'0','border':'0','box-sizing':'border-box','object-fit':'contain','border-radius':'0','background':'#000','z-index':'2147483647'});
      }
      function restore() {
        for (const [element, style] of saved) {
          if (style === null) element.removeAttribute('style'); else element.setAttribute('style', style);
        }
        for (const style of styles) style.remove();
        video.controls = originalControls;
        for (const [win, x, y] of scrolls) { try { win.scrollTo(x, y); } catch (_) {} }
        if (restoreFocus) { try { originalFocus?.focus({preventScroll: true}); } catch (_) {} }
      }
      try {
        for (const frame of framePath) isolate(frame);
        isolate(video);
        video.controls = false;
        globalThis.__orbitPiPState = {
          token: '__ORBIT_TOKEN__', video, restore,
          snapshot() {
            return {paused: video.paused || video.ended, muted: video.muted, volume: video.volume,
                    time: Number.isFinite(video.currentTime) ? video.currentTime : 0,
                    duration: Number.isFinite(video.duration) ? video.duration : 0,
                    canSeek: video.seekable.length > 0 || Number.isFinite(video.duration)};
          },
          seek(delta) {
            let low = 0, high = Number.isFinite(video.duration) ? video.duration : 0;
            if (video.seekable.length) {
              low = video.seekable.start(0); high = video.seekable.end(video.seekable.length - 1);
            }
            if (high > low) video.currentTime = Math.min(Math.max(low, high - 0.05), Math.max(low, video.currentTime + delta));
          },
          resumeIfNeeded() { if (wasPlaying && video.paused && !video.ended) video.play().catch(() => {}); }
        };
        return {found: true, width: video.videoWidth, height: video.videoHeight, playing: wasPlaying};
      } catch (_) { restore(); return {found: false}; }
    })()
    """#
}

@MainActor private final class ArkVideoPanel: NSPanel {
    var onEscape: (() -> Void)?
    weak var overlay: PiPOverlayView?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { onEscape?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            overlay?.revealControls()
            if event.keyCode == 53 { onEscape?(); return }
            if overlay?.handleKey(event) == true { return }
        }
        super.sendEvent(event)
    }
}

/// AppKit controls stay above the rehosted page; no player cloning or custom
/// website JavaScript UI is needed. The empty overlay is also the drag surface.
@MainActor private final class PiPOverlayView: NSView {
    var onReturn: (() -> Void)?
    var onClose: (() -> Void)?
    var onCommand: ((String, Double) -> Void)?
    private let controls = PiPControlsSurface()
    private let returnButton = PiPControlButton(symbol: "pip.exit", label: "Return to Tab (R)", name: "return")
    private let closeButton = PiPControlButton(symbol: "xmark", label: "Close Floating Video (Escape)", name: "close")
    private let backward = PiPControlButton(symbol: "gobackward.10", label: "Back 10 Seconds (Left Arrow)", name: "backward")
    private let play = PiPControlButton(symbol: "pause.fill", label: "Pause (Space)", name: "playPause")
    private let forward = PiPControlButton(symbol: "goforward.10", label: "Forward 10 Seconds (Right Arrow)", name: "forward")
    private let mute = PiPControlButton(symbol: "speaker.wave.2.fill", label: "Mute (M)", name: "mute")
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00")
    private let resizeGrip = PiPResizeGrip()
    private var tracking: NSTrackingArea?
    private var hideWork: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        controls.frame = bounds; controls.autoresizingMask = [.width, .height]
        addSubview(controls)
        for control in [returnButton, closeButton, backward, play, forward, mute, volume, time, resizeGrip] as [NSView] { controls.addSubview(control) }
        returnButton.handler = { [weak self] in self?.onReturn?() }
        closeButton.handler = { [weak self] in self?.onClose?() }
        backward.handler = { [weak self] in self?.onCommand?("seek", -10) }
        play.handler = { [weak self] in self?.onCommand?("play", 0) }
        forward.handler = { [weak self] in self?.onCommand?("seek", 10) }
        mute.handler = { [weak self] in self?.onCommand?("mute", 0) }
        volume.identifier = NSUserInterfaceItemIdentifier("pip.volume")
        volume.setAccessibilityLabel("Video Volume")
        volume.toolTip = "Volume (Up/Down Arrow)"
        volume.target = self; volume.action = #selector(volumeChanged)
        volume.isContinuous = true
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.textColor = .white; time.alignment = .right
        time.setAccessibilityElement(false)
        setAccessibilityLabel("Floating video. Drag to move; Tab to navigate controls.")
        returnButton.nextKeyView = closeButton; closeButton.nextKeyView = backward
        backward.nextKeyView = play; play.nextKeyView = forward; forward.nextKeyView = mute
        mute.nextKeyView = volume; volume.nextKeyView = resizeGrip; resizeGrip.nextKeyView = returnButton
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        returnButton.frame = NSRect(x: 10, y: h - 42, width: 32, height: 32)
        closeButton.frame = NSRect(x: w - 42, y: h - 42, width: 32, height: 32)
        backward.frame = NSRect(x: w / 2 - 82, y: h / 2 - 22, width: 44, height: 44)
        play.frame = NSRect(x: w / 2 - 26, y: h / 2 - 26, width: 52, height: 52)
        forward.frame = NSRect(x: w / 2 + 38, y: h / 2 - 22, width: 44, height: 44)
        mute.frame = NSRect(x: 10, y: 10, width: 28, height: 28)
        volume.frame = NSRect(x: 43, y: 14, width: min(90, max(64, w - 128)), height: 20)
        time.frame = NSRect(x: w - 120, y: 17, width: 86, height: 16)
        time.isHidden = w < 300
        resizeGrip.frame = NSRect(x: w - 25, y: 2, width: 23, height: 23)
    }
    func update(_ state: [String: Any]) {
        let paused = state["paused"] as? Bool ?? true
        let muted = state["muted"] as? Bool ?? false
        let level = (state["volume"] as? NSNumber)?.doubleValue ?? 1
        play.configure(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Play (Space)" : "Pause (Space)")
        mute.configure(symbol: muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", label: muted ? "Unmute (M)" : "Mute (M)")
        if window?.firstResponder !== volume { volume.doubleValue = muted ? 0 : level }
        let seekable = state["canSeek"] as? Bool ?? false
        backward.isEnabled = seekable; forward.isEnabled = seekable
        let elapsed = (state["time"] as? NSNumber)?.doubleValue ?? 0
        let duration = (state["duration"] as? NSNumber)?.doubleValue ?? 0
        time.stringValue = duration > 0 ? "\(clock(elapsed)) / \(clock(duration))" : clock(elapsed)
    }
    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, min(seconds.isFinite ? seconds : 0, 35_999_999)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
    @objc private func volumeChanged() { onCommand?("volume", volume.doubleValue); revealControls() }
    func stop() { hideWork?.cancel(); hideWork = nil }
    func revealControls() {
        stop()
        setControlsVisible(true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let focused = self.window?.firstResponder as? NSView,
               focused !== self, focused.isDescendant(of: self.controls) { return }
            self.setControlsVisible(false)
        }
        hideWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2.3, execute: work)
    }
    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { revealControls() }
    override func mouseMoved(with event: NSEvent) { revealControls() }
    override func mouseExited(with event: NSEvent) {
        stop()
        if let focused = window?.firstResponder as? NSView, focused !== self, focused.isDescendant(of: controls) { return }
        setControlsVisible(false)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === controls || controls.alphaValue < 0.1 ? self : hit
    }
    override func mouseDown(with event: NSEvent) {
        revealControls(); window?.makeFirstResponder(self)
        if event.clickCount == 2 { onReturn?() } else { window?.performDrag(with: event) }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              !(window?.firstResponder is NSControl), window?.firstResponder !== resizeGrip else { return false }
        switch event.keyCode {
        case 49: onCommand?("play", 0)
        case 123: onCommand?("seek", -10)
        case 124: onCommand?("seek", 10)
        case 126: onCommand?("volumeStep", 0.1)
        case 125: onCommand?("volumeStep", -0.1)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m": onCommand?("mute", 0)
            case "r": onReturn?()
            default: return false
            }
        }
        return true
    }
    deinit { hideWork?.cancel() }
}

@MainActor private final class PiPControlsSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Subtle gradients keep controls legible without a permanent toolbar.
        NSGradient(colors: [.black.withAlphaComponent(0.56), .clear, .black.withAlphaComponent(0.50)])?
            .draw(in: bounds, angle: 90)
    }
}

@MainActor private final class PiPControlButton: NSButton {
    var handler: (() -> Void)?
    init(symbol: String, label: String, name: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("pip.\(name)")
        isBordered = false; imagePosition = .imageOnly; focusRingType = .exterior
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        contentTintColor = .white
        target = self; action = #selector(pressed)
        configure(symbol: symbol, label: label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: identifier?.rawValue == "pip.playPause" ? 22 : 16, weight: .medium))
        toolTip = label; setAccessibilityLabel(label)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() { super.layout(); layer?.cornerRadius = min(bounds.width, bounds.height) / 2 }
    @objc private func pressed() { handler?() }
}

@MainActor private final class PiPResizeGrip: NSView {
    private var startPoint = NSPoint.zero
    private var startFrame = NSRect.zero
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("pip.resize")
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("Resize Floating Video")
        toolTip = "Drag to resize video"
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5
        path.move(to: NSPoint(x: 7, y: 4)); path.line(to: NSPoint(x: 18, y: 15))
        path.move(to: NSPoint(x: 12, y: 4)); path.line(to: NSPoint(x: 18, y: 10)); path.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startPoint = NSEvent.mouseLocation; startFrame = window?.frame ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let ratio = window.contentAspectRatio.width / max(0.001, window.contentAspectRatio.height)
        let delta = NSEvent.mouseLocation
        let dx = delta.x - startPoint.x, dy = -(delta.y - startPoint.y) * ratio
        resize(to: startFrame.width + (abs(dx) >= abs(dy) ? dx : dy), from: startFrame)
    }
    private func resize(to requestedWidth: CGFloat, from frame: NSRect) {
        guard let window else { return }
        let ratio = window.contentAspectRatio.width / max(0.001, window.contentAspectRatio.height)
        let visible = window.screen?.visibleFrame ?? frame
        let limit = min(visible.width, visible.height * ratio)
        let width = min(max(window.contentMinSize.width, requestedWidth), max(window.contentMinSize.width, limit))
        let size = NSSize(width: width, height: width / ratio)
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        setAccessibilityValue("\(Int(width)) points wide")
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard let window else { return false }; resize(to: window.frame.width + 40, from: window.frame); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard let window else { return false }; resize(to: window.frame.width - 40, from: window.frame); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 || event.keyCode == 126 { _ = accessibilityPerformIncrement() }
        else if event.keyCode == 123 || event.keyCode == 125 { _ = accessibilityPerformDecrement() }
        else { super.keyDown(with: event) }
    }
}
