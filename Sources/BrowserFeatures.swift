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
           let web = little.webView, let host = little.window?.contentView { return (pageTools.reading.readerView(over: web) ?? web, host) }
        guard NSApp.keyWindow === view.window, let web = peeks[session.activeID]?.webView ?? activeWebView else { return nil }
        // Reading Mode lies over the page: Find searches the article.
        return (pageTools.reading.readerView(over: web) ?? web, card)
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
    var pageCommandSurface: (web: WKWebView, host: NSView)? {
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
    func copyableURL(for web: WKWebView) -> URL? {
        // Preserve the current page's query/fragment and history.pushState URL.
        // A requested URL is only a fallback before the first page exists.
        let url = web.url ?? (web as? PreviewWKWebView)?.requestedURL
        return url.flatMap { URLInput.directURL($0.absoluteString) }
    }
    /// The address to share: the current page's, without tracking parameters.
    func cleanLink(for web: WKWebView) -> URL? { copyableURL(for: web).map(CleanLinks.clean) }
    @objc func copyCurrentURL(_ sender: Any?) {
        guard let surface = pageCommandSurface, let url = cleanLink(for: surface.web) else { return }
        pageCommandPasteboard.clearContents()
        guard pageCommandPasteboard.setString(url.absoluteString, forType: .string) else { return }
        pageFeedback.show("Copied Current URL", symbol: "link", in: surface.host, action: shareAction(for: url))
    }
    /// Share on the copy confirmation, as in Arc: the system share menu for this address.
    func shareAction(for url: URL) -> PageFeedbackAction {
        PageFeedbackAction(symbol: "square.and.arrow.up", label: "Share") { anchor, closed in
            SharePickerSession.show(url, from: anchor, closed: closed)
        }
    }
    /// "[Title](address)" as text, and as a live link for apps that paste rich text.
    @objc func copyMarkdownLink(_ sender: Any?) {
        guard let surface = pageCommandSurface, let url = cleanLink(for: surface.web) else { return }
        let title = surface.web.title
        pageCommandPasteboard.clearContents()
        pageCommandPasteboard.declareTypes([.string, .html], owner: nil)
        guard pageCommandPasteboard.setString(CleanLinks.markdown(title: title, url: url), forType: .string) else { return }
        pageCommandPasteboard.setString(CleanLinks.html(title: title, url: url), forType: .html)
        pageFeedback.show("Copied Current URL", symbol: "link", in: surface.host, action: shareAction(for: url))
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
        let profile = activeWebView.flatMap { profileID(of: $0) } ?? session.currentProfileID
        peeks[owner]?.dismiss()
        let peek = PeekCoordinator()
        peek.onDownload = { [weak self] download in self?.downloads.start(download: download) }
        peek.onVisit = { [weak self] title, address in self?.library(for: profile).recordVisit(title: title, address: address) }
        peeks[owner] = peek; peekExtensionIDs[owner] = UUID()
        peek.shouldHandleEscape = { [weak self] in !(self?.findBar.isVisible ?? false) }
        peek.onDismiss = { [weak self, weak peek] in
            guard let self, self.peeks[owner] === peek else { return }
            self.peeks.removeValue(forKey: owner); self.peekExtensionIDs.removeValue(forKey: owner)
            self.scheduleExtensionRefresh()
            self.refreshFindTarget()
        }
        peek.onPromote = { [weak self] web in _ = self?.adoptWebView(web) }
        peek.onOpenLittleOrbit = { [weak self] web in self?.openLittleOrbit(adopting: web) }
        peek.onSplit = { [weak self] web in self?.openSplit(adopting: web, beside: owner) }
        let store = activeWebView?.configuration.websiteDataStore ?? profileStores.store(for: profile)
        if !peek.present(url: url, in: card, websiteDataStore: store, configure: { [weak self] in self?.configureExtensions($0, profileID: profile); self?.preparePageTools(configuration: $0) }, beforeLoad: { [weak self] action in self?.whenExtensionsReady(profileID: profile, perform: action) }) { peeks.removeValue(forKey: owner); peekExtensionIDs.removeValue(forKey: owner) }
        if let web = peek.webView { PageInspector.enable(web) }
        scheduleExtensionRefresh()
    }
    @discardableResult func adoptWebView(_ web: WKWebView) -> UUID? {
        cancelPaging(); dismissAddress()
        let pendingURL = (web as? PreviewWKWebView)?.pendingReadyURL
        let address = (pendingURL ?? (web as? PreviewWKWebView)?.promotionURL ?? web.url).flatMap { URLInput.directURL($0.absoluteString) }?.absoluteString ?? "orbit://newtab"
        let sourceProfile = profileID(of: web)
        if let sourceProfile, !selectSpace(forProfile: sourceProfile) {
            openLittleOrbit(adopting: web); return nil
        }
        (web as? PreviewWKWebView)?.pendingReadyURL = nil
        let id = session.add(address: address, title: web.title?.isEmpty == false ? web.title : nil)
        // Unknown externally-created pages are never transplanted into a real
        // login profile. Disposable fixtures may supply their own private view.
        if sourceProfile == nil && !privateMode {
            web.stopLoading(); web.removeFromSuperview(); showActive(); save(); return id
        }
        web.removeFromSuperview(); register(web, id: id)
        if web.isLoading { pendingLoads.insert(id) }
        if pendingURL != nil || address == "orbit://newtab" || (web.url == nil && !web.isLoading) { load(address, in: web, id: id) }
        showActive(); save(); view.window?.makeKeyAndOrderFront(nil)
        return id
    }
    @objc func newLittleOrbit(_ sender: Any?) { openLittleOrbit(url: nil) }
    /// Little Bam's "Open in <Space>" picker. A Space on the same login takes
    /// the page itself; a Space on another login loads the address fresh
    /// there, because a web view never crosses website-data stores.
    func promote(_ web: WKWebView, into spaceID: Int, from profile: UUID) {
        guard let target = session.spaceDefinition(spaceID) else { _ = adoptWebView(web); return }
        if target.profileID == profile {
            if session.space != target.id { session.changeSpace(target.id); onSpacesChanged?() }
            _ = adoptWebView(web)
            return
        }
        // The window is already closed and the web view taken by now, so an
        // empty Little Bam still lands somewhere: on a new tab, like adoptWebView.
        let pendingURL = (web as? PreviewWKWebView)?.pendingReadyURL
        let address = (pendingURL ?? (web as? PreviewWKWebView)?.promotionURL ?? web.url)
            .flatMap({ URLInput.directURL($0.absoluteString) })?.absoluteString ?? "orbit://newtab"
        web.stopLoading(); web.removeFromSuperview()
        cancelPaging(); dismissAddress()
        if session.space != target.id { session.changeSpace(target.id); onSpacesChanged?() }
        _ = session.add(address: address, title: web.title?.isEmpty == false ? web.title : nil)
        showActive(); save(); view.window?.makeKeyAndOrderFront(nil)
    }
    func openLittleOrbit(url: URL? = nil, adopting web: WKWebView? = nil, profileID sourceProfile: UUID? = nil) {
        if let url, URLInput.directURL(url.absoluteString) == nil { return }
        let id = UUID()
        let profile = sourceProfile ?? web.flatMap { profileID(of: $0) } ?? commandWebView.flatMap { profileID(of: $0) } ?? session.currentProfileID
        let store = web?.configuration.websiteDataStore ?? profileStores.store(for: profile)
        let little = LittleBamController(websiteDataStore: store, configure: { [weak self] in self?.configureExtensions($0, profileID: profile); self?.preparePageTools(configuration: $0) }, beforeLoad: { [weak self] action in self?.whenExtensionsReady(profileID: profile, perform: action) })
        little.onDownload = { [weak self] download in self?.downloads.start(download: download) }
        little.onVisit = { [weak self] title, address in self?.library(for: profile).recordVisit(title: title, address: address) }
        littleWindows[id] = little
        little.onClose = { [weak self] in self?.littleWindows.removeValue(forKey: id); self?.scheduleExtensionRefresh() }
        little.canPromote = { [weak self] in
            guard let self else { return false }
            guard self.selectSpace(forProfile: profile) else {
                let alert = NSAlert(); alert.messageText = "Make room for this profile"
                alert.informativeText = "Assign a Space to this window’s login profile, or remove an unused Space, before opening it in the main browser."
                alert.addButton(withTitle: "OK"); alert.runModal(); return false
            }
            return true
        }
        little.onPromote = { [weak self] web in _ = self?.adoptWebView(web) }
        little.onPromoteTo = { [weak self] web, spaceID in self?.promote(web, into: spaceID, from: profile) }
        little.profileName = session.profileName(profile)
        little.destinations = { [weak self] in
            guard let self else { return [] }
            let landing = self.session.currentProfileID == profile ? self.session.space : self.session.spaceID(forProfile: profile)
            return self.session.spaces.map {
                LittleBamDestination(id: $0.id, name: $0.name, symbol: $0.symbol, colorIndex: $0.colorIndex, isDefault: $0.id == landing)
            }
        }
        if #available(macOS 15.4, *) {
            little.extensionsMenu = { [weak self] anchor in
                guard let self else { return nil }
                self.browserExtensions.reconcile()
                let menu = self.browserExtensions.actionsMenu(profileID: profile, tabID: id, anchor: anchor)
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(self.manageExtensions(_:)), keyEquivalent: "")
                manage.target = self; menu.addItem(manage)
                return menu
            }
        }
        if let web { little.adopt(webView: web) }
        else if let url { _ = little.open(url: url) }
        little.show(relativeTo: view.window); scheduleExtensionRefresh()
        if let web = little.webView { PageInspector.enable(web) }
    }
}

