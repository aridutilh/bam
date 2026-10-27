import AppKit

/// The commands whose menu shortcuts Settings lets people remap. Raw values
/// are the UserDefaults keys, so renaming a case would orphan saved chords.
enum ShortcutCommand: String, CaseIterable {
    case newTab, openLocation, toggleSidebar, nextSpace, previousSpace, keepTab, settings

    var title: String {
        switch self {
        case .newTab: return "New tab or search"
        case .openLocation: return "Open location"
        case .toggleSidebar: return "Toggle sidebar"
        case .nextSpace: return "Next Space"
        case .previousSpace: return "Previous Space"
        case .keepTab: return "Keep or unkeep tab"
        case .settings: return "Settings"
        }
    }
    /// The palette row that runs this command, so its badge shows the live chord.
    init?(paletteID: String) {
        switch paletteID {
        case "settings": self = .settings
        case "toggle-sidebar": self = .toggleSidebar
        case "new-tab": self = .newTab
        case "next-space": self = .nextSpace
        case "previous-space": self = .previousSpace
        default: return nil
        }
    }
    /// The welcome tour's training targets are keyed by their default letter.
    init?(onboardingTarget: String) {
        switch onboardingTarget {
        case "t": self = .newTab
        case "s": self = .toggleSidebar
        default: return nil
        }
    }
    /// The menu command this case names in the full shortcut list (its action's selector).
    /// Chords saved before every menu command became remappable were keyed by the raw value.
    var menuID: String {
        switch self {
        case .newTab: return "newTab:"
        case .openLocation: return "focusAddress:"
        case .toggleSidebar: return "toggleSidebar:"
        case .nextSpace: return "nextSpace:"
        case .previousSpace: return "previousSpace:"
        case .keepTab: return "togglePin:"
        case .settings: return "showSettings:"
        }
    }
    var defaultCombo: KeyCombo {
        switch self {
        case .newTab: return KeyCombo("t", .command)
        case .openLocation: return KeyCombo("l", .command)
        case .toggleSidebar: return KeyCombo("s", .command)
        case .nextSpace: return KeyCombo(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        case .previousSpace: return KeyCombo(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        case .keepTab: return KeyCombo("d", .command)
        case .settings: return KeyCombo(",", .command)
        }
    }
}

/// A key equivalent as NSMenuItem wants it: the key string (a lowercase
/// letter, punctuation or a function-key scalar) plus the modifier mask.
struct KeyCombo: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
    }

    /// The chord a key press describes, or nil when it cannot serve as a
    /// shortcut: modifier-only presses, Escape and Delete (the recorder's own
    /// keys), and keys with no ⌘, ⌃ or ⌥ to carry them. Only F1–F35 may go
    /// bare; a bare arrow or Page key would steal the caret from every text field.
    static func from(event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Shift changes the glyph (⇧1 is "!" on a US keyboard); the chord
        // keeps the unshifted key so it survives a layout change.
        guard var characters = event.charactersIgnoringModifiers, characters.unicodeScalars.count == 1,
              var scalar = characters.unicodeScalars.first else { return nil }
        if flags.contains(.shift), !(0xF700...0xF8FF).contains(scalar.value),
           let unshifted = event.characters(byApplyingModifiers: []), unshifted.unicodeScalars.count == 1 {
            characters = unshifted; scalar = unshifted.unicodeScalars.first!
        }
        if scalar.value == 0x1B || scalar.value == 0x7F || scalar.value == 0xF728 { return nil }
        let fKey = (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value))
        let carried = !flags.intersection([.command, .control, .option]).isEmpty
        guard fKey || carried else { return nil }
        return KeyCombo(characters, flags)
    }

    /// "⌥⌘→", the palette's tighter spelling.
    var compact: String { display.replacingOccurrences(of: " ", with: "") }
    /// "⌥ ⌘ →", the way the site's keycaps spell chords.
    var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.glyph(for: key))
        return parts.joined(separator: " ")
    }
    /// A spoken form for accessibility and tooltips: "Option Command Right Arrow".
    var spoken: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(Self.name(for: key))
        return parts.joined(separator: " ")
    }
    private static func glyph(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case 0x09: return "⇥"
        case 0x0D, 0x03: return "↩"
        case 0x20: return "Space"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        case NSF1FunctionKey...NSF12FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        default: return key.uppercased()
        }
    }
    private static func name(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "Left Arrow"
        case NSRightArrowFunctionKey: return "Right Arrow"
        case NSUpArrowFunctionKey: return "Up Arrow"
        case NSDownArrowFunctionKey: return "Down Arrow"
        case 0x09: return "Tab"
        case 0x0D, 0x03: return "Return"
        case 0x20: return "Space"
        case 0x2C: return "Comma"
        case 0x2E: return "Period"
        default: return glyph(for: key)
        }
    }
}

