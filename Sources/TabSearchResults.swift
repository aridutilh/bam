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

/// Embed below the command palette's text field. The parent keeps first responder
/// in that field and forwards arrow keys, Return and Tab to this view.
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
    var preferredHeight: CGFloat { max(44, CGFloat(rows.count) * Self.rowHeight + 8) }
    private(set) var selectedIndex = 0
    private static let rowHeight: CGFloat = 40
    private enum Entry {
        case query(String)
        case search(String)
        case tab(BrowserTab)
        case command(PaletteCommand)
        var identity: String {
            switch self {
            case .query: return "query"
            case .search(let text): return "search:\(text)"
            case .tab(let tab): return tab.id.uuidString
            case .command(let command): return "command:\(command.id)"
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
        highlight.layer?.cornerRadius = 8
        highlight.setAccessibilityElement(false)
        addSubview(highlight)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.maximumNumberOfLines = 1
        emptyLabel.setAccessibilityElement(true)
        addSubview(emptyLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(tabs: [BrowserTab], query: String, activeID: UUID, canCreate: Bool,
                spaces: [BrowserSpace] = BrowserSpace.legacyDefaults, profiles: [BrowserProfile] = BrowserProfile.defaults,
                engine: SiteSearchEngine? = nil, suggestions: [String] = [],
                commands: [PaletteCommandMatch] = [], selectionTint: NSColor? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIdentity = entries.indices.contains(selectedIndex) ? entries[selectedIndex].identity : nil
        if let engine {
            // Scoped to one site: its own color, as Arc does.
            accent = engine.color; accentText = engine.accentTextColor
        } else {
            // Arc's selection is a quiet wash of the Space's color with normal text, not a saturated accent fill.
            accent = (selectionTint ?? .controlAccentColor).withAlphaComponent(0.3); accentText = .labelColor
        }
        engineURL = engine.flatMap { URL(string: "https://\($0.host)") }
        entries = []
        if engine != nil {
            searchIndex = TabSearchMatcher.Index()
            // Scoped to one site: the typed text searches it, suggestions refine it.
            if !trimmed.isEmpty { entries.append(.search(trimmed)) }
            entries += suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(5).map(Entry.search)
        } else {
            // A command the text names outright leads; looser command matches
            // follow the tabs so an open page keeps winning its own name.
            entries += commands.filter(\.leading).map { Entry.command($0.command) }
            if canCreate && !trimmed.isEmpty { entries.append(.query(trimmed)) }
            entries += searchIndex.matches(tabs: tabs, query: trimmed, activeID: activeID).map(Entry.tab)
            entries += commands.filter { !$0.leading }.map { Entry.command($0.command) }
            let room = max(0, 8 - entries.count)
            entries += suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(min(3, room)).map(Entry.search)
        }
        if trimmed == lastQuery, let previousIdentity, let index = entries.firstIndex(where: { $0.identity == previousIdentity }) {
            selectedIndex = index
        } else { selectedIndex = 0 }
        lastQuery = trimmed
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.enumerated().map { index, entry in
            let row = TabSearchResultRow(frame: .zero)
            row.selectedTextColor = accentText
            switch entry {
            case .query(let text):
                row.configure(title: text, detail: "", badge: "", symbol: "magnifyingglass", action: "Open or Search")
            case .search(let text):
                let action = (engine != nil && index == 0) ? "Search \(engine?.name ?? "")" : "Search"
                row.configure(title: text, detail: "", badge: "", symbol: "magnifyingglass", action: action)
            case .tab(let tab):
                // IDs remain stable when Spaces are renamed, reordered or deleted.
                let space = spaces.first(where: { $0.id == tab.space })?.name ?? "Unknown Space"
                let profileID = tab.saved?.profileID ?? spaces.first(where: { $0.id == tab.space })?.profileID ?? BrowserProfile.defaultID
                let profile = profiles.first(where: { $0.id == profileID })?.name ?? "Profile"
                let context = tab.isFavorite ? "Favorite · \(profile)" : (tab.id == activeID ? "\(space) · Current" : space)
                let address = tab.isHome ? "New tab" : tab.isVideoDemo ? "Picture in Picture demo" : tab.address
                let detail = tab.isUnloaded ? "Sleeping · \(address)" : address
                // The Space stays as quiet context; the trailing label says what Return does.
                row.configure(title: tab.displayTitle.isEmpty ? address : tab.displayTitle, detail: detail,
                              badge: context, symbol: tab.symbol, action: tab.id == activeID ? nil : "Switch to Tab")
            case .command(let command):
                let live = ShortcutCommand(paletteID: command.id).map { ShortcutStore.shared.combo(for: $0).compact }
                row.configure(title: command.title, detail: command.detail,
                              badge: live ?? command.shortcut ?? "Command", symbol: command.symbol)
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

    /// Images can arrive while the palette is open without replacing rows,
    /// changing keyboard selection or disturbing the shared highlight.
    func refreshFavicons() {
        for (entry, row) in zip(entries, rows) { row.setFavicon(favicon(for: entry)) }
    }
    private func favicon(for entry: Entry) -> NSImage? {
        switch entry {
        case .tab(let tab): return faviconProvider?(tab.id)
        case .command: return nil
        case .search: return engineURL.flatMap { siteFaviconProvider?($0, true) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        } else {
            applyColors()
        }
        if rows.indices.contains(selectedIndex) {
            NSAccessibility.post(element: rows[selectedIndex], notification: .selectedChildrenChanged)
        }
    }
    private func rowFrame(at index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight - 2)
    }
    /// Glides the shared highlight to the selected row; a held arrow key
    /// retargets the in-flight animation instead of snapping row to row.
    private func moveHighlight(animated: Bool) {
        guard rows.indices.contains(selectedIndex) else { highlight.isHidden = true; return }
        highlight.isHidden = false
        let destination = rowFrame(at: selectedIndex)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
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
        moveHighlight(animated: false)
        // The label always shows its full text, centered.
        let emptyWidth = emptyLabel.measuredTextWidth + 8
        emptyLabel.frame = NSRect(x: (bounds.width - emptyWidth) / 2, y: 14, width: emptyWidth, height: 18)
    }
}

extension NSTextField {
    /// A truncating label can under-report intrinsicContentSize; measure the text.
    var measuredTextWidth: CGFloat {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return ceil((stringValue as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// One Arc-style single-line result: icon, title, dimmed address, quiet context, and a trailing action
/// ("Switch to Tab" with an arrow box) that brightens on the selected row.
@MainActor private final class TabSearchResultRow: NSView {
    var onActivate: (() -> Void)?
    var onHover: (() -> Void)?
    var selectedTextColor: NSColor = .white
    var isSelected = false { didSet { applySelection(); setAccessibilitySelected(isSelected) } }
    private let icon = NSImageView()
    private var favicon: NSImage?
    private var symbol = "magnifyingglass"
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
        arrowBox.wantsLayer = true; arrowBox.layer?.cornerRadius = 5
        for child in [icon, title, detail, badge, action, arrowBox, arrow] { child.setAccessibilityElement(false); addSubview(child) }
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.alignment = .right
        action.font = .systemFont(ofSize: 12, weight: .medium)
        action.alignment = .right
        for label in [title, detail, badge, action] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1 }
        icon.imageScaling = .scaleProportionallyUpOrDown
        arrow.imageScaling = .scaleProportionallyDown
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        applySelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(title: String, detail: String, badge: String, symbol: String, action: String? = nil) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.badge.stringValue = badge
        self.action.stringValue = action ?? ""
        self.symbol = symbol
        favicon = nil
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.identifier = nil
        setAccessibilityLabel([title, detail, badge, action ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        toolTip = detail.isEmpty ? title : detail
        applySelection()
        needsLayout = true
    }
    func setFavicon(_ image: NSImage?) {
        guard favicon !== image else { return }
        favicon = image
        icon.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.identifier = image == nil ? nil : NSUserInterfaceItemIdentifier("website-favicon")
        applySelection()
    }
    private func applySelection() {
        // The parent's shared highlight view paints the selection background.
        let primary: NSColor = isSelected ? selectedTextColor : .labelColor
        let secondary: NSColor = isSelected ? selectedTextColor.withAlphaComponent(0.75) : .tertiaryLabelColor
        title.textColor = primary
        detail.textColor = secondary
        badge.textColor = secondary
        icon.contentTintColor = favicon == nil ? (isSelected ? selectedTextColor : .secondaryLabelColor) : nil
        // Every actionable row shows its action; the selected one reads at full strength.
        let hasAction = !action.stringValue.isEmpty
        action.isHidden = !hasAction; arrow.isHidden = !hasAction; arrowBox.isHidden = !hasAction
        action.textColor = isSelected ? primary : .tertiaryLabelColor
        arrow.contentTintColor = isSelected ? primary : .tertiaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arrowBox.layer?.backgroundColor = (isSelected ? NSColor.labelColor.withAlphaComponent(0.14)
                                                          : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        icon.frame = NSRect(x: 12, y: middle - 8, width: 16, height: 16)
        var trailing = bounds.width - 10
        if !arrowBox.isHidden {
            arrowBox.frame = NSRect(x: trailing - 22, y: middle - 11, width: 22, height: 22)
            arrow.frame = arrowBox.frame.insetBy(dx: 4, dy: 4)
            trailing = arrowBox.frame.minX - 8
            let actionWidth = min(160, action.measuredTextWidth + 6)
            action.frame = NSRect(x: trailing - actionWidth, y: middle - 8, width: actionWidth, height: 16)
            trailing = action.frame.minX - 12
        }
        let badgeWidth = min(180, badge.stringValue.isEmpty ? 0 : badge.measuredTextWidth + 6)
        let badgeX = trailing - badgeWidth
        badge.frame = NSRect(x: badgeX, y: middle - 7, width: badgeWidth, height: 15)
        let titleWidth = min(title.measuredTextWidth + 6, max(0, badgeX - 46))
        title.frame = NSRect(x: 38, y: middle - 9, width: titleWidth, height: 18)
        detail.frame = NSRect(x: 38 + titleWidth + 8, y: middle - 8,
                              width: max(0, badgeX - (38 + titleWidth + 16)), height: 16)
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
