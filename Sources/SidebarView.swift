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
}

/// Shared Favorites and chrome stay fixed while each Space's heading and rows page.
@MainActor final class SidebarView: NSView {
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
    var onSpaceScroll: ((NSEvent, SpaceScrollSource) -> Bool)?
    override var isFlipped: Bool { true }
    private let back = ArkIconButton(symbol: "arrow.left", label: "Go back")
    private let forward = ArkIconButton(symbol: "arrow.right", label: "Go forward")
    private let reload = ArkIconButton(symbol: "arrow.clockwise", label: "Reload page")
    private let toggle = ArkIconButton(symbol: "sidebar.left", label: "Hide sidebar")
    private let search = ArkSearchButton()
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
        [toggle, back, forward, reload, search, favoritesHost, clip, library, plus, pip, spaceOverflow].forEach(addSubview)
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
            $0.id == $1.id && $0.name == $1.name && $0.symbol == $1.symbol && $0.colorIndex == $1.colorIndex
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
            item.image = SidebarSymbol.image(named: definition.symbol, color: ArkPalette.spaceColor(definition.colorIndex), pointSize: 14)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Spaces…", action: #selector(manageSpacesFromMenu), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: spaceOverflow.bounds.maxY), in: spaceOverflow)
    }
    @objc private func chooseSpaceFromMenu(_ sender: NSMenuItem) { onSpaceChange?(sender.tag) }
    @objc private func manageSpacesFromMenu() { onManageSpaces?() }

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
        search.frame = NSRect(x: 8, y: 46, width: max(0, w - 16), height: 36)
        // Four 47-point tiles fit the normal 228-point sidebar. Keep three
        // columns at narrow widths (44-point tiles at the 164-point minimum)
        // so twelve Favorites still leave room for the scrolling tab list.
        let columns = w >= 224 ? 4 : 3
        let favoriteRows = (favorites.count + columns - 1) / columns
        let favoriteHeight = favoriteRows == 0 ? CGFloat.zero : CGFloat(favoriteRows) * 47 + CGFloat(favoriteRows - 1) * 8
        favoritesHost.isHidden = favorites.isEmpty
        favoritesHost.frame = NSRect(x: 0, y: 92, width: w, height: favoriteHeight)
        let tileWidth = max(0, (w - 16 - CGFloat(columns - 1) * 8) / CGFloat(columns))
        for (index, button) in favorites.enumerated() {
            button.frame = NSRect(x: 8 + CGFloat(index % columns) * (tileWidth + 8),
                                  y: CGFloat(index / columns) * 55, width: tileWidth, height: 47)
        }
        let pageTop: CGFloat = 92 + favoriteHeight + (favorites.isEmpty ? 0 : 8)
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
    var select: ((UUID)->Void)?; var close: ((UUID)->Void)?; var pin: ((UUID)->Void)?; var newTab: (()->Void)?
    var manageSpaces: (() -> Void)?
    var move: ((UUID, Int) -> Void)?
    var favorite: ((UUID) -> Void)?
    var editSaved: ((UUID) -> Void)?
    var resetSaved: ((UUID) -> Void)?
    var reorderSaved: ((UUID, Int) -> Void)?
    let heading = ArkSpaceHeading()
    let scroll = SidebarScrollView()
    private let table = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tabs"))
    private enum Entry { case tab(Int), divider, newTab }
    private var entries: [Entry] = []
    private var rowByID: [UUID: Int] = [:]
    private var keptFirst: UUID?
    private var keptLast: UUID?
    private var spaceAppearance: BrowserSpace?
    private var destinations: [BrowserSpace] = []
    private var synchronizingSelection = false
    private(set) var tabs: [SidebarTabItem] = []

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
        table.allowsMultipleSelection = false; table.allowsColumnSelection = false
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.dataSource = self; table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-list")
        scroll.documentView = table
        heading.handler = { [weak self] in self?.manageSpaces?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ items: [SidebarTabItem], space: BrowserSpace, destinations: [BrowserSpace]) {
        let items = items.filter { !$0.isFavorite }
        let structureChanged = tabs.count != items.count || zip(tabs, items).contains {
            $0.id != $1.id || $0.isPinned != $1.isPinned
        }
        let changed = structureChanged ? [] : items.indices.filter { tabs[$0] != items[$0] }
        let origin = scroll.contentView.bounds.origin
        tabs = items
        configureAppearance(space: space, destinations: destinations)
        if structureChanged || entries.isEmpty {
            entries = []; rowByID = [:]
            let kept = tabs.indices.filter { tabs[$0].isPinned }
            keptFirst = kept.first.map { tabs[$0].id }; keptLast = kept.last.map { tabs[$0].id }
            for index in kept { rowByID[tabs[index].id] = entries.count; entries.append(.tab(index)) }
            if !kept.isEmpty { entries.append(.divider) }
            entries.append(.newTab)
            for index in tabs.indices where !tabs[index].isPinned {
                rowByID[tabs[index].id] = entries.count; entries.append(.tab(index))
            }
            synchronizingSelection = true
            table.reloadData()
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

    func configureAppearance(space: BrowserSpace, destinations: [BrowserSpace]) {
        guard spaceAppearance != space || self.destinations != destinations else { return }
        spaceAppearance = space; self.destinations = destinations
        identifier = NSUserInterfaceItemIdentifier("sidebar-space-\(space.id)")
        heading.configure(space)
        table.setAccessibilityLabel("Tabs in \(space.name)")
        let tint = ArkPalette.spaceColor(space.colorIndex)
        table.enumerateAvailableRowViews { [weak self] _, index in
            guard let self, let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarTabCell else { return }
            cell.row.configureSpace(id: space.id, tint: tint, destinations: destinations)
        }
    }

    private func configure(_ cell: SidebarTabCell, item: SidebarTabItem) {
        let row = cell.row
        if row.item.id != item.id, let focused = window?.firstResponder as? NSView,
           focused === row || focused.isDescendant(of: row) { window?.makeFirstResponder(table) }
        row.update(item)
        if let spaceAppearance { row.configureSpace(id: spaceAppearance.id, tint: ArkPalette.spaceColor(spaceAppearance.colorIndex), destinations: destinations) }
        row.canMoveEarlier = keptFirst != item.id; row.canMoveLater = keptLast != item.id
        // Read the cell's current identity: AppKit can recycle it for a different tab.
        row.select = { [weak self, weak row] in if let id = row?.item.id { self?.select?(id) } }
        row.close = { [weak self, weak row] in if let id = row?.item.id { self?.close?(id) } }
        row.pin = { [weak self, weak row] in if let id = row?.item.id { self?.pin?(id) } }
        row.move = { [weak self, weak row] destination in if let id = row?.item.id { self?.move?(id, destination) } }
        row.favorite = { [weak self, weak row] in if let id = row?.item.id { self?.favorite?(id) } }
        row.editSaved = { [weak self, weak row] in if let id = row?.item.id { self?.editSaved?(id) } }
        row.resetSaved = { [weak self, weak row] in if let id = row?.item.id { self?.resetSaved?(id) } }
        row.reorderSaved = { [weak self, weak row] direction in if let id = row?.item.id { self?.reorderSaved?(id, direction) } }
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
        if case .tab = entries[row] { return true }; return false
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
    override func layout() {
        super.layout(); let w = bounds.width
        heading.frame = NSRect(x: 12, y: 0, width: max(0, w-24), height: 32)
        scroll.frame = NSRect(x: 8, y: 39, width: max(0,w-16), height: max(0,bounds.height-39))
        let width = scroll.contentSize.width
        if table.frame.width != width { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if column.width != width { column.width = width }
    }
}

@MainActor private final class SidebarTableRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
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
        NSColor.white.withAlphaComponent(0.13).setFill()
        NSRect(x: 9, y: bounds.midY, width: max(0,bounds.width-18), height: 0.5).fill()
    }
}

@MainActor
enum ArkPalette {
    static let ink = NSColor(white: 0.94, alpha: 1)
    static let secondary = NSColor(white: 0.73, alpha: 1)
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
        if (hovered || isHighlighted) && isEnabled { fill(NSColor.white.withAlphaComponent(isHighlighted ? 0.20 : 0.10), radius: 7) }
        symbol(symbolName, rect: NSRect(x: (bounds.width - glyphSize) / 2, y: (bounds.height - glyphSize) / 2, width: glyphSize, height: glyphSize), color: ArkPalette.ink, size: glyphSize)
    }
}

