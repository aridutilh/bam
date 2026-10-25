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
        var maximumDimension = 256
        var maximumIcons = 4000
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

    /// Reads and decodes icons for `items`. Each file must be a regular file
    /// (not a symlink) directly inside `directory`, within the byte limit, and
    /// decode as an image no larger than the dimension limit. Anything else is
    /// skipped, so the tab keeps its normal fallback icon.
    static func loadIcons(for items: [(itemID: String, tabID: UUID)], in directory: URL,
                          limits: Limits = Limits()) -> [UUID: CGImage] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var result: [UUID: CGImage] = [:]
        for item in items.prefix(limits.maximumIcons) {
            let file = root.appendingPathComponent(fileName(forItemID: item.itemID), isDirectory: false)
            guard file.deletingLastPathComponent().path == root.path,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= limits.maximumBytes,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: limits.maximumBytes + 1), data.count <= limits.maximumBytes,
                  let image = decode(data, maximumDimension: limits.maximumDimension) else { continue }
            result[item.tabID] = image
        }
        return result
    }

    static func decode(_ data: Data, maximumDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Imported per-tab icons, in memory only. Each icon belongs to the page the
/// tab was imported with: once the tab shows another site, the normal
/// favicon takes over. Bounded; the oldest entries go first.
@MainActor final class ImportedTabIcons {
    private struct Entry { let image: NSImage; let origin: String; let order: Int }
    private var entries: [UUID: Entry] = [:]
    private var counter = 0
    let maximumEntries: Int
    init(maximumEntries: Int = 4000) { self.maximumEntries = maximumEntries }

    var count: Int { entries.count }
    func install(_ image: CGImage, for tab: UUID, address: String) {
        guard let url = URL(string: address), let origin = WebsiteFaviconStore.originKey(for: url) else { return }
        if entries[tab] == nil, entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.order < $1.value.order })?.key { entries.removeValue(forKey: oldest) }
        counter += 1
        // Point size follows Arc's 2x cache: 32px icons draw at 16pt.
        let scale: CGFloat = image.width >= 32 ? 2 : 1
        let icon = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        entries[tab] = Entry(image: icon, origin: origin, order: counter)
    }
    /// The imported icon while `address` is still on the imported site.
    func image(for tab: UUID, address: String) -> NSImage? {
        guard let entry = entries[tab], let url = URL(string: address),
              WebsiteFaviconStore.originKey(for: url) == entry.origin else { return nil }
        return entry.image
    }
    func remove(_ tab: UUID) { entries.removeValue(forKey: tab) }
    func removeAll() { entries.removeAll() }
}
