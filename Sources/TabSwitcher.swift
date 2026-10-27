import AppKit
import WebKit

/// Per-window tab navigation state: the ⌃⇥ switcher, page thumbnails it
/// shows, and the key monitors for the switcher and ⌘Z.
@MainActor final class TabNavigationState {
    struct Switcher {
        var items: [UUID]
        var index: Int
        var view: TabSwitcherView?
        var reveal: DispatchWorkItem?
    }
    var switcher: Switcher?
    /// Last rendered picture of each tab's page, taken as you leave it.
    var thumbnails: [UUID: NSImage] = [:]
    var monitors: [Any] = []
    var resignObserver: NSObjectProtocol?
    /// Set while a ⌘Z that belongs to the page is sent through again.
    var replayingUndo = false
    /// Tabs (Split primaries) the user muted; reapplied to pages created later.
    var mutedTabs: Set<UUID> = []
    /// A tab waiting for the Space being created ("Move to ▸ New Space…").
    var pendingMoveToNewSpace: UUID?
    /// Capture (⇧⌘2), PageCapture.swift.
    lazy var capture = PageCaptureCoordinator()
    /// The hovered-link address at the page's corner (LinkStatus.swift).
    lazy var linkStatus = LinkStatusController()
    /// A quick ⌃⇥ tap lands without the overlay ever drawing.
    static let revealDelay: TimeInterval = 0.09
    static let maximumTiles = 5
    static let thumbnailLimit = 48
}

@MainActor extension BrowserController {
    // MARK: Setup

