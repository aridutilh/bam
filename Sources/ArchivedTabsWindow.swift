import AppKit

/// What the Archive window needs from the browser; closures, so it is testable offscreen.
struct ArchiveWindowSource {
    var records: () -> [ClosedRecord] = { [] }
    /// The site icon for an address, from cache only (opening the archive never fetches).
    var favicon: (String) -> NSImage? = { _ in nil }
    /// Restores one record (and removes it from the archive). False if it could not be taken.
    var restore: (UUID) -> Bool = { _ in false }
    var clear: () -> Bool = { false }
    /// "12 hours", or nil when auto-archive is off.
    var interval: () -> String? = { nil }
    var openSettings: () -> Void = {}
}

/// Archived tabs: everything closed by hand or by auto-archive, newest first, grouped by day, with
/// search and Restore. Drawn on Bam's paper like Settings.
@MainActor final class ArchivedTabsController: NSObject, NSWindowDelegate {
    let window: SettingsWindow
    let searchField = NSSearchField()
    private let source: ArchiveWindowSource
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let clearPill = BamPillButton(title: "Clear Archive…", symbol: "trash", compact: true)
    private(set) var shownRecordIDs: [UUID] = []
    private var shownOnce = false
    static let size = NSSize(width: 640, height: 660)

    init(source: ArchiveWindowSource) {
        self.source = source
        window = SettingsWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        super.init()
        window.title = "Archive"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.backgroundColor = BamTheme.bg
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("BamArchive")
        build()
    }

    private func build() {
        let paper = BamSurfaceView(frame: NSRect(origin: .zero, size: Self.size))
        paper.autoresizingMask = [.width, .height]
        window.contentView = paper
        let heading = NSTextField(labelWithString: "Archive")
        heading.font = BamType.display(26, weight: .heavy); heading.textColor = BamTheme.ink
        subtitle.font = BamType.sans(13); subtitle.textColor = BamTheme.muted; subtitle.isSelectable = false
        let settings = BamPillButton(title: "Change…", compact: true)
        settings.target = self; settings.action = #selector(openSettings)
        settings.setAccessibilityLabel("Change when tabs are archived")
        let subtitleRow = NSStackView(views: [subtitle, settings]); subtitleRow.spacing = 10; subtitleRow.alignment = .centerY
        searchField.placeholderString = "Search archived tabs"
        searchField.font = BamType.sans(13)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search archived tabs")
        clearPill.target = self; clearPill.action = #selector(confirmClear)
        let bar = NSStackView(views: [searchField, clearPill]); bar.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, subtitleRow, bar])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 2
        header.setCustomSpacing(14, after: subtitleRow)
        header.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(header)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedContainer(); document.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        paper.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: paper.topAnchor, constant: 40),
            header.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 30),
            header.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -30),
            bar.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 30),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -30),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -30)
        ])
    }

    func present(relativeTo parent: NSWindow?) {
        reload()
        if !shownOnce {
            shownOnce = true
            if !window.setFrameUsingName("BamArchive") {
                if let parent {
                    window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
                } else { window.center() }
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    /// Rebuilds the list from the archive as it is now, keeping the scroll position.
    func reload() {
        if let interval = source.interval() {
            subtitle.stringValue = "Tabs you closed, and Today tabs Bam closed after \(interval) unseen."
        } else {
            subtitle.stringValue = "Tabs you closed. Auto-archive is off."
        }
        let offset = scroll.contentView.bounds.origin
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = source.records()
        clearPill.isEnabled = !all.isEmpty
        let shown = Self.filter(all, query: searchField.stringValue)
        shownRecordIDs = shown.map(\.id)
        if shown.isEmpty {
            let empty = BamCard(frame: .zero); empty.cornerRadius = 12; empty.isQuiet = true; empty.isDashed = true
            empty.add(BamRow(title: all.isEmpty ? "Nothing archived yet" : "No archived tabs match",
                             detail: all.isEmpty ? "Tabs you close, and Today tabs you leave alone for a while, land here." : "Try other words, or part of an address.",
                             enabled: false, compact: true))
            add(empty)
        }
        var day = ""
        var card: BamCard?
        for record in shown {
            let title = ArchiveDay.title(for: record.closedAt)
            if title != day || card == nil {
                day = title
                let caption = SettingsCaption(title)
                add(caption, spacingAfter: 6)
                let next = BamCard(frame: .zero); next.cornerRadius = 12; next.isQuiet = true; next.separatorInset = 16
                add(next, spacingAfter: 18)
                card = next
            }
            let row = ArchivedTabRow(record: record, favicon: source.favicon(record.tabs.first?.address ?? ""))
            row.onRestore = { [weak self] in self?.restore(record.id) }
            card?.add(row)
        }
        column.superview?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func add(_ view: NSView, spacingAfter: CGFloat = 18) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(spacingAfter, after: view)
    }

    /// Every word must appear in a record's titles or addresses.
    static func filter(_ records: [ClosedRecord], query: String) -> [ClosedRecord] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return records }
        return records.filter { record in
            let text = record.tabs.map { $0.title + " " + $0.address }.joined(separator: " ")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    func restore(_ id: UUID) {
        if source.restore(id) { reload() } else { NSSound.beep() }
    }
    @objc private func searchChanged() { reload(); scroll.contentView.scroll(to: .zero) }
    @objc private func openSettings() { source.openSettings() }
    @objc private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear the archive?"
        alert.informativeText = "Removes every archived tab from this list. Open tabs, history, cookies and downloads are kept."
        alert.addButton(withTitle: "Clear Archive")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if !self.source.clear() { NSSound.beep() }
            self.reload()
        }
    }
}

