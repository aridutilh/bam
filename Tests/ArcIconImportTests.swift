import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Arc icon-cache import with original synthetic PNGs and invented IDs/URLs.
/// Pure file reads and decoding: no network, no web views, no personal data.
@main enum ArcIconImportTests {
    @MainActor static func main() async throws {
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

        // Per-tab, per-site, per-profile memory store.
        let store = ImportedTabIcons(maximumEntries: 2)
        let home = BrowserProfile.defaultID, work = UUID()
        store.install(loaded[ok]!, for: ok, origin: "https://same.example", profile: home)
        store.install(loaded[other]!, for: other, origin: "https://same.example", profile: home)
        require(store.image(for: ok, address: "https://same.example/a", profile: home) !== store.image(for: other, address: "https://same.example/b", profile: home),
                "Same-origin tabs keep separate imported icons")
        require(store.image(for: ok, address: "https://same.example/elsewhere", profile: home) != nil, "The icon follows the tab within its site")
        require(store.image(for: ok, address: "https://different.example/", profile: home) == nil, "Navigating to another site falls back to the normal favicon")
        require(store.image(for: ok, address: "https://same.example/a", profile: work) == nil, "A tab moved to another login profile loses the imported icon")
        require(store.image(for: ok, address: "https://same.example/a", profile: home)?.size == NSSize(width: 16, height: 16), "32px cache icons draw at 16pt")
        store.install(loaded[ok]!, for: UUID(), origin: "https://third.example", profile: home)
        require(store.count == 2 && store.image(for: ok, address: "https://same.example/a", profile: home) == nil, "The store is bounded; oldest goes first")

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

        // Memory bounds: thumbnails, decoded budget, cancellation between files.
        try png(size: 200, red: 0.4).write(to: path("item-wide"))
        let wideID = UUID()
        let thumb = ArcIconImport.loadIcons(for: [("item-wide", wideID)], in: cache)[wideID]
        require(thumb != nil && thumb!.width <= 64 && thumb!.height <= 64, "Large sources decode as 64 px thumbnails, never full size")
        var budget = ArcIconImport.Limits(); budget.maximumDecodedBytes = 32 * 32 * 4   // room for exactly one 32 px icon
        require(ArcIconImport.loadIcons(for: [("item-ok", ok), ("item-other", other)], in: cache, limits: budget).count == 1,
                "The decoded-memory budget stops the import's icon work")
        var polls = 0
        let cancelled = ArcIconImport.loadIcons(for: [("item-ok", ok), ("item-other", other), ("item-wide", wideID)], in: cache,
                                                isCancelled: { polls += 1; return polls > 1 })
        require(cancelled.count == 1, "Cancellation (shutdown or a newer import) stops between files")

        // Jobs capture the imported site and profile at commit; completion revalidates.
        let jobs = ArcIconImport.jobs(for: added, in: after)
        require(jobs.count == added.count, "Every added web tab gets a job")
        let todayJob = jobs.first { job in after.tabs.first { $0.id == job.tabID }?.saved == nil }!
        let todayOrigin = todayJob.origin
        var navigated = after
        let todayIndex = navigated.tabs.firstIndex { $0.id == todayJob.tabID }!
        navigated.tabs[todayIndex].address = "https://somewhere-else.example/page"   // Today tab navigated during decode
        require(ArcIconImport.stillValid(todayJob, in: navigated) && todayJob.origin == todayOrigin,
                "A navigated tab keeps its job; the icon stays bound to the imported origin, not the new one")
        let navigatedStore = ImportedTabIcons()
        navigatedStore.install(loaded[ok]!, for: todayJob.tabID, origin: todayJob.origin, profile: todayJob.profile)
        require(navigatedStore.image(for: todayJob.tabID, address: navigated.tabs[todayIndex].address, profile: todayJob.profile) == nil,
                "So the old icon is never stamped onto the new site")
        var removedTab = after; removedTab.tabs.removeAll { $0.id == todayJob.tabID }
        require(!ArcIconImport.stillValid(todayJob, in: removedTab), "A tab removed before completion gets no icon")
        var relinked = after; relinked.importLinks?["arc:\(todayJob.itemID)"] = "tab:\(UUID().uuidString)"
        require(!ArcIconImport.stillValid(todayJob, in: relinked), "Changed provenance invalidates the job")
        let keptJob = jobs.first { job in after.tabs.first { $0.id == job.tabID }?.saved?.kind == .kept }!
        var moved = after
        let workProfile = moved.createProfile(name: "Elsewhere")!
        let workSpace = moved.createSpace(name: "Elsewhere", symbol: "globe", colorIndex: 1, profileID: workProfile)!
        _ = moved.moveTab(id: keptJob.tabID, toSpace: workSpace)
        require(!ArcIconImport.stillValid(keptJob, in: moved), "A tab moved to another login profile before completion gets no icon")

        // Persistent cache: relaunch, isolation, deletion, corruption, bounds.
        let diskDirectory = base.appendingPathComponent("Support/ImportedIcons", isDirectory: true)
        let disk = ImportedIconDiskCache(directory: diskDirectory)
        let tabA = UUID(), tabB = UUID(), tabC = UUID()
        require(disk.save([(tabA, home, "https://a.example", loaded[ok]!), (tabB, home, "https://b.example", loaded[other]!),
                           (tabC, work, "https://c.example", loaded[ok]!)]) == 3, "Icons save")
        let indexText = try String(contentsOf: diskDirectory.appendingPathComponent("index.json"), encoding: .utf8)
        require(!indexText.contains("item-") && !indexText.contains(cache.path) && !indexText.contains("SidebarItemsFaviconCache"),
                "The index keeps no Arc item IDs or source paths")
        require(fm.fileExists(atPath: disk.fileURL(profile: work, tab: tabC).path), "Icons are stored per login profile")
        let relaunch = ImportedIconDiskCache(directory: diskDirectory)
        let restored = relaunch.restore(validTabs: [tabA: home, tabB: home, tabC: work])
        require(Set(restored.map(\.tab)) == [tabA, tabB, tabC] && restored.first { $0.tab == tabA }?.origin == "https://a.example"
                && restored.first { $0.tab == tabC }?.profile == work, "Icons survive a relaunch with their site and profile")
        require(abs(red(of: restored.first { $0.tab == tabA }!.image) - 0.9) < 0.05, "Restored pixels match what was saved")
        // Deleted tab and moved profile are pruned, files removed.
        let pruning = ImportedIconDiskCache(directory: diskDirectory)
        let afterPrune = pruning.restore(validTabs: [tabA: home, tabC: home])
        require(Set(afterPrune.map(\.tab)) == [tabA], "Removed tabs and tabs now in another profile are not restored")
        require(!fm.fileExists(atPath: pruning.fileURL(profile: home, tab: tabB).path)
                && !fm.fileExists(atPath: pruning.fileURL(profile: work, tab: tabC).path) && pruning.recordCount == 1,
                "Their files and index entries are deleted")
        pruning.remove(tabs: [tabA])
        require(pruning.recordCount == 0 && !fm.fileExists(atPath: pruning.fileURL(profile: home, tab: tabA).path), "Explicit removal deletes the icon")
        // Corruption: tampered file and damaged index fall back without failing.
        let tamper = ImportedIconDiskCache(directory: diskDirectory)
        tamper.save([(tabA, home, "https://a.example", loaded[ok]!), (tabB, home, "https://b.example", loaded[other]!)])
        try Data("garbage".utf8).write(to: tamper.fileURL(profile: home, tab: tabB))
        try fm.removeItem(at: tamper.fileURL(profile: home, tab: tabA))
        try fm.createSymbolicLink(at: tamper.fileURL(profile: home, tab: tabA), withDestinationURL: tamper.fileURL(profile: home, tab: tabB))
        require(ImportedIconDiskCache(directory: diskDirectory).restore(validTabs: [tabA: home, tabB: home]).isEmpty,
                "Tampered or substituted files are refused (size/hash/symlink checks)")
        try Data("{ not json".utf8).write(to: diskDirectory.appendingPathComponent("index.json"))
        let recovered = ImportedIconDiskCache(directory: diskDirectory)
        require(recovered.restore(validTabs: [tabA: home]).isEmpty && recovered.save([(tabA, home, "https://a.example", loaded[ok]!)]) == 1
                && ImportedIconDiskCache(directory: diskDirectory).restore(validTabs: [tabA: home]).count == 1,
                "A damaged index starts over and the cache keeps working")
        // Bounds: entries and per-file size.
        var tight = ImportedIconDiskCache.Limits(); tight.maximumEntries = 2
        let bounded = ImportedIconDiskCache(directory: base.appendingPathComponent("Bounded", isDirectory: true), limits: tight)
        let three = (0..<3).map { _ in UUID() }
        bounded.save(three.map { ($0, home, "https://x.example", loaded[ok]!) })
        require(bounded.recordCount == 2 && bounded.record(for: three[0]) == nil, "Entry count is bounded; the oldest goes first")
        var small = ImportedIconDiskCache.Limits(); small.maximumFileBytes = 10
        require(ImportedIconDiskCache(directory: base.appendingPathComponent("Small", isDirectory: true), limits: small)
                .save([(UUID(), home, "https://x.example", loaded[ok]!)]) == 0, "Oversized encodings are not stored")
        // Damaged index: duplicate spellings of one UUID, extreme orders, bad records.
        let messy = base.appendingPathComponent("Messy", isDirectory: true)
        let messyTab = UUID()
        let seed = ImportedIconDiskCache(directory: messy)
        seed.save([(messyTab, home, "https://m.example", loaded[ok]!)])
        let good = seed.record(for: messyTab)!
        func entry(_ order: Int, bytes: Int) -> String {
            "{\"profile\":\"\(home.uuidString)\",\"origin\":\"https://m.example\",\"bytes\":\(bytes),\"sha256\":\"\(good.sha256)\",\"order\":\(order)}"
        }
        let messyJSON = "{\"\(messyTab.uuidString.lowercased())\":\(entry(Int.max, bytes: good.bytes)),"
            + "\"\(messyTab.uuidString.uppercased())\":\(entry(-5, bytes: good.bytes)),"
            + "\"\(UUID().uuidString)\":\(entry(3, bytes: -1)),\"not-a-uuid\":\(entry(1, bytes: 10)),"
            + "\"\(UUID().uuidString)\":{\"profile\":\"\(home.uuidString)\",\"origin\":\"https://m.example\",\"bytes\":10,\"sha256\":\"zz\",\"order\":2}}"
        try messyJSON.write(to: messy.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        let tolerant = ImportedIconDiskCache(directory: messy)
        require(tolerant.restore(validTabs: [messyTab: home]).count == 1 && tolerant.recordCount == 1,
                "Duplicate UUID spellings merge, invalid records drop, nothing traps")
        require(tolerant.record(for: messyTab)!.order == 1, "Orders are renumbered, so Int.max can't overflow")
        require(tolerant.save([(UUID(), home, "https://n.example", loaded[other]!)]) == 1 && tolerant.recordCount == 2, "Saving continues after recovery")

        // Reconciliation of Bam's own folder before any decode.
        func ownedFixture(_ name: String) throws -> (dir: URL, kept: UUID, orphan: UUID, unrelated: [URL], outside: URL) {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let keeper = ImportedIconDiskCache(directory: dir)
            let kept = UUID(), orphan = UUID()
            keeper.save([(kept, home, "https://k.example", loaded[ok]!)])
            // An image written without an index entry (crash between image and index).
            try ImportedIconDiskCache.pngData(loaded[other]!)!.write(to: keeper.fileURL(profile: home, tab: orphan))
            // Unrelated names Bam doesn't own, in the root and in a profile folder.
            let notes = dir.appendingPathComponent("notes.txt"); try Data("keep".utf8).write(to: notes)
            let stray = dir.appendingPathComponent(home.uuidString).appendingPathComponent("readme.txt"); try Data("keep".utf8).write(to: stray)
            let foreignDir = dir.appendingPathComponent("not-a-uuid", isDirectory: true)
            try fm.createDirectory(at: foreignDir, withIntermediateDirectories: true)
            let foreignPNG = foreignDir.appendingPathComponent("\(UUID().uuidString).png"); try Data("x".utf8).write(to: foreignPNG)
            // A symlinked "profile" folder pointing outside must not be entered.
            let outsideDir = base.appendingPathComponent("\(name)-outside", isDirectory: true)
            try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            let outside = outsideDir.appendingPathComponent("\(UUID().uuidString).png"); try Data("x".utf8).write(to: outside)
            try fm.createSymbolicLink(at: dir.appendingPathComponent(UUID().uuidString), withDestinationURL: outsideDir)
            return (dir, kept, orphan, [notes, stray, foreignPNG], outside)
        }
        func untouched(_ f: (dir: URL, kept: UUID, orphan: UUID, unrelated: [URL], outside: URL)) -> Bool {
            f.unrelated.allSatisfy { fm.fileExists(atPath: $0.path) } && fm.fileExists(atPath: f.outside.path)
        }
        // 1. Image written before its index entry: orphan removed, indexed icon kept.
        let crash = try ownedFixture("Crash")
        let crashCache = ImportedIconDiskCache(directory: crash.dir)
        require(crashCache.recordCount == 1 && !fm.fileExists(atPath: crashCache.fileURL(profile: home, tab: crash.orphan).path)
                && fm.fileExists(atPath: crashCache.fileURL(profile: home, tab: crash.kept).path) && untouched(crash),
                "An unindexed icon left by a crash is removed; indexed icons and unrelated files stay")
        // 2. Damaged index: every owned icon becomes an orphan and is removed; unrelated files stay.
        let damagedIndex = try ownedFixture("BadIndex")
        try Data("{ broken".utf8).write(to: damagedIndex.dir.appendingPathComponent("index.json"))
        let badCache = ImportedIconDiskCache(directory: damagedIndex.dir)
        require(badCache.recordCount == 0 && !fm.fileExists(atPath: badCache.fileURL(profile: home, tab: damagedIndex.kept).path)
                && untouched(damagedIndex), "A damaged index cleans up Bam's own icons without touching anything else")
        // 3. Missing index: same.
        let missingIndex = try ownedFixture("NoIndex")
        try fm.removeItem(at: missingIndex.dir.appendingPathComponent("index.json"))
        let noIndexCache = ImportedIconDiskCache(directory: missingIndex.dir)
        require(noIndexCache.recordCount == 0 && !fm.fileExists(atPath: noIndexCache.fileURL(profile: home, tab: missingIndex.kept).path)
                && untouched(missingIndex), "A missing index leaves no orphaned icons")
        // 4. Oversized index is treated as damaged.
        let oversized = try ownedFixture("Oversized")
        try Data(count: ImportedIconDiskCache.maximumIndexBytes + 1).write(to: oversized.dir.appendingPathComponent("index.json"))
        require(ImportedIconDiskCache(directory: oversized.dir).recordCount == 0 && untouched(oversized), "An oversized index is not read")
        // 5. Count and byte limits apply before any decode.
        let crowded = base.appendingPathComponent("Crowded", isDirectory: true)
        let filler = ImportedIconDiskCache(directory: crowded)
        let five = (0..<5).map { _ in UUID() }
        filler.save(five.map { ($0, home, "https://f.example", loaded[ok]!) })
        var two = ImportedIconDiskCache.Limits(); two.maximumEntries = 2
        let trimmed = ImportedIconDiskCache(directory: crowded, limits: two)
        require(trimmed.recordCount == 2 && five.prefix(3).allSatisfy { !fm.fileExists(atPath: trimmed.fileURL(profile: home, tab: $0).path) },
                "An index over the entry limit is trimmed (oldest first) before decoding")
        require(trimmed.restore(validTabs: Dictionary(uniqueKeysWithValues: five.map { ($0, home) })).count == 2, "Restore decodes only the bounded set")
        let pngsOnDisk = (try? fm.contentsOfDirectory(atPath: crowded.appendingPathComponent(home.uuidString).path))?.filter { $0.hasSuffix(".png") } ?? []
        require(pngsOnDisk.count == 2, "Only the bounded icons remain on disk, not just in the index: \(pngsOnDisk.count)")
        var byteCap = ImportedIconDiskCache.Limits(); byteCap.maximumTotalBytes = filler.record(for: five[4])!.bytes
        let capped2 = ImportedIconDiskCache(directory: crowded, limits: byteCap)
        require(capped2.recordCount == 1, "The total byte limit applies before decoding too")

        // Folder boundary: no read, write or delete through a symlinked root or profile folder.
        func snapshot(_ dir: URL) -> [String: Data] {
            var result: [String: Data] = [:]
            for case let file as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() {
                if let data = try? Data(contentsOf: file) { result[file.path.replacingOccurrences(of: dir.path, with: "")] = data }
            }
            return result
        }
        // A. Symlinked ImportedIcons root pointing at a valid cache elsewhere.
        let realRoot = base.appendingPathComponent("RealRoot", isDirectory: true)
        let rootTab = UUID()
        ImportedIconDiskCache(directory: realRoot).save([(rootTab, home, "https://r.example", loaded[ok]!)])
        let rootBefore = snapshot(realRoot)
        let linkParent = base.appendingPathComponent("LinkParent", isDirectory: true)
        try fm.createDirectory(at: linkParent, withIntermediateDirectories: true)
        let linkedRoot = linkParent.appendingPathComponent("ImportedIcons")
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let viaLink = ImportedIconDiskCache(directory: linkedRoot)
        require(viaLink.recordCount == 0 && viaLink.restore(validTabs: [rootTab: home]).isEmpty, "A symlinked root is never read")
        require(viaLink.save([(UUID(), home, "https://r.example", loaded[ok]!)]) == 0, "Nothing is written through a symlinked root")
        viaLink.remove(tabs: [rootTab])
        require(snapshot(realRoot) == rootBefore && !rootBefore.isEmpty, "Nothing behind a symlinked root is deleted or changed")
        // B. A valid indexed record whose profile folder is a symlink to outside files.
        for tight in [false, true] {
            let root = base.appendingPathComponent("ProfileLink-\(tight)", isDirectory: true)
            let tab = UUID()
            let seeded = ImportedIconDiskCache(directory: root)
            seeded.save([(tab, home, "https://p.example", loaded[ok]!)])
            let outsideProfile = base.appendingPathComponent("Outside-\(tight)", isDirectory: true)
            try fm.moveItem(at: root.appendingPathComponent(home.uuidString), to: outsideProfile)
            try fm.createSymbolicLink(at: root.appendingPathComponent(home.uuidString), withDestinationURL: outsideProfile)
            let outsideBefore = snapshot(outsideProfile)
            var limits = ImportedIconDiskCache.Limits(); if tight { limits.maximumEntries = 0 }   // would trim (delete) the entry
            let guarded = ImportedIconDiskCache(directory: root, limits: limits)
            require(guarded.restore(validTabs: [tab: home]).isEmpty && guarded.recordCount == 0,
                    "An indexed icon under a symlinked profile folder is not read (limits trimming: \(tight))")
            require(guarded.save([(tab, home, "https://p.example", loaded[other]!)]) == 0, "Nothing is written through a symlinked profile folder")
            guarded.remove(tabs: [tab])
            require(snapshot(outsideProfile) == outsideBefore, "Files behind a symlinked profile folder are never deleted or replaced (\(tight))")
        }

        // Successive imports queue instead of cancelling each other.
        actor Gate {
            private var waiters: [CheckedContinuation<Void, Never>] = []
            var waiting: Int { waiters.count }
            func wait() async { await withCheckedContinuation { waiters.append($0) } }
            func openOne() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
        }
        let gate = Gate()
        let queue = ArcIconImportQueue(decode: { jobs, _ in
            await gate.wait()
            return Dictionary(uniqueKeysWithValues: jobs.map { ($0.tabID, loaded[ok]!) })
        })
        var finished: [[UUID]] = []
        queue.onDecoded = { jobs, icons in finished.append(jobs.map(\.tabID)); _ = icons }
        func job() -> ArcIconImport.IconJob { ArcIconImport.IconJob(itemID: UUID().uuidString, tabID: UUID(), origin: "https://q.example", profile: home) }
        func settle(_ condition: () async -> Bool) async { for _ in 0..<2000 where !(await condition()) { await Task.yield() } }
        let keptBatch = [job(), job()], todayBatch = [job()]
        queue.enqueue(keptBatch, directory: cache)
        await settle { await gate.waiting == 1 }
        queue.enqueue(todayBatch, directory: cache)          // a second import while the first decodes
        require(queue.pendingBatches == 1, "The second import waits; the first keeps decoding")
        await gate.openOne(); await settle { await gate.waiting == 1 }
        await gate.openOne(); await settle { queue.isIdle }
        require(finished == [keptBatch.map(\.tabID), todayBatch.map(\.tabID)], "Both imports' icons arrive, in order (none lost)")
        // Shutdown cancels the running batch and drops queued ones.
        finished.removeAll()
        queue.enqueue([job()], directory: cache); await settle { await gate.waiting == 1 }
        queue.enqueue([job()], directory: cache)
        queue.cancelAll()
        require(queue.isIdle, "Cancel clears the queue")
        await gate.openOne(); for _ in 0..<50 { await Task.yield() }
        require(finished.isEmpty, "A cancelled batch never installs icons")
        let afterCancel = [job()]
        queue.enqueue(afterCancel, directory: cache); await settle { await gate.waiting >= 1 }
        await gate.openOne(); await settle { queue.isIdle }
        require(finished == [afterCancel.map(\.tabID)], "The queue works again after a cancel (an old worker can't clear a new one)")
        print("PASS: \(checks) Arc icon import checks")
    }
}