@MainActor private final class ArkSearchButton: ArkHoverButton {
    var address = "Search or enter URL" { didSet { needsDisplay = true } }
    init() { super.init(frame: .zero); setAccessibilityLabel("Search or enter a web address"); toolTip = "Search or enter address (⌘L)" }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        fill(NSColor.black.withAlphaComponent(hovered ? 0.25 : 0.18), radius: 10)
        text(address, rect: NSRect(x: 12, y: 9, width: max(0, bounds.width - 38), height: 20), size: 14, color: ArkPalette.ink)
        symbol("ellipsis", rect: NSRect(x: bounds.width-25, y: 11, width: 14, height: 14), color: ArkPalette.secondary, size: 14)
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
        fill(NSColor.white.withAlphaComponent(item.isActive ? 0.18 : hovered ? 0.14 : 0.08), radius: 9)
        symbol(item.symbol, rect: NSRect(x: (bounds.width - 19) / 2, y: (bounds.height - 19) / 2, width: 19, height: 19),
               color: item.isUnloaded || item.isSleeping ? ArkPalette.secondary.withAlphaComponent(0.66) : ArkPalette.ink, size: 18)
        if item.isUnloaded || item.isSleeping {
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
    init() { super.init(frame: .zero); setAccessibilityLabel("New tab"); toolTip = "New tab (⌘T)" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(NSColor.white.withAlphaComponent(0.08)) }
        symbol("plus", rect: NSRect(x: 10, y: 10, width: 16, height: 16), color: ArkPalette.secondary, size: 16)
        text("New Tab", rect: NSRect(x: 36, y: 9, width: max(0, bounds.width - 48), height: 20), size: 14, color: ArkPalette.secondary)
    }
}

