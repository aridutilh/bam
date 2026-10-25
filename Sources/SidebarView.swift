import AppKit
import QuartzCore

enum SpaceScrollSource: String {
    case monitor, tabList, sidebar
}

/// AppKit can deliver tracked scroll events without going through a local monitor.
@MainActor private final class SidebarScrollView: NSScrollView {
    var onSpaceScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onSpaceScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

struct SidebarTabItem: Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbol: String
    let isPinned: Bool
    let isActive: Bool
    var isFavorite: Bool = false
    var isUnloaded: Bool = false
    var isSleeping: Bool = false
    var isSplit: Bool = false
    var canFavorite: Bool = true
    /// Kept-section hierarchy. Folder rows reuse this item with `isFolder`.
    var depth: Int = 0
    var isFolder: Bool = false
    var isExpanded: Bool = true
    /// The folder holding this row, if any.
    var parentFolderID: UUID? = nil
    /// Siblings within the same container, for Move Earlier/Later.
    var hasEarlierSibling: Bool = false
    var hasLaterSibling: Bool = false
    /// Number of tabs anywhere inside a folder row.
    var folderTabCount: Int = 0
    /// Whether a folder can hold another folder (depth limit).
    var canNestFolder: Bool = true
    /// Whether a tab can be wrapped in a new folder (it must be keepable).
    var canWrapInFolder: Bool = true
    /// Deepest level in the Space's whole kept tree, collapsed folders
    /// included. It sets one indent step for the list that doesn't change
    /// when a folder opens or closes, so rows never shift sideways.
    var treeDepth: Int = 0
}

/// A destination offered by Move to Folder menus.
struct SidebarFolderTarget: Equatable {
    let id: UUID?
    let name: String
    let depth: Int
    let isEnabled: Bool
}

/// Display state only: the controller resolves the current profile/tab again on click.
struct SidebarExtensionItem {
    let id: UUID
    let name: String
    let label: String
    let icon: NSImage?
    let badge: String
    let isEnabled: Bool
}

