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
    /// Read from the preference itself, so it is right however the snapshot is built.
    var asksBeforeQuitting = QuitConfirmationPreference().asksBeforeQuitting
    var searchEngine: DefaultSearchEngine = .duckDuckGo
    var appearance: BrowserAppearance = .system
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
    var setKeepsSiteAwake: (String, Bool) -> Void = { _, _ in }
    var setAsksBeforeQuitting: (Bool) -> Void = { QuitConfirmationPreference().asksBeforeQuitting = $0 }
    var setSearchEngine: (DefaultSearchEngine) -> Void = { _ in }
    var editSpace: (BrowserSpace) -> Bool = { _ in false }
    var switchSpace: (Int) -> Void = { _ in }
    var manageSpaces: () -> Void = {}
    var manageExtensions: () -> Void = {}
    var showWelcome: () -> Void = {}
    var importFromArc: () -> Void = {}
    var setAppearance: (BrowserAppearance) -> Void = { _ in }
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

/// Bam's settings: a window on bambrowser.com's paper with a section rail
/// and stacked cards, following the system appearance like the site does.
@MainActor final class SettingsController: NSObject, NSWindowDelegate {
    static let githubURL = URL(string: "https://github.com/aridutilh/bam")!
    static let siteURL = URL(string: "https://bambrowser.com")!
    private let provider: () -> SettingsSnapshot
    private let actions: SettingsActions
    private(set) var snapshot: SettingsSnapshot
    private(set) var section: SettingsSection = .general
    let window: SettingsWindow
    private let paper = BamSurfaceView(frame: .zero)
    private let rail = NSStackView()
    private var railButtons: [SettingsSection: SettingsRailButton] = [:]
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private var shownOnce = false
    private var renderQueued = false
    private var accent: NSColor { BamTheme.red }

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
        window.appearance = nil
        window.backgroundColor = BamTheme.bg
        window.delegate = self
        window.setFrameAutosaveName("BamSettings")
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: ShortcutStore.didChange, object: nil)
    }

    private func build() {
        paper.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
        paper.autoresizingMask = [.width, .height]
        window.contentView = paper
        // The site header: icon tile, then the wordmark.
        let heading = NSStackView()
        heading.orientation = .horizontal; heading.alignment = .centerY; heading.spacing = 10
        let icon = NSImageView()
        icon.image = Self.appIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true; icon.layer?.cornerRadius = 8; icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let word = NSTextField(labelWithString: "Settings")
        word.font = BamType.display(24, weight: .heavy)
        word.textColor = BamTheme.ink
        heading.addArrangedSubview(icon); heading.addArrangedSubview(word)
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 4
        rail.translatesAutoresizingMaskIntoConstraints = false
        heading.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(heading)
        paper.addSubview(rail)
        for section in SettingsSection.allCases {
            let button = SettingsRailButton(section: section)
            button.target = self; button.action = #selector(pickSection(_:))
            railButtons[section] = button
            rail.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
        }
        let divider = BamHairline()
        paper.addSubview(divider)
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
        paper.addSubview(scroll)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 22),
            heading.topAnchor.constraint(equalTo: paper.topAnchor, constant: 46),
            rail.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 16),
            rail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            rail.widthAnchor.constraint(equalToConstant: 184),
            divider.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 216),
            divider.topAnchor.constraint(equalTo: paper.topAnchor),
            divider.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: paper.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 48),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 36),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -40),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -44)
        ])
    }
    static var appIcon: NSImage {
        let bundled = Bundle.main.url(forResource: "BamIcon", withExtension: "png")
        let override = ProcessInfo.processInfo.environment["BAM_RESOURCES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("BamIcon.png") }
        return (bundled ?? override).flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
    }

    func show(section: SettingsSection, relativeTo parent: NSWindow?) {
        reload()
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

    /// Re-reads the browser and rebuilds the visible section on the next
    /// run-loop turn, so a change that arrives from inside a control's own
    /// callback never tears that control down mid-call. Rebuilds coalesce.
    func refresh() {
        reload()
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderQueued = false
            self.render()
        }
    }
    private func reload() {
        snapshot = provider()
    }
    func select(_ section: SettingsSection) {
        self.section = section
        for (key, button) in railButtons { button.isPicked = key == section }
        render()
        scroll.contentView.scroll(to: .zero)
    }
    @objc private func pickSection(_ sender: SettingsRailButton) { select(sender.section) }

    /// A toggle or chip already shows its new state; only the snapshot moves,
    /// so keyboard focus stays on the control that was just used.
    private func act(_ work: () -> Void) {
        work()
        reload()
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
        heading.font = BamType.display(34, weight: .heavy)
        heading.textColor = BamTheme.ink
        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = BamType.sans(15); sub.textColor = BamTheme.muted; sub.isSelectable = false
        column.addArrangedSubview(heading)
        column.addArrangedSubview(sub)
        column.setCustomSpacing(2, after: heading)
        column.setCustomSpacing(26, after: sub)
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
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: BamType.sans(12, weight: .bold), .foregroundColor: BamTheme.muted, .kern: 0.8
        ])
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
            let keep = actions.setKeepsSiteAwake
            memory.add(BamRow(title: "Keep \(host) awake", detail: "Never sleep this site’s tabs.",
                              control: toggle(snapshot.keepsCurrentSiteAwake, { keep(host, $0) })))
        } else {
            memory.add(BamRow(title: "Keep this site awake", detail: "Open a website to protect it from sleeping.",
                              control: toggle(false, enabled: false, { _ in }), enabled: false))
        }
        let keys = BamCard(frame: .zero)
        for command in ShortcutCommand.allCases {
            keys.add(BamRow(title: command.title, control: BamShortcutRecorder(command: command)))
        }
        let reset = BamPillButton(title: "Reset all", symbol: "arrow.counterclockwise")
        reset.target = self; reset.action = #selector(resetShortcuts)
        reset.isEnabled = ShortcutStore.shared.anyCustom
        resetPill = reset
        keys.add(BamRow(title: "Click a key to change it",
                        detail: "Then press the new shortcut. Escape keeps the old one, Delete restores the default.",
                        control: reset))
        let bring = BamCard(frame: .zero)
        let arc = BamPillButton(title: "Import from Arc…", symbol: "square.and.arrow.down")
        arc.target = self; arc.action = #selector(importFromArc)
        bring.add(BamRow(title: "Bring in your Arc sidebar",
                         detail: "Spaces, folders, kept tabs, Today tabs and Favorites from Arc’s layout file. Pages stay asleep until you open them.",
                         control: arc))
        let look = BamCard(frame: .zero)
        let choices = NSStackView(); choices.orientation = .horizontal; choices.spacing = 8
        appearanceChips = choices
        for (index, choice) in BrowserAppearance.allCases.enumerated() {
            let chip = BamChip(title: choice.title)
            chip.accent = accent; chip.isPicked = choice == snapshot.appearance; chip.tag = index
            chip.setAccessibilityLabel("\(choice.title) appearance")
            chip.target = self; chip.action = #selector(pickAppearance(_:))
            choices.addArrangedSubview(chip)
        }
        look.add(BamRow(title: "Appearance", detail: "Light or dark browser chrome. System follows macOS; Space colors carry over in both.", control: choices))
        let quitting = BamCard(frame: .zero)
        quitting.add(BamRow(title: "Ask before quitting",
                            detail: "Confirm before Bam closes its windows. Turn this back on after choosing “don’t ask again”.",
                            control: toggle(snapshot.asksBeforeQuitting, actions.setAsksBeforeQuitting)))
        return [caption("Look"), look, caption("Import"), bring, caption("Playback"), playback, caption("Memory"), memory,
                caption("Quitting"), quitting, caption("Keyboard"), keys]
    }
    private weak var appearanceChips: NSStackView?
    /// An appearance change (from here, the View menu or a relaunch) updates
    /// the chips in place. Rebuilding the section would drop keyboard focus.
    func syncAppearance() {
        reload()
        for case let chip as BamChip in appearanceChips?.arrangedSubviews ?? [] {
            chip.isPicked = BrowserAppearance.allCases.indices.contains(chip.tag) && BrowserAppearance.allCases[chip.tag] == snapshot.appearance
        }
    }
    @objc private func pickAppearance(_ sender: BamChip) {
        guard BrowserAppearance.allCases.indices.contains(sender.tag) else { return }
        act { actions.setAppearance(BrowserAppearance.allCases[sender.tag]) }
        for case let chip as BamChip in appearanceChips?.arrangedSubviews ?? [] { chip.isPicked = chip === sender }
    }
    @objc private func importFromArc() {
        window.orderOut(nil)
        actions.importFromArc()
    }
    private weak var resetPill: BamPillButton?
    @objc private func resetShortcuts() { ShortcutStore.shared.resetAll() }
    /// The recorders repaint themselves; only the reset pill needs a nudge.
    @objc private func shortcutsChanged() { resetPill?.isEnabled = ShortcutStore.shared.anyCustom }

    private func searchCards() -> [NSView] {
        let card = BamCard(frame: .zero)
        let chips = NSStackView()
        engineChips = chips
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
        card.add(BamRow(title: "Default search engine", detail: "Where plain words go. Suggestions come from it when it offers them.", control: chips))
        let tip = BamCard(frame: .zero)
        tip.isDashed = true
        tip.add(BamRow(title: "Search one site instead",
                       detail: "Type a site name in the palette — YouTube, Wikipedia, GitHub and more — and press Tab to search it directly.",
                       control: BamKeycap("⇥")))
        return [caption("Engine"), card, caption("Tip"), tip]
    }
    private weak var engineChips: NSStackView?
    @objc private func pickEngine(_ sender: BamChip) {
        guard DefaultSearchEngine.allCases.indices.contains(sender.tag) else { return }
        let engine = DefaultSearchEngine.allCases[sender.tag]
        act { actions.setSearchEngine(engine) }
        for case let chip as BamChip in engineChips?.arrangedSubviews ?? [] { chip.isPicked = chip === sender }
    }

    /// The Space the editor shows; the list on top picks it. Survives refreshes.
    private var editingSpaceID: Int?

    private func spacesCards() -> [NSView] {
        let spaces = snapshot.spaces
        let editing = spaces.first { $0.id == editingSpaceID } ?? spaces.first { $0.id == snapshot.currentSpaceID } ?? spaces.first
        editingSpaceID = editing?.id
        let list = BamCard(frame: .zero)
        list.showsSeparators = false
        let rows = NSStackView(); rows.orientation = .vertical; rows.spacing = 2; rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        for space in spaces {
            let row = SpaceListRow(space: space, isCurrent: space.id == snapshot.currentSpaceID)
            row.isPicked = space.id == editing?.id
            row.target = self; row.action = #selector(pickSpace(_:))
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let host = NSView(); host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8)
        ])
        list.add(host)
        var cards: [NSView] = [caption("Your Spaces"), list]
        if let editing {
            let editor = SpaceEditorCard(space: editing, isCurrent: editing.id == snapshot.currentSpaceID)
            // A successful edit reaches the app's onSpacesChanged, which refreshes
            // this window; a rejected one leaves the card as it was.
            editor.onEdit = { [weak self] updated in
                guard let self else { return false }
                let applied = self.actions.editSpace(updated)
                if !applied { NSSound.beep() }
                return applied
            }
            editor.onSwitch = { [weak self] id in
                guard let self else { return }
                self.act { self.actions.switchSpace(id) }
                self.refresh()
            }
            cards += [caption("Edit \(editing.name)"), editor]
        }
        let manage = BamPillButton(title: "Manage Spaces", symbol: "square.stack.3d.up")
        manage.target = self; manage.action = #selector(manageSpaces)
        let footer = BamCard(frame: .zero)
        footer.add(BamRow(title: "Reorder, add or remove Spaces", detail: "Login profiles live there too.", control: manage))
        return cards + [footer]
    }
    /// Rebuilds on the next turn, like refresh(), so the clicked row is not
    /// torn down inside its own action; the scroll position stays put.
    @objc private func pickSpace(_ sender: SpaceListRow) {
        guard editingSpaceID != sender.spaceID else { return }
        editingSpaceID = sender.spaceID
        let offset = scroll.contentView.bounds.origin
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.render()
            self.scroll.contentView.scroll(to: offset)
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
    }
    @objc private func manageSpaces() { actions.manageSpaces() }

    private func extensionsCards() -> [NSView] {
        let card = BamCard(frame: .zero)
        if snapshot.extensions.isEmpty {
            card.add(BamRow(title: "No extensions yet", detail: "Import an unpacked WebExtension folder to get started."))
        }
        for item in snapshot.extensions {
            let state: NSView
            if item.enabled { state = BamBadge("On") } else {
                let off = NSTextField(labelWithString: "Off")
                off.font = BamType.sans(12, weight: .semibold); off.textColor = BamTheme.muted
                state = off
            }
            card.add(BamRow(title: item.name, detail: "Version \(item.version)", control: state))
        }
        let manage = BamPillButton(title: "Manage Extensions…", symbol: "puzzlepiece.extension")
        manage.target = self; manage.action = #selector(manageExtensions)
        let footer = BamCard(frame: .zero)
        footer.add(BamRow(title: "Add, enable or remove", detail: "Store links, Firefox Add-ons search, package links and local folders.", control: manage))
        return [caption(snapshot.profileName + " profile"), card, footer]
    }
    @objc private func manageExtensions() { actions.manageExtensions() }

    private func aboutCards() -> [NSView] {
        let hero = NSStackView()
        hero.orientation = .horizontal; hero.alignment = .centerY; hero.spacing = 18
        let icon = NSImageView()
        icon.image = Self.appIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true; icon.layer?.cornerRadius = 20; icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let words = NSStackView()
        words.orientation = .vertical; words.alignment = .leading; words.spacing = 4
        let name = NSTextField(labelWithString: "The browser that goes Bam.")
        name.font = BamType.display(28, weight: .heavy); name.textColor = BamTheme.ink
        let version = NSTextField(labelWithString: snapshot.build.isEmpty ? "Version \(snapshot.version)" : "Version \(snapshot.version) · build \(snapshot.build)")
        version.font = BamType.sans(13.5, weight: .medium); version.textColor = BamTheme.muted
        let blurb = NSTextField(wrappingLabelWithString: "Native, fast, built in Swift on your Mac’s own WebKit. Free, no account. Not affiliated with The Browser Company.")
        blurb.font = BamType.sans(13); blurb.textColor = BamTheme.muted; blurb.isSelectable = false
        words.addArrangedSubview(name); words.addArrangedSubview(version); words.addArrangedSubview(blurb)
        words.setCustomSpacing(10, after: version)
        blurb.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        hero.addArrangedSubview(icon); hero.addArrangedSubview(words)
        hero.translatesAutoresizingMaskIntoConstraints = false
        // The changelog's version sticker; its label carries the site's tilt.
        let sticker = BamSticker(snapshot.version.split(separator: ".").prefix(2).joined(separator: "."), diameter: 84)
        let heroRow = NSView(); heroRow.translatesAutoresizingMaskIntoConstraints = false
        heroRow.addSubview(hero); heroRow.addSubview(sticker)
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: heroRow.leadingAnchor, constant: 20),
            hero.trailingAnchor.constraint(equalTo: sticker.leadingAnchor, constant: -16),
            hero.topAnchor.constraint(equalTo: heroRow.topAnchor, constant: 22),
            hero.bottomAnchor.constraint(equalTo: heroRow.bottomAnchor, constant: -22),
            sticker.trailingAnchor.constraint(equalTo: heroRow.trailingAnchor, constant: -22),
            sticker.centerYAnchor.constraint(equalTo: heroRow.centerYAnchor)
        ])
        let heroCard = BamCard(frame: .zero); heroCard.add(heroRow)
        let links = BamCard(frame: .zero)
        let welcome = BamPillButton(title: "Welcome to Bam", symbol: "sparkles")
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

