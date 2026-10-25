import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Arc icon-cache import with original synthetic PNGs and invented IDs/URLs.
/// Pure file reads and decoding: no network, no web views, no personal data.
@main enum ArcIconImportTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let base = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("arc-icons-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func png(size: Int, red: CGFloat) -> Data {
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
            return data as Data
        }
        func red(of image: CGImage) -> CGFloat {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return CGFloat(context.data!.load(as: UInt8.self)) / 255
        }

        // File naming: lowercase MD5 of the exact ID, case preserved.
        require(ArcIconImport.fileName(forItemID: "abc") == "900150983cd24fb0d6963f7d28e17f72", "MD5 of the exact ID")
        require(ArcIconImport.fileName(forItemID: "ABC") != ArcIconImport.fileName(forItemID: "abc"), "ID case is not normalized")

        // The cache is used only when it sits beside the chosen layout.
        let arc = base.appendingPathComponent("Arc", isDirectory: true)
        let cache = arc.appendingPathComponent(ArcIconImport.cacheDirectoryName, isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
            : fm.currentDirectoryPath + "/Tests/Fixtures/arc/StorableSidebar.json")
        let layout = arc.appendingPathComponent("StorableSidebar.json")
        try fm.copyItem(at: fixture, to: layout)
        require(ArcIconImport.cacheDirectory(besideLayout: layout)?.standardizedFileURL == cache.standardizedFileURL, "Cache beside the layout is found")
        let elsewhere = base.appendingPathComponent("Copied", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.copyItem(at: fixture, to: elsewhere.appendingPathComponent("StorableSidebar.json"))
        require(ArcIconImport.cacheDirectory(besideLayout: elsewhere.appendingPathComponent("StorableSidebar.json")) == nil,
                "A layout copied elsewhere has no icons (normal partial import)")
        let linked = base.appendingPathComponent("Linked", isDirectory: true)
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.appendingPathComponent(ArcIconImport.cacheDirectoryName), withDestinationURL: cache)
        require(ArcIconImport.cacheDirectory(besideLayout: linked.appendingPathComponent("StorableSidebar.json")) == nil, "A symlinked cache folder is refused")

        // Validation of each file.
        let ok = UUID(), other = UUID(), big = UUID(), huge = UUID(), junk = UUID(), symlink = UUID(), missing = UUID(), folder = UUID()
        func path(_ id: String) -> URL { cache.appendingPathComponent(ArcIconImport.fileName(forItemID: id)) }
        try png(size: 32, red: 0.9).write(to: path("item-ok"))
        try png(size: 32, red: 0.1).write(to: path("item-other"))
        try png(size: 16, red: 0.5).write(to: path("item-big"))
        try png(size: 300, red: 0.5).write(to: path("item-huge"))
        try Data("not an image".utf8).write(to: path("item-junk"))
        try fm.createSymbolicLink(at: path("item-symlink"), withDestinationURL: path("item-ok"))
        try fm.createDirectory(at: path("item-folder"), withIntermediateDirectories: true)
        var limits = ArcIconImport.Limits(); limits.maximumBytes = 4096
        try Data(count: 5000).write(to: path("item-big"))   // over the byte limit
        let loaded = ArcIconImport.loadIcons(for: [("item-ok", ok), ("item-other", other), ("item-big", big), ("item-huge", huge),
                                                   ("item-junk", junk), ("item-symlink", symlink), ("item-missing", missing), ("item-folder", folder)],
                                             in: cache, limits: limits)
        require(Set(loaded.keys) == [ok, other], "Only valid, regular, small, decodable images load: \(loaded.keys.count)")
        require(abs(red(of: loaded[ok]!) - 0.9) < 0.05 && abs(red(of: loaded[other]!) - 0.1) < 0.05,
                "Two tabs keep their own distinct icons (no origin merging)")
        var capped = ArcIconImport.Limits(); capped.maximumIcons = 1
        require(ArcIconImport.loadIcons(for: [("item-ok", ok), ("item-other", other)], in: cache, limits: capped).count == 1, "Icon count is bounded")

        // Per-tab, per-site memory store.
        let store = ImportedTabIcons(maximumEntries: 2)
        store.install(loaded[ok]!, for: ok, address: "https://same.example/a")
        store.install(loaded[other]!, for: other, address: "https://same.example/b")
        require(store.image(for: ok, address: "https://same.example/a") !== store.image(for: other, address: "https://same.example/b"),
                "Same-origin tabs keep separate imported icons")
        require(store.image(for: ok, address: "https://same.example/elsewhere") != nil, "The icon follows the tab within its site")
        require(store.image(for: ok, address: "https://different.example/") == nil, "Navigating to another site falls back to the normal favicon")
        require(store.image(for: ok, address: "https://same.example/a")?.size == NSSize(width: 16, height: 16), "32px cache icons draw at 16pt")
        store.install(loaded[ok]!, for: UUID(), address: "https://third.example/")
        require(store.count == 2 && store.image(for: ok, address: "https://same.example/a") == nil, "The store is bounded; oldest goes first")

        // End to end with the synthetic layout: provenance → files → icons.
        let source = try ArcImport.load(from: layout)
        require(source.sourceURL == layout, "Loaded layouts remember their file for the icon cache")
        let before = BrowserSession.fresh()
        let after = ArcImport.apply(source, to: before).session
        let added = ArcIconImport.addedTabs(before: before.importLinks, after: after.importLinks)
        require(added.count == after.tabs.count - before.tabs.count, "Every added tab is mapped back to its Arc item ID")
        require(ArcIconImport.addedTabs(before: after.importLinks, after: after.importLinks).isEmpty, "A repeat import adds no icon work")
        for (index, item) in added.prefix(5).enumerated() { try png(size: 32, red: CGFloat(index) / 5).write(to: path(item.itemID)) }
        let fromLayout = ArcIconImport.loadIcons(for: added, in: ArcIconImport.cacheDirectory(besideLayout: layout)!)
        require(fromLayout.count == 5 && Set(fromLayout.keys).isSubset(of: Set(added.map(\.tabID))), "Icons resolve for exactly the cached imported tabs")
        print("PASS: \(checks) Arc icon import checks")
    }
}
