import AppKit

/// Offscreen AppKit coverage: no window is ordered front and no system input is posted.
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
        let folderRow = row(deepTable, 0)
        selected.removeAll()
        _ = folderRow.accessibilityPerformPress()
        require(toggled == [folderIDs[0]] && selected.isEmpty, "Pressing a folder toggles it and selects nothing")
        require(folderRow.isAccessibilityDisclosed() && folderRow.accessibilityValue() as? String == "Expanded", "Folder exposes expanded state")
        require(deepTable.delegate?.tableView?(deepTable, shouldSelectRow: 0) == false, "Folder rows are not table selections")
        print("PASS: \(checks) sidebar virtualization, identity, scrolling, paging and extension action checks")
        window.contentView = nil
    }
}
