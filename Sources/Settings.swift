import AppKit

enum SettingsSection: CaseIterable {
    case general, search, spaces, extensions, about
    var title: String {
        switch self {
        case .general: return "General"
        case .search: return "Search"
        case .spaces: return "Spaces"
        case .extensions: return "Extensions"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .search: return "magnifyingglass"
        case .spaces: return "square.stack.3d.up"
        case .extensions: return "puzzlepiece.extension"
        case .about: return "info.circle"
        }
    }
}

struct SettingsExtensionItem: Equatable {
    let name: String
    let version: String
    let enabled: Bool
}

/// Everything the window shows, read fresh from the browser each time it is
/// opened or an action lands, so it never drifts from menu toggles.
struct SettingsSnapshot {
    var showsPlayingVideo = true
    var sleepsIdlePages = true
    var keepAwakeHost: String? = nil
    var keepsCurrentSiteAwake = false
    var searchEngine: DefaultSearchEngine = .duckDuckGo
    var spaces: [BrowserSpace] = BrowserSpace.defaults
    var currentSpaceID = 0
    var profileName = "Default"
    var extensions: [SettingsExtensionItem] = []
    var version = "Development"
    var build = ""
    var accentIndex: Int { spaces.first { $0.id == currentSpaceID }?.colorIndex ?? 0 }
}

struct SettingsActions {
    var setShowsPlayingVideo: (Bool) -> Void = { _ in }
    var setSleepsIdlePages: (Bool) -> Void = { _ in }
    var setKeepsCurrentSiteAwake: (Bool) -> Void = { _ in }
    var setSearchEngine: (DefaultSearchEngine) -> Void = { _ in }
    var editSpace: (BrowserSpace) -> Bool = { _ in false }
    var manageSpaces: () -> Void = {}
    var manageExtensions: () -> Void = {}
    var showWelcome: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
}

/// ⌘W and Escape close Settings instead of reaching the browser's Close Tab.
@MainActor final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// Bam's settings: a floating Space-tinted window with a section rail and
/// stacked cards, built from the same ink and washes as onboarding.
@MainActor final class SettingsController: NSObject, NSWindowDelegate {
    static let githubURL = URL(string: "https://github.com/aridutilh/bam")!
    static let siteURL = URL(string: "https://bambrowser.com")!
    private let provider: () -> SettingsSnapshot
    private let actions: SettingsActions
    private(set) var snapshot: SettingsSnapshot
    private(set) var section: SettingsSection = .general
    let window: SettingsWindow
    private let backdrop = BamBackdropView(frame: .zero)
    private let rail = NSStackView()
    private var railButtons: [SettingsSection: SettingsRailButton] = [:]
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private var shownOnce = false
    private var accent: NSColor { ArkPalette.spaceColor(snapshot.accentIndex) }

    init(snapshot provider: @escaping () -> SettingsSnapshot, actions: SettingsActions) {
        self.provider = provider
        self.actions = actions
        self.snapshot = provider()
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.delegate = self
        window.setFrameAutosaveName("BamSettings")
        build()
    }

