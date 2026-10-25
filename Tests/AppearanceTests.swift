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

        // Imported Space themes: own window gradient and accent per appearance;
        // flat colors stay for unthemed Spaces and for Prism/Clear.
        func rgba(_ r: Double, _ g: Double, _ b: Double) -> SpaceTheme.RGBA { SpaceTheme.RGBA(red: r, green: g, blue: b)! }
        let theme = SpaceTheme(gradient: [rgba(0.62, 0.78, 0.96), rgba(0.95, 0.70, 0.80)],
                               light: .init(background: rgba(0.95, 0.94, 0.97), backgroundExtra: nil, title: rgba(0.08, 0.08, 0.10), subtitle: nil),
                               dark: .init(background: rgba(0.10, 0.10, 0.13), backgroundExtra: nil, title: rgba(0.95, 0.95, 0.97), subtitle: nil),
                               accent: rgba(0.40, 0.55, 0.90), accentLight: rgba(0.80, 0.86, 0.98), accentDark: rgba(0.30, 0.40, 0.70))!
        let themed = BrowserSpace(id: 5, name: "Themed", symbol: "globe", colorIndex: 2, theme: theme)
        let lightCanvas = NSColor.themedCanvas(theme, colorIndex: 2, dark: false)!, darkCanvas = NSColor.themedCanvas(theme, colorIndex: 2, dark: true)!
        require(lightCanvas.count == 2 && !lightCanvas[0].isEqualIgnoringAlpha(lightCanvas[1]), "A themed Space draws its own two-color gradient")
        // Bam's own dark Space gradients sit around 0.2–0.3; themed ones match.
        require(lightCanvas.allSatisfy { $0.whiteComponentApprox > 0.6 } && darkCanvas.allSatisfy { $0.whiteComponentApprox < 0.36 },
                "The themed gradient follows the window's light or dark appearance")
        require(NSColor.themedCanvas(nil, colorIndex: 2, dark: false) == nil && NSColor.themedCanvas(theme, colorIndex: BrowserSpace.prismColorIndex, dark: false) == nil,
                "Unthemed Spaces and Prism/Clear keep Bam's own backgrounds")
        let themedTint = ArkPalette.spaceTint(for: themed)
        require(themedTint === ArkPalette.spaceTint(for: themed), "A themed tint is one stable object per theme")
        require(!resolved(themedTint, .aqua).isEqualIgnoringAlpha(resolved(ArkPalette.spaceTint(2), .aqua))
                && !resolved(themedTint, .aqua).isEqualIgnoringAlpha(resolved(themedTint, .darkAqua)),
                "The accent is the theme's own, different in light and dark")
        require(ArkPalette.spaceTint(for: BrowserSpace(id: 6, name: "Plain", symbol: "globe", colorIndex: 2)) === ArkPalette.spaceTint(2),
                "An unthemed Space keeps its flat tint")
        print("PASS: \(checks) appearance preference and color token checks")
    }
}

private extension NSColor {
    var whiteComponentApprox: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }
    func isEqualIgnoringAlpha(_ other: NSColor) -> Bool {
        abs(redComponent - other.redComponent) < 0.01 && abs(greenComponent - other.greenComponent) < 0.01 && abs(blueComponent - other.blueComponent) < 0.01
    }
}