@MainActor
private final class ArkSpaceButton: ArkHoverButton {
    let index: Int
    private var name = ""
    private var symbolName = "globe"
    private var tint = ArkPalette.ink
    var manage: (() -> Void)?
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "Selected" : "Not selected") } }
    init(space: BrowserSpace) {
        index = space.id
        super.init(frame: .zero)
        configure(space)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ space: BrowserSpace) {
        name = space.name; symbolName = space.symbol; tint = ArkPalette.spaceColor(space.colorIndex)
        setAccessibilityLabel("Switch to \(name) space")
        toolTip = name
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered { fill(NSColor.white.withAlphaComponent(selected ? 0.14 : 0.07), radius: 7) }
        symbol(symbolName, rect: NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16),
               color: tint.withAlphaComponent(selected ? 1 : 0.78), size: 16)
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
    private var tint = ArkPalette.ink
    init() { super.init(frame: .zero); toolTip = "Manage Spaces" }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ space: BrowserSpace) {
        name = space.name; symbolName = space.symbol; tint = ArkPalette.spaceColor(space.colorIndex)
        setAccessibilityLabel("Manage Spaces — \(name)")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(NSColor.white.withAlphaComponent(0.06), radius: 6) }
        symbol(symbolName, rect: NSRect(x: 4, y: 8, width: 16, height: 16), color: tint, size: 16)
        text(name, rect: NSRect(x: 32, y: 7, width: max(0, bounds.width - 50), height: 20), size: 14, weight: .medium)
        if hovered { symbol("chevron.down", rect: NSRect(x: bounds.width - 15, y: 11, width: 10, height: 10), color: ArkPalette.secondary, size: 10) }
    }
}

