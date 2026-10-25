import Foundation

/// Reads Arc's local sidebar layout (`StorableSidebar.json`) and maps it onto
/// Bam Spaces, folders, kept tabs, Today tabs and Favorites.
///
/// Only the live local tree (`sidebar.containers`) is read. Arc's separate sync
/// snapshots (`sidebarSyncState`, `firebaseSyncState`) can describe deleted or
/// other-device items and are never merged in. The source file is opened
/// read-only; nothing in Arc's profile is modified. This is a layout import:
/// cookies, passwords, history and extensions are not transferred.
enum ArcImport {
    static let sourceFileName = "StorableSidebar.json"
    static let supportedVersions: ClosedRange<Int> = 1...1
    static let maximumFileSize = 64 * 1024 * 1024
    static let maximumItems = 50_000

    static func defaultSourceURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Arc/\(sourceFileName)")
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case tooLarge
        case notArcLayout
        case unsupportedVersion(Int)
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Bam couldn’t read that file."
            case .tooLarge: return "That file is too large to be an Arc sidebar layout."
            case .notArcLayout: return "That file isn’t an Arc sidebar layout (StorableSidebar.json)."
            case .unsupportedVersion(let version): return "This Arc layout uses format version \(version), which Bam doesn’t recognize yet."
            case .malformed(let detail): return "The Arc layout is damaged: \(detail)."
            }
        }
    }

    // MARK: Parsed source

    /// Arc profile identity, from `{"default":true}` or
    /// `{"custom":{"_0":{"machineID":…,"directoryBasename":…}}}`.
    struct Profile: Hashable {
        let key: String
        let isDefault: Bool
    }
    struct Space: Equatable {
        let id: String
        let title: String
        let emoji: String?
        let colorIndex: Int?
        let hasCustomIcon: Bool
        let hasTheme: Bool
        let profile: Profile
        let pinnedRoot: String?
        let unpinnedRoot: String?
    }
    enum Kind: Equatable {
        case tab(url: String, savedTitle: String?)
        case folder(isLive: Bool)
        case split
        case container
        /// An Easel's reference metadata only (no canvas is present in the layout).
        case easel(id: String?, title: String?)
        case unknown(String)
    }
    struct Node: Equatable {
        let id: String
        let kind: Kind
        let title: String?
        let children: [String]
    }
    struct Source {
        let spaces: [Space]
        let nodes: [String: Node]
        /// Favorites roots per Arc profile, in source order.
        let favoriteRoots: [(profile: Profile, root: String)]
        /// The layout file this came from, when loaded from disk (for its icon cache).
        var sourceURL: URL? = nil
    }

    static func load(from url: URL) throws -> Source {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber, size.intValue > maximumFileSize { throw Failure.tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { throw Failure.unreadable }
        var source = try parse(data)
        source.sourceURL = url
        return source
    }

    static func parse(_ data: Data) throws -> Source {
        guard data.count <= maximumFileSize else { throw Failure.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any] else { throw Failure.notArcLayout }
        if let version = root["version"] as? Int, !supportedVersions.contains(version) { throw Failure.unsupportedVersion(version) }
        guard let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["items"] != nil && $0["spaces"] != nil }) else {
            throw Failure.notArcLayout
        }
        let rawItems = try objectPairs(main["items"], label: "items")
        guard rawItems.count <= maximumItems else { throw Failure.tooLarge }
        var nodes: [String: Node] = [:]
        for object in rawItems {
            guard let id = object["id"] as? String, !id.isEmpty else { throw Failure.malformed("an item has no identifier") }
            guard nodes[id] == nil else { throw Failure.malformed("an item identifier appears twice") }
            // A damaged child list would silently hide contents; refuse instead.
            var children: [String] = []
            if let raw = object["childrenIds"], !(raw is NSNull) {
                guard let list = raw as? [Any] else { throw Failure.malformed("an item’s child list is damaged") }
                children = try list.map { value in
                    guard let id = value as? String else { throw Failure.malformed("an item’s child list is damaged") }
                    return id
                }
            }
            let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            nodes[id] = Node(id: id, kind: kind(of: object["data"]), title: title, children: children)
        }
        var spaces: [Space] = []
        for object in try objectPairs(main["spaces"], label: "spaces") {
            guard let id = object["id"] as? String, !id.isEmpty else { throw Failure.malformed("a Space has no identifier") }
            guard !spaces.contains(where: { $0.id == id }) else { throw Failure.malformed("a Space identifier appears twice") }
            let roots = containerRoots(object)
            let custom = object["customInfo"] as? [String: Any]
            let icon = custom?["iconType"] as? [String: Any]
            var emoji = (icon?["emoji_v2"] as? String).flatMap(BrowserSpace.validEmoji)
            if emoji == nil, let code = icon?["emoji"] as? Int, let value = UInt32(exactly: code), let scalar = Unicode.Scalar(value) {
                emoji = BrowserSpace.validEmoji(String(Character(scalar)))
            }
            spaces.append(Space(id: id, title: (object["title"] as? String) ?? "", emoji: emoji,
                                colorIndex: themeColorIndex(custom?["windowTheme"]),
                                hasCustomIcon: emoji == nil && icon?["icon"] != nil,
                                hasTheme: custom?["windowTheme"] != nil,
                                profile: profile(object["profile"]),
                                pinnedRoot: roots.pinned, unpinnedRoot: roots.unpinned))
        }
        var favoriteRoots: [(Profile, String)] = []
        if let pairs = main["topAppsContainerIDs"] as? [Any] {
            guard pairs.count % 2 == 0 else { throw Failure.malformed("Favorites roots are not paired with profiles") }
            for index in stride(from: 0, to: pairs.count, by: 2) {
                guard let root = pairs[index + 1] as? String else { throw Failure.malformed("a Favorites root has no identifier") }
                favoriteRoots.append((profile(pairs[index]), root))
            }
        }
        // Bound nesting before any traversal so hostile depth can't exhaust the stack.
        let roots = spaces.flatMap { [$0.pinnedRoot, $0.unpinnedRoot].compactMap { $0 } } + favoriteRoots.map(\.1)
        var stack = roots.map { ($0, 0) }, seen = Set<String>()
        while let (id, depth) = stack.popLast() {
            guard seen.insert(id).inserted, let node = nodes[id] else { continue }
            guard depth <= maximumNesting else { throw Failure.malformed("items are nested more than \(maximumNesting) levels deep") }
            stack += node.children.map { ($0, depth + 1) }
        }
        return Source(spaces: spaces, nodes: nodes, favoriteRoots: favoriteRoots)
    }
    static let maximumNesting = 256

    /// `items`/`spaces` alternate an ID string with the object it names.
    private static func objectPairs(_ value: Any?, label: String) throws -> [[String: Any]] {
        guard let list = value as? [Any] else { throw Failure.malformed("\(label) list is missing") }
        guard list.count % 2 == 0 else { throw Failure.malformed("\(label) list is not ID/object pairs") }
        var result: [[String: Any]] = []
        for index in stride(from: 0, to: list.count, by: 2) {
            guard let key = list[index] as? String, let object = list[index + 1] as? [String: Any] else {
                throw Failure.malformed("\(label) list is not ID/object pairs")
            }
            guard (object["id"] as? String) == key else { throw Failure.malformed("an entry in \(label) does not match its identifier") }
            result.append(object)
        }
        return result
    }
    /// Prefers `newContainerIDs` (`{"pinned":{}}`, id, …) and falls back to the
    /// legacy `containerIDs` (`"pinned"`, id, …). Only one is used.
    private static func containerRoots(_ space: [String: Any]) -> (pinned: String?, unpinned: String?) {
        func read(_ value: Any?) -> (String?, String?)? {
            guard let list = value as? [Any], list.count % 2 == 0, !list.isEmpty else { return nil }
            var pinned: String?, unpinned: String?
            for index in stride(from: 0, to: list.count, by: 2) {
                let tag: String? = (list[index] as? String) ?? (list[index] as? [String: Any])?.keys.first
                guard let id = list[index + 1] as? String else { continue }
                if tag == "pinned" { pinned = id } else if tag == "unpinned" { unpinned = id }
            }
            return pinned == nil && unpinned == nil ? nil : (pinned, unpinned)
        }
        return read(space["newContainerIDs"]) ?? read(space["containerIDs"]) ?? (nil, nil)
    }
    private static func profile(_ value: Any?) -> Profile {
        guard let object = value as? [String: Any], let custom = object["custom"] as? [String: Any] else {
            return Profile(key: "default", isDefault: true)
        }
        let details = custom["_0"] as? [String: Any] ?? [:]
        let basename = details["directoryBasename"] as? String ?? ""
        let machine = details["machineID"] as? String ?? ""
        return Profile(key: "custom:\(machine):\(basename)", isDefault: false)
    }
    private static func kind(of value: Any?) -> Kind {
        guard let data = value as? [String: Any], let key = data.keys.sorted().first else { return .unknown("empty") }
        switch key {
        case "tab":
            let tab = data["tab"] as? [String: Any] ?? [:]
            return .tab(url: tab["savedURL"] as? String ?? "", savedTitle: (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "list":
            let list = data["list"] as? [String: Any] ?? [:]
            return .folder(isLive: list["automaticLiveFolderData"] != nil)
        case "itemContainer": return .container
        case "splitView": return .split
        case "easel":
            let easel = data["easel"] as? [String: Any] ?? [:]
            return .easel(id: easel["easelID"] as? String, title: (easel["title"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        default: return .unknown(key)
        }
    }
    /// Nearest of Bam's flat colors to Arc's theme mid-tone, by hue.
    private static func themeColorIndex(_ value: Any?) -> Int? {
        guard let theme = value as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any],
              let mid = palette["midTone"] as? [String: Any],
              let r = mid["red"] as? Double, let g = mid["green"] as? Double, let b = mid["blue"] as? Double else { return nil }
        let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue
        if maxValue <= 0 || delta / maxValue < 0.15 { return 5 } // Graphite
        var hue: Double
        if maxValue == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxValue == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        let anchors: [(Double, Int)] = [(265, 0), (110, 1), (195, 2), (340, 3), (40, 4)]
        return anchors.min { a, b in
            min(abs(a.0 - hue), 360 - abs(a.0 - hue)) < min(abs(b.0 - hue), 360 - abs(b.0 - hue))
        }?.1
    }

    // MARK: Mapping

    struct Options: Equatable {
        var includeToday = true
        var includeFavorites = true
        /// Favorites roots belonging to Arc profiles that no current Space uses.
        /// Each becomes its own Space with its own new login profile.
        var includeUnattachedProfiles = false
        /// Selected source Space IDs; nil imports every Space.
        var spaceIDs: Set<String>? = nil
    }

    struct SpaceReport: Equatable {
        var title: String
        var emoji: String?
        var isNew: Bool
        var keptTabs = 0
        var folders = 0
        var todayTabs = 0
        var favorites = 0
        var splits = 0
        /// Easels kept as reference rows in their places (canvas not imported).
        var easels = 0
    }
    struct Report: Equatable {
        var spaces: [SpaceReport] = []
        var newProfiles: [String] = []
        var alreadyImported = 0
        /// Easels Bam could not place (e.g. inside Favorites); not represented.
        var easels = 0
        var easelReferences: Int { spaces.reduce(0) { $0 + $1.easels } }
        var liveFolders = 0
        var flattenedTodayFolders = 0
        var invalidAddresses = 0
        var unknownItems = 0
        var missingItems = 0
        var depthLimited = 0
        var favoriteOverflow = 0
        var oversizedSplits = 0
        var unattachedProfiles = 0
        var unattachedFavorites = 0
        var skippedSpaces = 0
        var approximatedThemes = 0
        var customIcons = 0
        var firstSpaceID: Int?
        /// Previously imported Spaces the user removed and Arc has nothing new for.
        var removedSpaces = 0
        /// Favorites of profiles whose Spaces were left out of this import.
        var excludedFavorites = 0
        /// Set when the import was refused as a whole; nothing changes.
        var refusal: String?

        var importedTabs: Int { spaces.reduce(0) { $0 + $1.keptTabs + $1.todayTabs + $1.favorites } }
        var importedFolders: Int { spaces.reduce(0) { $0 + $1.folders } }
        var isEmpty: Bool { importedTabs == 0 && importedFolders == 0 && easelReferences == 0 && !spaces.contains(where: \.isNew) }
        /// Why nothing would be added, without implying skipped items were imported.
        var emptyReason: String {
            if skippedSpaces > 0 { return "Nothing can be added: Bam’s \(BrowserSession.maximumSpaces)-Space limit is reached." }
            if removedSpaces > 0 && alreadyImported == 0 { return "Nothing new: the Spaces from this layout were removed after an earlier import." }
            if alreadyImported > 0 { return "All supported sidebar items in this layout are already in Bam." }
            return "This layout has no Spaces, tabs or folders Bam can import."
        }
        /// Plain-language notes about everything not carried over exactly.
        var notices: [String] {
            var lines: [String] = []
            func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            if alreadyImported > 0 { lines.append("\(plural(alreadyImported, "item")) already imported earlier will be skipped.") }
            if removedSpaces > 0 { lines.append("\(plural(removedSpaces, "Space")) you removed after an earlier import will stay removed. A removed Space comes back only if Arc has new items for it, holding just those items.") }
            if excludedFavorites > 0 { lines.append("\(plural(excludedFavorites, "Favorite")) of Spaces left out of this import won’t be imported.") }
            if easelReferences > 0 {
                lines.append("\(plural(easelReferences, "Easel")) will be kept as references in their places, with their names. Their canvases aren’t imported and stay in Arc.")
            }
            if easels > 0 { lines.append("\(plural(easels, "Easel")) outside a Space’s sidebar can’t be kept; Bam has no Easels.") }
            if liveFolders > 0 { lines.append("\(plural(liveFolders, "live folder")) will be imported as ordinary folders; live updates aren’t supported.") }
            if flattenedTodayFolders > 0 { lines.append("\(plural(flattenedTodayFolders, "folder")) in Today will be flattened; Bam keeps folders in the kept section.") }
            if favoriteOverflow > 0 { lines.append("\(plural(favoriteOverflow, "Favorite")) beyond Bam’s 12 per profile will go in a “More Favorites” folder.") }
            if oversizedSplits > 0 { lines.append("\(plural(oversizedSplits, "Split")) with more than two panes will keep two panes; the rest become tabs beside them.") }
            if unattachedProfiles > 0 {
                lines.append("\(plural(unattachedProfiles, "other Arc profile")) with \(plural(unattachedFavorites, "Favorite")) aren’t used by any current Space.")
            }
            if invalidAddresses > 0 { lines.append("\(plural(invalidAddresses, "tab")) with non-web addresses will be skipped.") }
            if depthLimited > 0 { lines.append("\(plural(depthLimited, "folder")) nested deeper than Bam allows will be placed in their nearest allowed parent.") }
            if missingItems > 0 || unknownItems > 0 { lines.append("\(plural(missingItems + unknownItems, "item")) Bam doesn’t recognize will be skipped.") }
            if skippedSpaces > 0 { lines.append("\(plural(skippedSpaces, "Space")) won’t fit within Bam’s \(BrowserSession.maximumSpaces)-Space limit.") }
            if approximatedThemes > 0 { lines.append("Arc window themes become the nearest Bam Space color.") }
            if customIcons > 0 { lines.append("\(plural(customIcons, "Space")) with Arc’s built-in icons will use a Bam symbol instead.") }
            lines.append("Sign-ins, passwords, history and extensions stay in Arc; this imports your sidebar layout.")
            return lines
        }
    }

    /// Switches to `space` and selects exactly one new blank tab there, so no
    /// imported page is chosen. `changeSpace` already creates a blank tab when
    /// nothing in the Space is selectable; that one is reused, never doubled.
    static func arrive(at space: Int, in session: inout BrowserSession) {
        guard session.spaceDefinition(space) != nil else { return }
        let existing = Set(session.tabs.map(\.id))
        session.changeSpace(space)
        if let active = session.active, !existing.contains(active.id), active.isHome, active.space == space { return }
        session.add()
    }

    /// Removes exactly what an import added (`imported` minus `previous`) from
    /// `current`, keeping anything the user did since. Used when the imported
    /// session can't be saved. A Space the user has since filled is kept.
    static func undo(_ imported: BrowserSession, over previous: BrowserSession, in current: BrowserSession) -> BrowserSession {
        let addedTabs = Set(imported.tabs.map(\.id)).subtracting(previous.tabs.map(\.id))
        let addedFolders = Set(imported.folders.map(\.id)).subtracting(previous.folders.map(\.id))
        let addedSpaces = Set(imported.spaces.map(\.id)).subtracting(previous.spaces.map(\.id))
        let addedProfiles = Set(imported.profiles.map(\.id)).subtracting(previous.profiles.map(\.id))
        var session = current
        session.tabs.removeAll { addedTabs.contains($0.id) }
        session.folders.removeAll { addedFolders.contains($0.id) }
        session.splits = session.splits?.filter { !addedTabs.contains($0.primaryID) && !addedTabs.contains($0.secondaryID) }
        let occupied = Set(session.tabs.filter { !$0.isFavorite }.map(\.space))
        let removableSpaces = addedSpaces.subtracting(occupied)
        if session.spaces.count > removableSpaces.count {
            session.spaces.removeAll { removableSpaces.contains($0.id) }
            for id in removableSpaces { session.rootOrder?[id] = nil }
        }
        let referenced = Set(session.spaces.map(\.profileID) + session.tabs.compactMap { $0.isFavorite ? $0.saved?.profileID : nil })
        session.profiles.removeAll { addedProfiles.contains($0.id) && !referenced.contains($0.id) }
        session.importLinks = previous.importLinks
        if session.spaceDefinition(session.space) == nil, let first = session.spaces.first { session.space = first.id }
        session.sanitize()
        return session
    }

    /// Builds the imported session without touching the input. Preview and
    /// commit run the same function, so the preview counts are what commit does.
    static func apply(_ source: Source, to original: BrowserSession, options: Options = Options()) -> (session: BrowserSession, report: Report) {
        var session = original
        var report = Report()
        var links = session.importLinks ?? [:]
        var orders: [BrowserSession.KeptContainer: [UUID]] = [:]
        var lastPlaced: [BrowserSession.KeptContainer: UUID] = [:]
        var visited = Set<String>()
        let existingTabIDs = Set(session.tabs.map(\.id))

        func linked(_ key: String, prefix: String) -> String? {
            guard let value = links[key], value.hasPrefix(prefix) else { return nil }
            return String(value.dropFirst(prefix.count))
        }
        func order(_ container: BrowserSession.KeptContainer) -> [UUID] {
            if let cached = orders[container] { return cached }
            let current = session.keptChildren(of: container); orders[container] = current; return current
        }
        /// Keep source order: place after the previously placed sibling, or at
        /// the front when this is the first source child of an existing container.
        func place(_ id: UUID, in container: BrowserSession.KeptContainer, isNewContainer: Bool) {
            var list = order(container)
            let index = lastPlaced[container].flatMap { list.firstIndex(of: $0).map { $0 + 1 } } ?? (isNewContainer ? list.count : 0)
            list.insert(id, at: min(list.count, index))
            orders[container] = list; lastPlaced[container] = id
        }
        func note(existing key: String, in container: BrowserSession.KeptContainer, prefix: String) {
            report.alreadyImported += 1
            if let raw = linked(key, prefix: prefix), let id = UUID(uuidString: raw), order(container).contains(id) { lastPlaced[container] = id }
        }
        func address(_ raw: String) -> String? {
            guard let url = URLInput.directURL(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return url.absoluteString
        }
        func clipped(_ text: String?, limit: Int) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let clean = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            return clean.isEmpty ? nil : String(clean.prefix(limit))
        }
        func makeTab(_ node: Node, url: String, savedTitle: String?, space: Int, kind: SavedTabKind?, folder: UUID?, profile: UUID? = nil) -> BrowserTab {
            let host = URL(string: url)?.host ?? url
            // Kept tabs keep Arc's rename as their saved name; a renamed Today
            // tab has no saved name, so the rename becomes its title.
            let title = (kind == nil ? clipped(node.title, limit: 300) : nil) ?? clipped(savedTitle, limit: 300) ?? clipped(node.title, limit: 300) ?? host
            let saved = kind.map { SavedTabState(kind: $0, address: url, customTitle: clipped(node.title, limit: 80),
                                                  isUnloaded: true, profileID: $0 == .favorite ? profile : nil) }
            return BrowserTab(title: title, address: url, space: space, saved: saved, folderID: kind == .kept ? folder : nil)
        }
        /// An Easel kept as a reference row: Arc's rename, else its own title,
        /// else a generic name; identity from its Easel ID (else its sidebar ID).
        /// No URL is invented and no canvas data exists to import.
        func makeEasel(_ node: Node, easelID: String?, payloadTitle: String?, space: Int, kept: Bool, folder: UUID?) -> BrowserTab {
            let identity = easelID.flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: node.id) ?? UUID()
            let reference = ArcEaselReference.address(for: identity)
            let title = clipped(node.title, limit: 300) ?? clipped(payloadTitle, limit: 300) ?? "Arc Easel"
            let saved = kept ? SavedTabState(kind: .kept, address: reference, isUnloaded: true) : nil
            return BrowserTab(title: title, address: reference, space: space, saved: saved, folderID: kept ? folder : nil)
        }

        // Profiles: Arc default -> Bam default; each custom Arc profile -> its own Bam profile.
        var profileMap: [Profile: UUID] = [:]
        func bamProfile(for profile: Profile, name: String) -> UUID? {
            if profile.isDefault { return BrowserProfile.defaultID }
            if let mapped = profileMap[profile] { return mapped }
            if let raw = linked("arc-profile:\(profile.key)", prefix: "profile:"), let id = UUID(uuidString: raw),
               session.profiles.contains(where: { $0.id == id }) { profileMap[profile] = id; return id }
            let base = BrowserSpace.validName(String(name.prefix(52))) ?? "Arc profile"
            var candidate = "\(base) (Arc)", suffix = 2
            while session.profiles.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                candidate = "\(base) (Arc \(suffix))"; suffix += 1
            }
            guard let id = session.createProfile(name: candidate) else { return nil }
            profileMap[profile] = id; links["arc-profile:\(profile.key)"] = "profile:\(id.uuidString)"
            report.newProfiles.append(candidate)
            return id
        }

        // Kept (pinned) hierarchy.
        func importPinned(_ children: [String], space: Int, folder: UUID?, depth: Int, isNewContainer: Bool, spaceReport: inout SpaceReport) {
            let container: BrowserSession.KeptContainer = folder.map { .folder($0) } ?? .root(space)
            for childID in children {
                guard visited.insert(childID).inserted else { report.missingItems += 1; continue }
                guard let node = source.nodes[childID] else { report.missingItems += 1; continue }
                switch node.kind {
                case .tab(let raw, let savedTitle):
                    let key = "arc:\(node.id)"
                    if links[key] != nil { note(existing: key, in: container, prefix: "tab:"); continue }
                    guard let url = address(raw) else { report.invalidAddresses += 1; continue }
                    let tab = makeTab(node, url: url, savedTitle: savedTitle, space: space, kind: .kept, folder: folder)
                    session.tabs.append(tab); links[key] = "tab:\(tab.id.uuidString)"
                    place(tab.id, in: container, isNewContainer: isNewContainer); spaceReport.keptTabs += 1
                case .folder(let isLive):
                    let key = "arc:\(node.id)"
                    if let raw = linked(key, prefix: "folder:"), let id = UUID(uuidString: raw), let existing = session.folder(id), existing.space == space {
                        note(existing: key, in: container, prefix: "folder:")
                        importPinned(node.children, space: space, folder: id, depth: depth + 1, isNewContainer: false, spaceReport: &spaceReport)
                        continue
                    }
                    if links[key] != nil { report.alreadyImported += 1 }
                    guard depth < BrowserSession.maximumFolderDepth, session.folders.count < BrowserSession.maximumFolders else {
                        report.depthLimited += 1
                        importPinned(node.children, space: space, folder: folder, depth: depth, isNewContainer: isNewContainer, spaceReport: &spaceReport)
                        continue
                    }
                    if links[key] == nil {
                        if isLive { report.liveFolders += 1 }
                        let created = BrowserFolder(name: BrowserFolder.validName(clipped(node.title, limit: 120) ?? "") ?? "Folder",
                                                    space: space, parentID: folder, isCollapsed: true)
                        session.folders.append(created); orders[.folder(created.id)] = []
                        links[key] = "folder:\(created.id.uuidString)"
                        place(created.id, in: container, isNewContainer: isNewContainer); spaceReport.folders += 1
                        importPinned(node.children, space: space, folder: created.id, depth: depth + 1, isNewContainer: true, spaceReport: &spaceReport)
                    } else {
                        // The user removed this imported folder; only new contents return, at this level.
                        importPinned(node.children, space: space, folder: folder, depth: depth, isNewContainer: isNewContainer, spaceReport: &spaceReport)
                    }
                case .split:
                    var created: [UUID] = []
                    for paneID in node.children {
                        guard visited.insert(paneID).inserted, let pane = source.nodes[paneID] else { report.missingItems += 1; continue }
                        guard case .tab(let raw, let savedTitle) = pane.kind else { report.unknownItems += 1; continue }
                        let key = "arc:\(pane.id)"
                        if links[key] != nil { note(existing: key, in: container, prefix: "tab:"); continue }
                        guard let url = address(raw) else { report.invalidAddresses += 1; continue }
                        let tab = makeTab(pane, url: url, savedTitle: savedTitle, space: space, kind: .kept, folder: folder)
                        session.tabs.append(tab); links[key] = "tab:\(tab.id.uuidString)"
                        spaceReport.keptTabs += 1; created.append(tab.id)
                        // A Split is one row; only its primary takes a place in the order.
                        if created.count != 2 { place(tab.id, in: container, isNewContainer: isNewContainer) }
                    }
                    if node.children.count > 2 { report.oversizedSplits += 1 }
                    if created.count >= 2 {
                        if session.splits == nil { session.splits = [] }
                        session.splits?.append(BrowserSplit(primaryID: created[0], secondaryID: created[1])); spaceReport.splits += 1
                    }
                case .container:
                    importPinned(node.children, space: space, folder: folder, depth: depth, isNewContainer: isNewContainer, spaceReport: &spaceReport)
                case .easel(let easelID, let payloadTitle):
                    // Kept in its exact folder and position as a reference row.
                    let key = "arc:\(node.id)"
                    if links[key] != nil { note(existing: key, in: container, prefix: "tab:"); continue }
                    let row = makeEasel(node, easelID: easelID, payloadTitle: payloadTitle, space: space, kept: true, folder: folder)
                    session.tabs.append(row); links[key] = "tab:\(row.id.uuidString)"
                    place(row.id, in: container, isNewContainer: isNewContainer); spaceReport.easels += 1
                case .unknown: report.unknownItems += 1
                }
            }
        }
        // Today tabs stay ordinary tabs. Bam creates no page for them until one is selected.
        func importToday(_ children: [String], space: Int, spaceReport: inout SpaceReport) {
            for childID in children {
                guard visited.insert(childID).inserted, let node = source.nodes[childID] else { report.missingItems += 1; continue }
                switch node.kind {
                case .tab(let raw, let savedTitle):
                    let key = "arc:\(node.id)"
                    if links[key] != nil { report.alreadyImported += 1; continue }
                    guard let url = address(raw) else { report.invalidAddresses += 1; continue }
                    let tab = makeTab(node, url: url, savedTitle: savedTitle, space: space, kind: nil, folder: nil)
                    session.tabs.append(tab); links[key] = "tab:\(tab.id.uuidString)"; spaceReport.todayTabs += 1
                case .folder:
                    if links["arc:\(node.id)"] == nil { report.flattenedTodayFolders += 1; links["arc:\(node.id)"] = "flattened" }
                    importToday(node.children, space: space, spaceReport: &spaceReport)
                case .split:
                    var created: [UUID] = []
                    for paneID in node.children {
                        guard visited.insert(paneID).inserted, let pane = source.nodes[paneID], case .tab(let raw, let savedTitle) = pane.kind else { report.unknownItems += 1; continue }
                        let key = "arc:\(pane.id)"
                        if links[key] != nil { report.alreadyImported += 1; continue }
                        guard let url = address(raw) else { report.invalidAddresses += 1; continue }
                        let tab = makeTab(pane, url: url, savedTitle: savedTitle, space: space, kind: nil, folder: nil)
                        session.tabs.append(tab); links[key] = "tab:\(tab.id.uuidString)"; spaceReport.todayTabs += 1; created.append(tab.id)
                    }
                    if node.children.count > 2 { report.oversizedSplits += 1 }
                    if created.count >= 2 {
                        if session.splits == nil { session.splits = [] }
                        session.splits?.append(BrowserSplit(primaryID: created[0], secondaryID: created[1])); spaceReport.splits += 1
                    }
                case .container: importToday(node.children, space: space, spaceReport: &spaceReport)
                case .easel(let easelID, let payloadTitle):
                    let key = "arc:\(node.id)"
                    if links[key] != nil { report.alreadyImported += 1; continue }
                    let row = makeEasel(node, easelID: easelID, payloadTitle: payloadTitle, space: space, kept: false, folder: nil)
                    session.tabs.append(row); links[key] = "tab:\(row.id.uuidString)"; spaceReport.easels += 1
                case .unknown: report.unknownItems += 1
                }
            }
        }
        /// Whether a subtree holds anything not imported before (tabs or folders).
        func hasNewItems(_ ids: [String]) -> Bool {
            var stack = ids, seen = Set<String>()
            while let id = stack.popLast() {
                guard seen.insert(id).inserted, let node = source.nodes[id] else { continue }
                switch node.kind {
                case .tab(let raw, _): if links["arc:\(id)"] == nil, address(raw) != nil { return true }
                case .folder: if links["arc:\(id)"] == nil { return true }; stack += node.children
                case .split, .container: stack += node.children
                case .easel: if links["arc:\(id)"] == nil { return true }
                case .unknown: continue
                }
            }
            return false
        }
        func importFavorites(root: String, profile: UUID, homeSpace: Int, spaceReport: inout SpaceReport) {
            guard let node = source.nodes[root] else { report.missingItems += 1; return }
            guard visited.insert(root).inserted else { return }
            var overflowFolder: UUID?
            for childID in node.children {
                guard visited.insert(childID).inserted, let child = source.nodes[childID] else { report.missingItems += 1; continue }
                guard case .tab(let raw, let savedTitle) = child.kind else {
                    if case .easel = child.kind { report.easels += 1 } else { report.unknownItems += 1 }
                    continue
                }
                let key = "arc:\(child.id)"
                if links[key] != nil { report.alreadyImported += 1; continue }
                guard let url = address(raw) else { report.invalidAddresses += 1; continue }
                if session.favorites(in: profile).count < BrowserSession.maximumFavorites {
                    let tab = makeTab(child, url: url, savedTitle: savedTitle, space: homeSpace, kind: .favorite, folder: nil, profile: profile)
                    session.tabs.append(tab); links[key] = "tab:\(tab.id.uuidString)"; spaceReport.favorites += 1
                } else {
                    // Never hide Favorites past Bam's per-profile limit: keep them, visibly grouped.
                    report.favoriteOverflow += 1
                    let overflowKey = "arc-favorites-overflow:\(root)"
                    if overflowFolder == nil, let raw = linked(overflowKey, prefix: "folder:"), let id = UUID(uuidString: raw),
                       session.folder(id)?.space == homeSpace { overflowFolder = id }
                    if overflowFolder == nil, session.folders.count < BrowserSession.maximumFolders {
                        let folder = BrowserFolder(name: "More Favorites", space: homeSpace, isCollapsed: false)
                        session.folders.append(folder); orders[.folder(folder.id)] = []
                        var rootList = order(.root(homeSpace)); rootList.insert(folder.id, at: 0); orders[.root(homeSpace)] = rootList
                        links[overflowKey] = "folder:\(folder.id.uuidString)"
                        overflowFolder = folder.id; spaceReport.folders += 1
                    }
                    let tab = makeTab(child, url: url, savedTitle: savedTitle, space: homeSpace, kind: .kept, folder: overflowFolder)
                    session.tabs.append(tab); links[key] = "tab:\(tab.id.uuidString)"
                    place(tab.id, in: overflowFolder.map { .folder($0) } ?? .root(homeSpace), isNewContainer: true); spaceReport.keptTabs += 1
                }
            }
        }

        // Spaces.
        let selected = source.spaces.filter { options.spaceIDs?.contains($0.id) ?? true }
        var homeSpaces: [Profile: Int] = [:]
        var reportIndexBySpace: [Int: Int] = [:]
        for (offset, arcSpace) in selected.enumerated() {
            let title = BrowserSpace.validName(String(arcSpace.title.prefix(60))) ?? "Arc Space \(offset + 1)"
            var spaceID: Int?
            var isNew = false
            if let raw = linked("arc-space:\(arcSpace.id)", prefix: "space:"), let id = Int(raw), session.spaceDefinition(id) != nil { spaceID = id }
            if arcSpace.pinnedRoot.map({ source.nodes[$0] == nil }) == true { report.missingItems += 1 }
            if options.includeToday, arcSpace.unpinnedRoot.map({ source.nodes[$0] == nil }) == true { report.missingItems += 1 }
            // A Space removed after an earlier import stays removed unless Arc
            // has something new for it; never recreate it empty.
            if spaceID == nil, links["arc-space:\(arcSpace.id)"] != nil {
                let roots = [arcSpace.pinnedRoot] + (options.includeToday ? [arcSpace.unpinnedRoot] : [])
                let children = roots.compactMap { $0.flatMap { source.nodes[$0]?.children } }.flatMap { $0 }
                if !hasNewItems(children) { report.removedSpaces += 1; continue }
            }
            if spaceID == nil {
                guard let profile = bamProfile(for: arcSpace.profile, name: title) else { report.skippedSpaces += 1; continue }
                let color = arcSpace.colorIndex ?? [0, 2, 3, 4, 1, 5][offset % 6]
                guard let created = session.createSpace(name: title, symbol: "sparkles", colorIndex: color, profileID: profile) else {
                    report.skippedSpaces += 1; continue
                }
                if let emoji = arcSpace.emoji { session.setSpaceEmoji(id: created, emoji: emoji) }
                if arcSpace.hasTheme { report.approximatedThemes += 1 }
                if arcSpace.hasCustomIcon { report.customIcons += 1 }
                links["arc-space:\(arcSpace.id)"] = "space:\(created)"
                spaceID = created; isNew = true
            }
            guard let space = spaceID else { continue }
            if report.firstSpaceID == nil { report.firstSpaceID = space }
            if homeSpaces[arcSpace.profile] == nil { homeSpaces[arcSpace.profile] = space }
            var spaceReport = SpaceReport(title: session.spaceDefinition(space)?.name ?? title, emoji: session.spaceDefinition(space)?.emoji, isNew: isNew)
            if let root = arcSpace.pinnedRoot, let node = source.nodes[root] {
                visited.insert(root)
                importPinned(node.children, space: space, folder: nil, depth: 0, isNewContainer: isNew, spaceReport: &spaceReport)
            }
            if options.includeToday, let root = arcSpace.unpinnedRoot, let node = source.nodes[root] {
                visited.insert(root)
                importToday(node.children, space: space, spaceReport: &spaceReport)
            }
            reportIndexBySpace[space] = report.spaces.count
            report.spaces.append(spaceReport)
        }

        // Favorites: matched by Arc profile identity, never by position.
        let sourceProfiles = Set(source.spaces.map(\.profile))
        if options.includeFavorites {
            for (profile, root) in source.favoriteRoots {
                // Favorites join the login profile their Arc Space now uses in Bam.
                if let home = homeSpaces[profile], let bam = session.spaceDefinition(home)?.profileID,
                   let index = reportIndexBySpace[home] {
                    var spaceReport = report.spaces[index]
                    importFavorites(root: root, profile: bam, homeSpace: home, spaceReport: &spaceReport)
                    report.spaces[index] = spaceReport
                    continue
                }
                // A profile used by any source Space is not an orphan, even when
                // that Space was left out, removed or skipped: its Favorites
                // follow the Space selection and never go to a recovery Space.
                if sourceProfiles.contains(profile) {
                    report.excludedFavorites += source.nodes[root]?.children.filter { links["arc:\($0)"] == nil }.count ?? 0
                    continue
                }
                guard source.nodes[root] != nil else { report.missingItems += 1; continue }
                let count = source.nodes[root]?.children.filter { id in
                    if case .tab = source.nodes[id]?.kind { return links["arc:\(id)"] == nil } else { return false }
                }.count ?? 0
                guard count > 0 else { continue }
                // Profiles without a current Space: report, or recover into their own Space and profile.
                guard options.includeUnattachedProfiles else {
                    report.unattachedProfiles += 1; report.unattachedFavorites += count; continue
                }
                let ordinal = report.newProfiles.count + 1
                var linkedSpace: Int?
                if let raw = linked("arc-profile-space:\(profile.key)", prefix: "space:"), let id = Int(raw), session.spaceDefinition(id) != nil { linkedSpace = id }
                guard let bam = bamProfile(for: profile, name: "Arc profile \(ordinal)") else { report.skippedSpaces += 1; continue }
                let space = linkedSpace ?? session.createSpace(name: "Arc Favorites \(ordinal)", symbol: "sparkles", colorIndex: 5, profileID: bam)
                guard let space else { report.skippedSpaces += 1; continue }
                links["arc-profile-space:\(profile.key)"] = "space:\(space)"
                homeSpaces[profile] = space
                var spaceReport = SpaceReport(title: session.spaceDefinition(space)?.name ?? "Arc Favorites", emoji: nil, isNew: linkedSpace == nil)
                importFavorites(root: root, profile: bam, homeSpace: space, spaceReport: &spaceReport)
                if report.firstSpaceID == nil { report.firstSpaceID = space }
                report.spaces.append(spaceReport)
            }
        }

        for (container, ids) in orders { session.setOrder(ids, for: container) }
        session.importLinks = links.isEmpty ? nil : links
        session.sanitize()
        // Importing only adds. If normalization would drop anything that existed
        // before, refuse the whole import instead of committing a partial change.
        if !existingTabIDs.isSubset(of: Set(session.tabs.map(\.id))) || session.folders.count < original.folders.count {
            var refused = Report(); refused.refusal = "Bam stopped the import because it would have changed existing tabs. Nothing was imported."
            return (original, refused)
        }
        return (session, report)
    }
}
