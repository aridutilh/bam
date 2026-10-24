import Foundation

/// First-run onboarding: pure decisions, step flow, Chrome favorite import,
/// and session application. All UI lives in Onboarding.swift; everything here
/// is deterministic and covered by Tests/OnboardingTests.swift.

enum OnboardingGate {
    static let completedKey = "OnboardingCompleted"
    static let startedKey = "OnboardingStarted"
    static let testArguments: Set<String> = ["--web-test", "--pip-test", "--interaction-test",
                                             "--auto-pip-test", "--feature-test", "--resource-test",
                                             "--profile-test", "--extension-test", "--favicon-test", "--vendor-extension-probe"]

    /// First launches with no profile get the welcome; existing profiles are
    /// grandfathered silently — unless the welcome already started and was cut
    /// short (a quit mid-onboarding writes a session but must not grandfather).
    /// Fixtures never see it. `--onboarding` forces it, including over
    /// `--fresh-preview` and over an existing profile, so demos stay possible.
    static func shouldPresent(arguments: [String], sessionFileExists: Bool,
                              completed: Bool, started: Bool = false) -> Bool {
        guard !arguments.contains(where: { testArguments.contains($0) }) else { return false }
        if arguments.contains("--onboarding") { return true }
        guard !arguments.contains("--fresh-preview") else { return false }
        return !completed && (!sessionFileExists || started)
    }

    /// An existing profile that predates onboarding should never be welcomed
    /// as new on a later launch.
    static func shouldGrandfather(arguments: [String], sessionFileExists: Bool,
                                  completed: Bool, started: Bool = false) -> Bool {
        !completed && !started && sessionFileExists
            && !arguments.contains("--onboarding") && !arguments.contains("--fresh-preview")
            && !arguments.contains(where: { testArguments.contains($0) })
    }
}

enum OnboardingStep: Int, CaseIterable, Equatable {
    case hello, color, name, favorites, shortcuts, defaultBrowser, finale
}

struct OnboardingBookmark: Equatable {
    var title: String
    var address: String
}

/// Step flow and collected choices. The favorites step exists only when the
/// machine found Chrome bookmarks to offer.
struct OnboardingModel {
    var colorIndex = 0
    var spaceName = ""
    var spaceSymbol = "sparkles"
    var bookmarks: [OnboardingBookmark]
    var selectedBookmarkAddresses: Set<String>
    var shortcutsCompleted: Set<String> = []
    private(set) var step: OnboardingStep = .hello

    static let shortcutTargets = ["t", "s"]
    static let preselectedFavorites = 6

    init(bookmarks: [OnboardingBookmark] = []) {
        self.bookmarks = bookmarks
        selectedBookmarkAddresses = Set(bookmarks.prefix(Self.preselectedFavorites).map(\.address))
    }

    var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .favorites || !bookmarks.isEmpty }
    }
    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirstStep: Bool { stepIndex == 0 }
    var isLastStep: Bool { stepIndex == steps.count - 1 }
    var shortcutsDone: Bool { Self.shortcutTargets.allSatisfy { shortcutsCompleted.contains($0) } }

    mutating func advance() {
        let steps = steps
        guard stepIndex + 1 < steps.count else { return }
        step = steps[stepIndex + 1]
    }
    mutating func goBack() {
        guard stepIndex > 0 else { return }
        step = steps[stepIndex - 1]
    }
    /// Records a training keystroke; returns true when it was a new completion.
    @discardableResult mutating func recordShortcut(_ key: String) -> Bool {
        guard step == .shortcuts, Self.shortcutTargets.contains(key) else { return false }
        return shortcutsCompleted.insert(key).inserted
    }
    mutating func toggleBookmark(_ address: String) {
        guard bookmarks.contains(where: { $0.address == address }) else { return }
        if selectedBookmarkAddresses.contains(address) { selectedBookmarkAddresses.remove(address) }
        else { selectedBookmarkAddresses.insert(address) }
    }

    var result: OnboardingResult {
        OnboardingResult(spaceName: BrowserSpace.validName(spaceName) ?? "Studio",
                         spaceSymbol: spaceSymbol, colorIndex: colorIndex,
                         favorites: bookmarks.filter { selectedBookmarkAddresses.contains($0.address) })
    }
}

struct OnboardingResult {
    var spaceName: String
    var spaceSymbol: String
    var colorIndex: Int
    var favorites: [OnboardingBookmark]
}

enum OnboardingApplication {
    /// Personalizes the first Space and adds the chosen favorites. Existing
    /// favorite addresses are kept, not duplicated, and the session-wide
    /// favorite cap is respected. Returns whether anything changed.
    @discardableResult static func apply(_ result: OnboardingResult, to session: inout BrowserSession) -> Bool {
        var changed = false
        if let first = session.spaces.first {
            changed = session.updateSpace(id: first.id, name: result.spaceName,
                                          symbol: result.spaceSymbol, colorIndex: result.colorIndex) || changed
        }
        let existing = Set(session.favoriteTabs.compactMap { $0.saved?.address })
        var room = BrowserSession.maximumFavorites - session.favoriteTabs.count
        for bookmark in result.favorites where room > 0 {
            guard !existing.contains(bookmark.address), URLInput.directURL(bookmark.address) != nil else { continue }
            let title = String(bookmark.title.prefix(80))
            var saved = SavedTabState(kind: .favorite, address: bookmark.address, isUnloaded: true)
            saved.customTitle = title.isEmpty ? nil : title
            session.tabs.append(BrowserTab(title: title.isEmpty ? bookmark.address : title,
                                           address: bookmark.address,
                                           space: session.spaces.first?.id ?? session.space,
                                           saved: saved))
            room -= 1; changed = true
        }
        session.sanitize()
        return changed
    }
}

enum ChromeBookmarks {
    /// Chrome's bookmark-bar entries from its plain-JSON store, flattened one
    /// folder level deep, HTTPS/HTTP only, deduplicated, capped for display.
    static let maximumOffered = 12

    static func defaultStoreURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
    }

    static func load(from url: URL) -> [OnboardingBookmark] {
        // This runs synchronously at launch: refuse oversized stores before
        // touching their bytes, and map rather than copy the rest.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size < 20_000_000,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [OnboardingBookmark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any],
              let bar = roots["bookmark_bar"] as? [String: Any] else { return [] }
        var found: [OnboardingBookmark] = []
        var seen = Set<String>()
        collect(from: bar, depth: 0, into: &found, seen: &seen)
        return found
    }

    private static func collect(from node: [String: Any], depth: Int,
                                into found: inout [OnboardingBookmark], seen: inout Set<String>) {
        guard found.count < maximumOffered, let children = node["children"] as? [Any] else { return }
        for child in children {
            guard found.count < maximumOffered, let child = child as? [String: Any] else { continue }
            if child["type"] as? String == "url", let address = child["url"] as? String,
               let url = URLInput.directURL(address), seen.insert(url.absoluteString).inserted {
                // Interior control characters would void the saved custom title
                // later in sanitize; clean them here where the data enters.
                let scalars = (child["name"] as? String ?? "").unicodeScalars
                    .map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
                let title = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
                found.append(OnboardingBookmark(title: title.isEmpty ? (url.host ?? address) : title,
                                                address: url.absoluteString))
            } else if child["type"] as? String == "folder", depth < 1 {
                collect(from: child, depth: depth + 1, into: &found, seen: &seen)
            }
        }
    }
}