/// Shared Favorites and chrome stay fixed while each Space's heading and rows page.
@MainActor final class SidebarView: NSView {
    /// Fast cache lookup; the owner may schedule a fetch for this current tab.
    var faviconProvider: ((UUID) -> NSImage?)? { didSet { refreshFavicons() } }
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onPinTab: ((UUID) -> Void)?
    var onFavoriteTab: ((UUID) -> Void)?
    var onEditSavedTab: ((UUID) -> Void)?
    var onResetSavedTab: ((UUID) -> Void)?
    var onReorderSavedTab: ((UUID, Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onSearch: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onSpaceChange: ((Int) -> Void)?
    var onManageSpaces: (() -> Void)?
    var onMoveTab: ((UUID, Int) -> Void)?
    var onPictureInPicture: (() -> Void)?
    var onExtensionAction: ((UUID, NSView) -> Void)?
    var onExtensionsMenu: ((NSView) -> Void)?
    var onExtensionLibrary: (() -> Void)?
    var onSpaceScroll: ((NSEvent, SpaceScrollSource) -> Bool)?
    /// Drag and drop of sidebar rows within the shown Space (target, Space ID).
    var onDrop: ((UUID, BrowserSession.SidebarDropTarget, Int) -> Bool)?
    var canDrop: ((UUID, BrowserSession.SidebarDropTarget, Int) -> Bool)?
    /// Observes (or, returning false, cancels) a row drag just before it starts.
    var onRowDragWillBegin: ((UUID) -> Bool)?
    /// Escape in the tab list: hand keyboard focus back to the page.
    var onFocusPage: (() -> Void)?
    /// View ▸ Focus Sidebar: focus the selected tab's row (or the first row)
    /// without selecting or waking anything.
    @discardableResult func focusTabList() -> Bool { page.focusInitialRow() }
    /// A row dropped on a footer Space icon moves there (profile-aware in the controller).
    var onDropOnSpace: ((UUID, Int) -> Bool)?
    var onToggleFolder: ((UUID) -> Void)?
    var onRenameFolder: ((UUID) -> Void)?
    /// Creates a folder; the item is a tab to put inside it or a parent folder.
    var onNewFolder: ((UUID?) -> Void)?
    var onUngroupFolder: ((UUID) -> Void)?
    var onMoveToFolder: ((UUID, UUID?) -> Void)?
    var folderTargets: ((UUID) -> [SidebarFolderTarget])?
    override var isFlipped: Bool { true }
    private let back = ArkIconButton(symbol: "arrow.left", label: "Go back")
    private let forward = ArkIconButton(symbol: "arrow.right", label: "Go forward")
    private let reload = ArkIconButton(symbol: "arrow.clockwise", label: "Reload page")
    private let toggle = ArkIconButton(symbol: "sidebar.left", label: "Hide sidebar")
    private let search = ArkSearchButton()
    private let extensionMenu = ArkIconButton(symbol: "puzzlepiece.extension", label: "Extensions")
    private let extensionLibrary = ArkExtensionLibraryButton()
    private var extensionButtons: [ArkExtensionButton] = []
    private let pip = ArkIconButton(symbol: "pip", label: "Picture in Picture (⌥⌘P)")
    private let library = ArkSpacesButton()
    private let plus = ArkIconButton(symbol: "plus", label: "New tab")
    private let spaceOverflow = ArkIconButton(symbol: "ellipsis", label: "Choose Space")
    private var spaceDefinitions: [BrowserSpace] = []
    private var spaces: [ArkSpaceButton] = []
    private let favoritesHost = ArkFlippedView()
    private var favorites: [ArkFavoriteButton] = []
    private var favoriteItems: [SidebarTabItem] = []
    private let clip = ArkFlippedView()
    private var page = SidebarPage()
    private var departing: SidebarPage?
    private var departingSpace: Int?
    private var next: SidebarPage?
    private var nextSpace: Int?
    private var nextItems: [SidebarTabItem] = []
    private var cachedPages: [Int: SidebarPage] = [:]
    private var pageDirection: CGFloat = 1
    private var offset: CGFloat = 0
    private var selectedSpace = 0
    private var items: [SidebarTabItem] = []
    var isPaging: Bool { next != nil || departing != nil }
    func canReversePaging(to space: Int) -> Bool { departingSpace == space }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityLabel("Bam sidebar")
        clip.wantsLayer = true; clip.layer?.masksToBounds = true
        favoritesHost.setAccessibilityLabel("Favorites")
        favoritesHost.setAccessibilityRole(.group)
        [toggle, back, forward, reload, search, extensionMenu, extensionLibrary, favoritesHost, clip, library, plus, pip, spaceOverflow].forEach(addSubview)
        clip.addSubview(page); connect(page); cachedPages[0] = page
        back.handler = { [weak self] in self?.onBack?() }
        forward.handler = { [weak self] in self?.onForward?() }
        reload.handler = { [weak self] in self?.onReload?() }
        toggle.handler = { [weak self] in self?.onToggleSidebar?() }
        search.handler = { [weak self] in self?.onSearch?() }
        plus.handler = { [weak self] in self?.onNewTab?() }
        pip.handler = { [weak self] in self?.onPictureInPicture?() }
        library.handler = { [weak self] in self?.onManageSpaces?() }
        spaceOverflow.handler = { [weak self] in self?.showSpaceMenu() }
        extensionMenu.identifier = NSUserInterfaceItemIdentifier("extensions-menu")
        extensionLibrary.identifier = NSUserInterfaceItemIdentifier("extension-library")
        extensionMenu.handler = { [weak self] in
            guard let self else { return }; self.onExtensionsMenu?(self.extensionMenu)
        }
        extensionLibrary.handler = { [weak self] in self?.onExtensionLibrary?() }
        configureSpaces([
            BrowserSpace(id: 0, name: "Studio", symbol: "sparkles", colorIndex: 0),
            BrowserSpace(id: 1, name: "Life", symbol: "sun.max", colorIndex: 1),
            BrowserSpace(id: 2, name: "Explore", symbol: "globe", colorIndex: 2)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Space IDs identify cached pages; their order is supplied separately by the session.
    func configureSpaces(_ definitions: [BrowserSpace]) {
        var seen = Set<Int>()
        let definitions = Array(definitions.filter { seen.insert($0.id).inserted }.prefix(32))
        guard !definitions.isEmpty else { return }
        guard !definitions.elementsEqual(spaceDefinitions, by: {
            $0.id == $1.id && $0.name == $1.name && $0.symbol == $1.symbol && $0.colorIndex == $1.colorIndex && $0.emoji == $1.emoji
        }) else { return }
        spaceDefinitions = definitions
        let ids = Set(definitions.map(\.id))
        // Deleted transition pages cannot remain attached or be reused by a later gesture.
        if !ids.contains(selectedSpace) || nextSpace.map({ !ids.contains($0) }) == true
            || departingSpace.map({ !ids.contains($0) }) == true { endPaging() }
        if !ids.contains(selectedSpace) {
            page.removeFromSuperview()
            selectedSpace = definitions[0].id
            page = pageForSpace(selectedSpace)
            items = page.tabs
            clip.addSubview(page)
        }
        for id in Array(cachedPages.keys) where !ids.contains(id) {
            cachedPages.removeValue(forKey: id)?.removeFromSuperview()
        }
        let existing = Dictionary(uniqueKeysWithValues: spaces.map { ($0.index, $0) })
        spaces.filter { !ids.contains($0.index) }.forEach { $0.removeFromSuperview() }
        spaces = definitions.map { definition in
            let button = existing[definition.id] ?? ArkSpaceButton(space: definition)
            button.configure(definition)
            button.selected = definition.id == selectedSpace
            button.handler = { [weak self, weak button] in
                guard let button else { return }; self?.onSpaceChange?(button.index)
            }
            button.manage = { [weak self] in self?.onManageSpaces?() }
            button.acceptDrop = { [weak self, weak button] id in
                guard let self, let button, button.index != self.selectedSpace else { return false }
                return self.onDropOnSpace?(id, button.index) ?? false
            }
            if button.superview == nil { addSubview(button) }
            return button
        }
        for definition in definitions {
            cachedPages[definition.id]?.configureAppearance(space: definition, destinations: definitions)
        }
        needsLayout = true
    }

    private func definition(for id: Int) -> BrowserSpace? { spaceDefinitions.first { $0.id == id } }

    private func showSpaceMenu() {
        let menu = NSMenu(title: "Choose Space")
        for definition in spaceDefinitions {
            let item = NSMenuItem(title: definition.name, action: #selector(chooseSpaceFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.tag = definition.id
            item.state = definition.id == selectedSpace ? .on : .off
            item.image = ArkSpaceIcon.image(for: definition, pointSize: 14)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Spaces…", action: #selector(manageSpacesFromMenu), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: spaceOverflow.bounds.maxY), in: spaceOverflow)
    }
    @objc private func chooseSpaceFromMenu(_ sender: NSMenuItem) { onSpaceChange?(sender.tag) }
    @objc private func manageSpacesFromMenu() { onManageSpaces?() }

    /// Custom-drawn controls resolve their colors at draw time; repaint them all.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        func invalidate(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(invalidate) }
        invalidate(self)
    }

    // A vertical tab list is always at its horizontal edge. Ask AppKit to
    // forward that axis through its responder chain, including tracked events.
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }
    override func scrollWheel(with event: NSEvent) {
        if onSpaceScroll?(event, .sidebar) == true { return }
        super.scrollWheel(with: event)
    }
    private func connect(_ page: SidebarPage) {
        page.faviconProvider = { [weak self] in self?.faviconProvider?($0) }
        page.scroll.onSpaceScroll = { [weak self] in self?.onSpaceScroll?($0, .tabList) ?? false }
        page.select = { [weak self] in self?.onSelectTab?($0) }
        page.close = { [weak self] in self?.onCloseTab?($0) }
        page.pin = { [weak self] in self?.onPinTab?($0) }
        page.favorite = { [weak self] in self?.onFavoriteTab?($0) }
        page.editSaved = { [weak self] in self?.onEditSavedTab?($0) }
        page.resetSaved = { [weak self] in self?.onResetSavedTab?($0) }
        page.reorderSaved = { [weak self] in self?.onReorderSavedTab?($0, $1) }
        page.newTab = { [weak self] in self?.onNewTab?() }
        page.manageSpaces = { [weak self] in self?.onManageSpaces?() }
        page.move = { [weak self] in self?.onMoveTab?($0, $1) }
        page.toggleFolder = { [weak self] in self?.onToggleFolder?($0) }
        page.renameFolder = { [weak self] in self?.onRenameFolder?($0) }
        page.newFolder = { [weak self] in self?.onNewFolder?($0) }
        page.ungroupFolder = { [weak self] in self?.onUngroupFolder?($0) }
        page.moveToFolder = { [weak self] in self?.onMoveToFolder?($0, $1) }
        page.folderTargets = { [weak self] in self?.folderTargets?($0) ?? [] }
        page.drop = { [weak self] in self?.onDrop?($0, $1, $2) ?? false }
        page.canDrop = { [weak self] in self?.canDrop?($0, $1, $2) ?? false }
        page.rowDragWillBegin = { [weak self] in self?.onRowDragWillBegin?($0) ?? true }
        page.escape = { [weak self] in self?.onFocusPage?() }
    }
    private func configureFavorites(_ allItems: [SidebarTabItem]) {
        var seen = Set<UUID>()
        let updated = Array(allItems.filter { $0.isFavorite && seen.insert($0.id).inserted }.prefix(12))
        guard updated != favoriteItems else { return }
        favoriteItems = updated
        let existing = Dictionary(uniqueKeysWithValues: favorites.map { ($0.item.id, $0) })
        let ids = Set(updated.map(\.id))
        favorites.filter { !ids.contains($0.item.id) }.forEach { $0.removeFromSuperview() }
        favorites = updated.enumerated().map { index, item in
            let button = existing[item.id] ?? ArkFavoriteButton(item: item)
            button.configure(item, canMoveEarlier: index > 0, canMoveLater: index + 1 < updated.count)
            button.setFavicon(faviconProvider?(item.id))
            button.handler = { [weak self] in self?.onSelectTab?(item.id) }
            button.close = { [weak self] in self?.onCloseTab?(item.id) }
            button.keep = { [weak self] in self?.onPinTab?(item.id) }
            button.favorite = { [weak self] in self?.onFavoriteTab?(item.id) }
            button.editSaved = { [weak self] in self?.onEditSavedTab?(item.id) }
            button.resetSaved = { [weak self] in self?.onResetSavedTab?(item.id) }
            button.reorderSaved = { [weak self] in self?.onReorderSavedTab?(item.id, $0) }
            if button.superview == nil { favoritesHost.addSubview(button) }
            return button
        }
        // A newly promoted Favorite may still have a row in a cached page.
        // Remove that duplicate without replacing its NSScrollView or other rows.
        for (spaceID, cached) in cachedPages where cached.tabs.contains(where: { ids.contains($0.id) }) {
            guard let definition = definition(for: spaceID) else { continue }
            cached.configure(cached.tabs.filter { !ids.contains($0.id) }, space: definition, destinations: spaceDefinitions)
            if spaceID == selectedSpace { items = cached.tabs }
        }
        nextItems.removeAll { ids.contains($0.id) }
        needsLayout = true
    }
    /// Refresh only materialized rows on attached pages, including both sides
    /// of a Space gesture. Cached offscreen pages resolve icons when attached.
    func refreshFavicons() {
        for button in favorites { button.setFavicon(faviconProvider?(button.item.id)) }
        for case let attached as SidebarPage in clip.subviews { attached.refreshFavicons() }
    }
    func update(tabs: [SidebarTabItem], space: Int, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        guard let definition = definition(for: space) else { return }
        configureFavorites(tabs)
        let tabs = tabs.filter { !$0.isFavorite }
        // A commit can reach refresh() before the controller explicitly finishes
        // paging. Adopt the incoming view here too, without rebuilding either page.
        let spaceChanged = selectedSpace != space
        if spaceChanged {
            if nextSpace == space { commitPaging(to: space) }
            else {
                endPaging()
                page.removeFromSuperview()
                page = pageForSpace(space)
                clip.addSubview(page)
                selectedSpace = space
                items = []
                library.playSelection()
            }
        }
        if items != tabs || spaceChanged { items = tabs; page.configure(tabs, space: definition, destinations: spaceDefinitions) }
        back.isEnabled = canGoBack; forward.isEnabled = canGoForward
        reload.setSymbol(isLoading ? "xmark" : "arrow.clockwise", label: isLoading ? "Stop loading" : "Reload page")
        for button in spaces { button.selected = button.index == space }
        needsLayout = true
    }
    func updateExtensions(_ items: [SidebarExtensionItem]) {
        let previous = Dictionary(uniqueKeysWithValues: extensionButtons.map { ($0.item.id, $0) })
        let ids = Set(items.map(\.id))
        extensionButtons.filter { !ids.contains($0.item.id) }.forEach { $0.removeFromSuperview() }
        extensionButtons = items.map { item in
            let button = previous[item.id] ?? ArkExtensionButton(item: item)
            button.configure(item)
            button.handler = { [weak self, weak button] in
                guard let self, let button else { return }; self.onExtensionAction?(button.item.id, button)
            }
            if button.superview == nil { addSubview(button) }
            return button
        }
        needsLayout = true
    }

    private func pageForSpace(_ space: Int) -> SidebarPage {
        if let cached = cachedPages[space] { return cached }
        let created = SidebarPage(); connect(created); cachedPages[space] = created
        if let definition = definition(for: space) {
            created.configureAppearance(space: definition, destinations: spaceDefinitions)
        }
        return created
    }
    func setAddress(_ address: String, title: String) { search.address = title; search.toolTip = address }
    func beginPaging(tabs: [SidebarTabItem], space: Int, direction: CGFloat) {
        guard space != selectedSpace, let definition = definition(for: space) else { return }
        // Preview data may describe a different selected tab. Shared Favorite
        // selection changes only when update() receives the committed session.
        let tabs = tabs.filter { !$0.isFavorite }
        if let next, nextSpace == space, pageDirection == direction {
            // Loading/title/selection updates may arrive while fingers are down.
            // Keep the page and offset; only reconcile its changing row data.
            if nextItems != tabs { nextItems = tabs; next.configure(tabs, space: definition, destinations: spaceDefinitions) }
            return
        }
        departing?.removeFromSuperview(); departing = nil; departingSpace = nil
        next?.removeFromSuperview()
        let incoming = pageForSpace(space)
        incoming.configure(tabs, space: definition, destinations: spaceDefinitions)
        nextSpace = space; nextItems = tabs; pageDirection = direction
        clip.addSubview(incoming); next = incoming
        layoutSubtreeIfNeeded(); setPagingOffset(offset)
    }
    func setPagingOffset(_ value: CGFloat) {
        guard value.isFinite else { return }
        offset = value
        // Frames are driven by the gesture/spring. Backing layers must not add a
        // second implicit animation, and origin-only moves need no row relayout.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        position(page, at: value)
        if let departing { position(departing, at: value - clip.bounds.width * pageDirection) }
        if let next { position(next, at: value + clip.bounds.width * pageDirection) }
        CATransaction.commit()
    }
    private func position(_ page: SidebarPage, at x: CGFloat) {
        let size = clip.bounds.size
        if page.frame.size != size { page.setFrameSize(size) }
        let origin = NSPoint(x: x, y: 0)
        if page.frame.origin != origin { page.setFrameOrigin(origin) }
    }
    /// Select immediately, retaining the outgoing page only for visual settling.
    /// Rebase to the selected page's coordinates so a reversal can reuse both
    /// live sidebar pages at their exact current positions.
    @discardableResult func commitPaging(to space: Int, preservingOffset: Bool = false) -> CGFloat {
        guard let incoming = next, nextSpace == space else { return offset }
        let previous = page, previousSpace = selectedSpace
        let incomingOffset = offset + clip.bounds.width * pageDirection
        page = incoming; items = nextItems; selectedSpace = space
        next = nil; nextSpace = nil; nextItems = []
        if preservingOffset { departing = previous; departingSpace = previousSpace }
        else { previous.removeFromSuperview() }
        setPagingOffset(preservingOffset ? incomingOffset : 0)
        for button in spaces { button.selected = button.index == space }
        library.playSelection()
        return offset
    }
    func endPaging() {
        next?.removeFromSuperview(); next = nil; nextSpace = nil; nextItems = []
        departing?.removeFromSuperview(); departing = nil; departingSpace = nil
        setPagingOffset(0)
    }
    override func layout() {
        super.layout(); let w = bounds.width
        // Native traffic lights occupy the first 78 points of the top strip.
        toggle.frame = NSRect(x: 80, y: 10, width: 28, height: 28)
        let start = w - 104
        for (i, button) in [back, forward, reload].enumerated() {
            button.frame = NSRect(x: start + CGFloat(i) * 34, y: 10, width: 28, height: 28)
        }
        // Keep navigation clear of the traffic lights and sidebar toggle.
        let compact = w < 218
        forward.isHidden = compact; back.isHidden = compact
        // Arc/Yab proportions: a 34-point address field under the window
        // controls, Favorites as a 3-column grid of 46-point tiles, then the
        // Space's rows. Extension actions take a row only when installed.
        let fieldTop = ArkMetrics.addressTop, fieldHeight = ArkMetrics.addressHeight
        search.frame = NSRect(x: 8, y: fieldTop, width: max(0, w - 16), height: fieldHeight)
        let hasActions = !extensionButtons.isEmpty
        search.trailingInset = hasActions ? 10 : 34
        extensionLibrary.isHidden = hasActions
        extensionLibrary.frame = NSRect(x: w - 8 - 32, y: fieldTop + (fieldHeight - 28) / 2, width: 28, height: 28)
        extensionMenu.isHidden = !hasActions
        let actionTop = fieldTop + fieldHeight + 6
        extensionMenu.frame = NSRect(x: 8, y: actionTop, width: 30, height: 30)
        let actionCapacity = max(0, Int((w - 52) / 34))
        for (index, button) in extensionButtons.enumerated() {
            button.isHidden = index >= actionCapacity
            if !button.isHidden { button.frame = NSRect(x: 45 + CGFloat(index) * 34, y: actionTop - 1, width: 32, height: 32) }
        }
        let hiddenCount = max(0, extensionButtons.count - actionCapacity)
        extensionMenu.setSymbol(hiddenCount > 0 ? "ellipsis.circle" : "puzzlepiece.extension",
            label: hiddenCount > 0 ? "All extensions, including \(hiddenCount) more" : "Extensions")
        let gridTop = hasActions ? actionTop + 38 : fieldTop + fieldHeight + 10
        let columns = w >= 330 ? 4 : 3
        let gap = ArkMetrics.favoriteGap, tileHeight = ArkMetrics.favoriteHeight
        let favoriteRows = (favorites.count + columns - 1) / columns
        let favoriteHeight = favoriteRows == 0 ? CGFloat.zero : CGFloat(favoriteRows) * tileHeight + CGFloat(favoriteRows - 1) * gap
        favoritesHost.isHidden = favorites.isEmpty
        favoritesHost.frame = NSRect(x: 0, y: gridTop, width: w, height: favoriteHeight)
        let tileWidth = max(0, (w - 16 - CGFloat(columns - 1) * gap) / CGFloat(columns))
        for (index, button) in favorites.enumerated() {
            button.frame = NSRect(x: 8 + CGFloat(index % columns) * (tileWidth + gap),
                                  y: CGFloat(index / columns) * (tileHeight + gap), width: tileWidth, height: tileHeight)
        }
        let pageTop: CGFloat = gridTop + favoriteHeight + (favorites.isEmpty ? 0 : 10)
        clip.frame = NSRect(x: 0, y: pageTop, width: w, height: max(0, bounds.height - pageTop - 45))
        setPagingOffset(offset)
        let y = bounds.height-36
        library.frame = NSRect(x: 9, y: y, width: 28, height: 28)
        // Keep footer actions separate at the minimum width. Overflow uses a
        // native menu, so horizontal input still belongs to Space paging.
        let selectorStart: CGFloat = 43
        let selectorEnd = w - (w < 220 ? 40 : 72)
        let selectorWidth = max(0, selectorEnd - selectorStart)
        let capacity = max(1, Int(selectorWidth / 28))
        let overflowing = spaces.count > capacity
        let visibleCount = min(spaces.count, max(1, capacity - (overflowing ? 1 : 0)))
        let selectedIndex = spaces.firstIndex { $0.index == selectedSpace } ?? 0
        let startIndex = max(0, min(selectedIndex - visibleCount / 2, spaces.count - visibleCount))
        let totalWidth = CGFloat(visibleCount + (overflowing ? 1 : 0)) * 28
        let x = selectorStart + max(0, (selectorWidth - totalWidth) / 2)
        for (index, button) in spaces.enumerated() {
            button.isHidden = index < startIndex || index >= startIndex + visibleCount
            if !button.isHidden {
                button.frame = NSRect(x: x + CGFloat(index - startIndex) * 28, y: y, width: 26, height: 28)
            }
        }
        spaceOverflow.isHidden = !overflowing
        spaceOverflow.frame = NSRect(x: x + CGFloat(visibleCount) * 28, y: y, width: 26, height: 28)
        pip.frame = NSRect(x: w-68, y: y, width: 28, height: 28)
        plus.frame = NSRect(x: w-36, y: y, width: 28, height: 28)
        pip.isHidden = w < 220
    }
}

/// Keep a lightweight model for every tab; AppKit creates/reuses only the rows
/// near the viewport, and supplies native accessibility for offscreen table rows.
@MainActor private final class SidebarPage: ArkFlippedView, NSTableViewDataSource, NSTableViewDelegate {
    var faviconProvider: ((UUID) -> NSImage?)?
    var select: ((UUID)->Void)?; var close: ((UUID)->Void)?; var pin: ((UUID)->Void)?; var newTab: (()->Void)?
    var manageSpaces: (() -> Void)?
    var move: ((UUID, Int) -> Void)?
    var favorite: ((UUID) -> Void)?
    var editSaved: ((UUID) -> Void)?
    var resetSaved: ((UUID) -> Void)?
    var reorderSaved: ((UUID, Int) -> Void)?
    var toggleFolder: ((UUID) -> Void)?
    var renameFolder: ((UUID) -> Void)?
    var newFolder: ((UUID?) -> Void)?
    var ungroupFolder: ((UUID) -> Void)?
    var moveToFolder: ((UUID, UUID?) -> Void)?
    var folderTargets: ((UUID) -> [SidebarFolderTarget])?
    var drop: ((UUID, BrowserSession.SidebarDropTarget, Int) -> Bool)?
    var canDrop: ((UUID, BrowserSession.SidebarDropTarget, Int) -> Bool)?
    var rowDragWillBegin: ((UUID) -> Bool)?
    var escape: (() -> Void)?
    let heading = ArkSpaceHeading()
    let scroll = SidebarScrollView()
    private let table = SidebarTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tabs"))
    private enum Entry { case tab(Int), divider, newTab }
    private var entries: [Entry] = []
    private var rowByID: [UUID: Int] = [:]
    private var spaceAppearance: BrowserSpace?
    private var destinations: [BrowserSpace] = []
    private var synchronizingSelection = false
    private(set) var tabs: [SidebarTabItem] = []
    /// Deepest folder level in this list; sets the shared indent step.
    private(set) var maxDepth = 0

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        addSubview(heading); addSubview(scroll)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .none
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear
        table.style = .plain; table.intercellSpacing = NSSize(width: 0, height: 5)
        table.rowSizeStyle = .custom; table.rowHeight = 36
        table.usesAutomaticRowHeights = false; table.selectionHighlightStyle = .none
        table.focusRingType = .none; table.allowsEmptySelection = true
        table.registerForDraggedTypes([.bamSidebarRow])
        table.draggingDestinationFeedbackStyle = .regular
        table.allowsMultipleSelection = false; table.allowsColumnSelection = false
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.dataSource = self; table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-list")
        scroll.documentView = table
        heading.handler = { [weak self] in self?.manageSpaces?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { refreshFavicons() }
    }
    func refreshFavicons() {
        guard superview != nil else { return }
        table.enumerateAvailableRowViews { [weak self] _, index in
            guard let self, let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarTabCell else { return }
            cell.row.setFavicon(cell.row.item.isSplit ? nil : self.faviconProvider?(cell.row.item.id))
        }
    }

    func configure(_ items: [SidebarTabItem], space: BrowserSpace, destinations: [BrowserSpace]) {
        let items = items.filter { !$0.isFavorite }
        let structureChanged = tabs.count != items.count || zip(tabs, items).contains {
            $0.id != $1.id || $0.isPinned != $1.isPinned || $0.isFolder != $1.isFolder || $0.depth != $1.depth
        }
        let changed = structureChanged ? [] : items.indices.filter { tabs[$0] != items[$0] }
        let origin = scroll.contentView.bounds.origin
        let oldKeys = structureChanged ? entryKeys : []
        // Keyboard focus belongs to a row identity, not a cell: the focused tab
        // or folder keeps focus through reloads, reorders and cell reuse. If it
        // was removed, focus moves to the row now in its place (nothing opens).
        let focusedRow = (window?.firstResponder as? ArkTabRow).flatMap { $0.isDescendant(of: table) ? $0 : nil }
        let focusedID = focusedRow?.item.id, focusedIndex = focusedRow.map { table.row(for: $0) } ?? -1
        defer { if let focusedID { restoreFocus(to: focusedID, near: focusedIndex) } }
        tabs = items
        configureAppearance(space: space, destinations: destinations)
        let deepest = items.map { max($0.depth, $0.treeDepth) }.max() ?? 0
        if deepest != maxDepth {
            // One indent step for the whole list: every visible row re-lays out.
            maxDepth = deepest
            table.enumerateAvailableRowViews { [weak self] _, index in
                guard let self, let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarTabCell else { return }
                cell.row.listMaxDepth = deepest
            }
        }
        if structureChanged || entries.isEmpty {
            entries = []; rowByID = [:]
            let kept = tabs.indices.filter { tabs[$0].isPinned }
            for index in kept { rowByID[tabs[index].id] = entries.count; entries.append(.tab(index)) }
            if !kept.isEmpty { entries.append(.divider) }
            entries.append(.newTab)
            for index in tabs.indices where !tabs[index].isPinned {
                rowByID[tabs[index].id] = entries.count; entries.append(.tab(index))
            }
            synchronizingSelection = true
            if !animateContiguousChange(from: oldKeys) { table.reloadData() }
            synchronizingSelection = false
            needsLayout = true; layoutSubtreeIfNeeded()
            // Table reloads/reorders must not reset a Space's retained scroll position.
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            // Most updates are a selection pair or one title. Do not recreate
            // symbols, callbacks, tracking areas or layout for unchanged rows.
            for index in changed {
                guard let row = rowByID[tabs[index].id],
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCell else { continue }
                configure(cell, item: tabs[index])
            }
        }
        synchronizeSelection()
    }

    /// Keyboard navigation moves a focus ring, never the selection: Up/Down
    /// visit tab and folder rows without opening (or waking) anything.
    /// Return/Space open the focused tab or toggle the focused folder.
    @discardableResult func moveKeyboardFocus(from row: Int, by delta: Int) -> Bool {
        var target = row + delta
        while entries.indices.contains(target) {
            if case .tab = entries[target] { focusRow(target); return true }
            target += delta
        }
        return false
    }
    /// Entry point for View ▸ Focus Sidebar: the selected tab's row, else the first row.
    @discardableResult func focusInitialRow() -> Bool {
        if let active = tabs.first(where: \.isActive), let row = rowByID[active.id] { focusRow(row); return true }
        if moveKeyboardFocus(from: -1, by: 1) { return true }
        // No rows yet: the list itself takes focus, so arrows are harmless no-ops.
        window?.makeFirstResponder(table); return false
    }
    private func restoreFocus(to id: UUID, near index: Int) {
        if rowByID[id] != nil { focusRow(withID: id); return }
        // Removed: the nearest focusable row at or above its old position, else the list.
        let start = min(max(index, 0), max(entries.count - 1, 0))
        if moveKeyboardFocus(from: start - 1, by: 1) || moveKeyboardFocus(from: start + 1, by: -1) { return }
        window?.makeFirstResponder(table)
    }
    /// ← on a row inside a folder moves focus to that folder.
    fileprivate func focusParent(of id: UUID) -> Bool {
        guard let parent = tabs.first(where: { $0.id == id })?.parentFolderID, rowByID[parent] != nil else { return false }
        focusRow(withID: parent); return true
    }
    private var focusedRowIndex: Int? {
        guard let focused = window?.firstResponder as? NSView, focused !== table, focused.isDescendant(of: table) else { return nil }
        let row = table.row(for: focused)
        return row >= 0 ? row : nil
    }
    private func focusRow(_ row: Int) {
        guard entries.indices.contains(row) else { return }
        table.scrollRowToVisible(row)
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarTabCell { window?.makeFirstResponder(cell.row) }
    }
    private func focusRow(withID id: UUID) {
        guard let row = rowByID[id], window?.firstResponder !== (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCell)?.row else { return }
        focusRow(row)
    }
    /// Arrows while the list itself has focus: continue from the focused row,
    /// else the selected row, else enter from the edge in the arrow's direction.
    fileprivate func handleTableArrow(_ delta: Int) -> Bool {
        let start = focusedRowIndex ?? (table.selectedRow >= 0 ? table.selectedRow : (delta > 0 ? -1 : entries.count))
        return moveKeyboardFocus(from: start, by: delta)
    }

    private static let dividerKey = UUID(), newTabKey = UUID()
    private var entryKeys: [UUID] {
        entries.map { entry in
            switch entry { case .tab(let index): return tabs.indices.contains(index) ? tabs[index].id : UUID()
            case .divider: return Self.dividerKey
            case .newTab: return Self.newTabKey }
        }
    }
    /// Expanding or collapsing a folder inserts or removes one contiguous run
    /// of rows. Slide just those rows (Arc-like) instead of reloading the
    /// list; anything else, offscreen pages and Reduce Motion reload directly.
    private func animateContiguousChange(from oldKeys: [UUID]) -> Bool {
        guard !oldKeys.isEmpty, window?.isVisible == true, superview != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        let newKeys = entryKeys
        var prefix = 0
        while prefix < min(oldKeys.count, newKeys.count), oldKeys[prefix] == newKeys[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldKeys.count, newKeys.count) - prefix,
              oldKeys[oldKeys.count - 1 - suffix] == newKeys[newKeys.count - 1 - suffix] { suffix += 1 }
        let removed = oldKeys.count - prefix - suffix, inserted = newKeys.count - prefix - suffix
        guard (removed == 0) != (inserted == 0), max(removed, inserted) <= 300 else { return false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            table.beginUpdates()
            if inserted > 0 { table.insertRows(at: IndexSet(prefix..<(prefix + inserted)), withAnimation: [.effectFade, .slideDown]) }
            else { table.removeRows(at: IndexSet(prefix..<(prefix + removed)), withAnimation: [.effectFade, .slideUp]) }
            table.endUpdates()
        }
        // Surviving rows keep their views; refresh their models (indices and the folder's own state moved).
        table.enumerateAvailableRowViews { [weak self] _, row in
            guard let self, self.entries.indices.contains(row), case .tab(let index) = self.entries[row],
                  let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCell else { return }
            self.configure(cell, item: self.tabs[index])
        }
        return true
    }

    func configureAppearance(space: BrowserSpace, destinations: [BrowserSpace]) {
        guard spaceAppearance != space || self.destinations != destinations else { return }
        spaceAppearance = space; self.destinations = destinations
        identifier = NSUserInterfaceItemIdentifier("sidebar-space-\(space.id)")
        heading.configure(space)
        table.setAccessibilityLabel("Tabs in \(space.name)")
        let tint = ArkPalette.spaceTint(space.colorIndex)
        table.enumerateAvailableRowViews { [weak self] _, index in
            guard let self, let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarTabCell else { return }
            cell.row.configureSpace(id: space.id, tint: tint, destinations: destinations)
        }
    }

    private func configure(_ cell: SidebarTabCell, item: SidebarTabItem) {
        let row = cell.row
        if row.item.id != item.id, let focused = window?.firstResponder as? NSView,
           focused === row || focused.isDescendant(of: row) { window?.makeFirstResponder(table) }
        row.listMaxDepth = maxDepth
        row.update(item)
        row.setFavicon(superview == nil || item.isSplit ? nil : faviconProvider?(item.id))
        if let spaceAppearance { row.configureSpace(id: spaceAppearance.id, tint: ArkPalette.spaceTint(spaceAppearance.colorIndex), destinations: destinations) }
        row.canMoveEarlier = item.hasEarlierSibling; row.canMoveLater = item.hasLaterSibling
        // Read the cell's current identity: AppKit can recycle it for a different tab.
        row.select = { [weak self, weak row] in if let id = row?.item.id { self?.select?(id) } }
        row.close = { [weak self, weak row] in if let id = row?.item.id { self?.close?(id) } }
        row.pin = { [weak self, weak row] in if let id = row?.item.id { self?.pin?(id) } }
        row.move = { [weak self, weak row] destination in if let id = row?.item.id { self?.move?(id, destination) } }
        row.favorite = { [weak self, weak row] in if let id = row?.item.id { self?.favorite?(id) } }
        row.editSaved = { [weak self, weak row] in if let id = row?.item.id { self?.editSaved?(id) } }
        row.resetSaved = { [weak self, weak row] in if let id = row?.item.id { self?.resetSaved?(id) } }
        row.reorderSaved = { [weak self, weak row] direction in if let id = row?.item.id { self?.reorderSaved?(id, direction) } }
        row.toggleFolder = { [weak self, weak row] in if let id = row?.item.id { self?.toggleFolder?(id) } }
        row.renameFolder = { [weak self, weak row] in if let id = row?.item.id { self?.renameFolder?(id) } }
        row.newFolder = { [weak self, weak row] in if let id = row?.item.id { self?.newFolder?(id) } }
        row.ungroupFolder = { [weak self, weak row] in if let id = row?.item.id { self?.ungroupFolder?(id) } }
        row.moveToFolder = { [weak self, weak row] target in if let id = row?.item.id { self?.moveToFolder?(id, target) } }
        row.folderTargets = { [weak self, weak row] in row.flatMap { self?.folderTargets?($0.item.id) } ?? [] }
        row.willBeginDrag = { [weak self] id in self?.rowDragWillBegin?(id) ?? true }
        row.arrow = { [weak self, weak row] delta in
            guard let self, let row else { return false }
            let index = self.table.row(for: row)
            return index >= 0 && self.moveKeyboardFocus(from: index, by: delta)
        }
        row.focusParent = { [weak self, weak row] in row.map { self?.focusParent(of: $0.item.id) ?? false } ?? false }
        row.escape = { [weak self] in self?.escape?() }
    }
    private func synchronizeSelection() {
        let selected = tabs.first(where: \.isActive).flatMap { rowByID[$0.id] }
        guard table.selectedRow != (selected ?? -1) else { return }
        synchronizingSelection = true
        if let selected { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        synchronizingSelection = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch entries[row] { case .tab: return 36; case .divider: return 20; case .newTab: return 36 }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard entries.indices.contains(row) else { return false }
        if case .tab(let index) = entries[row] { return !tabs[index].isFolder }; return false
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingSelection, entries.indices.contains(table.selectedRow),
              case .tab(let index) = entries[table.selectedRow] else { return }
        select?(tabs[index].id)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarTableRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entries[row] {
        case .tab(let index):
            let key = NSUserInterfaceItemIdentifier("sidebar-tab-cell")
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? SidebarTabCell ?? SidebarTabCell(item: tabs[index])
            cell.identifier = key; configure(cell, item: tabs[index]); return cell
        case .newTab:
            let key = NSUserInterfaceItemIdentifier("sidebar-new-tab")
            let button = tableView.makeView(withIdentifier: key, owner: self) as? ArkNewTabButton ?? ArkNewTabButton()
            button.identifier = key; button.handler = { [weak self] in self?.newTab?() }; return button
        case .divider:
            let key = NSUserInterfaceItemIdentifier("sidebar-divider")
            let divider = tableView.makeView(withIdentifier: key, owner: self) as? SidebarDividerCell ?? SidebarDividerCell(frame: .zero)
            divider.identifier = key; return divider
        }
    }
    // MARK: Drag and drop

    /// Maps the table's proposed drop to a model target. Dropping on a folder
    /// files the row inside it; between rows means "before that row" in its
    /// folder; the divider/New Tab gap is the end of the kept section; Today
    /// rows (and the end of the list) unkeep into Today at that position.
    func dropTarget(row: Int, operation: NSTableView.DropOperation) -> (target: BrowserSession.SidebarDropTarget, row: Int, operation: NSTableView.DropOperation) {
        if operation == .on, entries.indices.contains(row), case .tab(let index) = entries[row], tabs[index].isFolder {
            return (.into(tabs[index].id), row, .on)
        }
        if entries.indices.contains(row) {
            switch entries[row] {
            case .tab(let index): return (tabs[index].isPinned ? .before(tabs[index].id) : .today(before: tabs[index].id), row, .above)
            case .divider, .newTab: return (.keptEnd, row, .above)
            }
        }
        return (.today(before: nil), entries.count, .above)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let raw = info.draggingPasteboard.string(forType: .bamSidebarRow), let id = UUID(uuidString: raw),
              let space = spaceAppearance?.id else { return [] }
        let proposal = dropTarget(row: row, operation: operation)
        // Only show an indicator where the model would accept the row: no cycles,
        // no over-deep nesting, no folders in Today.
        guard canDrop?(id, proposal.target, space) == true else { return [] }
        tableView.setDropRow(proposal.row, dropOperation: proposal.operation)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: .bamSidebarRow), let id = UUID(uuidString: raw),
              let space = spaceAppearance?.id else { return false }
        return drop?(id, dropTarget(row: row, operation: dropOperation).target, space) ?? false
    }

    override func layout() {
        super.layout(); let w = bounds.width
        heading.frame = NSRect(x: 12, y: 0, width: max(0, w-24), height: 32)
        scroll.frame = NSRect(x: 8, y: 39, width: max(0,w-16), height: max(0,bounds.height-39))
        let width = scroll.contentSize.width
        if table.frame.width != width { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if column.width != width { column.width = width }
    }
}

/// Arrow keys reach folder rows, which are focus stops rather than selections.
@MainActor private final class SidebarTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let delta = event.keyCode == 125 ? 1 : event.keyCode == 126 ? -1 : 0
        // Plain Up/Down only ever move focus; with nowhere to go they are no-ops,
        // never NSTableView selection (which would open or wake a tab).
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if delta != 0, plain, let page = delegate as? SidebarPage { _ = page.handleTableArrow(delta); return }
        super.keyDown(with: event)
    }
}

@MainActor private final class SidebarTableRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    /// A folder about to receive a row lights up like a hovered row with a ring.
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: ArkMetrics.rowRadius, yRadius: ArkMetrics.rowRadius)
        ArkPalette.selection.setFill(); shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke(); shape.lineWidth = 1.5; shape.stroke()
    }
}

