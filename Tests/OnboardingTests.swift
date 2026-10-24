import Foundation

@main
struct OnboardingTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
        count += 1
    }

    static func main() {
        do {
            try gateDecidesWhoIsWelcomed()
            try stepFlowSkipsAndBounds()
            try shortcutTrainingAndBookmarkSelection()
            try namesFallBackToStudio()
            try chromeBookmarkBarParsing()
            try applicationPersonalizesTheFirstSpace()
            try applicationRespectsExistingFavoritesAndTheCap()
        } catch {
            print("FAIL: Onboarding — \(error)"); exit(1)
        }
        print("PASS: Onboarding — gating, step flow, shortcut training, Chrome bookmark parsing, and session application (\(count) checks)")
    }

    // MARK: Gate

    static func gateDecidesWhoIsWelcomed() throws {
        try expect(OnboardingGate.shouldPresent(arguments: [], sessionFileExists: false, completed: false),
                   "A true first run is welcomed")
        try expect(!OnboardingGate.shouldPresent(arguments: [], sessionFileExists: true, completed: false),
                   "An existing profile is not welcomed as new")
        try expect(!OnboardingGate.shouldPresent(arguments: [], sessionFileExists: false, completed: true),
                   "A completed welcome never repeats on its own")
        try expect(!OnboardingGate.shouldPresent(arguments: ["--fresh-preview"], sessionFileExists: false, completed: false),
                   "Ordinary fresh previews stay undisturbed")
        try expect(OnboardingGate.shouldPresent(arguments: ["--fresh-preview", "--onboarding"], sessionFileExists: false, completed: false),
                   "--onboarding forces the welcome in a preview")
        try expect(OnboardingGate.shouldPresent(arguments: ["--onboarding"], sessionFileExists: true, completed: true),
                   "--onboarding forces the welcome over any profile")
        for argument in OnboardingGate.testArguments {
            try expect(!OnboardingGate.shouldPresent(arguments: [argument, "--onboarding"], sessionFileExists: false, completed: false),
                       "Fixtures never see onboarding (\(argument))")
        }
        try expect(OnboardingGate.shouldGrandfather(arguments: [], sessionFileExists: true, completed: false),
                   "Pre-onboarding profiles are grandfathered")
        try expect(!OnboardingGate.shouldGrandfather(arguments: ["--fresh-preview"], sessionFileExists: true, completed: false),
                   "Previews never write the grandfather flag")
        try expect(!OnboardingGate.shouldGrandfather(arguments: ["--feature-test"], sessionFileExists: true, completed: false),
                   "Fixtures never write the grandfather flag")
        try expect(!OnboardingGate.shouldGrandfather(arguments: [], sessionFileExists: false, completed: false),
                   "A first run is welcomed, not grandfathered")
    }

    // MARK: Step flow

    static func stepFlowSkipsAndBounds() throws {
        var model = OnboardingModel()
        try expect(model.steps == [.hello, .color, .name, .shortcuts, .defaultBrowser, .finale],
                   "No bookmarks means no favorites step")
        try expect(model.isFirstStep && !model.isLastStep, "Flow starts at hello")
        model.goBack()
        try expect(model.step == .hello, "Back from the first step holds position")
        for _ in 0..<10 { model.advance() }
        try expect(model.step == .finale && model.isLastStep, "Advance clamps at the finale")
        model.goBack()
        try expect(model.step == .defaultBrowser, "Back returns to the previous step")

        var withBookmarks = OnboardingModel(bookmarks: [OnboardingBookmark(title: "A", address: "https://a.example")])
        try expect(withBookmarks.steps.contains(.favorites), "Found bookmarks add the favorites step")
        withBookmarks.advance(); withBookmarks.advance(); withBookmarks.advance()
        try expect(withBookmarks.step == .favorites, "Favorites follows naming when offered")
    }

    static func shortcutTrainingAndBookmarkSelection() throws {
        var model = OnboardingModel()
        try expect(!model.recordShortcut("t"), "Training only counts on the shortcuts step")
        while model.step != .shortcuts { model.advance() }
        try expect(model.recordShortcut("t"), "First ⌘T counts")
        try expect(!model.recordShortcut("t"), "Repeats do not count twice")
        try expect(!model.recordShortcut("x"), "Unrelated keys never count")
        try expect(!model.shortcutsDone, "One of two moves is not done")
        try expect(model.recordShortcut("s") && model.shortcutsDone, "Both moves complete the step")

        let bookmarks = (1...8).map { OnboardingBookmark(title: "B\($0)", address: "https://b\($0).example") }
        var selection = OnboardingModel(bookmarks: bookmarks)
        try expect(selection.selectedBookmarkAddresses.count == OnboardingModel.preselectedFavorites,
                   "The first few bookmarks are preselected")
        selection.toggleBookmark("https://b1.example")
        try expect(!selection.selectedBookmarkAddresses.contains("https://b1.example"), "Toggling removes a pick")
        selection.toggleBookmark("https://b8.example")
        try expect(selection.selectedBookmarkAddresses.contains("https://b8.example"), "Toggling adds a pick")
        selection.toggleBookmark("https://nowhere.example")
        try expect(selection.result.favorites.count == 6, "Unknown addresses change nothing")
    }

    static func namesFallBackToStudio() throws {
        var model = OnboardingModel()
        model.spaceName = "   "
        try expect(model.result.spaceName == "Studio", "Blank names fall back")
        model.spaceName = "  My Lab  "
        try expect(model.result.spaceName == "My Lab", "Names are trimmed")
        model.spaceName = String(repeating: "x", count: 61)
        try expect(model.result.spaceName == "Studio", "Overlong names fall back")
        model.spaceName = "a\u{0007}b"
        try expect(model.result.spaceName == "Studio", "Control characters fall back")
    }

    // MARK: Chrome parsing

    static func chromeBookmarkBarParsing() throws {
        func entry(_ title: String, _ url: String) -> String {
            "{\"type\": \"url\", \"name\": \"\(title)\", \"url\": \"\(url)\"}"
        }
        let json = """
        {"roots": {"bookmark_bar": {"children": [
            \(entry("GitHub", "https://github.com")),
            \(entry("Dup", "https://github.com")),
            \(entry("Script", "javascript:alert(1)")),
            \(entry("Local", "file:///etc/passwd")),
            \(entry("", "https://example.com/page")),
            {"type": "folder", "name": "Tools", "children": [
                \(entry("Nested", "https://nested.example")),
                {"type": "folder", "name": "Deeper", "children": [\(entry("TooDeep", "https://toodeep.example"))]}
            ]}
        ]}, "other": {"children": [\(entry("Elsewhere", "https://other.example"))]}}}
        """
        let found = ChromeBookmarks.parse(Data(json.utf8))
        try expect(found.map(\.address) == ["https://github.com", "https://example.com/page", "https://nested.example"],
                   "Bar entries parse in order: deduplicated, HTTP(S) only, one folder deep, bar only — got \(found.map(\.address))")
        try expect(found[1].title == "example.com", "Untitled bookmarks fall back to their host")
        try expect(ChromeBookmarks.parse(Data("not json".utf8)).isEmpty, "Garbage input parses to nothing")
        try expect(ChromeBookmarks.parse(Data("{\"roots\": {}}".utf8)).isEmpty, "A missing bar parses to nothing")

        let many = (1...20).map { entry("B\($0)", "https://b\($0).example") }.joined(separator: ",")
        let capped = ChromeBookmarks.parse(Data("{\"roots\": {\"bookmark_bar\": {\"children\": [\(many)]}}}".utf8))
        try expect(capped.count == ChromeBookmarks.maximumOffered, "The offer stays within its cap")

        try expect(ChromeBookmarks.load(from: URL(fileURLWithPath: "/nonexistent/Bookmarks")).isEmpty,
                   "A missing store loads as no offer")
    }

    // MARK: Application

    static func applicationPersonalizesTheFirstSpace() throws {
        var session = BrowserSession.fresh()
        let result = OnboardingResult(spaceName: "My Lab", spaceSymbol: "bolt", colorIndex: 3,
                                      favorites: [OnboardingBookmark(title: "GitHub", address: "https://github.com"),
                                                  OnboardingBookmark(title: "", address: "https://example.com")])
        try expect(OnboardingApplication.apply(result, to: &session), "Applying reports the change")
        let first = session.spaces[0]
        try expect(first.name == "My Lab" && first.symbol == "bolt" && first.colorIndex == 3,
                   "The first Space takes the chosen identity")
        let favorites = session.favoriteTabs
        try expect(favorites.count == 2, "Chosen bookmarks become favorites")
        try expect(favorites.allSatisfy { $0.isUnloaded }, "Imported favorites wait unloaded until selected")
        try expect(favorites.first?.saved?.customTitle == "GitHub", "Imported titles are kept")
        try expect(session.tabs.count > 2, "Existing tabs survive the import")

        var invalidSymbol = BrowserSession.fresh()
        OnboardingApplication.apply(OnboardingResult(spaceName: "Ok", spaceSymbol: "not-a-symbol",
                                                     colorIndex: 0, favorites: []), to: &invalidSymbol)
        try expect(invalidSymbol.spaces[0].symbol == "sparkles", "Unknown symbols normalize safely")
    }

    static func applicationRespectsExistingFavoritesAndTheCap() throws {
        var session = BrowserSession.fresh()
        _ = session.setRetention(id: session.tabs[0].id, kind: .favorite)
        let existing = session.tabs[0].address
        let flood = (1...20).map { OnboardingBookmark(title: "B\($0)", address: "https://b\($0).example") }
            + [OnboardingBookmark(title: "Dup", address: existing),
               OnboardingBookmark(title: "Bad", address: "javascript:alert(1)")]
        OnboardingApplication.apply(OnboardingResult(spaceName: "Studio", spaceSymbol: "sparkles",
                                                     colorIndex: 0, favorites: flood), to: &session)
        let favorites = session.favoriteTabs
        try expect(favorites.count == BrowserSession.maximumFavorites, "Imports never exceed the favorite cap")
        try expect(favorites.filter { $0.saved?.address == existing }.count == 1, "Existing favorites are not duplicated")
        try expect(!favorites.contains { $0.saved?.address.hasPrefix("javascript:") == true },
                   "Only navigable addresses are imported")
        // The applied session must survive persistence untouched.
        session.sanitize()
        try expect(session.favoriteTabs.count == BrowserSession.maximumFavorites, "Sanitize keeps the imported favorites")
    }
}
