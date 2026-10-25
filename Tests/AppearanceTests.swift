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
        // The sidebar draws exactly the ink the theme contrast checks use.
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let ink = resolved(ArkPalette.ink, name), secondary = resolved(ArkPalette.secondary, name)
            let expectedInk = BamInk.primary(dark: dark), expectedSecondary = BamInk.secondary(dark: dark)
            require(abs(ink.redComponent - expectedInk.red) < 0.002 && abs(secondary.redComponent - expectedSecondary.red) < 0.002,
                    "Sidebar ink matches the theme contrast reference (dark: \(dark))")
        }
        // A theme Bam's ink can't be read over in light falls back to the flat
        // canvas and flat tint there, and keeps both in dark.
        let invertedLight = SpaceTheme(gradient: theme.gradient,
                                       light: .init(background: rgba(0.12, 0.12, 0.14), backgroundExtra: nil, title: rgba(1, 1, 1), subtitle: nil),
                                       dark: theme.dark, accent: theme.accent, accentLight: theme.accentLight, accentDark: theme.accentDark)!
        let inverted = BrowserSpace(id: 7, name: "Inverted", symbol: "globe", colorIndex: 2, theme: invertedLight)
        require(NSColor.themedCanvas(invertedLight, colorIndex: 2, dark: false) == nil && NSColor.themedCanvas(invertedLight, colorIndex: 2, dark: true) != nil,
                "An unreadable light theme draws Bam's flat light background")
        let invertedTint = ArkPalette.spaceTint(for: inverted)
        require(resolved(invertedTint, .aqua).isEqualIgnoringAlpha(resolved(ArkPalette.spaceTint(2), .aqua))
                && !resolved(invertedTint, .darkAqua).isEqualIgnoringAlpha(resolved(ArkPalette.spaceTint(2), .darkAqua)),
                "The tint follows: flat where the canvas is flat, themed where it's themed")
        // The same theme on Spaces with different flat colors falls back to each one's own tint.
        let invertedOther = BrowserSpace(id: 8, name: "Inverted other", symbol: "globe", colorIndex: 4, theme: invertedLight)
        let otherTint = ArkPalette.spaceTint(for: invertedOther)
        require(otherTint !== invertedTint && resolved(otherTint, .aqua).isEqualIgnoringAlpha(resolved(ArkPalette.spaceTint(4), .aqua))
                && ArkPalette.spaceTint(for: invertedOther) === otherTint,
                "A cached themed tint is per theme and color: each Space's fallback is its own flat tint")

        // Light surface hierarchy (Yab): recessed tiles, a softer field, and the
        // selection as the only bright white card. Dark surfaces are unchanged.
        let lightTile = resolved(ArkPalette.tile, .aqua), lightHover = resolved(ArkPalette.tileHover, .aqua)
        let lightField = resolved(ArkPalette.field, .aqua), lightSelectedRow = resolved(ArkPalette.selection, .aqua)
        let lightActiveTile = resolved(ArkPalette.tileActive, .aqua)
        require(lightTile.whiteComponentApprox < 0.01 && lightTile.alphaComponent > 0.02 && lightTile.alphaComponent < 0.08
                && lightHover.whiteComponentApprox < 0.01 && lightHover.alphaComponent > lightTile.alphaComponent,
                "Light Favorite tiles are recessed (darker) washes, with a visible hover")
        require(lightField.whiteComponentApprox > 0.99 && lightField.alphaComponent < lightSelectedRow.alphaComponent
                && lightField.alphaComponent < lightActiveTile.alphaComponent,
                "The light field is a softer wash than the selected row or tile")
        let darkTokens: [(NSColor, CGFloat, CGFloat)] = [(ArkPalette.tile, 1, 0.09), (ArkPalette.tileHover, 1, 0.15), (ArkPalette.tileActive, 1, 0.22),
                                                         (ArkPalette.field, 1, 0.09), (ArkPalette.fieldHover, 1, 0.14), (ArkPalette.tileRing, 1, 0.28)]
        require(darkTokens.allSatisfy { color, white, alpha in
            let value = resolved(color, .darkAqua); return abs(value.whiteComponentApprox - white) < 0.01 && abs(value.alphaComponent - alpha) < 0.005
        }, "Dark tiles and field keep their exact previous values")

        // Monograms: first letter/number/emoji of the title, else the host.
        require(Monogram.make(title: "team docs", address: "https://docs.example.com/") == "T", "A title's first letter, uppercased")
        require(Monogram.make(title: "(7) Weekly notes", address: "https://x.example/") == "7", "Leading punctuation is skipped")
        require(Monogram.make(title: "🎨 Design", address: "https://x.example/") == "🎨", "A leading emoji is kept as the mark")
        require(Monogram.make(title: "❤️ Notes", address: "https://x.example/") == "❤️"
                && Monogram.make(title: "☀️ Weather", address: "https://x.example/") == "☀️",
                "Text-default emoji made emoji by VS16 are kept whole, not skipped to the next letter")
        require(Monogram.make(title: "1️⃣ First", address: "https://x.example/") == "1️⃣"
                && Monogram.make(title: "👩‍💻 Code", address: "https://x.example/") == "👩‍💻",
                "Keycap and ZWJ emoji sequences are kept whole")
        require(Monogram.make(title: "1 First", address: "https://x.example/") == "1" && Monogram.make(title: "❤ Notes", address: "https://x.example/") == "N",
                "A plain digit stays a digit; a bare text-style symbol without VS16 isn't treated as an emoji")
        require(Monogram.make(title: "", address: "https://www.alpha.example/") == "A"
                && Monogram.make(title: "https://www.alpha.example/", address: "https://www.alpha.example/") == "A"
                && Monogram.make(title: "beta.example", address: "https://beta.example/") == "B",
                "An empty title, or one that is just the address or host, uses the host without www")
        require(Monogram.make(title: "école", address: "https://x.example/") == "É" && Monogram.make(title: "ßeta", address: "https://x.example/") == "ß",
                "Non-Latin letters uppercase only when that keeps one character")
        require(Monogram.make(title: "  ", address: "orbit://newtab") == nil && Monogram.make(title: "…", address: "not a url") == nil,
                "Nothing to show means no monogram (the symbol stays)")
        let plainTab = BrowserTab(title: "Gamma", address: "https://gamma.example/", space: 0)
        var customTab = plainTab; customTab.saved = SavedTabState(kind: .kept, address: plainTab.address, customSymbol: "book")
        require(plainTab.monogram == "G" && customTab.monogram == nil
                && BrowserTab(title: "Code", address: "https://github.com/x", space: 0).monogram == nil
                && BrowserTab(title: "Home", address: "orbit://newtab", space: 0).monogram == nil
                && BrowserTab(title: "Sketch", address: ArcEaselReference.address(for: UUID()), space: 0).monogram == nil,
                "Custom and special symbols win over monograms")
        // The mark (Bam ink) reads on its disc over the sidebar in both appearances, for every Space tint.
        func composite(_ top: NSColor, alpha: CGFloat, over base: CGFloat) -> SpaceTheme.RGBA {
            SpaceTheme.RGBA(red: Double(top.redComponent * alpha + base * (1 - alpha)), green: Double(top.greenComponent * alpha + base * (1 - alpha)),
                            blue: Double(top.blueComponent * alpha + base * (1 - alpha)))!
        }
        for index in 0..<BrowserSpace.flatColorCount {
            let lightDisc = composite(resolved(ArkPalette.spaceTint(index), .aqua), alpha: ArkMonogram.tintAlpha.light, over: 0.88)
            let darkDisc = composite(resolved(ArkPalette.spaceTint(index), .darkAqua), alpha: ArkMonogram.tintAlpha.dark, over: 0.20)
            require(lightDisc.contrast(with: BamInk.primary(dark: false)) >= 4.5 && darkDisc.contrast(with: BamInk.primary(dark: true)) >= 4.5,
                    "Monogram marks read on Space \(index)'s disc in light and dark")
        }
        print("PASS: \(checks) appearance preference and color token checks")
    }
}

private extension NSColor {
    var whiteComponentApprox: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }
    func isEqualIgnoringAlpha(_ other: NSColor) -> Bool {
        abs(redComponent - other.redComponent) < 0.01 && abs(greenComponent - other.greenComponent) < 0.01 && abs(blueComponent - other.blueComponent) < 0.01
    }
}
