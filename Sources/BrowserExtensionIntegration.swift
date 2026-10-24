import AppKit
import WebKit

@MainActor extension BrowserController {
    @available(macOS 15.4, *)
    var browserExtensions: BrowserExtensions {
        if let existing = extensionStorage as? BrowserExtensions { return existing }
        let value = BrowserExtensions(storageURL: privateMode ? nil : sessionURL.deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true), isPrivate: privateMode)
        extensionStorage = value
        value.profileName = { [weak self] in self?.session.profileName($0) ?? "Profile" }
        value.surfaces = { [weak self] in self?.extensionSurfaces(profileID: $0) ?? [] }
        value.surface = { [weak self] profile, id in self?.extensionSurface(profileID: profile, id: id) }
        value.surfaceRevision = { [weak self] _ in self?.extensionTopologyRevision() }
        value.selectTab = { [weak self] id in
            guard let self else { return false }
            if self.session.tabs.contains(where: { $0.id == id }) {
                self.select(id); self.view.window?.makeKeyAndOrderFront(nil); return true
            }
            if let little = self.littleWindows[id] { little.show(relativeTo: self.view.window); return true }
            if let owner = self.peekExtensionIDs.first(where: { $0.value == id })?.key {
                self.select(owner); self.view.window?.makeKeyAndOrderFront(nil); return true
            }
            return false
        }
        value.closeTab = { [weak self] id in
            guard let self else { return false }
            if self.session.tabs.contains(where: { $0.id == id }) { self.close(id); return true }
            if let little = self.littleWindows[id] { little.close(); return true }
            if let owner = self.peekExtensionIDs.first(where: { $0.value == id })?.key { self.peeks[owner]?.dismiss(); return true }
            return false
        }
        value.navigateTab = { [weak self] id, url in
            guard let self else { return false }
            if self.session.tabs.contains(where: { $0.id == id }) { self.navigatePane(id, address: url.absoluteString); return true }
            if let little = self.littleWindows[id] { return little.open(url: url) }
            if let owner = self.peekExtensionIDs.first(where: { $0.value == id })?.key,
               let web = self.peeks[owner]?.webView, URLInput.directURL(url.absoluteString) != nil {
                web.load(URLRequest(url: url)); return true
            }
            return false
        }
        value.reloadTab = { [weak self] id, fromOrigin in
            guard let self else { return false }
            var web = self.extensionWebView(id)
            if web == nil, let tab = self.session.tabs.first(where: { $0.id == id }) { web = self.webView(for: tab) }
            guard let web else { return false }
            if fromOrigin { web.reloadFromOrigin() } else { web.reload() }
            return true
        }
        value.createTab = { [weak self] url, profile, active in self?.openProfileTab(url, profileID: profile, active: active) }
        value.createWindow = { [weak self] url, profile, focused in
            guard let self else { return nil }
            let before = Set(self.littleWindows.keys)
            self.openLittleOrbit(url: url, profileID: profile)
            guard let id = self.littleWindows.keys.first(where: { !before.contains($0) }), let little = self.littleWindows[id], let window = little.window else { return nil }
            if !focused { self.view.window?.makeKeyAndOrderFront(nil) }
            return window
        }
        value.closeWindow = { [weak self] window in
            guard let self, let little = self.littleWindows.values.first(where: { $0.window === window }) else { return false }
            little.close(); return true
        }
        value.startDownload = { [weak self] web, url, _ in
            guard let self else { return false }
            web.startDownload(using: URLRequest(url: url)) { [weak self] download in self?.downloads.start(download: download) }
            return true
        }
        value.onChange = { [weak self] in self?.scheduleExtensionRefresh() }
        value.onReloadNeeded = { [weak self] profile in self?.offerExtensionReload(profileID: profile) }
        return value
    }
    func configureExtensions(_ configuration: WKWebViewConfiguration, profileID: UUID) {
        if #available(macOS 15.4, *) { browserExtensions.configure(configuration, profileID: profileID) }
    }
    func whenExtensionsReady(profileID: UUID, perform: @escaping @MainActor () -> Void) {
        if #available(macOS 15.4, *) { browserExtensions.whenReady(profileID: profileID, perform: perform) }
        else { perform() }
    }
    func allowsExtensionPage(_ url: URL, profileID: UUID) -> Bool {
        guard URLInput.extensionURL(url.absoluteString) != nil, #available(macOS 15.4, *) else { return false }
        return browserExtensions.allowsExtensionURL(url, profileID: profileID)
    }
    func extensionPageConfiguration(_ url: URL, profileID: UUID) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        return browserExtensions.configuration(forExtensionURL: url, profileID: profileID)
    }
    func invalidateExtensionSurfaceTopology() {
        extensionSurfaceRevision &+= 1
        extensionTabIndices = nil
    }
    /// Preview objects can change their own presentation/window state. Keep that
    /// less common path fully live; no callback-timing assumptions enter the cache.
    func extensionTopologyRevision() -> UInt64? {
        guard peeks.isEmpty, littleWindows.isEmpty else { return nil }
        let window = (viewIfLoaded?.window).map(ObjectIdentifier.init)
        if window != extensionSurfaceWindow {
            extensionSurfaceWindow = window
            invalidateExtensionSurfaceTopology()
        }
        return extensionSurfaceRevision
    }
    func scheduleExtensionRefresh() {
        // Invalidate synchronously even when event publication is coalesced,
        // disabled, or shutting down.
        invalidateExtensionSurfaceTopology()
        guard !isShuttingDown, extensionRefreshWork == nil else { return }
        guard #available(macOS 15.4, *), let extensions = extensionStorage as? BrowserExtensions,
              extensions.records.contains(where: { $0.enabled }) else { return }
        let work = DispatchWorkItem { [weak self, weak extensions] in
            self?.extensionRefreshWork = nil
            guard self?.isShuttingDown == false else { return }
            extensions?.reconcile()
        }
        extensionRefreshWork = work; DispatchQueue.main.async(execute: work)
    }
    func stopExtensions() {
        extensionRefreshWork?.cancel(); extensionRefreshWork = nil
        if #available(macOS 15.4, *), let extensions = extensionStorage as? BrowserExtensions { extensions.shutdown() }
        extensionStorage = nil
    }
    func extensionWebView(_ id: UUID) -> WKWebView? {
        if let web = browsers[id] { return web }
        if let web = littleWindows[id]?.webView { return web }
        if let owner = peekExtensionIDs.first(where: { $0.value == id })?.key { return peeks[owner]?.webView }
        return nil
    }
    @available(macOS 15.4, *)
    func extensionSurfaces(profileID: UUID) -> [BrowserExtensionSurface] {
        guard !isShuttingDown, !isApplyingProfileChange else { return [] }
        var result: [BrowserExtensionSurface] = session.tabs.filter { session.profileID(for: $0) == profileID }.map { tab in
            BrowserExtensionSurface(id: tab.id, title: tab.displayTitle, url: URL(string: tab.address), webView: browsers[tab.id], window: viewIfLoaded?.window,
                isActive: session.currentProfileID == profileID && focusedTabID == tab.id && peeks[session.activeID]?.isPresented != true,
                isSelected: session.currentProfileID == profileID && visibleMemberIDs.contains(tab.id), isPinned: tab.isSaved)
        }
        for (owner, peek) in peeks {
            guard let web = peek.webView, self.profileID(of: web) == profileID, let id = peekExtensionIDs[owner] else { continue }
            result.append(BrowserExtensionSurface(id: id, title: web.title ?? "Peek", url: web.url, webView: web, window: viewIfLoaded?.window,
                isActive: session.activeID == owner && peek.isPresented, isSelected: session.activeID == owner && peek.isPresented))
        }
        for (id, little) in littleWindows {
            guard let web = little.webView, self.profileID(of: web) == profileID else { continue }
            result.append(BrowserExtensionSurface(id: id, title: web.title ?? "Little Bam", url: web.url, webView: web, window: little.window,
                isActive: true, isSelected: true))
        }
        return result
    }
    /// Resolve one live page without constructing metadata for every other tab.
    @available(macOS 15.4, *)
    func extensionSurface(profileID: UUID, id: UUID) -> BrowserExtensionSurface? {
        guard !isShuttingDown, !isApplyingProfileChange else { return nil }
        if extensionTabIndices == nil {
            extensionTabIndices = Dictionary(session.tabs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
        if let index = extensionTabIndices?[id], session.tabs.indices.contains(index),
           session.tabs[index].id == id, session.profileID(for: session.tabs[index]) == profileID {
            let tab = session.tabs[index]
            return BrowserExtensionSurface(id: tab.id, title: tab.displayTitle, url: URL(string: tab.address), webView: browsers[tab.id], window: viewIfLoaded?.window,
                isActive: session.currentProfileID == profileID && focusedTabID == tab.id && peeks[session.activeID]?.isPresented != true,
                isSelected: session.currentProfileID == profileID && visibleMemberIDs.contains(tab.id), isPinned: tab.isSaved)
        }
        for (owner, peek) in peeks where peekExtensionIDs[owner] == id {
            guard let web = peek.webView, self.profileID(of: web) == profileID else { continue }
            return BrowserExtensionSurface(id: id, title: web.title ?? "Peek", url: web.url, webView: web, window: viewIfLoaded?.window,
                isActive: session.activeID == owner && peek.isPresented, isSelected: session.activeID == owner && peek.isPresented)
        }
        if let little = littleWindows[id], let web = little.webView, self.profileID(of: web) == profileID {
            return BrowserExtensionSurface(id: id, title: web.title ?? "Little Bam", url: web.url, webView: web, window: little.window,
                isActive: true, isSelected: true)
        }
        return nil
    }
    var extensionCommandTabID: UUID? {
        if let pair = littleWindows.first(where: { $0.value.window?.isKeyWindow == true }) { return pair.key }
        if peeks[session.activeID]?.isPresented == true { return peekExtensionIDs[session.activeID] }
        return session.tabs.contains(where: { $0.id == focusedTabID }) ? focusedTabID : nil
    }
    @objc func manageExtensions(_ sender: Any?) {
        guard #available(macOS 15.4, *) else {
            let alert = NSAlert(); alert.messageText = "Extensions need macOS 15.4 or later"; alert.addButton(withTitle: "OK"); alert.runModal(); return
        }
        let profile = commandProfileID
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = profileStores.store(for: profile)
        browserExtensions.configure(configuration, profileID: profile)
        browserExtensions.showManager(profileID: profile, relativeTo: NSApp.keyWindow ?? view.window)
    }
    func updateExtensionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let profile = commandProfileID
        let heading = NSMenuItem(title: "Profile: \(session.profileName(profile))", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(manageExtensions(_:)), keyEquivalent: ""); manage.target = self; menu.addItem(manage)
        guard #available(macOS 15.4, *) else { return }
        menu.addItem(.separator())
        browserExtensions.reconcile()
        let anchor = commandWebView?.superview ?? sidebar
        let actions = browserExtensions.actionsMenu(profileID: profile, tabID: extensionCommandTabID, anchor: anchor)
        for item in actions.items { actions.removeItem(item); menu.addItem(item) }
    }
    func offerExtensionReload(profileID: UUID) {
        guard !isShuttingDown else { return }
        var seen = Set<ObjectIdentifier>()
        let mainIDs = session.tabs.filter { session.profileID(for: $0) == profileID && browsers[$0.id] != nil }.map(\.id)
        let previews = Array(peeks.values.compactMap(\.webView)) + Array(littleWindows.values.compactMap(\.webView))
        let webs = (mainIDs.compactMap { browsers[$0] } + previews.filter { self.profileID(of: $0) == profileID }).filter { seen.insert(ObjectIdentifier($0)).inserted }
        guard !webs.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Reload pages in \(session.profileName(profileID))?"
        alert.informativeText = "Reloading applies the extension change to open pages. Unsaved page edits will be lost. You can reload individual pages later instead."
        alert.addButton(withTitle: "Later"); alert.addButton(withTitle: "Reload Pages")
        guard runProfileAlert(alert) == .alertSecondButtonReturn else { return }
        for web in webs {
            if let id = browsers.first(where: { $0.value === web })?.key,
               let tab = session.tabs.first(where: { $0.id == id }) {
                load(tab.address, in: web, id: id)
            } else if self.profileID(of: web) == profileID { web.reload() }
        }
    }
}
