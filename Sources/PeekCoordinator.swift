import AppKit
import WebKit

/// Independent implementation informed by Arc's public product documentation:
/// https://resources.arc.net/hc/en-us/sections/19211965457687-Multitask
/// The parent owns one coordinator per source tab and calls setVisible on selection.
typealias PreviewNavigationReadiness = @MainActor (@escaping @MainActor () -> Void) -> Void

@MainActor final class PreviewWKWebView: WKWebView {
    var requestedURL: URL?
    var isProvisionalNavigation = false
    /// Retained only while readiness delays a requested navigation; follows adoption.
    var pendingReadyURL: URL?
    var promotionURL: URL? {
        isProvisionalNavigation ? (requestedURL ?? url) : (url ?? requestedURL)
    }
}

@MainActor final class PeekCoordinator: NSObject {
    var onPromote: ((WKWebView) -> Void)?
    var onSplit: ((WKWebView) -> Void)?
    var onOpenLittleOrbit: ((WKWebView) -> Void)?
    var onDismiss: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)? { didSet { content?.onDownload = onDownload } }
    var onVisit: ((String, String) -> Void)? { didSet { content?.onVisit = onVisit } }
    var shouldHandleEscape: (() -> Bool)?
    /// The page's address or title changed; the sidebar's address field shows the Peek's page while it is up.
    var onPageChange: (() -> Void)?
    var isPresented: Bool { backdrop != nil }
    /// Shown and not hidden behind another tab.
    var isShowing: Bool { backdrop?.isHidden == false }
    /// What the address field shows while the Peek is up.
    var pageURL: URL? { webView?.url ?? (webView as? PreviewWKWebView)?.requestedURL }
    var webView: WKWebView? { content?.webView }

    private var content: PreviewWebContent?
    private var backdrop: PeekBackdrop?
    private var keyMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?
    private weak var hostWindow: NSWindow?
    private var awaitingFirstPaint = false

    @discardableResult
    func present(url: URL, in hostView: NSView, websiteDataStore: WKWebsiteDataStore, configure: ((WKWebViewConfiguration) -> Void)? = nil, beforeLoad: PreviewNavigationReadiness? = nil) -> Bool {
        guard PreviewURLPolicy.allows(url) else { return false }
        _ = detach(notify: false, stop: true)
        let configuration = WKWebViewConfiguration()
        configuration.adoptSafariUserAgent()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configure?(configuration)
        let browser = PreviewWKWebView(frame: .zero, configuration: configuration)
        ContentBlocking.shared.track(browser)
        BrowserPageGestures.configure(browser)
        let content = PreviewWebContent(webView: browser, beforeLoad: beforeLoad)
        self.content = content
        content.onDownload = onDownload
        content.onVisit = onVisit
        // Over the whole window, like the reference: the card may run past the page's own edges,
        // while only the page dims and the sidebar stays live.
        let overlayHost = hostView.window?.contentView ?? hostView
        let backdrop = PeekBackdrop(frame: overlayHost.bounds, page: hostView)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.onOutsideClick = { [weak self] in self?.dismiss() }
        backdrop.closeButton.target = self; backdrop.closeButton.action = #selector(closeAction)
        backdrop.tabButton.target = self; backdrop.tabButton.action = #selector(tabAction)
        backdrop.splitButton.target = self; backdrop.splitButton.action = #selector(splitAction)
        backdrop.littleButton.target = self; backdrop.littleButton.action = #selector(littleAction)
        backdrop.splitButton.isHidden = onSplit == nil
        backdrop.littleButton.isHidden = onOpenLittleOrbit == nil
        backdrop.browserHost.addSubview(browser)
        browser.frame = backdrop.browserHost.bounds
        browser.autoresizingMask = [.width, .height]
        self.backdrop = backdrop
        hostWindow = hostView.window
        previousResponder = hostView.window?.firstResponder
        content.onChange = { [weak self] in self?.refresh() }
        content.onCloseRequest = { [weak self] in self?.dismiss() }
        backdrop.setSurface(PeekOrigin.surface(in: hostView, excluding: browser))
        let animate = !PeekMotion.reduceMotion && hostView.window?.isVisible == true
        // Until its page commits, the card shows the page behind's color, never an empty dark view.
        if hostView.window?.isVisible == true {
            browser.alphaValue = 0; awaitingFirstPaint = true
            if let surface = PeekOrigin.surface(in: hostView, excluding: browser) { browser.underPageBackgroundColor = surface }
        }
        if animate { backdrop.prepareEntrance() }
        overlayHost.addSubview(backdrop, positioned: .above, relativeTo: nil)
        backdrop.layoutSubtreeIfNeeded()
        installKeyboardHandling()
        if let window = hostWindow {
            windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                          object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        _ = content.load(url: url)
        refresh()
        hostWindow?.makeFirstResponder(browser)
        if animate {
            PeekOrigin.resolve(in: hostView, excluding: browser) { [weak backdrop] link, label in
                guard let backdrop, backdrop.superview != nil else { return }
                backdrop.animateEntrance(from: link.map { backdrop.convert($0, from: hostView) }, label: label)
            }
        } else if !PeekMotion.reduceMotion {
            backdrop.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; backdrop.animator().alphaValue = 1 }
        }
        return true
    }

    func setVisible(_ visible: Bool) {
        guard let backdrop else { return }
        let changed = backdrop.isHidden == visible
        if !visible { content?.cancelFileSelection() }
        backdrop.isHidden = !visible
        if visible && changed {
            backdrop.layoutSubtreeIfNeeded()
            hostWindow?.makeFirstResponder(webView)
        }
    }

    func dismiss() { _ = detach(notify: true, stop: true, exit: .collapse) }

    func promoteToTab() {
        guard let callback = onPromote, let web = detach(notify: true, stop: false, exit: .expand) else { return }
        callback(web)
    }

    func openInSplitView() {
        guard let callback = onSplit, let web = detach(notify: true, stop: false) else { return }
        callback(web)
    }

    func openInLittleOrbit() {
        guard let callback = onOpenLittleOrbit, let web = detach(notify: true, stop: false) else { return }
        callback(web)
    }

    private enum Exit { case none, collapse, expand }
    private func detach(notify: Bool, stop: Bool, exit: Exit = .none) -> WKWebView? {
        let wasPresented = backdrop != nil
        let wasVisible = backdrop?.isHidden == false
        // The closing motion runs on a still of the card, so the page can be handed off right away.
        if exit != .none, wasVisible, let backdrop, let host = backdrop.superview, backdrop.alphaValue > 0.5 {
            let image = backdrop.cardSnapshot()
            let style: PeekExitGhost.Style = exit == .expand ? .expand(backdrop.pageRect) : .collapse(backdrop.origin, backdrop.originLabel)
            backdrop.stopEntrance()
            let dim = backdrop.dimColor
            let frame = backdrop.convert(backdrop.card.frame, to: host)
            let dimFrame = backdrop.convert(backdrop.dim.frame, to: host)
            let radius = backdrop.dim.layer?.cornerRadius ?? 0
            backdrop.removeFromSuperview()
            PeekExitGhost.run(in: host, image: image, cardFrame: frame, dimFrame: dimFrame, dimRadius: radius, dim: dim, style: style)
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        let web = content?.takeWebView()
        if awaitingFirstPaint { web?.underPageBackgroundColor = nil }
        awaitingFirstPaint = false
        web?.alphaValue = 1
        if stop { web?.stopLoading() }
        content = nil
        backdrop?.stopEntrance()
        backdrop?.removeFromSuperview()
        backdrop = nil
        if wasVisible, let previousResponder { hostWindow?.makeFirstResponder(previousResponder) }
        previousResponder = nil
        hostWindow = nil
        if notify && wasPresented { onDismiss?() }
        return web
    }

    private func installKeyboardHandling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let backdrop = self.backdrop, !backdrop.isHidden,
                  event.window === self.hostWindow, self.hostWindow?.attachedSheet == nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                guard self.shouldHandleEscape?() != false else { return event }
                self.dismiss(); return nil
            }
            if flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "w": self.dismiss(); return nil
                case "c" where flags.contains(.shift): self.copyLink(); return nil
                case "o":
                    if flags.contains(.shift) { self.openInSplitView() }
                    else { self.promoteToTab() }
                    return nil
                default: break
                }
            }
            return event
        }
    }

    private var lastPageKey = ""
    private func refresh() {
        guard let content, let web = content.webView, backdrop != nil else { return }
        let key = "\(pageURL?.absoluteString ?? "")|\(content.status ?? "")"
        if key != lastPageKey { lastPageKey = key; onPageChange?() }
        let committed = web.url != nil && (web as? PreviewWKWebView)?.isProvisionalNavigation != true
        if awaitingFirstPaint, committed || content.status != nil || (!web.isLoading && (web as? PreviewWKWebView)?.pendingReadyURL == nil) {
            awaitingFirstPaint = false
            // The borrowed color only covers the blank card; the page's own takes over (nil resets it).
            web.underPageBackgroundColor = nil
            // A beat for the first paint after commit (WebKit has no paint callback), then the page fades in.
            DispatchQueue.main.asyncAfter(deadline: .now() + (web.isLoading ? 0.3 : 0.02)) { [weak web] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = PeekMotion.reduceMotion ? 0 : 0.14
                    web?.animator().alphaValue = 1
                }
            }
        }
    }

    @objc private func closeAction() { dismiss() }
    /// Copies the Peek's address (⇧⌘C).
    func copyLink() {
        guard let url = webView?.url ?? (webView as? PreviewWKWebView)?.requestedURL else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }
    @objc private func tabAction() { promoteToTab() }
    @objc private func splitAction() { openInSplitView() }
    @objc private func littleAction() { openInLittleOrbit() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }
}

