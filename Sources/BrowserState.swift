import Foundation

struct BrowserTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var address: String
    var space: Int
    var pinned = false
    var isHome: Bool { address == "orbit://newtab" }
    var isVideoDemo: Bool { address == "orbit://video" }
    var symbol: String {
        if isHome { return "sparkle" }
        if isVideoDemo { return "play.rectangle.fill" }
        if address.contains("developer.apple.com") { return "apple.logo" }
        if address.contains("github.com") { return "chevron.left.forwardslash.chevron.right" }
        if address.contains("wikipedia.org") { return "book.closed" }
        return "globe"
    }
}

struct BrowserSplit: Codable, Equatable {
    var primaryID: UUID
    var secondaryID: UUID
}

/// IDs remain stable as the user reorders Spaces; their array position is only
/// presentation order. Existing sessions retain IDs 0, 1, and 2.
struct BrowserSpace: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var symbol: String
    var colorIndex: Int

    static let symbols = ["sparkles", "sun.max", "globe", "briefcase", "house", "heart", "book", "paintbrush", "terminal", "bolt", "leaf", "music.note"]
    static let colorNames = ["Violet", "Sage", "Ocean", "Rose", "Amber", "Graphite"]
    static let defaults = [
        BrowserSpace(id: 0, name: "Studio", symbol: "sparkles", colorIndex: 0),
        BrowserSpace(id: 1, name: "Life", symbol: "sun.max", colorIndex: 1),
        BrowserSpace(id: 2, name: "Explore", symbol: "globe", colorIndex: 2)
    ]
    static let legacyDefaults = defaults

    fileprivate static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    fileprivate static func normalizedSymbol(_ raw: String) -> String {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return symbols.contains(symbol) ? symbol : "sparkles"
    }
}

struct BrowserSession: Codable {
    var tabs: [BrowserTab]
    var activeID: UUID
    var space: Int
    var sidebarWidth: Double
    var sidebarVisible: Bool
    // Optional so callers and sessions predating per-space selection still work.
    var lastSelectedTabIDsBySpace: [Int: UUID]?
    var splits: [BrowserSplit]?
    var spaces: [BrowserSpace]
    // Persist the high-water mark, including deleted Spaces, so tab/archive
    // metadata can never accidentally refer to a different newly created Space.
    private var lastIssuedSpaceID: Int
    static let maximumSpaces = 32
    private static let formatVersion = 2

    init(tabs: [BrowserTab], activeID: UUID, space: Int = 0,
         sidebarWidth: Double = 228, sidebarVisible: Bool = true,
         lastSelectedTabIDsBySpace: [Int: UUID]? = nil, splits: [BrowserSplit]? = nil,
         spaces: [BrowserSpace] = BrowserSpace.defaults) {
        self.tabs = tabs; self.activeID = activeID; self.space = space
        self.sidebarWidth = sidebarWidth; self.sidebarVisible = sidebarVisible
        self.lastSelectedTabIDsBySpace = lastSelectedTabIDsBySpace; self.splits = splits
        self.spaces = spaces
        lastIssuedSpaceID = max(2, spaces.map(\.id).max() ?? 2)
    }

