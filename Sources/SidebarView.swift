import AppKit
import QuartzCore

struct SidebarTabItem: Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbol: String
    let isPinned: Bool
    let isActive: Bool
}

/// Native paging keeps the header and space dock fixed while both pages follow the fingers.
@MainActor final class SidebarView: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onPinTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onSearch: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onSpaceChange: ((Int) -> Void)?
    var onPictureInPicture: (() -> Void)?
    override var isFlipped: Bool { true }
    private let back = OrbitIconButton(symbol: "chevron.left", label: "Go back")
    private let forward = OrbitIconButton(symbol: "chevron.right", label: "Go forward")
    private let reload = OrbitIconButton(symbol: "arrow.clockwise", label: "Reload page")
    private let toggle = OrbitIconButton(symbol: "sidebar.left", label: "Hide sidebar")
    private let search = OrbitSearchButton()
    private let pip = OrbitIconButton(symbol: "pip", label: "Picture in Picture (⌥⌘P)")
    private let library = OrbitSpacesButton()
    private let plus = OrbitIconButton(symbol: "plus", label: "New tab")
    private let spaces = ["Studio", "Life", "Explore"].enumerated().map { OrbitSpaceButton(index: $0.offset, name: $0.element) }
    private let clip = OrbitFlippedView()
    private var page = SidebarPage()
    private var next: SidebarPage?
    private var pageDirection: CGFloat = 1
    private var offset: CGFloat = 0
    private var selectedSpace = 0
    private var items: [SidebarTabItem] = []
    var isPaging: Bool { next != nil }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityLabel("Orbit sidebar")
        clip.wantsLayer = true; clip.layer?.masksToBounds = true
        [toggle, back, forward, reload, search, clip, library, plus, pip].forEach(addSubview)
        spaces.forEach(addSubview); clip.addSubview(page); connect(page)
        back.handler = { [weak self] in self?.onBack?() }
        forward.handler = { [weak self] in self?.onForward?() }
        reload.handler = { [weak self] in self?.onReload?() }
        toggle.handler = { [weak self] in self?.onToggleSidebar?() }
        search.handler = { [weak self] in self?.onSearch?() }
        plus.handler = { [weak self] in self?.onNewTab?() }
        pip.handler = { [weak self] in self?.onPictureInPicture?() }
        library.handler = { [weak self] in self?.library.playSelection(); self?.onSpaceChange?(((self?.selectedSpace ?? 0) + 1) % 3) }
        for button in spaces { button.handler = { [weak self, weak button] in guard let button else { return }; self?.onSpaceChange?(button.index) } }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func connect(_ page: SidebarPage) {
        page.select = { [weak self] in self?.onSelectTab?($0) }
        page.close = { [weak self] in self?.onCloseTab?($0) }
        page.pin = { [weak self] in self?.onPinTab?($0) }
        page.newTab = { [weak self] in self?.onNewTab?() }
    }
    func update(tabs: [SidebarTabItem], space: Int, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        if items != tabs || selectedSpace != space { if selectedSpace != space { library.playSelection() }; items = tabs; selectedSpace = space; page.configure(tabs, space: space) }
        back.isEnabled = canGoBack; forward.isEnabled = canGoForward
        reload.setSymbol(isLoading ? "xmark" : "arrow.clockwise", label: isLoading ? "Stop loading" : "Reload page")
        for button in spaces { button.selected = button.index == space }
        needsLayout = true
    }
    func setAddress(_ address: String, title: String) { search.address = title; search.toolTip = address }
    func beginPaging(tabs: [SidebarTabItem], space: Int, direction: CGFloat) {
        if next != nil, pageDirection == direction { return }
        next?.removeFromSuperview()
        let incoming = SidebarPage(); connect(incoming); incoming.configure(tabs, space: space)
        clip.addSubview(incoming); next = incoming; pageDirection = direction
        layoutSubtreeIfNeeded(); setPagingOffset(offset)
    }
    func setPagingOffset(_ value: CGFloat) {
        offset = value
        page.frame = NSRect(x: value, y: 0, width: clip.bounds.width, height: clip.bounds.height)
        next?.frame = NSRect(x: value + clip.bounds.width * pageDirection, y: 0, width: clip.bounds.width, height: clip.bounds.height)
    }
    func endPaging() {
        next?.removeFromSuperview(); next = nil; offset = 0; setPagingOffset(0)
    }
    override func layout() {
        super.layout(); let w = bounds.width
        // Native traffic lights occupy the first 78 points of the top strip.
        toggle.frame = NSRect(x: 81, y: 10, width: 25, height: 25)
        let start = max(108, w - 88)
        for (i, button) in [back, forward, reload].enumerated() { button.frame = NSRect(x: start + CGFloat(i)*27, y: 10, width: 25, height: 25) }
        // At the recovered 164pt minimum, navigation moves into the address strip.
        let compact = w < 208
        forward.isHidden = compact; back.isHidden = compact
        if compact { reload.frame.origin.x = w - 33 }
        search.frame = NSRect(x: 8, y: 46, width: w-16, height: 34)
        clip.frame = NSRect(x: 0, y: 90, width: w, height: max(0, bounds.height-135))
        setPagingOffset(offset)
        let y = bounds.height-36
        library.frame = NSRect(x: 9, y: y, width: 28, height: 28)
        for (i, button) in spaces.enumerated() { button.frame = NSRect(x: (w-84)/2 + CGFloat(i)*28, y: y, width: 26, height: 28) }
        pip.frame = NSRect(x: w-62, y: y, width: 25, height: 28)
        plus.frame = NSRect(x: w-33, y: y, width: 25, height: 28)
        pip.isHidden = w < 220
    }
}

