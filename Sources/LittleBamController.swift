import AppKit
import WebKit

/// One Space the Little Bam window can open its page in.
struct LittleBamDestination: Equatable {
    let id: Int
    let name: String
    let symbol: String
    let colorIndex: Int
    /// Where a plain ⌘O lands: the current Space, or the one that belongs
    /// to this window's login profile.
    let isDefault: Bool
}

/// Bam's compact browser window, named Little Bam in the UI: a translucent
/// bar over the page with the login profile, the site, extensions, Copy
/// Link, and an "Open in <Space>" control whose menu picks another Space.
/// Product reference: Arc's official 2021 release notes describe a compact lookup
/// window and Command-O promotion into the main browser:
/// https://resources.arc.net/hc/en-us/articles/20498463803799-Arc-for-macOS-2021-Release-Notes
@MainActor final class LittleBamController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onPromote: ((WKWebView) -> Void)?
    /// Opens the page in a chosen Space instead of the default one.
    var onPromoteTo: ((WKWebView, Int) -> Void)?
    var canPromote: (() -> Bool)?
    var onClose: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)? { didSet { content?.onDownload = onDownload } }
    var onVisit: ((String, String) -> Void)? { didSet { content?.onVisit = onVisit } }
    /// The Spaces to offer, read fresh each time the menu or label needs them.
    var destinations: (() -> [LittleBamDestination])? { didSet { refresh() } }
    /// The extension actions for this window's page; nil hides the button.
    var extensionsMenu: ((NSView) -> NSMenu?)? { didSet { root.extensions.isHidden = extensionsMenu == nil; root.needsLayout = true } }
    var profileName: String = "Default" { didSet { root.profile.title = profileName; root.needsLayout = true } }
    var webView: WKWebView? { content?.webView }

    private var content: PreviewWebContent?
    private let root = LittleOrbitRoot()
    private var didClose = false
    private let beforeLoad: PreviewNavigationReadiness?

    init(websiteDataStore: WKWebsiteDataStore, configure: ((WKWebViewConfiguration) -> Void)? = nil, beforeLoad: PreviewNavigationReadiness? = nil) {
        self.beforeLoad = beforeLoad
        let window = LittleOrbitWindow(contentRect: NSRect(x: 0, y: 0, width: LittleBamMetrics.width, height: LittleBamMetrics.height),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Little Bam"; window.contentMinSize = NSSize(width: 520, height: 320)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false; window.delegate = self
        // Bam runs its own quick zoom in and out (see show and close).
        window.animationBehavior = .none
        // Follows Bam's Appearance preference (NSApp.appearance), like the main window.
        window.contentView = root
        window.backgroundColor = BrowserChrome.pageSurface
        window.onEscape = { [weak self] in self?.close() }
        window.onPromote = { [weak self] in self?.promoteToOrbit() }
        window.onLocation = { [weak self] in self?.focusAddress() }
        window.onReload = { [weak self] in self?.reloadAction() }
        window.onBack = { [weak self] in self?.backAction() }
        window.onForward = { [weak self] in self?.forwardAction() }
        window.onCopyLink = { [weak self] in self?.copyLink() }
        root.address.target = self; root.address.action = #selector(submitAddress); root.address.delegate = self
        root.site.target = self; root.site.action = #selector(editAddress)
        root.back.target = self; root.back.action = #selector(backAction)
        root.forward.target = self; root.forward.action = #selector(forwardAction)
        root.reload.target = self; root.reload.action = #selector(reloadAction)
        root.extensions.target = self; root.extensions.action = #selector(showExtensions(_:))
        root.copyLink.target = self; root.copyLink.action = #selector(copyLinkAction)
        root.promote.onOpen = { [weak self] in self?.promoteToOrbit() }
        root.promote.onPick = { [weak self] anchor in self?.showDestinations(from: anchor) }
        root.extensions.isHidden = true
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = websiteDataStore
        configuration.adoptSafariUserAgent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configure?(configuration)
        let page = PreviewWKWebView(frame: .zero, configuration: configuration)
        ContentBlocking.shared.track(page)
        BrowserPageGestures.configure(page)
        adopt(webView: page)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult func open(url: URL) -> Bool {
        guard !didClose else { return false }
        return content?.load(url: url) ?? false
    }
    /// A pop-out window Bam opened for an extension: its own page, in the extension's own WebKit configuration, with
    /// `authorize` asked at both navigation gates (ordinary pages still load as usual).
    @discardableResult func openExtensionPage(_ url: URL, configuration: WKWebViewConfiguration, authorize: @escaping (URL) -> Bool) -> Bool {
        guard !didClose else { return false }
        adopt(webView: PreviewWKWebView(frame: .zero, configuration: configuration))
        content?.extensionPageAuthorization = authorize
        return content?.load(url: url) ?? false
    }

    /// Moves an existing Peek web view into this window without reloading it.
    func adopt(webView: WKWebView) {
        guard !didClose else { return }
        let previous = content?.takeWebView()
        if previous !== webView { previous?.stopLoading() }
        webView.removeFromSuperview()
        let content = PreviewWebContent(webView: webView, beforeLoad: beforeLoad)
        self.content = content
        content.onDownload = onDownload
        content.onVisit = onVisit
        content.onChange = { [weak self] in self?.refresh() }
        content.onCloseRequest = { [weak self] in self?.close() }
        root.browserHost.addSubview(webView)
        webView.frame = root.browserHost.bounds; webView.autoresizingMask = [.width, .height]
        root.browserHost.addSubview(root.progress, positioned: .above, relativeTo: webView)
        // A queued navigation belongs to the adopted view, not its obsolete host.
        if let requested = (webView as? PreviewWKWebView)?.pendingReadyURL { _ = content.load(url: requested) }
        refresh()
    }

    func show(relativeTo parent: NSWindow? = nil) {
        guard !didClose, let window else { return }
        if let parent, let screen = parent.screen {
            let available = screen.visibleFrame
            let width = min(LittleBamMetrics.width, available.width-40), height = min(LittleBamMetrics.height, available.height-40)
            let origin = NSPoint(x: min(max(available.minX+20,parent.frame.midX-width/2),available.maxX-width-20),
                                 y: min(max(available.minY+20,parent.frame.midY-height/2),available.maxY-height-20))
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width,height: height)), display: false)
        } else { window.center() }
        // Zooms out of the middle of where it lands, fast (about 80 ms), like the reference.
        let final = window.frame
        if LittleBamMetrics.animates, !window.isVisible, let window = window as? LittleOrbitWindow {
            window.setFrame(LittleBamMetrics.scaled(final, by: 0.25), display: false)
            showWindow(nil); window.makeKeyAndOrderFront(nil)
            window.zoom(to: final, alpha: 1, duration: 0.14, spring: true, completion: nil)
        } else {
            showWindow(nil); window.makeKeyAndOrderFront(nil)
        }
        if webView?.url == nil { focusAddress() } else { window.makeFirstResponder(webView) }
    }

    func promoteToOrbit() {
        guard canPromote?() != false, let callback = onPromote, let web = content?.takeWebView() else { return }
        content = nil
        close()
        callback(web)
    }
    /// Opens the page in the chosen Space; the default Space takes the plain path.
    func promote(to spaceID: Int) {
        let targets = destinations?() ?? []
        if targets.first(where: { $0.id == spaceID })?.isDefault != false { promoteToOrbit(); return }
        guard let callback = onPromoteTo, let web = content?.takeWebView() else { return }
        content = nil
        close()
        callback(web, spaceID)
    }

    override func close() {
        // Shrinks toward its middle while fading (about 70 ms), then closes for real.
        if LittleBamMetrics.animates, !didClose, let window, window.isVisible, !isLeaving {
            isLeaving = true
            // The page stays in the window while it shrinks; it is let go once the window is gone.
            let target = LittleBamMetrics.scaled(window.frame, by: 0.55)
            guard let window = window as? LittleOrbitWindow else { super.close(); return }
            window.zoom(to: target, alpha: 0, duration: 0.1, spring: false) { [weak self] in self?.finishClosing() }
            return
        }
        super.close()
        cleanup()
    }
    private var isLeaving = false
    private func finishClosing() {
        super.close()
        cleanup()
        window?.alphaValue = 1
    }
    func windowWillClose(_ notification: Notification) { cleanup() }
    /// ⌘W and the close button take the same quick shrink as close().
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard LittleBamMetrics.animates, !isLeaving, !didClose, sender.isVisible else { return true }
        close()
        return false
    }
    func windowDidResize(_ notification: Notification) { (window as? LittleOrbitWindow)?.centerTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { (window as? LittleOrbitWindow)?.centerTrafficLights(); refreshSpaces() }
    func windowDidResignKey(_ notification: Notification) { (window as? LittleOrbitWindow)?.centerTrafficLights() }

    private func cleanup() {
        guard !didClose else { return }
        didClose = true
        content?.takeWebView()?.stopLoading(); content = nil
        if let window = window as? LittleOrbitWindow {
            window.onEscape = nil; window.onPromote = nil; window.onLocation = nil
            window.onReload = nil; window.onBack = nil; window.onForward = nil; window.onCopyLink = nil
        }
        onClose?()
    }

    /// Shows the full address for editing in place of the site name.
    func focusAddress() {
        root.editing = true
        root.address.stringValue = webView?.url?.absoluteString ?? ""
        window?.makeFirstResponder(root.address); root.address.selectText(nil)
    }
    @objc private func editAddress() { focusAddress() }
    @objc private func submitAddress() {
        guard let url = PreviewURLPolicy.resolveAddress(root.address.stringValue), open(url: url) else {
            // Keep the field up with the text selected so it can be corrected.
            root.address.toolTip = "Enter an HTTP/HTTPS address or search"
            root.address.placeholderString = root.address.toolTip
            root.editing = true
            window?.makeFirstResponder(root.address); root.address.selectText(nil)
            NSSound.beep(); return
        }
        root.editing = false
        window?.makeFirstResponder(webView)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        // Leaving the field (Tab, a click elsewhere) returns to the site name.
        // Return ends editing too, before the action runs; submitAddress
        // decides that case so a rejected address is not swallowed here.
        let movement = (obj.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        if movement == NSTextMovement.return.rawValue { return }
        root.editing = false
        refresh()
    }
    @objc private func backAction() { webView?.goBack() }
    @objc private func forwardAction() { webView?.goForward() }
    @objc private func reloadAction() {
        guard let web = webView else { return }
        if web.isLoading { web.stopLoading() }
        else if web.url == nil, let url = (web as? PreviewWKWebView)?.requestedURL { _ = open(url: url) }
        else { web.reload() }
    }
    @objc private func showExtensions(_ sender: NSView) {
        guard let menu = extensionsMenu?(sender) else { return }
        menu.font = BamType.sans(13)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
    @objc private func copyLinkAction() { copyLink() }
    /// Copies the page address (⇧⌘C) and flashes the button to say so.
    func copyLink() {
        guard let url = webView?.url ?? (webView as? PreviewWKWebView)?.requestedURL else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
        root.copyLink.flash(symbol: "checkmark", toolTip: "Copied")
    }
    private func showDestinations(from anchor: NSView) {
        let targets = destinations?() ?? []
        guard !targets.isEmpty else { promoteToOrbit(); return }
        let menu = NSMenu()
        menu.font = BamType.sans(13)
        let heading = NSMenuItem(title: "Open this page in", action: nil, keyEquivalent: ""); heading.isEnabled = false
        menu.addItem(heading)
        for target in targets {
            let item = NSMenuItem(title: target.name, action: #selector(pickDestination(_:)), keyEquivalent: target.isDefault ? "o" : "")
            item.target = self; item.tag = target.id
            item.image = SidebarSymbol.image(named: target.symbol, color: ArkPalette.spaceColor(target.colorIndex), pointSize: 13)
                ?? NSImage(systemSymbolName: target.symbol, accessibilityDescription: nil)
            item.state = target.isDefault ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.maxX, y: anchor.bounds.maxY + 4), in: anchor)
    }
    @objc private func pickDestination(_ sender: NSMenuItem) { promote(to: sender.tag) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if webView?.url == nil { close() } else { root.editing = false; window?.makeFirstResponder(webView) }
            return true
        }
        return false
    }
    private func refresh() {
        guard let content, let web = content.webView else { return }
        let title = web.title?.isEmpty == false ? web.title! : "Little Bam"
        window?.title = title == "Little Bam" ? title : "\(title) — Little Bam"
        if root.address.currentEditor() == nil { root.address.stringValue = web.url?.absoluteString ?? "" }
        let host = web.url?.host?.replacingOccurrences(of: "www.", with: "", options: .anchored)
        root.site.title = host ?? (web.isLoading ? "Loading…" : "Little Bam")
        root.site.toolTip = web.url?.absoluteString ?? "Click to enter an address (\(ShortcutStore.shared.combo(for: .openLocation).compact))"
        root.back.isEnabled = web.canGoBack; root.forward.isEnabled = web.canGoForward
        root.reload.symbol = web.isLoading ? "xmark" : "arrow.clockwise"
        root.reload.toolTip = web.isLoading ? "Stop loading" : "Reload (⌘R)"
        root.progress.doubleValue = web.estimatedProgress; root.progress.isHidden = !web.isLoading
        refreshSpaces()
        root.copyLink.isEnabled = web.url != nil
        root.needsLayout = true
    }
    /// The frame color and the Open label follow the Space a plain ⌘O lands in. Also called by the
    /// browser when the Spaces change, since that changes nothing in this window's page.
    func refreshSpaces() {
        guard content?.webView != nil else { return }
        let targets = destinations?() ?? []
        root.tint = targets.first(where: \.isDefault)?.colorIndex
        let landing = targets.first(where: \.isDefault)?.name ?? "Bam"
        if root.promote.spaceName != landing { root.promote.spaceName = landing; root.needsLayout = true }
        root.promote.hasChoices = targets.count > 1
    }
}

@MainActor private final class LittleOrbitWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onPromote: (() -> Void)?
    var onLocation: (() -> Void)?
    var onReload: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onCopyLink: (() -> Void)?
    private var zoomLink: CADisplayLink?
    private var zoomFrom = NSRect.zero, zoomTo = NSRect.zero
    private var zoomAlpha: (CGFloat, CGFloat) = (1, 1)
    private var zoomBegan: CFTimeInterval = 0, zoomDuration: CFTimeInterval = 0, zoomSpring = false
    private var zoomDone: (() -> Void)?
    /// Frame-by-frame zoom of the window (AppKit drops animated frames on a window just ordered in).
    /// The open uses a critically damped spring (ω = 40); the close accelerates out.
    func zoom(to target: NSRect, alpha: CGFloat, duration: CFTimeInterval, spring: Bool, completion: (() -> Void)?) {
        zoomLink?.invalidate()
        zoomFrom = frame; zoomTo = target; zoomAlpha = (alphaValue, alpha)
        zoomBegan = CACurrentMediaTime(); zoomDuration = duration; zoomSpring = spring; zoomDone = completion
        guard let view = contentView else { setFrame(target, display: true); alphaValue = alpha; completion?(); return }
        let link = view.displayLink(target: self, selector: #selector(zoomFrame(_:)))
        link.add(to: .main, forMode: .common)
        zoomLink = link
    }
    @objc private func zoomFrame(_ link: CADisplayLink) {
        let t = CACurrentMediaTime() - zoomBegan
        let p: CGFloat
        if zoomSpring { let w = 40.0; p = CGFloat(1 - (1 + w * t) * exp(-w * t)) }
        else { let u = min(1, t / zoomDuration); p = CGFloat(u * u) }
        let done = zoomSpring ? (p > 0.995 || t > 0.4) : t >= zoomDuration
        let f = done ? zoomTo : NSRect(x: zoomFrom.minX + (zoomTo.minX - zoomFrom.minX) * p, y: zoomFrom.minY + (zoomTo.minY - zoomFrom.minY) * p,
                                       width: zoomFrom.width + (zoomTo.width - zoomFrom.width) * p,
                                       height: zoomFrom.height + (zoomTo.height - zoomFrom.height) * p)
        setFrame(f.integral, display: true)
        alphaValue = done ? zoomAlpha.1 : zoomAlpha.0 + (zoomAlpha.1 - zoomAlpha.0) * min(1, p)
        if done {
            link.invalidate(); zoomLink = nil
            let completion = zoomDone; zoomDone = nil; completion?()
        }
    }

    /// The traffic lights sit centered in Little Bam's 44-point bar, not the system's shorter titlebar.
    func centerTrafficLights() {
        // In full screen the buttons live in the separate titlebar window AppKit reveals at the top
        // of the screen; this window's bar height means nothing there, so AppKit keeps them.
        guard let content = contentView, !styleMask.contains(.fullScreen) else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let centerInWindow = NSPoint(x: 0, y: content.frame.height - LittleBamMetrics.barHeight / 2)
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type), button.window === self, let container = button.superview else { continue }
            let center = container.convert(centerInWindow, from: nil)
            let origin = NSPoint(x: LittleBamMetrics.lightsInset + CGFloat(index) * 20, y: (center.y - button.frame.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil, !(firstResponder is NSTextView) { onEscape?(); return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" { onCopyLink?(); return true }
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control), !flags.contains(.shift) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": onPromote?(); return true
            case "l": onLocation?(); return true
            case "r": onReload?(); return true
            case "[": onBack?(); return true
            case "]": onForward?(); return true
            case "w": performClose(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Little Bam's proportions, measured against the reference compact window: a 46-point bar in
/// the Space's color holding one field plate and the Open control, and the page flush below it.
enum LittleBamMetrics {
    static let width: CGFloat = 920
    static let height: CGFloat = 680
    static let barHeight: CGFloat = 46
    static let lightsInset: CGFloat = 16
    static let plateHeight: CGFloat = 30
    static let plateStart: CGFloat = 84
    static let edgeInset: CGFloat = 10
    /// Off under Reduce Motion, and for the native test fixtures, which check window state synchronously.
    @MainActor static var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-test") }
    }
    static func scaled(_ frame: NSRect, by scale: CGFloat) -> NSRect {
        let width = frame.width * scale, height = frame.height * scale
        return NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height).integral
    }
}

/// The window: a bar in the Space's color the traffic lights share with one field plate (profile,
/// the site, extensions, Copy Link) and the Open control, then the page edge to edge.
/// Back, Forward and Reload are keys only (⌘[ ⌘] ⌘R), as in the reference.
@MainActor private final class LittleOrbitRoot: NSView {
    static let barHeight: CGFloat = LittleBamMetrics.barHeight
    let bar = NSView()
    let plate = NSView()
    let browserHost = LittleOrbitBrowserHost()
    let profile = LittleBamChip(symbol: "person.crop.circle", title: "Default")
    let site = LittleBamSiteButton()
    let address = NSTextField()
    let back = LittleBamIconButton(symbol: "chevron.left", label: "Back")
    let forward = LittleBamIconButton(symbol: "chevron.right", label: "Forward")
    let reload = LittleBamIconButton(symbol: "arrow.clockwise", label: "Reload or stop")
    let extensions = LittleBamIconButton(symbol: "puzzlepiece.extension", label: "Extensions")
    let copyLink = LittleBamIconButton(symbol: "link", label: "Copy link")
    let promote = LittleBamOpenControl()
    let progress = NSProgressIndicator()
    /// The Space color the frame wears; nil is Bam's neutral chrome.
    var tint: Int? { didSet { if tint != oldValue { applyAppearanceColors() } } }
    /// While editing, the address field replaces the site name.
    var editing = false { didSet { address.isHidden = !editing; site.isHidden = editing; needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        browserHost.wantsLayer = true
        [back, forward, reload].forEach { $0.isHidden = true }
        addSubview(browserHost)
        addSubview(bar)
        bar.addSubview(plate)
        [profile, back, forward, reload, site, address, extensions, copyLink, promote].forEach(bar.addSubview)
        browserHost.addSubview(progress, positioned: .above, relativeTo: nil)
        profile.toolTip = "Login profile"
        address.placeholderString = "Search or enter a web address"; address.setAccessibilityLabel("Little Bam address")
        address.font = BamType.sans(13, weight: .medium); address.textColor = LittleBamTone.tone(1)
        address.isBezeled = false; address.isBordered = false; address.drawsBackground = false
        address.focusRingType = .none; address.alignment = .center
        address.usesSingleLineMode = true; address.lineBreakMode = .byTruncatingTail
        (address.cell as? NSTextFieldCell)?.isScrollable = true
        address.isHidden = true
        promote.toolTip = "Move this same page into Bam (⌘O)"
        copyLink.toolTip = "Copy link (⇧⌘C)"
        extensions.toolTip = "Extensions"
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true
        applyAppearanceColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func applyAppearanceColors() {
        layer?.backgroundColor = resolvedCGColor(LittleBamTone.frame(tint), for: self)
        plate.layer?.backgroundColor = resolvedCGColor(LittleBamTone.plate, for: self)
        browserHost.layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearanceColors() }
    override func layout() {
        super.layout()
        let width = bounds.width, barHeight = Self.barHeight
        bar.frame = NSRect(x: 0, y: 0, width: width, height: barHeight)
        browserHost.frame = NSRect(x: 0, y: barHeight, width: width, height: max(0, bounds.height - barHeight))
        progress.frame = NSRect(x: 0, y: 0, width: browserHost.bounds.width, height: 3)
        let plateHeight = LittleBamMetrics.plateHeight
        let y = ((barHeight - plateHeight) / 2).rounded()
        // Traffic lights own the first 84 points.
        let plateStart = LittleBamMetrics.plateStart
        var right = width - LittleBamMetrics.edgeInset
        let openWidth = promote.intrinsicContentSize.width
        promote.frame = NSRect(x: right - openWidth, y: y, width: openWidth, height: plateHeight); right = promote.frame.minX - 7
        plate.frame = NSRect(x: plateStart, y: y, width: max(0, right - plateStart), height: plateHeight)
        let icon: CGFloat = 26, iy = y + (plateHeight - icon) / 2
        let x = plate.frame.minX + 4
        profile.frame = NSRect(x: x, y: y + 4, width: profile.intrinsicContentSize.width, height: plateHeight - 8)
        let leftEnd = profile.frame.maxX + 6
        var plateRight = plate.frame.maxX - 4
        copyLink.frame = NSRect(x: plateRight - icon, y: iy, width: icon, height: icon); plateRight -= icon + 2
        if !extensions.isHidden { extensions.frame = NSRect(x: plateRight - icon, y: iy, width: icon, height: icon); plateRight -= icon }
        let rightStart = plateRight - 6
        // The site name centers in the plate when there is room, else in the gap beside the chip.
        let gap = NSRect(x: leftEnd, y: y + 3, width: max(0, rightStart - leftEnd), height: plateHeight - 6)
        let siteWidth = min(gap.width, max(120, site.intrinsicContentSize.width))
        var siteX = plate.frame.midX - siteWidth / 2
        siteX = min(max(siteX, gap.minX), max(gap.minX, gap.maxX - siteWidth))
        site.frame = NSRect(x: siteX, y: gap.minY, width: siteWidth, height: gap.height)
        address.frame = gap.insetBy(dx: 4, dy: 3)
        (window as? LittleOrbitWindow)?.centerTrafficLights()
    }
}

@MainActor private final class LittleOrbitBrowserHost: NSView {
    override var isFlipped: Bool { true }
}

/// Little Bam's bar tones: white on dark chrome, near-black on light chrome.
@MainActor enum LittleBamTone {
    static func tone(_ alpha: CGFloat) -> NSColor {
        .chrome(light: NSColor(white: 0.08, alpha: min(1, alpha)), dark: NSColor(white: 1, alpha: alpha))
    }
    /// The window frame in the Space's color: a pale wash on light chrome, a deep one on dark.
    static func frame(_ colorIndex: Int?) -> NSColor {
        guard let colorIndex else { return BrowserChrome.windowBackground }
        let base = ArkPalette.spaceColor(colorIndex)
        return .chrome(light: base.blended(withFraction: 0.62, of: NSColor(white: 0.97, alpha: 1)) ?? base,
                       dark: base.blended(withFraction: 0.84, of: NSColor(white: 0.11, alpha: 1)) ?? base)
    }
    /// The field plate: a shade lighter than the bar.
    static let plate = NSColor.chrome(light: NSColor(white: 1, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.07))
    /// The Open control: a shade deeper than the bar.
    static let raised = NSColor.chrome(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 0, alpha: 0.28))
    static let raisedHover = NSColor.chrome(light: NSColor(white: 0, alpha: 0.11), dark: NSColor(white: 0, alpha: 0.4))
}

/// A translucent 30-point square with one symbol; hover lifts it.
@MainActor final class LittleBamIconButton: NSButton {
    var symbol: String { didSet { paint() } }
    private var hovering = false
    private var flashWork: DispatchWorkItem?
    init(symbol: String, label: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        title = ""
        layer?.cornerRadius = 8
        setAccessibilityLabel(label)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel())?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = LittleBamTone.tone(isEnabled ? 0.85 : 0.35)
        layer?.backgroundColor = hovering && isEnabled ? resolvedCGColor(LittleBamTone.tone(0.12), for: self) : NSColor.clear.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var isEnabled: Bool { didSet { paint() } }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.7 : 1 } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    /// Briefly shows another symbol, then returns.
    func flash(symbol flashed: String, toolTip: String) {
        // The resting look is captured once; a second flash during the first
        // must not capture the flashed symbol as the thing to return to.
        if flashWork == nil { resting = (symbol, self.toolTip) }
        flashWork?.cancel()
        symbol = flashed; self.toolTip = toolTip
        let work = DispatchWorkItem { [weak self] in
            guard let self, let resting = self.resting else { return }
            self.symbol = resting.symbol; self.toolTip = resting.toolTip
            self.flashWork = nil; self.resting = nil
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
    private var resting: (symbol: String, toolTip: String?)?
}

/// A small translucent chip: symbol + word (the login profile).
@MainActor final class LittleBamChip: NSButton {
    init(symbol: String, title: String) {
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        // Informational: enabled so it isn't drawn dimmed, but it has no action.
        target = nil; action = nil
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        imagePosition = .imageLeading; imageHugsTitle = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = resolvedCGColor(LittleBamTone.tone(0.08), for: self)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(LittleBamTone.tone(0.08), for: self)
    }
    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: BamType.sans(12.5, weight: .semibold), .foregroundColor: LittleBamTone.tone(0.8)
            ])
            contentTintColor = LittleBamTone.tone(0.7)
        }
    }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += 22; return size }
}

