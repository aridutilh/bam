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
        print("PASS: \(checks) sidebar virtualization, identity, scrolling, paging and sleep checks")
        window.contentView = nil
    }
}
