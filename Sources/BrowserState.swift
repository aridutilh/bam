import Foundation

enum SavedTabKind: String, Codable { case kept, favorite }

struct SavedTabState: Codable, Equatable {
    var kind: SavedTabKind
    var address: String
    var customTitle: String?
    var customSymbol: String?
    var isUnloaded: Bool
    // Favorites belong to a login profile independently of their old home Space.
    var profileID: UUID?

    init(kind: SavedTabKind, address: String, customTitle: String? = nil,
         customSymbol: String? = nil, isUnloaded: Bool = false, profileID: UUID? = nil) {
        self.kind = kind; self.address = address; self.customTitle = customTitle
        self.customSymbol = customSymbol; self.isUnloaded = isUnloaded; self.profileID = profileID
    }
    private enum CodingKeys: String, CodingKey { case kind, address, customTitle, customSymbol, isUnloaded, profileID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(SavedTabKind.self, forKey: .kind)
        address = try values.decode(String.self, forKey: .address)
        customTitle = try? values.decodeIfPresent(String.self, forKey: .customTitle)
        customSymbol = try? values.decodeIfPresent(String.self, forKey: .customSymbol)
        isUnloaded = (try? values.decodeIfPresent(Bool.self, forKey: .isUnloaded)) ?? false
        profileID = values.contains(.profileID) ? try values.decode(UUID.self, forKey: .profileID) : nil
        if profileID == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) {
            throw DecodingError.dataCorruptedError(forKey: .profileID, in: values, debugDescription: "Invalid profile identifier")
        }
    }
}

/// Memory sleeping resumes the current page; it is distinct from closing a
/// saved tab, which resets that tab to its original saved address.
struct TabSleepState: Codable, Equatable {
    var address: String
    var scrollX: Double
    var scrollY: Double

    fileprivate func matches(_ currentAddress: String) -> Bool {
        address == currentAddress && URLInput.directURL(address) != nil
            && scrollX.isFinite && scrollY.isFinite
            && abs(scrollX) <= 10_000_000 && abs(scrollY) <= 10_000_000
    }
}

struct BrowserTab: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var address: String
    var space: Int
    var saved: SavedTabState?
    var sleepState: TabSleepState?
    /// The kept-section folder holding this tab. Only kept tabs live in folders;
    /// Favorites and ordinary (Today) tabs are always at their section root.
    var folderID: UUID?
    /// When this tab was last the visible one (wall clock, saved with the session). Auto-archive
    /// closes Today tabs that haven't been viewed for the chosen time; nil means "not seen yet".
    var lastViewedAt: Date?

    init(id: UUID = UUID(), title: String, address: String, space: Int,
         pinned: Bool = false, saved: SavedTabState? = nil, sleepState: TabSleepState? = nil, folderID: UUID? = nil) {
        self.id = id; self.title = title; self.address = address; self.space = space
        self.saved = saved ?? (pinned ? SavedTabState(kind: .kept, address: address) : nil)
        self.sleepState = sleepState; self.folderID = folderID
    }
    var pinned: Bool {
        get { saved != nil }
        set {
            if !newValue { saved = nil }
            else if saved == nil { saved = SavedTabState(kind: .kept, address: address) }
        }
    }
    var isFavorite: Bool { saved?.kind == .favorite }
    var isSaved: Bool { saved != nil }
    var isUnloaded: Bool { saved?.isUnloaded == true }
    var isSleeping: Bool { sleepState != nil }
    var displayTitle: String { saved?.customTitle ?? title }
    var isHome: Bool { address == "orbit://newtab" }
    var isVideoDemo: Bool { address == "orbit://video" }
    /// A row kept in place of an Arc Easel; it has no web page.
    var isArcEasel: Bool { ArcEaselReference.isReference(address) }
    /// What the address bar shows when it isn't being edited: the site's host,
    /// or a plain name for Bam's own reference rows. Editing still starts from
    /// `address`, which is unchanged.
    var addressLabel: String {
        if isArcEasel { return "Arc Easel" }
        return URL(string: address)?.host ?? address
    }
    var symbol: String {
        if let symbol = saved?.customSymbol { return symbol }
        if isHome { return "sparkle" }
        if isVideoDemo { return "play.rectangle.fill" }
        if isArcEasel { return "scribble.variable" }
        if address.contains("developer.apple.com") { return "apple.logo" }
        if address.contains("github.com") { return "chevron.left.forwardslash.chevron.right" }
        if address.contains("wikipedia.org") { return "book.closed" }
        return "globe"
    }
    /// A one-character mark shown instead of the generic globe, so pages
    /// without an icon yet are still told apart. Nil when a custom or
    /// special symbol applies (those, and real favicons, always win).
    var monogram: String? {
        guard saved?.customSymbol == nil, symbol == "globe" else { return nil }
        return Monogram.make(title: displayTitle, address: address)
    }
    static func validAddress(_ address: String) -> Bool {
        address == "orbit://newtab" || address == "orbit://video" || URLInput.directURL(address) != nil || URLInput.extensionURL(address) != nil
            || ArcEaselReference.isReference(address)
    }
    fileprivate static func validCustomTitle(_ title: String) -> Bool {
        title.count <= 80 && !title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private enum CodingKeys: String, CodingKey { case id, title, address, space, pinned, saved, sleepState, folderID, lastViewedAt }
    private enum SavedProfileKeys: String, CodingKey { case profileID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        address = try values.decode(String.self, forKey: .address)
        space = try values.decode(Int.self, forKey: .space)
        // Other malformed optional retention metadata remains recoverable, but
        // a corrupt profile binding must not silently become a personal tab.
        var hasProfileBinding = false
        if let binding = try? values.nestedContainer(keyedBy: SavedProfileKeys.self, forKey: .saved), binding.contains(.profileID) {
            hasProfileBinding = true
            let id = try binding.decode(UUID.self, forKey: .profileID)
            if id == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) {
                throw DecodingError.dataCorruptedError(forKey: .saved, in: values, debugDescription: "Invalid saved profile identifier")
            }
        }
        if hasProfileBinding { saved = try values.decodeIfPresent(SavedTabState.self, forKey: .saved) }
        else { saved = try? values.decodeIfPresent(SavedTabState.self, forKey: .saved) }
        sleepState = try? values.decodeIfPresent(TabSleepState.self, forKey: .sleepState)
        folderID = try? values.decodeIfPresent(UUID.self, forKey: .folderID)
        lastViewedAt = (try? values.decodeIfPresent(Date.self, forKey: .lastViewedAt)).flatMap { $0?.timeIntervalSince1970.isFinite == true ? $0 : nil }
        if saved == nil, (try? values.decodeIfPresent(Bool.self, forKey: .pinned)) == true {
            saved = SavedTabState(kind: .kept, address: address)
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(title, forKey: .title)
        try values.encode(address, forKey: .address); try values.encode(space, forKey: .space)
        try values.encode(pinned, forKey: .pinned)
        try values.encodeIfPresent(saved, forKey: .saved)
        try values.encodeIfPresent(sleepState, forKey: .sleepState)
        try values.encodeIfPresent(folderID, forKey: .folderID)
        try values.encodeIfPresent(lastViewedAt, forKey: .lastViewedAt)
    }
}

/// A named, collapsible group in a Space's kept section. Folders nest; stable
/// IDs survive renames and moves. Child order lives in `childOrder`, which may
/// list both tab and folder IDs and is repaired against actual membership.
struct BrowserFolder: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var space: Int
    var parentID: UUID?
    var isCollapsed: Bool
    var childOrder: [UUID]

    init(id: UUID = UUID(), name: String, space: Int, parentID: UUID? = nil, isCollapsed: Bool = false, childOrder: [UUID] = []) {
        self.id = id; self.name = name; self.space = space; self.parentID = parentID
        self.isCollapsed = isCollapsed; self.childOrder = childOrder
    }
    private enum CodingKeys: String, CodingKey { case id, name, space, parentID, isCollapsed, childOrder }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = (try? values.decode(String.self, forKey: .name)) ?? "Folder"
        space = try values.decode(Int.self, forKey: .space)
        parentID = try? values.decodeIfPresent(UUID.self, forKey: .parentID)
        isCollapsed = (try? values.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
        childOrder = (try? values.decodeIfPresent([UUID].self, forKey: .childOrder)) ?? []
    }
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

private struct LossyFolder: Decodable {
    let value: BrowserFolder?
    init(from decoder: Decoder) throws { value = try? BrowserFolder(from: decoder) }
}

/// One row of a Space's kept hierarchy, in display (depth-first) order.
struct KeptLayoutEntry: Equatable {
    let id: UUID
    let isFolder: Bool
    let depth: Int
    let parentID: UUID?
}

struct BrowserSplit: Codable, Equatable {
    var primaryID: UUID
    var secondaryID: UUID
}

/// The reserved default ID always maps to WebKit's existing default data store.
struct BrowserProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaults = [BrowserProfile(id: defaultID, name: "Default")]
}