    func installTabNavigation() {
        guard tabNavigation.monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleTabNavigationKey(event) ?? event
        }) { tabNavigation.monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleTabNavigationFlags(event); return event
        }) { tabNavigation.monitors.append(monitor) }
        if let window = view.window {
            tabNavigation.resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelTabSwitcher() }
            }
        }
    }

    /// Called whenever a tab comes on screen: remembers it for ⌃⇥ and keeps a
    /// picture of the page being left.
    func noteTabShown(_ id: UUID, leaving previous: UUID?) {
        if let previous, previous != id { captureThumbnail(previous); tabNavigation.linkStatus.hide(immediately: true) }
        let primary = session.split(for: id)?.primaryID ?? id
        if session.recentTabIDs?.first != primary { session.noteRecent(primary) }
    }

    func captureThumbnail(_ id: UUID, completion: (() -> Void)? = nil) {
        guard let web = browsers[id], web.window != nil, web.bounds.width > 40, web.bounds.height > 40 else { completion?(); return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(TabSwitcherView.thumbnailSize.width * 2))
        configuration.afterScreenUpdates = false
        web.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let image {
                    if self.tabNavigation.thumbnails.count >= TabNavigationState.thumbnailLimit {
                        let live = Set(self.session.recentTabIDs?.prefix(TabNavigationState.thumbnailLimit / 2) ?? [])
                        self.tabNavigation.thumbnails = self.tabNavigation.thumbnails.filter { live.contains($0.key) }
                    }
                    self.tabNavigation.thumbnails[id] = image
                    self.tabNavigation.switcher?.view?.updateThumbnail(image, for: id)
                }
                completion?()
            }
        }
    }

    // MARK: ⌃⇥ recent-tab switcher

    @objc func nextTab(_ sender: Any?) { stepTabSwitcher(1) }
    @objc func previousTab(_ sender: Any?) { stepTabSwitcher(-1) }

    /// Visual-order cycling, kept for callers that want the sidebar's order.
    func cycleTab(_ delta: Int) {
        let tabs = session.visibleTabs; guard let i = tabs.firstIndex(where: { $0.id == session.activeID }), !tabs.isEmpty else { return }
        select(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    var isTabSwitcherActive: Bool { tabNavigation.switcher != nil }

    /// The first ⌃⇥ opens a session on the previous tab; each further ⇥ (⇧⇥
    /// back) moves along, wrapping. Releasing ⌃ lands; a press without ⌃
    /// held (the menu, a click) lands at once.
    func stepTabSwitcher(_ delta: Int) {
        if littleWindows.values.contains(where: { $0.window?.isKeyWindow == true }) { return }
        if tabNavigation.switcher == nil {
            cancelPaging(); dismissAddress()
            let items = session.recentSwitcherTabs(limit: TabNavigationState.maximumTiles)
            guard items.count > 1 else { NSSound.beep(); return }
            tabNavigation.switcher = .init(items: items, index: 0)
            captureThumbnail(session.activeID)
            let reveal = DispatchWorkItem { [weak self] in self?.revealTabSwitcher() }
            tabNavigation.switcher?.reveal = reveal
            DispatchQueue.main.asyncAfter(deadline: .now() + TabNavigationState.revealDelay, execute: reveal)
        }
        guard var state = tabNavigation.switcher else { return }
        state.index = (state.index + delta % state.items.count + state.items.count) % state.items.count
        tabNavigation.switcher = state
        state.view?.select(state.index)
        if !NSEvent.modifierFlags.contains(.control) { commitTabSwitcher() }
    }

    private func revealTabSwitcher() {
        guard var state = tabNavigation.switcher, state.view == nil, let content = view.window?.contentView else { return }
        let tiles = state.items.compactMap { id -> TabSwitcherView.Tile? in
            guard let tab = session.tabs.first(where: { $0.id == id }) else { return nil }
            let companion = session.split(for: id).flatMap { group in session.tabs.first { $0.id == group.secondaryID } }
            let title = companion.map { "\(tab.displayTitle) · \($0.displayTitle)" } ?? tab.displayTitle
            // Same mark as the sidebar row: favicon, else the page's monogram, else its symbol.
            let tint = session.spaceDefinition(session.space).map { ArkPalette.spaceTint(for: $0) } ?? ArkPalette.spaceTint(0)
            let icon = favicon(forTabID: id) ?? tab.monogram.map { ArkMonogram.image($0, tint: tint, side: 16) }
            return .init(id: id, title: title.isEmpty ? tab.addressLabel : title, favicon: icon,
                         symbol: tab.symbol, thumbnail: tabNavigation.thumbnails[id])
        }
        guard tiles.count == state.items.count else { cancelTabSwitcher(); return }
        let tint = session.spaceDefinition(session.space).map { ArkPalette.spaceTint(for: $0) } ?? ArkPalette.spaceTint(0)
        let overlay = TabSwitcherView(tiles: tiles, tint: tint)
        overlay.onHover = { [weak self] index in
            guard let self, var current = self.tabNavigation.switcher else { return }
            current.index = index; self.tabNavigation.switcher = current; current.view?.select(index)
        }
        overlay.onChoose = { [weak self] index in
            guard let self, var current = self.tabNavigation.switcher else { return }
            current.index = index; self.tabNavigation.switcher = current; self.commitTabSwitcher()
        }
        overlay.select(state.index)
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        state.view = overlay
        tabNavigation.switcher = state
        NSAccessibility.post(element: overlay, notification: .created)
    }

    func commitTabSwitcher() {
        guard let state = tabNavigation.switcher else { return }
        let target = state.items[state.index]
        closeTabSwitcherOverlay()
        if target != session.activeID, session.tabs.contains(where: { $0.id == target }) { select(target) }
    }

    func cancelTabSwitcher() { closeTabSwitcherOverlay() }

    private func closeTabSwitcherOverlay() {
        guard let state = tabNavigation.switcher else { return }
        state.reveal?.cancel()
        state.view?.removeFromSuperview()
        tabNavigation.switcher = nil
    }

    // MARK: ⌘1–⌘9

    /// ⌘1–⌘8 go to that tab in the sidebar's order (Favorites first), ⌘9 to the last.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        if littleWindows.values.contains(where: { $0.window?.isKeyWindow == true }) { return }
        guard let id = session.shortcutTab(number) else { return }
        if id != session.activeID { select(id) } else { dismissAddress() }
    }

    // MARK: Keys

    private func handleTabNavigationFlags(_ event: NSEvent) {
        guard tabNavigation.switcher != nil, event.window === view.window || event.window == nil else { return }
        if !event.modifierFlags.contains(.control) { commitTabSwitcher() }
    }

    private func handleTabNavigationKey(_ event: NSEvent) -> NSEvent? {
        if tabNavigation.switcher != nil {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch event.keyCode {
            case 53: cancelTabSwitcher(); return nil                                   // Esc
            case 48 where flags.contains(.control): stepTabSwitcher(flags.contains(.shift) ? -1 : 1); return nil   // ⇥
            case 123: stepTabSwitcher(-1); return nil                                  // ←
            case 124: stepTabSwitcher(1); return nil                                   // →
            case 36, 76: commitTabSwitcher(); return nil                               // Return
            default: return nil
            }
        }
        // ⌃⇥ / ⌃⇧⇥ start here too: a focused page would otherwise take the key
        // before the Tabs menu sees it.
        if event.keyCode == 48, let window = view.window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
           event.modifierFlags.intersection([.command, .control, .option]) == .control {
            stepTabSwitcher(event.modifierFlags.contains(.shift) ? -1 : 1); return nil
        }
        return handleReopenShortcut(event)
    }

    /// ⌘Z outside a text field reopens the last closed tab, as ⇧⌘T does. In a
    /// native or page text field it stays Undo.
    private func handleReopenShortcut(_ event: NSEvent) -> NSEvent? {
        guard !tabNavigation.replayingUndo, event.keyCode == 6,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let window = view.window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, addressOverlay == nil else { return event }
        let responder = window.firstResponder
        if responder is NSText || responder is NSTextField { return event }
        guard let web = (responder as? NSView).flatMap(enclosingWebView) else {
            if window.undoManager?.canUndo == true { return event }
            reopenTab(nil); return nil
        }
        // Whether the page is editing is only known asynchronously; hold the
        // key, ask, then either reopen or hand the very same ⌘Z back to AppKit.
        let script = """
        (() => { let e = document.activeElement; while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
          if (!e || e === document.body || e === document.documentElement) return document.designMode === 'on';
          return e.isContentEditable || /^(INPUT|TEXTAREA|SELECT|IFRAME|EMBED|OBJECT)$/.test(e.tagName); })()
        """
        web.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (result as? Bool) == false { self.reopenTab(nil); return }
                self.tabNavigation.replayingUndo = true
                NSApp.sendEvent(event)
                self.tabNavigation.replayingUndo = false
            }
        }
        return nil
    }

    private func enclosingWebView(_ view: NSView) -> WKWebView? {
        var current: NSView? = view
        while let candidate = current {
            if let web = candidate as? WKWebView { return web }
            current = candidate.superview
        }
        return nil
    }
}

