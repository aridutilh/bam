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
/// in that field and forwards arrow keys and Return to this view.
@MainActor final class TabSearchResultsView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onSubmitQuery: ((String) -> Void)?
    var preferredHeight: CGFloat { max(44, CGFloat(rows.count) * Self.rowHeight) }
    private(set) var selectedIndex = 0
    private static let rowHeight: CGFloat = 46
    private enum Entry {
        case query(String)
        case tab(BrowserTab)
        var identity: String {
            switch self { case .query: return "query"; case .tab(let tab): return tab.id.uuidString }
        }
    }
    private var entries: [Entry] = []
    private var rows: [TabSearchResultRow] = []
    private var lastQuery = ""
    private let emptyLabel = NSTextField(labelWithString: "No matching tabs")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityElement(true)
        addSubview(emptyLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(tabs: [BrowserTab], query: String, activeID: UUID, canCreate: Bool,
                spaces: [BrowserSpace] = BrowserSpace.legacyDefaults) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIdentity = entries.indices.contains(selectedIndex) ? entries[selectedIndex].identity : nil
        entries = []
        if canCreate && !trimmed.isEmpty { entries.append(.query(trimmed)) }
        entries += TabSearchMatcher.matches(tabs: tabs, query: trimmed, activeID: activeID).map(Entry.tab)
        if trimmed == lastQuery, let previousIdentity, let index = entries.firstIndex(where: { $0.identity == previousIdentity }) {
            selectedIndex = index
        } else { selectedIndex = 0 }
        lastQuery = trimmed
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.enumerated().map { index, entry in
            let row = TabSearchResultRow(frame: .zero)
            switch entry {
            case .query(let text):
                row.configure(title: "Open or search “\(text)”", subtitle: "Return to open this address or search", badge: "↵", symbol: "magnifyingglass")
            case .tab(let tab):
                // IDs remain stable when Spaces are renamed, reordered or deleted.
                let space = spaces.first(where: { $0.id == tab.space })?.name ?? "Unknown Space"
                let badge = tab.isFavorite ? "Favorite · All Spaces" : (tab.id == activeID ? "\(space) · Current" : space)
                let address = tab.isHome ? "New tab" : tab.isVideoDemo ? "Picture in Picture demo" : tab.address
                let subtitle = tab.isUnloaded ? "Sleeping · \(address)" : address
                row.configure(title: tab.displayTitle.isEmpty ? address : tab.displayTitle, subtitle: subtitle, badge: badge, symbol: tab.symbol)
            }
            row.isSelected = index == selectedIndex
            row.onActivate = { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.refreshSelection()
                _ = self.activateSelection()
            }
            row.onHover = { [weak self] in
                guard let self, self.selectedIndex != index else { return }
                self.selectedIndex = index; self.refreshSelection()
            }
            addSubview(row)
            return row
        }
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.stringValue = trimmed.isEmpty ? "No tabs" : "No matching tabs"
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func moveSelection(delta: Int) {
        guard !entries.isEmpty, delta != 0 else { return }
        let amount = delta % entries.count
        selectedIndex = (selectedIndex + amount + entries.count) % entries.count
        refreshSelection()
    }

    @discardableResult func activateSelection() -> Bool {
        guard entries.indices.contains(selectedIndex) else { return false }
        switch entries[selectedIndex] {
        case .query(let query):
            guard let onSubmitQuery else { return false }
            onSubmitQuery(query)
        case .tab(let tab):
            guard let onSelect else { return false }
            onSelect(tab.id)
        }
        return true
    }

    private func refreshSelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
        if rows.indices.contains(selectedIndex) {
            NSAccessibility.post(element: rows[selectedIndex], notification: .selectedChildrenChanged)
        }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight) }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight - 2)
        }
        emptyLabel.frame = NSRect(x: 8, y: 14, width: max(0, bounds.width - 16), height: 18)
    }
}

@MainActor private final class TabSearchResultRow: NSView {
    var onActivate: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true; setAccessibilitySelected(isSelected) } }
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        for child in [icon, title, subtitle, badge] { child.setAccessibilityElement(false); addSubview(child) }
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        for label in [title, subtitle, badge] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1 }
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(title: String, subtitle: String, badge: String, symbol: String) {
        self.title.stringValue = title; self.subtitle.stringValue = subtitle; self.badge.stringValue = badge
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel("\(title), \(subtitle), \(badge)")
        toolTip = subtitle
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 13, width: 18, height: 18)
        let badgeWidth = min(126, max(30, badge.intrinsicContentSize.width + 2))
        badge.frame = NSRect(x: max(35, bounds.width - badgeWidth - 10), y: 7, width: badgeWidth, height: 15)
        title.frame = NSRect(x: 37, y: 5, width: max(0, bounds.width - 55 - badgeWidth), height: 18)
        subtitle.frame = NSRect(x: 37, y: 24, width: max(0, bounds.width - 49), height: 15)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 7, yRadius: 7).fill()
    }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { guard let onActivate else { return false }; onActivate(); return true }
}