@MainActor private final class SidebarPage: OrbitFlippedView {
    var select: ((UUID)->Void)?; var close: ((UUID)->Void)?; var pin: ((UUID)->Void)?; var newTab: (()->Void)?
    let favorites = (0..<3).map { _ in OrbitFavoriteButton() }
    let heading = orbitLabel("◈  Studio", size: 12, weight: .semibold)
    let scroll = NSScrollView(); let content = OrbitFlippedView(); let newButton = OrbitNewTabButton()
    let divider = NSView()
    var rows: [OrbitTabRow] = []
    var tabs: [SidebarTabItem] = []
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        favorites.forEach(addSubview); addSubview(heading); addSubview(scroll)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = content; content.wantsLayer = true
        divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        content.addSubview(divider); content.addSubview(newButton)
        newButton.handler = { [weak self] in self?.newTab?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ items: [SidebarTabItem], space: Int) {
        tabs = items
        heading.stringValue = ["✦  Studio", "☀︎  Life", "◉  Explore"][space]
        let scrollOrigin = scroll.contentView.bounds.origin
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.item.id, $0) })
        let surviving = Set(items.map(\.id))
        rows.filter { !surviving.contains($0.item.id) }.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = existing[item.id] ?? OrbitTabRow(item: item)
            row.update(item)
            row.select = { [weak self] in self?.select?(item.id) }; row.close = { [weak self] in self?.close?(item.id) }; row.pin = { [weak self] in self?.pin?(item.id) }
            if row.superview == nil { content.addSubview(row) }; return row
        }
        for (i, button) in favorites.enumerated() {
            if i < items.count {
                let item = items[i]; button.configure(symbol: item.symbol, title: item.title, active: item.isActive, tint: OrbitPalette.spaceColors[space])
                button.handler = { [weak self] in self?.select?(item.id) }
            } else {
                button.configure(symbol: ["sparkles", "globe", "plus"][i], title: "New tab", active: false, tint: OrbitPalette.secondary)
                button.handler = { [weak self] in self?.newTab?() }
            }
        }
        needsLayout = true; layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: scrollOrigin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func layout() {
        super.layout(); let w = bounds.width; let tile = (w-30)/3
        for (i, button) in favorites.enumerated() { button.frame = NSRect(x: 8+CGFloat(i)*(tile+7), y: 0, width: tile, height: 47) }
        heading.frame = NSRect(x: 16, y: 66, width: w-32, height: 18)
        scroll.frame = NSRect(x: 7, y: 93, width: w-14, height: max(0,bounds.height-93))
        let rw = scroll.contentSize.width
        var y: CGFloat = 0
        for row in rows.filter({$0.item.isPinned}) { row.frame = NSRect(x: 0, y: y, width: rw, height: 33); y += 37 }
        divider.frame = NSRect(x: 9, y: y+8, width: max(0,rw-18), height: 0.5); y += 18
        newButton.frame = NSRect(x: 0, y: y, width: rw, height: 32); y += 36
        for row in rows.filter({!$0.item.isPinned}) { row.frame = NSRect(x: 0, y: y, width: rw, height: 33); y += 37 }
        content.frame = NSRect(x: 0, y: 0, width: rw, height: max(scroll.contentSize.height,y+8))
    }
}

@MainActor
private enum OrbitPalette {
    static let ink = NSColor(white: 0.94, alpha: 1)
    static let secondary = NSColor(white: 0.73, alpha: 1)
    static let spaceColors = [NSColor(calibratedRed: 0.80, green: 0.72, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.88, green: 0.75, blue: 0.60, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.81, blue: 0.86, alpha: 1)]
}