/// IDs remain stable as the user reorders Spaces; their array position is only
/// presentation order. Existing sessions retain IDs 0, 1, and 2.
/// A Space's own colors, imported from an Arc window theme. Optional and
/// additive: Spaces without one, and every older session, use the flat
/// `colorIndex` color, which a themed Space also keeps as its fallback.
/// Bam draws its own gradient from these values; Arc's grain, noise and
/// vibrancy aren't reproduced.
struct SpaceTheme: Codable, Hashable {
    /// One color, sRGB components. Only finite values within 0…1 are kept.
    struct RGBA: Codable, Hashable {
        var red: Double, green: Double, blue: Double, alpha: Double
        init?(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && $0 >= -0.0005 && $0 <= 1.0005 }) else { return nil }
            func unit(_ value: Double) -> Double { min(1, max(0, value)) }
            self.red = unit(red); self.green = unit(green); self.blue = unit(blue); self.alpha = unit(alpha)
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let color = RGBA(red: try values.decode(Double.self, forKey: .red), green: try values.decode(Double.self, forKey: .green),
                                   blue: try values.decode(Double.self, forKey: .blue), alpha: try values.decode(Double.self, forKey: .alpha)) else {
                throw DecodingError.dataCorruptedError(forKey: .red, in: values, debugDescription: "Color component out of range")
            }
            self = color
        }
        private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }
        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func contrast(with other: RGBA) -> Double {
            let a = luminance, b = other.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        /// This color moved `fraction` of the way to `other`, opaque.
        func mixed(toward other: RGBA, by fraction: Double) -> RGBA {
            let t = min(1, max(0, fraction))
            return RGBA(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
                        blue: blue + (other.blue - blue) * t, alpha: 1)!
        }
    }
    /// Colors for one appearance (Arc's light or dark semantic palette).
    struct Roles: Codable, Hashable {
        var background: RGBA
        var backgroundExtra: RGBA?
        /// Main text color; the window gradient keeps readable contrast with it.
        var title: RGBA
        var subtitle: RGBA?
    }
    /// The window's own one or two gradient colors; empty means "use the
    /// appearance's background colors".
    var gradient: [RGBA]
    var light: Roles
    var dark: Roles
    /// Arc's primary palette: the Space's accent and its light/dark variants.
    var accent: RGBA
    var accentLight: RGBA?
    var accentDark: RGBA?

    init?(gradient: [RGBA], light: Roles, dark: Roles, accent: RGBA, accentLight: RGBA? = nil, accentDark: RGBA? = nil) {
        guard gradient.count <= 2 else { return nil }
        self.gradient = gradient; self.light = light; self.dark = dark
        self.accent = accent; self.accentLight = accentLight; self.accentDark = accentDark
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gradient = try values.decode([RGBA].self, forKey: .gradient)
        guard gradient.count <= 2 else { throw DecodingError.dataCorruptedError(forKey: .gradient, in: values, debugDescription: "Too many gradient colors") }
        light = try values.decode(Roles.self, forKey: .light); dark = try values.decode(Roles.self, forKey: .dark)
        accent = try values.decode(RGBA.self, forKey: .accent)
        accentLight = try? values.decodeIfPresent(RGBA.self, forKey: .accentLight)
        accentDark = try? values.decodeIfPresent(RGBA.self, forKey: .accentDark)
    }
    private enum CodingKeys: String, CodingKey { case gradient, light, dark, accent, accentLight, accentDark }

    /// Bam's sidebar text (`BamInk`) needs at least these contrasts with every
    /// gradient color: main text and secondary text.
    static let minimumInkContrast = 7.0
    static let minimumSecondaryContrast = 4.5
    /// The two window gradient colors for one appearance, or nil when this
    /// theme can't be made readable there (the window then uses Bam's own
    /// flat Space color for that appearance). Arc's colors are eased toward
    /// the appearance's background (a little in light, a lot in dark) and
    /// further until Bam's actual sidebar ink reads over them.
    func canvasStops(dark isDark: Bool) -> [RGBA]? {
        let roles = isDark ? dark : light
        let base: [RGBA]
        switch gradient.count {
        case 0: base = [roles.background, roles.backgroundExtra ?? roles.background]
        case 1: base = [gradient[0], gradient[0]]
        default: base = Array(gradient.prefix(2))
        }
        let primary = BamInk.primary(dark: isDark), secondary = BamInk.secondary(dark: isDark)
        func readable(_ color: RGBA) -> Bool {
            color.contrast(with: primary) >= Self.minimumInkContrast && color.contrast(with: secondary) >= Self.minimumSecondaryContrast
        }
        let start = isDark ? 0.7 : 0.25
        var stops: [RGBA] = []
        for stop in base {
            var amount = start
            var color = stop.mixed(toward: roles.background, by: amount)
            while !readable(color), amount < 1 {
                amount = min(1, amount + 0.05); color = stop.mixed(toward: roles.background, by: amount)
            }
            guard readable(color) else { return nil }
            stops.append(color)
        }
        return stops
    }
    /// Icons need at least this contrast with the window behind them.
    static let minimumIconContrast = 3.0
    /// The Space's accent (selected icons, Space icon) for one appearance:
    /// Arc's lighter variant in dark, its shaded variant in light, moved toward
    /// Bam's ink until it stands out from the gradient. Nil when the window
    /// uses the flat Space color there (the flat tint then applies too).
    func accent(dark isDark: Bool) -> RGBA? {
        guard let behind = canvasStops(dark: isDark) else { return nil }
        let base = (isDark ? accentLight : accentDark) ?? accent
        let ink = BamInk.primary(dark: isDark)
        func worst(_ color: RGBA) -> Double { behind.map { color.contrast(with: $0) }.min() ?? 21 }
        var amount = 0.0, color = base.mixed(toward: ink, by: 0)
        while worst(color) < Self.minimumIconContrast, amount < 1 {
            amount = min(1, amount + 0.05); color = base.mixed(toward: ink, by: amount)
        }
        return worst(color) >= Self.minimumIconContrast ? color : nil
    }
}

/// The mark for a page with no icon: the first letter, number or emoji of its
/// title, or of its host (without "www.") when the title is empty or is just
/// the address. Letters are uppercased.
enum Monogram {
    static func make(title: String, address: String) -> String? {
        // Only web addresses lend their host; Bam's own orbit:// pages don't.
        let url = URL(string: address)
        let host = ["http", "https"].contains(url?.scheme?.lowercased() ?? "") ? url?.host.map { $0.lowercased().hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } : nil
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != address, text.lowercased() != host?.lowercased(), let mark = first(in: text) { return mark }
        return host.flatMap(first(in:))
    }
    private static func first(in text: String) -> String? {
        for character in text {
            let emoji = isEmoji(character)
            guard character.isLetter || character.isNumber || emoji else { continue }
            if emoji { return String(character) }
            let upper = String(character).uppercased()
            return upper.count == 1 ? upper : String(character)
        }
        return nil
    }
    /// Whether a whole grapheme displays as an emoji: emoji-presentation
    /// scalars, or emoji-capable ones made emoji by VS16 (❤️), a keycap (1️⃣)
    /// or a ZWJ sequence. A plain digit or "#" alone stays text.
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        guard scalars.contains(where: { $0.properties.isEmoji }) else { return false }
        return scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 || $0.value == 0x200D }
    }
}

/// Bam's sidebar text colors (gray levels). The sidebar draws with these and
/// imported Space themes are checked against them, so the two can't drift.
enum BamInk {
    static let lightPrimary = 0.11, lightSecondary = 0.38
    static let darkPrimary = 0.94, darkSecondary = 0.73
    static func primary(dark: Bool) -> SpaceTheme.RGBA { gray(dark ? darkPrimary : lightPrimary) }
    static func secondary(dark: Bool) -> SpaceTheme.RGBA { gray(dark ? darkSecondary : lightSecondary) }
    private static func gray(_ level: Double) -> SpaceTheme.RGBA { SpaceTheme.RGBA(red: level, green: level, blue: level)! }
}

struct BrowserSpace: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var symbol: String
    var colorIndex: Int
    var profileID: UUID
    /// An optional emoji icon (Arc-style); when present it is shown instead of the symbol.
    var emoji: String?
    /// Imported Arc colors. Used only with a flat `colorIndex` (which stays the
    /// fallback); choosing another Space color, Prism or Clear removes it.
    var theme: SpaceTheme?

    init(id: Int, name: String, symbol: String, colorIndex: Int, profileID: UUID = BrowserProfile.defaultID, emoji: String? = nil,
         theme: SpaceTheme? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.colorIndex = colorIndex; self.profileID = profileID
        self.emoji = emoji.flatMap(Self.validEmoji)
        self.theme = colorIndex >= 0 && colorIndex < Self.flatColorCount ? theme : nil
    }
    private enum CodingKeys: String, CodingKey { case id, name, symbol, colorIndex, profileID, emoji, theme }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        symbol = try values.decode(String.self, forKey: .symbol); colorIndex = try values.decode(Int.self, forKey: .colorIndex)
        profileID = values.contains(.profileID) ? try values.decode(UUID.self, forKey: .profileID) : BrowserProfile.defaultID
        if profileID == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) {
            throw DecodingError.dataCorruptedError(forKey: .profileID, in: values, debugDescription: "Invalid profile identifier")
        }
        emoji = (try? values.decodeIfPresent(String.self, forKey: .emoji)).flatMap { $0 }.flatMap(Self.validEmoji)
        // A damaged theme falls back to the flat color; it never fails the Space.
        let decodedTheme = (try? values.decodeIfPresent(SpaceTheme.self, forKey: .theme)).flatMap { $0 }
        theme = colorIndex >= 0 && colorIndex < Self.flatColorCount ? decodedTheme : nil
    }
    /// A single emoji grapheme, without text or control characters.
    static func validEmoji(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1, value.unicodeScalars.count <= 16,
              value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.alphanumerics.contains($0) && $0.value < 0x80 })
        else { return nil }
        return value
    }

    static let symbols = ["sparkles", "sun.max", "globe", "briefcase", "house", "heart", "book", "paintbrush", "terminal", "bolt", "leaf", "music.note"]
    /// Prism (a slowly shifting spectrum) and Clear (a translucent window that
    /// shows the desktop) are appearances, not flat colors; their indices are
    /// stable because sessions persist colorIndex.
    static let colorNames = ["Violet", "Sage", "Ocean", "Rose", "Amber", "Graphite", "Prism", "Clear"]
    /// The first six entries are flat colors; the appearances follow them.
    static let flatColorCount = 6
    static let prismColorIndex = flatColorCount
    static let clearColorIndex = flatColorCount + 1
    static let defaults = [
        BrowserSpace(id: 0, name: "Studio", symbol: "sparkles", colorIndex: 0),
        BrowserSpace(id: 1, name: "Life", symbol: "sun.max", colorIndex: 1),
        BrowserSpace(id: 2, name: "Explore", symbol: "globe", colorIndex: 2)
    ]
    static let legacyDefaults = defaults

    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    fileprivate static func normalizedSymbol(_ raw: String) -> String {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return symbols.contains(symbol) ? symbol : "sparkles"
    }
}