extension NSPasteboard.PasteboardType {
    /// A sidebar row's tab or folder ID, for moves within Bam only.
    static let bamSidebarRow = NSPasteboard.PasteboardType("com.ari.bam.sidebar-row")
}
@MainActor private final class SidebarTabCell: NSTableCellView {
    let row: ArkTabRow
    init(item: SidebarTabItem) {
        row = ArkTabRow(item: item)
        super.init(frame: .zero); addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); row.frame = bounds }
}
@MainActor private final class SidebarDividerCell: NSView {
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        ArkPalette.separator.setFill()
        NSRect(x: 10, y: bounds.midY, width: max(0,bounds.width-20), height: 1).fill()
    }
}

/// Sidebar colors resolve per appearance at draw time. Dark keeps Bam's
/// established values; light follows Arc/Yab's light chrome: near-black ink,
/// a lifted white selection, translucent white tiles and black-tinted hovers.
@MainActor
enum ArkPalette {
    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }
    private static func black(_ alpha: CGFloat) -> NSColor { NSColor(white: 0, alpha: alpha) }
    static let ink = NSColor.chrome(light: NSColor(white: 0.11, alpha: 1), dark: NSColor(white: 0.94, alpha: 1))
    static let secondary = NSColor.chrome(light: NSColor(white: 0.38, alpha: 1), dark: NSColor(white: 0.73, alpha: 1))
    /// Hover wash for rows and icon buttons.
    static let hover = NSColor.chrome(light: black(0.055), dark: white(0.07))
    static let pressed = NSColor.chrome(light: black(0.10), dark: white(0.20))
    static let iconHover = NSColor.chrome(light: black(0.06), dark: white(0.10))
    /// The selected tab: a lifted pill.
    static let selection = NSColor.chrome(light: white(0.86), dark: white(0.15))
    static let selectionEdge = NSColor.chrome(light: black(0.06), dark: white(0.10))
    static let field = NSColor.chrome(light: white(0.58), dark: white(0.09))
    static let fieldHover = NSColor.chrome(light: white(0.75), dark: white(0.14))
    static let tile = NSColor.chrome(light: white(0.46), dark: white(0.09))
    static let tileHover = NSColor.chrome(light: white(0.66), dark: white(0.15))
    static let tileActive = NSColor.chrome(light: white(0.94), dark: white(0.22))
    static let tileRing = NSColor.chrome(light: black(0.10), dark: white(0.28))
    static let separator = NSColor.chrome(light: black(0.08), dark: white(0.10))
    /// Space icon tint: the pastel in dark mode, a deeper version on light chrome.
    static func spaceTint(_ index: Int) -> NSColor { spaceTints[min(spaceTints.count - 1, max(0, index))] }
    /// Built once so identity comparisons stay stable across updates.
    private static let spaceTints: [NSColor] = spaceColors.map { base in
        let deep = base.usingColorSpace(.deviceRGB).map {
            NSColor(deviceHue: $0.hueComponent, saturation: min(1, $0.saturationComponent * 1.5 + 0.12),
                    brightness: $0.brightnessComponent * 0.62, alpha: 1)
        } ?? base
        return .chrome(light: deep, dark: base)
    }
    static let spaceColors = [
        NSColor(calibratedRed: 0.80, green: 0.72, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.88, green: 0.75, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.62, green: 0.81, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.94, green: 0.65, blue: 0.73, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.79, blue: 0.47, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.80, alpha: 1),
        // Prism and Clear are appearances; these are their accent tints.
        NSColor(calibratedRed: 0.84, green: 0.62, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.90, alpha: 1)
    ]
    static func spaceColor(_ index: Int) -> NSColor { spaceColors[min(spaceColors.count - 1, max(0, index))] }
}