/// The ⌃⇥ overlay: a dark strip of up to five recent tabs, centered in the
/// window. Each tile is a page picture over the tab's icon and title; the
/// chosen one sits on a Space-tinted plate. Shown and hidden without motion,
/// as Arc does, so it needs nothing extra for Reduce Motion.
@MainActor final class TabSwitcherView: NSView {
    struct Tile { let id: UUID; let title: String; let favicon: NSImage?; let symbol: String; let thumbnail: NSImage? }

    static let tileSize = NSSize(width: 180, height: 155)
    static let thumbnailSize = NSSize(width: 156, height: 104)
    static let padding: CGFloat = 15
    static let panelRadius: CGFloat = 20
    static let plateRadius: CGFloat = 8
    static let thumbnailRadius: CGFloat = 6

    var onHover: ((Int) -> Void)?
    var onChoose: ((Int) -> Void)?
    private let tiles: [Tile]
    private let tint: NSColor
    private let panel = Flipped()
    private var plates: [Flipped] = []
    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    private var pictures: [NSView] = []
    private var placeholders: [NSImageView] = []
    private var titles: [NSTextField] = []
    private var selected = 0
    private var lastHoverPoint: NSPoint?

    override var isFlipped: Bool { true }

    init(tiles: [Tile], tint: NSColor) {
        self.tiles = tiles; self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        panel.wantsLayer = true
        panel.layer?.cornerRadius = Self.panelRadius
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        panel.shadow = { let s = NSShadow(); s.shadowBlurRadius = 24; s.shadowOffset = NSSize(width: 0, height: -6); s.shadowColor = NSColor.black.withAlphaComponent(0.22); return s }()
        addSubview(panel)
        for (index, tile) in tiles.enumerated() {
            let plate = Flipped(); plate.wantsLayer = true
            plate.layer?.cornerRadius = Self.plateRadius; plate.layer?.cornerCurve = .continuous
            panel.addSubview(plate); plates.append(plate)
            let picture = NSView(); picture.wantsLayer = true
            picture.layer?.contentsGravity = .resizeAspectFill
            picture.layer?.cornerRadius = Self.thumbnailRadius; picture.layer?.cornerCurve = .continuous
            picture.layer?.masksToBounds = true
            picture.layer?.borderWidth = 0.5
            plate.addSubview(picture); pictures.append(picture)
            let placeholder = NSImageView(); placeholder.imageScaling = .scaleProportionallyUpOrDown
            placeholder.image = tile.favicon ?? NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil)
            picture.addSubview(placeholder); placeholders.append(placeholder)
            let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
            icon.image = tile.favicon ?? NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil)
            icon.frame = NSRect(x: 12, y: 130, width: 16, height: 16)
            icon.identifier = NSUserInterfaceItemIdentifier("icon")
            plate.addSubview(icon)
            let label = NSTextField(labelWithString: tile.title)
            label.font = .systemFont(ofSize: 16, weight: .medium)
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
            label.frame = NSRect(x: 36, y: 128, width: Self.tileSize.width - 36 - 12, height: 20)
            plate.addSubview(label); titles.append(label)
            plate.setAccessibilityElement(true); plate.setAccessibilityRole(.button)
            plate.setAccessibilityLabel(tile.title)
            plate.setAccessibilityIdentifier("tab-switcher-tile-\(index)")
            setPicture(tile.thumbnail, at: index)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recent tabs")
        setAccessibilityIdentifier("tab-switcher")
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedIndex: Int { selected }
    var tileIDs: [UUID] { tiles.map(\.id) }