struct BrowserSession: Codable {
    var tabs: [BrowserTab]
    var activeID: UUID
    var space: Int
    var sidebarWidth: Double
    var sidebarVisible: Bool
    // Optional so callers and sessions predating per-space selection still work.
    var lastSelectedTabIDsBySpace: [Int: UUID]?
    var splits: [BrowserSplit]?
    var spaces: [BrowserSpace]
    var profiles: [BrowserProfile]
    /// Kept-section folders for every Space. Older sessions have none.
    var folders: [BrowserFolder] = []
    /// Order of root-level kept rows (tabs and folders) per Space. Absent
    /// entries fall back to tab-array order, matching sessions before folders.
    var rootOrder: [Int: [UUID]]?
    /// Provenance of imported items: source key -> local identifier
    /// ("space:<id>", "folder:<uuid>", "tab:<uuid>"). Repeat imports skip
    /// keys already present, even when the user later removed that item.
    var importLinks: [String: String]?
    /// Most recently shown tabs, newest first (Split primaries). Drives ⌃⇥.
    var recentTabIDs: [UUID]?
    /// Link-opened tab → the tab it was opened from. In memory only, like a
    /// browser's opener: it decides where the next link tab goes and which
    /// tab takes over when a link tab closes.
    var openers: [UUID: UUID] = [:]
    /// Closed ordinary tab → the Today row it sat below (nil: top), so a
    /// reopened tab returns to its place. In memory only.
    var closedAnchors: [UUID: ClosedAnchor] = [:]
    struct ClosedAnchor { let space: Int; let after: UUID? }
    // Persist the high-water mark, including deleted Spaces, so tab/archive
    // metadata can never accidentally refer to a different newly created Space.
    private var lastIssuedSpaceID: Int
    static let maximumSpaces = 32
    private static let formatVersion = 5
    static let maximumFavorites = 12
    static let maximumProfiles = 32
    static let maximumFolders = 4000
    static let maximumFolderDepth = 12

    init(tabs: [BrowserTab], activeID: UUID, space: Int = 0,
         sidebarWidth: Double = 228, sidebarVisible: Bool = true,
         lastSelectedTabIDsBySpace: [Int: UUID]? = nil, splits: [BrowserSplit]? = nil,
         spaces: [BrowserSpace] = BrowserSpace.defaults, profiles: [BrowserProfile] = BrowserProfile.defaults) {
        self.tabs = tabs; self.activeID = activeID; self.space = space
        self.sidebarWidth = sidebarWidth; self.sidebarVisible = sidebarVisible
        self.lastSelectedTabIDsBySpace = lastSelectedTabIDsBySpace; self.splits = splits
        self.spaces = spaces; self.profiles = profiles.contains(where: { $0.id == BrowserProfile.defaultID }) ? profiles : BrowserProfile.defaults + profiles
        lastIssuedSpaceID = max(2, spaces.map(\.id).max() ?? 2)
    }

