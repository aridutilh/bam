import Foundation

/// The vendor probe's opt-in bookmark fixture seed: gating (decided before any mutation) and exactly what it
/// adds to a task-owned session, cross-checked through the bookmarks snapshot adapter.
@main enum BookmarkVendorSeedTests {
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        typealias Seed = BookmarkVendorSeed
        // Gate: off unless exactly "1", only in normal mode, only with a literal loopback http site.
        require(Seed.decide(flag: nil, isNormalMode: true, site: "http://127.0.0.1:8000/") == .off
                && Seed.decide(flag: "", isNormalMode: false, site: nil) == .off, "Unset (default) is off: existing probes unchanged")
        let origin = URL(string: "http://127.0.0.1:8123/")!
        require(Seed.decide(flag: "1", isNormalMode: true, site: "http://127.0.0.1:8123/index.html?x=1#f") == .seed(origin: origin),
                "Enabled: the seed origin is the site's scheme, literal loopback host and port only")
        require(Seed.decide(flag: "1", isNormalMode: true, site: "http://[::1]:9000/page").isSeed, "IPv6 loopback literal accepted")
        for (flag, normal, site, label) in [("yes", true, "http://127.0.0.1:1/", "a value other than 1"),
                                             ("1", false, "http://127.0.0.1:1/", "private (default) mode"),
                                             ("1", true, nil as String?, "no site"),
                                             ("1", true, "http://localhost:1/", "a loopback name instead of a literal"),
                                             ("1", true, "https://127.0.0.1:1/", "https"),
                                             ("1", true, "http://example.com/", "a remote host"),
                                             ("1", true, "http://user:pw@127.0.0.1:1/", "user info"),
                                             ("1", true, "http://127.0.0.2:1/", "another 127/8 address")] {
            if case .refused = Seed.decide(flag: flag, isNormalMode: normal, site: site) {} else { require(false, "Refused for \(label)") }
            checks += 1
        }

        // Seeding a task-owned session shaped like the probe's (one Space, one blank tab, a run profile).
        let runProfile = UUID()
        let home = BrowserTab(title: "Vendor observation", address: "orbit://newtab", space: 0)
        var session = BrowserSession(tabs: [home], activeID: home.id,
                                     spaces: [BrowserSpace(id: 0, name: "Vendor probe", symbol: "puzzlepiece.extension", colorIndex: 0, profileID: runProfile)],
                                     profiles: BrowserProfile.defaults + [BrowserProfile(id: runProfile, name: "Vendor probe")])
        let profilesBefore = session.profiles, spacesBefore = session.spaces
        let seeded = Seed.seed(into: &session, profileID: runProfile, space: 0, origin: origin)
        require(seeded.itemCount == 5 && seeded.bookmarkPages == 2, "Five fixture items, two of them bookmark pages")
        require(session.activeID == home.id && session.profiles == profilesBefore && session.spaces == spacesBefore,
                "Selection stays on the blank tab; no profile or Space is added")
        let alpha = session.tabs.first { $0.id == seeded.ids["favorite_alpha"] }!, beta = session.tabs.first { $0.id == seeded.ids["kept_beta"] }!
        let today = session.tabs.first { $0.id == seeded.ids["today_control"] }!
        require(session.favorites(in: runProfile).map(\.id) == [alpha.id] && alpha.title == Seed.alphaTitle, "Alpha is a Favorite of the run profile")
        require(session.keptChildren(of: .root(0)) == [seeded.ids["folder"]!]
                && session.keptChildren(of: .folder(seeded.ids["folder"]!)) == [seeded.ids["nested_folder"]!]
                && session.keptChildren(of: .folder(seeded.ids["nested_folder"]!)) == [beta.id] && beta.title == Seed.betaTitle,
                "Beta is a kept item inside a nested folder")
        require(today.saved == nil && !session.keptChildren(of: .root(0)).contains(today.id), "The Today control is an ordinary unsaved tab")
        require(alpha.isUnloaded && beta.isUnloaded, "Seeded saved items are dormant")
        require([alpha, beta, today].allSatisfy { tab in tab.address.hasPrefix("http://127.0.0.1:8123/bam-bookmark/") && (tab.saved.map { $0.address == tab.address } ?? true) },
                "Every URL is on this run's local fixture origin")

        // Cross-check: the snapshot an extension's bookmarks.getTree gets lists alpha and beta, never the control.
        let input = BookmarkSessionSnapshot.input(from: session, profileID: runProfile)!
        let pages = input.favorites.map(\.title) + (input.folders.flatMap(\.children) + input.spaces.flatMap(\.children)).compactMap { child -> String? in
            if case .page(let page) = child { return page.title }; return nil
        }
        require(Set(pages) == [Seed.alphaTitle, Seed.betaTitle] && !pages.contains(Seed.todayTitle), "Bookmarks list alpha and beta, not the Today control")
        print("PASS: \(checks) bookmark vendor seed checks")
    }
}

private extension BookmarkVendorSeed.Decision {
    var isSeed: Bool { if case .seed = self { return true }; return false }
}