/// Sidebar type scale, measured against Arc/Yab at the default sidebar width.
@MainActor enum ArkType {
    static let rowSize: CGFloat = 13.5
    static func rowFont(active: Bool, folder: Bool) -> NSFont {
        .systemFont(ofSize: rowSize, weight: folder ? .semibold : active ? .medium : .regular)
    }
}
/// Sidebar geometry in points, matched to Arc/Yab at a ~230-point sidebar.
@MainActor enum ArkMetrics {
    static let folderIndent: CGFloat = 14
    /// Indentation shrinks for deep trees so titles keep this much room.
    /// At the 164pt minimum sidebar a row has 76pt for its title, so the floor
    /// stays below that; deep rows still indent a little to show hierarchy.
    static let minimumTitleWidth: CGFloat = 64
    static let addressTop: CGFloat = 44
    static let addressHeight: CGFloat = 34
    static let favoriteHeight: CGFloat = 46
    static let favoriteGap: CGFloat = 8
    static let rowRadius: CGFloat = 9
    /// Leading icon column and the trailing gap a row always keeps.
    static let leadingInset: CGFloat = 36
    static let trailingGap: CGFloat = 10
    /// Room the close button (or folder chevron) takes when it is showing.
    static let trailingControl: CGFloat = 24
    /// One per-level indent for the whole list, chosen from its deepest row so
    /// every level stays visibly distinct (depth 1 never lines up with depth 5)
    /// while the deepest titles keep at least `minimumTitleWidth`, even with
    /// the close button showing.
    static func indentStep(maxDepth: Int, width: CGFloat) -> CGFloat {
        guard maxDepth > 0 else { return folderIndent }
        let available = max(0, width - leadingInset - trailingGap - trailingControl - minimumTitleWidth)
        return min(folderIndent, available / CGFloat(maxDepth))
    }
}

