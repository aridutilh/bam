import AppKit
import WebKit
import QuartzCore

@MainActor final class CanvasView: NSView {
    var onLayout: (() -> Void)?
    var space = 0 { didSet { if space != oldValue { previewSpace = nil; previewProgress = 0 }; needsDisplay = true } }
    var previewSpace: Int? { didSet { needsDisplay = true } }
    var previewProgress: CGFloat = 0 { didSet { needsDisplay = true } }
    private lazy var grain: NSImage? = Bundle.main.url(forResource: "WindowTheme-grain", withExtension: "png", subdirectory: "Recovered").flatMap(NSImage.init(contentsOf:))
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) {
        let palettes: [[NSColor]] = [
            [NSColor(srgbRed: 0.20, green: 0.17, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.29, green: 0.23, blue: 0.29, alpha: 1)],
            [NSColor(srgbRed: 0.17, green: 0.24, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.27, green: 0.29, blue: 0.22, alpha: 1)],
            [NSColor(srgbRed: 0.16, green: 0.22, blue: 0.29, alpha: 1), NSColor(srgbRed: 0.26, green: 0.23, blue: 0.34, alpha: 1)]
        ]
        let base = palettes[min(2, max(0, space))]
        let colors: [NSColor]
        if let previewSpace { colors = zip(base, palettes[min(2, max(0, previewSpace))]).map { $0.blended(withFraction: min(1,max(0,previewProgress)), of: $1) ?? $0 } }
        else { colors = base }
        NSGradient(colors: colors)?.draw(in: bounds, angle: 65)
        if let grain { for x in stride(from: CGFloat(0), to: bounds.width, by: 155) { for y in stride(from: CGFloat(0), to: bounds.height, by: 155) { grain.draw(in: NSRect(x: x, y: y, width: 155, height: 155), from: .zero, operation: .sourceOver, fraction: 0.045, respectFlipped: true, hints: nil) } } }
    }
}