    func select(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        selected = index
        applyColors()
        setAccessibilityValue(tiles[index].title)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func updateThumbnail(_ image: NSImage, for id: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        setPicture(image, at: index)
    }

    /// The page's picture fills the frame (cropped, never squashed). Without
    /// one (a tab not shown since launch) the tab's icon sits on a quiet card.
    private func setPicture(_ image: NSImage?, at index: Int) {
        let layer = pictures[index].layer
        layer?.contents = image.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        placeholders[index].isHidden = image != nil
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private func applyColors() {
        let dark = isDark
        panel.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.078, green: 0.078, blue: 0.078, alpha: 0.97)
                                             : NSColor(srgbRed: 0.975, green: 0.975, blue: 0.975, alpha: 0.97)).cgColor
        panel.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.10)).cgColor
        var plateColor = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            plateColor = tint.usingColorSpace(.sRGB)?.withAlphaComponent(dark ? 0.27 : 0.32) ?? tint
        }
        for (index, plate) in plates.enumerated() {
            plate.layer?.backgroundColor = index == selected ? plateColor.cgColor : NSColor.clear.cgColor
            plate.setAccessibilitySelected(index == selected)
        }
        for picture in pictures {
            picture.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor
            picture.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)).cgColor
        }
        for label in titles { label.textColor = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85) }
    }

    override func layout() {
        super.layout()
        let width = CGFloat(tiles.count) * Self.tileSize.width + Self.padding * 2
        let height = Self.tileSize.height + Self.padding * 2
        panel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        for (index, plate) in plates.enumerated() {
            plate.frame = NSRect(x: Self.padding + CGFloat(index) * Self.tileSize.width, y: Self.padding,
                                 width: Self.tileSize.width, height: Self.tileSize.height)
            pictures[index].frame = NSRect(x: 12, y: 12, width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            placeholders[index].frame = NSRect(x: (Self.thumbnailSize.width - 28) / 2, y: (Self.thumbnailSize.height - 28) / 2, width: 28, height: 28)
        }
    }

    // The overlay swallows the mouse: a click on a tile lands there, anywhere
    // else does nothing (⌃ release still lands, Esc cancels).
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func tileIndex(at event: NSEvent) -> Int? {
        let point = panel.convert(event.locationInWindow, from: nil)
        return plates.firstIndex { $0.frame.contains(point) }
    }
    override func mouseMoved(with event: NSEvent) {
        // Only a moving pointer picks a tile, never one that happens to rest there.
        let location = event.locationInWindow
        defer { lastHoverPoint = location }
        guard let last = lastHoverPoint, hypot(location.x - last.x, location.y - last.y) > 1,
              let index = tileIndex(at: event), index != selected else { return }
        onHover?(index)
    }
    override func mouseDown(with event: NSEvent) { if let index = tileIndex(at: event) { onChoose?(index) } }
    override func scrollWheel(with event: NSEvent) {}
}