/// Frames inside a sidebar row. Pure geometry so it can be tested directly.
@MainActor struct ArkRowLayout {
    let icon: NSRect, title: NSRect, close: NSRect, chevron: NSRect
    let indent: CGFloat
    init(width: CGFloat, height: CGFloat, depth: Int, listMaxDepth: Int, isFolder: Bool, showsClose: Bool) {
        let step = ArkMetrics.indentStep(maxDepth: max(listMaxDepth, depth), width: width)
        indent = CGFloat(max(0, depth)) * step
        icon = NSRect(x: 10 + indent, y: (height - 16) / 2, width: 16, height: 16)
        close = NSRect(x: width - 30, y: (height - 24) / 2, width: 24, height: 24)
        chevron = NSRect(x: width - 24, y: (height - 12) / 2, width: 12, height: 12)
        // The title runs to the trailing control when one shows, else to the edge.
        let titleEnd = isFolder ? chevron.minX - 4 : showsClose ? close.minX - 4 : width - ArkMetrics.trailingGap
        let titleX = ArkMetrics.leadingInset + indent
        title = NSRect(x: titleX, y: (height - 20) / 2, width: max(0, titleEnd - titleX), height: 20)
    }
}

/// Row contrast. Like Arc, a saved tab that hasn't been opened yet (every
/// freshly imported row) reads at full contrast; only a page Bam put to sleep
/// to save memory is quieted, and only slightly.
@MainActor enum ArkRowInk {
    static func title(sleeping: Bool) -> NSColor { sleeping ? ArkPalette.secondary : ArkPalette.ink }
    static func iconAlpha(sleeping: Bool) -> CGFloat { sleeping ? 0.8 : 1 }
}

/// A Space's icon: its emoji when it has one, otherwise its tinted symbol.
@MainActor enum ArkSpaceIcon {
    static func draw(_ space: (emoji: String?, symbol: String, tint: NSColor), in rect: NSRect, opacity: CGFloat = 1) {
        if let emoji = space.emoji {
            let font = NSFont.systemFont(ofSize: rect.height * 0.86)
            let string = NSAttributedString(string: emoji, attributes: [.font: font])
            let size = string.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(opacity)
            string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        } else {
            SidebarSymbol.draw(named: space.symbol, in: rect, color: space.tint, pointSize: rect.height, opacity: opacity)
        }
    }
    static func image(for space: BrowserSpace, pointSize: CGFloat) -> NSImage? {
        guard let emoji = space.emoji else {
            return SidebarSymbol.image(named: space.symbol, color: ArkPalette.spaceTint(space.colorIndex), pointSize: pointSize)
        }
        let side = pointSize + 4
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw((emoji, space.symbol, .labelColor), in: rect); return true
        }
    }
}

@MainActor
private func arkLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = ArkPalette.ink
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor
private class ArkFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private class ArkHoverButton: NSButton {
    override var isEnabled: Bool {
        didSet { if oldValue != isEnabled { window?.invalidateCursorRects(for: self) } }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    var handler: (() -> Void)?
    var hovered = false
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        focusRingType = .exterior
        target = self
        action = #selector(performHandler)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill() }
    @objc private func performHandler() { handler?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func fill(_ color: NSColor, radius: CGFloat = 8) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).fill()
    }
    func symbol(_ name: String, rect: NSRect, color: NSColor, size: CGFloat = 14) {
        SidebarSymbol.draw(named: name, in: rect, color: color, pointSize: size,
                           opacity: isEnabled ? 1 : 0.32)
    }
    func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? ArkPalette.ink, .paragraphStyle: paragraph])
    }
}