/// Finds the link a Peek was opened from: the clickable element under the pointer in the page
/// beside it, measured in the page and converted to the host's coordinates. Falls back to a
/// link-sized rect at the pointer, or nil (no pointer over the page, e.g. a keyboard command).
@MainActor enum PeekOrigin {
    static func resolve(in host: NSView, excluding preview: WKWebView, completion: @escaping @MainActor (NSRect?, String?) -> Void) {
        guard let window = host.window else { completion(nil, nil); return }
        let mouse = window.mouseLocationOutsideOfEventStream
        let point = host.convert(mouse, from: nil)
        guard host.bounds.contains(point) else { completion(nil, nil); return }
        let fallback = NSRect(x: point.x - 70, y: point.y - 12, width: 140, height: 24)
        guard let web = pageView(in: host, at: mouse, excluding: preview) else { completion(fallback, nil); return }
        var finished = false
        let finish: @MainActor (NSRect?, String?) -> Void = { rect, label in
            guard !finished else { return }
            finished = true; completion(rect, label)
        }
        // A slow page must not hold the Peek back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { finish(fallback, nil) }
        let local = web.convert(mouse, from: nil)
        let scale = max(0.01, web.pageZoom * web.magnification)
        let cssX = (web.isFlipped ? local.x : local.x) / scale
        let cssY = (web.isFlipped ? local.y : web.bounds.height - local.y) / scale
        web.callAsyncJavaScript("""
            const hit = document.elementFromPoint(x, y);
            if (!hit) return null;
            const target = hit.closest('a[href],area[href],[role=link],button') || hit;
            let rect = null;
            for (const r of target.getClientRects()) {
                if (x >= r.left - 3 && x <= r.right + 3 && y >= r.top - 3 && y <= r.bottom + 3) { rect = r; break; }
            }
            rect = rect || target.getBoundingClientRect();
            if (rect.width > innerWidth * 0.8 && rect.height > innerHeight * 0.4) return null;
            return {x: rect.left, y: rect.top, w: rect.width, h: rect.height,
                    t: (target.innerText || target.getAttribute('aria-label') || '').trim().replace(/\\s+/g, ' ').slice(0, 140)};
            """, arguments: ["x": cssX, "y": cssY], in: nil, in: .defaultClient) { [weak web, weak host] result in
            guard let web, let host, case .success(let value) = result, let info = value as? [String: Any],
                  let x = (info["x"] as? NSNumber)?.doubleValue, let y = (info["y"] as? NSNumber)?.doubleValue,
                  let w = (info["w"] as? NSNumber)?.doubleValue, let h = (info["h"] as? NSNumber)?.doubleValue,
                  [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { finish(fallback, nil); return }
            let inWeb = NSRect(x: x * scale, y: web.isFlipped ? y * scale : web.bounds.height - (y + h) * scale,
                               width: w * scale, height: h * scale)
            var rect = web.convert(inWeb, to: host)
            rect = rect.intersection(host.bounds)
            guard !rect.isNull, rect.width > 2, rect.height > 2 else { finish(fallback, nil); return }
            finish(rect, info["t"] as? String)
        }
    }

    /// The background of the page the Peek opens over, used while the Peek's page loads.
    static func surface(in root: NSView, excluding preview: WKWebView) -> NSColor? {
        for view in root.subviews.reversed() where !view.isHidden {
            if let web = view as? WKWebView { if web !== preview, web.url != nil { return web.underPageBackgroundColor }; continue }
            if let found = surface(in: view, excluding: preview) { return found }
        }
        return nil
    }

    private static func pageView(in root: NSView, at windowPoint: NSPoint, excluding preview: WKWebView) -> WKWebView? {
        for view in root.subviews.reversed() where !view.isHidden && view.alphaValue > 0.01 {
            if let web = view as? WKWebView {
                if web !== preview, web.bounds.contains(web.convert(windowPoint, from: nil)) { return web }
                continue
            }
            if let found = pageView(in: view, at: windowPoint, excluding: preview) { return found }
        }
        return nil
    }
}

/// Peek's motion and geometry, measured frame by frame (60 fps) against the reference: the link
/// turns into a dark pill for two frames, then a white card springs out of it (critically damped,
/// ~45% in 33 ms, ~87% in 100 ms, settled by ~0.17 s) while only the page dims. Closing shrinks
/// the card back into a pale pill around the link, which then fades. Original Bam tuning.
enum PeekMotion {
    static let stiffness: CGFloat = 1600          // ω = 40 rad/s
    static let chipLead: CFTimeInterval = 0.022    // the dark pill before the card appears
    static let dimDuration: CFTimeInterval = 0.2
    static let closeDuration: CFTimeInterval = 0.18
    static let chipFade: CFTimeInterval = 0.14
    static let expandDuration: CFTimeInterval = 0.22
    static let cardRadius: CGFloat = 10
    /// The card runs this far past the page's top and bottom edges.
    static let overhang: CGFloat = 7
    static let buttonSize: CGFloat = 34
    static let buttonGap: CGFloat = 10

