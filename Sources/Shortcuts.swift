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
    /// keys), and bare letters or digits with no ⌘, ⌃ or ⌥ to carry them.
    static func from(event: NSEvent) -> KeyCombo? {
        guard let characters = event.charactersIgnoringModifiers, characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if scalar.value == 0x1B || scalar.value == 0x7F || scalar.value == 0xF728 { return nil }
        let functionKey = (0xF700...0xF8FF).contains(scalar.value)
        let carried = !flags.intersection([.command, .control, .option]).isEmpty
        guard functionKey || carried else { return nil }
        if !functionKey, scalar.properties.isWhitespace, !carried { return nil }
        return KeyCombo(characters, flags)
    }

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

/// Saved chords for the remappable commands. Menu items read it when they
/// are built and again whenever it changes; fresh previews never persist.
@MainActor final class ShortcutStore {
    static let shared = ShortcutStore()
    static let didChange = Notification.Name("BamShortcutsDidChange")
    static let defaultsKey = "Shortcuts"

    private(set) var persists = true
    private var custom: [ShortcutCommand: KeyCombo] = [:]

    init() { load() }

    /// Fresh previews start from the defaults and never write.
    func configure(persists: Bool) {
        self.persists = persists
        if !persists { custom = [:] }
    }

    func combo(for command: ShortcutCommand) -> KeyCombo { custom[command] ?? command.defaultCombo }
    func isDefault(_ command: ShortcutCommand) -> Bool { custom[command] == nil }
    var anyCustom: Bool { !custom.isEmpty }

    /// The other command already wearing this chord, if any.
    func owner(of combo: KeyCombo, besides command: ShortcutCommand) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { $0 != command && self.combo(for: $0) == combo }
    }

    /// Assigns a chord; a chord another command owns is refused so no
    /// shortcut silently goes dark.
    @discardableResult func set(_ combo: KeyCombo, for command: ShortcutCommand) -> Bool {
        guard owner(of: combo, besides: command) == nil else { return false }
        if combo == command.defaultCombo { custom.removeValue(forKey: command) } else { custom[command] = combo }
        save(); return true
    }
    func reset(_ command: ShortcutCommand) {
        guard custom.removeValue(forKey: command) != nil else { return }
        save()
    }
    func resetAll() {
        guard !custom.isEmpty else { return }
        custom = [:]; save()
    }

    private func load() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) else { return }
        for (name, value) in saved {
            guard let command = ShortcutCommand(rawValue: name), let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty, let raw = entry["modifiers"] as? UInt else { continue }
            let combo = KeyCombo(key, NSEvent.ModifierFlags(rawValue: raw))
            if combo != command.defaultCombo { custom[command] = combo }
        }
    }
    private func save() {
        if persists {
            var payload: [String: [String: Any]] = [:]
            for (command, combo) in custom { payload[command.rawValue] = ["key": combo.key, "modifiers": combo.modifiers.rawValue] }
            if payload.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
            else { UserDefaults.standard.set(payload, forKey: Self.defaultsKey) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
