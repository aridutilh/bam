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
    var isPresented: Bool { backdrop != nil }
    var webView: WKWebView? { content?.webView }

    private var content: PreviewWebContent?
    private var backdrop: PeekBackdrop?
    private var keyMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?
    private weak var hostWindow: NSWindow?

    @discardableResult
    func present(url: URL, in hostView: NSView, websiteDataStore: WKWebsiteDataStore, configure: ((WKWebViewConfiguration) -> Void)? = nil, beforeLoad: PreviewNavigationReadiness? = nil) -> Bool {
        guard PreviewURLPolicy.allows(url) else { return false }
        _ = detach(notify: false, stop: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configure?(configuration)
        let browser = PreviewWKWebView(frame: .zero, configuration: configuration)
        let content = PreviewWebContent(webView: browser, beforeLoad: beforeLoad)
        self.content = content
        content.onDownload = onDownload
        content.onVisit = onVisit
        let backdrop = PeekBackdrop(frame: hostView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.onOutsideClick = { [weak self] in self?.dismiss() }
        backdrop.closeButton.target = self; backdrop.closeButton.action = #selector(closeAction)
        backdrop.tabButton.target = self; backdrop.tabButton.action = #selector(tabAction)
        backdrop.splitButton.target = self; backdrop.splitButton.action = #selector(splitAction)
        backdrop.littleButton.target = self; backdrop.littleButton.action = #selector(littleAction)
        backdrop.splitButton.isEnabled = onSplit != nil
        backdrop.littleButton.isEnabled = onOpenLittleOrbit != nil
        backdrop.browserHost.addSubview(browser)
        browser.frame = backdrop.browserHost.bounds
        browser.autoresizingMask = [.width, .height]
        self.backdrop = backdrop
        hostWindow = hostView.window
        previousResponder = hostView.window?.firstResponder
        content.onChange = { [weak self] in self?.refresh() }
        content.onCloseRequest = { [weak self] in self?.dismiss() }
        hostView.addSubview(backdrop, positioned: .above, relativeTo: nil)
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
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            backdrop.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                backdrop.animator().alphaValue = 1
            }
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

    func dismiss() { _ = detach(notify: true, stop: true) }

    func promoteToTab() {
        guard let callback = onPromote, let web = detach(notify: true, stop: false) else { return }
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

    private func detach(notify: Bool, stop: Bool) -> WKWebView? {
        let wasPresented = backdrop != nil
        let wasVisible = backdrop?.isHidden == false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        let web = content?.takeWebView()
        if stop { web?.stopLoading() }
        content = nil
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

    private func refresh() {
        guard let content, let web = content.webView, let backdrop else { return }
        backdrop.title.stringValue = content.status ?? web.title ?? "Peek"
        backdrop.address.stringValue = web.url?.host ?? "Loading…"
        backdrop.title.toolTip = web.url?.absoluteString
        backdrop.progress.doubleValue = web.estimatedProgress
        backdrop.progress.isHidden = !web.isLoading
    }

    @objc private func closeAction() { dismiss() }
    @objc private func tabAction() { promoteToTab() }
    @objc private func splitAction() { openInSplitView() }
    @objc private func littleAction() { openInLittleOrbit() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }
}

@MainActor private final class PeekBackdrop: NSView {
    var onOutsideClick: (() -> Void)?
    let card = PeekCard()
    let browserHost = PeekCard()
    let title = NSTextField(labelWithString: "Peek")
    let address = NSTextField(labelWithString: "Loading…")
    let closeButton = NSButton(title: "✕", target: nil, action: nil)
    let tabButton = NSButton(title: "Open in Tab", target: nil, action: nil)
    let splitButton = NSButton(title: "Split View", target: nil, action: nil)
    let littleButton = NSButton(title: "Little Bam", target: nil, action: nil)
    let progress = NSProgressIndicator()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 12; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1; card.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(card)
        [browserHost, title, address, closeButton, tabButton, splitButton, littleButton, progress].forEach(card.addSubview)
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingTail
        address.font = .systemFont(ofSize: 10); address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingMiddle
        for button in [closeButton, tabButton, splitButton, littleButton] { button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11) }
        closeButton.setAccessibilityLabel("Close Peek"); closeButton.toolTip = "Close Peek (Escape or ⌘W)"
        tabButton.toolTip = "Keep the same page in a tab (⌘O)"
        splitButton.toolTip = "Keep the same page in Split View (⇧⌘O)"
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        setAccessibilityElement(false); card.setAccessibilityLabel("Peek preview")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
    override func layout() {
        super.layout()
        let width = min(1060, max(0, bounds.width - 60))
        let height = min(800, max(0, bounds.height - 60))
        card.frame = NSRect(x: (bounds.width-width)/2, y: (bounds.height-height)/2, width: width, height: height)
        closeButton.frame = NSRect(x: 12, y: 13, width: 28, height: 26)
        tabButton.frame = NSRect(x: width-112, y: 13, width: 100, height: 26)
        splitButton.frame = NSRect(x: width-201, y: 13, width: 86, height: 26)
        littleButton.frame = NSRect(x: width-299, y: 13, width: 95, height: 26)
        title.frame = NSRect(x: 50, y: 8, width: max(0,width-360), height: 19)
        address.frame = NSRect(x: 50, y: 28, width: max(0,width-360), height: 14)
        progress.frame = NSRect(x: 0, y: 51, width: width, height: 2)
        browserHost.frame = NSRect(x: 0, y: 54, width: width, height: max(0,height-54))
    }
}

@MainActor private final class PeekCard: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { /* Blank card area is not the dimmed backdrop. */ }
}

/// Shared by Peek and Little Bam; no external URL is handed to NSWorkspace.
enum PreviewURLPolicy {
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

    @discardableResult func load(url: URL) -> Bool {
        guard PreviewURLPolicy.allows(url) else { status = "Only HTTP and HTTPS pages can open here"; onChange?(); return false }
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
        guard let url = navigationAction.request.url, PreviewURLPolicy.allows(url) else {
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
        guard let url = navigationResponse.response.url, PreviewURLPolicy.allows(url) else {
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
