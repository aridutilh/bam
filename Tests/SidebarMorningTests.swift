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
                let tile = (ArkMetrics.sidebarContentWidth(width) - CGFloat(columns - 1) * ArkMetrics.favoriteGap) / CGFloat(columns)
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

        // MARK: Drag feedback: one tap per change of accepted target in a drag, none for moves over the same target.
        var gate = ArkDropFeedbackGate()
        require(gate.shouldTap(sequence: 1, target: "3:1"), "Entering an accepted target taps")
        require(!gate.shouldTap(sequence: 1, target: "3:1") && !gate.shouldTap(sequence: 1, target: "3:1"), "Moving over the same target doesn't tap again")
        require(gate.shouldTap(sequence: 1, target: "4:1"), "A new target taps once")
        require(!gate.shouldTap(sequence: 1, target: nil), "A refused position never taps")
        require(gate.shouldTap(sequence: 1, target: "4:1"), "Coming back to an accepted target after a refused one taps")
        require(gate.shouldTap(sequence: 2, target: "4:1"), "A new drag starts fresh")
        // Dropping into Favorites: the pointer picks an insertion slot, and the tiles at or after it move on one.
        let tileW: CGFloat = 50, step = tileW + ArkMetrics.favoriteGap, rowStep = ArkMetrics.favoriteHeight + ArkMetrics.favoriteGap
        func slot(_ x: CGFloat, _ y: CGFloat, count: Int = 6) -> Int {
            ArkMetrics.favoriteInsertionSlot(at: NSPoint(x: x, y: y), count: count, columns: 4, leading: 8, tileWidth: tileW)
        }
        require(slot(8 + 5, 10) == 0 && slot(8 + tileW - 5, 10) == 1 && slot(8 + step + tileW - 5, 10) == 2,
                "Left of a tile's middle inserts before it; right of it, after it")
        require(slot(8 + 5, rowStep + 10) == 4 && slot(8 + 3 * step + tileW - 2, rowStep + 10) == 6 && slot(300, 300) == 6,
                "The second row continues the count; past the last tile is the end")
        require(slot(8, 10, count: 0) == 0, "An empty grid's only slot is the first")
        require((0..<6).map { ArkMetrics.favoriteSlot(forTile: $0, gap: 2) } == [0, 1, 3, 4, 5, 6]
                    && (0..<3).map { ArkMetrics.favoriteSlot(forTile: $0, gap: nil) } == [0, 1, 2],
                "Tiles at or after the gap move on one slot; without a gap nothing moves")

        // MARK: Space sheet fields: editable text sits on the field's vertical center, inset from the edge.
        let fieldCell = ArkCenteredFieldCell.editable(); fieldCell.font = .systemFont(ofSize: 13)
        let fieldBounds = NSRect(x: 0, y: 0, width: 200, height: 26)
        let textBox = fieldCell.drawingRect(forBounds: fieldBounds)
        require(abs(textBox.midY - fieldBounds.midY) <= 0.5 && textBox.minX == ArkCenteredFieldCell.sideInset
                    && textBox.height < fieldBounds.height && fieldCell.titleRect(forBounds: fieldBounds) == textBox,
                "Space name text is vertically centered and inset (\(textBox) in \(fieldBounds))")
        require(fieldCell.isEditable && fieldCell.isSelectable && fieldCell.usesSingleLineMode, "The centered field cell stays editable")

        // MARK: In a real sidebar: 8 Favorites lay out 4×2 and a 32px icon is copied 1:1 at 2x.
        // 230pt gives a fractional tile (49.25pt) with the sidebar's content edges, so alignment is exercised.
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 230, height: 720))
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
                "Eight Favorites at 230pt show as four columns, two rows")
        let tile = tiles[1]
        require(tile.frame.width.truncatingRemainder(dividingBy: 0.5) != 0, "The fixture tile has a fractional width (alignment matters)")
        // Arc's edges: content starts 8pt in and runs to within 1pt of the sidebar's trailing edge (the page card's gap is
        // the only margin there): no doubled trailing inset, no reserved scroller gutter.
        let tileEdges = tiles.map { $0.convert($0.bounds, to: sidebar) }
        require(abs((tileEdges.map(\.maxX).max() ?? 0) - (sidebar.bounds.width - 1)) < 0.01 && abs((tileEdges.map(\.minX).min() ?? 0) - 8) < 0.01,
                "Favorites span the sidebar's content edges: \(tileEdges.map(\.minX).min() ?? 0)–\(tileEdges.map(\.maxX).max() ?? 0) of \(sidebar.bounds.width)")
        if let list = descendants(sidebar).compactMap({ $0 as? NSTableView }).first(where: { $0.identifier?.rawValue == "sidebar-tab-list" }),
           let listScroll = list.enclosingScrollView {
            let edge = listScroll.convert(listScroll.bounds, to: sidebar)
            require(abs(edge.maxX - (sidebar.bounds.width - 1)) < 0.01 && !listScroll.hasVerticalScroller,
                    "The tab list reaches the trailing content edge with no system scroller over its rows: \(edge.maxX) of \(sidebar.bounds.width)")
        } else { require(false, "The sidebar has a tab list") }
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

        // MARK: Folder focus: a pointer click keeps focus (AX, arrows) but draws no keyboard ring.
        let focusSidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let focusWindow = NSWindow(contentRect: focusSidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        focusWindow.contentView = focusSidebar
        let folderID = UUID(), insideID = UUID(), selectedID = UUID()
        var tree = [SidebarTabItem(id: folderID, title: "Merge", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: false),
                    SidebarTabItem(id: selectedID, title: "Selected page", subtitle: "", symbol: "globe", isPinned: false, isActive: true)]
        @MainActor func showTree() {
            focusSidebar.update(tabs: tree, space: 0, canGoBack: false, canGoForward: false, isLoading: false); focusSidebar.layoutSubtreeIfNeeded()
        }
        focusSidebar.onToggleFolder = { _ in
            tree[0].isExpanded.toggle()
            if tree[0].isExpanded {
                tree.insert(SidebarTabItem(id: insideID, title: "Inside", subtitle: "", symbol: "globe", isPinned: true, isActive: false, depth: 1, parentFolderID: folderID), at: 1)
            } else { tree.removeAll { $0.id == insideID } }
            showTree()
        }
        showTree()
        @MainActor func folderRow() -> NSView { descendants(focusSidebar).first { $0.identifier?.rawValue == "tab-row-\(folderID.uuidString)" }! }
        @MainActor func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: focusWindow.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        @MainActor func key(_ code: UInt16, to view: NSView) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: focusWindow.windowNumber,
                                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        folderRow().mouseDown(with: mouse(.leftMouseDown)); folderRow().mouseUp(with: mouse(.leftMouseUp))
        let clicked = folderRow()
        require(tree[0].isExpanded && focusWindow.firstResponder === clicked, "A click opens the folder and keeps it focused (arrows, VoiceOver)")
        let clickedPixels = pixels(clicked)
        focusWindow.makeFirstResponder(nil)
        let unfocusedPixels = pixels(folderRow())
        require(clickedPixels == unfocusedPixels, "No focus ring after a pointer click, including after the folder's reload")
        focusWindow.makeFirstResponder(folderRow())   // keyboard/programmatic focus (Focus Sidebar, arrows)
        require(pixels(folderRow()) != unfocusedPixels, "Keyboard focus still draws a visible ring")
        folderRow().mouseDown(with: mouse(.leftMouseDown)); folderRow().mouseUp(with: mouse(.leftMouseUp))
        require(!tree[0].isExpanded && focusWindow.firstResponder === folderRow() && pixels(folderRow()) == pixels(folderRow()),
                "Clicking the keyboard-focused folder closes it and keeps focus")
        let closedClicked = pixels(folderRow())
        focusWindow.makeFirstResponder(nil)
        require(closedClicked == pixels(folderRow()), "Pointer input hides a ring the keyboard had shown")
        // Pointer-focused, then a key: focus becomes visible (Down moves to the row below, with its ring).
        folderRow().mouseDown(with: mouse(.leftMouseDown)); folderRow().mouseUp(with: mouse(.leftMouseUp))
        key(125, to: focusWindow.firstResponder as! NSView)
        let inside = descendants(focusSidebar).first { $0.identifier?.rawValue == "tab-row-\(insideID.uuidString)" }!
        let insideFocused = pixels(inside)
        require(focusWindow.firstResponder === inside, "Down from the clicked folder focuses the row inside")
        focusWindow.makeFirstResponder(nil)
        require(insideFocused != pixels(inside), "Arrow-key focus draws its ring")
        // Review: View ▸ Focus Sidebar on the row that is already first responder from a pointer click must show
        // the ring (AppKit doesn't call becomeFirstResponder again for the same row).
        tree = [SidebarTabItem(id: folderID, title: "Merge", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: false),
                SidebarTabItem(id: insideID, title: "Unselected page", subtitle: "", symbol: "globe", isPinned: false, isActive: false)]
        showTree()
        folderRow().mouseDown(with: mouse(.leftMouseDown)); folderRow().mouseUp(with: mouse(.leftMouseUp))
        let pointerFocused = folderRow()
        let pointerPixels = pixels(pointerFocused)
        focusWindow.makeFirstResponder(nil); let restingPixels = pixels(folderRow())
        require(pointerPixels == restingPixels, "Fixture: the click left pointer-mode focus (no ring)")
        folderRow().mouseDown(with: mouse(.leftMouseDown)); folderRow().mouseUp(with: mouse(.leftMouseUp))
        let sameRow = focusWindow.firstResponder as? NSView
        require(sameRow === folderRow() && pixels(folderRow()) == pixels(folderRow()), "Fixture: the folder is first responder after the click")
        let clickedAgain = pixels(folderRow())
        require(focusSidebar.focusTabList() && focusWindow.firstResponder === sameRow, "Focus Sidebar lands on that same row (no new first responder)")
        let viaFocusSidebar = pixels(folderRow())
        require(viaFocusSidebar != clickedAgain, "Focus Sidebar shows the keyboard ring even on the already-focused row")
        // And the reload after a click still restores pointer mode (no ring), while keyboard mode survives a reload.
        key(124, to: focusWindow.firstResponder as! NSView)   // → opens the folder (a reload) with keyboard focus
        let afterKeyboardReload = pixels(folderRow())
        focusWindow.makeFirstResponder(nil)
        require(focusWindow.firstResponder !== folderRow() && afterKeyboardReload != pixels(folderRow()), "Keyboard-mode focus keeps its ring through a reload")
        // The folder just opened by keyboard settles on the exact open glyph once its short lid animation ends.
        RunLoop.main.run(until: Date().addingTimeInterval(ArkFolderGlyph.toggleDuration + 0.2))
        let settledGlyph = descendants(folderRow()).first { $0.identifier?.rawValue.hasPrefix("folder-glyph") == true } as? NSImageView
        require(settledGlyph?.identifier?.rawValue == "folder-glyph-open" && settledGlyph?.image?.accessibilityDescription == "Open folder",
                "An opened folder ends on the open glyph (\(settledGlyph?.identifier?.rawValue ?? "none"))")
        // A row reused mid-animation for another folder in the same state shows that folder's settled glyph, not a
        // frame of the old folder's lid. An empty folder toggles in place (no rows inserted), so its lid animates; then
        // scrolling it away makes the table recycle its row for a folder further down.
        @MainActor func glyph(_ row: NSView) -> Data? {
            (descendants(row).first { $0.identifier?.rawValue.hasPrefix("folder-glyph") == true } as? NSImageView)?.image?.tiffRepresentation
        }
        let manyFolders = (0..<80).map { _ in UUID() }
        tree = manyFolders.enumerated().map { index, id in
            SidebarTabItem(id: id, title: "Folder \(index)", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: index != 0)
        }
        showTree()
        let folderList = descendants(focusSidebar).compactMap { $0 as? NSTableView }.first { $0.window != nil && $0.numberOfRows >= 80 }!
        @MainActor func settle() { folderList.layoutSubtreeIfNeeded(); folderList.prepareContent(in: folderList.visibleRect); folderList.layoutSubtreeIfNeeded() }
        folderList.scrollRowToVisible(0); settle()
        let animating = descendants(focusSidebar).first { $0.identifier?.rawValue == "tab-row-\(manyFolders[0].uuidString)" }!
        tree[0].isExpanded = true; showTree()   // its lid starts opening
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        require(glyph(animating) != nil && glyph(animating) != glyph(descendants(focusSidebar).first { $0.identifier?.rawValue == "tab-row-\(manyFolders[1].uuidString)" }!),
                "The lid is mid-animation")
        folderList.scrollRowToVisible(79); settle()
        let reusedAs = manyFolders.first { animating.identifier?.rawValue == "tab-row-\($0.uuidString)" }
        require(reusedAs != nil && reusedAs != manyFolders[0], "The animating row was recycled for another folder (the case under test)")
        let shown = descendants(focusSidebar).filter { view in view.window != nil && manyFolders.dropFirst().contains { view.identifier?.rawValue == "tab-row-\($0.uuidString)" } }
        require(shown.count > 3 && Set(shown.map(glyph)).count == 1, "A row recycled mid-animation shows its new folder's settled glyph")
        RunLoop.main.run(until: Date().addingTimeInterval(ArkFolderGlyph.toggleDuration + 0.1))
        require(Set(shown.map(glyph)).count == 1, "No late frame of the old folder lands afterwards")
        withExtendedLifetime(focusWindow) {}

        // MARK: Folder glyph: Bam's own vector folder, tinted, distinct open and closed.
        @MainActor func glyphPixels(_ open: Bool, scale: Int) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ArkFolderGlyph.image(open: open, tint: NSColor(srgbRed: 0.2, green: 0.25, blue: 0.95, alpha: 1)).draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        let closedGlyph = glyphPixels(false, scale: 2), openGlyph = glyphPixels(true, scale: 2)
        require(closedGlyph.tiffRepresentation != openGlyph.tiffRepresentation, "Open and closed folders look different")
        var tinted = 0, covered = 0
        for x in 0..<32 { for y in 0..<32 {
            guard let c = closedGlyph.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
            covered += 1; if c.blueComponent > c.redComponent + 0.4 { tinted += 1 }
        } }
        require(covered > 32 * 32 / 3 && tinted > covered / 2, "The folder is a filled shape in the Space's tint, not a thin outline (\(tinted)/\(covered))")
        require(glyphPixels(false, scale: 3).pixelsWide == 48, "Vector glyph renders at any scale")
        // Toggling tilts the front panel through Bam's own in-between shapes, ending exactly on the closed or open face.
        let closedFront = ArkFolderGlyph.frontCorners(openness: 0), openFront = ArkFolderGlyph.frontCorners(openness: 1)
        let halfway = ArkFolderGlyph.frontCorners(openness: 0.5)
        require(closedFront[2] == NSPoint(x: 15, y: 11.1) && openFront[2] == NSPoint(x: 15.6, y: 9.4)
                    && halfway[2].x > closedFront[2].x && halfway[2].x < openFront[2].x && halfway[2].y < closedFront[2].y && halfway[2].y > openFront[2].y,
                "The front panel's top edge moves between the closed and open faces (\(halfway[2]))")
        require(ArkFolderGlyph.frontCorners(openness: -1) == closedFront && ArkFolderGlyph.frontCorners(openness: 2) == openFront, "Openness is clamped")

        // MARK: Footer, as in Arc: Downloads left, Spaces centered, + right.
        let footer = ArkFooterLayout(width: 240, spaceCount: 3, selectedIndex: 1)
        let groupWidth = 3 * footer.step - 2
        require(footer.downloads.minX == 9 && footer.plus.maxX == 240 - 8 && !footer.overflowing && footer.visibleCount == 3,
                "Downloads at the leading edge, + at the trailing edge, three Spaces all shown")
        require(abs((footer.spacesX + groupWidth / 2) - 120) <= 1, "The Space group is centered in the footer")
        for width in stride(from: CGFloat(164), through: 420, by: 13) {
            for count in 1...12 {
                let layout = ArkFooterLayout(width: width, spaceCount: count, selectedIndex: count - 1)
                let end = layout.spacesX + CGFloat(layout.visibleCount + (layout.overflowing ? 1 : 0)) * layout.step - 2
                require(layout.spacesX >= layout.downloads.maxX + 4 && end <= layout.plus.minX - 4,
                        "Spaces never overlap Downloads or + (\(count) at \(width))")
                require(layout.visibleCount >= 1 && (layout.overflowing == (layout.visibleCount < count)), "Overflow only when Spaces don't fit")
                require((layout.startIndex..<(layout.startIndex + layout.visibleCount)).contains(count - 1), "The selected Space stays visible")
            }
        }
        let footerSidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let footerWindow = NSWindow(contentRect: footerSidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        footerWindow.contentView = footerSidebar
        footerSidebar.configureSpaces([BrowserSpace(id: 0, name: "Explore", symbol: "globe", colorIndex: 0),
                                       BrowserSpace(id: 1, name: "Reading", symbol: "sparkles", colorIndex: 1),
                                       BrowserSpace(id: 2, name: "Projects", symbol: "sun.max", colorIndex: 2)])
        footerSidebar.update(tabs: [], space: 1, canGoBack: false, canGoForward: false, isLoading: false)
        footerSidebar.layoutSubtreeIfNeeded()
        var opened: [String] = []
        footerSidebar.onShowDownloads = { opened.append("downloads") }
        footerSidebar.onShowHistory = { opened.append("history") }
        footerSidebar.onShowRecentlyClosed = { opened.append("recently-closed") }
        footerSidebar.onManageSpaces = { opened.append("manage-spaces") }
        footerSidebar.onNewTab = { opened.append("new-tab") }
        let libraryButton = descendants(footerSidebar).first { $0.identifier?.rawValue == "sidebar-library" } as! NSButton
        require(libraryButton.accessibilityLabel() == "Archived Tabs" && libraryButton.toolTip == "Archived Tabs", "The leading button is Arc's archive box")
        libraryButton.performClick(nil)
        require(opened == ["recently-closed"], "Clicking it opens Archived Tabs")
        let libraryMenu = libraryButton.menu!
        require(libraryMenu.items.map(\.title) == ["Archived Tabs", "Downloads", "History", "", "Manage Spaces…"], "Its menu: Archived Tabs, Downloads, History, Manage Spaces")
        opened.removeAll()
        for item in libraryMenu.items where !item.isSeparatorItem { _ = item.target.map { NSApp.sendAction(item.action!, to: $0, from: item) } }
        require(opened == ["recently-closed", "downloads", "history", "manage-spaces"], "Every menu item opens the real feature")
        let footerViews = descendants(footerSidebar).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.frame.minY >= footerSidebar.bounds.height - 40 }
        require(!footerViews.contains { ($0.accessibilityLabel() ?? "").hasPrefix("Picture in Picture") || $0.accessibilityLabel() == "Manage Spaces" },
                "No PiP or Spaces stack button in the footer")
        let spaceButtons = descendants(footerSidebar).filter { ($0.accessibilityLabel() ?? "").hasPrefix("Switch to ") && !$0.isHidden }
        require(spaceButtons.count == 3, "All three actual Spaces keep their buttons")
        let spacesMid = (spaceButtons.map(\.frame.minX).min()! + spaceButtons.map(\.frame.maxX).max()!) / 2
        require(abs(spacesMid - footerSidebar.bounds.midX) <= 1, "Space buttons are centered")
        let plusButton = descendants(footerSidebar).first { $0.accessibilityLabel() == "New tab" && $0.frame.minY >= footerSidebar.bounds.height - 40 } as! NSButton
        plusButton.performClick(nil)
        require(opened.last == "new-tab" && plusButton.frame.maxX == footerSidebar.bounds.width - 8, "+ at the trailing edge opens a new tab")
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: footerWindow.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        require(spaceButtons.allSatisfy { $0.menu(for: rightClick)?.items.map(\.title) == ["Manage Spaces…"] },
                "Space buttons keep Manage Spaces… in their context menu")

        // MARK: Display policy: internal addresses, blank placeholders, imported-folder provenance.
        require(SidebarDisplayPolicy.visibleAddress("orbit://newtab").isEmpty && SidebarDisplayPolicy.visibleAddress("ORBIT://video").isEmpty
                && SidebarDisplayPolicy.visibleAddress("https://example.com/") == "https://example.com/", "Internal orbit:// addresses are never shown")
        require(SidebarDisplayPolicy.readableAddress("orbit://newtab") == "New Tab" && SidebarDisplayPolicy.readableAddress("orbit://video") == "Picture in Picture demo"
                && SidebarDisplayPolicy.readableAddress(ArcEaselReference.address(for: UUID())) == "Arc Easel"
                && SidebarDisplayPolicy.readableAddress("orbit://future-page") == "Bam page"
                && SidebarDisplayPolicy.readableAddress("https://docs.example/a") == "https://docs.example/a",
                "Recently Closed names Bam's own pages plainly and leaves web addresses as they are")
        let blank = BrowserTab(title: "New tab", address: "orbit://newtab", space: 0)
        let page = BrowserTab(title: "Docs", address: "https://docs.example/", space: 0)
        var keptBlank = BrowserTab(title: "New tab", address: "orbit://newtab", space: 0)
        keptBlank.saved = SavedTabState(kind: .kept, address: "orbit://newtab", isUnloaded: false)
        require(SidebarDisplayPolicy.hidesPlaceholder(blank, activeID: page.id, inSplit: false), "An unselected unsaved blank New Tab has no row")
        require(!SidebarDisplayPolicy.hidesPlaceholder(blank, activeID: blank.id, inSplit: false), "The selected blank tab stays listed")
        require(!SidebarDisplayPolicy.hidesPlaceholder(blank, activeID: page.id, inSplit: true), "A split pane is never hidden")
        require(!SidebarDisplayPolicy.hidesPlaceholder(keptBlank, activeID: page.id, inSplit: false), "A saved item is never hidden")
        require(!SidebarDisplayPolicy.hidesPlaceholder(page, activeID: blank.id, inSplit: false), "Real pages are never hidden")
        let importedFolder = UUID(), otherFolder = UUID()
        let links = ["arc:abc": "folder:\(importedFolder.uuidString)", "arc:def": "tab:\(UUID().uuidString)", "arc:x": "flattened",
                     "chrome:1": "folder:\(otherFolder.uuidString)", "arc:bad": "folder:not-a-uuid"]
        require(SidebarDisplayPolicy.arcImportedFolderIDs(links) == [importedFolder] && SidebarDisplayPolicy.arcImportedFolderIDs(nil).isEmpty,
                "Only folders the Arc import recorded are marked")
        // Rows: no internal address in tooltips; the imported note on imported folders only.
        let policySidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let policyWindow = NSWindow(contentRect: policySidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        policyWindow.contentView = policySidebar
        let blankRowID = UUID(), arcFolderID = UUID(), plainFolderID = UUID()
        policySidebar.update(tabs: [
            SidebarTabItem(id: arcFolderID, title: "Pull Requests", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: false, importedFromArc: true),
            SidebarTabItem(id: plainFolderID, title: "Mine", subtitle: "", symbol: "folder", isPinned: true, isActive: false, isFolder: true, isExpanded: false),
            SidebarTabItem(id: blankRowID, title: "New tab", subtitle: "orbit://newtab", symbol: "star", isPinned: false, isActive: true)
        ], space: 0, canGoBack: false, canGoForward: false, isLoading: false)
        policySidebar.layoutSubtreeIfNeeded()
        @MainActor func policyRow(_ id: UUID) -> NSView { descendants(policySidebar).first { $0.identifier?.rawValue == "tab-row-\(id.uuidString)" }! }
        require(policyRow(blankRowID).toolTip?.contains("orbit") == false, "A blank tab's tooltip never shows orbit://newtab")
        require(policyRow(arcFolderID).toolTip?.contains(SidebarDisplayPolicy.arcImportedFolderNote) == true
                && (policyRow(arcFolderID).accessibilityHelp() ?? "").contains("Imported from Arc as saved links"), "Imported folders say so (tooltip and VoiceOver)")
        require(policyRow(plainFolderID).toolTip?.contains("Imported") == false && (policyRow(plainFolderID).accessibilityHelp() ?? "").contains("Imported") == false,
                "Other folders don't")
        let searchField = descendants(policySidebar).first { $0.accessibilityLabel() == "Search or enter a web address" }!
        policySidebar.setAddress("orbit://newtab", title: "New tab")
        require(searchField.toolTip?.contains("orbit") == false && searchField.toolTip?.hasPrefix("Search or enter address") == true,
                "The address field's tooltip never shows an internal address")
        policySidebar.setAddress("https://docs.example/a", title: "Docs")
        require(searchField.toolTip == "https://docs.example/a", "A real page's address still shows")
        // Site settings: a button inside the field for a page (not Bam's own), beside the still-reachable extension library.
        policySidebar.layoutSubtreeIfNeeded()
        @MainActor func control(_ id: String) -> NSView { descendants(policySidebar).first { $0.identifier?.rawValue == id }! }
        let siteButton = control("site-settings"), library = control("extension-library")
        require(!siteButton.isHidden && !library.isHidden && !siteButton.frame.intersects(library.frame)
                    && searchField.frame.contains(siteButton.frame) && searchField.frame.contains(library.frame),
                "A page's field shows site settings and the extension library side by side, inside the field")
        var anchor: NSView?
        policySidebar.onSiteSettings = { anchor = $0 }
        (siteButton as? NSButton)?.performClick(nil)
        require(anchor === siteButton, "Clicking site settings anchors its popover on the button")
        policySidebar.setAddress("orbit://newtab", title: "New tab"); policySidebar.layoutSubtreeIfNeeded()
        require(siteButton.isHidden && !library.isHidden, "Bam's own pages show no site settings; the library stays")
        withExtendedLifetime(footerWindow) {}; withExtendedLifetime(policyWindow) {}

        // MARK: The list's scroll thumb sits in the gap beside the card, as in Arc, never over a row.
        typealias Thumb = SidebarScrollIndicator
        require(Thumb.knobRect(trackHeight: 400, contentHeight: 300, visibleHeight: 400, offset: 0, width: 4) == nil,
                "A list that fits shows no thumb")
        if let top = Thumb.knobRect(trackHeight: 400, contentHeight: 1600, visibleHeight: 400, offset: 0, width: ArkMetrics.scrollThumbWidth),
           let end = Thumb.knobRect(trackHeight: 400, contentHeight: 1600, visibleHeight: 400, offset: 1200, width: ArkMetrics.scrollThumbWidth),
           let tiny = Thumb.knobRect(trackHeight: 400, contentHeight: 100_000, visibleHeight: 400, offset: 50_000, width: 4) {
            require(top.minX == ArkMetrics.scrollThumbLead && top.width == 4 && top.minY == ArkMetrics.scrollThumbInset &&
                    abs(top.height - (400 - 2 * ArkMetrics.scrollThumbInset) / 4) < 0.01, "The thumb's lead, width, top inset and proportion: \(top)")
            require(abs(end.maxY - (400 - ArkMetrics.scrollThumbInset)) < 0.01, "At the end the thumb rests its inset above the bottom: \(end)")
            require(tiny.height == ArkMetrics.scrollThumbMinLength, "A very long list keeps a grabbable thumb")
        } else { require(false, "An overflowing list has a thumb") }

        let gap: CGFloat = 8, thumbSidebarWidth: CGFloat = 240
        let thumbRoot = NSView(frame: NSRect(x: 0, y: 0, width: thumbSidebarWidth + gap + 200, height: 720))
        let thumbWindow = NSWindow(contentRect: thumbRoot.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        thumbWindow.contentView = thumbRoot
        let thumbSidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: thumbSidebarWidth, height: 720))
        let thumb = Thumb(frame: .zero)
        thumbRoot.addSubview(thumbSidebar); thumbRoot.addSubview(thumb)
        thumbSidebar.configureSpaces([BrowserSpace(id: 0, name: "One", symbol: "sparkles", colorIndex: 0)])
        thumbSidebar.update(tabs: spaceZero, space: 0, canGoBack: false, canGoForward: false, isLoading: false)
        // As BrowserController lays it out: from the rows' trailing edge across the gap to the card.
        thumb.frame = NSRect(x: thumbSidebarWidth - ArkMetrics.sidebarTrailing, y: 0, width: gap + ArkMetrics.sidebarTrailing, height: 0)
        thumbSidebar.onTabListChange = { thumb.scrollView = thumbSidebar.tabListScrollView; thumb.refresh() }
        thumbRoot.layoutSubtreeIfNeeded(); thumbSidebar.layoutSubtreeIfNeeded(); spin()
        let thumbList = thumbSidebar.tabListScrollView
        let listRect = thumbList.convert(thumbList.bounds, to: thumbRoot)
        require(thumb.scrollView === thumbList && abs(thumb.frame.minY - listRect.minY) < 0.01 && abs(thumb.frame.height - listRect.height) < 0.01,
                "The thumb's column spans exactly the visible list: \(thumb.frame) vs \(listRect)")
        require(thumb.hitTest(NSPoint(x: thumb.frame.midX, y: thumb.frame.midY)) == nil,
                "At rest the thumb is hidden and the gap belongs to the resize handle")
        // Pointing at the gap at rest (someone reaching for the resize handle) must not reveal the thumb.
        @MainActor func pointerEvent(_ type: NSEvent.EventType, _ local: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: thumb.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: thumbWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var handleBarSuppressed: [Bool] = []
        thumb.onInteractionChange = { handleBarSuppressed.append($0) }
        thumb.mouseEntered(with: pointerEvent(.mouseMoved, NSPoint(x: thumb.bounds.midX, y: 4)))
        for y in stride(from: CGFloat(2), to: thumb.bounds.height, by: 6) { thumb.mouseMoved(with: pointerEvent(.mouseMoved, NSPoint(x: thumb.bounds.midX, y: y))) }
        spin()
        require((0..<Int(thumb.frame.height)).allSatisfy { thumb.hitTest(NSPoint(x: thumb.frame.midX, y: thumb.frame.minY + CGFloat($0) + 0.5)) == nil } &&
                !thumb.isInteracting && handleBarSuppressed.isEmpty,
                "Hovering the gap at rest reveals no thumb and leaves the gap (and its bar) to the resize handle")
        thumb.mouseExited(with: pointerEvent(.mouseMoved, NSPoint(x: thumb.bounds.midX, y: 4)))
        let thumbClip = thumbList.contentView
        thumbClip.scroll(to: NSPoint(x: 0, y: 200)); thumbList.reflectScrolledClipView(thumbClip); spin()
        // The knob, in root coordinates.
        let rows = descendants(thumbSidebar).filter { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? "").hasPrefix("Zero ") && $0.window != nil }
        let rowsMaxX = rows.map { $0.convert($0.bounds, to: thumbRoot).maxX }.max() ?? 0
        let knobProbe = (0..<Int(thumb.frame.height)).map { CGFloat($0) + thumb.frame.minY + 0.5 }
            .first { thumb.hitTest(NSPoint(x: thumb.frame.midX, y: $0)) != nil }
        require(knobProbe != nil, "Scrolling shows the thumb, and it takes the pointer")
        // Resting the pointer on a visible thumb holds it past the fade and widens it; the handle's bar hides meanwhile.
        let onKnob = thumb.convert(NSPoint(x: thumb.frame.midX, y: knobProbe! + 2), from: thumbRoot)
        thumb.mouseEntered(with: pointerEvent(.mouseMoved, onKnob)); thumb.mouseMoved(with: pointerEvent(.mouseMoved, onKnob))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        require(thumb.isInteracting && handleBarSuppressed == [true] && thumb.hitTest(NSPoint(x: thumb.frame.midX, y: knobProbe! + 2)) != nil,
                "A hovered visible thumb stays past the fade, and the resize handle's bar is suppressed: \(handleBarSuppressed)")
        thumb.mouseExited(with: pointerEvent(.mouseMoved, onKnob))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        require(!thumb.isInteracting && handleBarSuppressed == [true, false] &&
                thumb.hitTest(NSPoint(x: thumb.frame.midX, y: knobProbe! + 2)) == nil,
                "Once the pointer leaves, the thumb fades and the gap returns to the resize handle")
        thumbClip.scroll(to: NSPoint(x: 0, y: 200)); thumbList.reflectScrolledClipView(thumbClip)
        thumbClip.scroll(to: NSPoint(x: 0, y: 210)); thumbList.reflectScrolledClipView(thumbClip); spin()
        let knobMinX = thumb.frame.minX + ArkMetrics.scrollThumbLead, knobMaxX = knobMinX + ArkMetrics.scrollThumbWidth
        require(!rows.isEmpty && rowsMaxX <= thumbSidebarWidth - ArkMetrics.sidebarTrailing + 0.01 && knobMinX >= rowsMaxX + 1,
                "The thumb starts past the rows' trailing edge: rows end \(rowsMaxX), thumb \(knobMinX)")
        require(knobMaxX <= thumbSidebarWidth + gap - 3 + 0.01, "The thumb keeps clear of the card: ends \(knobMaxX), card \(thumbSidebarWidth + gap)")
        require(thumb.hitTest(NSPoint(x: thumb.frame.midX, y: thumb.frame.maxY - 1)) == nil || knobProbe! > thumb.frame.maxY - 30,
                "Beside the thumb (not on it) the gap still belongs to the resize handle")
        // Dragging the thumb scrolls the list, clamped to its ends.
        let grab = thumb.convert(NSPoint(x: thumb.frame.midX, y: knobProbe! + 2), from: thumbRoot)
        @MainActor func drag(_ type: NSEvent.EventType, _ local: NSPoint) -> NSEvent { pointerEvent(type, local) }
        let before = thumbClip.bounds.minY
        thumb.mouseDown(with: drag(.leftMouseDown, grab))
        thumb.mouseDragged(with: drag(.leftMouseDragged, NSPoint(x: grab.x, y: grab.y + 40)))
        let dragged = thumbClip.bounds.minY
        thumb.mouseDragged(with: drag(.leftMouseDragged, NSPoint(x: grab.x, y: grab.y + 5000)))
        let travel = (thumbList.documentView?.frame.height ?? 0) - thumbClip.bounds.height
        require(dragged > before + 40 && abs(thumbClip.bounds.minY - travel) < 0.5, "Dragging the thumb scrolls the list and stops at its end (\(before) → \(dragged) → \(thumbClip.bounds.minY) of \(travel))")
        thumb.mouseUp(with: drag(.leftMouseUp, grab))
        // Hidden while paging Spaces or with the sidebar away; no thumb, no hit.
        thumb.isSuppressed = true
        require(thumb.hitTest(NSPoint(x: thumb.frame.midX, y: thumb.frame.midY)) == nil, "A suppressed thumb never takes the pointer")
        withExtendedLifetime(thumbWindow) {}

        // MARK: Yab-grade chrome (0.26 night): titles, the trailing minus/cross, toolbar row, footer, list edge fades.
        require(SidebarDisplayPolicy.rowTitle("ariport – Deployments – Vercel", address: "https://vercel.com/team/ariport") == "ariport – Deployments",
                "A trailing site name that matches the host is dropped")
        require(SidebarDisplayPolicy.rowTitle("Steve Jobs at 27 - YouTube", address: "https://www.youtube.com/watch?v=1") == "Steve Jobs at 27"
                && SidebarDisplayPolicy.rowTitle("Portfolio | Notion", address: "https://www.notion.so/x") == "Portfolio"
                && SidebarDisplayPolicy.rowTitle("serafim on X: \"Arc\" / X", address: "https://x.com/serafim/status/1") == "serafim on X: \"Arc\""
                && SidebarDisplayPolicy.rowTitle("1115 8th Ave W - Google Maps", address: "https://www.google.com/maps/place/1") == "1115 8th Ave W",
                "YouTube, Notion, X and Google Maps suffixes go")
        require(SidebarDisplayPolicy.rowTitle("Bam — a fast, native browser", address: "https://bambrowser.com/") == "Bam — a fast, native browser"
                && SidebarDisplayPolicy.rowTitle("Pull requests · aridutilh/bam", address: "https://github.com/aridutilh/bam/pulls") == "Pull requests · aridutilh/bam"
                && SidebarDisplayPolicy.rowTitle("Linear – Inbox", address: "https://linear.app/inbox") == "Linear – Inbox"
                && SidebarDisplayPolicy.rowTitle("A - Vercel", address: "https://vercel.com") == "A - Vercel",
                "Suffixes that aren't the site's name, and titles that would be left too short, stay whole")
        let rawAddress = "https://open.substack.com/pub/notboring/p/more-intelligence"
        require(SidebarDisplayPolicy.rowTitle("open.substack.com/pub/notboring/p/more-intelligence", address: rawAddress) == "open.substack.com"
                && SidebarDisplayPolicy.rowTitle(rawAddress, address: rawAddress, knownTitle: "More intelligence") == "More intelligence"
                && SidebarDisplayPolicy.rowTitle("", address: "https://www.example.com/a/b") == "example.com",
                "A title that is only an address shows the best-known title, then the host; never a raw path")
        require(!SidebarDisplayPolicy.looksLikeAddress("Dashboard", address: "https://dashboard.render.com/")
                && !SidebarDisplayPolicy.looksLikeAddress("Node.js docs", address: "https://nodejs.org/docs")
                && SidebarDisplayPolicy.looksLikeAddress("github.com", address: "https://github.com/"), "Only address-like titles count as addresses")
        require(SidebarDisplayPolicy.rowTitle("New tab", address: "orbit://newtab") == "New tab", "Bam's own pages keep their names")

        ArkHover.pointerLocation = { _ in pointer }
        defer { ArkHover.pointerLocation = { _ in nil } }
        let chrome = SidebarView(frame: NSRect(x: 0, y: 0, width: 228, height: 520))
        let chromeWindow = NSWindow(contentRect: chrome.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        chromeWindow.contentView = chrome
        chrome.configureSpaces((0..<6).map { BrowserSpace(id: $0, name: "S\($0)", symbol: "globe", colorIndex: $0 % 6, emoji: ["🫠", "🏠", "🎒", "💼", "🌱", "🧪"][$0]) })
        let todayID = UUID(), openKeptID = UUID(), downKeptID = UUID()
        var chromeItems = [
            SidebarTabItem(id: openKeptID, title: "Open kept", subtitle: "https://a.invalid", symbol: "globe", isPinned: true, isActive: false),
            SidebarTabItem(id: downKeptID, title: "Down kept", subtitle: "https://b.invalid", symbol: "globe", isPinned: true, isActive: false, isUnloaded: true),
            SidebarTabItem(id: todayID, title: "Today page - YouTube", subtitle: "https://www.youtube.com/watch", symbol: "globe", isPinned: false, isActive: true)
        ] + (0..<40).map { SidebarTabItem(id: UUID(), title: "Filler \($0)", subtitle: "", symbol: "globe", isPinned: false, isActive: false) }
        chrome.update(tabs: chromeItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false)
        chrome.layoutSubtreeIfNeeded(); spin()
        @MainActor func chromeRow(_ id: UUID) -> NSView { descendants(chrome).first { $0.identifier?.rawValue == "tab-row-\(id.uuidString)" }! }
        @MainActor func shownButton(_ row: NSView) -> NSView? {
            descendants(row).first { !$0.isHiddenOrHasHiddenAncestor && ["Close tab", "Unload tab", "Remove tab"].contains($0.accessibilityLabel() ?? "") }
        }
        @MainActor func hover(_ row: NSView, _ on: Bool) {
            let event = NSEvent.enterExitEvent(with: on ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: chromeWindow.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            // Hover resyncs (after an update) read the pointer; keep it where the hover is.
            pointer = on ? row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil) : nil
            if on { row.mouseEntered(with: event) } else { row.mouseExited(with: event) }
            row.layoutSubtreeIfNeeded()
        }
        require(descendants(chromeRow(todayID)).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Today page" }
                && chromeRow(todayID).accessibilityLabel() == "Today page", "Rows show (and speak) the cleaned title")
        require([todayID, openKeptID, downKeptID].allSatisfy { shownButton(chromeRow($0)) == nil }, "No row, selected included, shows a button at rest")
        var removed: [UUID] = [], closedIDs: [UUID] = []
        chrome.onRemoveSavedTab = { removed.append($0) }; chrome.onCloseTab = { closedIDs.append($0) }
        for (id, label) in [(todayID, "Close tab"), (openKeptID, "Unload tab"), (downKeptID, "Remove tab")] {
            let row = chromeRow(id); hover(row, true)
            let button = shownButton(row) as? NSButton
            require(button?.accessibilityLabel() == label, "Hovering shows \(label) (\(button?.accessibilityLabel() ?? "none"))")
            button?.performClick(nil); hover(row, false)
        }
        require(closedIDs == [todayID, openKeptID] && removed == [downKeptID],
                "The cross closes a Today tab, the minus unloads an open kept tab, and an unloaded kept tab's cross removes it")
        // The kept tab goes down under the pointer: its minus becomes the cross in place.
        let openRow = chromeRow(openKeptID); hover(openRow, true)
        let morphing = shownButton(openRow)
        chromeItems[0].isUnloaded = true
        chrome.update(tabs: chromeItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false); spin()
        require(shownButton(openRow) === morphing && morphing?.accessibilityLabel() == "Remove tab",
                "Once down, the same button is the cross that removes it (\(String(describing: shownButton(openRow)?.accessibilityLabel())), \(String(describing: morphing?.accessibilityLabel())), same row \(chromeRow(openKeptID) === openRow))")
        hover(openRow, false)
        // Keyboard and VoiceOver never see the hover-only button: the row carries the same action, and an unloaded
        // kept tab's menu can remove it.
        removed = []
        let downRow = chromeRow(downKeptID)
        let rowActions = downRow.accessibilityCustomActions() ?? []
        require(rowActions.map(\.name) == ["Remove tab"] && chromeRow(todayID).accessibilityCustomActions()?.map(\.name) == ["Close tab"],
                "Rows offer their trailing action to VoiceOver (\(rowActions.map(\.name)))")
        _ = rowActions.first?.handler?()
        let menuEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: chromeWindow.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let removeItem = downRow.menu(for: menuEvent)?.items.first { $0.title == "Remove Tab" }
        require(removeItem != nil && chromeRow(todayID).menu(for: menuEvent)?.items.contains { $0.title == "Remove Tab" } == false,
                "Only an unloaded kept tab's menu offers Remove Tab")
        if let removeItem, let action = removeItem.action { _ = (removeItem.target as AnyObject).perform(action) }
        require(removed == [downKeptID, downKeptID], "The VoiceOver action and the menu item both remove the kept tab")
        // A name the person gave a kept tab is shown exactly as typed.
        var named = SidebarTabItem(id: UUID(), title: "Plans - Notion", subtitle: "https://www.notion.so/x", symbol: "globe", isPinned: true, isActive: false)
        require(named.displayTitle == "Plans", "A page title loses its site suffix")
        named.hasCustomTitle = true
        require(named.displayTitle == "Plans - Notion", "A custom name keeps every word")
        // Toolbar row: lights, toggle and navigation share one center line.
        let toggleButton = descendants(chrome).first { $0.accessibilityLabel() == "Hide sidebar" }!
        let reloadButton = descendants(chrome).first { $0.accessibilityLabel() == "Reload page" }!
        require(toggleButton.frame.midY == ArkMetrics.toolbarCenterY && reloadButton.frame.midY == ArkMetrics.toolbarCenterY,
                "The sidebar toggle and reload sit on the traffic lights' row (center \(ArkMetrics.toolbarCenterY))")
        chrome.update(tabs: chromeItems, space: 0, canGoBack: false, canGoForward: false, isLoading: true)
        require(descendants(chrome).contains { $0.accessibilityLabel() == "Stop loading" }, "Reload becomes Stop while loading")
        chrome.update(tabs: chromeItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false)
        // Footer: all six emoji Spaces fit at the default width, as in Yab.
        let twoSpaces = ArkFooterLayout(width: 228, spaceCount: 2, selectedIndex: 0), sixSpaces = ArkFooterLayout(width: 228, spaceCount: 6, selectedIndex: 0)
        require(twoSpaces.step == ArkFooterLayout.maximumStep && !sixSpaces.overflowing && sixSpaces.step >= ArkFooterLayout.minimumStep && sixSpaces.step < twoSpaces.step,
                "Arc's spacing for a few Spaces; six still fit a 228pt footer by closing up (\(sixSpaces.step))")
        require(ArkFooterLayout(width: 228, spaceCount: 12, selectedIndex: 11).overflowing, "Many Spaces overflow into a menu")
        // List edges: rows fade under the heading only once scrolled, and above the footer while more rows lie below.
        let chromeList = chrome.tabListScrollView
        chrome.layoutSubtreeIfNeeded(); spin()
        @MainActor func edgeAlphas() -> (top: CGFloat, bottom: CGFloat)? {
            guard let mask = chromeList.layer?.mask as? CAGradientLayer, let colors = mask.colors as? [CGColor] else { return nil }
            return (colors.first?.alpha ?? 1, colors.last?.alpha ?? 1)
        }
        require(edgeAlphas().map { $0.top == 1 && $0.bottom == 0 } == true, "At the top only the bottom edge fades (\(String(describing: edgeAlphas())))")
        chromeList.contentView.scroll(to: NSPoint(x: 0, y: 60)); chromeList.reflectScrolledClipView(chromeList.contentView)
        require(edgeAlphas().map { $0.top == 0 && $0.bottom == 0 } == true, "Mid-list both edges fade")
        let listEnd = (chromeList.documentView?.frame.height ?? 0) - chromeList.contentView.bounds.height
        chromeList.contentView.scroll(to: NSPoint(x: 0, y: listEnd)); chromeList.reflectScrolledClipView(chromeList.contentView)
        require(edgeAlphas().map { $0.top == 0 && $0.bottom == 1 } == true, "At the end only the top edge fades")
        require(chrome.footerRuleOpacity == 0, "At the end of the list the footer's hairline is gone")
        chromeList.contentView.scroll(to: .zero); chromeList.reflectScrolledClipView(chromeList.contentView)
        require(chrome.footerRuleOpacity == 1, "With tabs continuing below, Arc's hairline sits over the footer")
        // Tab actions in Arc's order: Copy Link… first, then the row's own entries, Close Tabs Below after Close Tab.
        chrome.tabActionItems = { _ in ([NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""), NSMenuItem(title: "Rename…", action: nil, keyEquivalent: "")],
                                        NSMenuItem(title: "Move to", action: nil, keyEquivalent: ""), NSMenuItem(title: "Close Tabs Below", action: nil, keyEquivalent: "")) }
        let tabMenuClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: chromeWindow.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let todayMenu = chromeRow(todayID).menu(for: tabMenuClick)!.items.map(\.title)
        require(Array(todayMenu.prefix(4)) == ["Copy Link", "Rename…", "Move to", ""], "Tab actions lead the menu (\(todayMenu))")
        require(todayMenu.firstIndex(of: "Close Tabs Below") == todayMenu.firstIndex(of: "Close Tab").map { $0 + 1 }, "Close Tabs Below follows Close Tab on a Today row")
        require(!chromeRow(downKeptID).menu(for: tabMenuClick)!.items.contains { $0.title == "Close Tabs Below" }, "Kept rows have no Close Tabs Below")
        require(todayMenu.firstIndex(of: "Move to") == 2 && !todayMenu.contains("Move to Space") && todayMenu.last == "Close Tabs Below",
                "Today rows use Arc's Move to after the actions (no second Space list), closing last (\(todayMenu))")
        // Double-click renames in place: Return keeps the name.
        var tabRenames: [(UUID, String)] = []
        chrome.onRenameTab = { tabRenames.append(($0, $1)) }
        let renameRow = chromeRow(todayID)
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: renameRow.convert(NSPoint(x: 80, y: 18), to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: chromeWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        renameRow.mouseDown(with: doubleClick)
        let renameField = descendants(renameRow).first { $0.identifier?.rawValue == "tab-rename-field" } as? NSTextField
        require(renameField?.stringValue == "Today page", "Double-click turns the title into a field holding the shown name")
        renameField?.stringValue = "Morning read"
        if let renameField, let editor = renameField.currentEditor() as? NSTextView {
            _ = (renameField.delegate as? NSTextFieldDelegate)?.control?(renameField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        } else if let renameField { (renameField.delegate as? NSTextFieldDelegate)?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: renameField)) }
        require(tabRenames.count == 1 && tabRenames[0].0 == todayID && tabRenames[0].1 == "Morning read", "Return renames the tab (\(tabRenames))")
        require(descendants(renameRow).first { $0.identifier?.rawValue == "tab-rename-field" } == nil, "The field goes away after renaming")
        // Arc's sidebar player: above the footer, the list ends above it; its buttons reach the controller.
        let listBottomBefore = chromeList.convert(chromeList.bounds, to: chrome).maxY
        var mediaCalls: [String] = []
        chrome.onMediaPlayPause = { mediaCalls.append("playpause") }; chrome.onMediaSelect = { mediaCalls.append("select") }
        chrome.onMediaMute = { mediaCalls.append("mute") }; chrome.onMediaNext = { mediaCalls.append("next") }
        chrome.setMediaPlayer(SidebarMediaState(tabID: todayID, title: "Song", isPlaying: true, isMuted: false, canPrevious: false, canNext: true))
        chrome.layoutSubtreeIfNeeded(); spin(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); chrome.layoutSubtreeIfNeeded()
        let player = descendants(chrome).first { $0.identifier?.rawValue == "sidebar-media-player" }!
        @MainActor func playerButton(_ label: String) -> NSButton? { descendants(player).first { $0.accessibilityLabel() == label } as? NSButton }
        require(!player.isHidden && player.frame.maxY <= chrome.bounds.height - 40 && chromeList.convert(chromeList.bounds, to: chrome).maxY <= player.frame.minY,
                "The player sits above the footer and the list ends above it (\(player.isHidden) \(player.frame) \(chrome.bounds) list \(chromeList.convert(chromeList.bounds, to: chrome)))")
        require(chromeList.convert(chromeList.bounds, to: chrome).maxY < listBottomBefore, "The list makes room for the player")
        require(playerButton("Pause") != nil && playerButton("Previous")?.isEnabled == false && playerButton("Next")?.isEnabled == true,
                "Pause while playing; previous/next only when the page has them")
        playerButton("Pause")?.performClick(nil); playerButton("Go to Song")?.performClick(nil); playerButton("Mute")?.performClick(nil); playerButton("Next")?.performClick(nil)
        require(mediaCalls == ["playpause", "select", "mute", "next"], "Player buttons reach the controller (\(mediaCalls))")
        chrome.setMediaPlayer(SidebarMediaState(tabID: todayID, title: "Song", isPlaying: false, isMuted: true, canPrevious: false, canNext: false))
        require(playerButton("Play") != nil && playerButton("Unmute") != nil, "Paused and muted states show Play and Unmute")
        chrome.setMediaPlayer(nil); chrome.layoutSubtreeIfNeeded(); spin(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        require(player.isHidden && abs(chromeList.convert(chromeList.bounds, to: chrome).maxY - listBottomBefore) < 0.5, "Without media the player goes and the list returns")
        // Rows: Arc's speaker after the icon while the page plays; clicking it mutes.
        var muteToggles: [UUID] = []
        chrome.onToggleTabMute = { muteToggles.append($0) }
        var audioItems = chromeItems; audioItems[2].isPlayingAudio = true
        chrome.update(tabs: audioItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false); spin()
        let speaker = descendants(chromeRow(todayID)).first { $0.identifier?.rawValue == "tab-speaker" } as? NSButton
        require(speaker?.isHidden == false && speaker?.accessibilityLabel() == "Mute tab", "A playing tab shows its speaker")
        speaker?.performClick(nil)
        require(muteToggles == [todayID], "Clicking the speaker mutes that tab")
        audioItems[2].isPlayingAudio = false; audioItems[2].isMuted = true
        chrome.update(tabs: audioItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false); spin()
        require(speaker?.isHidden == false && speaker?.accessibilityLabel() == "Unmute tab", "A muted tab keeps a slashed speaker")
        chrome.update(tabs: chromeItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false); spin()
        require(speaker?.isHidden == true, "No sound, no speaker")
        // A single row moving (drop, Move Earlier/Later) slides: the table moves that row's view rather than
        // rebuilding the list, so its view (and any state on it) survives the move.
        chromeList.contentView.scroll(to: .zero); chromeList.reflectScrolledClipView(chromeList.contentView)
        // Animated list changes only run in a visible window: show this one, off screen.
        chromeWindow.setFrameOrigin(NSPoint(x: -6000, y: 200)); chromeWindow.orderBack(nil); spin()
        let movedID = chromeItems[3].id, movedView = chromeRow(movedID)
        var reordered = chromeItems; let moved = reordered.remove(at: 3); reordered.insert(moved, at: 5)
        chrome.update(tabs: reordered, space: 0, canGoBack: false, canGoForward: false, isLoading: false); spin()
        require(chromeRow(movedID) === movedView, "A moved row keeps its view and slides to its new place")
        chrome.update(tabs: chromeItems, space: 0, canGoBack: false, canGoForward: false, isLoading: false); spin()
        chromeWindow.orderOut(nil)
        withExtendedLifetime(chromeWindow) {}

        print("PASS: \(checks) sidebar morning checks")
    }
}
