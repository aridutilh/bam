import AppKit
import WebKit

@MainActor extension BrowserController {
    func sidebarItems(in snapshot: BrowserSession) -> [SidebarTabItem] {
        // Build indexes once per update, rather than scan the entire session
        // for every sidebar row. A thousand metadata-only tabs must stay cheap.
        let tabsByID = Dictionary(snapshot.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favoriteCount = snapshot.favoriteTabs.count
        var companions: [UUID: BrowserTab] = [:]
        for split in snapshot.splits ?? [] { companions[split.primaryID] = tabsByID[split.secondaryID] }
        func item(_ tab: BrowserTab, depth: Int = 0, parent: UUID? = nil, earlier: Bool = false, later: Bool = false) -> SidebarTabItem {
            let companion = companions[tab.id]
            return SidebarTabItem(id: tab.id, title: companion.map { "\(tab.displayTitle) · \($0.displayTitle)" } ?? tab.displayTitle,
                subtitle: companion.map { "\(tab.address) | \($0.address)" } ?? tab.address,
                symbol: companion == nil ? tab.symbol : "rectangle.split.2x1", isPinned: tab.pinned,
                isActive: tab.id == snapshot.activeID, isFavorite: tab.isFavorite, isUnloaded: tab.isUnloaded, isSleeping: tab.isSleeping,
                isSplit: companion != nil, canFavorite: companion == nil && (tab.isFavorite || favoriteCount < BrowserSession.maximumFavorites),
                depth: depth, parentFolderID: parent, hasEarlierSibling: earlier, hasLaterSibling: later,
                canWrapInFolder: !tab.isFavorite && URLInput.extensionURL(tab.address) == nil)
        }
        let visible = snapshot.visibleTabs
        // Stable indent: from the whole tree, so collapsing the deepest branch doesn't shift rows.
        let treeDepth = snapshot.keptLayout(in: snapshot.space).map(\.depth).max() ?? 0
        var result = visible.filter(\.isFavorite).map { item($0) }
        var siblings: [BrowserSession.KeptContainer: [UUID]] = [:]
        for entry in snapshot.visibleKeptLayout(in: snapshot.space, revealing: snapshot.activeID) {
            let container: BrowserSession.KeptContainer = entry.parentID.map { .folder($0) } ?? .root(snapshot.space)
            if siblings[container] == nil { siblings[container] = snapshot.keptChildren(of: container) }
            let order = siblings[container] ?? []
            let index = order.firstIndex(of: entry.id)
            let earlier = (index ?? 0) > 0, later = index.map { $0 + 1 < order.count } ?? false
            if entry.isFolder, let folder = snapshot.folder(entry.id) {
                result.append(SidebarTabItem(id: folder.id, title: folder.name, subtitle: "", symbol: "folder", isPinned: true,
                    isActive: false, canFavorite: false, depth: entry.depth, isFolder: true, isExpanded: !folder.isCollapsed,
                    parentFolderID: entry.parentID, hasEarlierSibling: earlier, hasLaterSibling: later,
                    folderTabCount: snapshot.tabIDs(inFolder: folder.id).count,
                    canNestFolder: snapshot.canCreateFolder(inside: folder.id)))
            } else if let tab = tabsByID[entry.id] {
                result.append(item(tab, depth: entry.depth, parent: entry.parentID, earlier: earlier, later: later))
            }
        }
        result += visible.filter { !$0.isSaved }.map { item($0) }
        for index in result.indices { result[index].treeDepth = treeDepth }
        return result
    }
    func showSplit(_ group: BrowserSplit) {
        guard let left = session.tabs.first(where: { $0.id == group.primaryID }), let right = session.tabs.first(where: { $0.id == group.secondaryID }) else { return }
        let split = splitCoordinators[group.primaryID] ?? makeSplitCoordinator(group)
        let leftWeb = webView(for: left), rightWeb = webView(for: right)
        installActiveHost(split.view)
        split.configure(left: pictureInPicture.owns(leftWeb) ? nil : leftWeb, right: pictureInPicture.owns(rightWeb) ? nil : rightWeb, leftAddress: left.address, rightAddress: right.address)
    }
    func makeSplitCoordinator(_ group: BrowserSplit) -> SplitViewCoordinator {
        let split = SplitViewCoordinator()
        splitCoordinators[group.primaryID] = split
        let id: (SplitViewCoordinator.Side) -> UUID = { $0 == .left ? group.primaryID : group.secondaryID }
        split.onNavigate = { [weak self] side, url in self?.navigatePane(id(side), address: url.absoluteString) }
        split.onBack = { [weak self] side in self?.returnPaneVideo(id(side)); self?.browsers[id(side)]?.goBack() }
        split.onForward = { [weak self] side in self?.returnPaneVideo(id(side)); self?.browsers[id(side)]?.goForward() }
        split.onReload = { [weak self] side in
            guard let self, let web = self.browsers[id(side)] else { return }
            self.returnPaneVideo(id(side))
            if web.isLoading { web.stopLoading(); self.pendingLoads.remove(id(side)) }
            else if self.tabErrors[id(side)] != nil, let address = self.requestedAddresses[id(side)] { self.navigatePane(id(side), address: address) }
            else { web.reload() }
        }
        split.onFocus = { [weak self] _ in self?.refresh() }
        split.onClose = { [weak self] side in self?.closeSplitPane(id(side)) }
        split.onUnsplit = { [weak self] in self?.unsplit(group.primaryID) }
        split.onReturnVideo = { [weak self] side in self?.returnPaneVideo(id(side)) }
        return split
    }
    func refreshSplitMetadata() {
        guard let group = session.split(for: session.activeID), let split = splitCoordinators[group.primaryID] else { return }
        for (side, id) in [(SplitViewCoordinator.Side.left, group.primaryID), (.right, group.secondaryID)] {
            guard let tab = session.tabs.first(where: { $0.id == id }) else { continue }
            let web = browsers[id]
            split.updateMetadata(side: side, address: tab.address, title: tab.displayTitle, canGoBack: web?.canGoBack ?? false, canGoForward: web?.canGoForward ?? false, isLoading: web?.isLoading ?? false)
        }
    }
    func returnPaneVideo(_ id: UUID) {
        if let web = browsers[id], pictureInPicture.references(web) { pictureInPicture.restore() }
    }
    func navigatePane(_ id: UUID, address: String) {
        returnPaneVideo(id)
        guard let i = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        // An Easel row shows a native view; giving it a web address (e.g. an
        // extension's tabs.update) must make the new page the visible host.
        let leavingNativeView = session.tabs[i].isArcEasel
        session.tabs[i].address = address
        session.tabs[i].title = URL(string: address)?.host ?? "New tab"
        load(address, in: webView(for: session.tabs[i]), id: id)
        if leavingNativeView && id == session.activeID { showActive() } else { refresh() }
        save()
    }
    func openSplit(adopting web: WKWebView, beside owner: UUID) {
        guard let primary = session.tabs.first(where: { $0.id == owner }) else { _ = adoptWebView(web); return }
        // A shared Favorite cannot belong to a Space-specific Split. Promote
        // its Peek to a normal tab instead, preserving the already loaded page.
        guard !primary.isFavorite else { _ = adoptWebView(web); return }
        if let sourceProfile = profileID(of: web), sourceProfile != session.profileID(for: primary) {
            _ = adoptWebView(web); return
        }
        cancelPaging(); dismissAddress(); session.select(primary.id)
        if session.split(for: primary.id) != nil { unsplit(primary.id) }
        let pendingURL = (web as? PreviewWKWebView)?.pendingReadyURL
        (web as? PreviewWKWebView)?.pendingReadyURL = nil
        let address = (pendingURL ?? (web as? PreviewWKWebView)?.promotionURL ?? web.url).flatMap { URLInput.directURL($0.absoluteString) }?.absoluteString ?? "orbit://newtab"
        let id = session.add(address: address, title: web.title)
        web.removeFromSuperview(); register(web, id: id)
        if pendingURL != nil { load(address, in: web, id: id) }
        if web.isLoading { pendingLoads.insert(id) }
        session.makeSplit(primary: primary.id, secondary: id)
        showActive()
        view.window?.makeKeyAndOrderFront(nil)
        // Give AppKit the final page responder before publishing the focused side;
        // otherwise its window-update observer can restore the old left focus.
        view.window?.makeFirstResponder(web)
        splitCoordinators[primary.id]?.setFocusedSide(.right)
        refresh(); save()
    }
    @objc func splitWithNewPage(_ sender: Any?) {
        let primary = session.activeID
        if session.split(for: primary) != nil || session.active?.isFavorite == true { return }
        // All or nothing: a refused Split (e.g. an Arc Easel reference, which
        // has no page) must not leave a new blank tab created and selected.
        var draft = session
        let id = draft.add()
        guard draft.makeSplit(primary: primary, secondary: id) else {
            if session.active?.isArcEasel == true { pageFeedback.show("Easels can’t be in a Split", symbol: "rectangle.split.2x1", in: webHost) }
            return
        }
        session = draft; showActive(); save()
        splitCoordinators[primary]?.focusAddress(.right)
    }
    @objc func unsplitCurrent(_ sender: Any?) { unsplit(session.activeID) }
    func unsplit(_ id: UUID) {
        guard let group = session.split(for: id) else { return }
        splitCoordinators.removeValue(forKey: group.primaryID)?.detach()
        session.removeSplit(containing: id); showActive(); save()
    }
    func closeSplitPane(_ id: UUID) {
        guard let group = session.split(for: id) else { close(id); return }
        let survivor = id == group.primaryID ? group.secondaryID : group.primaryID
        splitCoordinators.removeValue(forKey: group.primaryID)?.detach()
        session.removeSplit(containing: id)
        session.select(survivor); close(id)
    }
}
