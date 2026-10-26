import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The actions every download surface offers, routed to the coordinator by id.
struct DownloadActions {
    var cancel: (UUID) -> Void = { _ in }
    var open: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
    var showAll: () -> Void = {}
}

/// File icons immediately, then real Quick Look thumbnails of finished files. A thumbnail
/// belongs to one download's own file: it is keyed by the download and the file identity
/// recorded when Bam saved it, and is shown only while the file at that path still has that
/// identity. A file deleted, moved or replaced (even by another download at the same path)
/// falls back to its type icon; a late thumbnail of an old file is stored only under the old key.
@MainActor final class DownloadThumbnails {
    var onUpdate: (() -> Void)?
    private var cache: [String: NSImage] = [:]
    private var requested: Set<String> = []

    func image(for item: DownloadSnapshot) -> NSImage {
        let typeIcon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data)
        guard item.status == .finished, let url = item.destinationURL, let saved = item.fileIdentity,
              DownloadFileIdentity.of(url) == saved else { return typeIcon }
        let key = Self.key(item.id, saved)
        if let thumbnail = cache[key] { return thumbnail }
        request(url, key: key, identity: saved)
        return typeIcon
    }

    static func key(_ id: UUID, _ identity: String) -> String { "\(id.uuidString)|\(identity)" }

    private func request(_ url: URL, key: String, identity: String) {
        guard requested.insert(key).inserted else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 180), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            DispatchQueue.main.async {
                // The file may have changed while Quick Look worked; keep the image only if it is still that file.
                guard let self, DownloadFileIdentity.of(url) == identity else { return }
                self.cache[key] = NSImage(cgImage: cgImage, size: .zero)
                self.onUpdate?()
            }
        }
    }
}

// MARK: - Compact list (anchored popover)

/// The compact surface that rises from the sidebar's Downloads button: recent and
/// unfinished downloads with live progress, Open on click, Show in Finder and Cancel.
@MainActor final class DownloadsPopoverController: NSViewController {
    private let actions: DownloadActions
    private let thumbnails: DownloadThumbnails
    private let list = NSStackView()
    private let empty = NSStackView()
    private let showAll = NSButton(title: "Show All", target: nil, action: nil)
    private var rows: [UUID: DownloadCompactRow] = [:]

