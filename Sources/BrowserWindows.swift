import AppKit
import WebKit

// More than one normal window (File ▸ New Window, ⌘N), as in Arc: every window shows the same
// Spaces, Favorites, kept and Today tabs, and each has its own current Space, selected tab and
// sidebar. Model:
// - The main browser owns the session file, history, favicons, downloads and website data. A
//   second window is another BrowserController that borrows them (`primaryBrowser`).
// - Every window keeps a full copy of the session. Each change copies the shared part (tabs,
//   Spaces, folders, splits, profiles) into the other windows, keeping their own selection and
//   sidebar. Tabs exist once, in that shared list, which only the main browser writes to disk,
//   so a window can never lose or duplicate a tab.
// - A tab's page lives in one window at a time. Choosing it in another window moves the live
//   page there; the window it left says so and offers to bring it back.
// - Extensions run in the main window only for now.

/// The normal windows showing one profile's session.
@MainActor final class BrowserWindowGroup {
    private var members: [Weak] = []
    private struct Weak { weak var value: BrowserController? }
    private var isSharing = false
    private var isReconciling = false
    private var pending: Set<ObjectIdentifier> = []
    private var flushScheduled = false
    private var spacesChanged = false

    var browsers: [BrowserController] { members.compactMap(\.value).filter { !$0.isShuttingDown } }
    func add(_ browser: BrowserController) {
        members.removeAll { $0.value == nil || $0.value === browser }
        members.append(Weak(value: browser)); browser.windowGroup = self
    }
    func remove(_ browser: BrowserController) {
        members.removeAll { $0.value == nil || $0.value === browser }
        if browser.windowGroup === self { browser.windowGroup = nil }
    }
    /// The window whose page view currently holds this tab, other than `excluding`.
    func owner(of id: UUID, excluding: BrowserController) -> BrowserController? {
        browsers.first { $0 !== excluding && $0.browsers[id] != nil }
    }
    /// Copies `source`'s shared session content into every other window, then lets them catch up.
    func share(from source: BrowserController) {
        guard !isSharing else { return }
        let others = browsers.filter { $0 !== source }
        guard !others.isEmpty else { return }
        isSharing = true
        for other in others {
            if other.session.spaces != source.session.spaces { spacesChanged = true }
            other.session = source.session.sharing(windowStateOf: other.session)
            // Changes a window makes while catching up need no further round.
            if !isReconciling { pending.insert(ObjectIdentifier(other)) }
        }
        isSharing = false
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }
    private func flush() {
        flushScheduled = false
        let due = pending; pending.removeAll()
        let spaces = spacesChanged; spacesChanged = false
        isReconciling = true
        for browser in browsers where due.contains(ObjectIdentifier(browser)) {
            browser.sessionChangedElsewhere()
            // The Spaces menu and an open Settings window follow Spaces made or edited in another window.
            if spaces, browser.primaryBrowser == nil { browser.onSpacesChanged?() }
        }
        isReconciling = false
    }
}

extension BrowserController {
    /// True for a second normal window and private windows: no extension runtime of their own.
    var extensionsOff: Bool { privateMode || primaryBrowser != nil }

    /// Where Little Bam's "Open in Space" lands: the frontmost normal window.
    static var frontmostNormalBrowser: (() -> BrowserController?)?
    var promotionTarget: BrowserController {
        guard !isPrivateWindow, let front = Self.frontmostNormalBrowser?(), front.windowGroup === windowGroup else { return self }
        return front
    }

    func shareSessionWithOtherWindows() { windowGroup?.share(from: self) }

    /// Every normal window over this session, this one included (just this one when it is alone).
    var sessionWindows: [BrowserController] {
        guard let all = windowGroup?.browsers, !all.isEmpty else { return [self] }
        return all.contains { $0 === self } ? all : [self] + all
    }
    /// Open on screen or in the Dock; false for a main window closed while another stays open.
    var isWindowOpen: Bool {
        guard let window = viewIfLoaded?.window else { return false }
        return window.isVisible || window.isMiniaturized
    }
    /// The windows whose shown tabs count as viewed. Alone, this window always counts (as before
    /// there were more windows); otherwise only the ones open.
    var viewingWindows: [BrowserController] {
        let windows = sessionWindows
        return windows.count == 1 ? windows : windows.filter(\.isWindowOpen)
    }
    /// The tabs on screen in any window (both sides of a Split).
    var viewedMemberIDs: [UUID] { viewingWindows.flatMap(\.visibleMemberIDs) }
    /// A tab's page, in whichever window holds it.
    func livePage(_ id: UUID) -> WKWebView? { sessionWindows.lazy.compactMap { $0.browsers[id] }.first }
    /// No window is mid-swipe, paging Spaces or showing a sheet: auto-archive can close tabs.
    var archiveCanProceed: Bool {
        sessionWindows.allSatisfy { window in
            window.viewIfLoaded?.window?.attachedSheet == nil && !window.trackingSwipe && window.pagingOffset == 0 && window.pagingTarget == nil
        }
    }

