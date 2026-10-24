import AppKit

/// Local-only ranking. Original order breaks ties; an empty query puts the
/// active tab first, without pretending the model contains recency timestamps.
enum TabSearchMatcher {
    static func matches(tabs: [BrowserTab], query: String, activeID: UUID, limit: Int = 6) -> [BrowserTab] {
        guard limit > 0 else { return [] }
        let query = normalized(query)
        let tokens = query.split(separator: " ").map(String.init)
        return tabs.enumerated().compactMap { index, tab -> (BrowserTab, Int, Int)? in
            guard !query.isEmpty else { return (tab, tab.id == activeID ? 0 : 1, index) }
            let title = normalized(tab.displayTitle)
            // A kept page may navigate away from its saved destination. Both
            // addresses remain useful local search keys without adding a duplicate result.
            let addresses = [tab.address, tab.saved?.address].compactMap { $0 }.map {
                normalized($0.removingPercentEncoding ?? $0)
            }
            let sites = addresses.map { $0.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression) }
            let rank: Int
            if title == query { rank = 0 }
            else if title.hasPrefix(query) { rank = 1 }
            else if title.contains(query) { rank = 2 }
            else if sites.contains(where: { $0.hasPrefix(query) }) || addresses.contains(where: { $0.hasPrefix(query) }) { rank = 3 }
            else if addresses.contains(where: { $0.contains(query) }) { rank = 4 }
            else if tokens.allSatisfy({ token in title.contains(token) || addresses.contains(where: { $0.contains(token) }) }) { rank = 5 }
            else { return nil }
            return (tab, rank, index)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if (lhs.0.id == activeID) != (rhs.0.id == activeID) { return lhs.0.id == activeID }
            return lhs.2 < rhs.2
        }.prefix(limit).map { $0.0 }
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
    var preferredHeight: CGFloat { max(44, CGFloat(rows.count) * Self.rowHeight + 8) }
    private(set) var selectedIndex = 0
    private static let rowHeight: CGFloat = 40
    private enum Entry {
        case query(String)
        case search(String)
        case tab(BrowserTab)
        var identity: String {
            switch self {
            case .query: return "query"
            case .search(let text): return "search:\(text)"
            case .tab(let tab): return tab.id.uuidString
            }
        }
    }
    private var entries: [Entry] = []
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
                engine: SiteSearchEngine? = nil, suggestions: [String] = []) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIdentity = entries.indices.contains(selectedIndex) ? entries[selectedIndex].identity : nil
        accent = engine?.color ?? .controlAccentColor
        accentText = engine?.accentTextColor ?? .white
        engineURL = engine.flatMap { URL(string: "https://\($0.host)") }
        entries = []
        if engine != nil {
            // Scoped to one site: the typed text searches it, suggestions refine it.
            if !trimmed.isEmpty { entries.append(.search(trimmed)) }
            entries += suggestions.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
                .prefix(5).map(Entry.search)
        } else {
            if canCreate && !trimmed.isEmpty { entries.append(.query(trimmed)) }
            entries += TabSearchMatcher.matches(tabs: tabs, query: trimmed, activeID: activeID).map(Entry.tab)
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
                row.configure(title: text, detail: "", badge: "Open or Search", symbol: "magnifyingglass")
            case .search(let text):
                let badge = (engine != nil && index == 0) ? "Search \(engine?.name ?? "")" : ""
                row.configure(title: text, detail: "", badge: badge, symbol: "magnifyingglass")
            case .tab(let tab):
                // IDs remain stable when Spaces are renamed, reordered or deleted.
                let space = spaces.first(where: { $0.id == tab.space })?.name ?? "Unknown Space"
                let profileID = tab.saved?.profileID ?? spaces.first(where: { $0.id == tab.space })?.profileID ?? BrowserProfile.defaultID
                let profile = profiles.first(where: { $0.id == profileID })?.name ?? "Profile"
                let context = tab.isFavorite ? "Favorite · \(profile)" : (tab.id == activeID ? "\(space) · Current" : space)
                let address = tab.isHome ? "New tab" : tab.isVideoDemo ? "Picture in Picture demo" : tab.address
                let detail = tab.isUnloaded ? "Sleeping · \(address)" : address
                row.configure(title: tab.displayTitle.isEmpty ? address : tab.displayTitle, detail: detail,
                              badge: context, symbol: tab.symbol)
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
                self.selectedIndex = index; self.refreshSelection(animated: true)
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

    func moveSelection(delta: Int) {
        guard !entries.isEmpty, delta != 0 else { return }
        let amount = delta % entries.count
        selectedIndex = (selectedIndex + amount + entries.count) % entries.count
        refreshSelection(animated: true)
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
        }
        return true
    }

    private func refreshSelection(animated: Bool = false) {
        selectionFlip?.cancel(); selectionFlip = nil
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

/// One Arc-style single-line result: icon, title, dimmed address, trailing
/// action badge. Selection fills the row with the palette's accent.
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
    private let arrow = NSImageView()
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        for child in [icon, title, detail, badge, arrow] { child.setAccessibilityElement(false); addSubview(child) }
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.alignment = .right
        for label in [title, detail, badge] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1 }
        icon.imageScaling = .scaleProportionallyUpOrDown
        arrow.imageScaling = .scaleProportionallyDown
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        applySelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(title: String, detail: String, badge: String, symbol: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.badge.stringValue = badge
        self.symbol = symbol
        favicon = nil
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.identifier = nil
        setAccessibilityLabel([title, detail, badge].filter { !$0.isEmpty }.joined(separator: ", "))
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
        arrow.contentTintColor = selectedTextColor
        arrow.isHidden = !isSelected
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        icon.frame = NSRect(x: 12, y: middle - 8, width: 16, height: 16)
        let showsArrow = !arrow.isHidden
        arrow.frame = NSRect(x: bounds.width - 26, y: middle - 7, width: 14, height: 14)
        let badgeWidth = min(180, badge.stringValue.isEmpty ? 0 : badge.measuredTextWidth + 6)
        let badgeX = bounds.width - badgeWidth - (showsArrow ? 32 : 12)
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
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { guard let onActivate else { return false }; onActivate(); return true }
}