    init(actions: DownloadActions, thumbnails: DownloadThumbnails) {
        self.actions = actions; self.thumbnails = thumbnails
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = DownloadSurfaceBackground(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let heading = NSTextField(labelWithString: "Downloads")
        heading.font = BamType.sans(13, weight: .bold); heading.textColor = BamTheme.ink
        heading.setAccessibilityRole(.staticText)
        showAll.isBordered = false
        showAll.target = self; showAll.action = #selector(showAllAction)
        showAll.setAccessibilityHelp("Opens every download with thumbnails")
        let header = NSStackView(views: [heading, NSView(), showAll])
        header.orientation = .horizontal
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 2
        let emptyTitle = NSTextField(labelWithString: DownloadPresentation.emptyTitle)
        emptyTitle.font = BamType.sans(13, weight: .semibold); emptyTitle.textColor = BamTheme.ink
        let emptyDetail = NSTextField(wrappingLabelWithString: DownloadPresentation.emptyDetail)
        emptyDetail.font = BamType.sans(12); emptyDetail.textColor = BamTheme.muted
        empty.orientation = .vertical; empty.alignment = .leading; empty.spacing = 3
        empty.addArrangedSubview(emptyTitle); empty.addArrangedSubview(emptyDetail)
        let column = NSStackView(views: [header, list, empty])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 320),
            header.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            list.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            emptyDetail.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24)
        ])
        view = root
        view.setAccessibilityLabel("Downloads")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.autorecalculatesKeyViewLoop = true
    }

    func update(_ items: [DownloadSnapshot], now: Date) {
        _ = view
        let compact = DownloadPresentation.compact(items)
        empty.isHidden = !items.isEmpty
        showAll.isHidden = items.isEmpty
        showAll.attributedTitle = NSAttributedString(string: DownloadPresentation.showAllTitle(more: compact.more), attributes: [
            .font: BamType.sans(12, weight: .semibold), .foregroundColor: BamTheme.red
        ])
        let ids = compact.shown.map(\.id)
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows.removeValue(forKey: id) }
        for (index, item) in compact.shown.enumerated() {
            let row = rows[item.id] ?? {
                let row = DownloadCompactRow(id: item.id, actions: actions)
                rows[item.id] = row
                return row
            }()
            if list.arrangedSubviews.firstIndex(of: row) != index {
                row.removeFromSuperview()
                list.insertArrangedSubview(row, at: min(index, list.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            row.update(DownloadPresentation.row(item, now: now), image: thumbnails.image(for: item))
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func showAllAction() { actions.showAll() }
}

/// One compact row: thumbnail, name, status, progress, and its actions.
/// Keyboard: Tab reaches it; Return or Space opens a finished file.
@MainActor private final class DownloadCompactRow: NSView {
    private let id: UUID
    private let actions: DownloadActions
    private let thumbnail = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancel = DownloadIconButton(symbol: "xmark.circle.fill", label: "Cancel download")
    private let reveal = DownloadIconButton(symbol: "magnifyingglass", label: "Show in Finder")
    private var presentation: DownloadRowPresentation?
    private var hovering = false { didSet { paint() } }

    init(id: UUID, actions: DownloadActions) {
        self.id = id; self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = 5; thumbnail.layer?.masksToBounds = true
        title.font = BamType.sans(13, weight: .semibold); title.textColor = BamTheme.ink; title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = BamType.sans(11.5); subtitle.lineBreakMode = .byTruncatingTail
        progress.style = .bar; progress.controlSize = .small; progress.minValue = 0; progress.maxValue = 1
        cancel.onPress = { [weak self] in guard let self else { return }; self.actions.cancel(self.id) }
        reveal.onPress = { [weak self] in guard let self else { return }; self.actions.reveal(self.id) }
        let text = NSStackView(views: [title, subtitle, progress])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let row = NSStackView(views: [thumbnail, text, cancel, reveal])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 34), thumbnail.heightAnchor.constraint(equalToConstant: 34),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ item: DownloadRowPresentation, image: NSImage) {
        presentation = item
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle
        subtitle.textColor = item.isProblem ? BamTheme.red : BamTheme.muted
        thumbnail.image = image
        progress.isHidden = !item.showsProgress
        if let fraction = item.fraction { progress.isIndeterminate = false; progress.doubleValue = fraction; progress.stopAnimation(nil) }
        else if item.showsProgress { progress.isIndeterminate = true; progress.startAnimation(nil) }
        cancel.isHidden = !item.canCancel
        reveal.isHidden = !item.canReveal
        setAccessibilityLabel(item.accessibilityLabel)
        setAccessibilityHelp(item.canOpen ? "Opens the file" : nil)
        toolTip = item.canOpen ? "Open \(item.title)" : nil
        paint()
    }

    private func paint() {
        let focused = window?.firstResponder === self
        layer?.backgroundColor = hovering || focused ? bamCG(BamTheme.redWash) : NSColor.clear.cgColor
        layer?.borderWidth = focused ? 1.5 : 0
        layer?.borderColor = bamCG(BamTheme.red)
    }
    private func open() { if presentation?.canOpen == true { actions.open(id) } }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
    }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { defer { paint() }; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { defer { paint() }; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { open() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { open(); return presentation?.canOpen == true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// A small borderless symbol button with an accessible name.
@MainActor private final class DownloadIconButton: NSButton {
    var onPress: (() -> Void)?
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = BamTheme.muted
        toolTip = label
        setAccessibilityLabel(label)
        target = self; action = #selector(press)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func press() { onPress?() }
}

/// Bam paper behind the popover, filling its arrow too.
@MainActor private final class DownloadSurfaceBackground: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; paint() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() { layer?.backgroundColor = bamCG(BamTheme.surface) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

// MARK: - Expanded library (thumbnail grid)

/// Every download as a thumbnail grid: click (or Return/Space) opens a finished file;
/// each tile's menu offers Open, Show in Finder and Cancel where they apply.
@MainActor final class DownloadsLibraryWindowController: NSWindowController, NSWindowDelegate {
    private let actions: DownloadActions
    private let thumbnails: DownloadThumbnails
    private let grid = DownloadGridView()
    private let emptyTitle = NSTextField(labelWithString: DownloadPresentation.emptyTitle)
    private let emptyDetail = NSTextField(wrappingLabelWithString: DownloadPresentation.emptyDetail)

    init(actions: DownloadActions, thumbnails: DownloadThumbnails) {
        self.actions = actions; self.thumbnails = thumbnails
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Downloads"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = window.contentView!
        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 0, dy: 0))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0)
        grid.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: 10)
        grid.autoresizingMask = [.width]
        scroll.documentView = grid
        root.addSubview(scroll)
        for label in [emptyTitle, emptyDetail] {
            label.alignment = .center; label.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(label)
        }
        emptyTitle.font = BamType.sans(15, weight: .semibold); emptyTitle.textColor = BamTheme.ink
        emptyDetail.font = BamType.sans(13); emptyDetail.textColor = BamTheme.muted
        NSLayoutConstraint.activate([
            emptyTitle.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyTitle.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -10),
            emptyDetail.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyDetail.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 6),
            emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        BamSheetStyle.dress(window: window, root: root)
        grid.actions = actions
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ items: [DownloadSnapshot], now: Date) {
        emptyTitle.isHidden = !items.isEmpty; emptyDetail.isHidden = !items.isEmpty
        grid.show(items.map { ($0.id, DownloadPresentation.row($0, now: now), thumbnails.image(for: $0)) })
    }

    func present(over parent: NSWindow?) {
        guard let window else { return }
        if let parent, parent.isVisible, !window.isVisible {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
        } else if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
}

/// A flowing grid of tiles; it lays out its own children so tiles reflow as the window resizes.
@MainActor private final class DownloadGridView: NSView {
    var actions = DownloadActions()
    private var tiles: [UUID: DownloadTile] = [:]
    private var order: [UUID] = []
    private let tileSize = NSSize(width: 168, height: 156)
    private let spacing: CGFloat = 14
    override var isFlipped: Bool { true }

    func show(_ items: [(UUID, DownloadRowPresentation, NSImage)]) {
        let ids = items.map(\.0)
        for (id, tile) in tiles where !ids.contains(id) { tile.removeFromSuperview(); tiles.removeValue(forKey: id) }
        for (id, item, image) in items {
            let tile = tiles[id] ?? {
                let tile = DownloadTile(id: id, actions: actions)
                tiles[id] = tile; addSubview(tile)
                return tile
            }()
            tile.update(item, image: image)
        }
        order = ids
        needsLayout = true
        window?.recalculateKeyViewLoop()
    }

    override func layout() {
        super.layout()
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        let columns = max(1, Int((width - spacing) / (tileSize.width + spacing)))
        let inset = max(spacing, (width - CGFloat(columns) * tileSize.width - CGFloat(columns - 1) * spacing) / 2)
        for (index, id) in order.enumerated() {
            let x = inset + CGFloat(index % columns) * (tileSize.width + spacing)
            let y = spacing + CGFloat(index / columns) * (tileSize.height + spacing)
            tiles[id]?.frame = NSRect(origin: NSPoint(x: x, y: y), size: tileSize)
        }
        let rows = (order.count + columns - 1) / columns
        let height = max(enclosingScrollView?.contentSize.height ?? 0, spacing + CGFloat(rows) * (tileSize.height + spacing))
        if frame.height != height || frame.width != width { setFrameSize(NSSize(width: width, height: height)) }
    }
}

/// One grid tile: a large thumbnail with the name and status beneath.
@MainActor private final class DownloadTile: NSView {
    private let id: UUID
    private let actions: DownloadActions
    private let thumbnail = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var presentation: DownloadRowPresentation?
    override var isFlipped: Bool { true }

    init(id: UUID, actions: DownloadActions) {
        self.id = id; self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = 8; thumbnail.layer?.masksToBounds = true
        title.font = BamType.sans(12.5, weight: .semibold); title.textColor = BamTheme.ink; title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = BamType.sans(11); subtitle.lineBreakMode = .byTruncatingTail
        progress.style = .bar; progress.controlSize = .small; progress.minValue = 0; progress.maxValue = 1
        [thumbnail, title, subtitle, progress].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        thumbnail.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 98)
        progress.frame = NSRect(x: 14, y: 92, width: bounds.width - 28, height: 8)
        title.frame = NSRect(x: 8, y: 112, width: bounds.width - 16, height: 17)
        subtitle.frame = NSRect(x: 8, y: 131, width: bounds.width - 16, height: 15)
    }

    func update(_ item: DownloadRowPresentation, image: NSImage) {
        presentation = item
        thumbnail.image = image
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle
        subtitle.textColor = item.isProblem ? BamTheme.red : BamTheme.muted
        progress.isHidden = !item.showsProgress
        if let fraction = item.fraction { progress.isIndeterminate = false; progress.doubleValue = fraction; progress.stopAnimation(nil) }
        else if item.showsProgress { progress.isIndeterminate = true; progress.startAnimation(nil) }
        setAccessibilityLabel(item.accessibilityLabel)
        setAccessibilityHelp(item.canOpen ? "Opens the file. More actions in its menu." : "More actions in its menu.")
        toolTip = item.title
        menu = contextMenu(for: item)
    }

    private func contextMenu(for item: DownloadRowPresentation) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ enabled: Bool, _ action: @escaping () -> Void) {
            let entry = DownloadMenuItem(title: title, run: action); entry.isEnabled = enabled; menu.addItem(entry)
        }
        menu.autoenablesItems = false
        let id = self.id, actions = self.actions
        add("Open", item.canOpen) { actions.open(id) }
        add("Show in Finder", item.canReveal) { actions.reveal(id) }
        if item.canCancel { menu.addItem(.separator()); add("Cancel Download", true) { actions.cancel(id) } }
        return menu
    }

    private func paint() {
        let focused = window?.firstResponder === self
        layer?.backgroundColor = bamCG(BamTheme.card)
        layer?.borderWidth = 1.5
        layer?.borderColor = bamCG(focused ? BamTheme.red : BamTheme.line)
    }
    private func open() { if presentation?.canOpen == true { actions.open(id) } }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { open() } }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { defer { paint() }; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { defer { paint() }; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { open() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { open(); return presentation?.canOpen == true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: bounds.height - 8), in: self)
        return true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// A menu item that runs a closure.
@MainActor private final class DownloadMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func runAction() { run() }
}