/// One command in the menu bar as Settings › Shortcuts lists it. `id` is stable across
/// launches and title changes (the action's selector, plus the item's choice when a
/// menu repeats one action); `defaultCombo` is the chord the menu was built with.
struct MenuShortcut: Equatable {
    let id: String
    var title: String
    var menu: String
    var defaultCombo: KeyCombo?
}

/// Saved chords for every menu command. Menu items read it when they are built and
/// again whenever it changes; fresh previews never persist. An override can also be
/// "no shortcut" (Remove), which is saved too.
@MainActor final class ShortcutStore {
    static let shared = ShortcutStore()
    static let didChange = Notification.Name("BamShortcutsDidChange")
    static let defaultsKey = "Shortcuts"

    enum Assignment: Equatable {
        case assigned
        /// Another command wears the chord; pass `takeOver` to move it.
        case taken(by: String)
        /// Something outside the list (an extension's command) wears it; it can't be moved.
        case reserved(by: String)
    }

    private(set) var persists = true
    private(set) var catalog: [MenuShortcut]
    private var positions: [String: Int] = [:]
    /// id → chord, or nil for a shortcut that was removed.
    private var custom: [String: KeyCombo?] = [:]
    /// The app answers with the title of a menu item outside the list (an extension's
    /// command) that already wears a chord, so recording it is refused.
    var reservedOwner: ((KeyCombo) -> String?)?

    init() {
        catalog = ShortcutCommand.allCases.map { MenuShortcut(id: $0.menuID, title: $0.title, menu: "", defaultCombo: $0.defaultCombo) }
        reindex()
        load()
    }

    /// Fresh previews start from the defaults and never write.
    func configure(persists: Bool) {
        self.persists = persists
        if !persists { custom = [:] }
    }