    private func build() {
        backdrop.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
        backdrop.autoresizingMask = [.width, .height]
        window.contentView = backdrop
        let heading = NSTextField(labelWithString: "Settings")
        heading.font = OnboardingText.serif(26, weight: .bold)
        heading.textColor = ArkPalette.ink
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 4
        rail.translatesAutoresizingMaskIntoConstraints = false
        heading.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(heading)
        backdrop.addSubview(rail)
        for section in SettingsSection.allCases {
            let button = SettingsRailButton(section: section)
            button.target = self; button.action = #selector(pickSection(_:))
            railButtons[section] = button
            rail.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
        }
        let divider = NSView(); divider.wantsLayer = true
        divider.layer?.backgroundColor = BamStyle.separator.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(divider)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedContainer()
        document.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        backdrop.addSubview(scroll)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 26),
            heading.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 48),
            rail.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            rail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            rail.widthAnchor.constraint(equalToConstant: 180),
            divider.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 212),
            divider.topAnchor.constraint(equalTo: backdrop.topAnchor),
            divider.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 48),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 36),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -36),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -40)
        ])
    }

    func show(section: SettingsSection, relativeTo parent: NSWindow?) {
        refresh()
        select(section)
        if !shownOnce {
            shownOnce = true
            if let parent, !window.setFrameUsingName("BamSettings") {
                window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                              y: parent.frame.midY - window.frame.height / 2))
            } else if parent == nil { window.center() }
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Re-reads the browser and rebuilds the visible section in place.
    func refresh() {
        snapshot = provider()
        backdrop.tint(colorIndex: snapshot.accentIndex)
        for (_, button) in railButtons { button.accent = accent }
        render()
    }
    func select(_ section: SettingsSection) {
        self.section = section
        for (key, button) in railButtons { button.isPicked = key == section }
        render()
        scroll.contentView.scroll(to: .zero)
    }
    @objc private func pickSection(_ sender: SettingsRailButton) { select(sender.section) }

    private func act(_ work: () -> Void) {
        work()
        refresh()
    }

    // MARK: Sections

    private func render() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let (title, subtitle): (String, String)
        switch section {
        case .general: (title, subtitle) = ("General", "How Bam behaves while you browse.")
        case .search: (title, subtitle) = ("Search", "Where typed words go when they aren’t an address.")
        case .spaces: (title, subtitle) = ("Spaces", "Name and color each part of your day.")
        case .extensions: (title, subtitle) = ("Extensions", "Local WebExtensions in the \(snapshot.profileName) profile.")
        case .about: (title, subtitle) = ("About", "Bam \(snapshot.version)")
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = OnboardingText.serif(30, weight: .bold)
        heading.textColor = ArkPalette.ink
        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = .systemFont(ofSize: 14); sub.textColor = ArkPalette.secondary; sub.isSelectable = false
        column.addArrangedSubview(heading)
        column.addArrangedSubview(sub)
        column.setCustomSpacing(4, after: heading)
        column.setCustomSpacing(22, after: sub)
        let cards: [NSView]
        switch section {
        case .general: cards = generalCards()
        case .search: cards = searchCards()
        case .spaces: cards = spacesCards()
        case .extensions: cards = extensionsCards()
        case .about: cards = aboutCards()
        }
        for card in cards {
            column.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = ArkPalette.secondary
        return label
    }
    private func toggle(_ on: Bool, enabled: Bool = true, _ change: @escaping (Bool) -> Void) -> BamToggle {
        let toggle = BamToggle(frame: .zero)
        toggle.accent = accent; toggle.isOn = on; toggle.isEnabled = enabled
        toggle.onChange = { [weak self] value in self?.act { change(value) } }
        return toggle
    }

    private func generalCards() -> [NSView] {
        let playback = BamCard(frame: .zero)
        playback.add(BamRow(title: "Automatically show playing videos",
                            detail: "Pop a page’s video into Picture in Picture when you leave its tab.",
                            control: toggle(snapshot.showsPlayingVideo, actions.setShowsPlayingVideo)))
        let memory = BamCard(frame: .zero)
        memory.add(BamRow(title: "Sleep idle pages under memory pressure",
                          detail: "Idle tabs unload when macOS runs low on memory, then reload on return.",
                          control: toggle(snapshot.sleepsIdlePages, actions.setSleepsIdlePages)))
        if let host = snapshot.keepAwakeHost {
            memory.add(BamRow(title: "Keep \(host) awake", detail: "Never sleep this site’s tabs.",
                              control: toggle(snapshot.keepsCurrentSiteAwake, actions.setKeepsCurrentSiteAwake)))
        } else {
            memory.add(BamRow(title: "Keep this site awake", detail: "Open a website to protect it from sleeping.",
                              control: toggle(false, enabled: false, { _ in }), enabled: false))
        }
        let keys = BamCard(frame: .zero)
        for (keycap, title) in [("⌘ T", "New tab or search"), ("⌘ L", "Open location"), ("⌘ S", "Toggle sidebar"),
                                ("⌥ ⌘ →", "Next Space"), ("⌘ D", "Keep or unkeep tab"), ("⌘ ,", "Settings")] {
            keys.add(BamRow(title: title, control: BamKeycap(keycap)))
        }
        return [caption("Playback"), playback, caption("Memory"), memory, caption("Keyboard"), keys]
    }

    private func searchCards() -> [NSView] {
        let card = BamCard(frame: .zero)
        let chips = NSStackView()
        chips.orientation = .horizontal; chips.spacing = 8
        for engine in DefaultSearchEngine.allCases {
            let dot = SiteSearchCatalog.engines.first { $0.host == engine.rawValue }?.color ?? accent
            let chip = BamChip(title: engine.name, dot: dot)
            chip.accent = accent
            chip.isPicked = engine == snapshot.searchEngine
            chip.setAccessibilityLabel("\(engine.name) default search engine")
            chip.target = self; chip.action = #selector(pickEngine(_:))
            chip.tag = DefaultSearchEngine.allCases.firstIndex(of: engine) ?? 0
            chips.addArrangedSubview(chip)
        }
        card.add(BamRow(title: "Default search engine", detail: "Also supplies suggestions as you type.", control: chips))
        let tip = BamCard(frame: .zero)
        tip.add(BamRow(title: "Search one site instead",
                       detail: "Type a site name in the palette — YouTube, Wikipedia, GitHub and more — and press Tab to search it directly.",
                       control: BamKeycap("⇥")))
        return [caption("Engine"), card, caption("Tip"), tip]
    }
    @objc private func pickEngine(_ sender: BamChip) {
        guard DefaultSearchEngine.allCases.indices.contains(sender.tag) else { return }
        let engine = DefaultSearchEngine.allCases[sender.tag]
        act { actions.setSearchEngine(engine) }
    }

    private func spacesCards() -> [NSView] {
        var cards: [NSView] = []
        for space in snapshot.spaces {
            let editor = SpaceEditorCard(space: space, isCurrent: space.id == snapshot.currentSpaceID, accent: accent)
            editor.onEdit = { [weak self] updated in
                guard let self else { return }
                if !self.actions.editSpace(updated) { NSSound.beep() }
                self.refresh()
            }
            cards.append(editor)
        }
        let manage = BamPillButton(title: "Manage Spaces…", symbol: "square.stack.3d.up")
        manage.target = self; manage.action = #selector(manageSpaces)
        let footer = BamCard(frame: .zero)
        footer.add(BamRow(title: "Reorder, add or remove Spaces", detail: "Login profiles live there too.", control: manage))
        return cards + [footer]
    }
    @objc private func manageSpaces() { actions.manageSpaces() }

    private func extensionsCards() -> [NSView] {
        let card = BamCard(frame: .zero)
        if snapshot.extensions.isEmpty {
            card.add(BamRow(title: "No extensions yet", detail: "Import an unpacked WebExtension folder to get started."))
        }
        for item in snapshot.extensions {
            let state = NSTextField(labelWithString: item.enabled ? "On" : "Off")
            state.font = .systemFont(ofSize: 12, weight: .semibold)
            state.textColor = item.enabled ? accent : ArkPalette.secondary
            card.add(BamRow(title: item.name, detail: "Version \(item.version)", control: state))
        }
        let manage = BamPillButton(title: "Manage Extensions…", symbol: "puzzlepiece.extension")
        manage.target = self; manage.action = #selector(manageExtensions)
        let footer = BamCard(frame: .zero)
        footer.add(BamRow(title: "Import, enable or remove", detail: "Chrome Web Store installs aren’t supported yet.", control: manage))
        return [caption(snapshot.profileName + " profile"), card, footer]
    }
    @objc private func manageExtensions() { actions.manageExtensions() }

    private func aboutCards() -> [NSView] {
        let hero = NSStackView()
        hero.orientation = .horizontal; hero.alignment = .centerY; hero.spacing = 18
        let icon = NSImageView()
        icon.image = Bundle.main.url(forResource: "BamIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true; icon.layer?.cornerRadius = 20; icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let words = NSStackView()
        words.orientation = .vertical; words.alignment = .leading; words.spacing = 4
        let name = NSTextField(labelWithString: "Bam")
        name.font = OnboardingText.serif(34, weight: .bold); name.textColor = ArkPalette.ink
        let version = NSTextField(labelWithString: snapshot.build.isEmpty ? "Version \(snapshot.version)" : "Version \(snapshot.version) · build \(snapshot.build)")
        version.font = .systemFont(ofSize: 13); version.textColor = ArkPalette.secondary
        let blurb = NSTextField(wrappingLabelWithString: "A native AppKit + WebKit browser. Not affiliated with The Browser Company.")
        blurb.font = .systemFont(ofSize: 12); blurb.textColor = ArkPalette.secondary; blurb.isSelectable = false
        words.addArrangedSubview(name); words.addArrangedSubview(version); words.addArrangedSubview(blurb)
        blurb.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        hero.addArrangedSubview(icon); hero.addArrangedSubview(words)
        hero.translatesAutoresizingMaskIntoConstraints = false
        let heroRow = NSView(); heroRow.translatesAutoresizingMaskIntoConstraints = false
        heroRow.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: heroRow.leadingAnchor, constant: 18),
            hero.trailingAnchor.constraint(equalTo: heroRow.trailingAnchor, constant: -18),
            hero.topAnchor.constraint(equalTo: heroRow.topAnchor, constant: 18),
            hero.bottomAnchor.constraint(equalTo: heroRow.bottomAnchor, constant: -18)
        ])
        let heroCard = BamCard(frame: .zero); heroCard.add(heroRow)
        let links = BamCard(frame: .zero)
        let welcome = BamPillButton(title: "Welcome to Bam…", symbol: "sparkles")
        welcome.target = self; welcome.action = #selector(showWelcome)
        links.add(BamRow(title: "Replay the welcome", detail: "Pick a color, name a Space, learn the keys.", control: welcome))
        let github = BamPillButton(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right")
        github.target = self; github.action = #selector(openGitHub)
        links.add(BamRow(title: "Source code", detail: "Bam is open source.", control: github))
        let site = BamPillButton(title: "bambrowser.com", symbol: "safari")
        site.target = self; site.action = #selector(openSite)
        links.add(BamRow(title: "Website", detail: "Releases and the changelog.", control: site))
        return [heroCard, links]
    }
    @objc private func showWelcome() { actions.showWelcome() }
    @objc private func openGitHub() { actions.openURL(Self.githubURL) }
    @objc private func openSite() { actions.openURL(Self.siteURL) }
}

