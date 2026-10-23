import AppKit
import WebKit

@MainActor extension BrowserController {
    func sidebarItem(_ tab: BrowserTab, activeID: UUID) -> SidebarTabItem {
        let companion = session.split(for: tab.id).flatMap { group in session.tabs.first { $0.id == group.secondaryID } }
        return SidebarTabItem(id: tab.id, title: companion.map { "\(tab.title) · \($0.title)" } ?? tab.title, subtitle: companion.map { "\(tab.address) | \($0.address)" } ?? tab.address, symbol: companion == nil ? tab.symbol : "rectangle.split.2x1", isPinned: tab.pinned, isActive: tab.id == activeID)
    }
    func showSplit(_ group: BrowserSplit) {
        guard let left = session.tabs.first(where: { $0.id == group.primaryID }), let right = session.tabs.first(where: { $0.id == group.secondaryID }) else { return }
        let split = splitCoordinators[group.primaryID] ?? makeSplitCoordinator(group)
        let leftWeb = webView(for: left), rightWeb = webView(for: right)
        webHost.addSubview(split.view); split.view.frame = webHost.bounds
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
            split.updateMetadata(side: side, address: tab.address, title: tab.title, canGoBack: web?.canGoBack ?? false, canGoForward: web?.canGoForward ?? false, isLoading: web?.isLoading ?? false)
        }
    }
    func returnPaneVideo(_ id: UUID) {
        if let web = browsers[id], pictureInPicture.references(web) { pictureInPicture.restore() }
    }
    func navigatePane(_ id: UUID, address: String) {
        returnPaneVideo(id)
        guard let i = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[i].address = address
        session.tabs[i].title = URL(string: address)?.host ?? "New tab"
        load(address, in: webView(for: session.tabs[i]), id: id); refresh(); save()
    }
    func openSplit(adopting web: WKWebView, beside owner: UUID) {
        guard let primary = session.tabs.first(where: { $0.id == owner }) else { _ = adoptWebView(web); return }
        cancelPaging(); dismissAddress(); session.select(primary.id)
        if session.split(for: primary.id) != nil { unsplit(primary.id) }
        let address = ((web as? PreviewWKWebView)?.promotionURL ?? web.url).flatMap { URLInput.directURL($0.absoluteString) }?.absoluteString ?? "orbit://newtab"
        let id = session.add(address: address, title: web.title)
        web.removeFromSuperview(); register(web, id: id)
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
        if session.split(for: primary) != nil { return }
        let id = session.add()
        session.makeSplit(primary: primary, secondary: id); showActive(); save()
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