    @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The card's resting frame for a page at `page`, inside an overlay of `bounds` (flipped).
    static func cardFrame(page: NSRect, in bounds: NSRect) -> NSRect {
        // About 81% of the page's width, centered on it, leaving room for the buttons.
        let side = min(140, max(56, (page.width * 0.093).rounded()))
        let width = max(0, page.width - 2 * side)
        let top = max(bounds.minY + 10, page.minY - overhang)
        let bottom = min(bounds.maxY - 10, page.maxY + overhang)
        return NSRect(x: (page.midX - width / 2).rounded(), y: top, width: width, height: max(0, bottom - top))
    }

    /// Where the card starts: the link itself, padded like a pressed pill and kept inside the page.
    static func originFrame(link: NSRect, in bounds: NSRect) -> NSRect {
        var rect = link.insetBy(dx: -6, dy: -4)
        rect.size.width = max(rect.width, 40); rect.size.height = max(rect.height, 24)
        rect.origin.x = min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        rect.origin.y = min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return rect.integral
    }
}

@MainActor private final class PeekBackdrop: NSView {
    var onOutsideClick: (() -> Void)?
    let cardShadow = NSView()
    let card = PeekCard()
    let browserHost = PeekCard()
    let closeButton = PeekRoundButton(symbol: "xmark", label: "Close Peek", toolTip: "Close (Esc)")
    let tabButton = PeekRoundButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open in Tab", toolTip: "Open as a tab (⌘O)")
    let splitButton = PeekRoundButton(symbol: "rectangle.split.2x1", label: "Split View", toolTip: "Open beside the page (⇧⌘O)")
    let littleButton = PeekRoundButton(symbol: "macwindow", label: "Little Bam", toolTip: "Move to Little Bam")
    let dim = PeekDim()
    /// The page the Peek opens over; the dim covers exactly it.
    private weak var page: NSView?
    /// The link the card grew from (and its words), kept so closing can shrink back into it.
    private(set) var origin: NSRect?
    private(set) var originLabel: String?
    private var entering = false
    override var isFlipped: Bool { true }
    var buttons: [PeekRoundButton] { [closeButton, tabButton, splitButton, littleButton] }
    var pageRect: NSRect {
        guard let page, page.window === window, window != nil else { return bounds }
        return convert(page.bounds, from: page)
    }

