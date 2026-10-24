import AppKit
import WebKit

/// Bam's compact browser window, named Little Bam in the UI.
/// Product reference: Arc's official 2021 release notes describe a compact lookup
/// window and Command-O promotion into the main browser:
/// https://resources.arc.net/hc/en-us/articles/20498463803799-Arc-for-macOS-2021-Release-Notes
@MainActor final class LittleArcController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onPromote: ((WKWebView) -> Void)?
    var canPromote: (() -> Bool)?
    var onClose: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)? { didSet { content?.onDownload = onDownload } }
    var onVisit: ((String, String) -> Void)? { didSet { content?.onVisit = onVisit } }
    var webView: WKWebView? { content?.webView }

    private var content: PreviewWebContent?
    private let root = LittleOrbitRoot()
    private var didClose = false
    private let beforeLoad: PreviewNavigationReadiness?

    init(websiteDataStore: WKWebsiteDataStore, configure: ((WKWebViewConfiguration) -> Void)? = nil, beforeLoad: PreviewNavigationReadiness? = nil) {
        self.beforeLoad = beforeLoad
        let window = LittleOrbitWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Little Bam"; window.contentMinSize = NSSize(width: 500, height: 320)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = root; window.appearance = NSAppearance(named: .darkAqua)
        window.onEscape = { [weak self] in self?.close() }
        window.onPromote = { [weak self] in self?.promoteToOrbit() }
        window.onLocation = { [weak self] in self?.focusAddress() }
        window.onReload = { [weak self] in self?.reloadAction() }
        window.onBack = { [weak self] in self?.backAction() }
        window.onForward = { [weak self] in self?.forwardAction() }
        root.address.target = self; root.address.action = #selector(submitAddress); root.address.delegate = self
        root.back.target = self; root.back.action = #selector(backAction)
        root.forward.target = self; root.forward.action = #selector(forwardAction)
        root.reload.target = self; root.reload.action = #selector(reloadAction)
        root.promote.target = self; root.promote.action = #selector(promoteAction)
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
            window.onReload = nil; window.onBack = nil; window.onForward = nil
        }
        onClose?()
    }

    func focusAddress() { window?.makeFirstResponder(root.address); root.address.selectText(nil) }
    @objc private func submitAddress() {
        guard let url = PreviewURLPolicy.resolveAddress(root.address.stringValue), open(url: url) else {
            root.status.stringValue = "Enter an HTTP/HTTPS address or search"; NSSound.beep(); return
        }
        window?.makeFirstResponder(webView)
    }
    @objc private func backAction() { webView?.goBack() }
    @objc private func forwardAction() { webView?.goForward() }
    @objc private func reloadAction() {
        guard let web = webView else { return }
        if web.isLoading { web.stopLoading() }
        else if web.url == nil, let url = (web as? PreviewWKWebView)?.requestedURL { _ = open(url: url) }
        else { web.reload() }
    }
    @objc private func promoteAction() { promoteToOrbit() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    private func refresh() {
        guard let content, let web = content.webView else { return }
        let title = web.title?.isEmpty == false ? web.title! : "Little Bam"
        window?.title = title == "Little Bam" ? title : "\(title) — Little Bam"
        if root.address.currentEditor() == nil { root.address.stringValue = web.url?.absoluteString ?? "" }
        root.status.stringValue = content.status ?? web.title ?? "Quick lookup · ⌘O opens this page in Bam"
        root.back.isEnabled = web.canGoBack; root.forward.isEnabled = web.canGoForward
        root.reload.title = web.isLoading ? "✕" : "↻"
        root.reload.toolTip = web.isLoading ? "Stop loading" : "Reload (⌘R)"
        root.progress.doubleValue = web.estimatedProgress; root.progress.isHidden = !web.isLoading
    }
}

@MainActor private final class LittleOrbitWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onPromote: (() -> Void)?
    var onLocation: (() -> Void)?
    var onReload: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil { onEscape?(); return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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

@MainActor private final class LittleOrbitRoot: NSView {
    let browserHost = LittleOrbitBrowserHost()
    let address = NSTextField()
    let back = NSButton(title: "‹", target: nil, action: nil)
    let forward = NSButton(title: "›", target: nil, action: nil)
    let reload = NSButton(title: "↻", target: nil, action: nil)
    let promote = NSButton(title: "Open in Bam", target: nil, action: nil)
    let status = NSTextField(labelWithString: "Quick lookup · ⌘O opens this page in Bam")
    let progress = NSProgressIndicator()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        [browserHost, address, back, forward, reload, promote, status, progress].forEach(addSubview)
        for button in [back, forward, reload, promote] { button.bezelStyle = .rounded }
        back.setAccessibilityLabel("Back"); forward.setAccessibilityLabel("Forward"); reload.setAccessibilityLabel("Reload or stop")
        address.placeholderString = "Search or enter a web address"; address.setAccessibilityLabel("Little Bam address")
        address.font = .systemFont(ofSize: 12); address.bezelStyle = .roundedBezel
        promote.toolTip = "Move this same page into Bam (⌘O)"; promote.font = .systemFont(ofSize: 11)
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let width = bounds.width
        back.frame = NSRect(x: 9,y: 10,width: 28,height: 27)
        forward.frame = NSRect(x: 38,y: 10,width: 28,height: 27)
        reload.frame = NSRect(x: 67,y: 10,width: 30,height: 27)
        promote.frame = NSRect(x: width-118,y: 10,width: 108,height: 27)
        address.frame = NSRect(x: 105,y: 10,width: max(0,width-231),height: 27)
        status.frame = NSRect(x: 14,y: 43,width: max(0,width-28),height: 16)
        progress.frame = NSRect(x: 0,y: 62,width: width,height: 2)
        browserHost.frame = NSRect(x: 0,y: 65,width: width,height: max(0,bounds.height-65))
    }
}

@MainActor private final class LittleOrbitBrowserHost: NSView {
    override var isFlipped: Bool { true }
}