@MainActor
private final class ArkIconButton: ArkHoverButton {
    private var symbolName: String
    private let glyphSize: CGFloat
    init(symbol: String, label: String, glyphSize: CGFloat = 16) {
        symbolName = symbol; self.glyphSize = glyphSize
        super.init(frame: .zero)
        toolTip = label
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSymbol(_ symbol: String, label: String) {
        symbolName = symbol
        toolTip = label
        setAccessibilityLabel(label)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if (hovered || isHighlighted) && isEnabled { fill(isHighlighted ? ArkPalette.pressed : ArkPalette.iconHover, radius: 7) }
        symbol(symbolName, rect: NSRect(x: (bounds.width - glyphSize) / 2, y: (bounds.height - glyphSize) / 2, width: glyphSize, height: glyphSize), color: ArkPalette.ink, size: glyphSize)
    }
}

@MainActor private final class ArkExtensionLibraryButton: ArkHoverButton {
    init() {
        super.init(frame: .zero)
        toolTip = "Find and install extensions"; setAccessibilityLabel("Add extensions")
    }
    required init?(coder: NSCoder) { fatalError() }
    // A quiet icon at the address field's trailing edge, like Arc's toolbar
    // extension affordance; the full library opens on click.
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted { fill(isHighlighted ? ArkPalette.pressed : ArkPalette.iconHover, radius: 7) }
        symbol("puzzlepiece.extension", rect: NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14),
               color: hovered ? ArkPalette.ink : ArkPalette.secondary, size: 14)
    }
}

@MainActor private final class ArkExtensionButton: ArkHoverButton {
    private(set) var item: SidebarExtensionItem
    init(item: SidebarExtensionItem) { self.item = item; super.init(frame: .zero); configure(item) }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ item: SidebarExtensionItem) {
        self.item = item; isEnabled = item.isEnabled
        identifier = NSUserInterfaceItemIdentifier("extension-action-\(item.id.uuidString)")
        toolTip = item.label.isEmpty || item.label == item.name ? item.name : "\(item.name) — \(item.label)"
        setAccessibilityLabel(item.name)
        setAccessibilityHelp(item.label.isEmpty ? "Open extension" : item.label)
        setAccessibilityValue(item.badge.isEmpty ? nil : item.badge)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if (hovered || isHighlighted) && isEnabled { fill(isHighlighted ? ArkPalette.pressed : ArkPalette.iconHover, radius: 7) }
        let rect = bounds.insetBy(dx: 6, dy: 6)
        if let icon = item.icon {
            icon.draw(in: SidebarSymbol.fittedRect(imageSize: icon.size, in: rect), from: .zero,
                operation: .sourceOver, fraction: isEnabled ? 1 : 0.32, respectFlipped: true, hints: nil)
        } else { symbol("puzzlepiece.extension.fill", rect: rect, color: ArkPalette.ink, size: 20) }
        if !item.badge.isEmpty {
            let badge = String(item.badge.prefix(3))
            let width: CGFloat = badge.count > 1 ? 20 : 13
            let badgeRect = NSRect(x: bounds.maxX - width, y: 0, width: width, height: 13)
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
            text(badge, rect: badgeRect.offsetBy(dx: 0, dy: -0.5), size: 9, weight: .semibold, color: .white, alignment: .center)
        }
    }
}

@MainActor private final class ArkSearchButton: ArkHoverButton {
    var address = "Search or enter URL" { didSet { needsDisplay = true } }
    /// Room kept clear at the trailing edge for the extension control.
    var trailingInset: CGFloat = 12 { didSet { if oldValue != trailingInset { needsDisplay = true } } }
    init() {
        super.init(frame: .zero); setAccessibilityLabel("Search or enter a web address"); hint()
        NotificationCenter.default.addObserver(self, selector: #selector(hint), name: ShortcutStore.didChange, object: nil)
    }
    @objc private func hint() { toolTip = "Search or enter address (\(ShortcutStore.shared.combo(for: .openLocation).compact))" }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        // A lifted, translucent field like Arc/Yab rather than a dark well.
        fill(hovered || isHighlighted ? ArkPalette.fieldHover : ArkPalette.field, radius: 10)
        text(address, rect: NSRect(x: 12, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 12 - trailingInset), height: 18),
             size: 13.5, color: ArkPalette.ink.withAlphaComponent(0.92))
    }
}

@MainActor
private final class ArkFavoriteButton: ArkHoverButton {
    private(set) var item: SidebarTabItem
    var close: (() -> Void)?
    var keep: (() -> Void)?
    var favorite: (() -> Void)?
    var editSaved: (() -> Void)?
    var resetSaved: (() -> Void)?
    var reorderSaved: ((Int) -> Void)?
    private var canMoveEarlier = false
    private var canMoveLater = false
    init(item: SidebarTabItem) {
        self.item = item
        super.init(frame: .zero)
        configure(item, canMoveEarlier: false, canMoveLater: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setFavicon(_ favicon: NSImage?) {
        guard image !== favicon else { return }
        image = favicon
        needsDisplay = true
    }
    func configure(_ item: SidebarTabItem, canMoveEarlier: Bool, canMoveLater: Bool) {
        self.item = item; self.canMoveEarlier = canMoveEarlier; self.canMoveLater = canMoveLater
        identifier = NSUserInterfaceItemIdentifier("favorite-\(item.id.uuidString)")
        setAccessibilityLabel(item.title.isEmpty ? "Favorite" : item.title)
        setAccessibilityValue([item.isActive ? "Selected" : nil, item.isUnloaded ? "Unloaded" : item.isSleeping ? "Sleeping" : nil].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityHelp("Favorite shared by all Spaces. \(item.isUnloaded ? "Select to open its saved page." : "Select to show its page.")")
        toolTip = [item.title, item.subtitle, item.isUnloaded ? "Unloaded — opens saved page" : item.isSleeping ? "Sleeping — reloads when selected" : "Favorite"].filter { !$0.isEmpty }.joined(separator: "\n")
        needsDisplay = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        fill(item.isActive ? ArkPalette.tileActive : hovered ? ArkPalette.tileHover : ArkPalette.tile, radius: 10)
        if item.isActive {
            ArkPalette.tileRing.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
            ring.lineWidth = 1; ring.stroke()
        }
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(20 / image.size.width, 20 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                       fraction: ArkRowInk.iconAlpha(sleeping: item.isSleeping), respectFlipped: true, hints: nil)
        } else {
            symbol(item.symbol, rect: NSRect(x: (bounds.width - 19) / 2, y: (bounds.height - 19) / 2, width: 19, height: 19),
                   color: ArkPalette.ink.withAlphaComponent(ArkRowInk.iconAlpha(sleeping: item.isSleeping)), size: 18)
        }
        // Only pages put to sleep to save memory get the moon; a saved
        // Favorite that simply hasn't been opened yet looks like any other.
        if item.isSleeping {
            symbol("moon", rect: NSRect(x: bounds.width - 13, y: bounds.height - 13, width: 8, height: 8), color: ArkPalette.secondary, size: 8)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
        }
        add("Remove from Favorites", #selector(favoriteFromMenu))
        add("Keep Tab", #selector(keepFromMenu))
        menu.addItem(.separator())
        add("Edit Saved Tab…", #selector(editFromMenu))
        add("Reset to Saved Page", #selector(resetFromMenu))
        add("Move Earlier", #selector(earlierFromMenu), enabled: canMoveEarlier)
        add("Move Later", #selector(laterFromMenu), enabled: canMoveLater)
        menu.addItem(.separator())
        add("Unload Favorite", #selector(closeFromMenu), enabled: !item.isUnloaded)
        return menu
    }
    @objc private func favoriteFromMenu() { favorite?() }
    @objc private func keepFromMenu() { keep?() }
    @objc private func editFromMenu() { editSaved?() }
    @objc private func resetFromMenu() { resetSaved?() }
    @objc private func earlierFromMenu() { reorderSaved?(-1) }
    @objc private func laterFromMenu() { reorderSaved?(1) }
    @objc private func closeFromMenu() { close?() }
}

@MainActor
private final class ArkNewTabButton: ArkHoverButton {
    init() {
        super.init(frame: .zero); setAccessibilityLabel("New tab"); hint()
        NotificationCenter.default.addObserver(self, selector: #selector(hint), name: ShortcutStore.didChange, object: nil)
    }
    @objc private func hint() { toolTip = "New tab (\(ShortcutStore.shared.combo(for: .newTab).compact))" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(ArkPalette.hover, radius: ArkMetrics.rowRadius) }
        symbol("plus", rect: NSRect(x: 10, y: (bounds.height - 15) / 2, width: 15, height: 15), color: ArkPalette.secondary, size: 15)
        text("New Tab", rect: NSRect(x: 36, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 48), height: 18),
             size: ArkType.rowSize, color: ArkPalette.secondary)
    }
}

@MainActor
private final class ArkSpaceButton: ArkHoverButton {
    let index: Int
    private var name = ""
    private var symbolName = "globe"
    private var emoji: String?
    private var tint = ArkPalette.ink
    var manage: (() -> Void)?
    /// A dragged tab or folder dropped here moves to this Space.
    var acceptDrop: ((UUID) -> Bool)?
    private var dropHovered = false { didSet { if oldValue != dropHovered { needsDisplay = true } } }
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "Selected" : "Not selected") } }
    init(space: BrowserSpace) {
        index = space.id
        super.init(frame: .zero)
        registerForDraggedTypes([.bamSidebarRow])
        configure(space)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // The current Space is not a destination; rows reorder in the list instead.
        guard !selected, sender.draggingPasteboard.string(forType: .bamSidebarRow) != nil else { return [] }
        dropHovered = true; return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHovered = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHovered = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHovered = false
        guard let raw = sender.draggingPasteboard.string(forType: .bamSidebarRow), let id = UUID(uuidString: raw) else { return false }
        return acceptDrop?(id) ?? false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ space: BrowserSpace) {
        name = space.name; symbolName = space.symbol; emoji = space.emoji; tint = ArkPalette.spaceTint(space.colorIndex)
        setAccessibilityLabel("Switch to \(name) space")
        toolTip = name
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered || dropHovered { fill(selected || dropHovered ? ArkPalette.selection : ArkPalette.hover, radius: 7) }
        if dropHovered {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7); ring.lineWidth = 1.5; ring.stroke()
        }
        // Unselected Spaces recede, as Arc's footer dots do.
        let size: CGFloat = emoji == nil ? 16 : 15
        ArkSpaceIcon.draw((emoji, symbolName, tint), in: NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size),
                          opacity: selected || hovered || dropHovered ? 1 : 0.62)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Manage Spaces…", action: #selector(manageFromMenu), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
    @objc private func manageFromMenu() { manage?() }
}

@MainActor
private final class ArkSpaceHeading: ArkHoverButton {
    private var name = "Studio"
    private var symbolName = "sparkles"
    private var emoji: String?
    private var tint = ArkPalette.ink
    init() { super.init(frame: .zero); toolTip = "Manage Spaces" }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ space: BrowserSpace) {
        name = space.name; symbolName = space.symbol; emoji = space.emoji; tint = ArkPalette.spaceTint(space.colorIndex)
        setAccessibilityLabel("Manage Spaces — \(name)")
        needsDisplay = true
    }
    // Arc and Yab label the Space quietly above its rows: a small icon and a
    // muted semibold name, aligned with the row icons below.
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(ArkPalette.hover, radius: 7) }
        let iconSize: CGFloat = emoji == nil ? 15 : 14
        ArkSpaceIcon.draw((emoji, symbolName, tint), in: NSRect(x: 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize))
        text(name, rect: NSRect(x: 28, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 46), height: 18),
             size: 13, weight: .semibold, color: ArkPalette.secondary)
        if hovered { symbol("chevron.down", rect: NSRect(x: bounds.width - 15, y: (bounds.height - 10) / 2, width: 10, height: 10), color: ArkPalette.secondary, size: 10) }
    }
}

