import Foundation

enum SavedTabKind: String, Codable { case kept, favorite }

struct SavedTabState: Codable, Equatable {
    var kind: SavedTabKind
    var address: String
    var customTitle: String?
    var customSymbol: String?
    var isUnloaded: Bool

    init(kind: SavedTabKind, address: String, customTitle: String? = nil,
         customSymbol: String? = nil, isUnloaded: Bool = false) {
        self.kind = kind; self.address = address; self.customTitle = customTitle
        self.customSymbol = customSymbol; self.isUnloaded = isUnloaded
    }
    private enum CodingKeys: String, CodingKey { case kind, address, customTitle, customSymbol, isUnloaded }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(SavedTabKind.self, forKey: .kind)
        address = try values.decode(String.self, forKey: .address)
        customTitle = try? values.decodeIfPresent(String.self, forKey: .customTitle)
        customSymbol = try? values.decodeIfPresent(String.self, forKey: .customSymbol)
        isUnloaded = (try? values.decodeIfPresent(Bool.self, forKey: .isUnloaded)) ?? false
    }
}

/// Memory sleeping resumes the current page; it is distinct from closing a
/// saved tab, which resets that tab to its original saved address.
struct TabSleepState: Codable, Equatable {
    var address: String
    var scrollX: Double
    var scrollY: Double

    fileprivate func matches(_ currentAddress: String) -> Bool {
        address == currentAddress && URLInput.directURL(address) != nil
            && scrollX.isFinite && scrollY.isFinite
            && abs(scrollX) <= 10_000_000 && abs(scrollY) <= 10_000_000
    }
}