/// One archived tab (or Split): icon, title, where it was and when, and Restore.
@MainActor final class ArchivedTabRow: NSView {
    var onRestore: (() -> Void)?
    let recordID: UUID
    init(record: ClosedRecord, favicon: NSImage?) {
        recordID = record.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = BamTheme.muted
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true; icon.layer?.cornerRadius = 3; icon.layer?.masksToBounds = true
        let titles = record.tabs.map { $0.title.isEmpty ? SidebarDisplayPolicy.readableAddress($0.address) : $0.title }
        let name = NSTextField(labelWithString: titles.joined(separator: "  +  "))
        name.font = BamType.sans(13.5, weight: .semibold); name.textColor = BamTheme.ink
        name.lineBreakMode = .byTruncatingTail
        let time = DateFormatter.localizedString(from: record.closedAt, dateStyle: .none, timeStyle: .short)
        let place = record.tabs.map { URL(string: $0.address)?.host ?? SidebarDisplayPolicy.readableAddress($0.address) }.joined(separator: " + ")
        var parts = [place, time]
        if record.split { parts.insert("Split", at: 0) }
        let detail = NSTextField(labelWithString: parts.joined(separator: " · "))
        detail.font = BamType.sans(12); detail.textColor = BamTheme.muted
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        let restore = BamPillButton(title: "Restore", symbol: "arrow.uturn.backward", compact: true)
        restore.target = self; restore.action = #selector(restoreNow)
        restore.setAccessibilityLabel("Restore \(titles.first ?? "tab")")
        var trailing: [NSView] = [restore]
        if record.wasAutoArchived {
            let badge = BamBadge("Archived")
            badge.toolTip = "Closed by auto-archive after it went unseen"
            trailing.insert(badge, at: 0)
        }
        let actions = NSStackView(views: trailing); actions.spacing = 10; actions.alignment = .centerY
        for view in [icon, text, actions] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            text.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(titles.joined(separator: " and ")), \(parts.joined(separator: ", "))\(record.wasAutoArchived ? ", archived automatically" : "")")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func restoreNow() { onRestore?() }
    /// Double-clicking a row restores it, like the history list.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRestore?() } else { super.mouseDown(with: event) }
    }
}
