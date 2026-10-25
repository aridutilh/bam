import AppKit

/// Morning sidebar pass (Favorites density/quality, hover lifecycle, folder focus, footer). Offscreen AppKit: no window
/// is ordered front, no system input is posted; the pointer is supplied through ArkHover's test seam.
@main enum SidebarMorningTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

        // MARK: Favorites grid: balanced, Arc-like density.
        require(ArkMetrics.favoriteColumns(count: 8, width: 228) == 4, "8 Favorites at ~230pt: 4×2, as in Arc")
        require(ArkMetrics.favoriteColumns(count: 6, width: 228) == 3, "6 Favorites at ~230pt: 3×2, as in Arc")
        require(ArkMetrics.favoriteColumns(count: 12, width: 228) == 4 && ArkMetrics.favoriteColumns(count: 5, width: 228) == 3,
                "12 → 4×3; 5 → 3+2 (no lone tile under a full row)")
        require(ArkMetrics.favoriteColumns(count: 8, width: 164) == 3, "At the minimum sidebar width a column drops")
        require(ArkMetrics.favoriteColumns(count: 8, width: 420) == 4 && ArkMetrics.favoriteColumns(count: 12, width: 420) == 6,
                "A wide sidebar keeps rows balanced instead of 7+1")
        require(ArkMetrics.favoriteColumns(count: 1, width: 228) == 1 && ArkMetrics.favoriteColumns(count: 0, width: 228) == 0, "Edge counts")
        for count in 1...12 {
            for width in stride(from: CGFloat(164), through: 420, by: 7.25) {
                let columns = ArkMetrics.favoriteColumns(count: count, width: width)
                let tile = (width - 16 - CGFloat(columns - 1) * ArkMetrics.favoriteGap) / CGFloat(columns)
                let rows = (count + columns - 1) / columns
                require(columns >= 1 && tile >= ArkMetrics.favoriteMinimumWidth - 0.001, "Tiles never go below the minimum (\(count) at \(width))")
                require(rows * columns - count < columns, "No empty row (\(count) at \(width))")
            }
        }

        // MARK: Favorite artwork: 16pt, aspect kept, never enlarged past 16pt.
        let tileBounds = NSRect(x: 0, y: 0, width: 47.25, height: 46)
        require(ArkMetrics.favoriteIconRect(in: tileBounds, imageSize: NSSize(width: 32, height: 32)).size == NSSize(width: 16, height: 16),
                "A 32px (16pt@2x or 32pt) icon draws at 16pt, not 20")
        require(ArkMetrics.favoriteIconRect(in: tileBounds, imageSize: NSSize(width: 64, height: 32)).size == NSSize(width: 16, height: 8),
                "A non-square icon keeps its aspect")

        // MARK: In a real sidebar: 8 Favorites lay out 4×2 and a 32px icon is copied 1:1 at 2x.
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 229, height: 720))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = sidebar
        let favoriteIDs = (0..<8).map { _ in UUID() }
        let favoriteItems = favoriteIDs.enumerated().map { index, id in
            SidebarTabItem(id: id, title: "Favorite \(index)", subtitle: "", symbol: "star", isPinned: true, isActive: false, isFavorite: true)
        }
        // A synthetic 32×32 one-pixel checkerboard of pure red and pure blue: any resampling mixes them.
        let checker = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        for x in 0..<32 { for y in 0..<32 { checker.setColor((x + y) % 2 == 0 ? red : blue, atX: x, y: y) } }
        checker.size = NSSize(width: 16, height: 16)   // as imported Arc icons: 32px at 16pt
        let icon = NSImage(size: checker.size); icon.addRepresentation(checker)
        sidebar.faviconProvider = { $0 == favoriteIDs[1] ? icon : nil }
        sidebar.update(tabs: favoriteItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false)
        sidebar.layoutSubtreeIfNeeded()
        let tiles = favoriteIDs.compactMap { id in descendants(sidebar).first { $0.identifier?.rawValue == "favorite-\(id.uuidString)" } }
        require(tiles.count == 8 && Set(tiles.map { $0.frame.minY }).count == 2 && Set(tiles.map { $0.frame.minX }).count == 4,
                "Eight Favorites at 229pt show as four columns, two rows")
        let tile = tiles[1]
        require(tile.frame.width.truncatingRemainder(dividingBy: 0.5) != 0, "The fixture tile has a fractional width (alignment matters)")
        @MainActor func render(_ view: NSView) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * 2)), pixelsHigh: Int(ceil(view.bounds.height * 2)),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        let rendered = render(tile)
        var pure: [(x: Int, y: Int, red: Bool)] = [], mixed = 0
        for x in 0..<rendered.pixelsWide { for y in 0..<rendered.pixelsHigh {
            guard let c = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.greenComponent < 0.02, c.redComponent > 0.98, c.blueComponent < 0.02 { pure.append((x, y, true)) }
            else if c.greenComponent < 0.02, c.blueComponent > 0.98, c.redComponent < 0.02 { pure.append((x, y, false)) }
            else if c.greenComponent < 0.1, c.redComponent > 0.2, c.blueComponent > 0.2 { mixed += 1 }   // red+blue blended = resampled
        } }
        let minX = pure.map(\.x).min() ?? 0, maxX = pure.map(\.x).max() ?? 0, minY = pure.map(\.y).min() ?? 0, maxY = pure.map(\.y).max() ?? 0
        require(pure.count == 1024 && mixed == 0, "All 32×32 icon pixels are copied unblended at 2x (pure \(pure.count), blended \(mixed))")
        require(maxX - minX == 31 && maxY - minY == 31, "The icon covers 32×32 device pixels (16pt at 2x), not 40×40")
        require(pure.allSatisfy { ($0.x - minX + $0.y - minY) % 2 == 0 ? $0.red != pure[0].red || true : true }
                && Set(pure.map { (($0.x - minX + $0.y - minY) % 2 == 0) == $0.red }).count == 1, "The checker pattern survives exactly")
        withExtendedLifetime(window) {}

        // MARK: Hover follows the real pointer (via the test seam), not stale enter/exit events.
        var pointer: NSPoint? = nil
        ArkHover.pointerLocation = { _ in pointer }
        @MainActor func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let hoverSidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 720))
        let hoverWindow = NSWindow(contentRect: hoverSidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hoverWindow.contentView = hoverSidebar
        hoverSidebar.configureSpaces([BrowserSpace(id: 0, name: "One", symbol: "sparkles", colorIndex: 0),
                                      BrowserSpace(id: 1, name: "Two", symbol: "globe", colorIndex: 1)])
        let spaceZero = (0..<60).map { SidebarTabItem(id: UUID(), title: "Zero \($0)", subtitle: "", symbol: "globe", isPinned: false, isActive: $0 == 59) }
        let spaceOne = (0..<3).map { SidebarTabItem(id: UUID(), title: "One \($0)", subtitle: "", symbol: "globe", isPinned: false, isActive: $0 == 0) }
        @MainActor func show(_ items: [SidebarTabItem], _ space: Int) {
            hoverSidebar.update(tabs: items, space: space, canGoBack: false, canGoForward: false, isLoading: false)
            hoverSidebar.layoutSubtreeIfNeeded(); spin()
        }
        @MainActor func hoverTable() -> NSTableView {
            descendants(hoverSidebar).compactMap { $0 as? NSTableView }.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }!
        }
        @MainActor func rowView(titled title: String) -> NSView? {
            descendants(hoverSidebar).first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == title && $0.window != nil }
        }
        /// Unselected rows show their close button only while hovered: the visible hover signal.
        @MainActor func hoveredRows() -> [String] {
            descendants(hoverSidebar).filter { view in
                view.window != nil && view.accessibilityRole() == .button && view.identifier?.rawValue.hasPrefix("tab-row-") == true
                    && view.accessibilityValue() as? String != "Selected"
                    && descendants(view).contains { !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityLabel() == "Close tab" }
            }.compactMap { $0.accessibilityLabel() }
        }
        @MainActor func center(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        show(spaceZero, 0)
        let rowTwo = rowView(titled: "Zero 2")!
        pointer = center(rowTwo)
        rowTwo.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: pointer!, modifierFlags: [], timestamp: 0,
                                                          windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        require(hoveredRows() == ["Zero 2"], "The row under the pointer hovers")
        // Switch Spaces; the pointer moves to the footer. AppKit sends no exit to a page that left the window.
        show(spaceOne, 1)
        pointer = NSPoint(x: 120, y: 10)
        show(spaceZero, 0)
        require(hoveredRows().isEmpty, "Returning to a Space leaves no stale gray on the row hovered before the switch")
        // A still pointer over a row when its page comes back keeps hovering exactly that row.
        pointer = center(rowView(titled: "Zero 4")!)
        show(spaceOne, 1); show(spaceZero, 0)
        require(hoveredRows() == ["Zero 4"], "A still pointer keeps hovering only the row actually under it after a switch")
        // Rebuild with different rows (cells reused): hover is resolved, not reset or carried.
        var renamed = spaceZero
        for index in 0..<10 { renamed[index] = SidebarTabItem(id: UUID(), title: "Fresh \(index)", subtitle: "", symbol: "globe", isPinned: false, isActive: false) }
        show(renamed, 0)
        require(hoveredRows() == ["Fresh 4"], "After a rebuild the reused cell under the still pointer hovers, and only it")
        // Scrolling under a still pointer: hover follows the row now under it.
        let list = hoverTable()
        let clipView = list.enclosingScrollView!.contentView
        clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.minY + 3 * (list.rowHeight + list.intercellSpacing.height)))
        list.enclosingScrollView!.reflectScrolledClipView(clipView)
        hoverSidebar.layoutSubtreeIfNeeded(); spin()
        let under = hoveredRows()
        require(under.count == 1 && under != ["Fresh 4"], "Scrolling moves hover to the row under the pointer (\(under))")
        // The window losing key clears hover (the tracking areas only apply in the key window).
        pointer = nil
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: hoverWindow)
        require(hoveredRows().isEmpty, "Hover clears when the window resigns key")
        // Buttons too: the list's New Tab row (the gray seen stuck in the baseline screenshot).
        clipView.scroll(to: .zero); list.enclosingScrollView!.reflectScrolledClipView(clipView)
        show(spaceOne, 1)
        let newTab = descendants(hoverSidebar).first { $0.accessibilityLabel() == "New tab" && $0.window != nil && $0 is NSButton } as! NSButton
        @MainActor func pixels(_ view: NSView) -> Data? {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: rep); return rep.tiffRepresentation
        }
        pointer = center(newTab)
        newTab.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: pointer!, modifierFlags: [], timestamp: 0,
                                                          windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        let hoveredPixels = pixels(newTab)
        show(spaceZero, 0)
        pointer = NSPoint(x: 120, y: 10)
        show(spaceOne, 1)
        let afterReturn = pixels(newTab)
        newTab.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        require(afterReturn != hoveredPixels && afterReturn == pixels(newTab), "The New Tab button shows no stale hover after a Space round trip")
        ArkHover.pointerLocation = { _ in nil }
        withExtendedLifetime(hoverWindow) {}

        print("PASS: \(checks) sidebar morning checks")
    }
}
