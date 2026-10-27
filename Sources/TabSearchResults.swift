import AppKit

/// Local-only ranking. Original order breaks ties; an empty query puts the
/// active tab first, without pretending the model contains recency timestamps.
enum TabSearchMatcher {
    /// One palette owns one index. Entries retain only search keys for current
    /// tabs; IDs alone never authorize reuse after navigation or a saved edit.
    struct Index {
        private struct Entry {
            let title: String
            let address: String
            let savedAddress: String?
            let normalizedTitle: String
            let addresses: [String]
            let sites: [String]

            init(_ tab: BrowserTab) {
                title = tab.displayTitle; address = tab.address; savedAddress = tab.saved?.address
                normalizedTitle = normalized(title)
                var rawAddresses = [address]
                if let savedAddress, savedAddress != address { rawAddresses.append(savedAddress) }
                addresses = rawAddresses.map { normalized($0.removingPercentEncoding ?? $0) }
                sites = addresses.map { value in
                    if value.hasPrefix("https://") { return String(value.dropFirst(8)) }
                    if value.hasPrefix("http://") { return String(value.dropFirst(7)) }
                    return value
                }
            }
            func matches(_ tab: BrowserTab) -> Bool {
                title == tab.displayTitle && address == tab.address && savedAddress == tab.saved?.address
            }
        }
        private var entries: [UUID: Entry] = [:]