    /// Another window changed the shared tabs or Spaces: drop pages of tabs closed there (a kept tab
    /// closed there is unloaded, a tab moved to another profile needs that profile's website data),
    /// keep this window's selection valid, and redraw.
    func sessionChangedElsewhere() {
        guard isViewLoaded, !isShuttingDown else { return }
        let live = Dictionary(session.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var retired = false
        for (id, web) in Array(browsers) {
            if let tab = live[id], !tab.isUnloaded,
               profileStores.profileID(for: web.configuration.websiteDataStore).map({ $0 == session.profileID(for: tab) }) ?? true { continue }
            if let group = session.split(for: id), let split = splitCoordinators.removeValue(forKey: group.primaryID) {
                split.detach(); split.view.removeFromSuperview()
            }
            teardownPage(id); retired = true
        }
        let groups = Set((session.splits ?? []).map(\.primaryID))
        for (primary, split) in splitCoordinators where !groups.contains(primary) {
            split.detach(); split.view.removeFromSuperview(); splitCoordinators.removeValue(forKey: primary)
        }
        var repaired = session; repaired.repairWindowSelection()
        if repaired.activeID != session.activeID || repaired.space != session.space || repaired.tabs.count != session.tabs.count {
            session = repaired
        }
        // A main window closed while others stay open keeps no pages; it shows its tab again when it comes back.
        if primaryBrowser == nil, !isWindowOpen, sessionWindows.count > 1 { return }
        if retired || displayedTabID != session.activeID || webHost.subviews.contains(where: { $0 is PageElsewhereView }) { showActive() }
        else { refresh() }
    }

    /// A tab live in another window: that window gives up the page (still loaded, scrolled and
    /// playing) and it is registered here.
    func takePageFromOtherWindow(_ id: UUID) -> WKWebView? {
        guard let group = windowGroup, let other = group.owner(of: id, excluding: self), let web = other.handOverPage(id) else { return nil }
        register(web, id: id)
        if web.isLoading { pendingLoads.insert(id) }
        return web
    }
    /// Releases this tab's page view to another window without stopping it.
    func handOverPage(_ id: UUID) -> WKWebView? {
        guard let web = browsers[id] else { return nil }
        if pictureInPicture.references(web) { pictureInPicture.restore() }
        peeks[id]?.dismiss()
        if let group = session.split(for: id), let split = splitCoordinators.removeValue(forKey: group.primaryID) {
            split.detach(); split.view.removeFromSuperview(); retiringViews.removeValue(forKey: ObjectIdentifier(split.view))
        }
        invalidateFaviconDocument(id); historyTitleFollowUps.removeValue(forKey: id)
        observations.removeValue(forKey: id); browsers.removeValue(forKey: id)
        tabActivityProbe.invalidate(web)
        web.navigationDelegate = nil; web.uiDelegate = nil
        retiringViews.removeValue(forKey: ObjectIdentifier(web)); web.removeFromSuperview()
        tabLastUsed.removeValue(forKey: id); sleepRestores.removeValue(forKey: id); nonGetDocuments.remove(id); pendingNonGetDocuments.removeValue(forKey: id)
        navigationTokens.removeValue(forKey: id); browserExtensionOrigins.removeValue(forKey: id)
        pendingHome.remove(id); tabErrors.removeValue(forKey: id); pendingLoads.remove(id); requestedAddresses.removeValue(forKey: id)
        if displayedMemberIDs.contains(id) || displayedTabID == id {
            DispatchQueue.main.async { [weak self] in self?.showActive() }
        }
        return web
    }
    /// The stand-in shown when this window's selected tab is open in another window. Nil when this
    /// window is in front: choosing a tab here takes its page.
    func pageShownElsewhere(_ ids: [UUID]) -> NSView? {
        guard let group = windowGroup, view.window?.isKeyWindow != true,
              ids.contains(where: { group.owner(of: $0, excluding: self) != nil }) else { return nil }
        let placeholder = PageElsewhereView(frame: webHost.bounds)
        placeholder.onShowHere = { [weak self] in
            guard let self else { return }
            self.view.window?.makeKeyAndOrderFront(nil); self.showActive()
        }
        return placeholder
    }

    /// The main window was closed while another window stays open: its pages stop (no sound from a
    /// hidden window) and its tabs stay. They load again when the window comes back.
    func releasePagesWhileHidden() {
        guard primaryBrowser == nil, !isShuttingDown else { return }
        dismissAddress(); findBar.hide(); pictureInPicture.restore()
        for peek in Array(peeks.values) { peek.dismiss() }
        for split in splitCoordinators.values { split.detach(); split.view.removeFromSuperview() }
        splitCoordinators.removeAll()
        for id in Array(browsers.keys) { teardownPage(id) }
        displayedTabID = nil; displayedMemberIDs = []
    }
    /// Stops this second window's own work without touching what it shares with the main browser
    /// (downloads, favicons, history, website data). Its tabs stay in the shared session.
    func closeAsSecondaryWindow() {
        guard primaryBrowser != nil, !isShuttingDown else { return }
        dismissAddress(); findBar.hide(); pageFeedback.hide(); pictureInPicture.restore()
        stopTabResourceMonitoring(); cancelAutomaticDepartures(); cancelPaging(); animator.stop()
        for peek in Array(peeks.values) { peek.dismiss() }
        for split in splitCoordinators.values { split.detach(); split.view.removeFromSuperview() }
        splitCoordinators.removeAll()
        for id in Array(browsers.keys) { teardownPage(id) }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor); scrollMonitor = nil }
        let others = windowGroup?.browsers.filter { $0 !== self } ?? []
        windowGroup?.remove(self)
        isShuttingDown = true
        // A window that showed "open in another window" for one of these tabs can show it again.
        DispatchQueue.main.async { others.forEach { $0.sessionChangedElsewhere() } }
    }
}

