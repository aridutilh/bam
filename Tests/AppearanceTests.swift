import AppKit

/// Browser Appearance preference and sidebar color tokens. Offscreen; no
/// window is ordered front and the user's own defaults are never touched.
@main enum AppearanceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let suite = "com.ari.bam.appearance-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Preference: System by default, persisted choices restore, previews never write.
        BrowserAppearance.restore(persists: true, defaults: defaults)
        require(BrowserAppearance.current == .system && NSApp.appearance == nil, "Default follows macOS")
        BrowserAppearance.apply(.light, defaults: defaults)
        require(NSApp.appearance?.name == .aqua && defaults.string(forKey: BrowserAppearance.defaultsKey) == "light", "Light applies and persists")
        BrowserAppearance.apply(.dark, defaults: defaults)
        require(NSApp.appearance?.name == .darkAqua, "Dark applies app-wide")
        BrowserAppearance.restore(persists: true, defaults: defaults)
        require(BrowserAppearance.current == .dark, "Saved choice restores at launch")
        defaults.set("sepia", forKey: BrowserAppearance.defaultsKey)
        BrowserAppearance.restore(persists: true, defaults: defaults)
        require(BrowserAppearance.current == .system, "Unknown saved values fall back to System")
        let previewSuite = "\(suite).preview", previewDefaults = UserDefaults(suiteName: previewSuite)!
        defer { previewDefaults.removePersistentDomain(forName: previewSuite) }
        previewDefaults.set("dark", forKey: BrowserAppearance.defaultsKey)
        BrowserAppearance.restore(persists: false, defaults: previewDefaults)
        BrowserAppearance.apply(.light, defaults: previewDefaults)
        require(BrowserAppearance.current == .light && previewDefaults.string(forKey: BrowserAppearance.defaultsKey) == "dark",
                "Disposable previews start from System and never write the preference")
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: BrowserAppearance.didChange, object: nil, queue: nil) { _ in notified += 1 }
        BrowserAppearance.apply(.system, defaults: previewDefaults)
        NotificationCenter.default.removeObserver(token)
        require(notified == 1 && NSApp.appearance == nil, "Changes are announced so menus and Settings stay in step")

        // Tokens resolve per appearance; dark values are unchanged from the shipped look.
        func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
            var result = color
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB)! }
            return result
        }
        func luminance(_ color: NSColor) -> CGFloat {
            func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let (x, y) = (luminance(a), luminance(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let darkInk = resolved(ArkPalette.ink, .darkAqua), lightInk = resolved(ArkPalette.ink, .aqua)
        require(abs(darkInk.whiteComponentApprox - 0.94) < 0.01, "Dark ink keeps its shipped value")
        // The darkest light window wash Bam uses, and its sidebar selection.
        let lightWash = NSColor(srgbRed: 0.86, green: 0.92, blue: 0.96, alpha: 1)
        require(contrast(lightInk, lightWash) >= 7, "Light sidebar text reads as body text (≥7:1)")
        require(contrast(resolved(ArkPalette.secondary, .aqua), lightWash) >= 4.5, "Light secondary text meets 4.5:1")
        for index in 0..<6 {
            let tint = resolved(ArkPalette.spaceTint(index), .aqua)
            require(contrast(tint, lightWash) >= 3, "Space \(index) icon tint is visible on light chrome (≥3:1)")
            require(resolved(ArkPalette.spaceTint(index), .darkAqua).isEqualIgnoringAlpha(resolved(ArkPalette.spaceColor(index), .darkAqua)),
                    "Space \(index) keeps its pastel on dark chrome")
        }
        require(ArkPalette.spaceTint(2) === ArkPalette.spaceTint(2), "Space tints are stable objects for cheap change checks")
        let lightSelection = resolved(ArkPalette.selection, .aqua), darkSelection = resolved(ArkPalette.selection, .darkAqua)
        require(lightSelection.alphaComponent > 0.8 && darkSelection.alphaComponent < 0.2, "Light selection is a lifted white card; dark keeps its wash")
        print("PASS: \(checks) appearance preference and color token checks")
    }
}

private extension NSColor {
    var whiteComponentApprox: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }
    func isEqualIgnoringAlpha(_ other: NSColor) -> Bool {
        abs(redComponent - other.redComponent) < 0.01 && abs(greenComponent - other.greenComponent) < 0.01 && abs(blueComponent - other.blueComponent) < 0.01
    }
}