    private enum CodingKeys: String, CodingKey {
        case version, tabs, activeID, space, sidebarWidth, sidebarVisible
        case lastSelectedTabIDsBySpace, splits, spaces, lastIssuedSpaceID, profiles
        case folders, rootOrder, importLinks
        case recentTabIDs = "recentTabs"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.formatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported session version")
        }
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        activeID = try values.decode(UUID.self, forKey: .activeID)
        space = try values.decodeIfPresent(Int.self, forKey: .space) ?? 0
        sidebarWidth = try values.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 228
        sidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        lastSelectedTabIDsBySpace = try values.decodeIfPresent([Int: UUID].self, forKey: .lastSelectedTabIDsBySpace)
        splits = try values.decodeIfPresent([BrowserSplit].self, forKey: .splits)
        spaces = try values.decodeIfPresent([BrowserSpace].self, forKey: .spaces) ?? BrowserSpace.defaults
        profiles = try values.decodeIfPresent([BrowserProfile].self, forKey: .profiles) ?? BrowserProfile.defaults
        // Folder metadata is additive: a damaged folder list must never cost tabs.
        // Decode element by element so one bad record costs only that folder.
        folders = ((try? values.decodeIfPresent([LossyFolder].self, forKey: .folders)).flatMap { $0 } ?? []).compactMap(\.value)
        rootOrder = (try? values.decodeIfPresent([Int: [UUID]].self, forKey: .rootOrder)).flatMap { $0 }
        importLinks = (try? values.decodeIfPresent([String: String].self, forKey: .importLinks)).flatMap { $0 }
        recentTabIDs = (try? values.decodeIfPresent([UUID].self, forKey: .recentTabIDs)).flatMap { $0 }
        lastIssuedSpaceID = max(2, max(try values.decodeIfPresent(Int.self, forKey: .lastIssuedSpaceID) ?? 2,
                                      spaces.map(\.id).max() ?? 2))
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.formatVersion, forKey: .version)
        try values.encode(tabs, forKey: .tabs); try values.encode(activeID, forKey: .activeID)
        try values.encode(space, forKey: .space); try values.encode(sidebarWidth, forKey: .sidebarWidth)
        try values.encode(sidebarVisible, forKey: .sidebarVisible)
        try values.encodeIfPresent(lastSelectedTabIDsBySpace, forKey: .lastSelectedTabIDsBySpace)
        try values.encodeIfPresent(splits, forKey: .splits)
        try values.encode(spaces, forKey: .spaces)
        try values.encode(profiles, forKey: .profiles)
        try values.encode(lastIssuedSpaceID, forKey: .lastIssuedSpaceID)
        if !folders.isEmpty { try values.encode(folders, forKey: .folders) }
        if let rootOrder, !rootOrder.isEmpty { try values.encode(rootOrder, forKey: .rootOrder) }
        if let importLinks, !importLinks.isEmpty { try values.encode(importLinks, forKey: .importLinks) }
        if let recentTabIDs, !recentTabIDs.isEmpty { try values.encode(recentTabIDs, forKey: .recentTabIDs) }
    }

    /// The very first launch of an installed Bam: one tab on bambrowser.com,
    /// so a new user lands on Bam's own page instead of an empty start page.
    /// Fixtures and fresh previews keep `fresh()`, which needs no network.
    static func firstRun() -> BrowserSession {
        let welcome = BrowserTab(title: "Bam", address: "https://bambrowser.com", space: 0)
        return BrowserSession(tabs: [welcome], activeID: welcome.id, lastSelectedTabIDsBySpace: [0: welcome.id])
    }
    static func fresh() -> BrowserSession {
        let home = BrowserTab(title: "New tab", address: "orbit://newtab", space: 0)
        return BrowserSession(tabs: [
            BrowserTab(title: "Apple Developer", address: "https://developer.apple.com", space: 0, pinned: true),
            BrowserTab(title: "GitHub", address: "https://github.com", space: 0, pinned: true), home,
            BrowserTab(title: "New tab", address: "orbit://newtab", space: 1),
            BrowserTab(title: "Wikipedia", address: "https://www.wikipedia.org", space: 2, pinned: true),
            BrowserTab(title: "New tab", address: "orbit://newtab", space: 2)
        ], activeID: home.id, lastSelectedTabIDsBySpace: [0: home.id])
    }
    var active: BrowserTab? { tabs.first { $0.id == activeID } }
    var visibleTabs: [BrowserTab] { orderedTabs(in: space) }
    var currentProfileID: UUID { spaceDefinition(space)?.profileID ?? BrowserProfile.defaultID }
    func profileID(for tab: BrowserTab) -> UUID {
        if tab.isFavorite, let id = tab.saved?.profileID { return id }
        return spaceDefinition(tab.space)?.profileID ?? BrowserProfile.defaultID
    }
    func profileName(_ id: UUID) -> String { profiles.first { $0.id == id }?.name ?? "Default" }
    func spaceID(forProfile id: UUID) -> Int? { spaces.first { $0.profileID == id }?.id }
    func favorites(in profile: UUID) -> [BrowserTab] { tabs.filter { $0.isFavorite && profileID(for: $0) == profile } }
    var favoriteTabs: [BrowserTab] { favorites(in: currentProfileID) }
    @discardableResult mutating func createProfile(name: String, id: UUID = UUID()) -> UUID? {
        guard profiles.count < Self.maximumProfiles, id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
              !profiles.contains(where: { $0.id == id }), let name = BrowserSpace.validName(name),
              !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        profiles.append(BrowserProfile(id: id, name: name)); return id
    }
    @discardableResult mutating func renameProfile(id: UUID, name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }), let name = BrowserSpace.validName(name),
              !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        profiles[index].name = name; return true
    }
    private mutating func bindFavoriteProfiles() {
        for index in tabs.indices where tabs[index].isFavorite && tabs[index].saved?.profileID == nil {
            let id = profileID(for: tabs[index]); tabs[index].saved?.profileID = id
        }
    }
    var spaceIDs: [Int] { spaces.map(\.id) }
    func spaceIndex(_ id: Int) -> Int? { spaces.firstIndex { $0.id == id } }
    func spaceDefinition(_ id: Int) -> BrowserSpace? { spaces.first { $0.id == id } }

    @discardableResult mutating func createSpace(name: String, symbol: String, colorIndex: Int, profileID: UUID = BrowserProfile.defaultID) -> Int? {
        guard profiles.contains(where: { $0.id == profileID }), spaces.count < Self.maximumSpaces, let name = BrowserSpace.validName(name),
              BrowserSpace.colorNames.indices.contains(colorIndex) else { return nil }
        let highWater = max(lastIssuedSpaceID, spaces.map(\.id).max() ?? 2)
        guard highWater < Int.max else { return nil }
        lastIssuedSpaceID = highWater + 1
        spaces.append(BrowserSpace(id: lastIssuedSpaceID, name: name,
                                   symbol: BrowserSpace.normalizedSymbol(symbol), colorIndex: colorIndex, profileID: profileID))
        return lastIssuedSpaceID
    }
    @discardableResult mutating func updateSpace(id: Int, name: String, symbol: String, colorIndex: Int, profileID: UUID? = nil) -> Bool {
        guard let index = spaceIndex(id), let name = BrowserSpace.validName(name),
              BrowserSpace.colorNames.indices.contains(colorIndex) else { return false }
        let profile = profileID ?? spaces[index].profileID
        guard profiles.contains(where: { $0.id == profile }) else { return false }
        bindFavoriteProfiles()
        if profile != spaces[index].profileID {
            for i in tabs.indices where tabs[i].space == id && !tabs[i].isFavorite { tabs[i].sleepState = nil }
        }
        // An imported theme stays while the Space keeps its color; picking another color replaces it.
        let theme = colorIndex == spaces[index].colorIndex ? spaces[index].theme : nil
        spaces[index] = BrowserSpace(id: id, name: name, symbol: BrowserSpace.normalizedSymbol(symbol), colorIndex: colorIndex, profileID: profile,
                                     emoji: spaces[index].emoji, theme: theme)
        repairRememberedSelections(); repairActiveSelection()
        return true
    }
    @discardableResult mutating func setSpaceEmoji(id: Int, emoji: String?) -> Bool {
        guard let index = spaceIndex(id) else { return false }
        if let emoji, BrowserSpace.validEmoji(emoji) == nil { return false }
        spaces[index].emoji = emoji.flatMap(BrowserSpace.validEmoji); return true
    }
    /// Gives a flat-colored Space imported colors (nil removes them).
    @discardableResult mutating func setSpaceTheme(id: Int, theme: SpaceTheme?) -> Bool {
        guard let index = spaceIndex(id), theme == nil || (0..<BrowserSpace.flatColorCount).contains(spaces[index].colorIndex) else { return false }
        spaces[index].theme = theme; return true
    }
    @discardableResult mutating func reorderSpace(id: Int, to index: Int) -> Bool {
        guard let oldIndex = spaceIndex(id), spaces.indices.contains(index) else { return false }
        let definition = spaces.remove(at: oldIndex)
        spaces.insert(definition, at: index)
        return true
    }
    @discardableResult mutating func deleteSpace(id: Int, movingTabsTo destination: Int) -> Bool {
        guard spaces.count > 1, id != destination, let index = spaceIndex(id), spaceDefinition(destination) != nil else { return false }
        bindFavoriteProfiles()
        rememberActiveSelection()
        let oldProfile = spaceDefinition(id)!.profileID
        let newProfile = spaceDefinition(destination)!.profileID
        let remembered = rememberedTab(in: id)
        let wasSelected = space == id
        let carriedRoot = keptChildren(of: .root(id))
        let destinationRoot = keptChildren(of: .root(destination))
        for index in tabs.indices where tabs[index].space == id {
            if !tabs[index].isFavorite && oldProfile != newProfile { tabs[index].sleepState = nil }
            tabs[index].space = destination
        }
        for index in folders.indices where folders[index].space == id { folders[index].space = destination }
        setOrder(destinationRoot + carriedRoot, for: .root(destination))
        rootOrder?[id] = nil
        spaces.remove(at: index)
        lastSelectedTabIDsBySpace?[id] = nil
        repairRememberedSelection(in: destination, preferred: remembered)
        if wasSelected { space = destination }
        repairActiveSelection()
        return true
    }
    /// A split is one movable item. Stable tab IDs let the controller retain the
    /// existing WKWebViews within a profile. The controller reloads cross-profile moves.
    @discardableResult mutating func moveTab(id: UUID, toSpace destination: Int) -> Bool {
        guard spaceDefinition(destination) != nil, let tab = tabs.first(where: { $0.id == id }), !tab.isFavorite else { return false }
        guard tab.space != destination else { return true }
        rememberActiveSelection()
        let group = split(for: id)
        let members = Set(group.map { [$0.primaryID, $0.secondaryID] } ?? [id])
        let movedSelection = members.contains(activeID)
        let crossesProfile = profileID(for: tab) != spaceDefinition(destination)!.profileID
        for index in tabs.indices where members.contains(tabs[index].id) {
            tabs[index].space = destination
            tabs[index].folderID = nil
            if crossesProfile { tabs[index].sleepState = nil }
        }
        repairRememberedSelection(in: tab.space)
        repairRememberedSelection(in: destination, preferred: group?.primaryID ?? id)
        if movedSelection { space = destination }
        repairActiveSelection()
        return true
    }

    /// Whether `setRetention(id:kind: .favorite)` would turn this tab into a new Favorite, by the same rules: not an
    /// extension page, not in a Split, a saveable address (or already saved), room in its profile's Favorites.
    /// Drop targets use it so they only offer what the session will accept.
    func canBecomeFavorite(id: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.isFavorite,
              URLInput.extensionURL(tab.address) == nil, split(for: id) == nil,
              favorites(in: profileID(for: tab)).count < Self.maximumFavorites else { return false }
        return tab.saved != nil || BrowserTab.validAddress(tab.address)
    }
    /// Makes a tab a Favorite (exactly `setRetention`'s rules) and places it just before `anchor`, a Favorite of the
    /// same profile; nil (or any other anchor) puts it after that profile's last Favorite. Favorites are ordered by the
    /// tab list, so only the new Favorite moves: every other tab keeps its relative order, and nothing is added or removed.
    @discardableResult mutating func makeFavorite(id: UUID, before anchor: UUID?) -> Bool {
        guard canBecomeFavorite(id: id), setRetention(id: id, kind: .favorite),
              let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let profile = profileID(for: tabs[from])
        let moved = tabs.remove(at: from)
        if let anchor, let to = tabs.firstIndex(where: { $0.id == anchor && $0.isFavorite && profileID(for: $0) == profile }) {
            tabs.insert(moved, at: to)
        } else if let last = tabs.lastIndex(where: { $0.isFavorite && profileID(for: $0) == profile }) {
            tabs.insert(moved, at: last + 1)
        } else {
            tabs.insert(moved, at: from)   // The first Favorite: nothing to order against.
        }
        return true
    }
    @discardableResult mutating func setRetention(id: UUID, kind: SavedTabKind?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        if kind != nil && URLInput.extensionURL(tabs[index].address) != nil { return false }
        let profile = profileID(for: tabs[index])
        if kind == .favorite {
            guard split(for: id) == nil,
                  tabs[index].isFavorite || favorites(in: profile).count < Self.maximumFavorites else { return false }
        }
        let localDestination = currentProfileID == profile ? space
            : (spaceDefinition(tabs[index].space)?.profileID == profile ? tabs[index].space : spaceID(forProfile: profile))
        if tabs[index].isFavorite && kind != .favorite && (localDestination == nil || currentProfileID != profile) { return false }
        rememberActiveSelection()
        let wasFavorite = tabs[index].isFavorite
        if let kind {
            if tabs[index].saved == nil {
                guard BrowserTab.validAddress(tabs[index].address) else { return false }
                tabs[index].saved = SavedTabState(kind: kind, address: tabs[index].address)
            } else { tabs[index].saved?.kind = kind }
        } else { tabs[index].saved = nil }
        if kind == .favorite { tabs[index].saved?.profileID = profile }
        else { tabs[index].saved?.profileID = nil }
        if kind != .kept { tabs[index].folderID = nil }
        alignSplitFolders()
        if wasFavorite && kind != .favorite { tabs[index].space = localDestination! }
        repairRememberedSelections()
        repairActiveSelection()
        return true
    }
    @discardableResult mutating func resetSavedTab(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let saved = tabs[index].saved,
              BrowserTab.validAddress(saved.address) else { return false }
        tabs[index].address = saved.address
        tabs[index].saved?.isUnloaded = false
        tabs[index].sleepState = nil
        return true
    }
    @discardableResult mutating func updateSavedTab(id: UUID, customTitle: String?, customSymbol: String?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isSaved else { return false }
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = customSymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.map(BrowserTab.validCustomTitle) ?? true,
              symbol.map({ $0.isEmpty || BrowserSpace.symbols.contains($0) }) ?? true else { return false }
        tabs[index].saved?.customTitle = title?.isEmpty == false ? title : nil
        tabs[index].saved?.customSymbol = symbol?.isEmpty == false ? symbol : nil
        return true
    }
    @discardableResult mutating func reorderSavedTab(id: UUID, by offset: Int) -> Bool {
        let primaryID = split(for: id)?.primaryID ?? id
        guard let source = tabs.first(where: { $0.id == primaryID }), let kind = source.saved?.kind else { return false }
        if kind == .kept { return reorderKeptItem(id: primaryID, by: offset) }
        let secondaryIDs = Set((splits ?? []).map(\.secondaryID))
        let candidates = tabs.indices.filter {
            !secondaryIDs.contains(tabs[$0].id) && tabs[$0].saved?.kind == kind
                && (kind == .favorite ? profileID(for: tabs[$0]) == profileID(for: source) : tabs[$0].space == source.space)
        }
        guard let current = candidates.firstIndex(where: { tabs[$0].id == primaryID }) else { return false }
        let (target, overflow) = current.addingReportingOverflow(offset)
        guard !overflow, candidates.indices.contains(target) else { return false }
        // Only primary positions determine row order. Secondary identities and
        // the pair itself remain intact even when a saved split row is moved.
        tabs.swapAt(candidates[current], candidates[target])
        return true
    }
    private func orderedTabs(in space: Int) -> [BrowserTab] {
        let grouped = Set((splits ?? []).map(\.secondaryID))
        let local = tabs.filter { $0.space == space && !$0.isFavorite && !grouped.contains($0.id) }
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = keptLayout(in: space).compactMap { $0.isFolder ? nil : byID[$0.id] }
        return favorites(in: spaceDefinition(space)?.profileID ?? BrowserProfile.defaultID) + kept + local.filter { !$0.isSaved }
    }
    private func selectable(_ tab: BrowserTab, in space: Int) -> Bool {
        !tab.isUnloaded && (tab.isFavorite ? profileID(for: tab) == spaceDefinition(space)?.profileID : tab.space == space)
    }
    private func fallbackTab(in space: Int, last: Bool = false) -> UUID? {
        let visible = orderedTabs(in: space).filter { !$0.isUnloaded }
        // A blank New Tab placeholder has no sidebar row: any real tab is a better landing.
        let pages = visible.filter { !$0.isSaved && !$0.isHome }
        let ordinary = pages.isEmpty ? visible.filter { !$0.isSaved } : pages
        let kept = visible.filter { $0.isSaved && !$0.isFavorite }
        let preferred = !ordinary.isEmpty ? ordinary : !kept.isEmpty ? kept : visible
        return (last ? preferred.last : preferred.first)?.id
    }
    private func rememberedTab(in space: Int) -> UUID? {
        guard let id = lastSelectedTabIDsBySpace?[space],
              let tab = tabs.first(where: { $0.id == id }), selectable(tab, in: space) else { return nil }
        return split(for: id)?.primaryID ?? id
    }
    private mutating func rememberActiveSelection() {
        guard let tab = active, selectable(tab, in: space), spaceDefinition(space) != nil else { return }
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        let selectedID = split(for: tab.id)?.primaryID ?? tab.id
        let context = tab.isFavorite ? space : tab.space
        lastSelectedTabIDsBySpace?[context] = selectedID
    }
    private mutating func repairRememberedSelection(in id: Int, preferred: UUID? = nil) {
        guard spaceDefinition(id) != nil else { lastSelectedTabIDsBySpace?[id] = nil; return }
        if let remembered = rememberedTab(in: id) {
            lastSelectedTabIDsBySpace?[id] = remembered
            return
        }
        let preferred = preferred.flatMap { candidate in
            tabs.first(where: { $0.id == candidate && selectable($0, in: id) })?.id
        }
        let replacement = preferred ?? fallbackTab(in: id, last: true)
        if lastSelectedTabIDsBySpace == nil { lastSelectedTabIDsBySpace = [:] }
        lastSelectedTabIDsBySpace?[id] = replacement
    }
    private mutating func repairRememberedSelections() {
        for id in Array((lastSelectedTabIDsBySpace ?? [:]).keys) { repairRememberedSelection(in: id) }
    }
    private mutating func repairActiveSelection() {
        if let selected = active, !selected.isUnloaded,
           (selected.isFavorite ? profileID(for: selected) == currentProfileID : spaceDefinition(selected.space) != nil) {
            activeID = split(for: selected.id)?.primaryID ?? selected.id
            if !selected.isFavorite { space = selected.space }
            rememberActiveSelection()
        } else {
            if spaceDefinition(space) == nil { space = spaces[0].id }
            if let id = rememberedTab(in: space) ?? fallbackTab(in: space, last: true) { activeID = id; rememberActiveSelection() }
            else { add() }
        }
    }
    /// New tabs open at the top of Today, as in Arc. `opener` (a link opened
    /// from a page) places the tab just after its opener and the tabs already
    /// opened from it, in open order.
    @discardableResult mutating func add(address: String = "orbit://newtab", title: String? = nil, opener: UUID? = nil) -> UUID {
        rememberActiveSelection()
        let defaultTitle = address == "orbit://newtab" ? "New tab" : address == "orbit://video" ? "Picture in Picture demo" : URL(string: address)?.host ?? address
        let tab = BrowserTab(title: title ?? defaultTitle, address: address, space: space)
        let opener = opener.flatMap { id in tabs.first { $0.id == id && !$0.isSaved && $0.space == space } }.map(\.id)
        tabs.insert(tab, at: TabOrdering.insertionIndex(in: tabs, space: space, opener: opener, openers: openers))
        if let opener { openers[tab.id] = opener }
        activeID = tab.id
        rememberActiveSelection()
        return tab.id
    }
    /// Puts a reopened ordinary tab back where it was closed (falling back to
    /// the top of Today) and returns its index.
    @discardableResult mutating func insertRestored(_ tab: BrowserTab, originalID: UUID) -> Int {
        guard !tab.isSaved else { tabs.append(tab); return tabs.count - 1 }
        let anchor = closedAnchors.removeValue(forKey: originalID)
        let index: Int
        if let anchor, anchor.space == tab.space, let after = anchor.after,
           let position = tabs.firstIndex(where: { $0.id == after && !$0.isSaved && $0.space == tab.space }) {
            index = position + 1
        } else {
            index = TabOrdering.insertionIndex(in: tabs, space: tab.space, opener: nil, openers: [:])
        }
        tabs.insert(tab, at: index)
        return index
    }
    /// Records that `id` is the tab on screen, for ⌃⇥'s recent order.
    mutating func noteRecent(_ id: UUID) {
        let id = split(for: id)?.primaryID ?? id
        var list = recentTabIDs ?? []
        if list.first == id { return }
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        let live = Set(tabs.map(\.id))
        list = Array(list.filter { live.contains($0) }.prefix(64))
        recentTabIDs = list
    }
    /// The tabs a ⌃⇥ switcher offers, newest first: the current tab, then the
    /// tabs used most recently in this Space (its Favorites included), topped
    /// up in sidebar order when there's little history. At most `limit`.
    func recentSwitcherTabs(limit: Int = 5) -> [UUID] {
        let rows = shortcutTabs()
        let candidates = Set(rows)
        var result: [UUID] = []
        func take(_ id: UUID) {
            let id = split(for: id)?.primaryID ?? id
            guard result.count < limit, candidates.contains(id), !result.contains(id) else { return }
            result.append(id)
        }
        take(activeID)
        for id in recentTabIDs ?? [] { take(id) }
        for id in rows { take(id) }
        return result
    }
    /// The tabs ⌘1–⌘9 reach, in sidebar order: Favorites, then the kept rows
    /// on show (folders open), then Today. Blank New Tab placeholders that
    /// have no row are skipped, like the sidebar does.
    func shortcutTabs() -> [UUID] {
        let profile = spaceDefinition(space)?.profileID ?? BrowserProfile.defaultID
        let grouped = splitSecondaryIDs
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favoriteIDs = favorites(in: profile).map(\.id)
        let kept = visibleKeptLayout(in: space, revealing: activeID).compactMap { $0.isFolder ? nil : byID[$0.id]?.id }
        let today = tabs.filter { $0.space == space && !$0.isSaved && !grouped.contains($0.id) && (!$0.isHome || $0.id == activeID) }.map(\.id)
        return favoriteIDs + kept + today
    }
    /// ⌘1–⌘8 go to that tab, ⌘9 to the last one.
    func shortcutTab(_ number: Int) -> UUID? {
        let rows = shortcutTabs()
        guard (1...9).contains(number), !rows.isEmpty else { return nil }
        if number == 9 { return rows.last }
        return rows.indices.contains(number - 1) ? rows[number - 1] : nil
    }
    mutating func select(_ id: UUID) {
        let selectedID = split(for: id)?.primaryID ?? id
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }),
              tabs[index].isFavorite || spaceDefinition(tabs[index].space) != nil else { return }
        let selected = tabs[index]
        var destination = space
        if selected.isFavorite && profileID(for: selected) != currentProfileID {
            let profile = profileID(for: selected)
            guard let matching = spaceDefinition(selected.space)?.profileID == profile ? selected.space : spaceID(forProfile: profile) else { return }
            destination = matching
        }
        rememberActiveSelection()
        if TabOrdering.family(of: activeID, openers: openers) != TabOrdering.family(of: selectedID, openers: openers) { openers.removeAll() }
        space = destination
        let members = split(for: selectedID).map { [$0.primaryID, $0.secondaryID] } ?? [selectedID]
        for index in tabs.indices where members.contains(tabs[index].id) { tabs[index].saved?.isUnloaded = false }
        activeID = selectedID
        if !tabs[index].isFavorite { space = tabs[index].space }
        rememberActiveSelection()
    }
    mutating func changeSpace(_ value: Int) {
        guard spaceDefinition(value) != nil else { return }
        rememberActiveSelection()
        space = value
        if let id = rememberedTab(in: space) ?? fallbackTab(in: space) {
            activeID = id
            rememberActiveSelection()
        } else { add() }
    }
    func split(for id: UUID) -> BrowserSplit? { (splits ?? []).first { $0.primaryID == id || $0.secondaryID == id } }
    @discardableResult mutating func makeSplit(primary: UUID, secondary: UUID) -> Bool {
        guard primary != secondary, let left = tabs.first(where: { $0.id == primary }),
              let right = tabs.first(where: { $0.id == secondary }), left.space == right.space,
              !left.isFavorite, !right.isFavorite, !left.isUnloaded, !right.isUnloaded, !left.isArcEasel, !right.isArcEasel,
              spaceDefinition(left.space) != nil else { return false }
        splits = (splits ?? []).filter { ![primary,secondary].contains($0.primaryID) && ![primary,secondary].contains($0.secondaryID) }
        splits?.append(BrowserSplit(primaryID: primary, secondaryID: secondary))
        alignSplitFolders()
        select(primary); return true
    }
    mutating func removeSplit(containing id: UUID) { splits = (splits ?? []).filter { $0.primaryID != id && $0.secondaryID != id } }
    @discardableResult mutating func close(_ id: UUID) -> BrowserTab? {
        guard let closing = tabs.first(where: { $0.id == id }) else { return nil }
        rememberActiveSelection()
        let group = split(for: id)
        let members = Set(group?.primaryID == id ? [id, group!.secondaryID] : [id])
        // Where a closing Today tab hands the selection, decided before it leaves.
        let today = tabs.filter { $0.space == closing.space && !$0.isSaved && !splitSecondaryIDs.contains($0.id) }
        let successor = !closing.isSaved && members.contains(activeID)
            ? TabOrdering.successor(closing: id, today: today.map(\.id), openers: openers,
                                    eligible: { candidate in today.first { $0.id == candidate }.map { !$0.isHome && !$0.isUnloaded } ?? false })
            : nil
        for member in members {
            guard let tab = tabs.first(where: { $0.id == member }), !tab.isSaved else { continue }
            let row = today.firstIndex { $0.id == member }
            let above = row.flatMap { $0 > 0 ? today[..<$0].last { !members.contains($0.id) }?.id : nil }
            if closedAnchors.count > 200 { closedAnchors.removeAll() }
            closedAnchors[member] = ClosedAnchor(space: tab.space, after: above)
        }
        for member in members {
            openers[member] = nil
            for (child, opener) in openers where opener == member { openers[child] = nil }
        }
        removeSplit(containing: id)
        for index in tabs.indices where members.contains(tabs[index].id) && tabs[index].isSaved {
            tabs[index].address = tabs[index].saved!.address
            tabs[index].saved?.isUnloaded = true
            tabs[index].sleepState = nil
        }
        tabs.removeAll { members.contains($0.id) && !$0.isSaved }
        if let successor, tabs.contains(where: { $0.id == successor }) { activeID = successor }
        repairRememberedSelections()
        repairActiveSelection()
        return closing
    }

    // MARK: Kept-section folders

    enum KeptContainer: Hashable { case root(Int), folder(UUID) }

    func folder(_ id: UUID) -> BrowserFolder? { folders.first { $0.id == id } }
    func folders(in space: Int) -> [BrowserFolder] { folders.filter { $0.space == space } }
    private var splitSecondaryIDs: Set<UUID> { Set((splits ?? []).map(\.secondaryID)) }
    /// Rows that can live in the kept hierarchy: local kept tabs (Split primaries only).
    private func isKeptRow(_ tab: BrowserTab, secondaries: Set<UUID>) -> Bool {
        tab.saved?.kind == .kept && !secondaries.contains(tab.id)
    }
    private func storedOrder(for container: KeptContainer) -> [UUID]? {
        switch container {
        case .root(let space): return rootOrder?[space]
        case .folder(let id): return folder(id)?.childOrder
        }
    }
    mutating func setOrder(_ ids: [UUID], for container: KeptContainer) {
        var seen = Set<UUID>(); let ids = ids.filter { seen.insert($0).inserted }
        switch container {
        case .root(let space):
            if rootOrder == nil { rootOrder = [:] }
            rootOrder?[space] = ids
        case .folder(let id):
            if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].childOrder = ids }
        }
    }
    /// Ordered child IDs of a container. Stored order wins; members missing from
    /// it follow in tab-array order (tabs) and then folder-array order.
    func keptChildren(of container: KeptContainer) -> [UUID] {
        let secondaries = splitSecondaryIDs
        let space: Int, parent: UUID?
        switch container {
        case .root(let id): space = id; parent = nil
        case .folder(let id):
            guard let definition = folder(id) else { return [] }
            space = definition.space; parent = id
        }
        let memberTabs = tabs.filter { $0.space == space && $0.folderID == parent && isKeptRow($0, secondaries: secondaries) }.map(\.id)
        let memberFolders = folders.filter { $0.space == space && $0.parentID == parent }.map(\.id)
        return Self.ordered(members: memberTabs + memberFolders, stored: storedOrder(for: container))
    }
    private static func ordered(members: [UUID], stored: [UUID]?) -> [UUID] {
        guard let stored, !stored.isEmpty else { return members }
        let memberSet = Set(members); var seen = Set<UUID>()
        let known = stored.filter { memberSet.contains($0) && seen.insert($0).inserted }
        return known + members.filter { !seen.contains($0) }
    }
    func container(ofKeptItem id: UUID) -> KeptContainer? {
        if let definition = folder(id) { return definition.parentID.map { .folder($0) } ?? .root(definition.space) }
        guard let tab = tabs.first(where: { $0.id == id }), tab.saved?.kind == .kept else { return nil }
        return tab.folderID.map { .folder($0) } ?? .root(tab.space)
    }
    func folderDepth(_ id: UUID) -> Int {
        var depth = 0, current = folder(id)?.parentID, visited = Set<UUID>([id])
        while let parent = current, visited.insert(parent).inserted { depth += 1; current = folder(parent)?.parentID }
        return depth
    }
    /// True when `candidate` is `ancestor` itself or nested anywhere inside it.
    func isFolder(_ candidate: UUID, within ancestor: UUID) -> Bool {
        var current: UUID? = candidate, visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted {
            if id == ancestor { return true }
            current = folder(id)?.parentID
        }
        return false
    }
    private func subtreeHeight(_ id: UUID) -> Int {
        let children = folders.filter { $0.parentID == id }
        return children.isEmpty ? 0 : 1 + (children.map { subtreeHeight($0.id) }.max() ?? 0)
    }
    /// Every folder nested in `id`, including itself.
    func folderSubtree(_ id: UUID) -> Set<UUID> {
        var result = Set<UUID>([id]), frontier = [id]
        while let next = frontier.popLast() {
            for child in folders where child.parentID == next && result.insert(child.id).inserted { frontier.append(child.id) }
        }
        return result
    }
    /// Every tab anywhere inside a folder, including each Split companion, so
    /// a Split always travels as one unit whatever each pane's retention.
    func tabIDs(inFolder id: UUID) -> [UUID] {
        let subtree = folderSubtree(id)
        var members = Set(tabs.filter { $0.folderID.map(subtree.contains) == true }.map(\.id))
        for group in splits ?? [] where members.contains(group.primaryID) || members.contains(group.secondaryID) {
            members.insert(group.primaryID); members.insert(group.secondaryID)
        }
        return tabs.filter { members.contains($0.id) }.map(\.id)
    }
    /// A Split's folder is its primary's folder. A kept companion mirrors it;
    /// an ordinary companion has none (folders hold kept tabs only) but still
    /// moves with its primary through `tabIDs(inFolder:)`.
    private mutating func alignSplitFolders() {
        guard let splits, !splits.isEmpty else { return }
        let index = Dictionary(tabs.indices.map { (tabs[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in splits {
            guard let primary = index[group.primaryID], let secondary = index[group.secondaryID] else { continue }
            let folder = tabs[primary].saved?.kind == .kept ? tabs[primary].folderID : nil
            tabs[secondary].folderID = tabs[secondary].saved?.kind == .kept ? folder : nil
        }
    }
    /// Full depth-first kept hierarchy for a Space, ignoring collapse.
    func keptLayout(in space: Int) -> [KeptLayoutEntry] { keptLayout(in: space, revealing: nil, honorCollapse: false) }
    /// Sidebar rows: collapsed folders hide their contents, except that the
    /// selected tab stays visible beneath its collapsed ancestor.
    func visibleKeptLayout(in space: Int, revealing selected: UUID?) -> [KeptLayoutEntry] {
        keptLayout(in: space, revealing: selected, honorCollapse: true)
    }
    private func keptLayout(in space: Int, revealing selected: UUID?, honorCollapse: Bool) -> [KeptLayoutEntry] {
        let secondaries = splitSecondaryIDs
        var tabChildren: [UUID?: [UUID]] = [:], folderChildren: [UUID?: [UUID]] = [:]
        for tab in tabs where tab.space == space && isKeptRow(tab, secondaries: secondaries) { tabChildren[tab.folderID, default: []].append(tab.id) }
        var byID: [UUID: BrowserFolder] = [:]
        for definition in folders where definition.space == space {
            folderChildren[definition.parentID, default: []].append(definition.id); byID[definition.id] = definition
        }
        let selectedPrimary = selected.map { split(for: $0)?.primaryID ?? $0 }
        var result: [KeptLayoutEntry] = []; var visited = Set<UUID>()
        func children(_ parent: UUID?) -> [UUID] {
            Self.ordered(members: (tabChildren[parent] ?? []) + (folderChildren[parent] ?? []),
                         stored: parent.map { byID[$0]?.childOrder } ?? rootOrder?[space])
        }
        func contains(_ folderID: UUID, _ target: UUID) -> Bool {
            var stack = [folderID], seen = Set<UUID>()
            while let next = stack.popLast(), seen.insert(next).inserted {
                if (tabChildren[next] ?? []).contains(target) { return true }
                stack += folderChildren[next] ?? []
            }
            return false
        }
        func walk(_ parent: UUID?, depth: Int, hidden: Bool) {
            for id in children(parent) where visited.insert(id).inserted {
                if let definition = byID[id] {
                    if !hidden { result.append(KeptLayoutEntry(id: id, isFolder: true, depth: depth, parentID: parent)) }
                    let collapsed = honorCollapse && definition.isCollapsed
                    if hidden || collapsed {
                        // Only descend to reveal the selection inside a collapsed folder.
                        if !hidden, let target = selectedPrimary, contains(id, target) {
                            result.append(KeptLayoutEntry(id: target, isFolder: false, depth: depth + 1, parentID: id))
                        }
                        if !honorCollapse { walk(id, depth: depth + 1, hidden: hidden) }
                    } else { walk(id, depth: depth + 1, hidden: false) }
                } else if !hidden { result.append(KeptLayoutEntry(id: id, isFolder: false, depth: depth, parentID: parent)) }
            }
        }
        walk(nil, depth: 0, hidden: false)
        return result
    }

    /// Creates a folder, optionally wrapping existing rows. All or nothing: if
    /// any requested row cannot move in, no folder is created.
    @discardableResult mutating func createFolder(name: String, space: Int, parent: UUID? = nil, at position: Int? = nil,
                                                  containing items: [UUID] = [], id: UUID = UUID()) -> UUID? {
        var draft = self
        guard let created = draft.createFolderDraft(name: name, space: space, parent: parent, at: position, containing: items, id: id) else { return nil }
        self = draft
        return created
    }
    /// Whether `item` could move into `destination` (nil: its Space root) right now.
    func canMoveKeptItem(_ item: UUID, into destination: UUID?) -> Bool {
        var draft = self
        return draft.moveKeptItem(item, into: destination)
    }
    func canCreateFolder(inside parent: UUID?) -> Bool {
        guard folders.count < Self.maximumFolders else { return false }
        guard let parent else { return true }
        return folder(parent) != nil && folderDepth(parent) + 1 < Self.maximumFolderDepth
    }
    private mutating func createFolderDraft(name: String, space: Int, parent: UUID?, at position: Int?,
                                            containing items: [UUID], id: UUID) -> UUID? {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        guard id != zero, spaceDefinition(space) != nil, folders.count < Self.maximumFolders, folder(id) == nil,
              !tabs.contains(where: { $0.id == id }), let name = BrowserFolder.validName(name) else { return nil }
        if let parent {
            guard let definition = folder(parent), definition.space == space,
                  folderDepth(parent) + 1 < Self.maximumFolderDepth else { return nil }
        }
        let container: KeptContainer = parent.map { .folder($0) } ?? .root(space)
        var order = keptChildren(of: container)
        folders.append(BrowserFolder(id: id, name: name, space: space, parentID: parent))
        // A folder made from a row takes that row's place.
        let anchor = items.first.flatMap { item in order.firstIndex(of: split(for: item)?.primaryID ?? item) }
        let index = min(order.count, max(0, position ?? anchor ?? order.count))
        order.insert(id, at: index)
        setOrder(order, for: container)
        for item in items { guard moveKeptItem(item, into: id) else { return nil } }
        return id
    }
    @discardableResult mutating func renameFolder(id: UUID, name: String) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }), let name = BrowserFolder.validName(name) else { return false }
        folders[index].name = name; return true
    }
    @discardableResult mutating func setFolderCollapsed(id: UUID, collapsed: Bool) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[index].isCollapsed = collapsed; return true
    }
    /// Moves a tab or folder into `destination` (nil: the Space's kept root) at
    /// `position` among its new siblings. Ordinary tabs become kept tabs; a
    /// Split moves as one row. Cycles, cross-Space moves and Favorites are refused.
    @discardableResult mutating func moveKeptItem(_ rawID: UUID, into destination: UUID?, at position: Int? = nil) -> Bool {
        let id = split(for: rawID)?.primaryID ?? rawID
        let itemSpace: Int
        if let definition = folder(id) {
            itemSpace = definition.space
            if let destination {
                guard let target = folder(destination), target.space == itemSpace, !isFolder(destination, within: id),
                      folderDepth(destination) + 1 + subtreeHeight(id) < Self.maximumFolderDepth else { return false }
            }
        } else {
            guard let tab = tabs.first(where: { $0.id == id }), !tab.isFavorite, spaceDefinition(tab.space) != nil else { return false }
            itemSpace = tab.space
            if let destination { guard folder(destination)?.space == itemSpace else { return false } }
            if tab.saved == nil { guard setRetention(id: id, kind: .kept) else { return false } }
        }
        let oldContainer = container(ofKeptItem: id) ?? .root(itemSpace)
        let newContainer: KeptContainer = destination.map { .folder($0) } ?? .root(itemSpace)
        var oldOrder = keptChildren(of: oldContainer)
        let oldIndex = oldOrder.firstIndex(of: id)
        oldOrder.removeAll { $0 == id }
        setOrder(oldOrder, for: oldContainer)
        if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].parentID = destination }
        else {
            let members = split(for: id).map { [$0.primaryID, $0.secondaryID] } ?? [id]
            for index in tabs.indices where members.contains(tabs[index].id) && tabs[index].saved?.kind == .kept {
                tabs[index].folderID = destination
            }
            alignSplitFolders()
        }
        var newOrder = keptChildren(of: newContainer).filter { $0 != id }
        var index = position ?? newOrder.count
        // Positions within the same container refer to the order before removal.
        if oldContainer == newContainer, let oldIndex, let position, position > oldIndex { index = position - 1 }
        newOrder.insert(id, at: min(newOrder.count, max(0, index)))
        setOrder(newOrder, for: newContainer)
        return true
    }
    @discardableResult mutating func reorderKeptItem(id rawID: UUID, by offset: Int) -> Bool {
        let id = split(for: rawID)?.primaryID ?? rawID
        guard let container = container(ofKeptItem: id) else { return false }
        var order = keptChildren(of: container)
        guard let current = order.firstIndex(of: id) else { return false }
        let (target, overflow) = current.addingReportingOverflow(offset)
        guard !overflow, order.indices.contains(target) else { return false }
        order.swapAt(current, target)
        setOrder(order, for: container); return true
    }

    /// Where a dragged sidebar row lands within one Space.
    enum SidebarDropTarget: Equatable {
        /// Just before this kept row (tab or folder), in that row's folder.
        case before(UUID)
        /// At the end of this folder.
        case into(UUID)
        /// At the end of the Space's kept section, outside any folder.
        case keptEnd
        /// Into Today (unkept), before this ordinary tab or at the end.
        case today(before: UUID?)
    }
    /// Drops a tab, Split or folder in `space`. Kept destinations reuse
    /// `moveKeptItem` (cycle/depth rules; Today tabs become kept); Today
    /// unkeeps a tab. Folders, Favorites and rows from another Space are
    /// refused here; moving between Spaces goes through `moveTab`/`moveFolder`.
    @discardableResult mutating func drop(_ rawID: UUID, at target: SidebarDropTarget, space: Int) -> Bool {
        var draft = self
        guard draft.applyDrop(rawID, at: target, space: space) else { return false }
        self = draft; return true
    }
    private mutating func applyDrop(_ rawID: UUID, at target: SidebarDropTarget, space: Int) -> Bool {
        let id = split(for: rawID)?.primaryID ?? rawID
        let isFolder = folder(id) != nil
        if isFolder { guard folder(id)?.space == space else { return false } }
        else { guard let tab = tabs.first(where: { $0.id == id }), !tab.isFavorite, tab.space == space else { return false } }
        switch target {
        case .before(let rawTarget):
            let target = split(for: rawTarget)?.primaryID ?? rawTarget
            guard target != id else { return true }
            let targetSpace = folder(target)?.space ?? tabs.first(where: { $0.id == target })?.space
            guard targetSpace == space, let container = container(ofKeptItem: target),
                  let index = keptChildren(of: container).firstIndex(of: target) else { return false }
            if case .folder(let parent) = container { return moveKeptItem(id, into: parent, at: index) }
            return moveKeptItem(id, into: nil, at: index)
        case .into(let destination):
            guard destination != id, folder(destination)?.space == space else { return false }
            return moveKeptItem(id, into: destination)
        case .keptEnd:
            return moveKeptItem(id, into: nil)
        case .today(let before):
            guard !isFolder, let tab = tabs.first(where: { $0.id == id }) else { return false }
            let anchor = before.map { split(for: $0)?.primaryID ?? $0 }
            if let anchor {
                guard anchor != id else { return tab.saved == nil ? true : setRetention(id: id, kind: nil) }
                guard let other = tabs.first(where: { $0.id == anchor }), other.space == space, !other.isSaved else { return false }
            }
            if tab.saved != nil { guard setRetention(id: id, kind: nil) else { return false } }
            // Today's order is tab order; a Split's companion is hidden, so only the primary moves.
            guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
            let moving = tabs.remove(at: from)
            let to = anchor.flatMap { a in tabs.firstIndex { $0.id == a } } ?? tabs.endIndex
            tabs.insert(moving, at: to)
            return true
        }
    }
    func canDrop(_ id: UUID, at target: SidebarDropTarget, space: Int) -> Bool {
        var draft = self
        return draft.applyDrop(id, at: target, space: space)
    }
    /// Removes the folder and puts its contents where it was, in order.
    @discardableResult mutating func ungroupFolder(id: UUID) -> Bool {
        guard let definition = folder(id) else { return false }
        let parent: KeptContainer = definition.parentID.map { .folder($0) } ?? .root(definition.space)
        let siblings = keptChildren(of: parent)
        let contents = keptChildren(of: .folder(id))
        for index in tabs.indices where tabs[index].folderID == id { tabs[index].folderID = definition.parentID }
        for index in folders.indices where folders[index].parentID == id { folders[index].parentID = definition.parentID }
        folders.removeAll { $0.id == id }
        var order: [UUID] = []
        for sibling in siblings { if sibling == id { order += contents } else { order.append(sibling) } }
        setOrder(order, for: parent)
        return true
    }
    /// Moves a folder, its nested folders and their tabs to another Space's kept root.
    @discardableResult mutating func moveFolder(id: UUID, toSpace destination: Int) -> Bool {
        guard let definition = folder(id), let target = spaceDefinition(destination) else { return false }
        guard definition.space != destination else { return true }
        rememberActiveSelection()
        let source = definition.space
        let subtree = folderSubtree(id)
        let moving = Set(tabIDs(inFolder: id))
        let crossesProfile = spaceDefinition(source)?.profileID != target.profileID
        let movedSelection = moving.contains(activeID)
        setOrder(keptChildren(of: .root(source)).filter { $0 != id }, for: .root(source))
        let destinationRoot = keptChildren(of: .root(destination))
        for index in folders.indices where subtree.contains(folders[index].id) { folders[index].space = destination }
        if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].parentID = nil }
        for index in tabs.indices where moving.contains(tabs[index].id) {
            tabs[index].space = destination
            if crossesProfile { tabs[index].sleepState = nil }
        }
        // A Split whose companion stayed behind cannot span Spaces.
        splits = (splits ?? []).filter { moving.contains($0.primaryID) == moving.contains($0.secondaryID) }
        setOrder(destinationRoot + [id], for: .root(destination))
        repairRememberedSelection(in: source)
        repairRememberedSelection(in: destination)
        if movedSelection { space = destination }
        repairActiveSelection()
        return true
    }
    private mutating func sanitizeFolders(validSpaceIDs: Set<Int>) {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        let tabIDs = Set(tabs.map(\.id))
        var seen = Set<UUID>()
        folders = Array(folders.filter { definition in
            definition.id != zero && !tabIDs.contains(definition.id) && validSpaceIDs.contains(definition.space)
                && seen.insert(definition.id).inserted
        }.prefix(Self.maximumFolders)).map { definition in
            var definition = definition
            definition.name = BrowserFolder.validName(definition.name) ?? "Folder"
            return definition
        }
        let spaceByFolder = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.space) })
        for index in folders.indices {
            if let parent = folders[index].parentID, spaceByFolder[parent] != folders[index].space || parent == folders[index].id {
                folders[index].parentID = nil
            }
        }
        // Break cycles and over-deep chains by lifting the offending folder to its Space root.
        for index in folders.indices {
            var chain = [folders[index].id], current = folders[index].parentID
            while let parent = current {
                if chain.contains(parent) || chain.count >= Self.maximumFolderDepth { folders[index].parentID = nil; break }
                chain.append(parent)
                current = folders.first(where: { $0.id == parent })?.parentID
            }
        }
        for index in tabs.indices {
            guard let folderID = tabs[index].folderID else { continue }
            if tabs[index].saved?.kind != .kept || spaceByFolder[folderID] != tabs[index].space { tabs[index].folderID = nil }
        }
        alignSplitFolders()
        let validItems = tabIDs.union(spaceByFolder.keys)
        for index in folders.indices {
            var unique = Set<UUID>()
            folders[index].childOrder = folders[index].childOrder.filter { validItems.contains($0) && unique.insert($0).inserted }
        }
        rootOrder = rootOrder.map { orders in
            Dictionary(uniqueKeysWithValues: orders.compactMap { key, ids -> (Int, [UUID])? in
                guard validSpaceIDs.contains(key) else { return nil }
                var unique = Set<UUID>()
                return (key, ids.filter { validItems.contains($0) && unique.insert($0).inserted })
            })
        }
        if rootOrder?.isEmpty == true { rootOrder = nil }
    }

    mutating func sanitize() {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        var seenProfiles = Set<UUID>()
        profiles = profiles.compactMap { profile in
            guard profile.id != zero, seenProfiles.insert(profile.id).inserted else { return nil }
            return BrowserProfile(id: profile.id, name: BrowserSpace.validName(profile.name) ?? "Profile")
        }
        if !profiles.contains(where: { $0.id == BrowserProfile.defaultID }) { profiles.insert(BrowserProfile.defaults[0], at: 0) }
        // Missing definitions must never route formerly isolated pages through
        // personal/default cookies. Recover the same stable store identifier.
        let replacementForZero = UUID()
        for i in spaces.indices where spaces[i].profileID == zero { spaces[i].profileID = replacementForZero }
        for i in tabs.indices where tabs[i].saved?.profileID == zero { tabs[i].saved?.profileID = replacementForZero }
        let referenced = spaces.map(\.profileID) + tabs.compactMap { $0.isFavorite ? $0.saved?.profileID : nil }
        for id in referenced where !profiles.contains(where: { $0.id == id }) {
            var name = "Recovered profile", suffix = 2
            while profiles.contains(where: { $0.name == name }) { name = "Recovered profile \(suffix)"; suffix += 1 }
            profiles.append(BrowserProfile(id: id, name: name))
        }
        let validProfiles = Set(profiles.map(\.id))
        lastIssuedSpaceID = max(lastIssuedSpaceID, spaces.map(\.id).max() ?? 2)
        var seenSpaces = Set<Int>()
        spaces = spaces.compactMap { definition in
            guard definition.id >= 0, seenSpaces.count < Self.maximumSpaces,
                  seenSpaces.insert(definition.id).inserted else { return nil }
            return BrowserSpace(id: definition.id,
                                name: BrowserSpace.validName(definition.name) ?? "Space \(definition.id)",
                                symbol: BrowserSpace.normalizedSymbol(definition.symbol),
                                // Out-of-range indices repair to a flat color;
                                // Prism and Clear apply only by explicit choice.
                                colorIndex: BrowserSpace.colorNames.indices.contains(definition.colorIndex)
                                    ? definition.colorIndex
                                    : min(BrowserSpace.flatColorCount - 1, max(0, definition.colorIndex)),
                                profileID: validProfiles.contains(definition.profileID) ? definition.profileID : BrowserProfile.defaultID,
                                emoji: definition.emoji,
                                // Kept only with an in-range flat color (the initializer enforces it).
                                theme: BrowserSpace.colorNames.indices.contains(definition.colorIndex) ? definition.theme : nil)
        }
        if spaces.isEmpty { spaces = BrowserSpace.defaults }
        lastIssuedSpaceID = max(2, max(lastIssuedSpaceID, spaces.map(\.id).max() ?? 2))
        let validSpaceIDs = Set(spaceIDs)
        if !validSpaceIDs.contains(space) {
            // Preserve legacy invalid-space clamping; custom IDs are not indices.
            space = validSpaceIDs == Set([0, 1, 2]) ? min(2, max(0, space)) : spaces[0].id
        }
        sidebarWidth = sidebarWidth.isFinite ? min(500, max(164, sidebarWidth)) : 228
        var seen = Set<UUID>()
        var favoriteCounts: [UUID: Int] = [:]
        let profilesBySpace = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.profileID) })
        tabs = tabs.compactMap { original in
            var tab = original
            guard seen.insert(tab.id).inserted else { return nil }
            if let saved = tab.saved, URLInput.extensionURL(saved.address) != nil || URLInput.extensionURL(tab.address) != nil { tab.saved = nil }
            if var saved = tab.saved {
                if !BrowserTab.validAddress(saved.address) {
                    guard BrowserTab.validAddress(tab.address) else { return nil }
                    saved.address = tab.address
                }
                let title = saved.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                saved.customTitle = title.map { !$0.isEmpty && BrowserTab.validCustomTitle($0) } == true ? title : nil
                let symbol = saved.customSymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
                saved.customSymbol = symbol.map { BrowserSpace.symbols.contains($0) } == true ? symbol : nil
                if saved.kind == .favorite {
                    if !validSpaceIDs.contains(tab.space) { tab.space = space }
                    let candidate = saved.profileID ?? profilesBySpace[tab.space] ?? BrowserProfile.defaultID
                    let profile = validProfiles.contains(candidate) ? candidate : BrowserProfile.defaultID
                    saved.profileID = profile
                    favoriteCounts[profile, default: 0] += 1
                    if favoriteCounts[profile, default: 0] > Self.maximumFavorites, let matching = spaces.first(where: { $0.profileID == profile }) {
                        saved.kind = .kept; saved.profileID = nil; tab.space = matching.id
                    }
                } else { saved.profileID = nil }
                tab.saved = saved
                if saved.isUnloaded || !BrowserTab.validAddress(tab.address) { tab.address = saved.address }
            }
            guard validSpaceIDs.contains(tab.space), BrowserTab.validAddress(tab.address) else { return nil }
            if let sleep = tab.sleepState, tab.isUnloaded || !sleep.matches(tab.address) { tab.sleepState = nil }
            return tab
        }
        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var grouped = Set<UUID>()
        splits = (splits ?? []).filter { group in
            guard group.primaryID != group.secondaryID,
                  let left = tabByID[group.primaryID], let right = tabByID[group.secondaryID], left.space == right.space,
                  !left.isFavorite, !right.isFavorite, left.isUnloaded == right.isUnloaded, !left.isUnloaded || (left.isSaved && right.isSaved),
                  !left.isArcEasel, !right.isArcEasel,
                  !grouped.contains(group.primaryID), !grouped.contains(group.secondaryID) else { return false }
            grouped.insert(group.primaryID); grouped.insert(group.secondaryID); return true
        }
        if let group = split(for: activeID) { activeID = group.primaryID }
        sanitizeFolders(validSpaceIDs: validSpaceIDs)
        lastSelectedTabIDsBySpace = (lastSelectedTabIDsBySpace ?? [:]).filter { entry in
            validSpaceIDs.contains(entry.key) && tabByID[entry.value].map { selectable($0, in: entry.key) } == true
        }.mapValues { split(for: $0)?.primaryID ?? $0 }
        repairActiveSelection()

    }
}