    private enum CodingKeys: String, CodingKey {
        case version, tabs, activeID, space, sidebarWidth, sidebarVisible
        case lastSelectedTabIDsBySpace, splits, spaces, lastIssuedSpaceID
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.formatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported session version")
        }
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        activeID = try values.decode(UUID.self, forKey: .activeID)
        space = try values.decodeIfPresent(Int.self, forKey: .space) ?? 0
        sidebarWidth = try values.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 228
        sidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        lastSelectedTabIDsBySpace = try values.decodeIfPresent([Int: UUID].self, forKey: .lastSelectedTabIDsBySpace)
        splits = try values.decodeIfPresent([BrowserSplit].self, forKey: .splits)
        spaces = try values.decodeIfPresent([BrowserSpace].self, forKey: .spaces) ?? BrowserSpace.defaults
        lastIssuedSpaceID = max(2, max(try values.decodeIfPresent(Int.self, forKey: .lastIssuedSpaceID) ?? 2,
                                      spaces.map(\.id).max() ?? 2))
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.formatVersion, forKey: .version)
        try values.encode(tabs, forKey: .tabs); try values.encode(activeID, forKey: .activeID)
        try values.encode(space, forKey: .space); try values.encode(sidebarWidth, forKey: .sidebarWidth)
        try values.encode(sidebarVisible, forKey: .sidebarVisible)
        try values.encodeIfPresent(lastSelectedTabIDsBySpace, forKey: .lastSelectedTabIDsBySpace)
        try values.encodeIfPresent(splits, forKey: .splits)
        try values.encode(spaces, forKey: .spaces)
        try values.encode(lastIssuedSpaceID, forKey: .lastIssuedSpaceID)
    }

    static func fresh() -> BrowserSession {
        let home = BrowserTab(title: "A little space", address: "orbit://newtab", space: 0)
        return BrowserSession(tabs: [
            BrowserTab(title: "Apple Developer", address: "https://developer.apple.com", space: 0, pinned: true),
            BrowserTab(title: "GitHub", address: "https://github.com", space: 0, pinned: true), home,
            BrowserTab(title: "A little space", address: "orbit://newtab", space: 1),
            BrowserTab(title: "Wikipedia", address: "https://www.wikipedia.org", space: 2, pinned: true),
            BrowserTab(title: "A little space", address: "orbit://newtab", space: 2)
        ], activeID: home.id, lastSelectedTabIDsBySpace: [0: home.id])
    }
    var active: BrowserTab? { tabs.first { $0.id == activeID } }
    var visibleTabs: [BrowserTab] { orderedTabs(in: space) }
    var spaceIDs: [Int] { spaces.map(\.id) }
    func spaceIndex(_ id: Int) -> Int? { spaces.firstIndex { $0.id == id } }
    func spaceDefinition(_ id: Int) -> BrowserSpace? { spaces.first { $0.id == id } }

    @discardableResult mutating func createSpace(name: String, symbol: String, colorIndex: Int) -> Int? {
        guard spaces.count < Self.maximumSpaces, let name = BrowserSpace.validName(name),
              BrowserSpace.colorNames.indices.contains(colorIndex) else { return nil }
        let highWater = max(lastIssuedSpaceID, spaces.map(\.id).max() ?? 2)
        guard highWater < Int.max else { return nil }
        lastIssuedSpaceID = highWater + 1
        spaces.append(BrowserSpace(id: lastIssuedSpaceID, name: name,
                                   symbol: BrowserSpace.normalizedSymbol(symbol), colorIndex: colorIndex))
        return lastIssuedSpaceID
    }
    @discardableResult mutating func updateSpace(id: Int, name: String, symbol: String, colorIndex: Int) -> Bool {
        guard let index = spaceIndex(id), let name = BrowserSpace.validName(name),
              BrowserSpace.colorNames.indices.contains(colorIndex) else { return false }
        spaces[index] = BrowserSpace(id: id, name: name, symbol: BrowserSpace.normalizedSymbol(symbol), colorIndex: colorIndex)
        return true
    }
    @discardableResult mutating func reorderSpace(id: Int, to index: Int) -> Bool {
        guard let oldIndex = spaceIndex(id), spaces.indices.contains(index) else { return false }
        let definition = spaces.remove(at: oldIndex)
        spaces.insert(definition, at: index)
        return true
    }
    @discardableResult mutating func deleteSpace(id: Int, movingTabsTo destination: Int) -> Bool {
        guard spaces.count > 1, id != destination, let index = spaceIndex(id), spaceDefinition(destination) != nil else { return false }
        rememberActiveSelection()
        let remembered = rememberedTab(in: id)
        let wasSelected = space == id
        for index in tabs.indices where tabs[index].space == id { tabs[index].space = destination }
        spaces.remove(at: index)
        lastSelectedTabIDsBySpace?[id] = nil
        repairRememberedSelection(in: destination, preferred: remembered)
        if wasSelected { space = destination }
        repairActiveSelection()
        return true
    }
    /// A split is one movable item. Stable tab IDs let the controller retain the
    /// existing WKWebViews; moving changes only their Space membership.
    @discardableResult mutating func moveTab(id: UUID, toSpace destination: Int) -> Bool {
        guard spaceDefinition(destination) != nil, let tab = tabs.first(where: { $0.id == id }) else { return false }
        guard tab.space != destination else { return true }
        rememberActiveSelection()
        let group = split(for: id)
        let members = Set(group.map { [$0.primaryID, $0.secondaryID] } ?? [id])
        let movedSelection = members.contains(activeID)
        for index in tabs.indices where members.contains(tabs[index].id) { tabs[index].space = destination }
        repairRememberedSelection(in: tab.space)
        repairRememberedSelection(in: destination, preferred: group?.primaryID ?? id)
        if movedSelection { space = destination }
        repairActiveSelection()
        return true
    }

    private func orderedTabs(in space: Int) -> [BrowserTab] {
        let grouped = Set((splits ?? []).map(\.secondaryID))
        return tabs.filter { $0.space == space && !grouped.contains($0.id) }.sorted { $0.pinned && !$1.pinned }
    }
    private func rememberedTab(in space: Int) -> UUID? {
        guard let id = lastSelectedTabIDsBySpace?[space],
              tabs.contains(where: { $0.id == id && $0.space == space }) else { return nil }
        return split(for: id)?.primaryID ?? id
    }
    private mutating func rememberActiveSelection() {
        guard let tab = active, spaceDefinition(tab.space) != nil else { return }
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        let selectedID = split(for: tab.id)?.primaryID ?? tab.id
        lastSelectedTabIDsBySpace?[tab.space] = selectedID
    }
    private mutating func repairRememberedSelection(in id: Int, preferred: UUID? = nil) {
        guard spaceDefinition(id) != nil else { lastSelectedTabIDsBySpace?[id] = nil; return }
        if let remembered = rememberedTab(in: id) {
            lastSelectedTabIDsBySpace?[id] = remembered
            return
        }
        let preferred = preferred.flatMap { candidate in
            tabs.contains(where: { $0.id == candidate && $0.space == id }) ? candidate : nil
        }
        let replacement = preferred ?? orderedTabs(in: id).last?.id
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        lastSelectedTabIDsBySpace?[id] = replacement
    }
    private mutating func repairActiveSelection() {
        if let selected = active, spaceDefinition(selected.space) != nil {
            activeID = split(for: selected.id)?.primaryID ?? selected.id
            space = selected.space
            rememberActiveSelection()
        } else { changeSpace(spaceDefinition(space) != nil ? space : spaces[0].id) }
    }
    @discardableResult mutating func add(address: String = "orbit://newtab", title: String? = nil) -> UUID {
        rememberActiveSelection()
        let defaultTitle = address == "orbit://newtab" ? "New tab" : address == "orbit://video" ? "Picture in Picture demo" : URL(string: address)?.host ?? address
        let tab = BrowserTab(title: title ?? defaultTitle, address: address, space: space)
        tabs.append(tab); activeID = tab.id
        rememberActiveSelection()
        return tab.id
    }
    mutating func select(_ id: UUID) {
        let selectedID = (splits ?? []).first(where: { $0.secondaryID == id })?.primaryID ?? id
        guard let tab = tabs.first(where: { $0.id == selectedID }), spaceDefinition(tab.space) != nil else { return }
        rememberActiveSelection()
        activeID = selectedID; space = tab.space
        rememberActiveSelection()
    }
    mutating func changeSpace(_ value: Int) {
        guard spaceDefinition(value) != nil else { return }
        rememberActiveSelection()
        space = value
        if let id = rememberedTab(in: space) ?? visibleTabs.first(where: { !$0.pinned })?.id ?? visibleTabs.first?.id {
            activeID = id
            rememberActiveSelection()
        } else { add() }
    }
    func split(for id: UUID) -> BrowserSplit? { (splits ?? []).first { $0.primaryID == id || $0.secondaryID == id } }
    @discardableResult mutating func makeSplit(primary: UUID, secondary: UUID) -> Bool {
        guard primary != secondary, let left = tabs.first(where: { $0.id == primary }),
              let right = tabs.first(where: { $0.id == secondary }), left.space == right.space,
              spaceDefinition(left.space) != nil else { return false }
        splits = (splits ?? []).filter { ![primary,secondary].contains($0.primaryID) && ![primary,secondary].contains($0.secondaryID) }
        splits?.append(BrowserSplit(primaryID: primary, secondaryID: secondary)); select(primary); return true
    }
    mutating func removeSplit(containing id: UUID) { splits = (splits ?? []).filter { $0.primaryID != id && $0.secondaryID != id } }
    @discardableResult mutating func close(_ id: UUID) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        rememberActiveSelection()
        let removed = tabs.remove(at: index)
        if let group = split(for: id) {
            if group.primaryID == id { tabs.removeAll { $0.id == group.secondaryID } }
            removeSplit(containing: id)
        }
        if activeID == id {
            if let next = visibleTabs.last?.id { activeID = next } else { add() }
        }
        // A remembered tab can be closed while a different space is visible.
        // Repair only that space's choice and leave the active tab alone.
        if lastSelectedTabIDsBySpace?[removed.space] == id {
            let replacementID = orderedTabs(in: removed.space).last?.id
            lastSelectedTabIDsBySpace?[removed.space] = replacementID
        }
        rememberActiveSelection()
        return removed
    }
    mutating func sanitize() {
        lastIssuedSpaceID = max(lastIssuedSpaceID, spaces.map(\.id).max() ?? 2)
        var seenSpaces = Set<Int>()
        spaces = spaces.compactMap { definition in
            guard definition.id >= 0, seenSpaces.count < Self.maximumSpaces,
                  seenSpaces.insert(definition.id).inserted else { return nil }
            return BrowserSpace(id: definition.id,
                                name: BrowserSpace.validName(definition.name) ?? "Space \(definition.id)",
                                symbol: BrowserSpace.normalizedSymbol(definition.symbol),
                                colorIndex: min(BrowserSpace.colorNames.count - 1, max(0, definition.colorIndex)))
        }
        if spaces.isEmpty { spaces = BrowserSpace.defaults }
        lastIssuedSpaceID = max(2, max(lastIssuedSpaceID, spaces.map(\.id).max() ?? 2))
        let validSpaceIDs = Set(spaceIDs)
        if !validSpaceIDs.contains(space) {
            // Preserve legacy invalid-space clamping; custom IDs are not indices.
            space = validSpaceIDs == Set([0, 1, 2]) ? min(2, max(0, space)) : spaces[0].id
        }
        sidebarWidth = sidebarWidth.isFinite ? min(500, max(164, sidebarWidth)) : 228
        var seen = Set<UUID>()
        tabs = tabs.filter { tab in
            validSpaceIDs.contains(tab.space) && seen.insert(tab.id).inserted && (tab.isHome || tab.isVideoDemo || URLInput.directURL(tab.address) != nil)
        }
        let tabSpaces = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.space) })
        var grouped = Set<UUID>()
        splits = (splits ?? []).filter { group in
            guard group.primaryID != group.secondaryID, let space = tabSpaces[group.primaryID], tabSpaces[group.secondaryID] == space,
                  !grouped.contains(group.primaryID), !grouped.contains(group.secondaryID) else { return false }
            grouped.insert(group.primaryID); grouped.insert(group.secondaryID); return true
        }
        if let group = split(for: activeID) { activeID = group.primaryID }
        lastSelectedTabIDsBySpace = (lastSelectedTabIDsBySpace ?? [:]).filter { entry in
            validSpaceIDs.contains(entry.key) && tabSpaces[entry.value] == entry.key
        }.mapValues { split(for: $0)?.primaryID ?? $0 }
        if let selected = active { space = selected.space }
        else if let id = rememberedTab(in: space) ?? visibleTabs.first?.id { activeID = id }
        else { add() }
        rememberActiveSelection()
    }
}

enum URLInput {
    static func directURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func resolve(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if ["orbit://newtab", "about:blank"].contains(text) { return "orbit://newtab" }
        if text == "orbit://video" { return "orbit://video" }
        if let url = directURL(text) { return url.absoluteString }
        if text.contains("://") || text.lowercased().hasPrefix("javascript:") || text.lowercased().hasPrefix("file:") || text.lowercased().hasPrefix("data:") { return nil }
        if !text.contains(where: { $0.isWhitespace }) && (text.contains(".") || text.hasPrefix("localhost") || text.hasPrefix("[::1]")) {
            let scheme = (text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")) ? "http://" : "https://"
            if let url = directURL(scheme + text) { return url.absoluteString }
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url?.absoluteString
    }
}

enum SessionFile {
    static func load(_ url: URL) -> BrowserSession {
        guard let data = try? Data(contentsOf: url), var session = try? JSONDecoder().decode(BrowserSession.self, from: data) else { return .fresh() }
        session.sanitize(); return session
    }
    static func save(_ session: BrowserSession, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: url, options: .atomic)
    }
}