        mutating func matches(tabs: [BrowserTab], query: String, activeID: UUID, limit: Int = 6) -> [BrowserTab] {
            guard limit > 0 else { entries.removeAll(); return [] }
            let query = normalized(query)
            guard !query.isEmpty else {
                // Opening the palette should not normalize every tab before a
                // user types. Remove obsolete keys even during an empty search.
                if !entries.isEmpty {
                    let ids = Set(tabs.map(\.id))
                    entries = entries.filter { ids.contains($0.key) }
                }
                var active: [BrowserTab] = [], others: [BrowserTab] = []
                for tab in tabs {
                    if tab.id == activeID { if active.count < limit { active.append(tab) } }
                    else if others.count < limit { others.append(tab) }
                }
                return Array((active + others).prefix(limit))
            }
            let tokens = query.split(separator: " ").map(String.init)
            var current: [UUID: Entry] = [:]
            current.reserveCapacity(tabs.count)
            var ranked: [(BrowserTab, Int, Int)] = []
            for (index, tab) in tabs.enumerated() {
                let entry: Entry
                if let cached = entries[tab.id], cached.matches(tab) { entry = cached }
                else { entry = Entry(tab) }
                current[tab.id] = entry
                let title = entry.normalizedTitle, addresses = entry.addresses
                let rank: Int
                if title == query { rank = 0 }
                else if title.hasPrefix(query) { rank = 1 }
                else if title.contains(query) { rank = 2 }
                else if entry.sites.contains(where: { $0.hasPrefix(query) }) || addresses.contains(where: { $0.hasPrefix(query) }) { rank = 3 }
                else if addresses.contains(where: { $0.contains(query) }) { rank = 4 }
                else if tokens.allSatisfy({ token in title.contains(token) || addresses.contains(where: { $0.contains(token) }) }) { rank = 5 }
                else { continue }
                ranked.append((tab, rank, index))
            }
            entries = current
            return ranked.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if (lhs.0.id == activeID) != (rhs.0.id == activeID) { return lhs.0.id == activeID }
                return lhs.2 < rhs.2
            }.prefix(limit).map { $0.0 }
        }
    }

    /// Stateless callers retain the original API; a live results view reuses
    /// its own index across typing and asynchronous suggestion updates.
    static func matches(tabs: [BrowserTab], query: String, activeID: UUID, limit: Int = 6) -> [BrowserTab] {
        var index = Index()
        return index.matches(tabs: tabs, query: query, activeID: activeID, limit: limit)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Palette geometry, after Yab's field: about half the window wide (520–760pt), a 20pt corner, a 56pt input row
/// with large type, 38pt rows, section headings, and a footer saying what Return does. The card keeps one height
/// while you type (rows scroll inside it), so nothing jumps; it shrinks only when the window is too short.
enum PaletteGeometry {
    static let cornerRadius: CGFloat = 20
    static let inputHeight: CGFloat = 56
    /// Where the result list starts, below the input row.
    static let resultsTop: CGFloat = 62
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 28
    static let sectionGap: CGFloat = 6
    static let footerHeight: CGFloat = 48
    /// Rows area of a full-size card: nine and a half rows, as Yab shows.
    static let designResultsHeight: CGFloat = 362
    static let typicalRows = 9
    /// Space kept clear above and below the card.
    static let margin: CGFloat = 20
    /// Everything but the rows: the input row and the footer.
    static let chromeHeight: CGFloat = resultsTop + footerHeight
    static func width(forWindowWidth w: CGFloat) -> CGFloat {
        min(max(0, w - 40), max(520, min(760, (w * 0.495).rounded())))
    }
    static func top(forWindowHeight h: CGFloat) -> CGFloat {
        let card = chromeHeight + designResultsHeight
        return max(margin, ((h - card) * 0.42).rounded())
    }
    /// Where the card goes and how tall its rows area is. A full card sits a little above center; in a short window
    /// it rises to the margin and its rows area shrinks to the room left (rows scroll).
    static func fit(windowHeight h: CGFloat, resultsHeight: CGFloat = 0) -> (top: CGFloat, visibleResultsHeight: CGFloat) {
        let room = max(0, h - 2 * margin - chromeHeight)
        let visible = min(designResultsHeight, room)
        let card = chromeHeight + visible
        return (max(min(margin, h), ((h - card) * 0.42).rounded()), visible)
    }
}

/// What the selected row stands for, so the field's keys and its actions menu can act on it.
enum PaletteTarget: Equatable {
    case tab(UUID, address: String)
    /// A known web address: a completed site, a visited page or a quick action.
    case address(String, alwaysNewTab: Bool)
    /// Typed text: an address or words for the default engine.
    case query(String)
    /// A suggestion, or words for the scoped engine.
    case search(String)
    case command(PaletteCommand)
    case calculation(PaletteCalculation)
}

/// The palette's result list, below the field. The parent keeps first responder in the field and forwards arrow
/// keys, Return and Tab here. An empty field lists Recent Tabs, Favorites and Quick Actions under headings;
/// typed text lists, in order: an answer, the completed site, the search, open and visited pages, suggestions
/// and commands.
@MainActor final class TabSearchResultsView: NSView {
    var faviconProvider: ((UUID) -> NSImage?)? { didSet { refreshFavicons() } }
    /// Unsubmitted URL text may consult the cache, but must not start a fetch.
    var siteFaviconProvider: ((URL, Bool) -> NSImage?)? { didSet { refreshFavicons() } }
    var onSelect: ((UUID) -> Void)?
    var onSubmitQuery: ((String) -> Void)?
    /// A chosen remote suggestion or scoped search; the parent routes it to the
    /// active site engine, or to the default engine when none is scoped.
    var onSearch: ((String) -> Void)?
    /// A chosen browser command (Settings, History…); the parent runs it.
    var onCommand: ((PaletteCommand) -> Void)?
    /// A completed site, visited page or quick action; true forces a new tab.
    var onOpenAddress: ((String, Bool) -> Void)?
    /// A calculator answer to put on the clipboard.
    var onCopy: ((String) -> Void)?
    /// The selection moved or the rows changed: the footer re-reads `returnTitle`.
    var onSelectionChange: (() -> Void)?
    /// After ⌘T Return opens a new tab; after ⌘L it replaces this page. Only the footer wording depends on it.
    var opensInNewTab = false
    var preferredHeight: CGFloat { max(44, contentHeight) }
    private(set) var selectedIndex = 0
    private static let rowHeight = PaletteGeometry.rowHeight
    private enum Entry {
        case query(String)
        case search(String)
        case tab(BrowserTab)
        case command(PaletteCommand)
        case site(PaletteCompletion)
        case history(PaletteHistoryHit)
        case quickAction(PaletteQuickAction)
        case calculation(PaletteCalculation)
        var identity: String {
            switch self {
            case .query: return "query"
            case .search(let text): return "search:\(text)"
            case .tab(let tab): return tab.id.uuidString
            case .command(let command): return "command:\(command.id)"
            case .site(let completion): return "site:\(PaletteAddressKey.key(completion.address))"
            case .history(let hit): return "page:\(PaletteAddressKey.key(hit.address))"
            case .quickAction(let action): return "quick:\(action.id)"
            case .calculation: return "calculation"
            }
        }
    }
    private var entries: [Entry] = []
    private var searchIndex = TabSearchMatcher.Index()
    private var rows: [TabSearchResultRow] = []
    private var rowOrigins: [CGFloat] = []
    private var headers: [(label: NSTextField, y: CGFloat)] = []
    private var contentHeight: CGFloat = 0
    private var engineURL: URL?
    private var scoped = false
    private var lastQuery = ""
    private var accent: NSColor = .controlAccentColor
    private var accentText: NSColor = .labelColor
    private var selectionFlip: DispatchWorkItem?
    // One shared highlight glides between rows instead of each row repainting.
    private let highlight = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No matching tabs")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 9
        highlight.layer?.cornerCurve = .continuous
        highlight.setAccessibilityElement(false)
        addSubview(highlight)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.maximumNumberOfLines = 1
        emptyLabel.setAccessibilityElement(true)
        addSubview(emptyLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // swiftlint:disable:next function_parameter_count
    func update(tabs: [BrowserTab], query: String, activeID: UUID, canCreate: Bool,
                spaces: [BrowserSpace] = BrowserSpace.legacyDefaults, profiles: [BrowserProfile] = BrowserProfile.defaults,
                engine: SiteSearchEngine? = nil, suggestions: [String] = [],
                commands: [PaletteCommandMatch] = [], selectionTint: NSColor? = nil,
                history: [PaletteHistoryHit] = [], completion: PaletteCompletion? = nil,
                recentTabIDs: [UUID]? = nil, calculation: PaletteCalculation? = nil,
                quickActions: [(action: PaletteQuickAction, leading: Bool)] = [],
                folderNames: [UUID: String] = [:], searchEngineName: String? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIdentity = entries.indices.contains(selectedIndex) ? entries[selectedIndex].identity : nil
        scoped = engine != nil
        if let engine {
            // Scoped to one site: its own color, as Arc does.
            accent = engine.color; accentText = engine.accentTextColor
        } else {
            // A quiet neutral fill with normal text, as Yab's field.
            accent = .labelColor.withAlphaComponent(0.075); accentText = .labelColor
        }
        engineURL = engine.flatMap { URL(string: "https://\($0.host)") }
        var sections: [(title: String?, entries: [Entry])] = []
        // A blank untitled tab is never worth a row.
        let listable = tabs.filter { !($0.isHome && $0.displayTitle == "New tab") }
        if engine != nil {
            searchIndex = TabSearchMatcher.Index()
            // Scoped to one site: the typed text searches it, suggestions refine it.
            var scopedEntries: [Entry] = []
            if !trimmed.isEmpty { scopedEntries.append(.search(trimmed)) }
            scopedEntries += suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(6).map(Entry.search)
            sections = [(nil, scopedEntries)]
        } else if trimmed.isEmpty {
            // Yab's empty field: the last tabs you were on (the first one preselected, so ⌘T Return jumps back),
            // Favorites, and Quick Actions.
            let byID = Dictionary(listable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let order = recentTabIDs ?? listable.map(\.id)
            var recent: [BrowserTab] = []
            for id in order where id != activeID {
                guard let tab = byID[id], !recent.contains(where: { $0.id == id }) else { continue }
                recent.append(tab)
                if recent.count == 3 { break }
            }
            // A lone current tab still shows, so the list is never blank while tabs exist.
            if recent.isEmpty, let active = byID[activeID] { recent = [active] }
            if !recent.isEmpty { sections.append(("Recent Tabs", recent.map(Entry.tab))) }
            let favorites = listable.filter { tab in tab.isFavorite && tab.id != activeID && !recent.contains { $0.id == tab.id } }
            if !favorites.isEmpty { sections.append(("Favorites", favorites.prefix(4).map(Entry.tab))) }
            if canCreate { sections.append(("Quick Actions", PaletteQuickActionCatalog.suggested.map(Entry.quickAction))) }
        } else {
            var lead: [Entry] = []
            if let calculation { lead.append(.calculation(calculation)) }
            var matchedTabs = searchIndex.matches(tabs: listable, query: trimmed, activeID: activeID, limit: 5)
            // The completed site leads; when it is already open, its tab takes the row and Return switches to it.
            if let completion {
                let key = PaletteAddressKey.key(completion.address)
                if let open = listable.first(where: { PaletteAddressKey.key($0.address) == key && $0.id != activeID }) {
                    lead.append(.tab(open)); matchedTabs.removeAll { $0.id == open.id }
                } else { lead.append(.site(completion)) }
            }
            lead += quickActions.filter(\.leading).map { Entry.quickAction($0.action) }
            lead += commands.filter(\.leading).map { Entry.command($0.command) }
            if canCreate { lead.append(.query(trimmed)) }
            let completedKey = completion.map { PaletteAddressKey.key($0.address) }
            let pages = matchedTabs.map(Entry.tab)
                + history.filter { PaletteAddressKey.key($0.address) != completedKey }.prefix(max(0, 5 - matchedTabs.count)).map(Entry.history)
            let room = max(0, 12 - lead.count - pages.count)
            let suggested = suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(min(4, room)).map(Entry.search)
            let trailing = quickActions.filter { !$0.leading }.map { Entry.quickAction($0.action) }
                + commands.filter { !$0.leading }.map { Entry.command($0.command) }
            sections = [(nil, lead + pages + suggested + trailing)]
        }
        sections = sections.filter { !$0.entries.isEmpty }
        entries = sections.flatMap(\.entries)
        if trimmed == lastQuery, let previousIdentity, let index = entries.firstIndex(where: { $0.identity == previousIdentity }) {
            selectedIndex = index
        } else { selectedIndex = 0 }
        lastQuery = trimmed

        // Rows and headings, top to bottom.
        headers.forEach { $0.label.removeFromSuperview() }
        headers = []
        rowOrigins = []
        var y: CGFloat = 0
        for (index, section) in sections.enumerated() {
            if let title = section.title {
                if index > 0 { y += PaletteGeometry.sectionGap }
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 12, weight: .medium)
                label.textColor = .secondaryLabelColor
                label.setAccessibilityRole(.staticText)
                addSubview(label)
                headers.append((label, y))
                y += PaletteGeometry.headerHeight
            }
            for _ in section.entries { rowOrigins.append(y); y += Self.rowHeight }
        }
        contentHeight = entries.isEmpty ? 0 : y + 6

        let activeSpace = tabs.first { $0.id == activeID }?.space
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.enumerated().map { index, entry in
            let row = TabSearchResultRow(frame: .zero)
            row.selectedTextColor = accentText
            switch entry {
            case .query(let text):
                let addressLike = Self.looksLikeAddress(text)
                row.configure(title: text, detail: addressLike ? "" : (searchEngineName ?? "Search"), badge: "",
                              symbol: addressLike ? "globe" : "magnifyingglass", boxed: true)
            case .search(let text):
                let detail = (engine != nil && index == 0) ? (engine?.name ?? "") : ""
                row.configure(title: text, detail: detail, badge: "", symbol: "magnifyingglass", boxed: true)
            case .tab(let tab):
                // Quiet context only: where the tab lives. The footer says what Return does.
                let context: String
                if tab.id == activeID { context = "Current Tab" }
                else if let folder = tab.folderID.flatMap({ folderNames[$0] }) { context = "In \(folder)" }
                else if tab.isFavorite { context = "Favorite" }
                else if tab.space != activeSpace {
                    // IDs remain stable when Spaces are renamed, reordered or deleted.
                    context = spaces.first(where: { $0.id == tab.space })?.name ?? "Unknown Space"
                } else { context = "" }
                let address = tab.isHome ? "" : tab.isVideoDemo ? "Picture in Picture demo"
                    : PaletteAddressKey.display(tab.isUnloaded ? (tab.saved?.address ?? tab.address) : tab.address)
                let title = tab.displayTitle.isEmpty ? address : tab.displayTitle
                row.configure(title: title, detail: title == address ? "" : address, badge: context, symbol: tab.symbol)
            case .command(let command):
                let live = ShortcutCommand(paletteID: command.id).map { ShortcutStore.shared.combo(for: $0).compact }
                row.configure(title: command.title, detail: command.detail,
                              badge: live ?? command.shortcut ?? "", symbol: command.symbol, boxed: true)
            case .site(let completion):
                let shown = PaletteAddressKey.display(completion.text)
                row.configure(title: shown, detail: completion.title == shown ? "" : completion.title, badge: "", symbol: "globe")
            case .history(let hit):
                let address = PaletteAddressKey.display(hit.address)
                row.configure(title: hit.title.isEmpty ? address : hit.title, detail: hit.title.isEmpty ? "" : address,
                              badge: "", symbol: "clock")
            case .quickAction(let action):
                let look = Self.quickActionLook(action.id)
                row.configure(title: action.title, detail: action.host, badge: "", symbol: look.symbol, boxed: true, tint: look.color)
            case .calculation(let calculation):
                row.configure(title: "= " + calculation.display, detail: calculation.expression, badge: "", symbol: "equal", boxed: true)
            }
            row.setFavicon(favicon(for: entry))
            row.isSelected = index == selectedIndex
            row.onActivate = { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.refreshSelection(animated: false)
                _ = self.activateSelection()
            }
            row.onHover = { [weak self] in
                guard let self, self.selectedIndex != index else { return }
                self.selectedIndex = index; self.refreshSelection(animated: false)
            }
            addSubview(row)
            return row
        }
        paintHighlight()
        moveHighlight(animated: false)
        emptyLabel.isHidden = !entries.isEmpty
        if engine != nil {
            emptyLabel.stringValue = trimmed.isEmpty ? "Suggestions appear as you type" : "Press Return to search"
        } else {
            emptyLabel.stringValue = trimmed.isEmpty ? "No tabs" : "No matching tabs"
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
        onSelectionChange?()
    }

    private func paintHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = scoped ? accent : (effectiveAppearance.isDarkPalette ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.068))
            highlight.layer?.backgroundColor = fill.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintHighlight()
    }

    /// Images can arrive while the palette is open without replacing rows,
    /// changing keyboard selection or disturbing the shared highlight.
    func refreshFavicons() {
        for (entry, row) in zip(entries, rows) { row.setFavicon(favicon(for: entry)) }
    }
    private func favicon(for entry: Entry) -> NSImage? {
        switch entry {
        case .tab(let tab): return faviconProvider?(tab.id)
        case .command, .calculation: return nil
        case .search: return engineURL.flatMap { siteFaviconProvider?($0, true) }
        case .site(let completion): return URL(string: completion.address).flatMap { siteFaviconProvider?($0, false) }
        case .history(let hit): return URL(string: hit.address).flatMap { siteFaviconProvider?($0, false) }
        case .quickAction: return nil
        case .query(let text):
            let url: URL?
            if let direct = URLInput.directURL(text) { url = direct }
            else if !text.contains(where: { $0.isWhitespace }) &&
                        (text.contains(".") || text.hasPrefix("localhost") || text.hasPrefix("[::1]")) {
                url = URLInput.resolve(text).flatMap(URLInput.directURL)
            } else { url = nil }
            return url.flatMap { siteFaviconProvider?($0, false) }
        }
    }

    /// What the selected row is, for the field's keys and the actions menu.
    var selectedTarget: PaletteTarget? {
        guard entries.indices.contains(selectedIndex) else { return nil }
        switch entries[selectedIndex] {
        case .query(let text): return .query(text)
        case .search(let text): return .search(text)
        case .tab(let tab): return .tab(tab.id, address: tab.isUnloaded ? (tab.saved?.address ?? tab.address) : tab.address)
        case .command(let command): return .command(command)
        case .site(let completion): return .address(completion.address, alwaysNewTab: false)
        case .history(let hit): return .address(hit.address, alwaysNewTab: false)
        case .quickAction(let action): return .address(action.address, alwaysNewTab: true)
        case .calculation(let calculation): return .calculation(calculation)
        }
    }
    /// A Quick Action's own glyph and color, drawn by Bam (no service artwork).
    static func quickActionLook(_ id: String) -> (symbol: String, color: NSColor) {
        switch id {
        case "doc": return ("doc.text.fill", NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1))
        case "meet": return ("video.fill", NSColor(srgbRed: 0.0, green: 0.62, blue: 0.47, alpha: 1))
        case "sheet": return ("tablecells.fill", NSColor(srgbRed: 0.06, green: 0.62, blue: 0.35, alpha: 1))
        case "slides": return ("rectangle.on.rectangle", NSColor(srgbRed: 0.96, green: 0.65, blue: 0.0, alpha: 1))
        case "cal": return ("calendar", NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1))
        case "form": return ("list.bullet.rectangle.fill", NSColor(srgbRed: 0.45, green: 0.28, blue: 0.75, alpha: 1))
        case "figma": return ("pencil.and.outline", NSColor(srgbRed: 0.64, green: 0.35, blue: 1.0, alpha: 1))
        case "linear": return ("circle.lefthalf.filled", NSColor(srgbRed: 0.37, green: 0.42, blue: 0.82, alpha: 1))
        default: return ("plus", .secondaryLabelColor)
        }
    }
    /// "example.com/path", "localhost:3000" or a full URL, not words or sums.
    static func looksLikeAddress(_ text: String) -> Bool {
        if URLInput.directURL(text) != nil { return true }
        let pattern = #"^(localhost|\[::1\]|[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z0-9-]*|\d{1,3}(\.\d{1,3}){3})(:\d+)?([/?#].*)?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    /// The footer's "what Return does" for the selected row.
    var returnTitle: String {
        switch selectedTarget {
        case .tab: return "Switch to Tab"
        case .command: return "Run Command"
        case .calculation: return "Copy Answer"
        case .address(_, let alwaysNewTab): return alwaysNewTab || opensInNewTab ? "Open in New Tab" : "Open"
        case .search: return opensInNewTab ? "Search in New Tab" : "Search"
        case .query(let text):
            if Self.looksLikeAddress(text) { return opensInNewTab ? "Open in New Tab" : "Open" }
            return opensInNewTab ? "Search in New Tab" : "Search"
        case nil: return opensInNewTab ? "Open in New Tab" : "Open"
        }
    }

    /// A discrete press wraps at the ends and glides. A held key (auto-repeat) steps instantly, applies colors at
    /// once and stops at the first or last row, so selection never flickers or jumps back to the top mid-hold.
    func moveSelection(delta: Int, repeating: Bool = false) {
        guard !entries.isEmpty, delta != 0 else { return }
        if repeating {
            let next = min(entries.count - 1, max(0, selectedIndex + delta))
            guard next != selectedIndex else { return }
            selectedIndex = next
            refreshSelection(animated: false)
        } else {
            let amount = delta % entries.count
            selectedIndex = (selectedIndex + amount + entries.count) % entries.count
            refreshSelection(animated: true)
        }
    }

    @discardableResult func activateSelection() -> Bool {
        guard entries.indices.contains(selectedIndex) else { return false }
        switch entries[selectedIndex] {
        case .query(let query):
            guard let onSubmitQuery else { return false }
            onSubmitQuery(query)
        case .search(let text):
            guard let onSearch else { return false }
            onSearch(text)
        case .tab(let tab):
            guard let onSelect else { return false }
            onSelect(tab.id)
        case .command(let command):
            guard let onCommand else { return false }
            onCommand(command)
        case .site(let completion):
            guard let onOpenAddress else { return false }
            onOpenAddress(completion.address, false)
        case .history(let hit):
            guard let onOpenAddress else { return false }
            onOpenAddress(hit.address, false)
        case .quickAction(let action):
            guard let onOpenAddress else { return false }
            onOpenAddress(action.address, true)
        case .calculation(let calculation):
            guard let onCopy else { return false }
            onCopy(calculation.plain)
        }
        return true
    }

    private func refreshSelection(animated: Bool = false) {
        selectionFlip?.cancel(); selectionFlip = nil
        // A highlight still gliding toward an earlier row stops where it is before retargeting.
        if !animated { highlight.layer?.removeAllAnimations() }
        let applyColors = { [weak self] in
            guard let self else { return }
            for (index, row) in self.rows.enumerated() { row.isSelected = index == self.selectedIndex }
        }
        moveHighlight(animated: animated)
        if animated && scoped && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Over a saturated engine color, flip text colors mid-glide so neither row shows the wrong contrast.
            let work = DispatchWorkItem(block: applyColors)
            selectionFlip = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        } else {
            applyColors()
        }
        if rows.indices.contains(selectedIndex) {
            NSAccessibility.post(element: rows[selectedIndex], notification: .selectedChildrenChanged)
        }
        revealSelection()
        onSelectionChange?()
    }
    /// When the results scroll, keeps the selected row in view (and its section heading, for the first row).
    func revealSelection() {
        guard rows.indices.contains(selectedIndex), let clip = enclosingScrollView?.contentView else { return }
        var target = rowFrame(at: selectedIndex)
        if let header = headers.last(where: { $0.y < target.minY }), target.minY - header.y <= PaletteGeometry.headerHeight + 0.5 {
            target = target.union(NSRect(x: 0, y: header.y, width: 1, height: 1))
        }
        let visible = clip.documentVisibleRect
        guard target.minY < visible.minY || target.maxY > visible.maxY else { return }
        let y = target.minY < visible.minY ? target.minY : target.maxY - visible.height
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
    private func rowFrame(at index: Int) -> NSRect {
        let y = rowOrigins.indices.contains(index) ? rowOrigins[index] : CGFloat(index) * Self.rowHeight
        return NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight - 1)
    }
    /// Glides the shared highlight to the selected row; a held arrow key
    /// retargets the in-flight animation instead of snapping row to row.
    private func moveHighlight(animated: Bool) {
        guard rows.indices.contains(selectedIndex) else { highlight.isHidden = true; return }
        highlight.isHidden = false
        let destination = rowFrame(at: selectedIndex)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                highlight.animator().frame = destination
            }
        } else {
            highlight.frame = destination
        }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight) }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = rowFrame(at: index) }
        for header in headers {
            header.label.frame = NSRect(x: 12, y: header.y + 7, width: max(0, bounds.width - 24), height: 16)
        }
        moveHighlight(animated: false)
        // The label always shows its full text, centered.
        let emptyWidth = emptyLabel.measuredTextWidth + 8
        emptyLabel.frame = NSRect(x: (bounds.width - emptyWidth) / 2, y: 14, width: emptyWidth, height: 18)
    }
}