/// One rail entry: symbol + title, filled when picked.
@MainActor final class SettingsRailButton: NSButton {
    let section: SettingsSection
    var accent: NSColor = ArkPalette.spaceColor(0) { didSet { paint() } }
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }
    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        alignment = .left
        imagePosition = .imageLeading
        layer?.cornerRadius = 9
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(section.title) settings")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        attributedTitle = NSAttributedString(string: "  " + section.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: isPicked ? .semibold : .medium),
            .foregroundColor: isPicked ? ArkPalette.ink : ArkPalette.secondary
        ])
        image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
        contentTintColor = isPicked ? accent : ArkPalette.secondary
        layer?.backgroundColor = (isPicked ? NSColor.white.withAlphaComponent(0.12) : NSColor.clear).cgColor
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.8 : 1 } }
}

/// A card editing one Space in place: name, color and icon. Each change
/// applies immediately; the browser retints behind the window.
@MainActor final class SpaceEditorCard: BamCard {
    var onEdit: ((BrowserSpace) -> Void)?
    private var space: BrowserSpace
    private let accent: NSColor
    private var swatches: [SettingsSwatch] = []
    private var glyphs: [SettingsGlyph] = []
    private let field: BamTextField
    private let preview = NSImageView()

    init(space: BrowserSpace, isCurrent: Bool, accent: NSColor) {
        self.space = space
        self.accent = accent
        field = BamTextField(string: space.name, placeholder: "Space name")
        super.init(frame: .zero)
        showsSeparators = false
        let header = NSStackView()
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12
        preview.imageScaling = .scaleProportionallyDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 10
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 36).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 36).isActive = true
        field.setAccessibilityLabel("\(space.name) Space name")
        field.onCommit = { [weak self] name in
            guard let self, let valid = BrowserSpace.validName(name) else { NSSound.beep(); self?.field.stringValue = self?.space.name ?? ""; return }
            self.space.name = valid; self.onEdit?(self.space)
        }
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        header.addArrangedSubview(preview)
        header.addArrangedSubview(field)
        if isCurrent {
            let tag = NSTextField(labelWithString: "Current")
            tag.font = .systemFont(ofSize: 11, weight: .semibold)
            tag.textColor = accent
            header.addArrangedSubview(tag)
        }
        add(pad(header, top: 16, bottom: 6))
        let colors = NSStackView(); colors.orientation = .horizontal; colors.spacing = 8
        for index in 0..<BrowserSpace.colorNames.count {
            let swatch = SettingsSwatch(colorIndex: index)
            swatch.isPicked = index == space.colorIndex
            swatch.target = self; swatch.action = #selector(pickColor(_:))
            swatches.append(swatch); colors.addArrangedSubview(swatch)
        }
        let glyphRow = NSStackView(); glyphRow.orientation = .horizontal; glyphRow.spacing = 6
        for symbol in BrowserSpace.symbols {
            let glyph = SettingsGlyph(symbol: symbol)
            glyph.isPicked = symbol == space.symbol
            glyph.target = self; glyph.action = #selector(pickGlyph(_:))
            glyphs.append(glyph); glyphRow.addArrangedSubview(glyph)
        }
        add(pad(colors, top: 6, bottom: 6))
        add(pad(glyphRow, top: 6, bottom: 16))
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func pad(_ view: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
        let host = NSView(); host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -bottom)
        ])
        return host
    }
    private func updatePreview() {
        preview.image = SidebarSymbol.image(named: space.symbol, color: NSColor(white: 0.08, alpha: 1), pointSize: 17)
            ?? NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
        preview.layer?.backgroundColor = ArkPalette.spaceColor(space.colorIndex).cgColor
    }
    @objc private func pickColor(_ sender: SettingsSwatch) {
        guard sender.colorIndex != space.colorIndex else { return }
        space.colorIndex = sender.colorIndex
        for swatch in swatches { swatch.isPicked = swatch.colorIndex == space.colorIndex }
        updatePreview(); onEdit?(space)
    }
    @objc private func pickGlyph(_ sender: SettingsGlyph) {
        guard sender.symbol != space.symbol else { return }
        space.symbol = sender.symbol
        for glyph in glyphs { glyph.isPicked = glyph.symbol == space.symbol }
        updatePreview(); onEdit?(space)
    }
}

