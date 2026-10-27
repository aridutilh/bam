import AppKit
import WebKit

/// Fixtures only: an extension host with an owned persistent extension-controller store, so storage.local survives a
/// restart as in a normal profile, inside an otherwise ephemeral window. The fixture removes that store afterwards.
struct ExtensionHostOverride {
    let storageURL: URL
    let controllerIdentifier: UUID
}

@MainActor extension BrowserController {
    @available(macOS 15.4, *)
    var browserExtensions: BrowserExtensions {
        if let existing = extensionStorage as? BrowserExtensions { return existing }
        // A disposable isolated store policy always gets non-persistent extension controllers: WebKit
        // offers no public removal for a persistent controller configuration. Standard runs are unchanged.
        let isolated: Bool
        if case .isolated = profileStores.policy { isolated = true } else { isolated = false }
        let value = extensionHostOverride.map { BrowserExtensions(storageURL: $0.storageURL, isPrivate: false, controllerStorage: .ownedPersistent($0.controllerIdentifier)) }
            ?? BrowserExtensions(storageURL: extensionsOff ? nil : sessionURL.deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true),
                                 isPrivate: extensionsOff, controllerStorage: isolated ? .nonPersistent : .automatic)
        extensionStorage = value
        value.profileName = { [weak self] in self?.session.profileName($0) ?? "Profile" }
        value.surfaces = { [weak self] in self?.extensionSurfaces(profileID: $0) ?? [] }
        value.surface = { [weak self] profile, id in self?.extensionSurface(profileID: profile, id: id) }
        value.surfaceRevision = { [weak self] _ in self?.extensionTopologyRevision() }
        // bookmarks.getTree: the engine has already checked the calling context's own profile, the explicit
        // grant and that this isn't a private host. Read-only snapshot of that profile's saved items; nil
        // (an error for the extension, never an empty tree) when closing, mid profile change, unknown or over budget.
        value.bookmarkSnapshot = { [weak self] profileID in
            guard let self else { return nil }
            return BookmarkSessionSnapshot.input(from: self.session, profileID: profileID,
                                                 isShuttingDown: self.isShuttingDown, isApplyingProfileChange: self.isApplyingProfileChange)
        }
        // history: a read-only snapshot of the profile's in-memory library, and genuine change events from each
        // profile library: the ones that exist now are wired here, later ones when library(for:) creates them
        // (extensionStorage is already set, so neither path re-enters this getter). Nothing in private windows.
        value.historySnapshot = { [weak self] profileID in self?.extensionHistorySnapshot(profileID: profileID) }
        for (profile, library) in profileLibraries { wireExtensionHistory(library, profileID: profile, host: value) }
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
            if let tab = self.session.tabs.first(where: { $0.id == id }) {
                // An Arc Easel is a native reference, not a web page: extensions cannot navigate it into one.
                guard !tab.isArcEasel else { return false }
                self.navigatePane(id, address: url.absoluteString); return true
            }
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
            if web == nil, let tab = self.session.tabs.first(where: { $0.id == id }) {
                // Never allocate a renderer for an Arc Easel's native reference.
                guard !tab.isArcEasel else { return false }
                web = self.webView(for: tab)
            }
            guard let web else { return false }
            if fromOrigin { web.reloadFromOrigin() } else { web.reload() }
            return true
        }
        value.createTab = { [weak self, weak value] url, profile, active in
            self?.openProfileTab(url, profileID: profile, active: active, kept: value?.createsKeptTab == true, before: value?.createsTabBefore)
        }
        value.placesTabsBeforeAnchor = true
        value.setTabPinned = { [weak self] id, profile, pinned in
            // nil is success: never coalesce it into a refusal.
            guard let self else { return "This tab cannot be pinned or unpinned." }
            return self.setExtensionTabPinned(id, profileID: profile, pinned: pinned)
        }
        // Only windows an extension opened may be closed by one; user-opened Little Bam windows are not.
        final class OpenedWindows { var ids = Set<ObjectIdentifier>() }
        let opened = OpenedWindows()
        value.createWindow = { [weak self, weak value] url, profile, focused in
            guard let self else { return nil }
            let before = Set(self.littleWindows.keys)
            // Little Bam refuses non-web addresses on its own; an extension's own page
            // goes in after the window exists, through the readiness-gated open path.
            let isExtensionPage = BrowserExtensions.pageSchemes.contains(url?.scheme ?? "")
            self.openLittleOrbit(url: isExtensionPage ? nil : url, profileID: profile)
            guard let id = self.littleWindows.keys.first(where: { !before.contains($0) }), let little = self.littleWindows[id], let window = little.window else { return nil }
            // The extension's own page, in its own WebKit configuration (as extension tabs are). Every navigation in the
            // window must stay on that extension's origin while it is still owned and enabled in this profile.
            if isExtensionPage, let url {
                guard let configuration = value?.configuration(forExtensionURL: url, profileID: profile) else { little.close(); return nil }
                let authorize: (URL) -> Bool = { [weak value] candidate in
                    guard let value, candidate.scheme == url.scheme, candidate.host == url.host, candidate.port == url.port else { return false }
                    return value.allowsExtensionURL(candidate, profileID: profile)
                }
                if !little.openExtensionPage(url, configuration: configuration, authorize: authorize) { little.close(); return nil }
            }
            opened.ids.insert(ObjectIdentifier(window))
            if !focused { self.view.window?.makeKeyAndOrderFront(nil) }
            return window
        }
        value.closeWindow = { [weak self] window in
            guard let self, opened.ids.contains(ObjectIdentifier(window)), let little = self.littleWindows.values.first(where: { $0.window === window }) else { return false }
            opened.ids.remove(ObjectIdentifier(window)); little.close(); return true
        }
        value.startDownload = { [weak self] web, url, _ in
            guard let self else { return false }
            web.startDownload(using: URLRequest(url: url)) { [weak self] download in self?.downloads.start(download: download) }
            return true
        }
        value.onChange = { [weak self] in self?.scheduleExtensionRefresh() }
        value.onReloadNeeded = { [weak self] profile in self?.offerExtensionReload(profileID: profile) }
        value.onExtensionRenderers = { [weak self] phase, profile, baseURL in self?.handleExtensionRenderers(phase, profileID: profile, baseURL: baseURL) ?? [] }
        value.onSiteAccessRestartFinished = { [weak self] _, _ in self?.scheduleExtensionRefresh() }
        return value
    }
    func configureExtensions(_ configuration: WKWebViewConfiguration, profileID: UUID) {
        if #available(macOS 15.4, *) {
            preloadHistoryForExtensions(profileID: profileID)
            browserExtensions.configure(configuration, profileID: profileID)
        }
    }
    /// The profile's library is loaded as part of preparing its extension runtime, before any of that
    /// profile's extensions can run. So history.search reads memory only and never triggers disk I/O.
    /// Not in private windows (no library file, and history is unavailable there).
    func preloadHistoryForExtensions(profileID: UUID) {
        guard !extensionsOff else { return }
        _ = library(for: profileID)
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
    /// A tab's `isLoading` flipped. Remembered until the next surface list consumes it,
    /// so `reconcile` reports `.loading` even when the flag already flipped back.
    func noteExtensionLoadingChange(_ id: UUID) {
        extensionLoadingChanges.insert(id)
        scheduleExtensionRefresh()
    }
    func scheduleExtensionRefresh() {
        // Invalidate synchronously even when event publication is coalesced,
        // disabled, or shutting down.
        invalidateExtensionSurfaceTopology()
        guard !isShuttingDown, extensionRefreshWork == nil else { return }
        guard #available(macOS 15.4, *), let extensions = extensionStorage as? BrowserExtensions else { return }
        let work = DispatchWorkItem { [weak self, weak extensions] in
            self?.extensionRefreshWork = nil
            guard self?.isShuttingDown == false else { return }
            extensions?.reconcile()
            self?.refreshExtensionActions()
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
        let members = session.tabs.filter { session.profileID(for: $0) == profileID }
        var result: [BrowserExtensionSurface] = members.map { tab in
            BrowserExtensionSurface(id: tab.id, title: tab.displayTitle, url: URL(string: tab.address), webView: browsers[tab.id], window: viewIfLoaded?.window,
                isActive: session.currentProfileID == profileID && focusedTabID == tab.id && peeks[session.activeID]?.isPresented != true,
                isSelected: session.currentProfileID == profileID && visibleMemberIDs.contains(tab.id), isPinned: tab.isSaved,
                isLoading: browsers[tab.id]?.isLoading == true, loadingChanged: extensionLoadingChanges.contains(tab.id))
        }
        extensionLoadingChanges.subtract(members.map(\.id))
        for (owner, peek) in peeks {
            guard let web = peek.webView, self.profileID(of: web) == profileID, let id = peekExtensionIDs[owner] else { continue }
            // Shown after the window's tabs: new extension tabs land before it.
            result.append(BrowserExtensionSurface(id: id, title: web.title ?? "Peek", url: web.url, webView: web, window: viewIfLoaded?.window,
                isActive: session.activeID == owner && peek.isPresented, isSelected: session.activeID == owner && peek.isPresented, isLoading: web.isLoading, isPeek: true))
        }
        for (id, little) in littleWindows {
            guard let web = little.webView, self.profileID(of: web) == profileID else { continue }
            // One page, no tabs: reported to extensions as a popup window, which cannot take new tabs.
            result.append(BrowserExtensionSurface(id: id, title: web.title ?? "Little Bam", url: web.url, webView: web, window: little.window,
                isActive: true, isSelected: true, isLoading: web.isLoading, isSinglePage: true))
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
                isSelected: session.currentProfileID == profileID && visibleMemberIDs.contains(tab.id), isPinned: tab.isSaved,
                isLoading: browsers[tab.id]?.isLoading == true)
        }
        for (owner, peek) in peeks where peekExtensionIDs[owner] == id {
            guard let web = peek.webView, self.profileID(of: web) == profileID else { continue }
            return BrowserExtensionSurface(id: id, title: web.title ?? "Peek", url: web.url, webView: web, window: viewIfLoaded?.window,
                isActive: session.activeID == owner && peek.isPresented, isSelected: session.activeID == owner && peek.isPresented, isLoading: web.isLoading)
        }
        if let little = littleWindows[id], let web = little.webView, self.profileID(of: web) == profileID {
            return BrowserExtensionSurface(id: id, title: web.title ?? "Little Bam", url: web.url, webView: web, window: little.window,
                isActive: true, isSelected: true, isLoading: web.isLoading)
        }
        return nil
    }
    var extensionCommandTabID: UUID? {
        if let pair = littleWindows.first(where: { $0.value.window?.isKeyWindow == true }) { return pair.key }
        if peeks[session.activeID]?.isPresented == true { return peekExtensionIDs[session.activeID] }
        return session.tabs.contains(where: { $0.id == focusedTabID }) ? focusedTabID : nil
    }
    /// The sidebar always represents the main window, even while a Little Bam
    /// window is key. Re-resolve its tab/profile when clicked, never from a cached row.
    var sidebarExtensionTabID: UUID? {
        if peeks[session.activeID]?.isPresented == true { return peekExtensionIDs[session.activeID] }
        return session.tabs.contains(where: { $0.id == focusedTabID }) ? focusedTabID : nil
    }
    func refreshExtensionActions() {
        guard isViewLoaded else { return }
        guard #available(macOS 15.4, *), let extensions = extensionStorage as? BrowserExtensions else {
            sidebar.updateExtensions([]); return
        }
        let items = extensions.actionItems(profileID: session.currentProfileID, tabID: sidebarExtensionTabID)
        sidebar.updateExtensions(items.map { SidebarExtensionItem(id: $0.id, name: $0.name, label: $0.label,
            icon: $0.icon, badge: $0.badge, isEnabled: $0.isEnabled) })
    }
    func invokeSidebarExtension(_ id: UUID, anchor: NSView) {
        guard #available(macOS 15.4, *), !suspendsChromeInteraction,
              browserExtensions.items(profileID: session.currentProfileID).contains(where: { $0.id == id && $0.enabled }) else { return }
        browserExtensions.performAction(extensionID: id, tabID: sidebarExtensionTabID, anchor: anchor)
    }
    func showSidebarExtensions(anchor: NSView) {
        guard #available(macOS 15.4, *), !suspendsChromeInteraction else { return }
        browserExtensions.reconcile()
        let menu = browserExtensions.actionsMenu(profileID: session.currentProfileID, tabID: sidebarExtensionTabID, anchor: anchor)
        menu.addItem(.separator())
        let library = NSMenuItem(title: "Add Extensions…", action: #selector(showExtensionLibrary(_:)), keyEquivalent: "")
        library.target = self; menu.addItem(library)
        let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(manageExtensions(_:)), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
    }
    @objc func showExtensionLibrary(_ sender: Any?) {
        guard #available(macOS 15.4, *) else { manageExtensions(sender); return }
        let profile = commandProfileID
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = profileStores.store(for: profile)
        preloadHistoryForExtensions(profileID: profile)
        browserExtensions.configure(configuration, profileID: profile)
        browserExtensions.showLibrary(profileID: profile, relativeTo: NSApp.keyWindow ?? view.window)
    }

    @objc func manageExtensions(_ sender: Any?) {
        guard #available(macOS 15.4, *) else {
            let alert = NSAlert(); alert.messageText = "Extensions need macOS 15.4 or later"; alert.addButton(withTitle: "OK"); alert.runModal(); return
        }
        let profile = commandProfileID
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = profileStores.store(for: profile)
        preloadHistoryForExtensions(profileID: profile)
        browserExtensions.configure(configuration, profileID: profile)
        browserExtensions.showManager(profileID: profile, relativeTo: NSApp.keyWindow ?? view.window)
    }
    func updateExtensionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let profile = commandProfileID
        let heading = NSMenuItem(title: "Profile: \(session.profileName(profile))", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        let library = NSMenuItem(title: "Add Extensions…", action: #selector(showExtensionLibrary(_:)), keyEquivalent: ""); library.target = self; menu.addItem(library)
        let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(manageExtensions(_:)), keyEquivalent: ""); manage.target = self; menu.addItem(manage)
        guard #available(macOS 15.4, *) else { return }
        menu.addItem(.separator())
        browserExtensions.reconcile()
        let anchor = commandWebView?.superview ?? sidebar
        let actions = browserExtensions.actionsMenu(profileID: profile, tabID: extensionCommandTabID, anchor: anchor)
        for item in actions.items { actions.removeItem(item); menu.addItem(item) }
    }
    /// An extension restart replaces its context. Bam's renderers of that extension's own pages (exact
    /// `webkit-extension://<install>/` origin, that profile only) are retired before the old context unloads, so Bam holds
    /// no strong reference to their web views (`retireProfilePage` drops the renderer, its observers, delegates, view and
    /// origin), then recreated from the fresh context. Tab IDs, addresses, folders, pins, order and profiles are model
    /// state and are untouched. Ordinary site pages and other extensions' pages are never matched. A Peek or Little Bam
    /// showing such a page is closed (no persistent identity). Background tabs stay unloaded and restore when selected.
    /// If the extension is stopped, retired tabs stay restorable: selecting one shows the unavailable error, and a later
    /// Enable (a `.restore` from `load`) recreates them.
    @available(macOS 15.4, *)
    @discardableResult
    func handleExtensionRenderers(_ phase: BrowserExtensions.ExtensionRendererPhase, profileID: UUID, baseURL: URL) -> [RetiredRendererProbe] {
        guard !isShuttingDown, let baseScheme = baseURL.scheme, BrowserExtensions.pageSchemes.contains(baseScheme), let origin = baseURL.host?.lowercased() else { return [] }
        var released: [RetiredRendererProbe] = []
        let extensionController = browserExtensions.extensionController(profileID: profileID)
        /// A preview of this exact install in this profile's runtime: its profile and its configuration's extension
        /// controller must match, and its current, requested or pending URL is on the install's origin (an in-flight
        /// extension navigation can hide behind a prior ordinary URL).
        func showsThisExtension(_ web: WKWebView?) -> Bool {
            guard let web, self.profileID(of: web) == profileID, let extensionController,
                  web.configuration.webExtensionController === extensionController else { return false }
            let preview = web as? PreviewWKWebView
            return [web.url, preview?.requestedURL, preview?.pendingReadyURL].contains { url in
                url?.scheme == baseScheme && url?.host?.lowercased() == origin
            }
        }
        func retire(_ ids: [UUID]) {
            guard !ids.isEmpty else { return }
            // Everything AppKit autoreleases while detaching (the view hierarchy, the responder) is released when this
            // pool ends, before the caller unloads the old context. A focused page resigns first, so the window's
            // responder chain doesn't keep it.
            autoreleasepool {
                if let window = view.window, let focused = focusedView(in: window),
                   let id = ids.first(where: { id in browsers[id].map { focused === $0 || focused.isDescendant(of: $0) } ?? false }) {
                    retiredExtensionFocus = id
                    window.makeFirstResponder(nil)
                }
                retiredRendererProbes.removeAll { $0.web == nil }   // released ones carry no evidence; don't accumulate
                for id in ids {
                    let probe = RetiredRendererProbe(browsers[id], role: visibleMemberIDs.contains(id) ? "tab(visible)" : "tab")
                    retiredRendererProbes.append(probe); released.append(probe)
                }
                isApplyingProfileChange = true
                for id in ids { retireProfilePage(id) }
                isApplyingProfileChange = false
            }
        }
        func showIfVisible(_ ids: Set<UUID>) {
            guard !ids.isDisjoint(with: visibleMemberIDs) else { return }
            showActive()
            if let focus = retiredExtensionFocus, ids.contains(focus), let web = browsers[focus], let window = web.window,
               window.isKeyWindow { window.makeFirstResponder(web) }
            if let focus = retiredExtensionFocus, ids.contains(focus) { retiredExtensionFocus = nil }
        }
        switch phase {
        case .retire:
            for (owner, peek) in peeks where showsThisExtension(peek.webView) {
                released.append(RetiredRendererProbe(peek.webView, role: "peek"))
                peek.dismiss(); peeks.removeValue(forKey: owner); peekExtensionIDs.removeValue(forKey: owner)
            }
            for little in littleWindows.values where showsThisExtension(little.webView) { released.append(RetiredRendererProbe(little.webView, role: "little-bam")); little.close() }
            let ids = session.tabs.filter { session.profileID(for: $0) == profileID && browsers[$0.id] != nil && browserExtensionOrigins[$0.id] == origin }.map(\.id)
            retiredExtensionRenderers[origin, default: []].formUnion(ids)
            retire(ids)
        case .restore:
            guard let retired = retiredExtensionRenderers.removeValue(forKey: origin) else { return [] }
            let live = Set(session.tabs.filter { session.profileID(for: $0) == profileID }.map(\.id))
            let ids = retired.intersection(live)
            // A renderer made while the extension was stopped (showing the unavailable error) is replaced too.
            retire(ids.filter { browsers[$0] != nil })
            showIfVisible(ids)
            refresh()
        case .unavailable:
            // Retired tabs stay in `retiredExtensionRenderers` for Enable; a visible one shows the unavailable error now.
            showIfVisible(retiredExtensionRenderers[origin] ?? [])
            refresh()
        }
        return released
    }
    /// The message a tab shows for an extension page Bam won't open right now.
    func extensionPageUnavailableMessage(_ url: URL, profileID: UUID) -> String {
        if #available(macOS 15.4, *), browserExtensions.isRestarting(extensionURL: url, profileID: profileID) {
            return "This extension is restarting to apply a website access change — its page reopens when it’s back"
        }
        return "This extension is unavailable in this profile — open Manage Extensions to enable it"
    }
    /// How many renderers retired for an extension restart are still alive (weakly observed): evidence only.
    func retiredRenderersAlive() -> Int {
        retiredRendererProbes.removeAll { $0.web == nil }
        return retiredRendererProbes.count
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

    /// history.search's data: the registered profile's in-memory library, newest first. Memory only: no
    /// file or page is ever read on request (the library is preloaded when the profile's extension runtime is
    /// prepared). nil (an error for the extension, never an empty history) when that library isn't in memory,
    /// in private windows, while closing or switching profiles, or for an unknown profile.
    @available(macOS 15.4, *)
    func extensionHistorySnapshot(profileID: UUID) -> [ExtensionHistory.Visit]? {
        let available = !extensionsOff && !isShuttingDown && !isApplyingProfileChange && session.profiles.contains(where: { $0.id == profileID })
        return LibraryHistoryEvents.snapshot(of: profileLibraries[profileID], available: available)
    }

    /// Sends this profile library's genuine changes to the extension engine. Assigning replaces any earlier
    /// handler, so a library is never wired twice. Weak captures; each event re-checks that the profile is
    /// registered and that the controller isn't closing. (A visit during a profile switch is still a genuine
    /// visit of this library's own profile, so it isn't dropped; the engine re-checks grant and contexts.)
    /// Nothing in private windows.
    @available(macOS 15.4, *)
    func wireExtensionHistory(_ library: BrowserLibrary, profileID: UUID, host: BrowserExtensions) {
        guard !extensionsOff else { return }
        library.onHistoryChange = { [weak self, weak library, weak host] change in
            guard let self, let library, let host, !self.isShuttingDown,
                  self.session.profiles.contains(where: { $0.id == profileID }),
                  let event = LibraryHistoryEvents.change(change, history: library.history) else { return }
            host.historyChanged(profileID: profileID, change: event)
        }
    }
}
