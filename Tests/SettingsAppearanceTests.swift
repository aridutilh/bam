import AppKit

/// Stand-in for the browser's flipped container, which lives in
/// BrowserController.swift and is not needed for these Settings checks.
@MainActor final class FlippedContainer: NSView { override var isFlipped: Bool { true } }

/// Appearance chips in Settings: changes from the chips or the View menu update
/// the chips in place, so keyboard focus stays on the control. Offscreen: the
/// Settings window is never ordered front and no system input is posted.
@main enum SettingsAppearanceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        BrowserAppearance.restore(persists: false)  // Never touches real defaults.
        var actions = SettingsActions()
        actions.setAppearance = { BrowserAppearance.apply($0) }
        let settings = SettingsController(snapshot: { var s = SettingsSnapshot(); s.appearance = BrowserAppearance.current; return s },
                                          actions: actions)
        // The app forwards every change to Settings exactly like this.
        let token = NotificationCenter.default.addObserver(forName: BrowserAppearance.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { settings.syncAppearance() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.select(.general)
        settle()
        func chips() -> [BamChip] {
            descendants(settings.window.contentView!).compactMap { $0 as? BamChip }.filter { $0.accessibilityLabel()?.hasSuffix(" appearance") == true }
        }
        let original = chips()
        require(original.count == 3 && original.map(\.title) == ["System", "Light", "Dark"], "Three appearance chips")
        require(original[0].isPicked && !original[1].isPicked, "System starts picked")

        for (index, choice) in [(1, BrowserAppearance.light), (2, .dark), (0, .system)] {
            let chip = chips()[index]
            settings.window.makeFirstResponder(chip)
            let focused = settings.window.firstResponder
            chip.performClick(nil)   // What Space/Return does for a focused chip.
            settle()
            let after = chips()
            require(BrowserAppearance.current == choice, "\(choice.title) applied")
            require(zip(after, original).allSatisfy { $0 === $1 }, "\(choice.title): chips are updated in place, not rebuilt")
            require(after.enumerated().allSatisfy { $0.element.isPicked == ($0.offset == index) }, "\(choice.title): only that chip is picked")
            require(settings.window.firstResponder === focused, "\(choice.title): keyboard focus stays where it was")
        }

        // A change from View ▸ Appearance also updates the open Settings in place.
        let focusedBefore = settings.window.firstResponder
        BrowserAppearance.apply(.light)
        settle()
        require(zip(chips(), original).allSatisfy { $0 === $1 } && chips()[1].isPicked && !chips()[0].isPicked,
                "Menu changes re-pick chips without rebuilding Settings")
        require(settings.window.firstResponder === focusedBefore, "Menu changes leave Settings focus alone")
        BrowserAppearance.apply(.system)
        print("PASS: \(checks) Settings appearance focus checks")
    }
}
