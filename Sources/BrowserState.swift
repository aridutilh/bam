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

struct BrowserSession: Codable {
    var tabs: [BrowserTab]
    var activeID: UUID
    var space = 0
    var sidebarWidth: Double = 228
    var sidebarVisible = true
    // Optional so sessions saved before per-space selection still decode.
    var lastSelectedTabIDsBySpace: [Int: UUID]? = nil
    var splits: [BrowserSplit]? = nil

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
        guard let tab = active, (0...2).contains(tab.space) else { return }
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        lastSelectedTabIDsBySpace?[tab.space] = tab.id
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
        guard let tab = tabs.first(where: { $0.id == selectedID }) else { return }
        rememberActiveSelection()
        activeID = selectedID; space = tab.space
        rememberActiveSelection()
    }
    mutating func changeSpace(_ value: Int) {
        rememberActiveSelection()
        space = min(2, max(0, value))
        if let id = rememberedTab(in: space) ?? visibleTabs.first(where: { !$0.pinned })?.id ?? visibleTabs.first?.id {
            activeID = id
            rememberActiveSelection()
        } else { add() }
    }
    func split(for id: UUID) -> BrowserSplit? { (splits ?? []).first { $0.primaryID == id || $0.secondaryID == id } }
    @discardableResult mutating func makeSplit(primary: UUID, secondary: UUID) -> Bool {
        guard primary != secondary, let left = tabs.first(where: { $0.id == primary }),
              let right = tabs.first(where: { $0.id == secondary }), left.space == right.space else { return false }
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
        space = min(2, max(0, space))
        sidebarWidth = sidebarWidth.isFinite ? min(500, max(164, sidebarWidth)) : 228
        var seen = Set<UUID>()
        tabs = tabs.filter { tab in
            (0...2).contains(tab.space) && seen.insert(tab.id).inserted && (tab.isHome || tab.isVideoDemo || URLInput.directURL(tab.address) != nil)
        }
        if tabs.isEmpty { self = .fresh(); return }
        let tabSpaces = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.space) })
        var grouped = Set<UUID>()
        splits = (splits ?? []).filter { group in
            guard group.primaryID != group.secondaryID, let space = tabSpaces[group.primaryID], tabSpaces[group.secondaryID] == space,
                  !grouped.contains(group.primaryID), !grouped.contains(group.secondaryID) else { return false }
            grouped.insert(group.primaryID); grouped.insert(group.secondaryID); return true
        }
        if let group = split(for: activeID) { activeID = group.primaryID }
        lastSelectedTabIDsBySpace = (lastSelectedTabIDsBySpace ?? [:]).filter { entry in
            (0...2).contains(entry.key) && tabSpaces[entry.value] == entry.key
        }
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