/// One rail entry: symbol + title; the picked one sits on a paper card.
/// A rail entry: symbol and title laid out by hand, inset from the pill so
/// nothing touches its edge when it is picked.
@MainActor final class SettingsRailButton: NSButton {
    let section: SettingsSection
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var accent: NSColor = BamTheme.red { didSet { paint() } }
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }
    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)
        title = ""; isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 11
        icon.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.imageScaling = .scaleNone
        label.stringValue = section.title
        label.lineBreakMode = .byTruncatingTail
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(section.title) settings")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        label.font = BamType.sans(14.5, weight: isPicked ? .bold : .medium)
        label.textColor = isPicked ? BamTheme.ink : BamTheme.muted
        icon.contentTintColor = isPicked ? accent : BamTheme.muted
        layer?.backgroundColor = bamCG(isPicked ? BamTheme.card : NSColor.clear)
        layer?.borderWidth = isPicked ? 1.5 : 0
        layer?.borderColor = bamCG(BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.8 : 1 } }
}

/// One line per Space: its tile, its name and whether it is the one on screen.
/// Clicking it hands the Space to the editor below.
@MainActor final class SpaceListRow: NSButton {
    let spaceID: Int
    private let tile = SpaceTile(size: 32, pointSize: 15)
    private let name = NSTextField(labelWithString: "")
    private let badge = BamBadge("Current")
    private let chevron = NSImageView()
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }

    init(space: BrowserSpace, isCurrent: Bool) {
        spaceID = space.id
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 12
        tile.show(space)
        name.stringValue = space.name
        name.font = BamType.sans(15, weight: .semibold)
        name.textColor = BamTheme.ink
        name.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        chevron.contentTintColor = BamTheme.muted
        badge.isHidden = !isCurrent
        for view in [tile, name, badge, chevron] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -12),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(space.name) Space\(isCurrent ? ", current" : "")")
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        layer?.backgroundColor = bamCG(isPicked ? BamTheme.redWash : .clear)
        chevron.contentTintColor = isPicked ? BamTheme.red : BamTheme.muted
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.75 : 1 } }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A Space's colour square with its glyph, the way the sidebar draws it.
@MainActor final class SpaceTile: NSView {
    private let glyph = NSImageView()
    private let pointSize: CGFloat
    private var space: BrowserSpace?
    init(size: CGFloat, pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size * 0.28
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor), glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ space: BrowserSpace) { self.space = space; paint() }
    private func paint() {
        guard let space else { return }
        let clear = space.colorIndex == BrowserSpace.clearColorIndex
        let fill = clear ? BamTheme.card : ArkPalette.spaceColor(space.colorIndex)
        let ink = clear ? BamTheme.ink : NSColor(white: 0.08, alpha: 1)
        var resolvedInk = ink
        effectiveAppearance.performAsCurrentDrawingAppearance { resolvedInk = NSColor(cgColor: ink.cgColor) ?? ink }
        layer?.backgroundColor = bamCG(fill)
        layer?.borderWidth = clear ? 1.5 : 0
        layer?.borderColor = bamCG(BamTheme.line)
        glyph.image = SidebarSymbol.image(named: space.symbol, color: resolvedInk, pointSize: pointSize)
            ?? NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// Edits one Space: name, then colour, then icon, each on its own labelled row.
@MainActor final class SpaceEditorCard: BamCard {
    var onEdit: ((BrowserSpace) -> Bool)?
    var onSwitch: ((Int) -> Void)?
    private var space: BrowserSpace
    private var swatches: [SettingsSwatch] = []
    private var glyphs: [SettingsGlyph] = []
    private let field: BamTextField
    private let tile = SpaceTile(size: 44, pointSize: 20)
    private let colorName = NSTextField(labelWithString: "")

    init(space: BrowserSpace, isCurrent: Bool) {
        self.space = space
        field = BamTextField(string: space.name, placeholder: "Space name")
        super.init(frame: .zero)
        let header = NSStackView()
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 14
        field.setAccessibilityLabel("\(space.name) Space name")
        field.onCommit = { [weak self] name in
            guard let self, let valid = BrowserSpace.validName(name) else { NSSound.beep(); return false }
            var proposed = self.space; proposed.name = valid
            guard self.onEdit?(proposed) == true else { return false }
            self.space = proposed
            return true
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(tile)
        header.addArrangedSubview(field)
        if isCurrent {
            header.addArrangedSubview(BamBadge("Current"))
        } else {
            let go = BamPillButton(title: "Switch to it", symbol: "arrow.right")
            go.target = self; go.action = #selector(switchSpace)
            header.addArrangedSubview(go)
        }
        add(pad(header, top: 16, bottom: 16, stretch: true))

        let colors = NSStackView(); colors.orientation = .horizontal; colors.spacing = 10; colors.alignment = .centerY
        for index in 0..<BrowserSpace.colorNames.count {
            let swatch = SettingsSwatch(colorIndex: index)
            swatch.isPicked = index == space.colorIndex
            swatch.target = self; swatch.action = #selector(pickColor(_:))
            swatches.append(swatch); colors.addArrangedSubview(swatch)
        }
        colorName.font = BamType.sans(13); colorName.textColor = BamTheme.muted
        colors.setCustomSpacing(16, after: colors.arrangedSubviews.last!)
        colors.addArrangedSubview(colorName)
        add(labelled("Color", colors))

        let glyphRow = NSStackView(); glyphRow.orientation = .horizontal; glyphRow.spacing = 6
        for symbol in BrowserSpace.symbols {
            let glyph = SettingsGlyph(symbol: symbol)
            glyph.isPicked = symbol == space.symbol
            glyph.target = self; glyph.action = #selector(pickGlyph(_:))
            glyphs.append(glyph); glyphRow.addArrangedSubview(glyph)
        }
        add(labelled("Icon", glyphRow))
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func pad(_ view: NSView, top: CGFloat, bottom: CGFloat, stretch: Bool = false) -> NSView {
        let host = NSView(); host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            stretch ? view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20)
                    : view.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -20),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -bottom)
        ])
        return host
    }
    /// A small caption over a row of choices, like the site's form labels.
    private func labelled(_ text: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: BamType.sans(11, weight: .bold), .foregroundColor: BamTheme.muted, .kern: 0.8])
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.addArrangedSubview(label); stack.addArrangedSubview(view)
        return pad(stack, top: 14, bottom: 16)
    }
    private func updatePreview() {
        tile.show(space)
        colorName.stringValue = BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, space.colorIndex)]
    }
    @objc private func switchSpace() { onSwitch?(space.id) }
    @objc private func pickColor(_ sender: SettingsSwatch) {
        guard sender.colorIndex != space.colorIndex else { return }
        var proposed = space; proposed.colorIndex = sender.colorIndex
        guard onEdit?(proposed) == true else { return }
        space = proposed
        for swatch in swatches { swatch.isPicked = swatch.colorIndex == space.colorIndex }
        updatePreview()
    }
    @objc private func pickGlyph(_ sender: SettingsGlyph) {
        guard sender.symbol != space.symbol else { return }
        var proposed = space; proposed.symbol = sender.symbol
        guard onEdit?(proposed) == true else { return }
        space = proposed
        for glyph in glyphs { glyph.isPicked = glyph.symbol == space.symbol }
        updatePreview()
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
            layer?.borderWidth = 1.5
        } else {
            layer?.backgroundColor = ArkPalette.spaceColor(colorIndex).cgColor
        }
        layer?.cornerRadius = 13
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
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        ring.borderColor = bamCG(BamTheme.ink)
        if colorIndex == BrowserSpace.clearColorIndex {
            layer?.backgroundColor = bamCG(BamTheme.bg)
            layer?.borderColor = bamCG(BamTheme.line)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -3, dy: -3) }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: -3, dy: -3)).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class SettingsGlyph: NSButton {
    let symbol: String
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }
    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(symbol) icon")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        var ink = BamTheme.ink
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor(cgColor: BamTheme.ink.cgColor) ?? BamTheme.ink }
        image = SidebarSymbol.image(named: symbol, color: ink, pointSize: 13)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        layer?.backgroundColor = bamCG(isPicked ? BamTheme.redWash : BamTheme.bg)
        layer?.borderColor = bamCG(isPicked ? BamTheme.red : BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
