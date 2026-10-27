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
        settings.select(.appearance)
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

        // Websites: the chips and the keep-awake list call the browser with real values.
        var zoom: Double?, font: Double?, awake: [(String, Bool)] = []
        var webActions = SettingsActions()
        webActions.setPageZoom = { zoom = $0 }
        webActions.setMinimumFontSize = { font = $0 }
        webActions.setKeepsSiteAwake = { awake.append(($0, $1)) }
        webActions.hostFromTyped = { $0.contains(".") ? $0.lowercased() : nil }
        let web = SettingsController(snapshot: {
            var s = SettingsSnapshot()
            s.zoomChoices = [0.9, 1, 1.1, 1.25]; s.pageZoom = 1
            s.fontChoices = [0, 9, 12, 14, 18]; s.minimumFontSize = 0
            s.keepAwakeHosts = ["web.whatsapp.com"]
            return s
        }, actions: webActions)
        web.select(.websites)
        settle()
        func control<T: NSView>(_ type: T.Type, _ label: String) -> T? {
            descendants(web.window.contentView!).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label }
        }
        control(BamChip.self, "125% page zoom")?.performClick(nil)
        require(zoom == 1.25, "Page zoom chip sets 125%")
        control(BamChip.self, "14 minimum font size")?.performClick(nil)
        require(font == 14, "Minimum font size chip sets 14 pt")
        require(control(BamChip.self, "125% page zoom")?.isPicked == true && control(BamChip.self, "100% page zoom")?.isPicked == false,
                "Zoom chips re-pick in place")
        control(SettingsIconButton.self, "Stop keeping web.whatsapp.com awake")?.performClick(nil)
        require(awake.first.map { $0.0 == "web.whatsapp.com" && !$0.1 } == true, "Removing a site stops keeping it awake")

        // Search finds rows by title and keyword, and shortcuts by name or keys.
        let store = ShortcutStore.shared
        store.configure(persists: false)
        store.register([MenuShortcut(id: "copyCurrentURL:", title: "Copy Link", menu: "Edit", defaultCombo: KeyCombo("c", [.command, .shift])),
                        MenuShortcut(id: "zoomIn:", title: "Zoom In", menu: "View", defaultCombo: KeyCombo("+", .command))])
        let zoomHits = web.search("zoom")
        require(zoomHits.first == SettingsSearchHit(section: .websites, title: "Page zoom", detail: zoomHits.first?.detail),
                "“zoom” finds Page zoom first, got \(zoomHits.map(\.title))")
        require(zoomHits.contains { $0.shortcutID == "zoomIn:" }, "and the Zoom In shortcut")
        require(web.search("ad blocker").first?.title == "Block ads and trackers", "keywords find the ad blocker")
        require(web.search("⇧⌘C").map(\.shortcutID) == ["copyCurrentURL:"], "keys find the command wearing them")
        require(web.search("nothing like this").isEmpty, "no results for nonsense")
        web.go(to: zoomHits[0])
        settle()
        require(web.section == .websites && web.searchField.stringValue.isEmpty, "a result opens its section")
        web.go(to: web.search("copy link")[0])
        settle()
        require(web.section == .shortcuts, "a shortcut result opens Shortcuts")
        let recorders = descendants(web.window.contentView!).compactMap { $0 as? BamShortcutRecorder }
        require(recorders.contains { $0.commandID == "copyCurrentURL:" } && recorders.count >= 2, "Shortcuts lists every registered command")
        // Links: the try field names the route that wins, and New Route saves a route.
        var savedRouting: LinkRouting?
        var linkActions = SettingsActions()
        linkActions.setLinkRouting = { savedRouting = $0 }
        let design = BrowserSpace.defaults[1]
        let links = SettingsController(snapshot: {
            var s = SettingsSnapshot()
            s.linkRouting = savedRouting ?? LinkRouting(routes: [LinkRoute(match: .contains, text: "figma.com", destination: .space(design.id))])
            return s
        }, actions: linkActions)
        links.select(.links)
        settle()
        require(links.linkTestDescription("www.figma.com/file/1").hasPrefix("Opens in \(design.name), by route 1"), "Try a link names the Space and route")
        require(links.linkTestDescription("example.com") == "Opens in Little Bam, the default. No route matches.", "and the default otherwise")
        require(links.linkTestDescription("not a link") == "That isn’t a web address.", "and says when it isn't a link")
        descendants(links.window.contentView!).compactMap { $0 as? BamPillButton }.first { $0.title == "New Route" }?.performClick(nil)
        require(savedRouting?.routes.count == 2 && savedRouting?.routes.last?.destination == .mostRecentSpace, "New Route adds a route to the Space you're in")
        require(links.search("air traffic").first?.section == .links, "search finds Air Traffic Control")
        print("PASS: \(checks) Settings appearance, websites, links and search checks")
    }
}
