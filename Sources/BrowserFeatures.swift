import AppKit
import WebKit

@MainActor extension BrowserController {
    @objc func printPage(_ sender: Any?) {
        guard let web = commandWebView, let window = web.window else { return }
        web.printOperation(with: NSPrintInfo.shared).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
    /// Resolve Find against the key browser window, never a background main tab
    /// while a utility window is active.
    private var findSurface: (web: WKWebView, host: NSView)? {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }),
           let web = little.webView, let host = little.window?.contentView { return (web, host) }
        guard NSApp.keyWindow === view.window, let web = peeks[session.activeID]?.webView ?? activeWebView else { return nil }
        return (web, card)
    }
    @objc func findInPage(_ sender: Any?) {
        guard let surface = findSurface else { return }
        dismissAddress()
        findBar.show(in: surface.host, web: surface.web)
    }
    @objc func findNext(_ sender: Any?) { continueFind(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { continueFind(backwards: true) }
    private func continueFind(backwards: Bool) {
        guard let surface = findSurface else { return }
        findBar.continueFind(in: surface.host, web: surface.web, backwards: backwards)
    }
    func refreshFindTarget() {
        guard findBar.isVisible else { return }
        guard let surface = findSurface else { findBar.hide(); return }
        findBar.synchronize(in: surface.host, web: surface.web)
    }
    /// Page commands follow the focused browser surface. A Library, About, or
    /// floating-video window must never act on an unrelated background tab.
    private var pageCommandSurface: (web: WKWebView, host: NSView)? {
        guard !isShuttingDown, let key = NSApp.keyWindow, key.attachedSheet == nil else { return nil }
        let web: WKWebView?
        if let little = littleWindows.values.first(where: { $0.window === key }) {
            web = little.webView
        } else if isViewLoaded, key === view.window {
            web = peeks[session.activeID]?.webView ?? activeWebView
        } else { return nil }
        guard let web, web.window === key, !web.isHiddenOrHasHiddenAncestor,
              let host = web.superview else { return nil }
        return (web, host)
    }
    private func copyableURL(for web: WKWebView) -> URL? {
        // Preserve the current page's query/fragment and history.pushState URL.
        // A requested URL is only a fallback before the first page exists.
        let url = web.url ?? (web as? PreviewWKWebView)?.requestedURL
        return url.flatMap { URLInput.directURL($0.absoluteString) }
    }
    @objc func copyCurrentURL(_ sender: Any?) {
        guard let surface = pageCommandSurface, let url = copyableURL(for: surface.web) else { return }
        pageCommandPasteboard.clearContents()
        guard pageCommandPasteboard.setString(url.absoluteString, forType: .string) else { return }
        pageFeedback.show("Page copied", symbol: "link", in: surface.host)
    }
    @objc func hardReload(_ sender: Any?) {
        guard let surface = pageCommandSurface else { return }
        let web = surface.web
        let id = browsers.first(where: { $0.value === web })?.key
        let retryURL = id.flatMap { tabErrors[$0] == nil ? nil : requestedAddresses[$0] }
            .flatMap(URLInput.directURL)
        let navigation: WKNavigation?
        if let url = retryURL ?? (web.url == nil ? (web as? PreviewWKWebView)?.requestedURL : nil),
           URLInput.directURL(url.absoluteString) != nil {
            navigation = web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        } else {
            // WebKit revalidates the current navigation with the origin, keeping
            // its method/history semantics. Unlike Reload / Stop, do this even
            // while loading. This does not clear cookies or other website data.
            navigation = web.reloadFromOrigin()
        }
        guard navigation != nil else { return }
        pageFeedback.show("Hard refreshing…", symbol: "arrow.clockwise", in: surface.host)
    }
    @objc func toggleAutomaticVideo(_ sender: Any?) {
        automaticallyShowsVideo.toggle()
        if !automaticallyShowsVideo { cancelAutomaticDepartures() }
        if !privateMode { UserDefaults.standard.set(automaticallyShowsVideo, forKey: "AutomaticallyShowPlayingVideo") }
        (sender as? NSMenuItem)?.state = automaticallyShowsVideo ? .on : .off
    }
    func openPeek(_ url: URL) {
        guard URLInput.directURL(url.absoluteString) != nil else { return }
        dismissAddress(); cancelPaging(); findBar.hide()
        let owner = session.activeID
        peeks[owner]?.dismiss()
        let peek = PeekCoordinator()
        peek.onDownload = { [weak self] download in self?.downloads.start(download: download) }
        peek.onVisit = { [weak self] title, address in self?.library.recordVisit(title: title, address: address) }
        peeks[owner] = peek
        peek.shouldHandleEscape = { [weak self] in !(self?.findBar.isVisible ?? false) }
        peek.onDismiss = { [weak self, weak peek] in
            guard let self, self.peeks[owner] === peek else { return }
            self.peeks.removeValue(forKey: owner)
            self.refreshFindTarget()
        }
        peek.onPromote = { [weak self] web in self?.adoptWebView(web) }
        peek.onOpenLittleOrbit = { [weak self] web in self?.openLittleOrbit(adopting: web) }
        peek.onSplit = { [weak self] web in self?.openSplit(adopting: web, beside: owner) }
        let store = activeWebView?.configuration.websiteDataStore ?? (privateMode ? .nonPersistent() : .default())
        if !peek.present(url: url, in: card, websiteDataStore: store) { peeks.removeValue(forKey: owner) }
    }
    @discardableResult func adoptWebView(_ web: WKWebView) -> UUID {
        cancelPaging(); dismissAddress()
        let address = ((web as? PreviewWKWebView)?.promotionURL ?? web.url).flatMap { URLInput.directURL($0.absoluteString) }?.absoluteString ?? "orbit://newtab"
        let id = session.add(address: address, title: web.title?.isEmpty == false ? web.title : nil)
        web.removeFromSuperview(); register(web, id: id)
        if web.isLoading { pendingLoads.insert(id) }
        if address == "orbit://newtab" { load(address, in: web, id: id) }
        showActive(); save(); view.window?.makeKeyAndOrderFront(nil)
        return id
    }
    @objc func newLittleOrbit(_ sender: Any?) { openLittleOrbit(url: nil) }
    func openLittleOrbit(url: URL? = nil, adopting web: WKWebView? = nil) {
        if let url, URLInput.directURL(url.absoluteString) == nil { return }
        let id = UUID()
        let store = web?.configuration.websiteDataStore ?? activeWebView?.configuration.websiteDataStore ?? (privateMode ? .nonPersistent() : .default())
        let little = LittleArcController(websiteDataStore: store)
        little.onDownload = { [weak self] download in self?.downloads.start(download: download) }
        little.onVisit = { [weak self] title, address in self?.library.recordVisit(title: title, address: address) }
        littleWindows[id] = little
        little.onClose = { [weak self] in self?.littleWindows.removeValue(forKey: id) }
        little.onPromote = { [weak self] web in self?.adoptWebView(web) }
        if let web { little.adopt(webView: web) }
        else if let url { _ = little.open(url: url) }
        little.show(relativeTo: view.window)
    }
}

extension BrowserController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyCurrentURL(_:)):
            return pageCommandSurface.flatMap { copyableURL(for: $0.web) } != nil
        case #selector(hardReload(_:)):
            return pageCommandSurface != nil
        default: return true
        }
    }
}