/// Where plain typed text goes. Each option builds its results URL with
/// URLComponents so the query is encoded exactly once, whatever the engine.
enum DefaultSearchEngine: String, CaseIterable {
    case duckDuckGo = "duckduckgo.com"
    case google = "google.com"
    case perplexity = "perplexity.ai"
    static let defaultsKey = "DefaultSearchEngine"
    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .perplexity: return "Perplexity"
        }
    }
    var endpoint: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/search"
        case .perplexity: return "https://www.perplexity.ai/search"
        }
    }
    func searchURL(for query: String) -> String? {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url?.absoluteString
    }
}

/// An Arc Easel brought over as a reference: its place, name and Arc identity
/// are kept; its canvas is not imported and Bam doesn't guess a link to it.
/// Address: `orbit://arc-easel/<Easel UUID>`. Never typed or navigated to.
enum ArcEaselReference {
    static let prefix = "orbit://arc-easel/"
    static func address(for id: UUID) -> String { prefix + id.uuidString }
    static func isReference(_ address: String) -> Bool { easelID(address) != nil }
    static func easelID(_ address: String) -> UUID? {
        guard address.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(address.dropFirst(prefix.count)))
    }
}

enum URLInput {
    /// Settings swap this; the app restores the saved choice at launch.
    nonisolated(unsafe) static var searchEngine: DefaultSearchEngine = .duckDuckGo
    /// Extension-page restoration is validated separately from user input and
    /// HTTP navigation. The controller must still authorize the live context.
    static func extensionURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "webkit-extension",
              let host = url.host, UUID(uuidString: host) != nil,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }
    static func directURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func resolve(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if ["orbit://newtab", "about:blank"].contains(text) { return "orbit://newtab" }
        if text == "orbit://video" { return "orbit://video" }
        if let url = directURL(text) { return url.absoluteString }
        if text.contains("://") || text.lowercased().hasPrefix("javascript:") || text.lowercased().hasPrefix("file:") || text.lowercased().hasPrefix("data:") { return nil }
        if !text.contains(where: { $0.isWhitespace }) && (text.contains(".") || text.hasPrefix("localhost") || text.hasPrefix("[::1]")) {
            let scheme = (text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")) ? "http://" : "https://"
            if let url = directURL(scheme + text) { return url.absoluteString }
        }
        return searchEngine.searchURL(for: text)
    }
}

