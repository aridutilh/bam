import AppKit

@main
struct ShortcutTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }

    @MainActor static func main() {
        do {
            try defaultsAndDisplay()
            try storeAssignsRefusesAndResets()
            try eventsBecomeCombos()
            try roundTripThroughDefaults()
            try everyMenuCommand()
            try legacyChordsMigrate()
            try filtersMatchKeys()
            print("All shortcut tests passed")
        } catch {
            print("FAILED: \(error)"); exit(1)
        }
    }

    static func defaultsAndDisplay() throws {
        try check(ShortcutCommand.newTab.defaultCombo == KeyCombo("t", .command), "⌘T default")
        try check(ShortcutCommand.nextSpace.defaultCombo.display == "⌥ ⌘ →", "arrow chord spells ⌥ ⌘ →, got \(ShortcutCommand.nextSpace.defaultCombo.display)")
        try check(KeyCombo("T", [.shift, .command]).display == "⇧ ⌘ T", "letters display uppercase")
        try check(KeyCombo("t", [.shift, .command]) == KeyCombo("T", [.command, .shift]), "combos compare case-insensitively")
        try check(KeyCombo(",", .command).spoken == "Command Comma", "spoken form")
        try check(Set(ShortcutCommand.allCases.map { $0.defaultCombo.display }).count == ShortcutCommand.allCases.count, "default chords are distinct")
    }

    @MainActor static func storeAssignsRefusesAndResets() throws {
        let store = ShortcutStore(); store.configure(persists: false)
        try check(store.isDefault(.toggleSidebar) && !store.anyCustom, "fresh store is all defaults")
        try check(store.set(KeyCombo("b", .command), for: .toggleSidebar), "assign ⌘B to the sidebar")
        try check(store.combo(for: .toggleSidebar) == KeyCombo("b", .command) && store.anyCustom, "store reports the new chord")
        try check(!store.set(KeyCombo("t", .command), for: .toggleSidebar), "a chord another command owns is refused")
        try check(store.combo(for: .toggleSidebar) == KeyCombo("b", .command), "refusal leaves the chord alone")
        try check(store.owner(of: KeyCombo("b", .command), besides: .newTab) == "Toggle sidebar", "owner lookup")
        store.reservedOwner = { $0 == KeyCombo("q", .command) ? "Quit Bam" : nil }
        try check(!store.set(KeyCombo("q", .command), for: .newTab), "a fixed menu chord is refused")
        try check(store.owner(of: KeyCombo("q", .command), besides: .newTab) == "Quit Bam", "and names its owner")
        try check(store.combo(for: .newTab) == ShortcutCommand.newTab.defaultCombo, "New tab keeps its chord")
        try check(store.set(KeyCombo("s", .command), for: .toggleSidebar) && store.isDefault(.toggleSidebar), "setting the default clears the override")
        store.set(KeyCombo("k", [.command, .option]), for: .keepTab)
        store.reset(.keepTab)
        try check(store.isDefault(.keepTab), "reset restores the default")
        store.set(KeyCombo("1", .control), for: .settings); store.set(KeyCombo("2", .control), for: .openLocation)
        store.resetAll()
        try check(!store.anyCustom, "resetAll clears everything")
    }

    static func event(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }
    static func eventsBecomeCombos() throws {
        try check(KeyCombo.from(event: event("k", .command)) == KeyCombo("k", .command), "⌘K records")
        try check(KeyCombo.from(event: event("k", [])) == nil, "a bare letter is not a shortcut")
        try check(KeyCombo.from(event: event("k", .shift)) == nil, "shift alone does not carry a letter")
        try check(KeyCombo.from(event: event("\u{1B}", .command)) == nil, "Escape never records")
        try check(KeyCombo.from(event: event("\u{7F}", .command)) == nil, "Delete never records")
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        try check(KeyCombo.from(event: event(right, [])) == nil, "a bare arrow would steal the caret, so it never records")
        try check(KeyCombo.from(event: event(right, [.command, .option]))?.display == "⌥ ⌘ →", "a carried arrow records")
        try check(KeyCombo.from(event: event("\u{F704}", []))?.display == "F1", "F1 records bare and spells F1")
        try check(KeyCombo.from(event: event("\u{F704}", .shift))?.display == "⇧ F1", "shifted F keys keep their name")
        try check(KeyCombo.from(event: event(" ", [])) == nil, "bare space is not a shortcut")
        try check(KeyCombo.from(event: event(" ", .command))?.display == "⌘ Space", "⌘Space records")
        // ⇧⌘1 arrives as "!" on a US keyboard; the chord keeps the unshifted key.
        let shiftedOne = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .command], timestamp: 0, windowNumber: 0,
                                          context: nil, characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: 18)!
        try check(KeyCombo.from(event: shiftedOne)?.display == "⇧ ⌘ 1", "shift is stripped from the key, got \(KeyCombo.from(event: shiftedOne)?.display ?? "nil")")
        try check(KeyCombo(",", .command).compact == "⌘,", "compact spelling")
    }

    @MainActor static func roundTripThroughDefaults() throws {
        let key = ShortcutStore.defaultsKey
        let saved = UserDefaults.standard.dictionary(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        let writer = ShortcutStore()
        writer.set(KeyCombo("y", [.command, .shift]), for: .settings)
        let reader = ShortcutStore()
        try check(reader.combo(for: .settings) == KeyCombo("y", [.command, .shift]), "a saved chord loads in a new store")
        writer.resetAll()
        try check(UserDefaults.standard.dictionary(forKey: key) == nil, "all defaults removes the saved entry")
        try check(ShortcutStore().isDefault(.settings), "and a new store is clean")
    }

    /// Every menu command is listed; chords move by takeover, can be removed, and reset takes the default back.
    @MainActor static func everyMenuCommand() throws {
        let store = ShortcutStore(); store.configure(persists: false)
        store.register([
            MenuShortcut(id: "newTab:", title: "New Tab", menu: "File", defaultCombo: KeyCombo("t", .command)),
            MenuShortcut(id: "copyCurrentURL:", title: "Copy Link", menu: "Edit", defaultCombo: KeyCombo("c", [.command, .shift])),
            MenuShortcut(id: "zoomIn:", title: "Zoom In", menu: "View", defaultCombo: KeyCombo("+", .command)),
            MenuShortcut(id: "newFolder:", title: "New Folder…", menu: "Tabs", defaultCombo: nil)
        ])
        try check(store.command("newTab:")?.title == "New Tab" && store.command("newTab:")?.menu == "File", "menu titles replace the built-in names")
        try check(store.catalog.first?.id == "newTab:", "catalog follows menu order")
        try check(store.command("settings") == nil && store.command("showSettings:") != nil, "built-ins stay known before their menu registers")
        try check(store.combo(forID: "newFolder:") == nil, "a command without a default has no chord")
        try check(store.assign(KeyCombo("f", [.command, .shift]), to: "newFolder:") == .assigned, "any command can get a chord")
        try check(store.combo(forID: "newFolder:") == KeyCombo("f", [.command, .shift]), "and wears it")
        let copy = KeyCombo("c", [.command, .shift])
        try check(store.assign(copy, to: "newFolder:") == .taken(by: "Copy Link"), "a chord in use is reported with its owner")
        try check(store.combo(forID: "newFolder:") == KeyCombo("f", [.command, .shift]), "and not assigned without takeover")
        try check(store.assign(copy, to: "newFolder:", takeOver: true) == .assigned, "takeover moves it")
        try check(store.combo(forID: "copyCurrentURL:") == nil && store.combo(forID: "newFolder:") == copy, "the old owner is left without one")
        store.reset(id: "copyCurrentURL:")
        try check(store.combo(forID: "copyCurrentURL:") == copy && store.combo(forID: "newFolder:") == nil, "reset takes the default back from whoever holds it")
        store.remove(id: "zoomIn:")
        try check(store.combo(forID: "zoomIn:") == nil && !store.isDefault(id: "zoomIn:"), "remove leaves no shortcut and counts as a change")
        store.register([MenuShortcut(id: "zoomIn:", title: "Zoom In", menu: "View", defaultCombo: KeyCombo("=", .command))])
        try check(store.command("zoomIn:")?.defaultCombo == KeyCombo("+", .command), "re-registering keeps the first default (menus may wear custom chords)")
        store.reservedOwner = { $0 == KeyCombo("1", [.command, .shift]) ? "1Password" : nil }
        try check(store.assign(KeyCombo("1", [.command, .shift]), to: "newTab:", takeOver: true) == .reserved(by: "1Password"), "an extension's chord can't be taken")
        store.resetAll()
        try check(!store.anyCustom && store.combo(forID: "zoomIn:") == KeyCombo("+", .command), "reset all restores every default")
    }

    /// 0.17–0.25 saved the seven remappable commands by name; they load under the menu ids, and removals persist.
    @MainActor static func legacyChordsMigrate() throws {
        let key = ShortcutStore.defaultsKey
        let saved = UserDefaults.standard.dictionary(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(["toggleSidebar": ["key": "b", "modifiers": NSEvent.ModifierFlags.command.rawValue]], forKey: key)
        let legacy = ShortcutStore()
        try check(legacy.combo(for: .toggleSidebar) == KeyCombo("b", .command), "a 0.25 chord still applies")
        try check(legacy.combo(forID: "toggleSidebar:") == KeyCombo("b", .command), "under the menu command's id")
        legacy.remove(id: "focusAddress:")
        let saved2 = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        try check(saved2["toggleSidebar:"] != nil && saved2["toggleSidebar"] == nil, "the next save writes the new key")
        let reader = ShortcutStore()
        try check(reader.combo(forID: "focusAddress:") == nil && reader.combo(for: .toggleSidebar) == KeyCombo("b", .command), "removed shortcuts stay removed")
    }

    static func filtersMatchKeys() throws {
        let copyLink = KeyCombo("c", [.command, .shift])
        try check(copyLink.matches("⇧⌘C") && copyLink.matches("⌘⇧c") && copyLink.matches("cmd shift c"), "glyphs and words, any order")
        try check(copyLink.matches("⌘") && !copyLink.matches("⌥"), "a modifier alone matches chords holding it")
        try check(!copyLink.matches("⇧⌘D") && !KeyCombo("c", .command).matches("⇧⌘C"), "other keys and missing modifiers don't")
        let right = KeyCombo(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        try check(right.matches("right arrow") && right.matches("opt cmd →"), "named keys")
        try check(!KeyCombo("t", .command).matches("ta"), "short fragments don't match key names")
    }
}