extension NSAppearance {
    /// True for any dark variant (Dark Aqua, vibrant dark, their high-contrast forms).
    var isDarkPalette: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSTextField {
    /// A truncating label can under-report intrinsicContentSize; measure the text.
    var measuredTextWidth: CGFloat {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return ceil((stringValue as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// One calm single-line result, as Yab's: icon, title, the dimmed address after it, and one quiet piece of context
/// on the right (a folder, a Space, a shortcut). What Return does lives in the palette's footer, not on rows.
@MainActor private final class TabSearchResultRow: NSView {
    var onActivate: (() -> Void)?
    var onHover: (() -> Void)?
    var selectedTextColor: NSColor = .labelColor
    var isSelected = false { didSet { applySelection(); setAccessibilitySelected(isSelected) } }
    private let icon = NSImageView()
    /// A hairline rounded square behind symbol icons (search, commands), as Yab draws them.
    private let iconBox = NSView()
    private var boxed = false
    /// A Quick Action's color: its glyph takes it and its box a soft wash of it.
    private var tint: NSColor?
    private var favicon: NSImage?
    private var symbol = "magnifyingglass"
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 5.5
        iconBox.layer?.cornerCurve = .continuous
        iconBox.layer?.borderWidth = 1
        for child in [iconBox, icon, title, detail, badge] { child.setAccessibilityElement(false); addSubview(child) }
        title.font = .systemFont(ofSize: 14)
        detail.font = .systemFont(ofSize: 14)
        badge.font = .systemFont(ofSize: 13)
        badge.alignment = .right
        for label in [title, detail, badge] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1 }
        // The title gives way last: the address truncates first.
        icon.imageScaling = .scaleProportionallyUpOrDown
        applySelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(title: String, detail: String, badge: String, symbol: String, boxed: Bool = false, tint: NSColor? = nil) {
        self.tint = tint
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.badge.stringValue = badge
        self.symbol = symbol
        self.boxed = boxed
        favicon = nil
        icon.image = symbolImage()
        icon.identifier = nil
        setAccessibilityLabel([title, detail, badge].filter { !$0.isEmpty }.joined(separator: ", "))
        toolTip = detail.isEmpty ? title : detail
        applySelection()
        needsLayout = true
    }
    private func symbolImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: boxed ? 11 : 13, weight: boxed ? .semibold : .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
    func setFavicon(_ image: NSImage?) {
        guard favicon !== image else { return }
        favicon = image
        icon.image = image ?? symbolImage()
        icon.identifier = image == nil ? nil : NSUserInterfaceItemIdentifier("website-favicon")
        applySelection()
    }
    private func applySelection() {
        // The parent's shared highlight view paints the selection background.
        let primary: NSColor = isSelected ? selectedTextColor : .labelColor
        let secondary: NSColor = isSelected && selectedTextColor != .labelColor ? selectedTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        title.textColor = primary
        detail.textColor = secondary
        badge.textColor = secondary
        icon.contentTintColor = favicon == nil ? (isSelected && selectedTextColor != .labelColor ? selectedTextColor : (tint ?? .secondaryLabelColor)) : nil
        iconBox.isHidden = !(boxed && favicon == nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let tint {
                iconBox.layer?.borderColor = NSColor.clear.cgColor
                iconBox.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
            } else {
                iconBox.layer?.borderColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.16 : 0.12).cgColor
                iconBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.02).cgColor
            }
        }
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelection()
    }
    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        // Icons center on the field's magnifier; text starts under the typed text.
        iconBox.frame = NSRect(x: 9, y: middle - 10, width: 20, height: 20)
        icon.frame = favicon == nil && boxed ? NSRect(x: 12, y: middle - 7, width: 14, height: 14)
                                             : NSRect(x: 11, y: middle - 8, width: 16, height: 16)
        let textX: CGFloat = 42
        var trailing = bounds.width - 12
        let badgeWidth = badge.stringValue.isEmpty ? 0 : min(200, badge.measuredTextWidth + 4)
        if badgeWidth > 0 {
            badge.frame = NSRect(x: trailing - badgeWidth, y: middle - 9, width: badgeWidth, height: 17)
            trailing = badge.frame.minX - 16
        } else { badge.frame = .zero }
        let available = max(0, trailing - textX)
        let detailNatural = detail.stringValue.isEmpty ? 0 : detail.measuredTextWidth + 4
        // The title keeps at least 60% when both are long; the address takes what is left.
        let titleWidth = min(title.measuredTextWidth + 4, detailNatural == 0 ? available : max(available * 0.6, available - detailNatural - 10))
        title.frame = NSRect(x: textX, y: middle - 9.5, width: titleWidth, height: 18)
        let detailX = textX + titleWidth + 8
        detail.frame = NSRect(x: detailX, y: middle - 9.5, width: max(0, min(detailNatural, trailing - detailX)), height: 18)
    }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        // Selection follows real pointer movement only. Rows resliding under a
        // stationary cursor (suggestions arriving, panel resizing) generate
        // entered events but no moved events, and must not steal the selection.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        super.updateTrackingAreas()
    }
    /// Only an actual pointer movement takes the selection (a zero-delta move from a re-laid-out row never does).
    override func mouseMoved(with event: NSEvent) {
        guard event.deltaX != 0 || event.deltaY != 0 else { return }
        onHover?()
    }
    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { guard let onActivate else { return false }; onActivate(); return true }
}
