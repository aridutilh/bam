import AppKit

/// Bam's window appearance: follow macOS, or always light or dark.
/// Applied app-wide through `NSApp.appearance`, so the browser window,
/// Little Bam, Settings, onboarding and sheets all agree. Picture in Picture
/// stays dark on purpose: it is a video surface.
enum BrowserAppearance: String, CaseIterable {
    case system, light, dark
    static let defaultsKey = "BrowserAppearance"
    static let didChange = Notification.Name("BamBrowserAppearanceDidChange")

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor private(set) static var current: BrowserAppearance = .system
    @MainActor private static var persists = true

    /// Restores the saved choice. Disposable previews start from System and never write it.
    @MainActor static func restore(persists: Bool, defaults: UserDefaults = .standard) {
        self.persists = persists
        let saved = persists ? defaults.string(forKey: defaultsKey).flatMap(BrowserAppearance.init(rawValue:)) : nil
        apply(saved ?? .system, defaults: defaults)
    }
    @MainActor static func apply(_ value: BrowserAppearance, defaults: UserDefaults = .standard) {
        current = value
        if persists { defaults.set(value.rawValue, forKey: defaultsKey) }
        NSApp.appearance = value.appearance
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

extension NSAppearance {
    var isDarkChrome: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    /// A color that resolves per appearance whenever AppKit draws with it.
    static func chrome(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDarkChrome ? dark : light }
    }
    convenience init(spaceTheme color: SpaceTheme.RGBA) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
    /// The window gradient for a Space with an imported theme, or nil when the
    /// Space uses its flat color (no theme, Prism/Clear, or a theme Bam's
    /// sidebar text can't be read over in this appearance).
    static func themedCanvas(_ theme: SpaceTheme?, colorIndex: Int, dark: Bool) -> [NSColor]? {
        guard let theme, (0..<BrowserSpace.flatColorCount).contains(colorIndex),
              let stops = theme.canvasStops(dark: dark) else { return nil }
        return stops.map(NSColor.init(spaceTheme:))
    }
}

/// Resolves a dynamic color for a CALayer, which only stores a fixed CGColor.
@MainActor func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
    var result = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
    return result
}
