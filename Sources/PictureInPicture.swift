import AppKit
import WebKit
import QuartzCore

/// Bam's own feature: a floating panel rehosts the existing web view and
/// reversibly isolates its HTML5 video. This is not recovered Arc code or AVKit PiP.
@MainActor final class PictureInPictureCoordinator: NSObject, NSWindowDelegate {
    private(set) var activeTabID: UUID?
    var referencedTabID: UUID? { activeTabID ?? pendingTabID }
    var onChange: (() -> Void)?
    /// A fresh destination snapshot is installed, immediately before uncovering.
    var onRestorationReady: ((WKWebView) -> Void)?
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
    private var restorations: [ObjectIdentifier: PiPRestoration] = [:]
    private var pageSnapshot: NSImage?
    private var videoSnapshot: NSImage?
    private var sourceCover: PiPTransitionImage?
    private var presentationCover: PiPTransitionImage?
    private var snapshotToken: UUID?
    private var lastSnapshotTime: TimeInterval = 0
    private var presentationDeadline: DispatchWorkItem?
    private(set) var presentationReady = false
    private var originalAlpha: CGFloat = 1
    private var restoreView: ((WKWebView) -> Void)?
    private var reportMessage: ((String) -> Void)?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var requestID = UUID()
    private var originalAutoresizing: NSView.AutoresizingMask = []
    /// A pinch-zoomed page floats at 1× (the video fills the panel) and gets its zoom back on return.
    private var originalMagnification: CGFloat = 1
    private let world = WKContentWorld.world(name: "OrbitPictureInPicture")

