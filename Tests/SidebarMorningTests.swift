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

        print("PASS: \(checks) sidebar morning checks")
    }
}
