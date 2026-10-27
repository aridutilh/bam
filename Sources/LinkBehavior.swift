import Foundation

/// Settings › Links toggles, as in Arc's Links pane. Saved in preferences for normal launches;
/// fresh previews and fixtures keep them in memory. Everything defaults on, as in Arc, except the
/// global ⌥⌘N: it starts off everywhere, because Arc and Yab answer the same system-wide key and
/// people switching from them would get two windows per press. Turning it on is one switch.
enum LinkBehavior {
    enum Toggle: String, CaseIterable {
        /// ⌥⌘N opens Little Bam from any app.
        case globalLittleBamKey = "GlobalLittleBamHotKey"
        /// ⌥⌘-click on a link opens it in Little Bam.
        case optionCommandClickLittleBam = "OptionCommandClickLittleBam"
        /// Shift-click on a link opens it in Peek.
        case shiftClickPeek = "ShiftClickPeek"
        /// A link from a kept tab or Favorite to another site opens in Peek.
        case peekOtherSitesFromSaved = "PeekOtherSitesFromSaved"
    }
    /// How long a Little Bam window may sit unused before it closes into the archive. Arc's choices.
    enum LittleBamArchive: String, CaseIterable {
        case oneHour, sixHours, twelveHours
        var seconds: TimeInterval { self == .oneHour ? 3600 : self == .sixHours ? 6 * 3600 : 12 * 3600 }
        var title: String { self == .oneHour ? "1 hour" : self == .sixHours ? "6 hours" : "12 hours" }
        static let standard = LittleBamArchive.sixHours
    }
    static let littleBamArchiveKey = "LittleBamArchiveAfter"

    nonisolated(unsafe) static var defaults: UserDefaults? = isDisposableLaunch(CommandLine.arguments) ? nil : .standard
    nonisolated(unsafe) private static var memory: [Toggle: Bool] = [:]
    nonisolated(unsafe) private static var memoryArchive = LittleBamArchive.standard

    static func isDisposableLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--fresh-preview" || $0 == "--vendor-extension-probe" || ($0.hasPrefix("--") && $0.hasSuffix("-test")) }
    }
    static func isOn(_ toggle: Toggle) -> Bool {
        if let defaults { return defaults.object(forKey: toggle.rawValue) == nil ? toggle != .globalLittleBamKey : defaults.bool(forKey: toggle.rawValue) }
        return memory[toggle] ?? (toggle != .globalLittleBamKey)
    }
    static func set(_ toggle: Toggle, _ on: Bool) {
        if let defaults { defaults.set(on, forKey: toggle.rawValue) } else { memory[toggle] = on }
    }
    static var littleBamArchive: LittleBamArchive {
        get {
            guard let defaults else { return memoryArchive }
            return defaults.string(forKey: littleBamArchiveKey).flatMap(LittleBamArchive.init(rawValue:)) ?? .standard
        }
        set { if let defaults { defaults.set(newValue.rawValue, forKey: littleBamArchiveKey) } else { memoryArchive = newValue } }
    }

    /// What a link click should do, from its modifiers and where it came from. Pure, for tests.
    enum ClickResult: Equatable { case littleBam, newTab, peek, navigate }
    static func click(command: Bool, option: Bool, shift: Bool, fromSavedToOtherSite: Bool, sourceVisible: Bool,
                      isOn: (Toggle) -> Bool = LinkBehavior.isOn) -> ClickResult {
        if command && option && isOn(.optionCommandClickLittleBam) { return .littleBam }
        if command { return .newTab }
        guard sourceVisible else { return .navigate }
        if shift && isOn(.shiftClickPeek) { return .peek }
        if fromSavedToOtherSite && isOn(.peekOtherSitesFromSaved) { return .peek }
        return .navigate
    }
}
