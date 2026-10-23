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
    @objc func copyCurrentURL(_ sender: Any?) {
        guard let url = commandWebView?.url, URLInput.directURL(url.absoluteString) != nil else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