@MainActor final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class PaletteField: NSTextField {
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

@MainActor final class DismissView: NSView {
    var dismiss: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { dismiss?() }
}

@MainActor final class BrowserController: NSViewController, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let root = CanvasView()
    let sidebar = SidebarView(frame: .zero)
    let handle = ResizeHandleView(frame: .zero)
    let card = FlippedContainer()
    let webHost = FlippedContainer()
    let topbar = FlippedContainer()
    let progress = NSView()
    let location = NSButton(title: "New tab", target: nil, action: nil)
    let reveal = NSButton()
    let pin = NSButton()
    let animator = CubicAnimator()
    let pagingAnimator = SpringAnimator()
    let pictureInPicture = PictureInPictureCoordinator()
    let findBar = FindBarCoordinator()
    let downloads: DownloadCoordinator
    lazy var library = BrowserLibrary(storageURL: privateMode ? nil : sessionURL.deletingLastPathComponent().appendingPathComponent("library.json"))
    var displayedTabID: UUID?
    var displayedMemberIDs: [UUID] = []
    var automaticDepartureQueue: [UUID] = []
    var automaticProbeInFlight = false
    var retiringSplitViews: [UUID: NSView] = [:]
    var splitCoordinators: [UUID: SplitViewCoordinator] = [:]
    var isShuttingDown = false
    var automaticallyShowsVideo = true
    var peeks: [UUID: PeekCoordinator] = [:]
    var littleWindows: [UUID: LittleArcController] = [:]
    var swipe = SpaceSwipeStateMachine()
    var scrollMonitor: Any?
    var trackingSwipe = false
    var pagingOffset: CGFloat = 0
    var pagingTarget: Int?
    let sessionURL: URL
    var session: BrowserSession
    var displayedWidth: CGFloat
    var browsers: [UUID: WKWebView] = [:]
    var observations: [UUID: [NSKeyValueObservation]] = [:]
    var addressOverlay: DismissView?
    var addressField: PaletteField?
    var addressCard: FlippedContainer?
    var tabSearchResults: TabSearchResultsView?
    var paletteShortcuts: NSTextField?
    var newTabOnSubmit = false
    var privateMode: Bool
    var saveWork: DispatchWorkItem?
    var tabErrors: [UUID: String] = [:]
    var pendingHome: Set<UUID> = []
    var pendingLoads: Set<UUID> = []
    var requestedAddresses: [UUID: String] = [:]

    init(sessionURL: URL, ephemeral: Bool = false, downloadCoordinator: DownloadCoordinator? = nil) {
        self.downloads = downloadCoordinator ?? DownloadCoordinator()
        self.sessionURL = sessionURL; self.privateMode = ephemeral
        session = ephemeral ? .fresh() : SessionFile.load(sessionURL)
        if !ephemeral, UserDefaults.standard.object(forKey: "AutomaticallyShowPlayingVideo") != nil { automaticallyShowsVideo = UserDefaults.standard.bool(forKey: "AutomaticallyShowPlayingVideo") }
        displayedWidth = session.sidebarVisible ? CGFloat(session.sidebarWidth) : 0
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = root; root.wantsLayer = true; root.layer?.masksToBounds = true
        root.onLayout = { [weak self] in self?.layoutBrowser() }
        [sidebar, card, handle].forEach(root.addSubview)
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.98, blue: 0.97, alpha: 1).cgColor
        card.layer?.cornerRadius = 9; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1; card.layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        card.addSubview(webHost); card.addSubview(topbar)
        topbar.wantsLayer = true; topbar.layer?.backgroundColor = NSColor(srgbRed: 0.98, green: 0.975, blue: 0.97, alpha: 1).cgColor
        topbar.addSubview(location); topbar.addSubview(reveal); topbar.addSubview(pin)
        for button in [location, reveal, pin] { button.isBordered = false; button.bezelStyle = .inline; button.contentTintColor = NSColor.secondaryLabelColor }
        location.font = .systemFont(ofSize: 11, weight: .medium); location.target = self; location.action = #selector(focusAddress)
        location.setAccessibilityLabel("Address — click to navigate")
        reveal.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar")
        reveal.target = self; reveal.action = #selector(toggleSidebar); reveal.toolTip = "Toggle sidebar ⌘S"
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin tab")
        pin.target = self; pin.action = #selector(togglePin); pin.toolTip = "Pin or unpin this tab"
        progress.wantsLayer = true; progress.layer?.backgroundColor = NSColor(srgbRed: 0.47, green: 0.39, blue: 0.66, alpha: 1).cgColor
        card.addSubview(progress)
        sidebar.onSelectTab = { [weak self] id in self?.select(id) }
        sidebar.onCloseTab = { [weak self] id in self?.close(id) }
        sidebar.onPinTab = { [weak self] id in self?.pinTab(id) }
        sidebar.onNewTab = { [weak self] in self?.newTab(nil) }
        sidebar.onSearch = { [weak self] in self?.focusAddress(nil) }
        sidebar.onBack = { [weak self] in self?.goBack(nil) }
        sidebar.onForward = { [weak self] in self?.goForward(nil) }
        sidebar.onReload = { [weak self] in self?.reload(nil) }
        sidebar.onToggleSidebar = { [weak self] in self?.toggleSidebar(nil) }
        sidebar.onSpaceChange = { [weak self] space in self?.changeSpace(space) }
        sidebar.onPictureInPicture = { [weak self] in self?.togglePictureInPicture(nil) }
        library.onOpenURL = { [weak self] address in
            guard let self else { return }; self.session.add(address: address); self.showActive(); self.save()
        }
        library.onRestoreClosed = { [weak self] record in self?.restoreClosed(record) }
        pictureInPicture.onChange = { [weak self] in self?.showActive() }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }; return self.handleSpaceScroll(event)
        }
        handle.onResize = { [weak self] width, ended in
            guard let self else { return }; self.cancelPaging(); self.animator.stop(); self.displayedWidth = width
            if width >= RecoveredMetrics.minWidth { self.session.sidebarWidth = Double(width) }
            self.layoutBrowser()
            if ended { self.save() }
        }
        handle.onCollapse = { [weak self] in self?.setSidebar(false) }
        handle.onReset = { [weak self] in self?.resetSidebar(nil) }
        showActive(); refresh()
    }

    var focusedTabID: UUID {
        guard let group = session.split(for: session.activeID), splitCoordinators[group.primaryID]?.focusedSide == .right else { return session.activeID }
        return group.secondaryID
    }
    var visibleMemberIDs: [UUID] {
        guard let group = session.split(for: session.activeID) else { return [session.activeID] }
        return [group.primaryID, group.secondaryID]
    }
    var activeWebView: WKWebView? { browsers[focusedTabID] }
    var commandWebView: WKWebView? {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { return little.webView }
        return peeks[session.activeID]?.webView ?? activeWebView
    }
    func layoutBrowser() {
        let w = root.bounds.width, h = root.bounds.height
        guard w > 0 && h > 0 else { return }
        let targetWidth = CGFloat(session.sidebarWidth)
        let width = min(max(0, displayedWidth), max(164, w - 360))
        sidebar.frame = NSRect(x: width - targetWidth, y: 0, width: targetWidth, height: h)
        sidebar.layer?.transform = CATransform3DIdentity
        sidebar.alphaValue = 1
        sidebar.isHidden = width < 0.5
        card.frame = NSRect(x: width + 8, y: 8, width: max(100, w - width - 16), height: h - 16)
        let toolbarHeight: CGFloat = width < 80 ? 36 : 0
        topbar.isHidden = toolbarHeight == 0
        topbar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: toolbarHeight)
        webHost.frame = NSRect(x: 0, y: toolbarHeight, width: card.bounds.width, height: max(0, card.bounds.height - toolbarHeight))
        if let web = activeWebView, web.superview === webHost { web.frame = webHost.bounds }
        for child in webHost.subviews where !(child is WKWebView) { child.frame = webHost.bounds }
        reveal.frame = NSRect(x: 84, y: 6, width: 25, height: 24)
        location.frame = NSRect(x: 115, y: 6, width: max(60, card.bounds.width - 160), height: 24)
        pin.frame = NSRect(x: card.bounds.width - 34, y: 6, width: 24, height: 24)
        progress.isHidden = !(activeWebView?.isLoading ?? false)
        progress.frame = NSRect(x: 0, y: toolbarHeight, width: card.bounds.width * CGFloat(activeWebView?.estimatedProgress ?? 0), height: 2)
        handle.frame = NSRect(x: max(0, width - 5), y: 44, width: 10, height: max(0, h - 60))
        handle.currentWidth = targetWidth; handle.isHidden = !session.sidebarVisible || width < 100
        if let overlay = addressOverlay, let content = addressCard {
            overlay.frame = root.bounds
            let cw = min(590, w - 60)
            let rowsHeight = tabSearchResults?.preferredHeight ?? 44
            content.frame = NSRect(x: (w - cw) / 2, y: min(100, h * 0.10), width: cw, height: 145 + rowsHeight)
            addressField?.frame = NSRect(x: 24, y: 50, width: cw - 48, height: 40)
            tabSearchResults?.frame = NSRect(x: 14, y: 116, width: cw - 28, height: rowsHeight)
            paletteShortcuts?.frame = NSRect(x: 26, y: 124 + rowsHeight, width: cw - 52, height: 18)
        }
    }

    func webView(for tab: BrowserTab) -> WKWebView {
        if let cached = browsers[tab.id] { return cached }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = privateMode ? .nonPersistent() : .default()
        let browser = WKWebView(frame: .zero, configuration: configuration)
        register(browser, id: tab.id)
        load(tab.address, in: browser, id: tab.id)
        return browser
    }
    func register(_ browser: WKWebView, id: UUID) {
        browser.navigationDelegate = self; browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.autoresizingMask = [.width, .height]
        browser.setAccessibilityLabel("Web content")
        browsers[id] = browser
        observations[id] = [
            browser.observe(\.title, options: [.new]) { [weak self] web, _ in DispatchQueue.main.async { self?.updateMetadata(web) } },
            browser.observe(\.url, options: [.new]) { [weak self] web, _ in DispatchQueue.main.async { self?.updateMetadata(web) } },
            browser.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.layoutBrowser() } },
            browser.observe(\.isLoading, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        ]
    }
    func load(_ address: String, in browser: WKWebView, id: UUID) {
        tabErrors.removeValue(forKey: id)
        requestedAddresses[id] = address; pendingLoads.insert(id)
        if address == "orbit://newtab" || address == "orbit://video" {
            pendingHome.insert(id)
            if let file = Bundle.main.url(forResource: address == "orbit://video" ? "PiPDemo" : "Home", withExtension: "html") { browser.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()) }
            else { browser.loadHTMLString("<h1>Orbit</h1><p>Press Command-L to explore.</p>", baseURL: nil) }
        } else if let url = URLInput.directURL(address) {
            pendingHome.remove(id); browser.load(URLRequest(url: url))
        }
    }
    func showActive() {
        guard let tab = session.active, !isShuttingDown else { return }
        let previousID = displayedTabID
        let arriving = visibleMemberIDs
        let outgoing = displayedMemberIDs.filter { !arriving.contains($0) }
        let switched = displayedTabID != nil && displayedTabID != tab.id
        // Commit identity before PiP restoration callbacks can re-enter.
        displayedTabID = tab.id; displayedMemberIDs = arriving
        if switched, let source = pictureInPicture.referencedTabID, arriving.contains(source) { pictureInPicture.restore() }
        // Keep a departing split attached behind the destination while both
        // asynchronous video candidates are inspected. Detaching it first can
        // suspend WebKit's second player before that candidate is examined.
        if automaticallyShowsVideo, outgoing.count > 1, let previousID, let split = splitCoordinators[previousID], split.view.superview === webHost {
            retiringSplitViews[previousID] = split.view
        }
        if automaticallyShowsVideo, !outgoing.isEmpty { automaticallyFloatDeparture(outgoing) }
        for (id, peek) in peeks { peek.setVisible(id == tab.id) }
        webHost.subviews.filter { child in !retiringSplitViews.values.contains { $0 === child } }.forEach { $0.removeFromSuperview() }
        if let group = session.split(for: tab.id) { showSplit(group) }
        else {
            let browser = webView(for: tab)
            if pictureInPicture.owns(browser) {
                let placeholder = PiPPlaceholder(frame: webHost.bounds)
                placeholder.returnVideo = { [weak self] in self?.pictureInPicture.restore() }
                webHost.addSubview(placeholder)
            } else { webHost.addSubview(browser); browser.frame = webHost.bounds }
        }
        refresh()
    }
    func automaticallyFloatDeparture(_ candidates: [UUID]) {
        for id in candidates where !automaticDepartureQueue.contains(id) { automaticDepartureQueue.append(id) }
        drainAutomaticDepartures()
    }
    func drainAutomaticDepartures() {
        guard !automaticProbeInFlight else { return }
        guard automaticallyShowsVideo, !isShuttingDown, pictureInPicture.referencedTabID == nil else {
            automaticDepartureQueue.removeAll(); releaseRetiringSplits(); return
        }
        while let first = automaticDepartureQueue.first,
              visibleMemberIDs.contains(first) || browsers[first] == nil || !session.tabs.contains(where: { $0.id == first }) {
            automaticDepartureQueue.removeFirst()
        }
        guard !automaticDepartureQueue.isEmpty else { releaseRetiringSplits(); return }
        let id = automaticDepartureQueue.removeFirst()
        guard let outgoing = browsers[id] else { drainAutomaticDepartures(); return }
        automaticProbeInFlight = true
        pictureInPicture.automaticallyPresentIfPlaying(web: outgoing, tabID: id, shouldPresent: { [weak self, weak outgoing] in
            guard let self, let outgoing else { return false }
            return !self.isShuttingDown && self.automaticallyShowsVideo && !self.visibleMemberIDs.contains(id)
                && self.session.tabs.contains(where: { $0.id == id }) && self.browsers[id] === outgoing
        }, restore: { [weak self] _ in self?.showActive() }, completion: { [weak self] presented in
            guard let self else { return }
            self.automaticProbeInFlight = false
            if presented { self.automaticDepartureQueue.removeAll(); self.releaseRetiringSplits() }
            else { self.drainAutomaticDepartures() }
        })
    }
    func releaseRetiringSplits() {
        for (id, retiringView) in retiringSplitViews where session.activeID != id { retiringView.removeFromSuperview() }
        retiringSplitViews.removeAll()
    }
    func prepareToClose() {
        isShuttingDown = true; automaticDepartureQueue.removeAll(); releaseRetiringSplits(); findBar.hide(); downloads.cancelAll(); pictureInPicture.restore()
        for peek in Array(peeks.values) { peek.dismiss() }
        for little in Array(littleWindows.values) { little.close() }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor); scrollMonitor = nil }
        cancelPaging(); animator.stop(); save()
    }
    func updateMetadata(_ web: WKWebView) {
        guard let pair = browsers.first(where: { $0.value === web }), let i = session.tabs.firstIndex(where: { $0.id == pair.key }) else { return }
        guard !pendingLoads.contains(pair.key), tabErrors[pair.key] == nil else { return }
        if let url = web.url, ["https", "http"].contains(url.scheme ?? "") {
            session.tabs[i].address = url.absoluteString
            session.tabs[i].title = web.title?.isEmpty == false ? web.title! : url.host ?? "New tab"
        } else if web.url?.standardizedFileURL == Bundle.main.url(forResource: "PiPDemo", withExtension: "html")?.standardizedFileURL {
            session.tabs[i].address = "orbit://video"; session.tabs[i].title = "Picture in Picture demo"
        } else if web.url?.standardizedFileURL == Bundle.main.url(forResource: "Home", withExtension: "html")?.standardizedFileURL || (web.url == nil && pendingHome.contains(pair.key)) {
            session.tabs[i].address = "orbit://newtab"; session.tabs[i].title = "A little space"
        }
        refresh(); scheduleSave()
    }
    func refresh() {
        guard isViewLoaded else { return }
        root.space = session.space
        let tabs = session.visibleTabs.map { sidebarItem($0, activeID: session.activeID) }
        sidebar.update(tabs: tabs, space: session.space, canGoBack: activeWebView?.canGoBack ?? false, canGoForward: activeWebView?.canGoForward ?? false, isLoading: activeWebView?.isLoading ?? false)
        if let tab = session.active {
            let host = URL(string: tab.address)?.host ?? tab.address
            location.title = tabErrors[tab.id] ?? (tab.isHome ? "Orbit  /  New tab" : host)
            location.toolTip = tab.isHome ? "Search or enter a URL ⌘L" : tab.address
            sidebar.setAddress(tab.address, title: tabErrors[tab.id] ?? (tab.isHome ? "Search or enter URL" : host))
            pin.image = NSImage(systemSymbolName: tab.pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin tab")
            view.window?.title = "\(tab.title) — Orbit"
        }
        refreshSplitMetadata()
        if findBar.isVisible { findBar.retarget(web: commandWebView) }
        layoutBrowser()
    }
    func select(_ id: UUID) { cancelPaging(); session.select(id); dismissAddress(); showActive(); save() }
    func close(_ id: UUID) {
        cancelPaging()
        let group = session.split(for: id)
        let closingIDs = group?.primaryID == id ? [id, group!.secondaryID] : [id]
        let closed = closingIDs.compactMap { closingID in session.tabs.first { $0.id == closingID } }
        library.recordClosed(tabs: closed, split: closed.count == 2)
        _ = session.close(id)
        if let group { splitCoordinators.removeValue(forKey: group.primaryID)?.detach() }
        for closingID in closingIDs {
            peeks[closingID]?.dismiss()
            if let web = browsers[closingID], pictureInPicture.references(web) { pictureInPicture.restore() }
            observations.removeValue(forKey: closingID)
            browsers[closingID]?.stopLoading(); browsers[closingID]?.navigationDelegate = nil; browsers[closingID]?.uiDelegate = nil
            browsers[closingID]?.removeFromSuperview(); browsers.removeValue(forKey: closingID)
            pendingHome.remove(closingID); tabErrors.removeValue(forKey: closingID); pendingLoads.remove(closingID); requestedAddresses.removeValue(forKey: closingID)
        }
        showActive(); save()
    }
    func pinTab(_ id: UUID) {
        cancelPaging()
        guard let i = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[i].pinned.toggle(); refresh(); save()
    }
    func sidebarItems(for space: Int) -> [SidebarTabItem] {
        var preview = session; preview.changeSpace(space)
        return preview.visibleTabs.map { sidebarItem($0, activeID: preview.activeID) }
    }
    func cancelPaging() {
        pagingAnimator.stop(); swipe.reset(); trackingSwipe = false; pagingOffset = 0; pagingTarget = nil; sidebar.endPaging(); root.previewSpace = nil; root.previewProgress = 0
    }
    func changeSpace(_ space: Int) {
        guard (0...2).contains(space) else { return }
        if space == session.space { cancelPaging(); return }
        cancelPaging(); dismissAddress()
        let direction: CGFloat = space > session.space ? 1 : -1
        sidebar.beginPaging(tabs: sidebarItems(for: space), space: space, direction: direction)
        pagingTarget = space
        finishPaging(commit: space)
    }
    func handleSpaceScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === view.window, session.sidebarVisible, addressOverlay == nil,
              (trackingSwipe || sidebar.bounds.contains(sidebar.convert(event.locationInWindow, from: nil))), event.hasPreciseScrollingDeltas else { return event }
        let phase: SpaceSwipeStateMachine.Phase
        if event.phase.contains(.began) { phase = .began; trackingSwipe = true; pagingAnimator.stop(); pagingOffset = 0; pagingTarget = nil; sidebar.endPaging(); root.previewSpace = nil; root.previewProgress = 0 }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.changed) { phase = .changed }
        else { phase = .none }
        let result = swipe.handle(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, phase: phase, isMomentum: !event.momentumPhase.isEmpty, timestamp: event.timestamp, space: session.space, width: sidebar.bounds.width)
        if let offset = result.previewOffset {
            pagingOffset = offset
            let direction: CGFloat = offset < 0 ? 1 : -1
            let target = session.space + Int(direction)
            if (0...2).contains(target) {
                if pagingTarget != target { sidebar.beginPaging(tabs: sidebarItems(for: target), space: target, direction: direction); pagingTarget = target }
            } else if pagingTarget != nil { sidebar.endPaging(); pagingTarget = nil }
            sidebar.setPagingOffset(offset); root.previewSpace = pagingTarget; root.previewProgress = abs(offset) / max(1,sidebar.bounds.width)
        }
        if phase == .ended || phase == .cancelled { trackingSwipe = false }
        if result.finished { finishPaging(commit: result.committedSpace) }
        return result.shouldConsume ? nil : event
    }
    func finishPaging(commit: Int?) {
        let end: CGFloat = commit.map { $0 > session.space ? -sidebar.bounds.width : sidebar.bounds.width } ?? 0
        pagingAnimator.animate(from: pagingOffset, to: end, response: 0.30, dampingRatio: 0.99, update: { [weak self] offset in
            guard let self else { return }
            self.pagingOffset = offset; self.sidebar.setPagingOffset(offset)
            self.root.previewSpace = self.pagingTarget; self.root.previewProgress = abs(offset) / max(1,self.sidebar.bounds.width)
        }, completion: { [weak self] in
            guard let self else { return }
            if let commit { self.session.changeSpace(commit); self.showActive(); self.save() }
            self.sidebar.endPaging(); self.pagingOffset = 0; self.pagingTarget = nil; self.root.previewSpace = nil; self.root.previewProgress = 0
        })
    }
    @objc func nextSpace(_ sender: Any?) { changeSpace(min(2, session.space+1)) }
    @objc func previousSpace(_ sender: Any?) { changeSpace(max(0, session.space-1)) }
    func setSidebar(_ visible: Bool) {
        cancelPaging(); session.sidebarVisible = visible
        // Three concrete presentation-transition callbacks use this recovered curve.
        animator.animate(from: displayedWidth, to: visible ? CGFloat(session.sidebarWidth) : 0, duration: 0.08, controlPoints: (0.25, 0.46, 0.45, 0.94), update: { [weak self] value in
            guard let self else { return }; self.displayedWidth = value; self.layoutBrowser()
        }, completion: { [weak self] in self?.save() })
    }
    @objc func togglePictureInPicture(_ sender: Any?) {
        if pictureInPicture.activeTabID != nil, view.window?.isKeyWindow == false { pictureInPicture.restore(); return }
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { little.promoteToOrbit() }
        peeks[session.activeID]?.promoteToTab()
        guard let web = activeWebView else { return }
        pictureInPicture.toggle(web: web, tabID: focusedTabID, restore: { [weak self] _ in self?.showActive() }, report: { [weak self] message in
            guard let window = self?.view.window else { return }
            let alert = NSAlert(); alert.messageText = "Picture in Picture"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
        })
    }
    @objc func openVideoDemo(_ sender: Any?) {
        cancelPaging(); session.add(address: "orbit://video", title: "Picture in Picture demo"); showActive(); save()
    }
    func returnActiveVideo() { if let web = activeWebView, pictureInPicture.references(web) { pictureInPicture.restore() } }
    @objc func toggleSidebar(_ sender: Any?) { setSidebar(!session.sidebarVisible) }
    @objc func resetSidebar(_ sender: Any?) {
        session.sidebarWidth = 228; setSidebar(true)
    }
    @objc func newTab(_ sender: Any?) { cancelPaging(); openAddress(newTab: true, empty: true) }
    @objc func closeTab(_ sender: Any?) {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { little.close(); return }
        if let peek = peeks[session.activeID], peek.isPresented { peek.dismiss(); return }
        if pictureInPicture.activeTabID != nil, view.window?.isKeyWindow == false { pictureInPicture.restore(); return }
        close(session.activeID)
    }
    @objc func reopenTab(_ sender: Any?) { if let record = library.popClosed() { restoreClosed(record) } }
    @objc func togglePin(_ sender: Any?) { pinTab(session.activeID) }
    @objc func goBack(_ sender: Any?) { returnActiveVideo(); commandWebView?.goBack() }
    @objc func goForward(_ sender: Any?) { returnActiveVideo(); commandWebView?.goForward() }
    @objc func reload(_ sender: Any?) {
        if let web = commandWebView, web !== activeWebView {
            if web.isLoading { web.stopLoading() }
            else if web.url == nil, let url = (web as? PreviewWKWebView)?.requestedURL { web.load(URLRequest(url: url)) }
            else { web.reload() }
            return
        }
        returnActiveVideo()
        if activeWebView?.isLoading == true { activeWebView?.stopLoading(); pendingLoads.remove(focusedTabID) }
        else if tabErrors[focusedTabID] != nil, let address = requestedAddresses[focusedTabID] { navigate(address) }
        else { activeWebView?.reload() }
    }
    @objc func focusAddress(_ sender: Any?) {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { little.focusAddress(); return }
        peeks[session.activeID]?.dismiss()
        if let split = splitCoordinators[session.activeID], session.split(for: session.activeID) != nil { split.focusAddress(split.focusedSide) }
        else { openAddress(newTab: false, empty: session.active?.isHome ?? true) }
    }
    @objc func nextTab(_ sender: Any?) { cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(-1) }
    func cycleTab(_ delta: Int) {
        let tabs = session.visibleTabs; guard let i = tabs.firstIndex(where: { $0.id == session.activeID }), !tabs.isEmpty else { return }
        select(tabs[(i + delta + tabs.count) % tabs.count].id)
    }
    @objc func zoomIn(_ sender: Any?) { if let web = commandWebView { web.pageZoom = min(3, web.pageZoom + 0.1) } }
    @objc func zoomOut(_ sender: Any?) { if let web = commandWebView { web.pageZoom = max(0.4, web.pageZoom - 0.1) } }
    @objc func actualSize(_ sender: Any?) { commandWebView?.pageZoom = 1 }
    @objc func showHome(_ sender: Any?) { navigate("orbit://newtab") }
    func navigate(_ address: String) {
        peeks[session.activeID]?.dismiss()
        returnActiveVideo()
        let id = focusedTabID
        guard let i = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[i].address = address; session.tabs[i].title = address == "orbit://newtab" ? "New tab" : (address == "orbit://video" ? "Picture in Picture demo" : URL(string: address)?.host ?? address)
        let browser = webView(for: session.tabs[i]); load(address, in: browser, id: id)
        dismissAddress(); refresh(); save()
    }
    func scheduleSave() {
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.save() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func save() {
        guard !privateMode else { return }
        do { try SessionFile.save(session, to: sessionURL) } catch { NSLog("Session save: %@", error.localizedDescription) }
    }

    func openAddress(newTab: Bool, empty: Bool) {
        cancelPaging(); dismissAddress(); view.window?.makeKeyAndOrderFront(nil); newTabOnSubmit = newTab
        let overlay = DismissView(); overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        overlay.dismiss = { [weak self] in self?.dismissAddress() }
        let box = FlippedContainer(); box.wantsLayer = true
        box.appearance = NSAppearance(named: .aqua)
        box.layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.98, blue: 0.97, alpha: 1).cgColor
        box.layer?.cornerRadius = 18; box.layer?.shadowOpacity = 0.20; box.layer?.shadowRadius = 30; box.layer?.shadowOffset = CGSize(width: 0, height: -8)
        let heading = NSTextField(labelWithString: "Where would you like to go?")
        heading.font = .systemFont(ofSize: 12, weight: .medium); heading.textColor = .secondaryLabelColor
        heading.frame = NSRect(x: 26, y: 23, width: 400, height: 18); box.addSubview(heading)
        let field = PaletteField(); field.font = .systemFont(ofSize: 23, weight: .regular)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.placeholderString = "Search or enter a URL"; field.stringValue = empty ? "" : session.active?.address ?? ""
        field.target = self; field.action = #selector(submitAddress); field.delegate = self
        field.escape = { [weak self] in self?.dismissAddress() }; field.setAccessibilityLabel("Search or enter URL")
        box.addSubview(field)
        let line = NSBox(); line.boxType = .separator; line.frame = NSRect(x: 24, y: 108, width: 530, height: 1); line.autoresizingMask = [.width]; box.addSubview(line)
        let shortcuts = NSTextField(labelWithString: "↑↓ Choose     ↵ Open or switch     Esc Cancel")
        shortcuts.font = .systemFont(ofSize: 11); shortcuts.textColor = .tertiaryLabelColor; shortcuts.frame = NSRect(x: 26, y: 183, width: 500, height: 18); box.addSubview(shortcuts)
        let results = TabSearchResultsView(frame: .zero)
        results.onSelect = { [weak self] id in self?.selectSearchResult(id) }
        results.onSubmitQuery = { [weak self] query in self?.submitAddressQuery(query) }
        box.addSubview(results)
        overlay.addSubview(box); root.addSubview(overlay)
        addressOverlay = overlay; addressField = field; addressCard = box; tabSearchResults = results; paletteShortcuts = shortcuts
        refreshPaletteResults(); layoutBrowser()
        box.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12; box.animator().alphaValue = 1 }
        view.window?.makeFirstResponder(field); field.selectText(nil)
    }
    @objc func submitAddress(_ sender: Any?) {
        if tabSearchResults?.activateSelection() == true { return }
        submitAddressQuery(addressField?.stringValue ?? "")
    }
    func submitAddressQuery(_ query: String) {
        guard let address = URLInput.resolve(query) else { NSSound.beep(); return }
        if newTabOnSubmit { session.add(address: address); dismissAddress(); showActive(); save() }
        else { navigate(address) }
    }
    func refreshPaletteResults() {
        guard let field = addressField else { return }
        tabSearchResults?.update(tabs: session.tabs, query: field.stringValue, activeID: focusedTabID, canCreate: true)
        layoutBrowser()
    }
    func selectSearchResult(_ id: UUID) {
        select(id)
        if let group = session.split(for: id), let split = splitCoordinators[group.primaryID] {
            split.setFocusedSide(id == group.secondaryID ? .right : .left)
        }
        view.window?.makeFirstResponder(commandWebView)
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as AnyObject? === addressField { refreshPaletteResults() } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismissAddress(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { tabSearchResults?.moveSelection(delta: 1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { tabSearchResults?.moveSelection(delta: -1); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submitAddress(control); return true }
        return false
    }
    func dismissAddress() {
        addressOverlay?.removeFromSuperview(); addressOverlay = nil; addressField = nil; addressCard = nil; tabSearchResults = nil; paletteShortcuts = nil
        view.window?.makeFirstResponder(commandWebView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let id = browsers.first(where: { $0.value === webView })?.key { tabErrors.removeValue(forKey: id); pendingLoads.insert(id) }
        refresh()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let id = browsers.first(where: { $0.value === webView })?.key { pendingLoads.remove(id) }
        updateMetadata(webView)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = browsers.first(where: { $0.value === webView })?.key { tabErrors.removeValue(forKey: id); pendingLoads.remove(id) }
        updateMetadata(webView)
        if let url = webView.url { library.recordVisit(title: webView.title ?? url.host ?? "Page", address: url.absoluteString) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error, web: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error, web: webView) }
    func showError(_ error: Error, web: WKWebView) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if let id = browsers.first(where: { $0.value === web })?.key {
            pendingLoads.remove(id)
            if let failed = (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String, URLInput.directURL(failed) != nil { requestedAddresses[id] = failed }
            tabErrors[id] = "Couldn’t load page — ⌘R to retry"; refresh()
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if pictureInPicture.owns(webView) { pictureInPicture.restore() }; webView.reload() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload, ["http", "https", "blob", "data"].contains(scheme) { decisionHandler(.download); return }
        if scheme == "orbit", url.host == "newtab" { decisionHandler(.cancel); navigate("orbit://newtab"); return }
        if scheme == "file" {
            guard let resources = Bundle.main.resourceURL, url.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/") else { decisionHandler(.cancel); return }
        } else if !["http", "https", "about"].contains(scheme) { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated, let address = URLInput.directURL(url.absoluteString) {
            let modifiers = navigationAction.modifierFlags
            if modifiers.contains([.command, .option]) { openLittleOrbit(url: address); decisionHandler(.cancel); return }
            if modifiers.contains(.command) {
                let previous = session.activeID
                let id = session.add(address: address.absoluteString)
                if modifiers.contains(.shift) { select(id) }
                else { session.select(previous); if let tab = session.tabs.first(where: { $0.id == id }) { _ = self.webView(for: tab) }; refresh(); save() }
                decisionHandler(.cancel); return
            }
            let crossesPinnedOrigin = session.active?.pinned == true && address.host?.lowercased() != webView.url?.host?.lowercased()
            if activeWebView === webView && (modifiers.contains(.shift) || crossesPinnedOrigin) {
                openPeek(address); decisionHandler(.cancel); return
            }
        }
        if navigationAction.targetFrame?.isMainFrame == true, let id = browsers.first(where: { $0.value === webView })?.key {
            requestedAddresses[id] = scheme == "file" ? (url.lastPathComponent == "PiPDemo.html" ? "orbit://video" : "orbit://newtab") : url.absoluteString
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, let safe = URLInput.directURL(url.absoluteString) { let id = session.add(address: safe.absoluteString); select(id) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page message"; alert.informativeText = message; alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window) { _ in completionHandler() } } else { completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page confirmation"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        if let window = view.window { alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) } } else { completionHandler(false) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt; let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); input.stringValue = defaultText ?? ""; alert.accessoryView = input; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        if let window = view.window { alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) } } else { completionHandler(nil) }
    }
}

@MainActor final class PiPPlaceholder: NSView {
    var returnVideo: (() -> Void)?
    private let title = NSTextField(labelWithString: "Playing in Picture in Picture")
    private let button = NSButton(title: "Return video to tab", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        title.textColor = .white; title.font = .systemFont(ofSize: 20, weight: .medium); title.alignment = .center
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(returnClicked)
        addSubview(title); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); title.frame = NSRect(x: 20, y: bounds.midY-36, width: bounds.width-40, height: 30); button.frame = NSRect(x: bounds.midX-95, y: bounds.midY+10, width: 190, height: 32) }
    @objc func returnClicked() { returnVideo?() }
}
