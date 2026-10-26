import AppKit

/// What the person chose in Bam's quit confirmation.
enum QuitConfirmationChoice: Equatable { case cancel, quit, quitAndStopAsking }

/// "Ask before quitting" — on unless the person explicitly chose "don't ask again".
/// Settings › General turns it back on.
struct QuitConfirmationPreference {
    static let key = "BamAskBeforeQuitting"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var asksBeforeQuitting: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The decisions behind the quit confirmation, free of AppKit so they can be tested.
enum QuitConfirmationModel {
    /// "Bam" or "Bam Preview": the running app's own display name.
    static func appName(info: [String: Any]?) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info?[key] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return "Bam"
    }
    static func title(appName: String) -> String { "Quit \(appName)?" }

    /// Escape cancels and Return (or Enter) quits; any modifier leaves the key alone.
    static func choice(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> QuitConfirmationChoice? {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 53: return .cancel
        case 36, 76: return .quit
        default: return nil
        }
    }

    /// Whether to quit. "Don't ask again" is remembered only when `persist` is true
    /// (a private window's choice must not change the normal browser's preference).
    static func resolve(_ choice: QuitConfirmationChoice, preference: QuitConfirmationPreference, persist: Bool) -> Bool {
        switch choice {
        case .cancel: return false
        case .quit: return true
        case .quitAndStopAsking:
            if persist { preference.asksBeforeQuitting = false }
            return true
        }
    }
}