struct BrowserTab: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var address: String
    var space: Int
    var saved: SavedTabState?
    var sleepState: TabSleepState?

    init(id: UUID = UUID(), title: String, address: String, space: Int,
         pinned: Bool = false, saved: SavedTabState? = nil, sleepState: TabSleepState? = nil) {
        self.id = id; self.title = title; self.address = address; self.space = space
        self.saved = saved ?? (pinned ? SavedTabState(kind: .kept, address: address) : nil)
        self.sleepState = sleepState
    }
    var pinned: Bool {
        get { saved != nil }
        set {
            if !newValue { saved = nil }
            else if saved == nil { saved = SavedTabState(kind: .kept, address: address) }
        }
    }
    var isFavorite: Bool { saved?.kind == .favorite }
    var isSaved: Bool { saved != nil }
    var isUnloaded: Bool { saved?.isUnloaded == true }
    var isSleeping: Bool { sleepState != nil }
    var displayTitle: String { saved?.customTitle ?? title }
    var isHome: Bool { address == "orbit://newtab" }
    var isVideoDemo: Bool { address == "orbit://video" }
    var symbol: String {
        if let symbol = saved?.customSymbol { return symbol }
        if isHome { return "sparkle" }
        if isVideoDemo { return "play.rectangle.fill" }
        if address.contains("developer.apple.com") { return "apple.logo" }
        if address.contains("github.com") { return "chevron.left.forwardslash.chevron.right" }
        if address.contains("wikipedia.org") { return "book.closed" }
        return "globe"
    }
    fileprivate static func validAddress(_ address: String) -> Bool {
        address == "orbit://newtab" || address == "orbit://video" || URLInput.directURL(address) != nil
    }
    fileprivate static func validCustomTitle(_ title: String) -> Bool {
        title.count <= 80 && !title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private enum CodingKeys: String, CodingKey { case id, title, address, space, pinned, saved, sleepState }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        address = try values.decode(String.self, forKey: .address)
        space = try values.decode(Int.self, forKey: .space)
        saved = try? values.decodeIfPresent(SavedTabState.self, forKey: .saved)
        sleepState = try? values.decodeIfPresent(TabSleepState.self, forKey: .sleepState)
        if saved == nil, (try? values.decodeIfPresent(Bool.self, forKey: .pinned)) == true {
            saved = SavedTabState(kind: .kept, address: address)
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(title, forKey: .title)
        try values.encode(address, forKey: .address); try values.encode(space, forKey: .space)
        try values.encode(pinned, forKey: .pinned)
        try values.encodeIfPresent(saved, forKey: .saved)
        try values.encodeIfPresent(sleepState, forKey: .sleepState)
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

    static func validName(_ raw: String) -> String? {
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
    private static let formatVersion = 4
    static let maximumFavorites = 12

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
    var favoriteTabs: [BrowserTab] { tabs.filter(\.isFavorite) }
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
        guard spaceDefinition(destination) != nil, let tab = tabs.first(where: { $0.id == id }), !tab.isFavorite else { return false }
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

    @discardableResult mutating func setRetention(id: UUID, kind: SavedTabKind?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        if kind == .favorite {
            guard split(for: id) == nil,
                  tabs[index].isFavorite || favoriteTabs.count < Self.maximumFavorites else { return false }
        }
        rememberActiveSelection()
        let wasFavorite = tabs[index].isFavorite
        if let kind {
            if tabs[index].saved == nil {
                guard BrowserTab.validAddress(tabs[index].address) else { return false }
                tabs[index].saved = SavedTabState(kind: kind, address: tabs[index].address)
            } else { tabs[index].saved?.kind = kind }
        } else { tabs[index].saved = nil }
        if wasFavorite && kind != .favorite { tabs[index].space = space }
        repairRememberedSelections()
        repairActiveSelection()
        return true
    }
    @discardableResult mutating func resetSavedTab(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let saved = tabs[index].saved,
              BrowserTab.validAddress(saved.address) else { return false }
        tabs[index].address = saved.address
        tabs[index].saved?.isUnloaded = false
        tabs[index].sleepState = nil
        return true
    }
    @discardableResult mutating func updateSavedTab(id: UUID, customTitle: String?, customSymbol: String?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isSaved else { return false }
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = customSymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.map(BrowserTab.validCustomTitle) ?? true,
              symbol.map({ $0.isEmpty || BrowserSpace.symbols.contains($0) }) ?? true else { return false }
        tabs[index].saved?.customTitle = title?.isEmpty == false ? title : nil
        tabs[index].saved?.customSymbol = symbol?.isEmpty == false ? symbol : nil
        return true
    }
    @discardableResult mutating func reorderSavedTab(id: UUID, by offset: Int) -> Bool {
        let primaryID = split(for: id)?.primaryID ?? id
        guard let source = tabs.first(where: { $0.id == primaryID }), let kind = source.saved?.kind else { return false }
        let secondaryIDs = Set((splits ?? []).map(\.secondaryID))
        let candidates = tabs.indices.filter {
            !secondaryIDs.contains(tabs[$0].id) && tabs[$0].saved?.kind == kind
                && (kind == .favorite || tabs[$0].space == source.space)
        }
        guard let current = candidates.firstIndex(where: { tabs[$0].id == primaryID }) else { return false }
        let (target, overflow) = current.addingReportingOverflow(offset)
        guard !overflow, candidates.indices.contains(target) else { return false }
        // Only primary positions determine row order. Secondary identities and
        // the pair itself remain intact even when a saved split row is moved.
        tabs.swapAt(candidates[current], candidates[target])
        return true
    }
    private func orderedTabs(in space: Int) -> [BrowserTab] {
        let grouped = Set((splits ?? []).map(\.secondaryID))
        let local = tabs.filter { $0.space == space && !$0.isFavorite && !grouped.contains($0.id) }
        return favoriteTabs + local.filter(\.isSaved) + local.filter { !$0.isSaved }
    }
    private func selectable(_ tab: BrowserTab, in space: Int) -> Bool {
        !tab.isUnloaded && (tab.isFavorite || tab.space == space)
    }
    private func fallbackTab(in space: Int, last: Bool = false) -> UUID? {
        let visible = orderedTabs(in: space).filter { !$0.isUnloaded }
        let ordinary = visible.filter { !$0.isSaved }
        let kept = visible.filter { $0.isSaved && !$0.isFavorite }
        let preferred = !ordinary.isEmpty ? ordinary : !kept.isEmpty ? kept : visible
        return (last ? preferred.last : preferred.first)?.id
    }
    private func rememberedTab(in space: Int) -> UUID? {
        guard let id = lastSelectedTabIDsBySpace?[space],
              let tab = tabs.first(where: { $0.id == id }), selectable(tab, in: space) else { return nil }
        return split(for: id)?.primaryID ?? id
    }
    private mutating func rememberActiveSelection() {
        guard let tab = active, !tab.isUnloaded, spaceDefinition(space) != nil else { return }
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        let selectedID = split(for: tab.id)?.primaryID ?? tab.id
        let context = tab.isFavorite ? space : tab.space
        lastSelectedTabIDsBySpace?[context] = selectedID
    }
    private mutating func repairRememberedSelection(in id: Int, preferred: UUID? = nil) {
        guard spaceDefinition(id) != nil else { lastSelectedTabIDsBySpace?[id] = nil; return }
        if let remembered = rememberedTab(in: id) {
            lastSelectedTabIDsBySpace?[id] = remembered
            return
        }
        let preferred = preferred.flatMap { candidate in
            tabs.first(where: { $0.id == candidate && selectable($0, in: id) })?.id
        }
        let replacement = preferred ?? fallbackTab(in: id, last: true)
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        lastSelectedTabIDsBySpace?[id] = replacement
    }
    private mutating func repairRememberedSelections() {
        for id in Array((lastSelectedTabIDsBySpace ?? [:]).keys) { repairRememberedSelection(in: id) }
    }
    private mutating func repairActiveSelection() {
        if let selected = active, !selected.isUnloaded,
           selected.isFavorite || spaceDefinition(selected.space) != nil {
            activeID = split(for: selected.id)?.primaryID ?? selected.id
            if !selected.isFavorite { space = selected.space }
            rememberActiveSelection()
        } else {
            if spaceDefinition(space) == nil { space = spaces[0].id }
            if let id = rememberedTab(in: space) ?? fallbackTab(in: space, last: true) { activeID = id; rememberActiveSelection() }
            else { add() }
        }
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
        let selectedID = split(for: id)?.primaryID ?? id
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }),
              tabs[index].isFavorite || spaceDefinition(tabs[index].space) != nil else { return }
        rememberActiveSelection()
        let members = split(for: selectedID).map { [$0.primaryID, $0.secondaryID] } ?? [selectedID]
        for index in tabs.indices where members.contains(tabs[index].id) { tabs[index].saved?.isUnloaded = false }
        activeID = selectedID
        if !tabs[index].isFavorite { space = tabs[index].space }
        rememberActiveSelection()
    }
    mutating func changeSpace(_ value: Int) {
        guard spaceDefinition(value) != nil else { return }
        rememberActiveSelection()
        space = value
        if let id = rememberedTab(in: space) ?? fallbackTab(in: space) {
            activeID = id
            rememberActiveSelection()
        } else { add() }
    }
    func split(for id: UUID) -> BrowserSplit? { (splits ?? []).first { $0.primaryID == id || $0.secondaryID == id } }
    @discardableResult mutating func makeSplit(primary: UUID, secondary: UUID) -> Bool {
        guard primary != secondary, let left = tabs.first(where: { $0.id == primary }),
              let right = tabs.first(where: { $0.id == secondary }), left.space == right.space,
              !left.isFavorite, !right.isFavorite, !left.isUnloaded, !right.isUnloaded,
              spaceDefinition(left.space) != nil else { return false }
        splits = (splits ?? []).filter { ![primary,secondary].contains($0.primaryID) && ![primary,secondary].contains($0.secondaryID) }
        splits?.append(BrowserSplit(primaryID: primary, secondaryID: secondary)); select(primary); return true
    }
    mutating func removeSplit(containing id: UUID) { splits = (splits ?? []).filter { $0.primaryID != id && $0.secondaryID != id } }
    @discardableResult mutating func close(_ id: UUID) -> BrowserTab? {
        guard let closing = tabs.first(where: { $0.id == id }) else { return nil }
        rememberActiveSelection()
        let group = split(for: id)
        let members = Set(group?.primaryID == id ? [id, group!.secondaryID] : [id])
        removeSplit(containing: id)
        for index in tabs.indices where members.contains(tabs[index].id) && tabs[index].isSaved {
            tabs[index].address = tabs[index].saved!.address
            tabs[index].saved?.isUnloaded = true
            tabs[index].sleepState = nil
        }
        tabs.removeAll { members.contains($0.id) && !$0.isSaved }
        repairRememberedSelections()
        repairActiveSelection()
        return closing
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
        var favoriteCount = 0
        tabs = tabs.compactMap { original in
            var tab = original
            guard seen.insert(tab.id).inserted else { return nil }
            if var saved = tab.saved {
                if !BrowserTab.validAddress(saved.address) {
                    guard BrowserTab.validAddress(tab.address) else { return nil }
                    saved.address = tab.address
                }
                let title = saved.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                saved.customTitle = title.map { !$0.isEmpty && BrowserTab.validCustomTitle($0) } == true ? title : nil
                let symbol = saved.customSymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
                saved.customSymbol = symbol.map { BrowserSpace.symbols.contains($0) } == true ? symbol : nil
                if saved.kind == .favorite {
                    if !validSpaceIDs.contains(tab.space) { tab.space = space }
                    favoriteCount += 1
                    if favoriteCount > Self.maximumFavorites { saved.kind = .kept }
                }
                tab.saved = saved
                if saved.isUnloaded || !BrowserTab.validAddress(tab.address) { tab.address = saved.address }
            }
            guard validSpaceIDs.contains(tab.space), BrowserTab.validAddress(tab.address) else { return nil }
            if let sleep = tab.sleepState, tab.isUnloaded || !sleep.matches(tab.address) { tab.sleepState = nil }
            return tab
        }
        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var grouped = Set<UUID>()
        splits = (splits ?? []).filter { group in
            guard group.primaryID != group.secondaryID,
                  let left = tabByID[group.primaryID], let right = tabByID[group.secondaryID], left.space == right.space,
                  !left.isFavorite, !right.isFavorite, !left.isUnloaded, !right.isUnloaded,
                  !grouped.contains(group.primaryID), !grouped.contains(group.secondaryID) else { return false }
            grouped.insert(group.primaryID); grouped.insert(group.secondaryID); return true
        }
        if let group = split(for: activeID) { activeID = group.primaryID }
        lastSelectedTabIDsBySpace = (lastSelectedTabIDsBySpace ?? [:]).filter { entry in
            validSpaceIDs.contains(entry.key) && tabByID[entry.value].map { selectable($0, in: entry.key) } == true
        }.mapValues { split(for: $0)?.primaryID ?? $0 }
        repairActiveSelection()

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