    /// Includes the short paint/cover handoff after synchronous ownership release.
    func isRestoring(_ web: WKWebView) -> Bool { restorations[ObjectIdentifier(web)] != nil }
    func restorationHasRendered(_ web: WKWebView) -> Bool { restorations[ObjectIdentifier(web)]?.ready == true }

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
        restorations.removeValue(forKey: identity)?.cancel()
        sourceCover?.removeFromSuperview(); sourceCover = nil
        pageSnapshot = nil; videoSnapshot = nil; presentationReady = false
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
        let captureAndIsolate: () -> Void = { [weak self, weak web] in
            guard let self, let web, self.requestID == token else { return }
            guard shouldPresent() else { self.cancelPending(web, token: token); return }
            // Capture the normal page before any isolation CSS. This is also the
            // destination cover on return; an enlarged video still must never cover
            // the whole browser card.
            self.takeSnapshot(of: web) { [weak self, weak web] image in
                guard let self, let web, self.requestID == token else { return }
                guard shouldPresent() else { self.cancelPending(web, token: token); return }
                self.pageSnapshot = image
                let cover = PiPTransitionImage(image: image, frame: web.bounds, identifier: "pip.sourceCover")
                web.addSubview(cover); self.sourceCover = cover
                web.evaluateJavaScript(script, in: nil, in: self.world) { [weak self, weak web] result in
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
                        self.videoSnapshot = PiPVideoGeometry(info["geometry"])?.crop(from: image)
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
        }
        guard automatic else { captureAndIsolate(); return }
        // A video-free departure needs no compositor snapshot or page cover.
        // This read-only admission check shares final discovery's frame/video
        // rules; final isolation still rechecks playing state after capture.
        web.evaluateJavaScript(Self.playingVideoPreflightScript, in: nil, in: world) { [weak self, weak web] result in
            guard let self, let web, self.requestID == token else { return }
            guard shouldPresent(), web.url == startingURL, wasLoading || !web.isLoading,
                  case .success(let value) = result, value as? Bool == true else {
                self.cancelPending(web, token: token); return
            }
            captureAndIsolate()
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
            sourceCover?.removeFromSuperview(); sourceCover = nil
            pageSnapshot = nil; videoSnapshot = nil
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
        mediaTimer?.invalidate(); mediaTimer = nil; pollingToken = nil; snapshotToken = nil
        presentationDeadline?.cancel(); presentationDeadline = nil
        if let pending = pendingWebView {
            pendingWebView = nil
            removeIsolation(from: pending, token: oldToken)
        }
        sourceCover?.removeFromSuperview(); sourceCover = nil
        guard let web = webView else { complete(completion, presented: false); return }
        let callback = restoreView
        let oldPanel = panel
        let identity = ObjectIdentifier(web)
        let transfer = PiPRestoration(token: oldToken, web: web, alpha: originalAlpha, panel: oldPanel, image: pageSnapshot)
        restorations[identity]?.cancel()
        restorations[identity] = transfer
        webView = nil; activeTabID = nil; panel = nil
        chrome?.stop(); chrome = nil; presentationCover = nil; presentationReady = false
        restoreView = nil; reportMessage = nil
        // The old window holds only a still while the SAME web view transfers
        // synchronously. Neither its DOM nor its viewport is animated.
        oldPanel?.cancelPositioning()
        oldPanel?.delegate = nil; oldPanel?.onEscape = nil; oldPanel?.overlay = nil
        oldPanel?.ignoresMouseEvents = true
        if let host = oldPanel?.contentView {
            let still = PiPTransitionImage(image: videoSnapshot, frame: host.bounds, identifier: "pip.panelSnapshot")
            host.subviews.filter { $0 !== web }.forEach { $0.removeFromSuperview() }
            host.addSubview(still)
        }
        web.removeFromSuperview()
        web.autoresizingMask = originalAutoresizing
        web.alphaValue = originalAlpha
        if originalMagnification != 1, originalMagnification.isFinite { web.magnification = originalMagnification }
        originalMagnification = 1
        web.addSubview(transfer.cover)
        callback?(web)
        onChange?()
        transfer.cover.frame = web.bounds
        // A failed/crashed WebContent process must not leave an inert cover or
        // orphan panel indefinitely. Normal completion requires a fresh render.
        let deadline = DispatchWorkItem { [weak self, weak transfer] in
            guard let self, let transfer else { return }
            self.finishRestoration(transfer, geometry: nil, rendered: false)
        }
        transfer.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
        restoreLayout(transfer)
        complete(completion, presented: false)
    }

    private func restoreLayout(_ transfer: PiPRestoration) {
        guard restorations[transfer.identity] === transfer else { return }
        guard let web = transfer.web else {
            restorations.removeValue(forKey: transfer.identity); transfer.cancel(); return
        }
        // A style mutation's JS reply precedes rendering. Two animation frames
        // allow layout/resize work to settle. A short timer permits occluded
        // windows (whose RAF is suspended) to proceed to the same viewport check
        // and fresh WK snapshot; the timer alone never authorizes reveal.
        web.callAsyncJavaScript("""
            const state = globalThis.__orbitPiPState;
            if (state?.token === token) {
                state.restore();
                globalThis.__orbitPiPRestoredState = {token, geometry: state.geometry};
                delete globalThis.__orbitPiPState;
            }
            if (visible) await Promise.race([
                new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
                new Promise(resolve => setTimeout(resolve, 120))
            ]);
            if (globalThis.__orbitPiPState) return {ready: false};
            const restored = globalThis.__orbitPiPRestoredState;
            const ready = Math.abs(innerWidth - expectedWidth) < 2 && Math.abs(innerHeight - expectedHeight) < 2;
            return {ready, geometry: restored?.token === token ? restored.geometry() : null};
            """, arguments: ["token": transfer.token.uuidString, "visible": web.window != nil,
                              "expectedWidth": web.bounds.width / web.pageZoom,
                              "expectedHeight": web.bounds.height / web.pageZoom], in: nil, in: world) { [weak self, weak transfer] result in
                guard let self, let transfer, let web = transfer.web,
                      self.restorations[ObjectIdentifier(web)] === transfer, !transfer.finishing else { return }
                if web.window == nil {
                    self.finishRestoration(transfer, geometry: nil, rendered: false)
                    return
                }
                guard case .success(let value) = result, let info = value as? [String: Any], info["ready"] as? Bool == true else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak transfer] in
                        if let transfer { self?.restoreLayout(transfer) }
                    }
                    return
                }
                let geometry = PiPVideoGeometry(info["geometry"])
                let size = web.bounds.size
                self.takeSnapshot(of: web) { [weak self, weak transfer] image in
                    guard let self, let transfer, let web = transfer.web,
                          self.restorations[ObjectIdentifier(web)] === transfer, !transfer.finishing else { return }
                    guard size == web.bounds.size, let image else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak transfer] in
                            if let transfer { self?.restoreLayout(transfer) }
                        }
                        return
                    }
                    // This snapshot is the restored page at its final bounds.
                    // Replace the older normal-page cover without an empty frame.
                    transfer.cover.image = image
                    self.finishRestoration(transfer, geometry: geometry, rendered: true)
                }
        }
    }

    private func finishRestoration(_ transfer: PiPRestoration, geometry: PiPVideoGeometry?, rendered: Bool) {
        guard restorations[transfer.identity] === transfer, !transfer.finishing else { return }
        guard let web = transfer.web else {
            restorations.removeValue(forKey: transfer.identity); transfer.cancel(); return
        }
        transfer.finishing = true; transfer.ready = rendered
        transfer.deadline?.cancel(); transfer.deadline = nil
        web.alphaValue = transfer.alpha
        if rendered { onRestorationReady?(web) }
        guard restorations[transfer.identity] === transfer else { return }
        let target = rendered ? geometry?.screenRect(in: web) : nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            transfer.cover.animator().alphaValue = 0
            // Only the inert snapshot window changes size, never live WebKit.
            if let target, let panel = transfer.panel, panel.isVisible, panel.alphaValue > 0 {
                panel.animator().setFrame(target, display: true)
            }
            transfer.panel?.animator().alphaValue = 0
        } completionHandler: { [weak self, weak transfer] in
            Task { @MainActor [weak self, weak transfer] in
                guard let self, let transfer, self.restorations[transfer.identity] === transfer else { return }
                self.restorations.removeValue(forKey: transfer.identity)
                transfer.cancel()
            }
        }
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
        videoPanel.title = "Picture in Picture — Bam"
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
        originalMagnification = web.magnification
        if web.magnification != 1 { web.magnification = 1 }
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
        sourceCover?.removeFromSuperview(); sourceCover = nil
        let entry = PiPTransitionImage(image: videoSnapshot, frame: host.bounds, identifier: "pip.presentationCover")
        host.addSubview(entry, positioned: .below, relativeTo: controls)
        presentationCover = entry
        videoPanel.alphaValue = 0
        if automatic { videoPanel.orderFront(nil) }
        else { videoPanel.makeKeyAndOrderFront(nil); videoPanel.makeFirstResponder(controls) }
        let token = requestID
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == token, !self.presentationReady else { return }
            self.restore()
        }
        presentationDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
        preparePresentation(web: web, token: token)
        controls.revealControls()
        updateMediaState()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMediaState() }
        }
        mediaTimer = timer; RunLoop.main.add(timer, forMode: .common)
        onChange?()
    }

    private func preparePresentation(web: WKWebView, token: UUID, attempt: Int = 0) {
        guard requestID == token, webView === web else { return }
        web.callAsyncJavaScript("""
            await Promise.race([
                new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
                new Promise(resolve => setTimeout(resolve, 120))
            ]);
            const state = globalThis.__orbitPiPState;
            if (state?.token !== token) return false;
            const rect = state.video.getBoundingClientRect();
            const win = state.video.ownerDocument.defaultView;
            return Math.abs(rect.width - win.innerWidth) < 2 && Math.abs(rect.height - win.innerHeight) < 2
                && Math.abs(innerWidth - expectedWidth) < 2 && Math.abs(innerHeight - expectedHeight) < 2;
            """, arguments: ["token": token.uuidString,
                              "expectedWidth": web.bounds.width / web.pageZoom,
                              "expectedHeight": web.bounds.height / web.pageZoom], in: nil, in: world) { [weak self, weak web] result in
                guard let self, let web, self.requestID == token, self.webView === web else { return }
                let size = web.bounds.size
                guard case .success(let value) = result, value as? Bool == true else {
                    if attempt < 8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak web] in
                            if let web { self?.preparePresentation(web: web, token: token, attempt: attempt + 1) }
                        }
                    } else { self.restore() }
                    return
                }
                self.takeSnapshot(of: web) { [weak self, weak web] image in
                    guard let self, let web, self.requestID == token, self.webView === web else { return }
                    guard let image, size == web.bounds.size else {
                        if attempt < 8 { self.preparePresentation(web: web, token: token, attempt: attempt + 1) }
                        else { self.restore() }
                        return
                    }
                    self.videoSnapshot = image; self.presentationCover?.image = image
                    self.presentationReady = true
                    self.presentationDeadline?.cancel(); self.presentationDeadline = nil
                    self.lastSnapshotTime = ProcessInfo.processInfo.systemUptime
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.panel?.animator().alphaValue = 1
                    } completionHandler: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.requestID == token else { return }
                            self.presentationCover?.removeFromSuperview(); self.presentationCover = nil
                        }
                    }
                }
        }
    }

    private func takeSnapshot(of web: WKWebView, completion: @escaping (NSImage?) -> Void) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.bounds
        configuration.afterScreenUpdates = true
        var completed = false
        // Snapshot callbacks can stall after a WebContent process failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !completed else { return }; completed = true; completion(nil)
        }
        web.takeSnapshot(with: configuration) { image, _ in
            guard !completed else { return }; completed = true; completion(image)
        }
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
        if presentationReady, snapshotToken == nil,
           ProcessInfo.processInfo.systemUptime - lastSnapshotTime > 0.65 {
            snapshotToken = token
            takeSnapshot(of: web) { [weak self] image in
                guard let self, self.requestID == token else { return }
                self.snapshotToken = nil
                if let image { self.videoSnapshot = image }
                self.lastSnapshotTime = ProcessInfo.processInfo.systemUptime
            }
        }
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
    /// Both admission and final isolation inspect the same accessible frames.
    /// Admission only reads playback state; geometry/ranking is deferred until
    /// a real candidate is needed, avoiding layout for pages without video.
    private static let videoDiscoveryScript = #"""
    function collectVideoCandidates(requirePlaying, measureGeometry) {
      const candidates = [];
      const visited = new Set();
      function visit(doc, framePath) {
        if (!doc || visited.has(doc)) return;
        visited.add(doc);
        for (const video of doc.querySelectorAll('video')) {
          const playing = !video.paused && !video.ended && video.readyState >= 2;
          if (requirePlaying && !playing) continue;
          const rect = measureGeometry ? video.getBoundingClientRect() : {width: 0, height: 0};
          candidates.push({video, framePath, score: (playing ? 1e12 : 0) + (video.readyState > 0 ? 1e9 : 0) + rect.width * rect.height});
        }
        for (const frame of doc.querySelectorAll('iframe, frame')) {
          try { if (frame.contentDocument) visit(frame.contentDocument, [...framePath, frame]); } catch (_) {}
        }
      }
      visit(document, []);
      if (measureGeometry) candidates.sort((a, b) => b.score - a.score);
      return candidates;
    }
    """#
    private static let playingVideoPreflightScript = "(() => {\n" + videoDiscoveryScript
        + "\nreturn collectVideoCandidates(true, false).length > 0; })()"

    // No source extraction, video cloning, navigation, or player replacement.
    private static let isolationScript = #"""
    (() => {
      const previous = globalThis.__orbitPiPState;
      if (previous) { previous.restore(); delete globalThis.__orbitPiPState; }
      const requirePlaying = __ORBIT_REQUIRE_PLAYING__;
      const restoreFocus = __ORBIT_RESTORE_FOCUS__;
      __ORBIT_VIDEO_DISCOVERY__
      const candidates = collectVideoCandidates(requirePlaying, true);
      if (!candidates.length) return {found: false};
      const {video, framePath} = candidates[0];
      delete globalThis.__orbitPiPRestoredState;
      function geometry() {
        const bounds = video.getBoundingClientRect();
        let x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height;
        for (const frame of [...framePath].reverse()) {
          const rect = frame.getBoundingClientRect();
          const scaleX = rect.width / (frame.offsetWidth || rect.width || 1);
          const scaleY = rect.height / (frame.offsetHeight || rect.height || 1);
          x = rect.x + (x + frame.clientLeft) * scaleX;
          y = rect.y + (y + frame.clientTop) * scaleY;
          width *= scaleX; height *= scaleY;
        }
        return {rect: {x, y, width, height}, viewportWidth: innerWidth, viewportHeight: innerHeight};
      }
      const originalGeometry = geometry();
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
          token: '__ORBIT_TOKEN__', video, restore, geometry,
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
        return {found: true, width: video.videoWidth, height: video.videoHeight, playing: wasPlaying, geometry: originalGeometry};
      } catch (_) { restore(); return {found: false}; }
    })()
    """#.replacingOccurrences(of: "__ORBIT_VIDEO_DISCOVERY__", with: videoDiscoveryScript)
}