@MainActor
private func orbitLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = OrbitPalette.ink
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor
private class OrbitFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private class OrbitHoverButton: NSButton {
    var handler: (() -> Void)?
    var hovered = false
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        focusRingType = .exterior
        target = self
        action = #selector(performHandler)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill() }
    @objc private func performHandler() { handler?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func fill(_ color: NSColor, radius: CGFloat = 8) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).fill()
    }
    func symbol(_ name: String, rect: NSRect, color: NSColor, size: CGFloat = 14) {
        let recovered: String? = name == "sidebar.left" ? "Arc-icon-browser-navigation-sidebar" : (name == "arrow.clockwise" ? "Arc-icon-browser-navigation-reload" : nil)
        let source = recovered.flatMap { Bundle.main.url(forResource: $0, withExtension: "png", subdirectory: "Recovered") }.flatMap(NSImage.init(contentsOf:))
        guard let image = source ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium)) else { return }
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.32, respectFlipped: true, hints: nil)
    }
    func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? OrbitPalette.ink, .paragraphStyle: paragraph])
    }
}

@MainActor
private final class OrbitIconButton: OrbitHoverButton {
    private var symbolName: String
    init(symbol: String, label: String) {
        symbolName = symbol
        super.init(frame: .zero)
        toolTip = label
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSymbol(_ symbol: String, label: String) {
        symbolName = symbol
        toolTip = label
        setAccessibilityLabel(label)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if (hovered || isHighlighted) && isEnabled { fill(NSColor.white.withAlphaComponent(isHighlighted ? 0.20 : 0.10), radius: 7) }
        symbol(symbolName, rect: NSRect(x: (bounds.width - 13) / 2, y: (bounds.height - 13) / 2, width: 13, height: 13), color: OrbitPalette.ink, size: 13)
    }
}

@MainActor private final class OrbitSearchButton: OrbitHoverButton {
    var address = "Search or enter URL" { didSet { needsDisplay = true } }
    init() { super.init(frame: .zero); setAccessibilityLabel("Search or enter a web address"); toolTip = "Search or enter address (⌘L)" }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        fill(NSColor.black.withAlphaComponent(hovered ? 0.25 : 0.18), radius: 10)
        text(address, rect: NSRect(x: 12, y: 9, width: bounds.width-34, height: 18), size: 12, color: OrbitPalette.ink)
        symbol("ellipsis", rect: NSRect(x: bounds.width-23, y: 10, width: 13, height: 13), color: OrbitPalette.secondary, size: 12)
    }
}

@MainActor
private final class OrbitFavoriteButton: OrbitHoverButton {
    private var symbolName = "globe"
    private var caption = ""
    private var active = false
    private var tint = NSColor.systemPurple
    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(symbol: String, title: String, active: Bool, tint: NSColor) {
        symbolName = symbol
        caption = title
        self.active = active
        self.tint = tint
        setAccessibilityLabel(title)
        toolTip = title
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        fill(NSColor.white.withAlphaComponent(active ? 0.18 : hovered ? 0.14 : 0.08), radius: 9)
        symbol(symbolName, rect: NSRect(x: (bounds.width - 19) / 2, y: (bounds.height - 19) / 2, width: 19, height: 19), color: tint, size: 18)
    }
}

@MainActor
private final class OrbitNewTabButton: OrbitHoverButton {
    init() { super.init(frame: .zero); setAccessibilityLabel("New tab"); toolTip = "New tab (⌘T)" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(NSColor.white.withAlphaComponent(0.08)) }
        symbol("plus", rect: NSRect(x: 12, y: 10, width: 13, height: 13), color: OrbitPalette.secondary, size: 12)
        text("New Tab", rect: NSRect(x: 35, y: 9, width: max(0, bounds.width - 48), height: 18), size: 12, color: OrbitPalette.secondary)
    }
}

@MainActor
private final class OrbitSpaceButton: OrbitHoverButton {
    let index: Int
    private let name: String
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "Selected" : "Not selected") } }
    init(index: Int, name: String) {
        self.index = index
        self.name = name
        super.init(frame: .zero)
        setAccessibilityLabel("Switch to \(name) space")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered { fill(NSColor.white.withAlphaComponent(selected ? 0.14 : 0.07), radius: 7) }
        text(["✦", "☀︎", "◉"][index], rect: NSRect(x: 2, y: 4, width: bounds.width-4, height: 20), size: 16, color: selected ? OrbitPalette.ink : OrbitPalette.secondary, alignment: .center)
    }
}

