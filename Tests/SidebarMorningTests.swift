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

        // MARK: Footer, as in Arc: Downloads left, Spaces centered, + right.
        let footer = ArkFooterLayout(width: 240, spaceCount: 3, selectedIndex: 1)
        let groupWidth = 3 * ArkFooterLayout.step - 2
        require(footer.downloads.minX == 9 && footer.plus.maxX == 240 - 8 && !footer.overflowing && footer.visibleCount == 3,
                "Downloads at the leading edge, + at the trailing edge, three Spaces all shown")
        require(abs((footer.spacesX + groupWidth / 2) - 120) <= 1, "The Space group is centered in the footer")
        for width in stride(from: CGFloat(164), through: 420, by: 13) {
            for count in 1...12 {
                let layout = ArkFooterLayout(width: width, spaceCount: count, selectedIndex: count - 1)
                let end = layout.spacesX + CGFloat(layout.visibleCount + (layout.overflowing ? 1 : 0)) * ArkFooterLayout.step - 2
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
                                       BrowserSpace(id: 1, name: "chill", symbol: "sparkles", colorIndex: 1),
                                       BrowserSpace(id: 2, name: "Solo", symbol: "sun.max", colorIndex: 2)])
        footerSidebar.update(tabs: [], space: 1, canGoBack: false, canGoForward: false, isLoading: false)
        footerSidebar.layoutSubtreeIfNeeded()
        var opened: [String] = []
        footerSidebar.onShowDownloads = { opened.append("downloads") }
        footerSidebar.onShowHistory = { opened.append("history") }
        footerSidebar.onShowRecentlyClosed = { opened.append("recently-closed") }
        footerSidebar.onManageSpaces = { opened.append("manage-spaces") }
        footerSidebar.onNewTab = { opened.append("new-tab") }
        let downloadsButton = descendants(footerSidebar).first { $0.identifier?.rawValue == "sidebar-downloads" } as! NSButton
        require(downloadsButton.accessibilityLabel() == "Downloads" && downloadsButton.toolTip == "Downloads (⌘J)", "The leading button is Downloads")
        downloadsButton.performClick(nil)
        require(opened == ["downloads"], "Clicking it opens Bam's actual Downloads window")
        let libraryMenu = downloadsButton.menu!
        require(libraryMenu.items.map(\.title) == ["Downloads", "History", "Recently Closed", "", "Manage Spaces…"], "Its menu: Downloads, History, Recently Closed, Manage Spaces")
        opened.removeAll()
        for item in libraryMenu.items where !item.isSeparatorItem { _ = item.target.map { NSApp.sendAction(item.action!, to: $0, from: item) } }
        require(opened == ["downloads", "history", "recently-closed", "manage-spaces"], "Every menu item opens the real feature")
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
        withExtendedLifetime(footerWindow) {}; withExtendedLifetime(policyWindow) {}

        print("PASS: \(checks) sidebar morning checks")
    }
}
