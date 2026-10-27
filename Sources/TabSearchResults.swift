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

/// Palette geometry, as Arc's command bar: about half the window wide (540–820pt), a 10pt corner, a 63pt input row
/// over a hairline, and roomy 50pt rows. The top stays put while results come and go (sized for a typical five
/// rows, centered), so the field never jumps; the card's height follows its rows. When a long list wouldn't fit the
/// window, the card rises only as far as needed and its rows scroll.
enum PaletteGeometry {
    static let cornerRadius: CGFloat = 10
    static let inputHeight: CGFloat = 63
    static let rowHeight: CGFloat = 50
    /// The selected row's fill inside its 50pt slot.
    static let highlightInset: CGFloat = 2.5
    static let typicalRows = 5
    /// Space kept clear above and below the card.
    static let margin: CGFloat = 20
    /// The gap between the input's hairline and the first row, and below the last row.
    static let listPadding: CGFloat = 8
    /// The input row, the gap under its hairline and the bottom padding around the rows.
    static let chromeHeight: CGFloat = inputHeight + 2 * listPadding
    static func width(forWindowWidth w: CGFloat) -> CGFloat {
        min(max(0, w - 40), max(540, min(820, (w * 0.505).rounded())))
    }
    static func top(forWindowHeight h: CGFloat) -> CGFloat {
        let typical = chromeHeight + CGFloat(typicalRows) * rowHeight
        return max(margin, ((h - typical) / 2).rounded())
    }
    /// Where the card goes and how much of its rows show. The centered top holds while the card fits; otherwise
    /// it rises toward the top margin, and past that the rows are cut to the room left (they scroll).
    static func fit(windowHeight h: CGFloat, resultsHeight: CGFloat) -> (top: CGFloat, visibleResultsHeight: CGFloat) {
        let room = max(0, h - 2 * margin - chromeHeight)
        let visible = min(resultsHeight, room)
        let bottomLimit = h - margin - (chromeHeight + visible)
        return (max(min(margin, h), min(top(forWindowHeight: h), bottomLimit)), visible)
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

/// The palette's result list, below the field, as Arc's: one list, no headings. An empty field lists your most
/// recent tabs (the previous one first, so ⌘T Return jumps back). Typed text lists, in order: an answer, the
/// completed site, the search, open and visited pages, suggestions and commands. The parent keeps first
/// responder in the field and forwards arrow keys, Return and Tab here.
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
    var preferredHeight: CGFloat { max(44, CGFloat(rows.count) * Self.rowHeight) }
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
    private var engineURL: URL?
    private var lastQuery = ""
    private var accent: NSColor = .controlAccentColor
    private var accentText: NSColor = .white
    private var selectionFlip: DispatchWorkItem?
    // One shared highlight glides between rows instead of each row repainting.
    private let highlight = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No matching tabs")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
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

    /// `selectionTint` is the Space's color: the selected row is filled with it, as Arc does. `editingAddress`
    /// marks ⌘L's untouched address: the current page leads, then recent tabs.
    func update(tabs: [BrowserTab], query: String, activeID: UUID, canCreate: Bool,
                spaces: [BrowserSpace] = BrowserSpace.legacyDefaults, profiles: [BrowserProfile] = BrowserProfile.defaults,
                engine: SiteSearchEngine? = nil, suggestions: [String] = [],
                commands: [PaletteCommandMatch] = [], selectionTint: NSColor? = nil,
                history: [PaletteHistoryHit] = [], completion: PaletteCompletion? = nil,
                recentTabIDs: [UUID]? = nil, calculation: PaletteCalculation? = nil,
                quickActions: [(action: PaletteQuickAction, leading: Bool)] = [],
                folderNames: [UUID: String] = [:], editingAddress: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIdentity = entries.indices.contains(selectedIndex) ? entries[selectedIndex].identity : nil
        if let engine {
            // Scoped to one site: its own color.
            accent = engine.color; accentText = engine.accentTextColor
        } else {
            // Arc fills the selected row with the Space's color and white text.
            accent = PaletteSelection.fill(for: selectionTint ?? .controlAccentColor, in: effectiveAppearance); accentText = .white
        }
        engineURL = engine.flatMap { URL(string: "https://\($0.host)") }
        // A blank untitled tab is never worth a row.
        let listable = tabs.filter { !($0.isHome && $0.displayTitle == "New tab") }
        let byID = Dictionary(listable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func recentTabs(limit: Int) -> [BrowserTab] {
            var recent: [BrowserTab] = []
            for id in recentTabIDs ?? listable.map(\.id) where id != activeID {
                guard let tab = byID[id], !recent.contains(where: { $0.id == id }) else { continue }
                recent.append(tab)
                if recent.count == limit { break }
            }
            return recent
        }
        entries = []
        if engine != nil {
            searchIndex = TabSearchMatcher.Index()
            // Scoped to one site: the typed text searches it, suggestions refine it.
            if !trimmed.isEmpty { entries.append(.search(trimmed)) }
            entries += suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(5).map(Entry.search)
        } else if trimmed.isEmpty {
            // Arc's empty field: the tabs you were just on, the previous one first.
            var recent = recentTabs(limit: 5)
            // A lone current tab still shows, so the list is never blank while tabs exist.
            if recent.isEmpty, let active = byID[activeID] { recent = [active] }
            entries = recent.map(Entry.tab)
        } else if editingAddress, let current = byID[activeID] {
            // ⌘L, before any edit: this page, then where you were before, then page commands (Copy Link) last,
            // where Arc keeps its own command rows.
            entries = [.tab(current)] + recentTabs(limit: 4).map(Entry.tab) + commands.map { Entry.command($0.command) }
        } else {
            if let calculation { entries.append(.calculation(calculation)) }
            var matchedTabs = searchIndex.matches(tabs: listable, query: trimmed, activeID: activeID)
            // The completed site leads; when it is already open, its tab takes the row and Return switches to it.
            if let completion {
                let key = PaletteAddressKey.key(completion.address)
                if let open = listable.first(where: { PaletteAddressKey.key($0.address) == key && $0.id != activeID }) {
                    entries.append(.tab(open)); matchedTabs.removeAll { $0.id == open.id }
                } else { entries.append(.site(completion)) }
            }
            entries += quickActions.filter(\.leading).map { Entry.quickAction($0.action) }
            // A command the text names outright leads; looser matches follow the pages.
            entries += commands.filter(\.leading).map { Entry.command($0.command) }
            if canCreate { entries.append(.query(trimmed)) }
            entries += matchedTabs.map(Entry.tab)
            let completedKey = completion.map { PaletteAddressKey.key($0.address) }
            entries += history.filter { PaletteAddressKey.key($0.address) != completedKey }
                .prefix(max(0, 3 - max(0, matchedTabs.count - 3))).map(Entry.history)
            // Arc keeps the list short: suggestions only fill what's left of about eight rows.
            let room = max(0, 8 - entries.count)
            entries += suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(min(3, room)).map(Entry.search)
            entries += quickActions.filter { !$0.leading }.map { Entry.quickAction($0.action) }
            entries += commands.filter { !$0.leading }.map { Entry.command($0.command) }
        }
        if trimmed == lastQuery, let previousIdentity, let index = entries.firstIndex(where: { $0.identity == previousIdentity }) {
            selectedIndex = index
        } else { selectedIndex = 0 }
        lastQuery = trimmed

        let activeSpace = tabs.first { $0.id == activeID }?.space
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.enumerated().map { index, entry in
            let row = TabSearchResultRow(frame: .zero)
            row.selectedTextColor = accentText
            switch entry {
            case .query(let text):
                row.configure(title: text, detail: "", badge: "", symbol: Self.looksLikeAddress(text) ? "globe" : "magnifyingglass")
            case .search(let text):
                row.configure(title: text, detail: "", badge: "", symbol: "magnifyingglass",
                              action: (engine != nil && index == 0) ? "Search \(engine?.name ?? "")" : nil)
            case .tab(let tab):
                // Quiet context where it helps (another Space, a folder); the trailing label says what Return does.
                let current = tab.id == activeID
                let context: String
                if current { context = editingAddress ? "" : "Current Tab" }
                else if let folder = tab.folderID.flatMap({ folderNames[$0] }) { context = folder }
                else if tab.space != activeSpace && !tab.isFavorite {
                    // IDs remain stable when Spaces are renamed, reordered or deleted.
                    context = spaces.first(where: { $0.id == tab.space })?.name ?? "Unknown Space"
                } else { context = "" }
                let address = tab.isHome ? "" : tab.isVideoDemo ? "Picture in Picture demo"
                    : PaletteAddressKey.display(tab.isUnloaded ? (tab.saved?.address ?? tab.address) : tab.address)
                let title = tab.displayTitle.isEmpty ? address : tab.displayTitle
                // Arc lists tabs by title alone under an empty field and ⌘L; typed results add " — address".
                let detail = trimmed.isEmpty || editingAddress || title == address ? "" : address
                row.configure(title: title, detail: detail, badge: context, symbol: tab.symbol,
                              action: current ? nil : "Switch to Tab")
            case .command(let command):
                // The chord the menu command wears now (remapped or removed in Settings › Shortcuts).
                let store = ShortcutStore.shared
                let live = store.command(command.action).map { _ in store.combo(forID: command.action)?.compact ?? "" }
                    ?? ShortcutCommand(paletteID: command.id).map { store.combo(for: $0).compact }
                row.configure(title: command.title, detail: command.detail,
                              badge: live ?? command.shortcut ?? "", symbol: command.symbol)
            case .site(let completion):
                let shown = PaletteAddressKey.display(completion.text)
                if completion.title.isEmpty || completion.title == shown {
                    row.configure(title: shown, detail: "", badge: "", symbol: "globe")
                } else {
                    row.configure(title: completion.title, detail: shown, badge: "", symbol: "globe")
                }
            case .history(let hit):
                let address = PaletteAddressKey.display(hit.address)
                row.configure(title: hit.title.isEmpty ? address : hit.title, detail: hit.title.isEmpty ? "" : address,
                              badge: "", symbol: "clock")
            case .quickAction(let action):
                let look = Self.quickActionLook(action.id)
                row.configure(title: action.title, detail: action.host, badge: "", symbol: look.symbol, tint: look.color)
            case .calculation(let calculation):
                row.configure(title: calculation.display, detail: calculation.expression, badge: "", symbol: "equal", action: "Copy")
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
        highlight.layer?.backgroundColor = accent.cgColor
        for row in rows { row.accent = accent }
        moveHighlight(animated: false)
        emptyLabel.isHidden = !entries.isEmpty
        if engine != nil {
            emptyLabel.stringValue = trimmed.isEmpty ? "Suggestions appear as you type" : "Press Return to search"
        } else {
            emptyLabel.stringValue = trimmed.isEmpty ? "No tabs" : "No matching tabs"
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
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

    /// Images can arrive while the palette is open without replacing rows,
    /// changing keyboard selection or disturbing the shared highlight.
    func refreshFavicons() {
        for (entry, row) in zip(entries, rows) { row.setFavicon(favicon(for: entry)) }
    }
    private func favicon(for entry: Entry) -> NSImage? {
        switch entry {
        case .tab(let tab): return faviconProvider?(tab.id)
        case .command, .calculation, .quickAction: return nil
        case .search: return engineURL.flatMap { siteFaviconProvider?($0, true) }
        case .site(let completion): return URL(string: completion.address).flatMap { siteFaviconProvider?($0, false) }
        case .history(let hit): return URL(string: hit.address).flatMap { siteFaviconProvider?($0, false) }
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
    /// The selected row's view, for anchoring the ⌘K actions menu beside it.
    var selectedRowView: NSView? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

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
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Flip text colors mid-glide so neither row shows selected-on-clear
            // or clear-on-selected for the whole highlight travel.
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
    }
    /// When the results scroll (a long list in a short window), keeps the selected row in view, without animation.
    func revealSelection() {
        guard rows.indices.contains(selectedIndex), let clip = enclosingScrollView?.contentView else { return }
        let target = rowFrame(at: selectedIndex)
        let visible = clip.documentVisibleRect
        guard target.minY < visible.minY || target.maxY > visible.maxY else { return }
        let y = target.minY < visible.minY ? target.minY : target.maxY - visible.height
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
    private func rowFrame(at index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
    }
    /// Glides the shared highlight to the selected row; a held arrow key
    /// retargets the in-flight animation instead of snapping row to row.
    private func moveHighlight(animated: Bool) {
        guard rows.indices.contains(selectedIndex) else { highlight.isHidden = true; return }
        highlight.isHidden = false
        let inset = PaletteGeometry.highlightInset
        let destination = rowFrame(at: selectedIndex).insetBy(dx: 0, dy: inset)
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
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight.layer?.backgroundColor = accent.cgColor
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight) }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = rowFrame(at: index) }
        moveHighlight(animated: false)
        // The label always shows its full text, centered.
        let emptyWidth = emptyLabel.measuredTextWidth + 8
        emptyLabel.frame = NSRect(x: (bounds.width - emptyWidth) / 2, y: 14, width: emptyWidth, height: 18)
    }
}

/// The selected row's fill: the Space's color at full strength, as Arc. A pale Space color (Bam's dark-mode tints
/// are pastels) is deepened so white text stays readable; an imported Arc accent is used as it is.
enum PaletteSelection {
    @MainActor static func fill(for tint: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = tint.usingColorSpace(.deviceRGB) }
        guard let rgb = resolved else { return tint }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let dark = appearance.isDarkPalette
        // Grays stay gray (a neutral Space); everything else keeps its hue.
        if saturation < 0.08 { return NSColor(white: dark ? 0.36 : 0.30, alpha: 1) }
        let s = min(0.82, max(saturation, 0.5))
        var b = max(0.42, min(brightness, dark ? 0.80 : 0.72))
        // The selected row's text is white: yellow, lime and cyan Spaces darken until it reads at 4.5:1.
        while b > 0.3, whiteContrast(on: NSColor(deviceHue: hue, saturation: s, brightness: b, alpha: 1)) < 4.5 { b -= 0.02 }
        return NSColor(deviceHue: hue, saturation: s, brightness: b, alpha: 1)
    }
    /// WCAG contrast of white text on an opaque color.
    static func whiteContrast(on color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 21 }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return 1.05 / (luminance + 0.05)
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

/// One Arc-style result: icon, title, " — address" dimmed after it, quiet context, and a trailing action
/// ("Switch to Tab" with an arrow) that brightens on the selected row, where the arrow sits in a white key.
@MainActor private final class TabSearchResultRow: NSView {
    var onActivate: (() -> Void)?
    var onHover: (() -> Void)?
    var selectedTextColor: NSColor = .white
    /// The selection fill; the selected row's arrow takes it over a white key.
    var accent: NSColor = .controlAccentColor { didSet { applySelection() } }
    var isSelected = false { didSet { applySelection(); setAccessibilitySelected(isSelected) } }
    private let icon = NSImageView()
    private var favicon: NSImage?
    private var symbol = "magnifyingglass"
    /// A Quick Action's own color for its glyph.
    private var tint: NSColor?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private let arrowBox = NSView()
    private let arrow = NSImageView()
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        arrowBox.wantsLayer = true; arrowBox.layer?.cornerRadius = 5; arrowBox.layer?.cornerCurve = .continuous
        for child in [icon, title, detail, badge, action, arrowBox, arrow] { child.setAccessibilityElement(false); addSubview(child) }
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        detail.font = .systemFont(ofSize: 14, weight: .medium)
        badge.font = .systemFont(ofSize: 13, weight: .medium)
        badge.alignment = .right
        action.font = .systemFont(ofSize: 14, weight: .semibold)
        action.alignment = .right
        for label in [title, detail, badge, action] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1 }
        detail.lineBreakMode = .byTruncatingMiddle
        icon.imageScaling = .scaleProportionallyUpOrDown
        arrow.imageScaling = .scaleProportionallyDown
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        applySelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(title: String, detail: String, badge: String, symbol: String, action: String? = nil, tint: NSColor? = nil) {
        self.title.stringValue = title
        // Arc's "Title — address".
        self.detail.stringValue = detail.isEmpty ? "" : "— " + detail
        self.badge.stringValue = badge
        self.action.stringValue = action ?? ""
        self.symbol = symbol
        self.tint = tint
        favicon = nil
        icon.image = symbolImage()
        icon.identifier = nil
        setAccessibilityLabel([title, detail, badge, action ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        toolTip = detail.isEmpty ? title : detail
        applySelection()
        needsLayout = true
    }
    private func symbolImage() -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
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
        let secondary: NSColor = isSelected ? selectedTextColor.withAlphaComponent(0.62) : .tertiaryLabelColor
        title.textColor = primary
        detail.textColor = secondary
        badge.textColor = secondary
        icon.contentTintColor = favicon == nil ? (isSelected ? selectedTextColor : (tint ?? .secondaryLabelColor)) : nil
        let hasAction = !action.stringValue.isEmpty
        action.isHidden = !hasAction; arrow.isHidden = !hasAction; arrowBox.isHidden = !hasAction
        action.textColor = isSelected ? primary : .tertiaryLabelColor
        // Selected: the arrow sits in a white key, colored like the fill. Otherwise a faint key, as Arc.
        arrow.contentTintColor = isSelected ? accent : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arrowBox.layer?.backgroundColor = (isSelected ? NSColor.white.withAlphaComponent(0.95)
                                               : NSColor.labelColor.withAlphaComponent(0.07)).cgColor
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
        // The icon centers under the field's own icon; text starts under the typed text.
        icon.frame = NSRect(x: 13, y: middle - 9, width: 18, height: 18)
        let textX: CGFloat = 42
        var trailing = bounds.width - 12
        if !action.isHidden {
            arrowBox.frame = NSRect(x: trailing - 24, y: middle - 12, width: 24, height: 24)
            arrow.frame = arrowBox.frame.insetBy(dx: 5, dy: 5)
            trailing = arrowBox.frame.minX - 10
            let actionWidth = min(160, action.measuredTextWidth + 4)
            action.frame = NSRect(x: trailing - actionWidth, y: middle - 9, width: actionWidth, height: 18)
            trailing = action.frame.minX - 14
        }
        let badgeWidth = badge.stringValue.isEmpty ? 0 : min(180, badge.measuredTextWidth + 4)
        if badgeWidth > 0 {
            badge.frame = NSRect(x: trailing - badgeWidth, y: middle - 8.5, width: badgeWidth, height: 17)
            trailing = badge.frame.minX - 14
        } else { badge.frame = .zero }
        let available = max(0, trailing - textX)
        let detailNatural = detail.stringValue.isEmpty ? 0 : detail.measuredTextWidth + 4
        // The title keeps at least 60% when both are long; the address takes what is left.
        let titleWidth = min(title.measuredTextWidth + 4, detailNatural == 0 ? available : max(available * 0.6, available - detailNatural - 6))
        title.frame = NSRect(x: textX, y: middle - 9, width: titleWidth, height: 18)
        let detailX = textX + titleWidth + 4
        detail.frame = NSRect(x: detailX, y: middle - 9, width: max(0, min(detailNatural, trailing - detailX)), height: 18)
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
