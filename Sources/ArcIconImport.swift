import AppKit
import CryptoKit
import ImageIO

/// Arc keeps a small PNG per sidebar item in `SidebarItemsFaviconCache`,
/// beside `StorableSidebar.json`, named by the lowercase MD5 of the item's
/// exact ID string. Bam reads only the files for tabs an import just added,
/// validates each one, and keeps the decoded icons in memory. Nothing is
/// copied into Bam's files, nothing is fetched, and no page is created.
enum ArcIconImport {
    static let cacheDirectoryName = "SidebarItemsFaviconCache"

    struct Limits {
        var maximumBytes = 512 * 1024
        /// Largest source image accepted (declared pixels).
        var maximumDimension = 256
        /// Icons are kept as thumbnails no larger than this; sidebar rows need 32 px.
        var thumbnailPixels = 64
        var maximumIcons = 4000
        /// Total decoded pixel memory one import may hold (RGBA bytes).
        var maximumDecodedBytes = 24 * 1024 * 1024
    }

    /// The icon cache that belongs to this layout file, if it sits beside it.
    /// A layout copied elsewhere has none; that is a normal partial import.
    static func cacheDirectory(besideLayout layout: URL, fileManager: FileManager = .default) -> URL? {
        let directory = layout.deletingLastPathComponent().appendingPathComponent(cacheDirectoryName, isDirectory: true)
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return directory
    }

    /// Lowercase hex MD5 of the exact item ID (case preserved, not normalized).
    static func fileName(forItemID id: String) -> String {
        Insecure.MD5.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Imported tab IDs (Bam) for the Arc item IDs this import added, read from
    /// provenance links that are new compared with `before`.
    static func addedTabs(before: [String: String]?, after: [String: String]?) -> [(itemID: String, tabID: UUID)] {
        let old = before ?? [:]
        return (after ?? [:]).compactMap { key, value in
            guard old[key] == nil, key.hasPrefix("arc:"), value.hasPrefix("tab:"),
                  let tab = UUID(uuidString: String(value.dropFirst(4))) else { return nil }
            return (String(key.dropFirst(4)), tab)
        }.sorted { $0.tabID.uuidString < $1.tabID.uuidString }
    }

    /// One icon to bring over, with everything captured when the import commits:
    /// the Arc item, the Bam tab, and the site and login profile it was imported with.
    struct IconJob: Equatable, Sendable {
        let itemID: String
        let tabID: UUID
        let origin: String
        let profile: UUID
    }
    static func jobs(for added: [(itemID: String, tabID: UUID)], in session: BrowserSession) -> [IconJob] {
        added.compactMap { item in
            guard let tab = session.tabs.first(where: { $0.id == item.tabID }),
                  let url = URL(string: tab.saved?.address ?? tab.address),
                  let origin = WebsiteFaviconStore.originKey(for: url) else { return nil }
            return IconJob(itemID: item.itemID, tabID: item.tabID, origin: origin, profile: session.profileID(for: tab))
        }
    }
    /// Whether a job still describes the tab when its icon is ready: the tab
    /// exists, its provenance still names this Arc item, and its login profile
    /// is unchanged. A navigated tab is fine — the icon keeps its captured
    /// origin and simply doesn't show off that site.
    static func stillValid(_ job: IconJob, in session: BrowserSession) -> Bool {
        guard let tab = session.tabs.first(where: { $0.id == job.tabID }),
              session.importLinks?["arc:\(job.itemID)"] == "tab:\(job.tabID.uuidString)" else { return false }
        return session.profileID(for: tab) == job.profile
    }

    /// Reads and decodes icons for `items`. Each file must be a regular file
    /// (not a symlink) directly inside `directory`, within the byte limit, and
    /// decode as an image no larger than the dimension limit. Anything else is
    /// skipped, so the tab keeps its normal fallback icon.
    /// Stops early when `isCancelled` turns true (shutdown, a newer import) or
    /// when the decoded-memory budget is spent.
    static func loadIcons(for items: [(itemID: String, tabID: UUID)], in directory: URL,
                          limits: Limits = Limits(), isCancelled: () -> Bool = { false }) -> [UUID: CGImage] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var result: [UUID: CGImage] = [:]
        var decodedBytes = 0
        for item in items.prefix(limits.maximumIcons) {
            guard !isCancelled() else { break }
            let file = root.appendingPathComponent(fileName(forItemID: item.itemID), isDirectory: false)
            guard file.deletingLastPathComponent().path == root.path,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= limits.maximumBytes,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: limits.maximumBytes + 1), data.count <= limits.maximumBytes,
                  let image = decode(data, maximumDimension: limits.maximumDimension, thumbnailPixels: limits.thumbnailPixels) else { continue }
            let cost = image.width * image.height * 4
            guard decodedBytes + cost <= limits.maximumDecodedBytes else { break }
            decodedBytes += cost
            result[item.tabID] = image
        }
        return result
    }

    /// Validates the declared size, then decodes straight to a small thumbnail
    /// so a large source never occupies full-size memory.
    static func decode(_ data: Data, maximumDimension: Int, thumbnailPixels: Int = 64) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(thumbnailPixels, max(width, height)))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Runs icon batches one at a time, in import order. A later import queues
