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
        let window = LittleOrbitWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Little Bam"; window.contentMinSize = NSSize(width: 520, height: 320)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = root; window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
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
        adopt(webView: PreviewWKWebView(frame: .zero, configuration: configuration))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult func open(url: URL) -> Bool {
        guard !didClose else { return false }
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
        // A queued navigation belongs to the adopted view, not its obsolete host.
        if let requested = (webView as? PreviewWKWebView)?.pendingReadyURL { _ = content.load(url: requested) }
        refresh()
    }

    func show(relativeTo parent: NSWindow? = nil) {
        guard !didClose, let window else { return }
        if let parent, let screen = parent.screen {
            let available = screen.visibleFrame
            let width = min(760, available.width-40), height = min(620, available.height-40)
            let origin = NSPoint(x: min(max(available.minX+20,parent.frame.midX-width/2),available.maxX-width-20),
                                 y: min(max(available.minY+20,parent.frame.midY-height/2),available.maxY-height-20))
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width,height: height)), display: false)
        } else { window.center() }
        showWindow(nil); window.makeKeyAndOrderFront(nil)
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
        super.close()
        cleanup()
    }
    func windowWillClose(_ notification: Notification) { cleanup() }

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
        let targets = destinations?() ?? []
        let landing = targets.first(where: \.isDefault)?.name ?? "Bam"
        if root.promote.spaceName != landing { root.promote.spaceName = landing }
        root.promote.hasChoices = targets.count > 1
        root.copyLink.isEnabled = web.url != nil
        root.needsLayout = true
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

/// The window: a translucent bar the traffic lights share, then the page.
@MainActor private final class LittleOrbitRoot: NSView {
    static let barHeight: CGFloat = 48
    let bar = NSVisualEffectView()
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
    /// While editing, the address field replaces the site name.
    var editing = false { didSet { address.isHidden = !editing; site.isHidden = editing; needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        bar.material = .hudWindow
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.wantsLayer = true
        let edge = CALayer(); edge.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        edge.name = "edge"; bar.layer?.addSublayer(edge)
        addSubview(browserHost)
        addSubview(bar)
        [profile, back, forward, reload, site, address, extensions, copyLink, promote, progress].forEach(bar.addSubview)
        profile.toolTip = "Login profile"
        address.placeholderString = "Search or enter a web address"; address.setAccessibilityLabel("Little Bam address")
        address.font = BamType.sans(13, weight: .medium); address.textColor = .white
        address.isBezeled = false; address.isBordered = false; address.drawsBackground = true
        address.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        address.wantsLayer = true; address.layer?.cornerRadius = 8
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let width = bounds.width, barHeight = Self.barHeight
        bar.frame = NSRect(x: 0, y: 0, width: width, height: barHeight)
        (bar.layer?.sublayers?.first { $0.name == "edge" })?.frame = NSRect(x: 0, y: barHeight - 1, width: width, height: 1)
        browserHost.frame = NSRect(x: 0, y: barHeight, width: width, height: max(0, bounds.height - barHeight))
        progress.frame = NSRect(x: 0, y: barHeight - 3, width: width, height: 3)
        let y = (barHeight - 30) / 2
        // Traffic lights own the first 76 points.
        var x: CGFloat = 80
        profile.frame = NSRect(x: x, y: y, width: profile.intrinsicContentSize.width, height: 30); x = profile.frame.maxX + 8
        back.frame = NSRect(x: x, y: y, width: 30, height: 30); x += 30
        forward.frame = NSRect(x: x, y: y, width: 30, height: 30); x += 30
        reload.frame = NSRect(x: x, y: y, width: 30, height: 30); x += 30
        let leftEnd = x + 8
        var right = width - 12
        let openWidth = promote.intrinsicContentSize.width
        promote.frame = NSRect(x: right - openWidth, y: y, width: openWidth, height: 30); right = promote.frame.minX - 8
        copyLink.frame = NSRect(x: right - 30, y: y, width: 30, height: 30); right -= 30
        if !extensions.isHidden { extensions.frame = NSRect(x: right - 30, y: y, width: 30, height: 30); right -= 30 }
        let rightStart = right - 8
        // The site name centers in the window when there is room, else in the gap.
        let gap = NSRect(x: leftEnd, y: y, width: max(0, rightStart - leftEnd), height: 30)
        let siteWidth = min(gap.width, max(120, site.intrinsicContentSize.width))
        var siteX = width / 2 - siteWidth / 2
        siteX = min(max(siteX, gap.minX), max(gap.minX, gap.maxX - siteWidth))
        site.frame = NSRect(x: siteX, y: y, width: siteWidth, height: 30)
        address.frame = gap.insetBy(dx: 0, dy: 1)
    }
}

@MainActor private final class LittleOrbitBrowserHost: NSView {
    override var isFlipped: Bool { true }
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
        contentTintColor = NSColor.white.withAlphaComponent(isEnabled ? 0.85 : 0.35)
        layer?.backgroundColor = (hovering && isEnabled ? NSColor.white.withAlphaComponent(0.12) : NSColor.clear).cgColor
    }
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
        isEnabled = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        imagePosition = .imageLeading; imageHugsTitle = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: BamType.sans(12.5, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.8)
            ])
            contentTintColor = NSColor.white.withAlphaComponent(0.7)
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
                .font: BamType.sans(13.5, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ])
        }
    }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += 24; return size }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor }
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
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        setAccessibilityElement(true); setAccessibilityRole(.group)
        main.isBordered = false; main.title = ""; main.setButtonType(.momentaryChange)
        main.target = self; main.action = #selector(openAction)
        main.setAccessibilityLabel("Open in Bam")
        main.wantsLayer = true; main.layer?.cornerRadius = 8
        picker.isBordered = false; picker.setButtonType(.momentaryChange)
        picker.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Choose a Space")?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        picker.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        picker.target = self; picker.action = #selector(pickAction)
        picker.setAccessibilityLabel("Choose a Space to open in")
        picker.wantsLayer = true; picker.layer?.cornerRadius = 8
        keycap.font = BamType.mono(10.5, weight: .semibold)
        keycap.textColor = NSColor.white.withAlphaComponent(0.85)
        keycap.wantsLayer = true; keycap.layer?.cornerRadius = 5
        keycap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        keycap.alignment = .center
        divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        label.lineBreakMode = .byTruncatingTail
        [main, label, keycap, divider, picker].forEach(addSubview)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        let text = NSMutableAttributedString(string: "Open in ", attributes: [
            .font: BamType.sans(13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.78)
        ])
        text.append(NSAttributedString(string: spaceName, attributes: [
            .font: BamType.sans(13, weight: .bold), .foregroundColor: NSColor.white
        ]))
        label.attributedStringValue = text
        main.setAccessibilityLabel("Open in \(spaceName)")
        layer?.backgroundColor = NSColor.white.withAlphaComponent(hovering || pickerHovering ? 0.16 : 0.10).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        picker.layer?.backgroundColor = (pickerHovering ? NSColor.white.withAlphaComponent(0.12) : NSColor.clear).cgColor
    }
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
