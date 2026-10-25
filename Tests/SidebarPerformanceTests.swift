import AppKit

/// Offscreen AppKit coverage: no window is ordered front and no system input is posted.
/// Just enough NSDraggingInfo to call the table's drop methods directly; no drag session runs.
@MainActor final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@main enum SidebarPerformanceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        @MainActor func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 228, height: 720))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = sidebar
        let ids = (0..<1000).map { _ in UUID() }
        @MainActor func item(_ index: Int, active: Int = 0, sleeping: Bool = false) -> SidebarTabItem {
            SidebarTabItem(id: ids[index], title: "Tab \(index)", subtitle: "https://example.invalid/\(index)",
                           symbol: "globe", isPinned: index < 10, isActive: index == active, isSleeping: sleeping)
        }
        var tabs = (0..<1000).map { item($0) }
        var selected: [UUID] = [], closed: [UUID] = []
        sidebar.onSelectTab = { selected.append($0) }; sidebar.onCloseTab = { closed.append($0) }
        @MainActor func update(_ space: Int = 0, _ items: [SidebarTabItem]? = nil) {
            sidebar.update(tabs: items ?? tabs, space: space, canGoBack: false, canGoForward: false, isLoading: false)
            sidebar.layoutSubtreeIfNeeded()
        }
        @MainActor func table(in space: Int) -> NSTableView {
            let page = descendants(sidebar).first { $0.identifier?.rawValue == "sidebar-space-\(space)" }!
            return descendants(page).compactMap { $0 as? NSTableView }.first!
        }
        @MainActor func prepare(_ table: NSTableView) {
            table.layoutSubtreeIfNeeded(); table.prepareContent(in: table.visibleRect); table.layoutSubtreeIfNeeded()
        }
        @MainActor func row(_ table: NSTableView, _ index: Int) -> NSView {
            table.scrollRowToVisible(index); prepare(table)
            let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true)!
            cell.layoutSubtreeIfNeeded()
            return descendants(cell).first { $0.identifier?.rawValue.hasPrefix("tab-row-") == true }!
        }
        update(); let list = table(in: 0); prepare(list)
        require(list.numberOfRows == 1002, "One thousand tabs retain a divider and New Tab row")
        require(list.accessibilityRows()?.count == list.numberOfRows, "Native accessibility retains every row, including unmaterialized tabs")
        require(list.frame.height > list.visibleRect.height + 1000, "Native document has its full scroll extent")
        let first = row(list, 0), second = row(list, 1)
        require(first.accessibilityLabel() == "Tab 0", "A materialized row exposes its actual title")
        require((first.accessibilityValue() as? String)?.contains("Selected") == true, "Active row exposes selection")
        let image = descendants(second).compactMap { $0 as? NSImageView }.first!.image
        let firstCell = list.view(atColumn: 0, row: 0, makeIfNecessary: false)
        let initialViews = descendants(sidebar).count
        require(initialViews < 600 && initialViews > 40, "Native views are bounded by the viewport, not 1000 tab models")
        tabs = (0..<1000).map { item($0, active: 1) }; update()
        require(selected.isEmpty, "Synchronizing the model must not recursively select a tab")
        require(list.view(atColumn: 0, row: 0, makeIfNecessary: false) === firstCell, "Selection does not reload native table cells")
        require(descendants(second).compactMap { $0 as? NSImageView }.first!.image === image, "Selection does not regenerate an unchanged symbol")
        require((second.accessibilityValue() as? String)?.contains("Selected") == true, "Changed visible row updates selection")
        require(!(first.accessibilityValue() as? String ?? "").contains("Selected"), "Old visible row clears selection")
        let scroll = list.enclosingScrollView!
        let far = row(list, 1001)
        require(far.identifier?.rawValue == "tab-row-\(ids[999].uuidString)", "A recycled row represents the far-end identity")
        require(far.accessibilityPerformPress() && selected.last == ids[999], "Recycled accessibility activation selects its current identity")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let close = far.menu(for: event)!.items.first { $0.title == "Close Tab" }!
        require(NSApp.sendAction(close.action!, to: close.target, from: close) && closed.last == ids[999],
                "Recycled context actions close the current identity")
        let origin = scroll.contentView.bounds.origin
        require(list.view(atColumn: 0, row: 502, makeIfNecessary: false) == nil, "The distant metadata target has no materialized cell")
        tabs[500] = SidebarTabItem(id: ids[500], title: "Changed offscreen", subtitle: "updated", symbol: "book", isPinned: false, isActive: false)
        tabs[999] = item(999, active: 999, sleeping: true); update()
        require(abs(scroll.contentView.bounds.minY - origin.y) < 0.5 && scroll.contentView.bounds.minX == origin.x, "Selection and metadata updates preserve scroll origin: \(scroll.contentView.bounds.origin) vs \(origin)")
        require((far.accessibilityValue() as? String)?.contains("Sleeping") == true && far.toolTip?.contains("Sleeping — reloads when selected") == true,
                "Sleeping has a distinct accessible state and reload hint")
        require(far.menu(for: event)!.items.first { $0.title == "Close Tab" }?.isEnabled == true,
                "Sleeping ordinary tabs can still be closed")
        require(list.view(atColumn: 0, row: 502, makeIfNecessary: false) == nil, "Offscreen metadata does not create a native cell")
        require(row(list, 502).accessibilityLabel() == "Changed offscreen", "Offscreen metadata appears when a row is materialized")
        list.selectRowIndexes(IndexSet(integer: 999), byExtendingSelection: false)
        require(selected.last == ids[997], "Native table selection routes the current row identity")
        let savedOrigin = scroll.contentView.bounds.origin
        let alternate = [SidebarTabItem(id: UUID(), title: "Other Space", subtitle: "", symbol: "sun.max", isPinned: false, isActive: true)]
        update(1, alternate); update()
        require(table(in: 0) === list && list.enclosingScrollView === scroll, "Space roundtrip retains the native table and scroll view")
        require(abs(scroll.contentView.bounds.minY - savedOrigin.y) < 0.5 && scroll.contentView.bounds.minX == savedOrigin.x, "Space roundtrip retains vertical scroll position: \(scroll.contentView.bounds.origin) vs \(savedOrigin)")
        sidebar.beginPaging(tabs: alternate, space: 1, direction: 1); sidebar.setPagingOffset(-70)
        let page0 = descendants(sidebar).first { $0.identifier?.rawValue == "sidebar-space-0" }!
        require(page0.frame.minX == -70 && sidebar.isPaging, "Horizontal paging moves the container without rebuilding the table")
        _ = sidebar.commitPaging(to: 1, preservingOffset: true)
        require(sidebar.canReversePaging(to: 0) && page0.frame.minX == -70, "Committed paging retains outgoing geometry for reversal")
        sidebar.endPaging(); update()
        for width: CGFloat in [164, 228, 500] {
            sidebar.setFrameSize(NSSize(width: width, height: 720)); sidebar.layoutSubtreeIfNeeded(); prepare(list)
            require(abs(list.frame.width - scroll.contentSize.width) < 1, "Table width follows the viewport at \(width)")
            require(!scroll.hasHorizontalScroller && scroll.horizontalScrollElasticity == .none, "No native horizontal bounce at \(width)")
        }
        tabs[0] = SidebarTabItem(id: ids[0], title: "Favorite", subtitle: "", symbol: "star", isPinned: true, isActive: false, isFavorite: true)
        update(); prepare(list)
        require(list.numberOfRows == 1001, "A global Favorite is excluded from the paged list")
        require(descendants(sidebar).filter { $0.identifier?.rawValue == "favorite-\(ids[0].uuidString)" }.count == 1,
                "A global Favorite has exactly one fixed native tile")
        require(descendants(sidebar).count < 1000, "Scrolling and visiting two Spaces keeps native views bounded")
        tabs = [SidebarTabItem(id: ids[1], title: "Unloaded", subtitle: "", symbol: "book", isPinned: true, isActive: false, isUnloaded: true)]
        update(); let unloaded = row(list, 0)
        require(list.numberOfRows == 3 && abs(scroll.contentView.bounds.minY) < 0.5, "Shrinking the list constrains its old scroll origin: rows=\(list.numberOfRows), origin=\(scroll.contentView.bounds.origin), extent=\(list.frame)")
        require((unloaded.accessibilityValue() as? String) == "Unloaded", "Manual saved unload stays distinct from automatic sleeping")
        require(unloaded.menu(for: event)!.items.first { $0.title == "Unload Tab" }?.isEnabled == false,
                "Already unloaded saved tabs cannot be unloaded twice")
        tabs = (0..<1000).map { item($0) }; update(); prepare(list)
        var times: [Double] = []
        for pass in 0..<30 {
            let active = pass % 2
            tabs[0] = item(0, active: active); tabs[1] = item(1, active: active)
            let start = ProcessInfo.processInfo.systemUptime; update()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        print("Sidebar 1000-tab selection median: \(times.sorted()[times.count / 2]) ms; native views: \(descendants(sidebar).count)")
        @MainActor func icon(_ row: NSView) -> NSImageView { descendants(row).compactMap { $0 as? NSImageView }.first! }
        let red = NSImage(size: NSSize(width: 32, height: 16), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let blue = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        tabs[0] = item(0, active: 0); tabs[1] = item(1, active: 0); update()
        let current = row(list, 0)
        var cache = [ids[0]: red, ids[1]: blue, alternate[0].id: red]
        var lookups: [UUID] = []
        sidebar.faviconProvider = { id in lookups.append(id); return cache[id] }
        require(!lookups.isEmpty && lookups.count < 100 && !lookups.contains(ids[500]),
                "Installing a provider looks up only the viewport, not one thousand tab models")
        require(icon(current).image === red && icon(current).contentTintColor == nil &&
                    (current.accessibilityValue() as? String)?.contains("Selected") == true,
                "A visible selected row displays its full-color favicon")
        require(icon(current).imageScaling == .scaleProportionallyUpOrDown && icon(current).frame.size == NSSize(width: 16, height: 16),
                "Sidebar favicons retain proportional scaling in their existing 16-point slot")
        let currentCell = list.view(atColumn: 0, row: 0, makeIfNecessary: false)
        let accessibleName = current.accessibilityLabel()
        cache[ids[0]] = blue; lookups = []
        sidebar.refreshFavicons()
        require(list.view(atColumn: 0, row: 0, makeIfNecessary: false) === currentCell && icon(current).image === blue,
                "A cache arrival refreshes the same native table cell")
        require(current.accessibilityLabel() == accessibleName && lookups.count < 100 && !lookups.contains(alternate[0].id),
                "Refresh keeps accessible identity and ignores cached detached Space pages")
        cache[ids[0]] = nil
        tabs[0] = SidebarTabItem(id: ids[0], title: "New destination", subtitle: "https://different.invalid", symbol: "book", isPinned: true, isActive: true)
        update()
        require(icon(current).image !== blue && icon(current).identifier == nil && icon(current).contentTintColor != nil,
                "A URL change with no cached icon clears the previous favicon and restores the symbol tint")
        let recycled = row(list, 1001)
        require(icon(recycled).image !== red && icon(recycled).image !== blue && icon(recycled).identifier == nil,
                "A reused far-end row cannot retain another tab's image")
        _ = row(list, 0)
        tabs[0] = SidebarTabItem(id: ids[0], title: "Split", subtitle: "", symbol: "rectangle.split.2x1", isPinned: true, isActive: true, isSplit: true)
        cache[ids[0]] = red; lookups = []; update(); sidebar.refreshFavicons()
        require(!lookups.contains(ids[0]) && icon(row(list, 0)).identifier == nil,
                "A split composite keeps its split symbol without requesting either tab's favicon")
        tabs[0] = SidebarTabItem(id: ids[0], title: "Favorite", subtitle: "https://favorite.invalid", symbol: "star", isPinned: true, isActive: true, isFavorite: true)
        update(); prepare(list)
        let tile = descendants(sidebar).first { $0.identifier?.rawValue == "favorite-\(ids[0].uuidString)" } as! NSButton
        require(tile.image === red && tile.accessibilityLabel() == "Favorite", "Favorites use the full-color cached image without changing their accessible name")
        cache[ids[0]] = blue; sidebar.refreshFavicons()
        require(tile.image === blue && tile.superview != nil, "Favorite cache arrival updates the existing fixed tile")
        sidebar.beginPaging(tabs: alternate, space: 1, direction: 1); sidebar.setPagingOffset(-70)
        let incomingList = table(in: 1), incomingRow = row(table(in: 1), 1)
        cache[alternate[0].id] = blue; lookups = []
        sidebar.refreshFavicons()
        require(lookups.contains(alternate[0].id) && icon(incomingRow).image === blue && table(in: 1) === incomingList,
                "An attached incoming Space refreshes its existing rows during paging")
        sidebar.endPaging()
        sidebar.faviconProvider = nil
        require(tile.image == nil && icon(row(list, 0)).identifier == nil && icon(row(list, 0)).contentTintColor != nil,
                "Removing the provider clears Favorite and row images immediately")
        // Installed extensions stay fixed above the scrolling tab list. Updating
        // badges preserves the native button used as WebKit's popover anchor.
        let extensionIDs = (0..<9).map { _ in UUID() }
        func extensionItems(badge: String = "") -> [SidebarExtensionItem] {
            extensionIDs.enumerated().map { SidebarExtensionItem(id: $0.element, name: "Extension \($0.offset)", label: "Open vault", icon: red, badge: $0.offset == 0 ? badge : "", isEnabled: $0.offset != 1) }
        }
        var invoked: UUID?, invokedAnchor: NSView?
        sidebar.onExtensionAction = { invoked = $0; invokedAnchor = $1 }
        sidebar.updateExtensions(extensionItems()); sidebar.layoutSubtreeIfNeeded()
        let firstAction = descendants(sidebar).first { $0.identifier?.rawValue == "extension-action-\(extensionIDs[0].uuidString)" } as! NSButton
        firstAction.performClick(nil)
        require(invoked == extensionIDs[0] && invokedAnchor === firstAction, "Vendor button dispatches its own identity and native popover anchor")
        require(firstAction.accessibilityLabel() == "Extension 0" && firstAction.toolTip?.contains("Open vault") == true, "Extension action exposes its vendor and current action label")
        sidebar.updateExtensions(extensionItems(badge: "12")); sidebar.layoutSubtreeIfNeeded()
        require(descendants(sidebar).first { $0.identifier == firstAction.identifier } === firstAction && firstAction.accessibilityValue() as? String == "12", "Badge update preserves popup anchor and exposes badge to accessibility")
        for width: CGFloat in [164, 228, 500] {
            sidebar.setFrameSize(NSSize(width: width, height: 720)); sidebar.layoutSubtreeIfNeeded()
            let actions = descendants(sidebar).filter { $0.identifier?.rawValue.hasPrefix("extension-action-") == true }
            require(actions.filter { !$0.isHidden }.allSatisfy { $0.frame.maxX <= width && $0.frame.minX >= 40 }, "Action icons fit without overlap at \(width)")
            let menu = descendants(sidebar).first { $0.identifier?.rawValue == "extensions-menu" }!
            require(!menu.isHidden && (menu.accessibilityLabel()?.contains("more") == true) == actions.contains(where: \.isHidden), "Overflow stays reachable at \(width)")
        }
        let disabled = descendants(sidebar).first { $0.identifier?.rawValue == "extension-action-\(extensionIDs[1].uuidString)" } as! NSButton
        require(!disabled.isEnabled, "Tab-disabled extension action remains visibly disabled")
        sidebar.updateExtensions([]); sidebar.layoutSubtreeIfNeeded()
        require(descendants(sidebar).allSatisfy { $0.identifier?.rawValue.hasPrefix("extension-action-") != true }, "Removing or switching profiles clears old actions")
        require(descendants(sidebar).first { $0.identifier?.rawValue == "extension-library" }?.isHidden == false, "Empty profiles offer Add extensions directly")

        // Folder rows: deep nesting keeps titles readable at the narrowest width,
        // and pressing a folder toggles it instead of selecting a page.
        sidebar.setFrameSize(NSSize(width: 164, height: 720))
        let folderIDs = (0..<12).map { _ in UUID() }, leaf = UUID()
        var toggled: [UUID] = []
        sidebar.onToggleFolder = { toggled.append($0) }
        let nested = folderIDs.enumerated().map { depth, id in
            SidebarTabItem(id: id, title: "Folder level \(depth) with a long name", subtitle: "", symbol: "folder", isPinned: true,
                           isActive: false, depth: depth, isFolder: true, isExpanded: true)
        } + [SidebarTabItem(id: leaf, title: "Deep leaf page title", subtitle: "https://deep.invalid", symbol: "globe",
                            isPinned: true, isActive: true, depth: 12, parentFolderID: folderIDs.last)]
        update(0, nested)
        let deepTable = table(in: 0)
        let deepRow = row(deepTable, 12)
        let deepTitle = descendants(deepRow).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Deep leaf page title" }!
        require(deepTitle.frame.width >= 60 && deepTitle.frame.minX > 36 && deepTitle.frame.maxX <= deepRow.bounds.width,
                "Depth-12 title stays readable and still indented at 164pt: \(deepTitle.frame)")
        let narrowIndent = deepTitle.frame.minX
        sidebar.setFrameSize(NSSize(width: 228, height: 720)); update(0, nested)
        let wideTitle = descendants(row(table(in: 0), 12)).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Deep leaf page title" }!
        require(wideTitle.frame.width >= 64 && wideTitle.frame.minX > narrowIndent, "Wider sidebars restore deeper indentation: \(wideTitle.frame)")
        // Visual review: one indent step per list, so every level stays distinct
        // at the narrowest width (depth 1 and depth 5 never line up).
        for width in [164, 200, 240] as [CGFloat] {
            let xs = (0...5).map { ArkRowLayout(width: width, height: 34, depth: $0, listMaxDepth: 5, isFolder: false, showsClose: true).title.minX }
            require(zip(xs, xs.dropFirst()).allSatisfy { $1 - $0 >= 5 }, "Every folder level indents further at \(width)pt: \(xs)")
            let deepest = ArkRowLayout(width: width, height: 34, depth: 5, listMaxDepth: 5, isFolder: false, showsClose: true)
            require(deepest.title.width >= ArkMetrics.minimumTitleWidth - 0.5, "Deepest title keeps its minimum with the close button showing at \(width)pt")
        }
        // A hidden close button gives its room back to the title.
        let quiet = ArkRowLayout(width: 240, height: 34, depth: 1, listMaxDepth: 1, isFolder: false, showsClose: false)
        let busy = ArkRowLayout(width: 240, height: 34, depth: 1, listMaxDepth: 1, isFolder: false, showsClose: true)
        require(quiet.title.width >= busy.title.width + 20 && quiet.title.maxX <= 240 - ArkMetrics.trailingGap + 0.5,
                "Titles run to the edge when the close button is hidden: \(quiet.title.width) vs \(busy.title.width)")
        let leafNow = row(table(in: 0), 12)
        let leafTitle = descendants(leafNow).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Deep leaf page title" }!
        let closeShown = descendants(leafNow).first { !$0.isHidden && ["Close tab", "Unload tab"].contains($0.accessibilityLabel() ?? "") }
        require(closeShown != nil && leafTitle.frame.maxX <= closeShown!.frame.minX, "The selected row's title stops before its close button")

        // Saved rows that haven't been opened (every fresh import) read at full
        // contrast; only memory-slept pages are quieted, and only slightly.
        require(ArkRowInk.title(sleeping: false) == ArkPalette.ink && ArkRowInk.iconAlpha(sleeping: false) == 1
                && ArkRowInk.iconAlpha(sleeping: true) >= 0.75, "Dormant saved rows are not dimmed")
        let dormantItems = Array(nested.dropLast()) + [SidebarTabItem(id: leaf, title: "Deep leaf page title", subtitle: "https://deep.invalid", symbol: "globe",
                                                                         isPinned: true, isActive: false, isUnloaded: true, depth: 12, parentFolderID: folderIDs.last)]
        update(0, dormantItems)
        let dormantRow = row(table(in: 0), 12)
        let dormantTitle = descendants(dormantRow).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Deep leaf page title" }!
        let dormantIcon = descendants(dormantRow).compactMap { $0 as? NSImageView }.first { $0.identifier?.rawValue != "folder-chevron" }!
        require(dormantTitle.textColor == ArkPalette.ink && dormantIcon.alphaValue == 1, "An unloaded saved row keeps full ink and icon")
        update(0, nested)

        let folderRow = row(deepTable, 0)
        // Folders show a disclosure chevron that follows their state.
        let chevron = descendants(folderRow).first { $0.identifier?.rawValue == "folder-chevron" } as? NSImageView
        require(chevron?.isHidden == false && chevron?.image?.name() == nil, "Folder rows show a chevron")
        require(descendants(leafNow).first { $0.identifier?.rawValue == "folder-chevron" }?.isHidden != false, "Tab rows show no chevron")
        let folderTitle = descendants(folderRow).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Folder level 0") }!
        require(chevron.map { folderTitle.frame.maxX <= $0.frame.minX } == true, "Folder titles stop before the chevron")
        selected.removeAll()
        _ = folderRow.accessibilityPerformPress()
        require(toggled == [folderIDs[0]] && selected.isEmpty, "Pressing a folder toggles it and selects nothing")
        require(folderRow.isAccessibilityDisclosed() && folderRow.isAccessibilityExpanded() && (folderRow.accessibilityValue() as? NSNumber)?.intValue == 1
                && folderRow.accessibilityRole() == .disclosureTriangle && folderRow.accessibilityLabel()?.hasPrefix("Folder level 0") == true,
                "Folder is one disclosure control with its name and expanded state")
        require(descendants(folderRow).filter { $0 !== folderRow && $0.isAccessibilityElement() && !($0 is NSButton) }.isEmpty,
                "Folder label and icon are not separate accessibility elements")
        let leafRow = row(table(in: 0), 12)
        require(leafRow.accessibilityRole() == .button && !leafRow.isAccessibilityDisclosed(), "Tab rows stay buttons without disclosure state")
        require(deepTable.delegate?.tableView?(deepTable, shouldSelectRow: 0) == false, "Folder rows are not table selections")

        // Keyboard-only: arrows from the selected tab reach folder rows, which
        // toggle on Return. Events go straight to the views; nothing is posted.
        @MainActor func key(_ code: UInt16, to view: NSView) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: code == 36 ? "\r" : "",
                                         isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        let keyTable = table(in: 0)
        keyTable.selectRowIndexes(IndexSet(integer: 12), byExtendingSelection: false)
        window.makeFirstResponder(keyTable)
        key(126, to: keyTable)
        let focusedFolder = window.firstResponder as? NSView
        require(focusedFolder?.identifier?.rawValue == "tab-row-\(folderIDs[11].uuidString)", "Up arrow from a tab focuses the folder above it")
        key(126, to: focusedFolder!)
        require((window.firstResponder as? NSView)?.identifier?.rawValue == "tab-row-\(folderIDs[10].uuidString)", "Up arrow moves between folders")
        toggled.removeAll()
        key(36, to: window.firstResponder as! NSView)
        require(toggled == [folderIDs[10]], "Return toggles the focused folder")
        key(123, to: window.firstResponder as! NSView)
        require(toggled == [folderIDs[10], folderIDs[10]], "Left arrow collapses an expanded folder")

        // No table selection (active page is a Favorite; the Space holds only folders):
        // Down enters at the first folder, Up at the last; nothing is selected as a tab.
        let onlyFolders = folderIDs.prefix(3).enumerated().map { index, id in
            SidebarTabItem(id: id, title: "Only folder \(index)", subtitle: "", symbol: "folder", isPinned: true,
                           isActive: false, isFolder: true, isExpanded: false)
        } + [SidebarTabItem(id: leaf, title: "Favorite page", subtitle: "", symbol: "star", isPinned: true, isActive: true, isFavorite: true)]
        update(0, Array(onlyFolders))
        let folderTable = table(in: 0)
        prepare(folderTable)
        require(folderTable.selectedRow == -1, "A Favorite selection leaves the Space list without a selected row")
        selected.removeAll()
        window.makeFirstResponder(folderTable); key(125, to: folderTable)
        require((window.firstResponder as? NSView)?.identifier?.rawValue == "tab-row-\(folderIDs[0].uuidString)" && selected.isEmpty,
                "Down with no selection focuses the first folder without selecting a tab")
        window.makeFirstResponder(folderTable); key(126, to: folderTable)
        require((window.firstResponder as? NSView)?.identifier?.rawValue == "tab-row-\(folderIDs[2].uuidString)" && selected.isEmpty,
                "Up with no selection focuses the last folder")

        // Native regression: a click expands a folder, the sidebar reloads, and
        // the folder must still hold focus so Left collapses it again.
        var tree = [SidebarTabItem(id: folderIDs[0], title: "Projects", subtitle: "", symbol: "folder", isPinned: true, isActive: false,
                                   isFolder: true, isExpanded: false),
                    SidebarTabItem(id: leaf, title: "Selected page", subtitle: "", symbol: "globe", isPinned: false, isActive: true)]
        let child = UUID()
        sidebar.onToggleFolder = { id in
            let expanding = !tree[0].isExpanded
            tree[0].isExpanded = expanding
            if expanding {
                tree.insert(SidebarTabItem(id: child, title: "Inside", subtitle: "", symbol: "globe", isPinned: true, isActive: false,
                                           depth: 1, parentFolderID: id), at: 1)
            } else { tree.removeAll { $0.id == child } }
            update(0, tree)
        }
        update(0, tree)
        let projects = row(table(in: 0), 0)
        @MainActor func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        projects.mouseDown(with: mouse(.leftMouseDown))
        require(tree.count == 2, "A folder doesn't toggle on mouse-down, so it can be dragged")
        projects.mouseUp(with: mouse(.leftMouseUp))
        require(tree.count == 3 && (window.firstResponder as? NSView)?.identifier?.rawValue == "tab-row-\(folderIDs[0].uuidString)",
                "Clicking a folder expands it and keeps focus on it after the reload")
        key(123, to: window.firstResponder as! NSView)
        require(tree.count == 2 && (window.firstResponder as? NSView)?.identifier?.rawValue == "tab-row-\(folderIDs[0].uuidString)",
                "Left then collapses it and focus stays on the folder")

        // Drag and drop: the table's own drop methods map rows to model targets,
        // only accept what the model accepts, and change nothing when refused.
        let k1 = UUID(), box = UUID(), boxChild = UUID(), k2 = UUID(), t1 = UUID(), t2 = UUID()
        let dndItems = [
            SidebarTabItem(id: k1, title: "Kept one", subtitle: "", symbol: "globe", isPinned: true, isActive: false),
            SidebarTabItem(id: box, title: "Box", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: true),
            SidebarTabItem(id: boxChild, title: "In box", subtitle: "", symbol: "globe", isPinned: true, isActive: false, depth: 1, parentFolderID: box),
            SidebarTabItem(id: k2, title: "Kept two", subtitle: "", symbol: "globe", isPinned: true, isActive: false),
            SidebarTabItem(id: t1, title: "Today one", subtitle: "", symbol: "globe", isPinned: false, isActive: true),
            SidebarTabItem(id: t2, title: "Today two", subtitle: "", symbol: "globe", isPinned: false, isActive: false)
        ]
        update(0, dndItems)
        let dndTable = table(in: 0)   // rows: k1, box, child, k2, divider, New Tab, t1, t2
        var asked: [BrowserSession.SidebarDropTarget] = [], dropped: [BrowserSession.SidebarDropTarget] = []
        var accept = true
        sidebar.canDrop = { _, target, space in asked.append(target); return accept && space == 0 }
        sidebar.onDrop = { _, target, _ in dropped.append(target); return true }
        let board = NSPasteboard(name: NSPasteboard.Name("bam-sidebar-dnd-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString(k2.uuidString, forType: .bamSidebarRow)
        let info = FakeDraggingInfo(pasteboard: board)
        @MainActor func validate(_ row: Int, _ operation: NSTableView.DropOperation) -> (NSDragOperation, BrowserSession.SidebarDropTarget?) {
            asked.removeAll()
            let result = dndTable.dataSource!.tableView!(dndTable, validateDrop: info, proposedRow: row, proposedDropOperation: operation)
            return (result, asked.last)
        }
        require(validate(1, .on) == (.move, .into(box)), "Dropping on a folder files the row inside it")
        require(validate(2, .on) == (.move, .before(boxChild)), "Dropping on a tab means just before it")
        require(validate(0, .above) == (.move, .before(k1)), "Between rows means before that row")
        require(validate(4, .above).1 == .keptEnd && validate(5, .above).1 == .keptEnd, "The divider/New Tab gap is the end of the kept section")
        require(validate(6, .above).1 == .today(before: t1) && validate(8, .above).1 == .today(before: nil), "Today rows and the list end unkeep into Today")
        accept = false
        require(validate(1, .on).0 == [], "No drop indicator where the model refuses (cycle, depth, folder into Today)")
        accept = true
        require(dndTable.dataSource!.tableView!(dndTable, acceptDrop: info, row: 1, dropOperation: .on) && dropped == [.into(box)],
                "Dropping commits exactly the validated target")
        board.clearContents(); board.setString("not a row", forType: .string)
        require(validate(1, .on).0 == [] && asked.isEmpty, "Foreign drags are ignored")

        // Regression: mouse-down selects, selection reloads the list (a revealed
        // child under a collapsed folder disappears), and the pressed view may be
        // reused for another row. A following drag must never carry another ID.
        let folder = UUID(), revealed = UUID(), pressed = UUID(), today = UUID()
        func layout(active: UUID) -> [SidebarTabItem] {
            var items = [SidebarTabItem(id: folder, title: "Closed", subtitle: "", symbol: "folder", isPinned: true, isActive: false,
                                        isFolder: true, isExpanded: false)]
            if active == revealed {
                items.append(SidebarTabItem(id: revealed, title: "Revealed", subtitle: "", symbol: "globe", isPinned: true, isActive: true,
                                            depth: 1, parentFolderID: folder))
            }
            items.append(SidebarTabItem(id: pressed, title: "Pressed", subtitle: "", symbol: "globe", isPinned: true, isActive: active == pressed))
            items.append(SidebarTabItem(id: today, title: "Today", subtitle: "", symbol: "globe", isPinned: false, isActive: false))
            return items
        }
        update(0, layout(active: revealed))
        var started: [UUID] = []
        sidebar.onRowDragWillBegin = { started.append($0); return false }   // Observe; never start a real session offscreen.
        sidebar.onSelectTab = { id in update(0, layout(active: id)) }       // Selection reloads synchronously.
        let pressTable = table(in: 0)
        let pressedView = row(pressTable, 2)
        require(pressedView.identifier?.rawValue == "tab-row-\(pressed.uuidString)", "Fixture: row 2 is the pressed tab")
        pressedView.mouseDown(with: mouse(.leftMouseDown))
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 40, y: 40), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pressedView.mouseDragged(with: drag)
        require(started.allSatisfy { $0 == pressed }, "A drag only ever carries the pressed row's ID: \(started)")
        // Force reuse mid-press: in a long list, the pressed view is recycled for
        // a far row once that row scrolls in (as a reload/scroll during a press can).
        started.removeAll()
        let crowd = (0..<600).map { SidebarTabItem(id: UUID(), title: "Crowd \($0)", subtitle: "", symbol: "globe", isPinned: false, isActive: $0 == 0) }
        sidebar.onSelectTab = { _ in }
        update(0, crowd)
        let crowdTable = table(in: 0)
        let reusedView = row(crowdTable, 2)   // rows 0/1 are the divider-less New Tab and first item
        let pressedCrowdID = reusedView.identifier?.rawValue
        reusedView.mouseDown(with: mouse(.leftMouseDown))
        _ = row(crowdTable, crowdTable.numberOfRows - 1)
        require(reusedView.identifier?.rawValue != pressedCrowdID, "Fixture: the pressed view now shows another row")
        reusedView.mouseDragged(with: drag)
        require(started.isEmpty, "A recycled view abandons the press instead of dragging the row it now shows: \(started)")
        reusedView.mouseUp(with: mouse(.leftMouseUp))
        // A plain press-and-drag with no reload drags the pressed row.
        started.removeAll(); sidebar.onSelectTab = { _ in }
        let stable = row(table(in: 0), 1)
        let stableID = stable.identifier?.rawValue
        stable.mouseDown(with: mouse(.leftMouseDown)); stable.mouseDragged(with: drag)
        require(started.count == 1 && "tab-row-\(started[0].uuidString)" == stableID, "Without a reload the pressed row is dragged")
        sidebar.onRowDragWillBegin = nil

        // Accessibility, pointer and keyboard model for rows.
        let navFolder = UUID(), navChild = UUID(), navKept = UUID(), navToday = UUID(), navOther = UUID()
        let navItems = [
            SidebarTabItem(id: navFolder, title: "Work", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: true),
            SidebarTabItem(id: navChild, title: "Inside work", subtitle: "", symbol: "globe", isPinned: true, isActive: false, isUnloaded: true,
                           depth: 1, parentFolderID: navFolder),
            SidebarTabItem(id: navKept, title: "Kept", subtitle: "", symbol: "globe", isPinned: true, isActive: false, isUnloaded: true),
            SidebarTabItem(id: navToday, title: "Today", subtitle: "", symbol: "globe", isPinned: false, isActive: true),
            SidebarTabItem(id: navOther, title: "Other", subtitle: "", symbol: "globe", isPinned: false, isActive: false)
        ]
        var navSelected: [UUID] = [], pageFocused = 0
        sidebar.onSelectTab = { navSelected.append($0) }
        sidebar.onToggleFolder = { _ in }
        sidebar.onFocusPage = { pageFocused += 1 }
        update(0, navItems)
        let navTable = table(in: 0)   // rows: Work, Inside work, Kept, divider, New Tab, Today, Other
        func focusedID() -> String? { (window.firstResponder as? NSView)?.identifier?.rawValue }
        func rowID(_ id: UUID) -> String { "tab-row-\(id.uuidString)" }
        let folderView = row(navTable, 0), childView = row(navTable, 1)
        require(folderView.isAccessibilityElement() && childView.isAccessibilityElement(), "Rows are real accessibility elements, not just table cells")
        require(folderView.accessibilityRole() == .disclosureTriangle && folderView.accessibilityRoleDescription() == "folder"
                && childView.accessibilityRole() == .button && childView.accessibilityLabel() == "Inside work",
                "Folders announce as disclosure controls; tabs as buttons with their titles")
        // Pointer: nothing opens on mouse-down; release opens; a drag never does.
        childView.mouseDown(with: mouse(.leftMouseDown))
        require(navSelected.isEmpty, "Mouse-down alone neither selects nor wakes a dormant tab")
        childView.mouseUp(with: mouse(.leftMouseUp))
        require(navSelected == [navChild], "Releasing without a drag opens the tab")
        navSelected.removeAll()
        sidebar.onRowDragWillBegin = { _ in false }
        childView.mouseDown(with: mouse(.leftMouseDown)); childView.mouseDragged(with: drag); childView.mouseUp(with: mouse(.leftMouseUp))
        require(navSelected.isEmpty, "Dragging a tab never selects or wakes it")
        sidebar.onRowDragWillBegin = nil
        // Keyboard entry (View ▸ Focus Sidebar) and navigation without selection.
        window.makeFirstResponder(nil)
        require(sidebar.focusTabList() && focusedID() == rowID(navToday) && navSelected.isEmpty,
                "Focus Sidebar lands on the selected tab's row without selecting anything")
        key(126, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navKept) && navSelected.isEmpty, "Up moves focus past the divider to a kept row; nothing opens")
        key(126, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navChild) && navSelected.isEmpty, "Arrows reach rows inside folders without opening them")
        key(123, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navFolder), "Left from a row in a folder moves focus to the folder")
        key(125, to: window.firstResponder as! NSView); key(125, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navKept), "Down continues row by row")
        key(36, to: window.firstResponder as! NSView)
        require(navSelected == [navKept], "Return opens the focused tab (only then is it woken)")
        key(53, to: window.firstResponder as! NSView)
        require(pageFocused == 1, "Escape hands focus back to the page")
        // A list with no selected row (active page is a Favorite) still has an entry point.
        update(0, navItems.map { item in
            SidebarTabItem(id: item.id, title: item.title, subtitle: item.subtitle, symbol: item.symbol, isPinned: item.isPinned, isActive: false,
                           isUnloaded: item.isUnloaded, depth: item.depth, isFolder: item.isFolder, isExpanded: item.isExpanded,
                           parentFolderID: item.parentFolderID)
        })
        window.makeFirstResponder(nil)
        require(sidebar.focusTabList() && focusedID() == rowID(navFolder), "With no selection, Focus Sidebar starts at the first row")

        // Edges: Up at the first row / Down at the last row do nothing, with the
        // active tab elsewhere (no fall-through to table selection).
        update(0, navItems)
        let edgeTable = table(in: 0)
        let selectedBefore = edgeTable.selectedRow
        navSelected.removeAll()
        sidebar.focusTabList()
        key(126, to: window.firstResponder as! NSView); key(126, to: window.firstResponder as! NSView); key(126, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navFolder), "Focus reaches the first row")
        key(126, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navFolder) && navSelected.isEmpty && edgeTable.selectedRow == selectedBefore,
                "Up at the first row is a no-op: no selection change, nothing opens")
        for _ in 0..<6 { key(125, to: window.firstResponder as! NSView) }
        require(focusedID() == rowID(navOther), "Focus reaches the last row")
        key(125, to: window.firstResponder as! NSView)
        require(focusedID() == rowID(navOther) && navSelected.isEmpty && edgeTable.selectedRow == selectedBefore,
                "Down at the last row is a no-op")
        window.makeFirstResponder(edgeTable)
        edgeTable.selectRowIndexes(IndexSet(integer: edgeTable.numberOfRows - 1), byExtendingSelection: false)
        navSelected.removeAll()
        key(125, to: edgeTable)
        require(navSelected.isEmpty, "Down past the end with the list itself focused selects nothing")
        update(0, navItems); navSelected.removeAll()

        // Focus survives a reorder/insertion and cell reuse; Return opens exactly that row.
        sidebar.focusTabList()                                   // on Today (active A)
        key(126, to: window.firstResponder as! NSView)           // to Kept (dormant B)
        require(focusedID() == rowID(navKept), "Fixture: dormant B is focused while A is active")
        let inserted = (0..<30).map { SidebarTabItem(id: UUID(), title: "New \($0)", subtitle: "", symbol: "globe", isPinned: false, isActive: false) }
        let reordered = [navItems[2], navItems[0], navItems[1]] + inserted + [navItems[4], navItems[3]]   // B moves up; 30 rows inserted
        update(0, reordered); prepare(table(in: 0))
        require(focusedID() == rowID(navKept) && navSelected.isEmpty, "Focus stays on B through a reorder, insertion and reload")
        key(36, to: window.firstResponder as! NSView)
        require(navSelected == [navKept], "Return then opens B, exactly once")
        // A removed focused row falls back nearby without opening anything.
        navSelected.removeAll()
        update(0, reordered); sidebar.focusTabList()
        for _ in 0..<3 { key(125, to: window.firstResponder as! NSView) }
        let doomed = focusedID()
        update(0, reordered.filter { rowID($0.id) != doomed })
        require(focusedID() != nil && focusedID() != doomed && navSelected.isEmpty, "Removing the focused row moves focus nearby; nothing opens")
        // Assistive label matches the shown fallback for a blank title.
        update(0, [SidebarTabItem(id: UUID(), title: "", subtitle: "", symbol: "globe", isPinned: false, isActive: true)])
        require(row(table(in: 0), 1).accessibilityLabel() == "New Tab", "A blank tab is announced as New Tab, as shown")
        // An empty list still accepts focus, and arrows there are harmless.
        update(0, [])
        require(!sidebar.focusTabList() && window.firstResponder === table(in: 0), "Focus Sidebar on an empty list focuses the list itself")
        key(125, to: table(in: 0))
        require(navSelected.isEmpty, "Arrows in an empty list do nothing")
        print("PASS: \(checks) sidebar virtualization, identity, scrolling, paging and extension action checks")
        window.contentView = nil
    }
}