@MainActor
private final class ArkTabRow: ArkFlippedView {
    private(set) var item: SidebarTabItem
    var select: (() -> Void)?
    var close: (() -> Void)?
    var pin: (() -> Void)?
    var move: ((Int) -> Void)?
    var favorite: (() -> Void)?
    var editSaved: (() -> Void)?
    var resetSaved: (() -> Void)?
    var reorderSaved: ((Int) -> Void)?
    var canMoveEarlier = false
    var canMoveLater = false
    private var currentSpace = 0
    private var destinations: [BrowserSpace] = []
    private var spaceTint = ArkPalette.spaceColor(0)
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let iconView = NSImageView()
    private let closeButton = ArkIconButton(symbol: "xmark", label: "Close tab", glyphSize: 12)
    private var hovered = false
    private var area: NSTrackingArea?
    private var configured = false
    init(item: SidebarTabItem) {
        self.item = item
        titleLabel = arkLabel(item.title.isEmpty ? "New Tab" : item.title, size: 14, weight: item.isActive ? .medium : .regular)
        subtitleLabel = arkLabel(item.subtitle, size: 9, weight: .regular)
        super.init(frame: .zero)
        wantsLayer = true
        subtitleLabel.textColor = ArkPalette.secondary.withAlphaComponent(0.84)
        iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        iconView.contentTintColor = item.isActive ? spaceTint : ArkPalette.secondary
        for view in [titleLabel, subtitleLabel, iconView, closeButton] as [NSView] { addSubview(view) }
        closeButton.isHidden = !item.isActive
        closeButton.handler = { [weak self] in self?.close?() }
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
        }
        if first || old.title != item.title { titleLabel.stringValue = item.title.isEmpty ? "New Tab" : item.title; setAccessibilityLabel(item.title) }
        if first || old.isActive != item.isActive { titleLabel.font = .systemFont(ofSize: 14, weight: item.isActive ? .medium : .regular) }
        if first || old.isUnloaded != item.isUnloaded || old.isSleeping != item.isSleeping {
            titleLabel.textColor = item.isUnloaded || item.isSleeping ? ArkPalette.secondary : ArkPalette.ink
            iconView.alphaValue = item.isUnloaded || item.isSleeping ? 0.55 : 1
        }
        if first || old.subtitle != item.subtitle { subtitleLabel.stringValue = item.subtitle }
        if first || old.symbol != item.symbol { iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) }
        if first || old.isActive != item.isActive { iconView.contentTintColor = item.isActive ? spaceTint : ArkPalette.secondary }
        if first || old.isSplit != item.isSplit || old.isPinned != item.isPinned {
            closeButton.setSymbol("xmark", label: item.isSplit ? "Close Split" : item.isPinned ? "Unload tab" : "Close tab")
            closeButton.setAccessibilityHelp(item.isSplit ? "Saved panes unload and remain in the sidebar; ordinary panes close." : nil)
            setAccessibilityHelp(item.isSplit ? "Split. Closing unloads saved panes and keeps their saved tabs; ordinary panes close." : item.isPinned ? "Kept tab. Closing unloads its page and keeps the saved tab." : "Tab")
        }
        closeButton.isHidden = item.isUnloaded || (!hovered && !item.isActive)
        if first || old.isActive != item.isActive || old.isUnloaded != item.isUnloaded || old.isSleeping != item.isSleeping {
            setAccessibilityValue([item.isActive ? "Selected" : nil, item.isUnloaded ? "Unloaded" : item.isSleeping ? "Sleeping" : nil].compactMap { $0 }.joined(separator: ", "))
        }
        if first || old.title != item.title || old.subtitle != item.subtitle || old.isUnloaded != item.isUnloaded || old.isSleeping != item.isSleeping {
            toolTip = [item.title, item.subtitle, item.isUnloaded ? "Unloaded — opens saved page" : item.isSleeping ? "Sleeping — reloads when selected" : ""].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        needsDisplay = true
    }
    func configureSpace(id: Int, tint: NSColor, destinations: [BrowserSpace]) {
        guard currentSpace != id || !spaceTint.isEqual(tint) || self.destinations != destinations else { return }
        currentSpace = id; spaceTint = tint; self.destinations = destinations
        iconView.contentTintColor = item.isActive ? tint : ArkPalette.secondary
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { select?() } else { super.keyDown(with: event) }
    }
    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let textWidth = max(0, bounds.width - 72)
        let hasSubtitle = false
        titleLabel.frame = NSRect(x: 36, y: (bounds.height - 20) / 2, width: textWidth, height: 20)
        subtitleLabel.frame = NSRect(x: 37, y: 23, width: textWidth, height: 12)
        subtitleLabel.isHidden = !hasSubtitle
        closeButton.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8); ring.lineWidth = 2; ring.stroke()
        }
        if item.isActive || hovered {
            NSColor.white.withAlphaComponent(item.isActive ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).fill()
        }
        if item.isActive {
            NSColor.white.withAlphaComponent(0.05).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
            border.lineWidth = 0.5
            border.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; closeButton.isHidden = item.isUnloaded; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; closeButton.isHidden = item.isUnloaded || !item.isActive; needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Labels and symbols belong to the row's selection target; the close
        // button keeps its own native control hit target.
        return hit === closeButton ? closeButton : self
    }
    override func mouseDown(with event: NSEvent) { select?() }
    override func accessibilityPerformPress() -> Bool { select?(); return true }
    override func menu(for event: NSEvent) -> NSMenu? {
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
        if destinations.count > 1 {
            let moveItem = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Move to Space"); submenu.autoenablesItems = false
            for space in destinations {
                let destination = NSMenuItem(title: space.name, action: #selector(moveFromMenu(_:)), keyEquivalent: "")
                destination.target = self; destination.tag = space.id
                destination.state = space.id == currentSpace ? .on : .off
                destination.isEnabled = space.id != currentSpace && move != nil
                destination.image = SidebarSymbol.image(named: space.symbol, color: ArkPalette.spaceColor(space.colorIndex), pointSize: 14)
                submenu.addItem(destination)
            }
            moveItem.submenu = submenu; menu.addItem(moveItem)
        }
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
        if hovered { fill(NSColor.white.withAlphaComponent(0.10), radius: 7) }
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