/// The site name in the middle of the bar; clicking it edits the address.
@MainActor final class LittleBamSiteButton: NSButton {
    private var hovering = false
    init() {
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 8
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("Site; click to edit the address")
        title = "Little Bam"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: BamType.sans(13, weight: .medium), .foregroundColor: LittleBamTone.tone(0.9)
            ])
        }
    }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += 24; return size }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; layer?.backgroundColor = resolvedCGColor(LittleBamTone.tone(0.1), for: self) }
    override func mouseExited(with event: NSEvent) { hovering = false; layer?.backgroundColor = NSColor.clear.cgColor }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

/// "Open in **Space** ⌘O | ⌄": the main part promotes, the chevron picks.
@MainActor final class LittleBamOpenControl: NSView {
    var onOpen: (() -> Void)?
    var onPick: ((NSView) -> Void)?
    var spaceName = "Bam" { didSet { paint(); invalidateIntrinsicContentSize() } }
    var hasChoices = true { didSet { picker.isHidden = !hasChoices; invalidateIntrinsicContentSize(); needsLayout = true } }
    private let label = NSTextField(labelWithString: "")
    private let keycap = NSTextField(labelWithString: "⌘O")
    private let divider = NSView()
    private let picker = NSButton()
    private let main = NSButton()
    private var hovering = false
    private var pickerHovering = false
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0
        setAccessibilityElement(true); setAccessibilityRole(.group)
        main.isBordered = false; main.title = ""; main.setButtonType(.momentaryChange)
        main.target = self; main.action = #selector(openAction)
        main.setAccessibilityLabel("Open in Bam")
        main.wantsLayer = true; main.layer?.cornerRadius = 8
        picker.isBordered = false; picker.setButtonType(.momentaryChange)
        picker.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Choose a Space")?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        picker.contentTintColor = LittleBamTone.tone(0.8)
        picker.target = self; picker.action = #selector(pickAction)
        picker.setAccessibilityLabel("Choose a Space to open in")
        picker.wantsLayer = true; picker.layer?.cornerRadius = 8
        keycap.font = BamType.mono(10.5, weight: .semibold)
        keycap.textColor = LittleBamTone.tone(0.85)
        keycap.wantsLayer = true; keycap.layer?.cornerRadius = 5
        keycap.alignment = .center
        divider.wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        [main, label, keycap, divider, picker].forEach(addSubview)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        let text = NSMutableAttributedString(string: "Open in ", attributes: [
            .font: BamType.sans(13, weight: .medium), .foregroundColor: LittleBamTone.tone(0.78)
        ])
        text.append(NSAttributedString(string: spaceName, attributes: [
            .font: BamType.sans(13, weight: .bold), .foregroundColor: LittleBamTone.tone(1)
        ]))
        label.attributedStringValue = text
        main.setAccessibilityLabel("Open in \(spaceName)")
        layer?.backgroundColor = resolvedCGColor(hovering || pickerHovering ? LittleBamTone.raisedHover : LittleBamTone.raised, for: self)
        layer?.borderColor = NSColor.clear.cgColor
        picker.layer?.backgroundColor = pickerHovering ? resolvedCGColor(LittleBamTone.tone(0.12), for: self) : NSColor.clear.cgColor
        keycap.layer?.backgroundColor = resolvedCGColor(LittleBamTone.tone(0.14), for: self)
        divider.layer?.backgroundColor = resolvedCGColor(LittleBamTone.tone(0.14), for: self)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var intrinsicContentSize: NSSize {
        let labelWidth = min(220, ceil(label.attributedStringValue.size().width) + 6)
        return NSSize(width: 12 + labelWidth + 8 + 30 + (hasChoices ? 1 + 26 : 0) + 8, height: 30)
    }
    override func layout() {
        super.layout()
        let pickerWidth: CGFloat = hasChoices ? 26 : 0
        main.frame = NSRect(x: 0, y: 0, width: bounds.width - pickerWidth - (hasChoices ? 1 : 0), height: bounds.height)
        keycap.frame = NSRect(x: main.frame.maxX - 8 - 30, y: 6, width: 30, height: 18)
        label.frame = NSRect(x: 12, y: 6, width: max(0, keycap.frame.minX - 8 - 12), height: 18)
        divider.frame = NSRect(x: main.frame.maxX, y: 6, width: hasChoices ? 1 : 0, height: bounds.height - 12)
        picker.frame = NSRect(x: divider.frame.maxX, y: 0, width: pickerWidth, height: bounds.height)
    }
    @objc private func openAction() { onOpen?() }
    @objc private func pickAction() { onPick?(self) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseMoved(with event: NSEvent) {
        let inPicker = hasChoices && picker.frame.contains(convert(event.locationInWindow, from: nil))
        if inPicker != pickerHovering { pickerHovering = inPicker; paint() }
    }
    override func mouseExited(with event: NSEvent) { hovering = false; pickerHovering = false; paint() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