@MainActor final class SettingsSwatch: NSButton {
    let colorIndex: Int
    private let ring = CALayer()
    var isPicked = false { didSet { ring.borderWidth = isPicked ? 2 : 0; setAccessibilityValue(isPicked ? "Selected" : "") } }
    init(colorIndex: Int) {
        self.colorIndex = colorIndex
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        if colorIndex == BrowserSpace.prismColorIndex {
            let rainbow = CAGradientLayer()
            rainbow.colors = (0..<6).map { NSColor(calibratedHue: CGFloat($0) / 6, saturation: 0.55, brightness: 0.88, alpha: 1).cgColor }
            rainbow.startPoint = CGPoint(x: 0, y: 1); rainbow.endPoint = CGPoint(x: 1, y: 0)
            rainbow.frame = NSRect(x: 0, y: 0, width: 26, height: 26); rainbow.cornerRadius = 13
            layer?.insertSublayer(rainbow, at: 0)
        } else if colorIndex == BrowserSpace.clearColorIndex {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
            layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        } else {
            layer?.backgroundColor = ArkPalette.spaceColor(colorIndex).cgColor
        }
        layer?.cornerRadius = 13
        ring.borderColor = NSColor.white.cgColor
        ring.cornerRadius = 16
        ring.frame = NSRect(x: -3, y: -3, width: 32, height: 32)
        layer?.addSublayer(ring)
        layer?.masksToBounds = false
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, colorIndex)]) color")
        toolTip = BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, colorIndex)]
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -3, dy: -3) }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: -3, dy: -3)).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class SettingsGlyph: NSButton {
    let symbol: String
    var isPicked = false {
        didSet { layer?.backgroundColor = NSColor.white.withAlphaComponent(isPicked ? 0.22 : 0.07).cgColor; setAccessibilityValue(isPicked ? "Selected" : "") }
    }
    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        image = SidebarSymbol.image(named: symbol, color: ArkPalette.ink, pointSize: 13)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(symbol) icon")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