    init(frame: NSRect, page: NSView) {
        self.page = page
        super.init(frame: frame)
        wantsLayer = true
        dim.wantsLayer = true
        dim.layer?.masksToBounds = true
        cardShadow.wantsLayer = true
        cardShadow.layer?.shadowOpacity = 1; cardShadow.layer?.shadowRadius = 18; cardShadow.layer?.shadowOffset = CGSize(width: 0, height: -6)
        card.wantsLayer = true
        card.layer?.cornerRadius = PeekMotion.cardRadius; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        addSubview(dim)
        addSubview(cardShadow)
        addSubview(card)
        card.addSubview(browserHost)
        buttons.forEach(addSubview)
        addSubview(chip)
        applyAppearanceColors()
        setAccessibilityElement(false); card.setAccessibilityLabel("Peek preview")
        page.postsFrameChangedNotifications = true
        pageObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: page, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var pageObserver: NSObjectProtocol?
    deinit { if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) } }

    /// Only the page, the card and its buttons take clicks; the sidebar and titlebar stay live.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        let interactive = dim.frame.contains(local) || card.frame.contains(local) || buttons.contains { !$0.isHidden && $0.frame.contains(local) }
        return interactive ? super.hitTest(point) : nil
    }

    var dimColor: CGColor {
        NSColor.black.withAlphaComponent(effectiveAppearance.isDarkChrome ? 0.5 : 0.42).cgColor
    }
    private func applyAppearanceColors() {
        let dark = effectiveAppearance.isDarkChrome
        dim.layer?.backgroundColor = dimColor
        card.layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: card)
        card.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.06)).cgColor
        cardShadow.layer?.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.28).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearanceColors() }
    override func mouseDown(with event: NSEvent) { onOutsideClick?() }

    /// The page's own background while it loads (the source page's), so a light page never flashes dark.
    func setSurface(_ color: NSColor?) {
        guard let color else { return }
        card.layer?.backgroundColor = resolvedCGColor(color, for: card)
        browserHost.wantsLayer = true
        browserHost.layer?.backgroundColor = resolvedCGColor(color, for: card)
    }

    override func layout() {
        super.layout()
        let page = pageRect
        dim.frame = page
        dim.layer?.cornerRadius = self.page?.layer?.cornerRadius ?? 0
        let frame = PeekMotion.cardFrame(page: page, in: bounds)
        // While growing, the card is a window onto content laid out at its final size.
        let shown = reveal ?? frame
        card.frame = shown
        cardShadow.frame = shown
        cardShadow.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: shown.size), cornerWidth: PeekMotion.cardRadius,
                                              cornerHeight: PeekMotion.cardRadius, transform: nil)
        browserHost.frame = NSRect(x: frame.minX - shown.minX, y: frame.minY - shown.minY, width: frame.width, height: frame.height)
        var y = frame.minY + 6
        let x = frame.maxX + 13
        for button in buttons where !button.isHidden {
            button.frame = NSRect(x: x, y: y, width: PeekMotion.buttonSize, height: PeekMotion.buttonSize)
            y += PeekMotion.buttonSize + PeekMotion.buttonGap
        }
    }

    // MARK: Motion

    /// Hides everything until the origin is known, so nothing flashes at full size first.
    func prepareEntrance() {
        entering = true
        alphaValue = 0
    }

    /// The pressed link: a dark pill with the link's words, shown for an instant before the card.
    let chip = PeekChip()

    /// The link turns into a dark pill, then the card springs out of it. Driven per display frame on
    /// view frames, so the page is laid out once at full size and never re-lays out mid-grow.
    func animateEntrance(from link: NSRect?, label: String?) {
        guard entering else { alphaValue = 1; return }
        entering = false
        layoutSubtreeIfNeeded()
        alphaValue = 1
        let final = PeekMotion.cardFrame(page: pageRect, in: bounds)
        guard final.width > 40, final.height > 40, !PeekMotion.reduceMotion else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
            return
        }
        let start = link.map { PeekMotion.originFrame(link: $0, in: pageRect) }
            ?? final.insetBy(dx: final.width * 0.04, dy: final.height * 0.04)
        origin = link.map { _ in start }
        originLabel = label
        if link != nil {
            chip.show(label ?? "", in: start, dark: true)
            card.alphaValue = 0; cardShadow.alphaValue = 0
        }
        chipLead = link == nil ? 0 : PeekMotion.chipLead
        for button in buttons { button.alphaValue = 0 }
        dim.alphaValue = 0
        reveal = start
        revealStart = start
        revealBegan = CACurrentMediaTime()
        needsLayout = true; layoutSubtreeIfNeeded()
        let displayLink = displayLink(target: self, selector: #selector(entranceFrame(_:)))
        displayLink.add(to: .main, forMode: .common)
        entranceLink = displayLink
    }

    private var reveal: NSRect?
    private var revealStart = NSRect.zero
    private var revealBegan: CFTimeInterval = 0
    private var chipLead: CFTimeInterval = 0
    private var entranceLink: CADisplayLink?

    @objc private func entranceFrame(_ displayLink: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - revealBegan
        let t = max(0, elapsed - chipLead)
        let omega = Double(PeekMotion.stiffness).squareRoot()
        // Critically damped spring from 0 to 1.
        let p = CGFloat(1 - (1 + omega * t) * exp(-omega * t))
        let final = PeekMotion.cardFrame(page: pageRect, in: bounds)
        let s = revealStart
        reveal = NSRect(x: s.minX + (final.minX - s.minX) * p, y: s.minY + (final.minY - s.minY) * p,
                        width: s.width + (final.width - s.width) * p, height: s.height + (final.height - s.height) * p)
        dim.alphaValue = CGFloat(min(1, 1 - pow(1 - min(1, elapsed / PeekMotion.dimDuration), 3)))
        if elapsed >= chipLead { card.alphaValue = 1; cardShadow.alphaValue = 1 }
        chip.alphaValue = CGFloat(max(0, 1 - max(0, elapsed - chipLead) / 0.05))
        for (index, button) in buttons.enumerated() {
            let local = (t - 0.08 - 0.025 * Double(index)) / 0.14
            button.alphaValue = CGFloat(min(1, max(0, local)))
        }
        if p > 0.998 && t > 0.22 + 0.025 * Double(buttons.count) { stopEntrance() }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func stopEntrance() {
        entranceLink?.invalidate(); entranceLink = nil
        reveal = nil; chip.isHidden = true
        dim.alphaValue = 1; card.alphaValue = 1; cardShadow.alphaValue = 1
        buttons.forEach { $0.alphaValue = 1 }
        needsLayout = true
    }

    /// A still of the card for the closing motion; nil when it can't be captured.
    func cardSnapshot() -> CGImage? {
        guard let window, window.isVisible, window.windowNumber > 0, !isHiddenOrHasHiddenAncestor, card.bounds.width > 4 else { return nil }
        let inWindow = card.convert(card.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        guard let primary = NSScreen.screens.first else { return nil }
        let cgRect = CGRect(x: onScreen.minX, y: primary.frame.maxY - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        return PeekWindowCapture.image(cgRect, window: CGWindowID(window.windowNumber))
    }
}

/// The link as a pill: dark (pressed) as a Peek opens, pale as it closes back into it.
@MainActor final class PeekChip: NSView {
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ text: String, in rect: NSRect, dark: Bool) {
        frame = rect
        layer?.backgroundColor = (dark ? NSColor(white: 0.18, alpha: 0.92) : NSColor(white: 0.86, alpha: 0.95)).cgColor
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: BamType.sans(13, weight: .medium), .foregroundColor: dark ? NSColor.white : NSColor(white: 0.12, alpha: 1)])
        let height = ceil(label.attributedStringValue.size().height)
        label.frame = NSRect(x: 6, y: (rect.height - height) / 2, width: max(0, rect.width - 12), height: height)
        alphaValue = 1; isHidden = false
    }
}

