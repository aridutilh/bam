import AppKit

enum SettingsSection: CaseIterable {
    case general, appearance, websites, privacy, search, spaces, links, shortcuts, extensions, about
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .websites: return "Websites"
        case .privacy: return "Privacy"
        case .search: return "Search"
        case .spaces: return "Spaces"
        case .links: return "Links"
        case .shortcuts: return "Shortcuts"
        case .extensions: return "Extensions"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .websites: return "globe"
        case .privacy: return "hand.raised"
        case .search: return "magnifyingglass"
        case .spaces: return "square.stack.3d.up"
        case .links: return "arrow.triangle.branch"
        case .shortcuts: return "command"
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
    /// Every host kept awake (Websites › Always keep these sites awake).
    var keepAwakeHosts: [String] = []
    /// False in a private window, which never remembers sites.
    var canKeepSitesAwake = true
    /// Archive tabs after: the choices' titles and which one is picked.
    var archiveChoices: [String] = ["Never"]
    var archiveChoice = 0
    var pageZoom: Double = 1
    var zoomChoices: [Double] = [1]
    var minimumFontSize: Double = 0
    var fontChoices: [Double] = [0]
    /// Read from the preference itself, so it is right however the snapshot is built.
    var asksBeforeQuitting = QuitConfirmationPreference().asksBeforeQuitting
    /// False in a private window: its choices never change the normal browser's preference.
    var canChangeQuitPreference = true
    var searchEngine: DefaultSearchEngine = .duckDuckGo
    var appearance: BrowserAppearance = .system
    var spaces: [BrowserSpace] = BrowserSpace.defaults
    /// Air Traffic Control's routes and default, and a route Bam would suggest.
    var linkRouting = LinkRouting()
    var linkSuggestion: (site: String, space: Int)? = nil
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
    /// "Mail.Google.com/inbox" → "mail.google.com", or nil when it isn't a site.
    var hostFromTyped: (String) -> String? = { _ in nil }
    var setArchiveChoice: (Int) -> Void = { _ in }
    var showArchive: () -> Void = {}
    var setPageZoom: (Double) -> Void = { _ in }
    var setMinimumFontSize: (Double) -> Void = { _ in }
    var setAsksBeforeQuitting: (Bool) -> Void = { _ in }
    var setSearchEngine: (DefaultSearchEngine) -> Void = { _ in }
    var setLinkRouting: (LinkRouting) -> Void = { _ in }
    var dismissLinkSuggestion: (String, Int) -> Void = { _, _ in }
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
        // ⌘F finds a setting, as in a document.
        if modifiers == .command, event.charactersIgnoringModifiers == "f",
           let controller = delegate as? SettingsController { controller.focusSearch(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// One thing the search field can take you to: a row in a section, or a menu command's shortcut.
struct SettingsSearchHit: Equatable {
    let section: SettingsSection
    let title: String
    let detail: String?
    var shortcutID: String? = nil
}

/// Bam's settings: a window on bambrowser.com's paper with a searchable section
/// rail and dense cards of rows, following the system appearance like the site does.
@MainActor final class SettingsController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    static let githubURL = URL(string: "https://github.com/aridutilh/bam")!
    static let siteURL = URL(string: "https://bambrowser.com")!
    static let size = NSSize(width: 780, height: 620)
    private let provider: () -> SettingsSnapshot
    private let actions: SettingsActions
    private(set) var snapshot: SettingsSnapshot
    private(set) var section: SettingsSection = .general
    let window: SettingsWindow
    private let paper = BamSurfaceView(frame: .zero)
    let searchField = NSSearchField()
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
        window = SettingsWindow(contentRect: NSRect(origin: .zero, size: Self.size),
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
        // Tab walks every control in reading order, whichever section is showing.
        window.autorecalculatesKeyViewLoop = true
        window.setFrameAutosaveName("BamSettings")
        // An older, larger saved frame would leave the new layout stretched; Settings keeps one size.
        window.setContentSize(Self.size)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: ShortcutStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(adBlockerChanged), name: .contentBlockingChanged, object: nil)
    }

    private func build() {
        paper.frame = NSRect(origin: .zero, size: Self.size)
        paper.autoresizingMask = [.width, .height]
        window.contentView = paper
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(sidebar)
        searchField.placeholderString = "Search settings"
        searchField.font = BamType.sans(13)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search settings and shortcuts")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(searchField)
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 2
        rail.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(rail)
        for section in SettingsSection.allCases {
            let button = SettingsRailButton(section: section)
            button.target = self; button.action = #selector(pickSection(_:))
            railButtons[section] = button
            rail.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
            // A little air between "how Bam looks and loads" and "what you've set up in it".
            if section == .privacy || section == .links { rail.setCustomSpacing(12, after: button) }
        }
        let divider = BamHairline()
        paper.addSubview(divider)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // The column sets its own top margin under the title bar; an automatic inset would
        // make the heading jump between panes depending on how each was scrolled to the top.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedContainer()
        document.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        paper.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: paper.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 42),
            rail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            rail.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            rail.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: paper.topAnchor),
            divider.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: paper.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 38),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 30),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -30),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -36)
        ])
    }
    static var appIcon: NSImage {
        let bundled = Bundle.main.url(forResource: "BamIcon", withExtension: "png")
        let override = ProcessInfo.processInfo.environment["BAM_RESOURCES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("BamIcon.png") }
        return (bundled ?? override).flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
    }

    func show(section: SettingsSection, relativeTo parent: NSWindow?) {
        reload()
        clearSearch()
        select(section)
        if !shownOnce {
            shownOnce = true
            if let parent, !window.setFrameUsingName("BamSettings") {
                window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                              y: parent.frame.midY - window.frame.height / 2))
            } else if parent == nil { window.center() }
            window.setContentSize(Self.size)
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
            self.keepingScroll { self.render() }
        }
    }
    private func reload() {
        snapshot = provider()
        searchIndex = nil
    }
    func select(_ section: SettingsSection) {
        self.section = section
        for (key, button) in railButtons { button.isPicked = key == section && query.isEmpty }
        render()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func pickSection(_ sender: SettingsRailButton) {
        clearSearch()
        select(sender.section)
    }
    private func keepingScroll(_ work: () -> Void) {
        let offset = scroll.contentView.bounds.origin
        work()
        column.superview?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// A toggle or chip already shows its new state; only the snapshot moves,
    /// so keyboard focus stays on the control that was just used.
    private func act(_ work: () -> Void) {
        work()
        reload()
    }

    // MARK: Building blocks

    private func render() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !query.isEmpty { renderResults(); return }
        let subtitle: String
        switch section {
        case .general: subtitle = "How Bam starts, tidies, plays and quits."
        case .appearance: subtitle = "Light or dark, and each Space’s color."
        case .websites: subtitle = "How pages look and when they rest."
        case .privacy: subtitle = "What pages may load while you browse."
        case .search: subtitle = "Where typed words go when they aren’t an address."
        case .spaces: subtitle = "Name and color each part of your day."
        case .links: subtitle = "Where links from other apps open: Air Traffic Control."
        case .shortcuts: subtitle = "Every command in the menu bar. Click a key to change it."
        case .extensions: subtitle = "Local WebExtensions in the \(snapshot.profileName) profile."
        case .about: subtitle = "Bam \(snapshot.version)"
        }
        addHeading(section.title, subtitle)
        let cards: [NSView]
        switch section {
        case .general: cards = generalCards()
        case .appearance: cards = appearanceCards()
        case .websites: cards = websitesCards()
        case .privacy: cards = privacyCards()
        case .search: cards = searchCards()
        case .spaces: cards = spacesCards()
        case .links: cards = linksCards()
        case .shortcuts: cards = shortcutsCards()
        case .extensions: cards = extensionsCards()
        case .about: cards = aboutCards()
        }
        add(cards)
    }
    private func addHeading(_ title: String, _ subtitle: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = BamType.display(26, weight: .heavy)
        heading.textColor = BamTheme.ink
        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = BamType.sans(13); sub.textColor = BamTheme.muted; sub.isSelectable = false
        column.addArrangedSubview(heading)
        column.addArrangedSubview(sub)
        column.setCustomSpacing(0, after: heading)
        column.setCustomSpacing(18, after: sub)
    }
    private func add(_ views: [NSView]) {
        for view in views {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            // Captions sit close to their card; cards keep their distance from the next caption.
            if view is SettingsCaption { column.setCustomSpacing(6, after: view) }
            else { column.setCustomSpacing(18, after: view) }
        }
    }

    private func caption(_ text: String) -> SettingsCaption { SettingsCaption(text) }
    private func card() -> BamCard {
        let card = BamCard(frame: .zero)
        card.cornerRadius = 12; card.separatorInset = 16; card.isQuiet = true
        return card
    }
    private func row(_ title: String, _ detail: String? = nil, _ control: NSView? = nil, enabled: Bool = true, keywords: [String] = []) -> BamRow {
        let row = BamRow(title: title, detail: detail, control: control, enabled: enabled, compact: true)
        row.keywords = keywords
        return row
    }
    private func toggle(_ on: Bool, enabled: Bool = true, label: String? = nil, _ change: @escaping (Bool) -> Void) -> BamToggle {
        let toggle = BamToggle(compact: true)
        toggle.accent = accent; toggle.isOn = on; toggle.isEnabled = enabled
        if let label { toggle.setAccessibilityLabel(label) }
        toggle.onChange = { [weak self] value in self?.act { change(value) } }
        return toggle
    }
    private func pill(_ title: String, symbol: String? = nil, _ action: Selector) -> BamPillButton {
        let pill = BamPillButton(title: title, symbol: symbol, compact: true)
        pill.target = self; pill.action = action
        return pill
    }
    /// A row of chips; `pick` gets the picked index. Chips re-pick in place, so focus stays.
    private func chips(_ titles: [String], picked: Int?, label: String, _ pick: @escaping (Int) -> Void) -> SettingsChipGroup {
        let group = SettingsChipGroup(titles: titles, picked: picked, accent: accent, label: label)
        group.onPick = { [weak self] index in self?.act { pick(index) } }
        return group
    }

    /// A pop-up choice (Arc's style for a long list): a pill naming the pick that opens a checked menu.
    private func choiceMenu(_ titles: [String], picked: Int, label: String, current shown: String? = nil, _ pick: @escaping (Int) -> Void) -> NSView {
        let current = shown ?? (titles.indices.contains(picked) ? titles[picked] : "")
        let button = SettingsMenuPill(title: current)
        button.setAccessibilityLabel(label); button.setAccessibilityValue(current)
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            let menu = NSMenu(); menu.autoenablesItems = false
            for (index, title) in titles.enumerated() {
                let handler = SettingsMenuAction { [weak self] in
                    self?.act { pick(index) }
                    self?.refresh()
                }
                let item = NSMenuItem(title: title, action: #selector(SettingsMenuAction.run(_:)), keyEquivalent: "")
                item.target = handler; item.representedObject = handler; item.state = index == picked ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: menu.items.indices.contains(picked) ? menu.items[picked] : nil,
                       at: NSPoint(x: 8, y: button.bounds.height - 6), in: button)
        }
        return button
    }

    // MARK: General

    private func generalCards() -> [NSView] {
        let startup = card()
        startup.add(row("Bring in your Arc sidebar",
                        "Spaces, folders, kept tabs and Favorites. Pages stay asleep until you open them.",
                        pill("Import from Arc…", symbol: "square.and.arrow.down", #selector(importFromArc)),
                        keywords: ["import", "migrate"]))
        startup.add(row("Welcome to Bam", "Pick a color, name a Space, learn the keys.",
                        pill("Show Again", symbol: "sparkles", #selector(showWelcome)), keywords: ["onboarding", "tour"]))
        let tabs = card()
        let archive = choiceMenu(snapshot.archiveChoices, picked: snapshot.archiveChoice, label: "Archive tabs after") { [actions] index in
            actions.setArchiveChoice(index)
        }
        tabs.add(row("Archive tabs after", "Today tabs you haven’t looked at for this long close into the archive. Kept tabs, Favorites and tabs playing or in a call stay.",
                     archive, keywords: ["auto archive", "auto-archive", "close old tabs", "tidy", "clean up"]))
        tabs.add(row("Archived tabs", "Everything you closed or Bam archived, by day. Restore any of it.",
                     pill("View Archive…", symbol: "archivebox", #selector(showArchive)), keywords: ["recently closed", "reopen", "history"]))
        let playback = card()
        playback.add(row("Picture in Picture when you leave a video",
                         "A playing video floats over other tabs and Spaces.",
                         toggle(snapshot.showsPlayingVideo, label: "Automatically show playing videos", actions.setShowsPlayingVideo),
                         keywords: ["automatically show playing videos", "pip", "float"]))
        let quitting = card()
        quitting.add(row("Warn before quitting",
                         snapshot.canChangeQuitPreference ? nil : "Change this in a normal Bam window; private windows don’t change it.",
                         toggle(snapshot.asksBeforeQuitting, enabled: snapshot.canChangeQuitPreference, label: "Ask before quitting", actions.setAsksBeforeQuitting),
                         enabled: snapshot.canChangeQuitPreference, keywords: ["ask before quitting", "quit", "⌘q"]))
        return [caption("Start"), startup, caption("Tabs"), tabs, caption("Playback"), playback, caption("Quitting"), quitting]
    }
    @objc private func showArchive() { actions.showArchive() }
    @objc private func importFromArc() {
        window.orderOut(nil)
        actions.importFromArc()
    }

    // MARK: Appearance

    private weak var appearanceChips: SettingsChipGroup?
    private func appearanceCards() -> [NSView] {
        let look = card()
        let picked = BrowserAppearance.allCases.firstIndex(of: snapshot.appearance)
        let group = SettingsChipGroup(titles: BrowserAppearance.allCases.map(\.title), picked: picked, accent: accent, label: "appearance")
        group.onPick = { [weak self] index in
            guard let self, BrowserAppearance.allCases.indices.contains(index) else { return }
            self.act { self.actions.setAppearance(BrowserAppearance.allCases[index]) }
        }
        appearanceChips = group
        look.add(row("Theme", "System follows macOS. Space colors carry over in both.", group, keywords: ["appearance", "dark mode", "light"]))
        let colors = card()
        for space in snapshot.spaces {
            let swatches = NSStackView(); swatches.orientation = .horizontal; swatches.spacing = 6
            for index in 0..<BrowserSpace.colorNames.count {
                let swatch = SettingsSwatch(colorIndex: index, diameter: 18)
                swatch.isPicked = index == space.colorIndex
                swatch.spaceID = space.id
                swatch.setAccessibilityLabel("\(BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, index)]) color for \(space.name)")
                swatch.target = self; swatch.action = #selector(pickSpaceColor(_:))
                swatches.addArrangedSubview(swatch)
            }
            colors.add(row(space.name, nil, swatches, keywords: ["space color", "color", "tint"]))
        }
        return [caption("Theme"), look, caption("Space colors"), colors]
    }
    /// An appearance change (from here, the View menu or a relaunch) updates
    /// the chips in place. Rebuilding the section would drop keyboard focus.
    func syncAppearance() {
        reload()
        appearanceChips?.pick(BrowserAppearance.allCases.firstIndex(of: snapshot.appearance))
    }
    @objc private func pickSpaceColor(_ sender: SettingsSwatch) {
        guard var space = snapshot.spaces.first(where: { $0.id == sender.spaceID }), space.colorIndex != sender.colorIndex else { return }
        space.colorIndex = sender.colorIndex
        guard actions.editSpace(space) else { NSSound.beep(); return }
        // The app's onSpacesChanged refreshes this window; repaint the row's swatches now too.
        for case let swatch as SettingsSwatch in sender.superview?.subviews ?? [] { swatch.isPicked = swatch === sender }
        reload()
    }

    // MARK: Websites

    private weak var keepAwakeField: BamTextField?
    private func websitesCards() -> [NSView] {
        let pages = card()
        let zoom = chips(snapshot.zoomChoices.map { "\(Int(($0 * 100).rounded()))%" },
                         picked: snapshot.zoomChoices.firstIndex(of: snapshot.pageZoom), label: "page zoom") { [actions, snapshot] index in
            actions.setPageZoom(snapshot.zoomChoices[index])
        }
        pages.add(row("Page zoom", "Where every page starts. ⌘+ and ⌘− still zoom one page; ⌘0 comes back here.", zoom,
                      keywords: ["page size", "default zoom", "scale", "bigger", "smaller"]))
        let fonts = chips(snapshot.fontChoices.map { $0 == 0 ? "Off" : "\(Int($0))" },
                          picked: snapshot.fontChoices.firstIndex(of: snapshot.minimumFontSize), label: "minimum font size") { [actions, snapshot] index in
            actions.setMinimumFontSize(snapshot.fontChoices[index])
        }
        pages.add(row("Minimum font size", "Text smaller than this many points is drawn at this size.", fonts,
                      keywords: ["fonts", "text size", "small text", "readability"]))
        let memory = card()
        memory.add(row("Sleep idle pages under memory pressure",
                       "When macOS runs low on memory, tabs you haven’t used in a while unload, then reload on return.",
                       toggle(snapshot.sleepsIdlePages, label: "Sleep idle pages under memory pressure", actions.setSleepsIdlePages),
                       keywords: ["memory", "performance", "unload", "sleeping tabs"]))
        let awake = card()
        let keep = actions.setKeepsSiteAwake
        if snapshot.keepAwakeHosts.isEmpty {
            awake.add(row("No sites yet", "Chats and mail you want ready at once, never asleep.", enabled: false))
        }
        for host in snapshot.keepAwakeHosts {
            let remove = SettingsIconButton(symbol: "minus.circle", label: "Stop keeping \(host) awake")
            remove.onPress = { [weak self] in self?.act { keep(host, false) }; self?.refresh() }
            awake.add(row(host, nil, remove, keywords: ["keep awake"]))
        }
        let field = BamTextField(string: "", placeholder: "Add a site, like mail.google.com")
        field.setAccessibilityLabel("Site to keep awake")
        field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        field.onCommit = { [weak self] text in
            guard let self else { return false }
            guard self.snapshot.canKeepSitesAwake, let host = self.actions.hostFromTyped(text) else { NSSound.beep(); return false }
            self.act { keep(host, true) }
            self.refresh()
            DispatchQueue.main.async { self.window.makeFirstResponder(self.keepAwakeField) }
            return true
        }
        keepAwakeField = field
        var controls: [NSView] = [field]
        if let host = snapshot.keepAwakeHost, !snapshot.keepAwakeHosts.contains(host) {
            let current = BamPillButton(title: "Add \(host)", symbol: "plus", compact: true)
            current.target = self; current.action = #selector(keepCurrentSiteAwake)
            controls.append(current)
        }
        let adder = NSStackView(views: controls); adder.spacing = 8
        awake.add(row("Add a site", nil, adder, enabled: snapshot.canKeepSitesAwake, keywords: ["keep awake", "keep site awake"]))
        return [caption("Pages"), pages, caption("Memory"), memory,
                caption("Always keep these sites awake"), awake]
    }
    @objc private func keepCurrentSiteAwake() {
        guard let host = snapshot.keepAwakeHost else { return }
        act { actions.setKeepsSiteAwake(host, true) }
        refresh()
    }

    // MARK: Privacy

    private weak var adSummaryRow: BamRow?
    private weak var adUpdatePill: BamPillButton?
    private var adSummary = ""
    private func privacyCards() -> [NSView] {
        let blocker = card()
        let summary = ContentBlockingPreference.summary(ContentBlockingPreference.status, enabled: ContentBlockingPreference.isEnabled)
        adSummary = summary
        let blockRow = row("Block ads and trackers", summary,
                           toggle(ContentBlockingPreference.isEnabled, label: "Block ads and trackers") { ContentBlockingPreference.isEnabled = $0 },
                           keywords: ["ad blocker", "adblock", "privacy", "tracking"])
        adSummaryRow = blockRow
        blocker.add(blockRow)
        let update = pill("Update Now", symbol: "arrow.clockwise", #selector(updateFilterLists))
        update.isEnabled = ContentBlockingPreference.isEnabled && !ContentBlockingPreference.status.updating
        adUpdatePill = update
        blocker.add(row("Filter lists",
                        "uBlock Origin’s defaults: EasyList, EasyPrivacy, uBlock filters, malware and scams, Peter Lowe’s list. Refreshed weekly.",
                        update, keywords: ["easylist", "easyprivacy", "ublock"]))
        let allowed = card()
        let sites = ContentBlockingPreference.allowedSites.sorted()
        if sites.isEmpty {
            allowed.add(row("No sites", "Allow ads on a site from its site controls in the address field.", enabled: false))
        }
        for site in sites {
            let block = SettingsIconButton(symbol: "minus.circle", label: "Block ads on \(site) again")
            block.onPress = { [weak self] in
                ContentBlockingPreference.setBlocks(true, for: URL(string: "https://\(site)"))
                self?.refresh()
            }
            allowed.add(row(site, nil, block, keywords: ["allowed", "whitelist", "ads allowed"]))
        }
        return [caption("Ad blocker"), blocker, caption("Sites that show ads"), allowed]
    }
    @objc private func updateFilterLists() {
        NotificationCenter.default.post(name: .contentBlockingUpdateRequested, object: nil)
    }
    /// New rule counts or an update starting/finishing: rewrite the summary line in place.
    @objc private func adBlockerChanged() {
        let summary = ContentBlockingPreference.summary(ContentBlockingPreference.status, enabled: ContentBlockingPreference.isEnabled)
        adUpdatePill?.isEnabled = ContentBlockingPreference.isEnabled && !ContentBlockingPreference.status.updating
        guard summary != adSummary, let row = adSummaryRow else { return }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == adSummary { return field }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        find(row)?.stringValue = summary
        adSummary = summary
    }

    // MARK: Search

    private func searchCards() -> [NSView] {
        let engine = card()
        let picked = DefaultSearchEngine.allCases.firstIndex(of: snapshot.searchEngine)
        let group = SettingsChipGroup(titles: DefaultSearchEngine.allCases.map(\.name), picked: picked, accent: accent, label: "default search engine",
                                      dots: DefaultSearchEngine.allCases.map { engine in SiteSearchCatalog.engines.first { $0.host == engine.rawValue }?.color ?? BamTheme.red })
        group.onPick = { [weak self] index in
            guard let self, DefaultSearchEngine.allCases.indices.contains(index) else { return }
            self.act { self.actions.setSearchEngine(DefaultSearchEngine.allCases[index]) }
        }
        engine.add(row("Search engine", "Where plain words go. Suggestions come from it when it offers them.", group,
                       keywords: ["default search engine", "google", "duckduckgo", "bing", "kagi"]))
        let tip = card()
        tip.isDashed = true
        tip.add(row("Search one site instead",
                    "Type a site name in the palette (YouTube, Wikipedia, GitHub…) and press Tab to search it directly.",
                    BamKeycap("⇥"), keywords: ["site search", "tab to search"]))
        return [caption("Engine"), engine, caption("Tip"), tip]
    }

    // MARK: Spaces

    /// The Space the editor shows; the list on top picks it. Survives refreshes.
    private var editingSpaceID: Int?

    private func spacesCards() -> [NSView] {
        let spaces = snapshot.spaces
        let editing = spaces.first { $0.id == editingSpaceID } ?? spaces.first { $0.id == snapshot.currentSpaceID } ?? spaces.first
        editingSpaceID = editing?.id
        let list = card()
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
            rows.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -6)
        ])
        list.add(host)
        var cards: [NSView] = [caption("Your Spaces"), list]
        if let editing {
            let editor = SpaceEditorCard(space: editing, isCurrent: editing.id == snapshot.currentSpaceID)
            editor.cornerRadius = 12; editor.isQuiet = true
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
        let footer = card()
        footer.add(row("Reorder, add or remove Spaces", "Login profiles live there too.",
                       pill("Manage Spaces…", symbol: "square.stack.3d.up", #selector(manageSpaces)), keywords: ["profiles", "new space"]))
        return cards + [footer]
    }
    /// Rebuilds on the next turn, like refresh(), so the clicked row is not
    /// torn down inside its own action; the scroll position stays put.
    @objc private func pickSpace(_ sender: SpaceListRow) {
        guard editingSpaceID != sender.spaceID else { return }
        editingSpaceID = sender.spaceID
        DispatchQueue.main.async { [weak self] in self?.keepingScroll { self?.render() } }
    }
    @objc private func manageSpaces() { actions.manageSpaces() }

    // MARK: Links

    /// Destinations in the order Arc lists them: each Space, then Most Recent Space and Little Bam.
    private var linkDestinations: [(LinkDestination, String)] {
        snapshot.spaces.map { (.space($0.id), $0.name) } + [(.mostRecentSpace, "Most Recent Space"), (.littleBam, "Little Bam")]
    }
    private func destinationMenu(_ current: LinkDestination, label: String, _ change: @escaping (LinkDestination) -> Void) -> NSView {
        let options = linkDestinations
        let picked = options.firstIndex { $0.0 == current } ?? -1
        return choiceMenu(options.map(\.1), picked: picked, label: label, current: picked < 0 ? "Missing Space" : nil) { index in
            change(options[index].0)
        }
    }
    /// Applies a change to the routes and redraws the section.
    private func updateRouting(_ change: (inout LinkRouting) -> Void) {
        var routing = snapshot.linkRouting
        change(&routing)
        act { actions.setLinkRouting(routing) }
        refresh()
    }
    /// Edits one route by id. Rows hold their route's id, not its position: a field that commits as
    /// its row is torn down (after a removal above it, or of itself) must not write to another route
    /// or past the end of the list.
    private func updateRoute(_ id: UUID, _ change: @escaping (inout LinkRoute) -> Void) {
        guard snapshot.linkRouting.routes.contains(where: { $0.id == id }) else { return }
        updateRouting { routing in
            if let index = routing.routes.firstIndex(where: { $0.id == id }) { change(&routing.routes[index]) }
        }
    }
    private weak var linkTestResult: NSTextField?
    private var focusRouteID: UUID?

    private func linksCards() -> [NSView] {
        var cards: [NSView] = []
        if let suggestion = snapshot.linkSuggestion, let space = snapshot.spaces.first(where: { $0.id == suggestion.space }) {
            let tip = card(); tip.isDashed = true
            let add = pill("Add Route", symbol: "plus", #selector(acceptSuggestion))
            let later = SettingsIconButton(symbol: "xmark", label: "Don’t suggest this again")
            later.onPress = { [weak self] in self?.act { self?.actions.dismissLinkSuggestion(suggestion.site, space.id) }; self?.refresh() }
            let controls = NSStackView(views: [add, later]); controls.spacing = 8
            tip.add(row("Open \(suggestion.site) links in \(space.name)?", "You’ve moved \(suggestion.site) to \(space.name) a few times.", controls,
                        keywords: ["suggested route"]))
            cards += [caption("Suggested"), tip]
        }
        let routes = card()
        let newRoute = pill("New Route", symbol: "plus", #selector(addRoute))
        routes.add(row("Routes", "Checked top to bottom. The first match wins.", newRoute,
                       keywords: ["air traffic control", "atc", "route", "rules", "links from other apps", "open links in space"]))
        for (index, route) in snapshot.linkRouting.routes.enumerated() {
            let line = SettingsRouteRow(route: route, position: index + 1)
            line.matchMenu = choiceMenu(LinkRoute.Match.allCases.map(\.title), picked: LinkRoute.Match.allCases.firstIndex(of: route.match) ?? 0,
                                        label: "Route \(index + 1) comparison") { [weak self] pick in
                self?.updateRoute(route.id) { $0.match = LinkRoute.Match.allCases[pick] }
            }
            line.destinationMenu = destinationMenu(route.destination, label: "Route \(index + 1) opens in") { [weak self] destination in
                self?.updateRoute(route.id) { $0.destination = destination }
            }
            line.onText = { [weak self] text in
                self?.updateRoute(route.id) { $0.text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            line.onRemove = { [weak self] in self?.updateRouting { $0.routes.removeAll { $0.id == route.id } } }
            line.build()
            routes.add(line)
            if route.id == focusRouteID {
                focusRouteID = nil
                DispatchQueue.main.async { [weak self, weak line] in if let field = line?.field { self?.window.makeFirstResponder(field) } }
            }
        }
        if snapshot.linkRouting.routes.isEmpty {
            routes.add(row("No routes yet", "Links from other apps all go to the default below.", enabled: false))
        }
        let fallback = card()
        fallback.add(row("Everything else opens in", "Links that match no route. Little Bam floats over the app you clicked in.",
                         destinationMenu(snapshot.linkRouting.fallback, label: "Default destination") { [weak self] destination in
                             self?.updateRouting { $0.fallback = destination }
                         }, keywords: ["default", "little bam", "fallback"]))
        let test = card()
        let field = BamTextField(string: "", placeholder: "Paste a link, like figma.com/file/abc")
        field.setAccessibilityLabel("Link to try")
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let result = NSTextField(labelWithString: "")
        result.font = BamType.sans(12.5, weight: .semibold); result.textColor = BamTheme.muted
        result.lineBreakMode = .byTruncatingTail
        linkTestResult = result
        field.onCommit = { [weak self] text in self?.tryLink(text); return true }
        let tryRow = row("Try a link", "See where a link from another app would open.", field, keywords: ["test", "check a url"])
        test.add(tryRow)
        let resultHost = NSView(); resultHost.translatesAutoresizingMaskIntoConstraints = false
        result.translatesAutoresizingMaskIntoConstraints = false
        resultHost.addSubview(result)
        NSLayoutConstraint.activate([
            result.leadingAnchor.constraint(equalTo: resultHost.leadingAnchor, constant: 16),
            result.trailingAnchor.constraint(lessThanOrEqualTo: resultHost.trailingAnchor, constant: -16),
            result.topAnchor.constraint(equalTo: resultHost.topAnchor, constant: 0),
            result.bottomAnchor.constraint(equalTo: resultHost.bottomAnchor, constant: -12)
        ])
        test.stack.addArrangedSubview(resultHost)
        resultHost.widthAnchor.constraint(equalTo: test.stack.widthAnchor).isActive = true
        result.stringValue = "Press Return to check."
        return cards + [caption("Air Traffic Control"), routes, caption("Default"), fallback, caption("Try it"), test]
    }
    @objc private func acceptSuggestion() {
        guard let suggestion = snapshot.linkSuggestion else { return }
        updateRouting { $0.routes.append(LinkRoute(match: .contains, text: suggestion.site, destination: .space(suggestion.space))) }
    }
    @objc private func addRoute() {
        let route = LinkRoute(match: .contains, text: "", destination: .mostRecentSpace)
        focusRouteID = route.id
        updateRouting { $0.routes.append(route) }
    }
    /// What "Try a link" says for a typed address.
    func linkTestDescription(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Press Return to check." }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), url.host != nil else { return "That isn’t a web address." }
        let spaces = snapshot.spaces
        let found = snapshot.linkRouting.destination(for: url, spaceExists: { id in spaces.contains { $0.id == id } })
        let place: String
        switch found.destination {
        case .space(let id): place = spaces.first { $0.id == id }?.name ?? "a Space"
        case .mostRecentSpace: place = "the Space you’re in"
        case .littleBam: place = "Little Bam"
        }
        if let route = found.route, let position = snapshot.linkRouting.routes.firstIndex(of: route) {
            return "Opens in \(place), by route \(position + 1) (\(route.match.title.lowercased()) “\(route.text)”)."
        }
        return "Opens in \(place), the default. No route matches."
    }
    private func tryLink(_ text: String) { linkTestResult?.stringValue = linkTestDescription(text) }

    // MARK: Shortcuts

    private struct ShortcutLine {
        let command: MenuShortcut
        let row: BamRow
        let group: Int
    }
    private var shortcutLines: [ShortcutLine] = []
    private var shortcutGroups: [(caption: NSView, card: BamCard)] = []
    private weak var shortcutFilter: NSSearchField?
    private weak var resetPill: BamPillButton?
    private weak var shortcutEmpty: NSView?

    private func shortcutsCards() -> [NSView] {
        let store = ShortcutStore.shared
        let tools = card()
        let filter = NSSearchField()
        filter.placeholderString = "Filter by name or keys, like ⌘K"
        filter.font = BamType.sans(13)
        filter.sendsSearchStringImmediately = true
        filter.target = self; filter.action = #selector(filterShortcuts(_:))
        filter.setAccessibilityLabel("Filter shortcuts")
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.widthAnchor.constraint(equalToConstant: 260).isActive = true
        shortcutFilter = filter
        let reset = pill("Reset All", symbol: "arrow.counterclockwise", #selector(resetShortcuts))
        reset.isEnabled = store.anyCustom
        resetPill = reset
        let bar = NSStackView(views: [filter, NSView(), reset])
        bar.orientation = .horizontal; bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        tools.add(bar)
        var views: [NSView] = [tools]
        shortcutLines = []; shortcutGroups = []
        // Group by menu, in menu-bar order.
        var order: [String] = []
        var byMenu: [String: [MenuShortcut]] = [:]
        for command in store.catalog where !command.menu.isEmpty {
            if byMenu[command.menu] == nil { order.append(command.menu) }
            byMenu[command.menu, default: []].append(command)
        }
        for menu in order {
            let group = card()
            let label = caption(menu)
            for command in byMenu[menu] ?? [] {
                let line = row(command.title, nil, shortcutControl(for: command))
                group.add(line)
                shortcutLines.append(ShortcutLine(command: command, row: line, group: shortcutGroups.count))
            }
            shortcutGroups.append((label, group))
            views += [label, group]
        }
        let empty = row("No commands match", "Try other words, or keys like ⇧⌘C.", enabled: false)
        let emptyCard = card(); emptyCard.add(empty); emptyCard.isHidden = true
        shortcutEmpty = emptyCard
        views.append(emptyCard)
        let note = card(); note.isDashed = true
        note.add(row("Recording a key", "Escape keeps the old one, Delete restores the default. A key another command uses can be moved to this one.",
                     BamKeycap("esc")))
        views.append(note)
        return views
    }
    private func shortcutControl(for command: MenuShortcut) -> NSView {
        let recorder = BamShortcutRecorder(id: command.id, title: command.title)
        recorder.onConflict = { [weak self] combo, owner in self?.offerTakeover(combo, from: owner, to: command) }
        let more = SettingsIconButton(symbol: "ellipsis.circle", label: "More for \(command.title)")
        more.onPress = { [weak more, weak recorder] in
            guard let more else { return }
            let store = ShortcutStore.shared
            let menu = NSMenu()
            let record = NSMenuItem(title: "Record Shortcut", action: #selector(SettingsMenuAction.run(_:)), keyEquivalent: "")
            let reset = NSMenuItem(title: "Reset to Default\(command.defaultCombo.map { " (\($0.compact))" } ?? "")",
                                   action: #selector(SettingsMenuAction.run(_:)), keyEquivalent: "")
            let remove = NSMenuItem(title: "Remove Shortcut", action: #selector(SettingsMenuAction.run(_:)), keyEquivalent: "")
            let handlers = [SettingsMenuAction { recorder?.start() },
                            SettingsMenuAction { store.reset(id: command.id) },
                            SettingsMenuAction { store.remove(id: command.id) }]
            for (item, handler) in zip([record, reset, remove], handlers) { item.target = handler; item.representedObject = handler; menu.addItem(item) }
            reset.isEnabled = !store.isDefault(id: command.id)
            remove.isEnabled = store.combo(forID: command.id) != nil
            menu.autoenablesItems = false
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        let stack = NSStackView(views: [recorder, more]); stack.spacing = 6
        return stack
    }
    /// The recorded chord belongs to another command: offer to move it, as a sheet on Settings.
    private func offerTakeover(_ combo: KeyCombo, from owner: String, to command: MenuShortcut) {
        let alert = NSAlert()
        alert.messageText = "\(combo.compact) is used by “\(owner)”"
        alert.informativeText = "Use it for “\(command.title)” instead? “\(owner)” will have no shortcut until you give it one."
        alert.addButton(withTitle: "Use for \(command.title)")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            ShortcutStore.shared.assign(combo, to: command.id, takeOver: true)
        }
    }
    @objc private func filterShortcuts(_ sender: NSSearchField) { applyShortcutFilter(sender.stringValue) }
    private func applyShortcutFilter(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        var visible = Array(repeating: 0, count: shortcutGroups.count)
        for line in shortcutLines {
            let show = query.isEmpty || Self.shortcut(line.command, matches: query)
            line.row.isHidden = !show
            if show { visible[line.group] += 1 }
        }
        for (index, group) in shortcutGroups.enumerated() {
            group.caption.isHidden = visible[index] == 0
            group.card.isHidden = visible[index] == 0
            // Hairlines next to hidden rows would double up; show only those between visible rows.
            var previousVisible = false
            for view in group.card.stack.arrangedSubviews {
                if view is BamSeparatorHolder { view.isHidden = true; continue }
                if !view.isHidden {
                    if previousVisible, let index = group.card.stack.arrangedSubviews.firstIndex(of: view), index > 0 {
                        group.card.stack.arrangedSubviews[index - 1].isHidden = false
                    }
                    previousVisible = true
                }
            }
        }
        shortcutEmpty?.isHidden = visible.contains { $0 > 0 }
    }
    /// A command matches a filter by its title, its menu, or its chord ("⌘K", "cmd shift c").
    static func shortcut(_ command: MenuShortcut, matches query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let haystack = (command.title + " " + command.menu).lowercased()
        if !words.isEmpty, words.allSatisfy({ haystack.contains($0) }) { return true }
        return ShortcutStore.shared.combo(forID: command.id)?.matches(query) ?? false
    }
    @objc private func resetShortcuts() { ShortcutStore.shared.resetAll() }
    /// The recorders repaint themselves; only the reset pill needs a nudge.
    @objc private func shortcutsChanged() {
        resetPill?.isEnabled = ShortcutStore.shared.anyCustom
        searchIndex = nil
    }

    // MARK: Extensions

    private func extensionsCards() -> [NSView] {
        let list = card()
        if snapshot.extensions.isEmpty {
            list.add(row("No extensions yet", "Add one from the Chrome Web Store, Firefox Add-ons or a folder.", enabled: false))
        }
        for item in snapshot.extensions {
            let state: NSView
            if item.enabled { state = BamBadge("On") } else {
                let off = NSTextField(labelWithString: "Off")
                off.font = BamType.sans(12, weight: .semibold); off.textColor = BamTheme.muted
                state = off
            }
            list.add(row(item.name, "Version \(item.version)", state))
        }
        let footer = card()
        footer.add(row("Add, enable or remove", "Store links, Firefox Add-ons search, package links and local folders.",
                       pill("Manage Extensions…", symbol: "puzzlepiece.extension", #selector(manageExtensions)),
                       keywords: ["install", "chrome web store", "add-ons"]))
        return [caption(snapshot.profileName + " profile"), list, footer]
    }
    @objc private func manageExtensions() { actions.manageExtensions() }

    // MARK: About

    private func aboutCards() -> [NSView] {
        let hero = NSStackView()
        hero.orientation = .horizontal; hero.alignment = .centerY; hero.spacing = 16
        let icon = NSImageView()
        icon.image = Self.appIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true; icon.layer?.cornerRadius = 16; icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let words = NSStackView()
        words.orientation = .vertical; words.alignment = .leading; words.spacing = 3
        let name = NSTextField(labelWithString: "The browser that goes Bam.")
        name.font = BamType.display(22, weight: .heavy); name.textColor = BamTheme.ink
        let version = NSTextField(labelWithString: snapshot.build.isEmpty ? "Version \(snapshot.version)" : "Version \(snapshot.version) · build \(snapshot.build)")
        version.font = BamType.sans(12.5, weight: .medium); version.textColor = BamTheme.muted
        let blurb = NSTextField(wrappingLabelWithString: "Native, fast, built in Swift on your Mac’s own WebKit. Free, no account. Not affiliated with The Browser Company.")
        blurb.font = BamType.sans(12.5); blurb.textColor = BamTheme.muted; blurb.isSelectable = false
        words.addArrangedSubview(name); words.addArrangedSubview(version); words.addArrangedSubview(blurb)
        words.setCustomSpacing(8, after: version)
        blurb.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        hero.addArrangedSubview(icon); hero.addArrangedSubview(words)
        hero.translatesAutoresizingMaskIntoConstraints = false
        // The changelog's version sticker; its label carries the site's tilt.
        let sticker = BamSticker(snapshot.version.split(separator: ".").prefix(2).joined(separator: "."), diameter: 72)
        let heroRow = NSView(); heroRow.translatesAutoresizingMaskIntoConstraints = false
        heroRow.addSubview(hero); heroRow.addSubview(sticker)
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: heroRow.leadingAnchor, constant: 18),
            hero.trailingAnchor.constraint(equalTo: sticker.leadingAnchor, constant: -14),
            hero.topAnchor.constraint(equalTo: heroRow.topAnchor, constant: 18),
            hero.bottomAnchor.constraint(equalTo: heroRow.bottomAnchor, constant: -18),
            sticker.trailingAnchor.constraint(equalTo: heroRow.trailingAnchor, constant: -18),
            sticker.centerYAnchor.constraint(equalTo: heroRow.centerYAnchor)
        ])
        let heroCard = card(); heroCard.add(heroRow)
        let links = card()
        links.add(row("Replay the welcome", "Pick a color, name a Space, learn the keys.",
                      pill("Welcome to Bam", symbol: "sparkles", #selector(showWelcome))))
        links.add(row("Source code", "Bam is open source.",
                      pill("GitHub", symbol: "chevron.left.forwardslash.chevron.right", #selector(openGitHub)), keywords: ["github"]))
        links.add(row("Website", "Releases and the changelog.", pill("bambrowser.com", symbol: "safari", #selector(openSite)),
                      keywords: ["changelog", "updates", "version"]))
        return [heroCard, caption("Links"), links]
    }
    @objc private func showWelcome() { actions.showWelcome() }
    @objc private func openGitHub() { actions.openURL(Self.githubURL) }
    @objc private func openSite() { actions.openURL(Self.siteURL) }

    // MARK: Finding a setting

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces) }
    private var searchIndex: [SettingsSearchHit]?
    private var results: [SettingsSearchHit] = []

    func focusSearch() { window.makeFirstResponder(searchField) }
    private func clearSearch() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
    }
    @objc private func searchChanged() {
        for (key, button) in railButtons { button.isPicked = key == section && query.isEmpty }
        render()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    /// Return goes to the first result; Escape clears the field (and a second Escape closes Settings).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)), let first = results.first { go(to: first); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)), !searchField.stringValue.isEmpty {
            searchField.stringValue = ""; searchChanged(); return true
        }
        return false
    }

    /// Every row of every section, read from the sections themselves so the index can't drift
    /// from what is shown, plus every menu command's shortcut.
    func buildSearchIndex() -> [SettingsSearchHit] {
        if let searchIndex { return searchIndex }
        var hits: [SettingsSearchHit] = []
        func rows(in view: NSView) -> [BamRow] { (view as? BamRow).map { [$0] } ?? view.subviews.flatMap(rows) }
        let builders: [(SettingsSection, () -> [NSView])] = [
            (.general, generalCards), (.appearance, appearanceCards), (.websites, websitesCards), (.privacy, privacyCards),
            (.search, searchCards), (.spaces, spacesCards), (.links, linksCards), (.extensions, extensionsCards), (.about, aboutCards)
        ]
        for (section, cards) in builders {
            for row in cards().flatMap(rows) where !row.title.hasPrefix("No ") {
                hits.append(SettingsSearchHit(section: section, title: row.title,
                                              detail: ([row.detail ?? ""] + row.keywords).joined(separator: " ")))
            }
        }
        for command in ShortcutStore.shared.catalog where !command.menu.isEmpty {
            hits.append(SettingsSearchHit(section: .shortcuts, title: command.title, detail: command.menu, shortcutID: command.id))
        }
        searchIndex = hits
        return hits
    }
    /// Titles first, then words in a row's description or keywords; shortcuts also by their keys.
    func search(_ text: String) -> [SettingsSearchHit] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let index = buildSearchIndex()
        var titled: [SettingsSearchHit] = [], described: [SettingsSearchHit] = [], keyed: [SettingsSearchHit] = []
        for hit in index {
            let title = (hit.title + " " + hit.section.title).lowercased()
            if words.allSatisfy({ title.contains($0) }) { titled.append(hit); continue }
            let all = title + " " + (hit.detail ?? "").lowercased()
            if words.allSatisfy({ all.contains($0) }) { described.append(hit); continue }
            if let id = hit.shortcutID, ShortcutStore.shared.combo(forID: id)?.matches(text) == true { keyed.append(hit) }
        }
        return titled + described + keyed
    }
    private func renderResults() {
        results = search(query)
        // Sections were built to read them; their weak references now point at nothing on screen.
        appearanceChips = nil
        addHeading("Results", results.isEmpty ? "Nothing matches “\(query)”." : "Return opens the first. Click one to go to it.")
        var bySection: [(SettingsSection, [SettingsSearchHit])] = []
        for hit in results.prefix(60) {
            if let index = bySection.firstIndex(where: { $0.0 == hit.section }) { bySection[index].1.append(hit) }
            else { bySection.append((hit.section, [hit])) }
        }
        var views: [NSView] = []
        for (section, hits) in bySection {
            let group = card()
            for hit in hits {
                let result = SettingsResultRow(hit: hit)
                result.onPress = { [weak self] in self?.go(to: hit) }
                group.add(result)
            }
            views += [caption(section.title), group]
        }
        add(views)
    }
    /// Opens the hit's section, scrolls its row to the middle and flashes it.
    func go(to hit: SettingsSearchHit) {
        clearSearch()
        select(hit.section)
        column.superview?.layoutSubtreeIfNeeded()
        func rows(in view: NSView) -> [BamRow] { (view as? BamRow).map { [$0] } ?? view.subviews.flatMap(rows) }
        let target: BamRow?
        if let id = hit.shortcutID { target = shortcutLines.first { $0.command.id == id }?.row }
        else { target = rows(in: column).first { $0.title == hit.title } }
        guard let target, let document = scroll.documentView else { return }
        let frame = target.convert(target.bounds, to: document)
        let visible = scroll.contentView.bounds.height
        let y = max(0, min(frame.midY - visible / 2, document.bounds.height - visible))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        target.flash()
        // Keyboard users land on the row's control.
        func focusable(_ view: NSView) -> NSView? {
            if !(view is NSTextField && !(view as! NSTextField).isEditable), view !== target, view.acceptsFirstResponder { return view }
            for sub in view.subviews { if let found = focusable(sub) { return found } }
            return nil
        }
        if let control = focusable(target) { window.makeFirstResponder(control) }
    }
}

/// An uppercase caption over a card.
@MainActor final class SettingsCaption: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: BamType.sans(10.5, weight: .bold), .foregroundColor: BamTheme.muted, .kern: 0.8
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let text = attributedStringValue.string
        attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: BamType.sans(10.5, weight: .bold), .foregroundColor: BamTheme.muted, .kern: 0.8
        ])
    }
}

/// A row of compact chips where one is picked. Picking re-paints in place, so keyboard focus stays.
@MainActor final class SettingsChipGroup: NSStackView {
    var onPick: ((Int) -> Void)?
    private(set) var chips: [BamChip] = []
    init(titles: [String], picked: Int?, accent: NSColor, label: String, dots: [NSColor]? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 6
        for (index, title) in titles.enumerated() {
            let chip = BamChip(title: title, dot: dots?[index], compact: true)
            chip.accent = accent; chip.isPicked = index == picked; chip.tag = index
            chip.setAccessibilityLabel("\(title) \(label)")
            chip.target = self; chip.action = #selector(choose(_:))
            chips.append(chip); addArrangedSubview(chip)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func pick(_ index: Int?) { for chip in chips { chip.isPicked = chip.tag == index } }
    @objc private func choose(_ sender: BamChip) {
        pick(sender.tag)
        onPick?(sender.tag)
    }
}

/// A small borderless symbol button for a row (remove a site, a shortcut's menu).
@MainActor final class SettingsIconButton: NSButton {
    var onPress: (() -> Void)?
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false; title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        imageScaling = .scaleNone
        contentTintColor = BamTheme.muted
        setAccessibilityLabel(label); toolTip = label
        target = self; action = #selector(press)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func press() { onPress?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); contentTintColor = BamTheme.muted }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { contentTintColor = isHighlighted ? BamTheme.red : BamTheme.muted } }
}

/// A quiet pill with up-down chevrons that opens a menu of choices.
@MainActor final class SettingsMenuPill: NSView {
    var onPress: (() -> Void)?
    private let pill: BamPillButton
    init(title: String) {
        pill = BamPillButton(title: title, symbol: "chevron.up.chevron.down", compact: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pill.imagePosition = .imageTrailing
        pill.target = self; pill.action = #selector(press)
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor), pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor), pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func press() { onPress?() }
    override func setAccessibilityLabel(_ label: String?) { pill.setAccessibilityLabel(label) }
    override func setAccessibilityValue(_ value: Any?) { pill.setAccessibilityValue(value) }
}

/// One Air Traffic Control route, laid out like Arc's: "URL [Contains] [text] (−)" over
/// "↳ Open in [Space]". The controller supplies the two menus and handles every change.
@MainActor final class SettingsRouteRow: NSView {
    var matchMenu: NSView?
    var destinationMenu: NSView?
    var onText: ((String) -> Void)?
    var onRemove: (() -> Void)?
    let field: BamTextField
    private let position: Int
    init(route: LinkRoute, position: Int) {
        self.position = position
        field = BamTextField(string: route.text, placeholder: "figma.com")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel("Route \(position) text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func build() {
        func label(_ text: String, _ symbol: String) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!)
            icon.contentTintColor = BamTheme.muted
            let words = NSTextField(labelWithString: text); words.font = BamType.sans(12.5, weight: .semibold); words.textColor = BamTheme.muted
            let stack = NSStackView(views: [icon, words]); stack.spacing = 5
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalToConstant: 72).isActive = true
            return stack
        }
        field.onCommit = { [weak self] text in self?.onText?(text); return true }
        let remove = SettingsIconButton(symbol: "minus.circle", label: "Remove route \(position)")
        remove.onPress = { [weak self] in self?.onRemove?() }
        let top = NSStackView(views: [label("URL", "link"), matchMenu ?? NSView(), field, remove])
        top.spacing = 8; top.alignment = .centerY
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [label("Open in", "arrow.turn.down.right"), destinationMenu ?? NSView()])
        bottom.spacing = 8; bottom.alignment = .centerY
        let stack = NSStackView(views: [top, bottom]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityElement(false)
    }
}

/// A closure as a menu item's target; the item keeps it alive through representedObject.
@MainActor final class SettingsMenuAction: NSObject {
    let work: () -> Void
    init(_ work: @escaping () -> Void) { self.work = work }
    @objc func run(_ sender: Any?) { work() }
}

/// One search result: the row's title, where it lives, and (for a command) its keys.
@MainActor final class SettingsResultRow: NSButton {
    var onPress: (() -> Void)?
    let hit: SettingsSearchHit
    init(hit: SettingsSearchHit) {
        self.hit = hit
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true
        setButtonType(.momentaryChange)
        target = self; action = #selector(press)
        let name = NSTextField(labelWithString: hit.title)
        name.font = BamType.sans(13.5, weight: .semibold); name.textColor = BamTheme.ink
        name.lineBreakMode = .byTruncatingTail
        let place = NSTextField(labelWithString: hit.shortcutID != nil ? "Shortcuts › \(hit.detail ?? "")" : hit.section.title)
        place.font = BamType.sans(12); place.textColor = BamTheme.muted
        place.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, place]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        var trailing: NSView
        if let id = hit.shortcutID {
            trailing = BamKeycap(ShortcutStore.shared.combo(forID: id)?.display ?? "—")
        } else {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!)
            chevron.contentTintColor = BamTheme.muted
            trailing = chevron
        }
        for view in [text, trailing] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel("\(hit.title), in \(hit.section.title)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func press() { onPress?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { layer?.backgroundColor = bamCG(isHighlighted ? BamTheme.redWash : .clear) } }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
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
        layer?.cornerRadius = 8
        icon.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.imageScaling = .scaleNone
        label.stringValue = section.title
        label.lineBreakMode = .byTruncatingTail
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(section.title) settings")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
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
        label.font = BamType.sans(13.5, weight: isPicked ? .bold : .medium)
        label.textColor = isPicked ? BamTheme.ink : BamTheme.muted
        icon.contentTintColor = isPicked ? accent : BamTheme.muted
        layer?.backgroundColor = bamCG(isPicked ? BamTheme.card : NSColor.clear)
        layer?.borderWidth = isPicked ? 1 : 0
        layer?.borderColor = bamCG(BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.8 : 1 } }
}

/// One line per Space: its tile, its name and whether it is the one on screen.
/// Clicking it hands the Space to the editor below.
@MainActor final class SpaceListRow: NSButton {
    let spaceID: Int
    private let tile = SpaceTile(size: 26, pointSize: 12)
    private let name = NSTextField(labelWithString: "")
    private let badge = BamBadge("Current")
    private let chevron = NSImageView()
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }

    init(space: BrowserSpace, isCurrent: Bool) {
        spaceID = space.id
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 9
        tile.show(space)
        name.stringValue = space.name
        name.font = BamType.sans(13.5, weight: .semibold)
        name.textColor = BamTheme.ink
        name.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        chevron.contentTintColor = BamTheme.muted
        badge.isHidden = !isCurrent
        for view in [tile, name, badge, chevron] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
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
    /// The Space this swatch colors, when a row shows one per Space (Appearance › Space colors).
    var spaceID: Int?
    private let ring = CALayer()
    var isPicked = false { didSet { ring.borderWidth = isPicked ? 2 : 0; setAccessibilityValue(isPicked ? "Selected" : "") } }
    init(colorIndex: Int, diameter: CGFloat = 26) {
        self.colorIndex = colorIndex
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        setButtonType(.momentaryChange)
        if colorIndex == BrowserSpace.prismColorIndex {
            let rainbow = CAGradientLayer()
            rainbow.colors = (0..<6).map { NSColor(calibratedHue: CGFloat($0) / 6, saturation: 0.55, brightness: 0.88, alpha: 1).cgColor }
            rainbow.startPoint = CGPoint(x: 0, y: 1); rainbow.endPoint = CGPoint(x: 1, y: 0)
            rainbow.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter); rainbow.cornerRadius = diameter / 2
            layer?.insertSublayer(rainbow, at: 0)
        } else if colorIndex == BrowserSpace.clearColorIndex {
            layer?.borderWidth = 1.5
        } else {
            layer?.backgroundColor = ArkPalette.spaceColor(colorIndex).cgColor
        }
        layer?.cornerRadius = diameter / 2
        ring.cornerRadius = diameter / 2 + 3
        ring.frame = NSRect(x: -3, y: -3, width: diameter + 6, height: diameter + 6)
        layer?.addSublayer(ring)
        layer?.masksToBounds = false
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, colorIndex)]) color")
        toolTip = BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, colorIndex)]
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
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