    /// Adds the commands the menus hold now. A command seen before keeps its first
    /// default (the menus may already wear a custom chord) but takes the new title.
    func register(_ commands: [MenuShortcut]) {
        var seen = Set<String>()
        var ordered: [MenuShortcut] = []
        for command in commands where seen.insert(command.id).inserted {
            var entry = command
            if let known = positions[command.id] { entry.defaultCombo = catalog[known].defaultCombo }
            ordered.append(entry)
        }
        // Commands not in the menus right now (a Space that was removed) stay known, after the rest.
        ordered += catalog.filter { !seen.contains($0.id) }
        catalog = ordered
        reindex()
    }
    private func reindex() { positions = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ($1.id, $0) }) }
    func command(_ id: String) -> MenuShortcut? { positions[id].map { catalog[$0] } }

    /// The chord a command wears now: its override, else its default; nil when it has none.
    func combo(forID id: String) -> KeyCombo? {
        if let override = custom[id] { return override }
        return command(id)?.defaultCombo
    }
    func isDefault(id: String) -> Bool { custom[id] == nil }
    var anyCustom: Bool { !custom.isEmpty }

    /// The command (id and title) wearing this chord, other than `besides`.
    func owner(of combo: KeyCombo, besides id: String?) -> (id: String?, title: String)? {
        if let other = catalog.first(where: { $0.id != id && self.combo(forID: $0.id) == combo }) { return (other.id, other.title) }
        return reservedOwner?(combo).map { (nil, $0) }
    }

    /// Gives `combo` to a command. A chord another command wears is refused unless
    /// `takeOver`, which leaves that command without a shortcut, so no two share one.
    @discardableResult func assign(_ combo: KeyCombo, to id: String, takeOver: Bool = false) -> Assignment {
        if let owner = owner(of: combo, besides: id) {
            guard let ownerID = owner.id else { return .reserved(by: owner.title) }
            guard takeOver else { return .taken(by: owner.title) }
            clear(ownerID)
        }
        if combo == command(id)?.defaultCombo { custom.removeValue(forKey: id) } else { custom[id] = .some(combo) }
        save(); return .assigned
    }
    /// Leaves a command without a shortcut.
    func remove(id: String) {
        clear(id); save()
    }
    private func clear(_ id: String) {
        if command(id)?.defaultCombo == nil { custom.removeValue(forKey: id) } else { custom[id] = .some(nil) }
    }
    /// Back to the menu's own chord; a command that took it meanwhile gives it up.
    func reset(id: String) {
        guard custom[id] != nil else { return }
        custom.removeValue(forKey: id)
        if let combo = command(id)?.defaultCombo, let owner = owner(of: combo, besides: id), let ownerID = owner.id { clear(ownerID) }
        save()
    }
    func resetAll() {
        guard !custom.isEmpty else { return }
        custom = [:]; save()
    }

    // The original seven, by name: what the palette, sidebar hints and welcome read.
    func combo(for command: ShortcutCommand) -> KeyCombo { combo(forID: command.menuID) ?? command.defaultCombo }
    func isDefault(_ command: ShortcutCommand) -> Bool { isDefault(id: command.menuID) }
    func owner(of combo: KeyCombo, besides command: ShortcutCommand) -> String? { owner(of: combo, besides: command.menuID)?.title }
    /// Assigns without taking over: a chord something else wears is refused.
    @discardableResult func set(_ combo: KeyCombo, for command: ShortcutCommand) -> Bool { assign(combo, to: command.menuID) == .assigned }
    func reset(_ command: ShortcutCommand) { reset(id: command.menuID) }

    private func load() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) else { return }
        for (name, value) in saved {
            guard let entry = value as? [String: Any] else { continue }
            // Chords saved by 0.17–0.25 are keyed by ShortcutCommand's raw value.
            let id = ShortcutCommand(rawValue: name)?.menuID ?? name
            if entry["removed"] as? Bool == true { custom[id] = .some(nil); continue }
            guard let key = entry["key"] as? String, !key.isEmpty, let raw = entry["modifiers"] as? UInt else { continue }
            let combo = KeyCombo(key, NSEvent.ModifierFlags(rawValue: raw))
            if combo != command(id)?.defaultCombo { custom[id] = .some(combo) }
        }
    }
    private func save() {
        if persists {
            var payload: [String: [String: Any]] = [:]
            for (id, combo) in custom {
                if let combo { payload[id] = ["key": combo.key, "modifiers": combo.modifiers.rawValue] }
                else { payload[id] = ["removed": true] }
            }
            if payload.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
            else { UserDefaults.standard.set(payload, forKey: Self.defaultsKey) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

extension KeyCombo {
    /// Whether a filter typed in Settings names this chord: glyphs ("⌥⌘→", "⌘k") or
    /// words ("cmd k", "option command right").
    func matches(_ query: String) -> Bool {
        var text = query.lowercased()
        for (words, glyph) in [(["command", "cmd"], "⌘"), (["option", "opt", "alt"], "⌥"), (["control", "ctrl"], "⌃"), (["shift"], "⇧")] {
            for word in words { text = text.replacingOccurrences(of: word, with: glyph) }
        }
        text = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "+", with: "")
        guard !text.isEmpty else { return false }
        let glyphs: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]
        if text.contains(where: { glyphs.contains($0) }) {
            // Modifiers in any order: every modifier typed must be held, and the rest must be the key.
            let typed = Set(text.filter { glyphs.contains($0) })
            let held = Set(compact.filter { glyphs.contains($0) })
            let key = text.filter { !glyphs.contains($0) }
            let ownKey = compact.filter { !glyphs.contains($0) }.lowercased()
            return typed.isSubset(of: held) && (key.isEmpty || ownKey == key)
        }
        // Key names: "f5", "right arrow", "space". Short fragments would match every chord.
        let names = spoken.lowercased().split(separator: " ").map(String.init)
        let words = query.lowercased().split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy { word in names.contains { $0 == word || (word.count >= 3 && $0.hasPrefix(word)) } }
    }
}