/// The closing card: a still of the Peek that shrinks into its link (or expands into the tab) and
/// fades, while the dim lifts. Inert to clicks, removed when done.
@MainActor final class PeekExitGhost: NSView {
    enum Style { case collapse(NSRect?, String?), expand(NSRect) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func run(in host: NSView, image: CGImage?, cardFrame: NSRect, dimFrame: NSRect, dimRadius: CGFloat, dim: CGColor, style: Style) {
        let ghost = PeekExitGhost(frame: host.bounds)
        ghost.wantsLayer = true
        ghost.autoresizingMask = [.width, .height]
        host.addSubview(ghost, positioned: .above, relativeTo: nil)
        guard let root = ghost.layer else { ghost.removeFromSuperview(); return }
        // AppKit gives a layer-backed view's sublayers the view's own coordinates, so in this
        // flipped view a sublayer at y = 0 sits at the top, whatever `isGeometryFlipped` reports.
        func layerRect(_ r: NSRect) -> CGRect { r }
        let reduce = PeekMotion.reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dimLayer = CALayer()
        dimLayer.frame = layerRect(dimFrame); dimLayer.backgroundColor = dim
        dimLayer.cornerRadius = dimRadius; dimLayer.masksToBounds = true
        root.addSublayer(dimLayer)
        let still = CALayer()
        still.contents = image
        still.contentsGravity = .resize
        still.masksToBounds = true; still.cornerRadius = PeekMotion.cardRadius
        still.backgroundColor = image == nil ? NSColor.windowBackgroundColor.cgColor : nil
        let from = layerRect(cardFrame)
        still.frame = from
        root.addSublayer(still)
        var target = from
        var duration = PeekMotion.closeDuration
        var curve = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.25, 1)
        var radius = PeekMotion.cardRadius
        var pill: (CGRect, String)?
        var stillFade: (times: [NSNumber], values: [Float]) = ([0, 0.6, 1], [1, 0.9, 0])
        switch style {
        case .collapse(let link, let label):
            if let link, !reduce {
                target = layerRect(link); radius = 6
                pill = (target, label ?? "")
            } else { target = from.insetBy(dx: from.width * 0.03, dy: from.height * 0.03) }
        case .expand(let page):
            target = reduce ? from : layerRect(page); radius = dimRadius
            duration = PeekMotion.expandDuration
            curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            // The live page underneath is the same page, so the still gives way early.
            stillFade = ([0, 0.55, 1], [1, 0, 0])
        }
        if reduce { duration = 0.12; stillFade = ([0, 1], [1, 0]) }
        let total = duration + (pill == nil ? 0 : PeekMotion.chipFade)
        CATransaction.setCompletionBlock { ghost.removeFromSuperview() }
        func add(_ layer: CALayer, _ key: String, _ start: Any?, _ end: Any?) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = start; animation.toValue = end
            animation.duration = duration; animation.timingFunction = curve
            layer.add(animation, forKey: "peek.exit.\(key)")
        }
        add(still, "bounds", NSValue(rect: CGRect(origin: .zero, size: from.size)), NSValue(rect: CGRect(origin: .zero, size: target.size)))
        add(still, "position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: CGPoint(x: target.midX, y: target.midY)))
        add(still, "cornerRadius", PeekMotion.cardRadius, radius)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = stillFade.values; fade.keyTimes = stillFade.times; fade.duration = duration
        still.add(fade, forKey: "peek.exit.opacity")
        let lift = CABasicAnimation(keyPath: "opacity")
        lift.fromValue = 1; lift.toValue = 0; lift.duration = duration
        lift.timingFunction = CAMediaTimingFunction(name: .easeIn)
        dimLayer.add(lift, forKey: "peek.exit.dim")
        // Closing into the link ends as a pale pill around its words, which then fades.
        if let (rect, label) = pill {
            let chip = CALayer()
            chip.frame = rect; chip.cornerRadius = 6
            chip.backgroundColor = NSColor(white: 0.86, alpha: 0.95).cgColor
            let text = CATextLayer()
            text.string = NSAttributedString(string: label, attributes: [.font: BamType.sans(13, weight: .medium), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            text.contentsScale = host.window?.backingScaleFactor ?? 2
            text.truncationMode = .end
            text.frame = CGRect(x: 6, y: (rect.height - 17) / 2, width: max(0, rect.width - 12), height: 17)
            chip.addSublayer(text)
            root.addSublayer(chip)
            let show = CAKeyframeAnimation(keyPath: "opacity")
            let cut = duration / total
            show.values = [0, 0, 1, 0]; show.keyTimes = [0, NSNumber(value: cut * 0.6), NSNumber(value: cut), 1]
            show.duration = total
            chip.add(show, forKey: "peek.exit.pill")
            chip.opacity = 0
        }
        // Keep the ghost until the pill has faded.
        let keep = CABasicAnimation(keyPath: "opacity"); keep.fromValue = 1; keep.toValue = 1; keep.duration = total
        root.add(keep, forKey: "peek.exit.keep")
        still.frame = target; still.cornerRadius = radius; still.opacity = 0; dimLayer.opacity = 0
        CATransaction.commit()
    }
}

/// Captures part of one of Bam's own windows (no Screen Recording permission is needed for that).
enum PeekWindowCapture {
    static func image(_ rect: CGRect, window: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(rect, .optionIncludingWindow, window, [.bestResolution, .boundsIgnoreFraming])
    }
}

/// Peek's round actions beside the card: near-black circles with a white symbol.
@MainActor final class PeekRoundButton: NSButton {
    private var hovering = false
    init(symbol: String, label: String, toolTip: String) {
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true; title = ""
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = .white
        self.toolTip = toolTip
        setAccessibilityLabel(label)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6; layer?.shadowOffset = CGSize(width: 0, height: -2)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        let base: CGFloat = isEnabled ? (hovering ? 0.24 : 0.08) : 0.08
        layer?.backgroundColor = NSColor(white: base, alpha: isEnabled ? 0.94 : 0.5).cgColor
        contentTintColor = .white.withAlphaComponent(isEnabled ? 1 : 0.4)
    }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override var isEnabled: Bool { didSet { paint() } }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.75 : 1 } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The soft dim behind the card; clicks fall through to the backdrop, which closes the Peek.
@MainActor final class PeekDim: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class PeekCard: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { /* Blank card area is not the dimmed backdrop. */ }
}

/// Shared by Peek and Little Bam; no external URL is handed to NSWorkspace.
enum PreviewURLPolicy {
    /// An extension's own page in a pop-out window Bam opened for that extension (`windows.create`). The runtime has
    /// already checked the page belongs to the requesting extension; the address field never uses this.
    static func allowsExtensionWindowPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "webkit-extension" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    static func resolveAddress(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let direct = URL(string: text), allows(direct) { return direct }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")
        if !text.contains("://"), !text.contains(where: { $0.isWhitespace }), text.contains(".") || local,
           let url = URL(string: (local ? "http://" : "https://") + text), allows(url) { return url }
        if URLComponents(string: text)?.scheme != nil { return nil }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }
}

/// Owns delegates and observations only while the web view is in a transient host.
@MainActor final class PreviewWebContent: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private(set) var status: String?
    var onChange: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)?
    var onVisit: ((String, String) -> Void)?
    /// Set only for a pop-out window Bam opened for an extension: whether this extension page may load now. Both
    /// navigation gates ask it every time (same extension origin, still owned and enabled in this profile); while it
    /// is nil only http/https load.
    var extensionPageAuthorization: ((URL) -> Bool)?
    private var uploadPanel: NSOpenPanel?
    private var uploadCompletion: (([URL]?) -> Void)?
    private var expectedDownloadNavigation = false
    private var observations: [NSKeyValueObservation] = []
    private let beforeLoad: PreviewNavigationReadiness?
    private var loadGeneration = UUID()

    init(webView: WKWebView, beforeLoad: PreviewNavigationReadiness? = nil) {
        self.webView = webView
        self.beforeLoad = beforeLoad
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setAccessibilityLabel("Preview web content")
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.onChange?() } }
        ]
    }

    private func allowsNavigation(to url: URL) -> Bool {
        PreviewURLPolicy.allows(url) || (PreviewURLPolicy.allowsExtensionWindowPage(url) && extensionPageAuthorization?(url) == true)
    }
    @discardableResult func load(url: URL) -> Bool {
        guard allowsNavigation(to: url) else { status = "Only HTTP and HTTPS pages can open here"; onChange?(); return false }
        guard let web = webView else { return false }
        status = nil
        let token = UUID(); loadGeneration = token
        (web as? PreviewWKWebView)?.requestedURL = url
        (web as? PreviewWKWebView)?.isProvisionalNavigation = true
        (web as? PreviewWKWebView)?.pendingReadyURL = url
        let navigate: @MainActor () -> Void = { [weak self, weak web] in
            guard let self, let web, self.webView === web, self.loadGeneration == token else { return }
            (web as? PreviewWKWebView)?.pendingReadyURL = nil
            web.load(URLRequest(url: url))
            self.onChange?()
        }
        if let beforeLoad { beforeLoad(navigate) } else { navigate() }
        onChange?()
        return true
    }

    func takeWebView() -> WKWebView? {
        loadGeneration = UUID()
        cancelFileSelection()
        observations.removeAll()
        let web = webView
        web?.navigationDelegate = nil; web?.uiDelegate = nil
        web?.removeFromSuperview()
        webView = nil
        onChange = nil; onCloseRequest = nil; onDownload = nil; onVisit = nil
        return web
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, allowsNavigation(to: url) else {
            if navigationAction.targetFrame?.isMainFrame != false { status = "This link cannot open in the preview"; onChange?() }
            decisionHandler(.cancel); return
        }
        if navigationAction.shouldPerformDownload {
            expectedDownloadNavigation = onDownload != nil
            if onDownload == nil { status = "Downloads are unavailable in this preview"; onChange?() }
            decisionHandler(onDownload == nil ? .cancel : .download)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false { (webView as? PreviewWKWebView)?.requestedURL = url }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url, allowsNavigation(to: url) else {
            status = "This content cannot be displayed in the preview"; onChange?(); decisionHandler(.cancel); return
        }
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("attachment") == true
        if attachment || !navigationResponse.canShowMIMEType {
            expectedDownloadNavigation = onDownload != nil
            if onDownload == nil { status = "Downloads are unavailable in this preview"; onChange?() }
            decisionHandler(onDownload == nil ? .cancel : .download)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        forwardDownload(download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        forwardDownload(download)
    }
    private func forwardDownload(_ download: WKDownload) {
        guard let onDownload else { download.cancel(nil); return }
        status = "Download started"; onChange?()
        onDownload(download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, PreviewURLPolicy.allows(url) { webView.load(navigationAction.request) }
        return nil
    }
    func webViewDidClose(_ webView: WKWebView) { onCloseRequest?() }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        (webView as? PreviewWKWebView)?.isProvisionalNavigation = true
        expectedDownloadNavigation = false; status = nil; onChange?()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? PreviewWKWebView)?.isProvisionalNavigation = false
        onChange?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        (webView as? PreviewWKWebView)?.isProvisionalNavigation = false
        status = nil; onChange?()
        if let url = webView.url, PreviewURLPolicy.allows(url) {
            onVisit?(webView.title ?? url.host ?? "Page", url.absoluteString)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        let failure = error as NSError
        (webView as? PreviewWKWebView)?.isProvisionalNavigation = false
        guard failure.code != NSURLErrorCancelled else { return }
        if expectedDownloadNavigation && failure.domain == "WebKitErrorDomain" && failure.code == 102 { return }
        status = "Couldn’t load page — try Reload"; onChange?()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { status = "Page stopped — try Reload"; onChange?() }

    // WebKit disables macOS HTML file inputs unless its UI delegate implements this.
    // https://developer.apple.com/documentation/webkit/wkopenpanelparameters
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard self.webView === webView, !webView.isHiddenOrHasHiddenAncestor,
              let window = webView.window, window.isVisible, window.attachedSheet == nil,
              uploadCompletion == nil else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Choose files for \(frame.request.url?.host ?? "this page")"
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        uploadPanel = panel; uploadCompletion = completionHandler
        panel.beginSheetModal(for: window) { [weak self, weak panel] result in
            guard let self, let panel, self.uploadPanel === panel else { return }
            let completion = self.uploadCompletion
            self.uploadPanel = nil; self.uploadCompletion = nil
            completion?(result == .OK ? panel.urls : nil)
        }
    }

    func cancelFileSelection() {
        let panel = uploadPanel
        let completion = uploadCompletion
        uploadPanel = nil; uploadCompletion = nil
        panel?.cancel(nil)
        completion?(nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard !webView.isHiddenOrHasHiddenAncestor, let window = webView.window else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page message"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard !webView.isHiddenOrHasHiddenAncestor, let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page confirmation"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { result in completionHandler(result == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard !webView.isHiddenOrHasHiddenAncestor, let window = webView.window else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page input"; alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { result in completionHandler(result == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
}