@MainActor
private final class OrbitTabRow: OrbitFlippedView {
    private(set) var item: SidebarTabItem
    var select: (() -> Void)?
    var close: (() -> Void)?
    var pin: (() -> Void)?
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let iconView = NSImageView()
    private let closeButton = OrbitIconButton(symbol: "xmark", label: "Close tab")
    private var hovered = false
    private var area: NSTrackingArea?
    init(item: SidebarTabItem) {
        self.item = item
        titleLabel = orbitLabel(item.title.isEmpty ? "New Tab" : item.title, size: 12, weight: item.isActive ? .medium : .regular)
        subtitleLabel = orbitLabel(item.subtitle, size: 9, weight: .regular)
        super.init(frame: .zero)
        wantsLayer = true
        subtitleLabel.textColor = OrbitPalette.secondary.withAlphaComponent(0.84)
        iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        iconView.contentTintColor = item.isActive ? OrbitPalette.spaceColors[0] : OrbitPalette.secondary
        for view in [titleLabel, subtitleLabel, iconView, closeButton] as [NSView] { addSubview(view) }
        closeButton.isHidden = !item.isActive
        closeButton.handler = { [weak self] in self?.close?() }
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityValue(item.isActive ? "Selected" : "")
        toolTip = item.subtitle.isEmpty ? item.title : "\(item.title) — \(item.subtitle)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ newItem: SidebarTabItem) {
        item = newItem
        titleLabel.stringValue = item.title.isEmpty ? "New Tab" : item.title
        titleLabel.font = .systemFont(ofSize: 12, weight: item.isActive ? .medium : .regular)
        subtitleLabel.stringValue = item.subtitle
        iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        iconView.contentTintColor = item.isActive ? OrbitPalette.spaceColors[0] : OrbitPalette.secondary
        closeButton.isHidden = !hovered && !item.isActive
        setAccessibilityLabel(item.title); setAccessibilityValue(item.isActive ? "Selected" : "")
        toolTip = item.subtitle; needsDisplay = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { select?() } else { super.keyDown(with: event) }
    }
    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
        let textWidth = max(0, bounds.width - 68)
        let hasSubtitle = false
        titleLabel.frame = NSRect(x: 35, y: 8, width: textWidth, height: 17)
        subtitleLabel.frame = NSRect(x: 37, y: 23, width: textWidth, height: 12)
        subtitleLabel.isHidden = !hasSubtitle
        closeButton.frame = NSRect(x: bounds.width - 27, y: 6, width: 20, height: 20)
    }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8); ring.lineWidth = 2; ring.stroke()
        }
        if item.isActive || hovered {
            NSColor.white.withAlphaComponent(item.isActive ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).fill()
        }
        if item.isActive {
            NSColor.white.withAlphaComponent(0.05).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
            border.lineWidth = 0.5
            border.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; closeButton.isHidden = false; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; closeButton.isHidden = !item.isActive; needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Labels and symbols belong to the row's selection target; the close
        // button keeps its own native control hit target.
        return hit === closeButton ? closeButton : self
    }
    override func mouseDown(with event: NSEvent) { select?() }
    override func accessibilityPerformPress() -> Bool { select?(); return true }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let pinItem = NSMenuItem(title: item.isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(pinFromMenu), keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: item.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.target = self
        menu.addItem(pinItem)
        menu.addItem(.separator())
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeFromMenu), keyEquivalent: "")
        closeItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeItem.target = self
        menu.addItem(closeItem)
        return menu
    }
    @objc private func pinFromMenu() { pin?() }
    @objc private func closeFromMenu() { close?() }
}

@MainActor private final class OrbitSpacesButton: OrbitHoverButton {
    private static let frames: [NSImage?] = (0...35).map { frame in
        Bundle.main.url(forResource: String(format: "spaces-%03d", frame), withExtension: "png", subdirectory: "Recovered/spaces-dark").flatMap(NSImage.init(contentsOf:))
    }
    private var frameIndex = 0
    private var timer: Timer?
    init() { super.init(frame: .zero); toolTip = "Cycle spaces — two-finger swipe over sidebar"; setAccessibilityLabel("Cycle spaces") }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); play(from: 1, to: 11) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); play(from: frameIndex, to: 0) }
    func playSelection() { play(from: 11, to: 35) }
    private func play(from: Int, to: Int) {
        timer?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { frameIndex = 0; needsDisplay = true; return }
        frameIndex = from; needsDisplay = true
        let start = CACurrentMediaTime(); let step = to >= from ? 1 : -1
        let timer = Timer(timeInterval: 1/60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let n = min(abs(to-from), Int((CACurrentMediaTime()-start)*60))
                self.frameIndex = from+n*step; self.needsDisplay = true
                if self.frameIndex == to { timer.invalidate(); self.timer = nil }
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { fill(NSColor.white.withAlphaComponent(0.10), radius: 7) }
        guard let source = Self.frames[frameIndex], let image = source.copy() as? NSImage else { return }
        image.draw(in: bounds.insetBy(dx: 3, dy: 3), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    deinit { timer?.invalidate() }
}