/// behind an earlier one instead of cancelling it, so rapid successive
/// imports keep every batch's icons. Only `cancelAll` (shutdown) stops work,
/// and it drops queued batches too.
@MainActor final class ArcIconImportQueue {
    typealias Decode = @Sendable ([ArcIconImport.IconJob], URL) async -> [UUID: CGImage]
    private var batches: [(jobs: [ArcIconImport.IconJob], directory: URL)] = []
    private var worker: Task<Void, Never>?
    private let decode: Decode
    /// Called on the main actor with each finished batch.
    var onDecoded: (([ArcIconImport.IconJob], [UUID: CGImage]) -> Void)?

    init(decode: @escaping Decode = ArcIconImportQueue.decodeFromCache) { self.decode = decode }

    var isIdle: Bool { worker == nil && batches.isEmpty }
    var pendingBatches: Int { batches.count }

    func enqueue(_ jobs: [ArcIconImport.IconJob], directory: URL) {
        guard !jobs.isEmpty else { return }
        batches.append((jobs, directory))
        guard worker == nil else { return }
        let token = UUID(); workerToken = token
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.batches.isEmpty {
                let batch = self.batches.removeFirst()
                let icons = await self.decode(batch.jobs, batch.directory)
                guard !Task.isCancelled else { break }
                self.onDecoded?(batch.jobs, icons)
            }
            // A cancelled worker must not clear a newer one started after it.
            if let self, self.workerToken == token { self.worker = nil }
        }
    }
    private var workerToken: UUID?
    func cancelAll() {
        batches.removeAll()
        worker?.cancel(); worker = nil; workerToken = nil
    }

    /// Off the main thread, cancellable between files.
    nonisolated static let decodeFromCache: Decode = { jobs, directory in
        let task = Task.detached(priority: .utility) {
            ArcIconImport.loadIcons(for: jobs.map { ($0.itemID, $0.tabID) }, in: directory, isCancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

/// Imported per-tab icons, in memory only. Each icon belongs to the page the
/// tab was imported with: once the tab shows another site, the normal
/// favicon takes over. Bounded; the oldest entries go first.
@MainActor final class ImportedTabIcons {
    private struct Entry { let image: NSImage; let origin: String; let profile: UUID; let order: Int }
    private var entries: [UUID: Entry] = [:]
    private var counter = 0
    let maximumEntries: Int
    init(maximumEntries: Int = 4000) { self.maximumEntries = maximumEntries }

    var count: Int { entries.count }
    /// Installs an icon for the site (`origin`) and login profile the tab was
    /// imported with; both are captured when the import commits, never read
    /// back from the tab later.
    func install(_ image: CGImage, for tab: UUID, origin: String, profile: UUID) {
        if entries[tab] == nil, entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.order < $1.value.order })?.key { entries.removeValue(forKey: oldest) }
        counter += 1
        // Point size follows Arc's 2x cache: 32px icons draw at 16pt.
        let scale: CGFloat = image.width >= 32 ? 2 : 1
        let icon = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        entries[tab] = Entry(image: icon, origin: origin, profile: profile, order: counter)
    }
    /// The imported icon while the tab is still on the imported site and in
    /// the same login profile; otherwise the normal favicon applies.
    func image(for tab: UUID, address: String, profile: UUID) -> NSImage? {
        guard let entry = entries[tab], entry.profile == profile, let url = URL(string: address),
              WebsiteFaviconStore.originKey(for: url) == entry.origin else { return nil }
        return entry.image
    }
    func remove(_ tab: UUID) { entries.removeValue(forKey: tab) }
    func removeAll() { entries.removeAll() }
}

/// Bam's private, bounded on-disk home for imported tab icons, so they are
/// still there after a relaunch. Layout: `<directory>/index.json` plus
/// `<directory>/<profile UUID>/<tab UUID>.png`. Icons are re-encoded PNGs of
/// already-validated images; the index records only Bam's own tab and profile
/// IDs, the site origin, size and a SHA-256. No Arc IDs, paths or page data.
/// Not thread-safe by itself: callers use one serial queue/actor context.
final class ImportedIconDiskCache: @unchecked Sendable {
    struct Limits {
        var maximumEntries = 4000
        var maximumFileBytes = 64 * 1024
        var maximumTotalBytes = 16 * 1024 * 1024
        /// Stored icons are the 64 px thumbnails produced at import.
        var maximumDimension = 64
    }
    struct Record: Codable, Equatable {
        var profile: UUID
        var origin: String
        var bytes: Int
        var sha256: String
        var order: Int
    }
    struct Restored { let tab: UUID; let origin: String; let profile: UUID; let image: CGImage }
    let directory: URL
    let limits: Limits
    private var index: [UUID: Record] = [:]
    private var loaded = false
    private var counter = 0

    init(directory: URL, limits: Limits = Limits()) { self.directory = directory; self.limits = limits }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    func fileURL(profile: UUID, tab: UUID) -> URL {
        directory.appendingPathComponent(profile.uuidString, isDirectory: true).appendingPathComponent("\(tab.uuidString).png")
    }
    var recordCount: Int { loadIndexIfNeeded(); return index.count }
    func record(for tab: UUID) -> Record? { loadIndexIfNeeded(); return index[tab] }

    /// A damaged or unreadable index starts the cache over; tabs then use normal favicons.
    /// Loads the index, then — before anything is decoded — applies the count
    /// and byte limits and removes Bam-owned icon files the index doesn't
    /// describe (left by a damaged/missing index or a crash between writing
    /// an image and the index).
    private func loadIndexIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let intact = decodeIndex()
        let before = index
        enforceLimits()
        let removedOrphans = reconcileOwnedFiles()
        if !intact || index != before || removedOrphans {
            if FileManager.default.fileExists(atPath: directory.path) { try? writeIndex() }
        }
    }
    /// The largest index Bam reads; anything bigger is treated as damaged.
    static let maximumIndexBytes = 4 * 1024 * 1024
    private func decodeIndex() -> Bool {
        index = [:]; counter = 0
        guard let values = try? indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return true  // No index yet.
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= Self.maximumIndexBytes,
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return false
        }
        // Tolerate a hand-edited or damaged index: drop implausible records,
        // merge different spellings of one UUID (newest wins), and renumber
        // the order 1…n so the counter can never overflow.
        var merged: [UUID: Record] = [:]
        for (key, record) in decoded {
            guard let tab = UUID(uuidString: key), record.bytes > 0, record.bytes <= limits.maximumFileBytes,
                  !record.origin.isEmpty, record.origin.count <= 2048,
                  record.sha256.count == 64, record.sha256.allSatisfy({ $0.isHexDigit }) else { continue }
            if let existing = merged[tab], existing.order >= record.order { continue }
            merged[tab] = record
        }
        for (tab, record) in merged.sorted(by: { $0.value.order < $1.value.order }) {
            counter += 1
            var renumbered = record; renumbered.order = counter
            index[tab] = renumbered
        }
        return merged.count == decoded.count
    }
    /// Deletes `<profile UUID>/<tab UUID>.png` entries under Bam's own folder
    /// that the index doesn't list, and empty profile folders. Names outside
    /// that pattern are never touched, symlinked folders are never entered,
    /// and a symlink in a PNG's place is removed as a link only. Bounded scan.
    @discardableResult private func reconcileOwnedFiles(scanLimit: Int = 20_000) -> Bool {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                    options: [.skipsHiddenFiles]) else { return false }
        var scanned = 0, changed = false
        for folder in top {
            guard let profile = UUID(uuidString: folder.lastPathComponent),
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { continue }
            var remaining = files.count
            for file in files {
                scanned += 1
                guard scanned <= scanLimit else { return changed }
                guard file.pathExtension == "png", let tab = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                if index[tab]?.profile == profile, file.lastPathComponent == "\(tab.uuidString).png" { continue }
                if (try? fm.removeItem(at: file)) != nil { remaining -= 1; changed = true }
            }
            if remaining == 0 { try? fm.removeItem(at: folder) }
        }
        // Index entries whose file is gone are dropped too.
        for (tab, record) in index where !fm.fileExists(atPath: fileURL(profile: record.profile, tab: tab).path) {
            index.removeValue(forKey: tab); changed = true
        }
        return changed
    }
    private func writeIndex() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Dictionary(uniqueKeysWithValues: index.map { ($0.key.uuidString, $0.value) }))
        try data.write(to: indexURL, options: .atomic)
    }
    private func removeFile(profile: UUID, tab: UUID) { try? FileManager.default.removeItem(at: fileURL(profile: profile, tab: tab)) }

    /// Saves icons for tabs, replacing earlier ones. Returns how many were stored.
    @discardableResult func save(_ items: [(tab: UUID, profile: UUID, origin: String, image: CGImage)]) -> Int {
        loadIndexIfNeeded()
        var stored = 0
        for item in items {
            guard item.image.width <= limits.maximumDimension, item.image.height <= limits.maximumDimension,
                  let data = Self.pngData(item.image), data.count <= limits.maximumFileBytes else { continue }
            if let old = index[item.tab], old.profile != item.profile { removeFile(profile: old.profile, tab: item.tab) }
            let file = fileURL(profile: item.profile, tab: item.tab)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch { continue }
            counter += 1
            index[item.tab] = Record(profile: item.profile, origin: item.origin, bytes: data.count, sha256: Self.sha256(data), order: counter)
            stored += 1
        }
        enforceLimits()
        try? writeIndex()
        return stored
    }

    /// Loads icons for tabs that still exist with the same login profile.
    /// Entries for removed tabs, moved profiles, damaged or substituted files
    /// are deleted, so the cache never outlives what it describes.
    func restore(validTabs: [UUID: UUID]) -> [Restored] {
        loadIndexIfNeeded()
        var restored: [Restored] = []
        var changed = false
        for (tab, record) in index.sorted(by: { $0.value.order < $1.value.order }) {
            guard validTabs[tab] == record.profile, let image = readImage(profile: record.profile, tab: tab, expected: record) else {
                removeFile(profile: record.profile, tab: tab); index.removeValue(forKey: tab); changed = true; continue
            }
            restored.append(Restored(tab: tab, origin: record.origin, profile: record.profile, image: image))
        }
        if changed { try? writeIndex() }
        return restored
    }
    /// Forgets icons for tabs that are gone (or all of them).
    func remove(tabs: Set<UUID>) {
        loadIndexIfNeeded()
        var changed = false
        for tab in tabs { if let record = index.removeValue(forKey: tab) { removeFile(profile: record.profile, tab: tab); changed = true } }
        if changed { try? writeIndex() }
    }

    private func readImage(profile: UUID, tab: UUID, expected: Record) -> CGImage? {
        let file = fileURL(profile: profile, tab: tab)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size == expected.bytes, size <= limits.maximumFileBytes,
              let data = try? Data(contentsOf: file), Self.sha256(data) == expected.sha256 else { return nil }
        return ArcIconImport.decode(data, maximumDimension: limits.maximumDimension, thumbnailPixels: limits.maximumDimension)
    }
    private func enforceLimits() {
        var total = index.values.reduce(0) { $0 + $1.bytes }
        for (tab, record) in index.sorted(by: { $0.value.order < $1.value.order })
            where index.count > limits.maximumEntries || total > limits.maximumTotalBytes {
            index.removeValue(forKey: tab); removeFile(profile: record.profile, tab: tab); total -= record.bytes
        }
    }
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