enum SessionFile {
    static func load(_ url: URL) -> BrowserSession {
        // No file at all is a first launch; an unreadable one keeps the demo session.
        guard FileManager.default.fileExists(atPath: url.path) else { return .firstRun() }
        guard let data = try? Data(contentsOf: url), var session = try? JSONDecoder().decode(BrowserSession.self, from: data) else { return .fresh() }
        session.sanitize(); return session
    }
    static func save(_ session: BrowserSession, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: url, options: .atomic)
    }
}

/// Pure tab-order rules shared by the session and its tests.
enum TabOrdering {
    /// A link tab's family is its opener; any other tab is its own family.
    static func family(of id: UUID, openers: [UUID: UUID]) -> UUID { openers[id] ?? id }

    /// Where a new ordinary tab goes in `tabs` (whose order is Today's order).
    /// Without an opener: before the Space's first Today tab (the top). With
    /// one: after the opener and the run of tabs already opened from it.
    static func insertionIndex(in tabs: [BrowserTab], space: Int, opener: UUID?, openers: [UUID: UUID]) -> Int {
        let today = tabs.indices.filter { tabs[$0].space == space && !tabs[$0].isSaved }
        guard let opener, let start = today.firstIndex(where: { tabs[$0].id == opener }) else {
            return today.first ?? tabs.count
        }
        var last = today[start]
        for position in today[(start + 1)...] {
            guard openers[tabs[position].id] == opener else { break }
            last = position
        }
        return last + 1
    }

    /// The tab that takes over when the selected Today tab `closing` closes.
    /// A link tab goes to the next tab opened from the same page (below, then
    /// above), then to its opener; any other tab goes to the row below, then
    /// above. Nil leaves the choice to the session's fallback.
    static func successor(closing: UUID, today: [UUID], openers: [UUID: UUID], eligible: (UUID) -> Bool) -> UUID? {
        guard let index = today.firstIndex(of: closing) else { return nil }
        let below = today[(index + 1)...].filter(eligible)
        let above = today[..<index].reversed().filter(eligible)
        if let opener = openers[closing] {
            if let sibling = below.first(where: { openers[$0] == opener }) ?? above.first(where: { openers[$0] == opener }) { return sibling }
            if today.contains(opener) ? eligible(opener) : true { return opener }
        }
        return below.first ?? above.first
    }
}