extension BrowserController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Editing a Space sheet must not close or navigate a background tab,
        // and the onboarding overlay owns the window while it is up.
        if suspendsChromeInteraction { return false }
        if isViewLoaded, view.window?.attachedSheet != nil { return false }
        if let pageTool = validatePageToolsItem(menuItem) { return pageTool }
        switch menuItem.action {
        case #selector(toggleAutomaticTabSleeping(_:)):
            menuItem.state = automaticTabSleeping ? .on : .off
            return true
        case #selector(toggleAutomaticVideo(_:)):
            menuItem.state = automaticallyShowsVideo ? .on : .off
            return true
        case #selector(toggleSiteKeepAwake(_:)):
            guard let host = currentSleepProtectionHost else { return false }
            menuItem.state = keepAwakeHosts.contains(host) ? .on : .off
            return NSApp.keyWindow === view.window && commandWebView === activeWebView
        case #selector(copyCurrentURL(_:)), #selector(copyMarkdownLink(_:)):
            return pageCommandSurface.flatMap { copyableURL(for: $0.web) } != nil
        case #selector(hardReload(_:)):
            return pageCommandSurface != nil
        case #selector(togglePin(_:)), #selector(toggleFavorite(_:)), #selector(editCurrentSavedTab(_:)), #selector(resetCurrentSavedTab(_:)):
            guard NSApp.keyWindow === view.window, peeks[session.activeID]?.isPresented != true,
                  let tab = session.tabs.first(where: { $0.id == focusedTabID }) else { return false }
            if menuItem.action == #selector(toggleFavorite(_:)) {
                return tab.isFavorite || (session.split(for: tab.id) == nil && session.favoriteTabs.count < 12)
            }
            if menuItem.action == #selector(editCurrentSavedTab(_:)) || menuItem.action == #selector(resetCurrentSavedTab(_:)) { return tab.isSaved }
            return true
        case #selector(splitWithNewPage(_:)):
            return NSApp.keyWindow === view.window && session.active?.isFavorite != true && session.split(for: session.activeID) == nil
        default: return true
        }
    }
}

/// Keeps the share picker (and the call that releases the confirmation it hangs
/// from) alive until the person picks a service or dismisses it.
@MainActor final class SharePickerSession: NSObject, NSSharingServicePickerDelegate {
    private static var current: SharePickerSession?
    private let picker: NSSharingServicePicker
    private var closed: (@MainActor () -> Void)?

    private init(_ url: URL, closed: @escaping @MainActor () -> Void) {
        picker = NSSharingServicePicker(items: [url]); self.closed = closed
        super.init()
        picker.delegate = self
    }
    static func show(_ url: URL, from anchor: NSView, closed: @escaping @MainActor () -> Void) {
        current?.finish()
        let session = SharePickerSession(url, closed: closed)
        current = session
        session.picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated { finish() }
    }
    private func finish() {
        let done = closed; closed = nil
        if Self.current === self { Self.current = nil }
        done?()
    }
}