@MainActor
private final class ArkTabRow: ArkFlippedView, NSDraggingSource {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
    private(set) var item: SidebarTabItem
    var select: (() -> Void)?
    var close: (() -> Void)?
    var pin: (() -> Void)?
    var move: ((Int) -> Void)?
    var favorite: (() -> Void)?
    var editSaved: (() -> Void)?
    var resetSaved: (() -> Void)?
    var reorderSaved: ((Int) -> Void)?
    var toggleFolder: (() -> Void)?
    var renameFolder: (() -> Void)?
    var newFolder: (() -> Void)?
    var ungroupFolder: (() -> Void)?
    var moveToFolder: ((UUID?) -> Void)?
    var folderTargets: (() -> [SidebarFolderTarget])?
    /// Moves keyboard focus to the neighboring row; returns whether it moved.
    var arrow: ((Int) -> Bool)?
    /// Called with the pressed row's ID just before a drag session starts; false cancels it.
    var willBeginDrag: ((UUID) -> Bool)?
    var focusParent: (() -> Bool)?
    var escape: (() -> Void)?
    var canMoveEarlier = false
    var canMoveLater = false
    /// The deepest row in this list; sets one indent step for every row.
    var listMaxDepth = 0 { didSet { if oldValue != listMaxDepth { needsLayout = true } } }
    private var currentSpace = 0
    private var destinations: [BrowserSpace] = []
    private var spaceTint = ArkPalette.spaceTint(0)
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let iconView = NSImageView()
    /// Folders show a small disclosure chevron at the trailing edge.
    private let chevronView = NSImageView()
    private var favicon: NSImage?
    private let closeButton = ArkIconButton(symbol: "xmark", label: "Close tab", glyphSize: 12)
    private var hovered = false
    private var area: NSTrackingArea?
    private var configured = false
    private var dragOrigin: NSPoint?
    /// The row identity captured at mouse-down; a drag only ever carries this ID.
    private var pressedID: UUID?
    private var didDrag = false
    init(item: SidebarTabItem) {
        self.item = item
        titleLabel = arkLabel(item.title.isEmpty ? "New Tab" : item.title, size: ArkType.rowSize, weight: item.isActive ? .medium : .regular)
        subtitleLabel = arkLabel(item.subtitle, size: 9, weight: .regular)
        super.init(frame: .zero)
        wantsLayer = true
        subtitleLabel.textColor = ArkPalette.secondary.withAlphaComponent(0.84)
        iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = item.isActive ? spaceTint : ArkPalette.secondary
        for view in [titleLabel, subtitleLabel, iconView, chevronView, closeButton] as [NSView] { addSubview(view) }
        closeButton.isHidden = !item.isActive
        closeButton.handler = { [weak self] in self?.close?() }
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevronView.contentTintColor = ArkPalette.secondary; chevronView.isHidden = true
        chevronView.identifier = NSUserInterfaceItemIdentifier("folder-chevron")
        // The row is one accessible control; its label and icons are not separate elements.
        for view in [titleLabel, subtitleLabel, iconView, chevronView] as [NSView] { view.setAccessibilityElement(false) }
        // A plain NSView is not an accessibility element by default; without
        // this, assistive tech sees only the table cell's raw subviews.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityValue(item.isActive ? "Selected" : "")
        update(item)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ newItem: SidebarTabItem) {
        let old = item, first = !configured
        guard first || old != newItem else { return }
        item = newItem; configured = true
        if first || old.id != item.id {
            hovered = false; closeButton.hovered = false
            identifier = NSUserInterfaceItemIdentifier("tab-row-\(item.id.uuidString)")
            // Reused for another row mid-press: abandon that press and any drag it began.
            dragOrigin = nil; pressedID = nil; didDrag = false
        }
        if first || old.title != item.title || old.isFolder != item.isFolder {
            // Assistive tech hears exactly what the row shows, including the blank-title fallback.
            titleLabel.stringValue = item.title.isEmpty ? (item.isFolder ? "Folder" : "New Tab") : item.title
            setAccessibilityLabel(titleLabel.stringValue)
        }
        if first || old.isActive != item.isActive || old.isFolder != item.isFolder { titleLabel.font = ArkType.rowFont(active: item.isActive, folder: item.isFolder) }
        if first || old.depth != item.depth || old.isFolder != item.isFolder { needsLayout = true }
        if first || old.isUnloaded != item.isUnloaded || old.isSleeping != item.isSleeping {
            titleLabel.textColor = ArkRowInk.title(sleeping: item.isSleeping)
            iconView.alphaValue = ArkRowInk.iconAlpha(sleeping: item.isSleeping)
        }
        if first || old.subtitle != item.subtitle { subtitleLabel.stringValue = item.subtitle }
        if item.isFolder {
            if first || !old.isFolder || old.isExpanded != item.isExpanded { favicon = nil; iconView.image = NSImage(systemSymbolName: item.isExpanded ? "folder" : "folder.fill", accessibilityDescription: nil); iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular) }
        } else if favicon == nil, first || old.symbol != item.symbol || old.isFolder { iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) }
        if first || old.isActive != item.isActive || old.isFolder != item.isFolder { applyIconTint() }
        if first || old.isSplit != item.isSplit || old.isPinned != item.isPinned || old.isFolder != item.isFolder {
            closeButton.setSymbol("xmark", label: item.isSplit ? "Close Split" : item.isPinned ? "Unload tab" : "Close tab")
            closeButton.setAccessibilityHelp(item.isSplit ? "Saved panes unload and remain in the sidebar; ordinary panes close." : nil)
            setAccessibilityHelp(item.isSplit ? "Split. Closing unloads saved panes and keeps their saved tabs; ordinary panes close." : item.isPinned ? "Kept tab. Closing unloads its page and keeps the saved tab." : "Tab")
        }
        updateTrailingControls()
        if item.isFolder, first || !old.isFolder || old.isExpanded != item.isExpanded {
            chevronView.image = NSImage(systemSymbolName: item.isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        }
        setAccessibilityDisclosureLevel(item.depth)
        // Recycled cells must not keep a folder's disclosure state.
        setAccessibilityDisclosed(item.isFolder && item.isExpanded)
        setAccessibilityExpanded(item.isFolder && item.isExpanded)
        if first || old.isFolder != item.isFolder {
            setAccessibilityRole(item.isFolder ? .disclosureTriangle : .button)
            setAccessibilityRoleDescription(item.isFolder ? "folder" : nil)
        }
        if item.isFolder {
            // Disclosure controls report 1 when open and 0 when closed.
            setAccessibilityValue(NSNumber(value: item.isExpanded ? 1 : 0))
            setAccessibilityHelp("Folder with \(item.folderTabCount) tab\(item.folderTabCount == 1 ? "" : "s"). Press to \(item.isExpanded ? "collapse" : "expand").")
        } else if first || old.isActive != item.isActive || old.isUnloaded != item.isUnloaded || old.isSleeping != item.isSleeping || old.isFolder {
            setAccessibilityValue([item.isActive ? "Selected" : nil, item.isUnloaded ? "Unloaded" : item.isSleeping ? "Sleeping" : nil].compactMap { $0 }.joined(separator: ", "))
        }
        if first || old.title != item.title || old.subtitle != item.subtitle || old.isUnloaded != item.isUnloaded || old.isSleeping != item.isSleeping {
            toolTip = [item.title, item.subtitle, item.isUnloaded ? "Unloaded — opens saved page" : item.isSleeping ? "Sleeping — reloads when selected" : ""].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        needsDisplay = true
    }
    func setFavicon(_ image: NSImage?) {
        if item.isFolder { return }
        if favicon !== image {
            favicon = image
            iconView.image = image ?? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            iconView.symbolConfiguration = image == nil ? NSImage.SymbolConfiguration(pointSize: 16, weight: .regular) : nil
            iconView.identifier = image == nil ? nil : NSUserInterfaceItemIdentifier("website-favicon")
        }
        applyIconTint()
    }
    private func applyIconTint() {
        if item.isFolder { iconView.contentTintColor = ArkPalette.secondary; return }
        iconView.contentTintColor = favicon == nil ? (item.isActive ? spaceTint : ArkPalette.secondary) : nil
    }
    func configureSpace(id: Int, tint: NSColor, destinations: [BrowserSpace]) {
        guard currentSpace != id || !spaceTint.isEqual(tint) || self.destinations != destinations else { return }
        currentSpace = id; spaceTint = tint; self.destinations = destinations
        applyIconTint()
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        // Return/Enter/Space open a tab or toggle a folder; →/← open and close
        // folders; ← elsewhere goes to the containing folder; Esc returns to the page.
        if [36, 76, 49].contains(event.keyCode) { activate() }
        else if item.isFolder, event.keyCode == 124, !item.isExpanded { toggleFolder?() }
        else if item.isFolder, event.keyCode == 123, item.isExpanded { toggleFolder?() }
        else if event.keyCode == 123, focusParent?() == true {}
        // Up/Down are always handled here: at the first or last row they do
        // nothing rather than reaching the table's own selection (which opens tabs).
        else if event.keyCode == 125 { _ = arrow?(1) }
        else if event.keyCode == 126 { _ = arrow?(-1) }
        else if event.keyCode == 53, let escape { escape() }
        else { super.keyDown(with: event) }
    }
    override func layout() {
        super.layout()
        let frames = ArkRowLayout(width: bounds.width, height: bounds.height, depth: item.depth, listMaxDepth: listMaxDepth,
                                  isFolder: item.isFolder, showsClose: !closeButton.isHidden)
        iconView.frame = frames.icon
        titleLabel.frame = frames.title
        subtitleLabel.frame = NSRect(x: frames.title.minX + 1, y: 23, width: frames.title.width, height: 12)
        subtitleLabel.isHidden = true
        closeButton.frame = frames.close
        chevronView.frame = frames.chevron
    }
    /// The close button shows on the selected or hovered tab; the title takes
    /// its room back whenever it is hidden.
    private func updateTrailingControls() {
        // The title's end depends on both trailing controls, so a change to
        // either (including a reused cell switching tab ↔ folder) re-lays out.
        let hidden = item.isFolder || item.isUnloaded || (!hovered && !item.isActive)
        if closeButton.isHidden != hidden { closeButton.isHidden = hidden; needsLayout = true }
        if chevronView.isHidden != !item.isFolder { chevronView.isHidden = !item.isFolder; needsLayout = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8); ring.lineWidth = 2; ring.stroke()
        }
        // Arc/Yab selection: one soft lifted pill, no outline; hover is fainter.
        let selected = item.isActive && !item.isFolder
        let light = !effectiveAppearance.isDarkChrome
        if selected || hovered {
            NSGraphicsContext.saveGraphicsState()
            if selected && light {
                // On light chrome the selected tab is a white card with a soft shadow, as in Yab/Arc.
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(white: 0, alpha: 0.10); shadow.shadowBlurRadius = 2.5
                shadow.shadowOffset = NSSize(width: 0, height: -0.5); shadow.set()
            }
            (selected ? ArkPalette.selection : ArkPalette.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: light && selected ? 1.5 : 0.5, dy: light && selected ? 1.5 : 0.5),
                         xRadius: ArkMetrics.rowRadius, yRadius: ArkMetrics.rowRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if selected && !light {
            ArkPalette.selectionEdge.setFill()
            NSRect(x: ArkMetrics.rowRadius, y: 0.5, width: max(0, bounds.width - 2 * ArkMetrics.rowRadius), height: 0.5).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateTrailingControls(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; updateTrailingControls(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Labels and symbols belong to the row's selection target; the close
        // button keeps its own native control hit target.
        return hit === closeButton ? closeButton : self
    }
    private func activate() { if item.isFolder { toggleFolder?() } else { select?() } }
    override func mouseDown(with event: NSEvent) {
        // Nothing opens on mouse-down: a tab is selected (and a dormant one
        // woken) or a folder toggled only on mouse-up without a drag, so
        // dragging never selects or wakes anything. The pressed identity is
        // captured now in case the view is reused before release.
        dragOrigin = convert(event.locationInWindow, from: nil); didDrag = false; pressedID = item.id
        if item.isFolder { window?.makeFirstResponder(self) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, !didDrag, let source = pressedID, source == item.id else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
        didDrag = true
        guard willBeginDrag?(source) ?? true else { return }
        let payload = NSPasteboardItem()
        payload.setString(source.uuidString, forType: .bamSidebarRow)
        let dragItem = NSDraggingItem(pasteboardWriter: payload)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        session.draggingFormation = .none
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; pressedID = nil }
        guard dragOrigin != nil, !didDrag, pressedID == item.id else { return }
        activate()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    /// The row as it looks now, lifted slightly, for the drag image.
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep); image.addRepresentation(rep)
        }
        return image
    }
    override func accessibilityPerformPress() -> Bool { activate(); return true }
    private func folderSubmenu() -> NSMenuItem {
        let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to Folder"); submenu.autoenablesItems = false
        for target in folderTargets?() ?? [] {
            let entry = NSMenuItem(title: target.name, action: #selector(moveToFolderFromMenu(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = target.id; entry.isEnabled = target.isEnabled
            entry.indentationLevel = min(8, target.depth)
            entry.image = NSImage(systemSymbolName: target.id == nil ? "sidebar.left" : "folder", accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        moveItem.submenu = submenu
        moveItem.isEnabled = submenu.items.contains(where: \.isEnabled)
        return moveItem
    }
    private func folderMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ symbol: String?, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled
            entry.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        add(item.isExpanded ? "Collapse Folder" : "Expand Folder", #selector(toggleFromMenu), item.isExpanded ? "chevron.up" : "chevron.down")
        add("Rename Folder…", #selector(renameFromMenu), "pencil")
        add("New Folder Inside", #selector(newFolderFromMenu), "folder.badge.plus", enabled: item.canNestFolder)
        if !item.canNestFolder { menu.items.last?.toolTip = "Folders can nest \(BrowserSession.maximumFolderDepth) levels deep." }
        menu.addItem(.separator())
        add("Move Earlier", #selector(earlierFromMenu), nil, enabled: canMoveEarlier)
        add("Move Later", #selector(laterFromMenu), nil, enabled: canMoveLater)
        menu.addItem(folderSubmenu())
        if destinations.count > 1 { menu.addItem(spaceSubmenu()) }
        menu.addItem(.separator())
        add("Ungroup Folder", #selector(ungroupFromMenu), "folder.badge.minus")
        menu.items.last?.toolTip = "Removes the folder and keeps its tabs in its place."
        return menu
    }
    private func spaceSubmenu() -> NSMenuItem {
        let moveItem = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Move to Space"); submenu.autoenablesItems = false
        for space in destinations {
            let destination = NSMenuItem(title: space.name, action: #selector(moveFromMenu(_:)), keyEquivalent: "")
            destination.target = self; destination.tag = space.id
            destination.state = space.id == currentSpace ? .on : .off
            destination.isEnabled = space.id != currentSpace && move != nil
            destination.image = ArkSpaceIcon.image(for: space, pointSize: 14)
            submenu.addItem(destination)
        }
        moveItem.submenu = submenu
        return moveItem
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if item.isFolder { return folderMenu() }
        let menu = NSMenu(); menu.autoenablesItems = false
        let keepTitle = item.isSplit ? (item.isPinned ? "Unkeep Left Tab" : "Keep Left Tab") : (item.isPinned ? "Unkeep Tab" : "Keep Tab")
        let pinItem = NSMenuItem(title: keepTitle, action: #selector(pinFromMenu), keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: item.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.target = self; menu.addItem(pinItem)
        let favoriteItem = NSMenuItem(title: "Add to Favorites", action: #selector(favoriteFromMenu), keyEquivalent: "")
        favoriteItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        favoriteItem.target = self; favoriteItem.isEnabled = item.canFavorite && !item.isSplit
        menu.addItem(favoriteItem)
        if item.isPinned {
            for (title, action, enabled) in [
                (item.isSplit ? "Edit Left Saved Tab…" : "Edit Saved Tab…", #selector(editFromMenu), true),
                (item.isSplit ? "Reset Left Saved Page" : "Reset to Saved Page", #selector(resetFromMenu), true),
                ("Move Earlier", #selector(earlierFromMenu), canMoveEarlier),
                ("Move Later", #selector(laterFromMenu), canMoveLater)
            ] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        let newFolder = NSMenuItem(title: "Add to New Folder", action: #selector(newFolderFromMenu), keyEquivalent: "")
        newFolder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        newFolder.target = self; newFolder.isEnabled = item.canWrapInFolder; menu.addItem(newFolder)
        if !item.canWrapInFolder { newFolder.toolTip = "This page can’t be kept, so it can’t go in a folder." }
        menu.addItem(folderSubmenu())
        if item.parentFolderID != nil {
            let out = NSMenuItem(title: "Remove from Folder", action: #selector(removeFromFolderFromMenu), keyEquivalent: "")
            out.target = self; menu.addItem(out)
        }
        if destinations.count > 1 { menu.addItem(spaceSubmenu()) }
        menu.addItem(.separator())
        let closeItem = NSMenuItem(title: item.isSplit ? "Close Split" : item.isPinned ? "Unload Tab" : "Close Tab", action: #selector(closeFromMenu), keyEquivalent: "")
        closeItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeItem.target = self; closeItem.isEnabled = !item.isPinned || !item.isUnloaded
        closeItem.toolTip = item.isSplit ? "Saved panes unload and remain in the sidebar; ordinary panes close." : nil
        menu.addItem(closeItem)
        return menu
    }
    @objc private func moveFromMenu(_ sender: NSMenuItem) { move?(sender.tag) }
    @objc private func pinFromMenu() { pin?() }
    @objc private func favoriteFromMenu() { favorite?() }
    @objc private func editFromMenu() { editSaved?() }
    @objc private func resetFromMenu() { resetSaved?() }
    @objc private func earlierFromMenu() { reorderSaved?(-1) }
    @objc private func laterFromMenu() { reorderSaved?(1) }
    @objc private func closeFromMenu() { close?() }
    @objc private func toggleFromMenu() { toggleFolder?() }
    @objc private func renameFromMenu() { renameFolder?() }
    @objc private func newFolderFromMenu() { newFolder?() }
    @objc private func ungroupFromMenu() { ungroupFolder?() }
    @objc private func removeFromFolderFromMenu() { moveToFolder?(nil) }
    @objc private func moveToFolderFromMenu(_ sender: NSMenuItem) { moveToFolder?(sender.representedObject as? UUID) }
}

/// An original animation of a system symbol, drawn natively without image frames.
@MainActor private final class ArkSpacesButton: ArkHoverButton {
    private let hoverAnimator = SpringAnimator()
    private let selectionAnimator = SpringAnimator()
    private var hoverAmount: CGFloat = 0
    private var selectionPulse: CGFloat = 0

    init() {
        super.init(frame: .zero)
        toolTip = "Manage Spaces — add, rename and reorder"
        setAccessibilityLabel("Manage Spaces")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        animateHover(to: 1)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        animateHover(to: 0)
    }
    private func animateHover(to value: CGFloat) {
        hoverAnimator.animate(from: hoverAmount, to: value, response: 0.24, dampingRatio: 0.90) { [weak self] value in
            self?.hoverAmount = value
            self?.needsDisplay = true
        }
    }
    func playSelection() {
        // A bounded impulse gives each space change a brief tilt and scale pulse.
        // Repeated selections replace the existing animation; no callbacks queue.
        selectionAnimator.animate(from: selectionPulse, to: 0, response: 0.36,
                                  dampingRatio: 0.62, initialVelocity: 18) { [weak self] value in
            self?.selectionPulse = value
            self?.needsDisplay = true
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverAnimator.stop(); selectionAnimator.stop()
            hoverAmount = 0; selectionPulse = 0; hovered = false
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(ArkPalette.iconHover, radius: 7) }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hover: CGFloat = reduced ? 0 : min(1, max(0, hoverAmount))
        let pulse: CGFloat = reduced ? 0 : min(1, max(-0.2, selectionPulse))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY - hover)
        transform.rotate(byDegrees: -8 * hover + 16 * pulse)
        transform.scale(by: 1 + 0.08 * hover + 0.12 * pulse)
        transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
        transform.concat()
        symbol("square.stack.3d.up", rect: bounds.insetBy(dx: 4, dy: 4),
               color: ArkPalette.ink, size: 18)
        NSGraphicsContext.restoreGraphicsState()
    }
    deinit { hoverAnimator.stop(); selectionAnimator.stop() }
}