/// "Open in another window", with a button to bring the page here.
@MainActor final class PageElsewhereView: NSView {
    var onShowHere: (() -> Void)?
    private let title = NSTextField(labelWithString: "This tab is open in another window")
    private let button = NSButton(title: "Show Here", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
        title.textColor = .secondaryLabelColor; title.font = .systemFont(ofSize: 15, weight: .medium); title.alignment = .center
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(showHere)
        addSubview(title); addSubview(button)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 20, y: bounds.midY - 34, width: bounds.width - 40, height: 22)
        button.frame = NSRect(x: bounds.midX - 60, y: bounds.midY, width: 120, height: 32)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
    }
    @objc private func showHere() { onShowHere?() }
}

/// What a second window remembers across relaunch: where it was and what it showed. Its tabs
/// are in the session file like every other tab.
struct BrowserWindowState: Codable, Equatable {
    var frame: String
    var space: Int
    var activeID: UUID
    var lastSelectedTabIDsBySpace: [Int: UUID]?
    var sidebarWidth: Double
    var sidebarVisible: Bool

    static func load(_ url: URL) -> [BrowserWindowState] {
        guard let data = try? Data(contentsOf: url), let states = try? JSONDecoder().decode([BrowserWindowState].self, from: data) else { return [] }
        return Array(states.prefix(16))
    }
    static func save(_ states: [BrowserWindowState], to url: URL) {
        if states.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// One second normal window and its controller.
@MainActor final class SecondaryWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let controller: BrowserController
    var onClose: ((SecondaryWindowController) -> Void)?

    /// `state` restores a window from the last run; otherwise it opens on `like`'s Space with a new tab.
    init(primary: BrowserController, group: BrowserWindowGroup, state: BrowserWindowState?, like reference: BrowserController?, frame: NSRect?) {
        controller = BrowserController(sessionURL: primary.sessionURL, sharing: primary)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        var session = controller.session
        if let state {
            session.space = state.space; session.activeID = state.activeID
            session.lastSelectedTabIDsBySpace = state.lastSelectedTabIDsBySpace
            session.sidebarWidth = state.sidebarWidth; session.sidebarVisible = state.sidebarVisible
        } else if let reference {
            session = session.sharing(windowStateOf: reference.session)
        }
        session.repairWindowSelection()
        // Join first: a tab the repair had to add (every Space empty) reaches the other windows too.
        group.add(controller)
        controller.session = session
        if state == nil {
            // Arc opens a new window on the same Space with nothing chosen yet: a new tab under the command bar.
            _ = controller.session.add(address: "orbit://newtab")
        }
        window.title = "Bam"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false; window.minSize = NSSize(width: 760, height: 540)
        window.backgroundColor = BrowserChrome.windowBackground
        window.contentViewController = controller
        window.delegate = self
        if let saved = state.map({ NSRectFromString($0.frame) }), saved.width >= 400, saved.height >= 300,
           Self.titleBarReachable(saved) {
            window.setFrame(saved, display: false)
        } else if let frame {
            // Arc opens the new window exactly over the one you were in.
            window.setFrame(frame, display: false)
        } else { window.center() }
    }

    /// A saved frame is used only if enough of its title bar is still on a display to drag it
    /// (displays get unplugged or rearranged between runs).
    static func titleBarReachable(_ frame: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> Bool {
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        return screens.contains { screen in
            let overlap = screen.intersection(titleBar)
            return overlap.width >= 120 && overlap.height >= 8
        }
    }

    var state: BrowserWindowState {
        let session = controller.session
        return BrowserWindowState(frame: NSStringFromRect(window.frame), space: session.space, activeID: session.activeID,
                                  lastSelectedTabIDsBySpace: session.lastSelectedTabIDsBySpace,
                                  sidebarWidth: session.sidebarWidth, sidebarVisible: session.sidebarVisible)
    }

    func show(openingPalette: Bool) {
        window.makeKeyAndOrderFront(nil)
        if openingPalette { controller.openAddress(newTab: false, empty: true) }
    }

    func windowWillClose(_ notification: Notification) {
        controller.closeAsSecondaryWindow()
        window.contentViewController = nil
        window.delegate = nil
        onClose?(self)
    }
}
