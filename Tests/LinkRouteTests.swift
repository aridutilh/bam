import Foundation

/// Air Traffic Control: how routes match, which one wins, what happens when a Space is gone,
/// how suggestions appear, and that routes survive a relaunch.
@main enum LinkRouteTests {
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("FAILED: \(message)"); exit(1) }; checks += 1
        }
        func url(_ text: String) -> URL { URL(string: text)! }

        // Contains: anywhere in the address, any case; empty never matches.
        let figma = LinkRoute(match: .contains, text: "figma.com", destination: .space(2))
        require(figma.matches(url("https://www.figma.com/file/abc")), "contains matches a subdomain and path")
        require(figma.matches(url("https://WWW.FIGMA.COM/")), "contains ignores case")
        require(!figma.matches(url("https://example.com/?q=figma")), "contains needs the whole text")
        require(LinkRoute(match: .contains, text: "  meet.google.com ", destination: .littleBam).matches(url("https://meet.google.com/abc-defg")), "surrounding spaces are ignored")
        require(!LinkRoute(match: .contains, text: "   ", destination: .littleBam).matches(url("https://example.com")), "an empty route matches nothing")

        // Is equal to: the whole address; trailing slash and a missing scheme don't matter.
        let exact = LinkRoute(match: .isEqualTo, text: "github.com/aridutilh/bam", destination: .space(3))
        require(exact.matches(url("https://github.com/aridutilh/bam")) && exact.matches(url("https://github.com/aridutilh/bam/")), "equal ignores the scheme and trailing slash")
        require(!exact.matches(url("https://github.com/aridutilh/bam/pulls")), "equal is not a prefix")
        require(LinkRoute(match: .isEqualTo, text: "https://x.com/", destination: .littleBam).matches(url("https://x.com")), "a typed scheme compares with it")
        require(!LinkRoute(match: .isEqualTo, text: "https://x.com", destination: .littleBam).matches(url("http://x.com")), "and then the scheme must agree")

        // Hostile and international addresses.
        require(!figma.matches(url("https://figma.com@evil.com/x")) && !figma.matches(url("https://figma.com:pw@evil.com/")), "user info is not the site")
        require(figma.matches(url("https://figma.com.evil.com/")), "contains is a substring test, as in Arc (documented weakness)")
        require(LinkRoute(match: .contains, text: "bücher.de", destination: .littleBam).matches(url("https://xn--bcher-kva.de/a")), "an IDN route matches the punycode host")
        require(LinkRoute(match: .contains, text: "café", destination: .littleBam).matches(url("https://example.com/caf%C3%A9")), "a route matches percent-encoded text")
        require(exact.matches(url("https://github.com/aridutilh/bam#readme")), "equal ignores a fragment the route doesn't name")
        require(!LinkRoute(match: .isEqualTo, text: "x.com/a#b", destination: .littleBam).matches(url("https://x.com/a#c")), "but compares one it does")
        require(LinkRoute(match: .isEqualTo, text: "GitHub.com/AriDutilh/Bam/", destination: .littleBam).matches(url("https://github.com/aridutilh/bam")), "equal ignores case")

        // Order, default, missing Spaces.
        var routing = LinkRouting(routes: [figma, LinkRoute(match: .contains, text: "figma.com/proto", destination: .littleBam)], fallback: .mostRecentSpace)
        let proto = url("https://figma.com/proto/1")
        require(routing.destination(for: proto).destination == .space(2) && routing.destination(for: proto).route == figma, "the first matching route wins")
        require(routing.destination(for: url("https://example.com")).destination == .mostRecentSpace && routing.destination(for: url("https://example.com")).route == nil,
                "no match → the default")
        require(routing.destination(for: proto, spaceExists: { $0 != 2 }).destination == .littleBam, "a route to a removed Space falls through to the next")
        routing.fallback = .space(9)
        require(routing.destination(for: url("https://example.com"), spaceExists: { $0 != 9 }).destination == .littleBam, "a default Space that is gone becomes Little Bam")
        require(LinkRouting().fallback == .littleBam && LinkRouting().routes.isEmpty, "out of the box: everything to Little Bam, as before")
        require(LinkRouting.site(of: url("https://www.figma.com/file/x")) == "figma.com" && LinkRouting.site(of: url("file:///tmp/a")) == nil, "site names for suggestions")

        // Persistence: routes round-trip; disposable launches keep them in memory.
        require(LinkRoutePreference.isDisposableLaunch(["Bam", "--fresh-preview"]) && LinkRoutePreference.isDisposableLaunch(["Bam", "--profile-instance-test"])
                && !LinkRoutePreference.isDisposableLaunch(["Bam"]), "fresh previews and fixtures don't persist")
        let suite = "bam.links.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let saved = LinkRoutePreference.defaults
        LinkRoutePreference.defaults = defaults
        LinkRoutePreference.routing = routing
        require(LinkRoutePreference.routing == routing, "routes and the default survive a relaunch")

        // Suggestions: the same site moved to the same Space three times, unless routed or declined.
        let exists: (Int) -> Bool = { [1, 4].contains($0) }
        let empty = LinkRouting()
        for _ in 0..<2 { LinkRoutePreference.noteMove(url("https://www.notion.so/page"), toSpace: 4) }
        require(LinkRoutePreference.suggestion(routing: empty, spaceExists: exists) == nil, "two moves aren't enough")
        LinkRoutePreference.noteMove(url("https://notion.so/other"), toSpace: 4)
        let suggestion = LinkRoutePreference.suggestion(routing: empty, spaceExists: exists)
        require(suggestion?.site == "notion.so" && suggestion?.space == 4, "three moves suggest notion.so → that Space")
        let routed = LinkRouting(routes: [LinkRoute(match: .contains, text: "notion.so", destination: .space(4))])
        require(LinkRoutePreference.suggestion(routing: routed, spaceExists: exists) == nil, "no suggestion once a route covers it")
        require(LinkRoutePreference.suggestion(routing: empty, spaceExists: { $0 == 1 }) == nil, "no suggestion for a Space that is gone")
        LinkRoutePreference.dismissSuggestion(site: "notion.so", space: 4)
        require(LinkRoutePreference.suggestion(routing: empty, spaceExists: exists) == nil, "a declined suggestion stays away")
        for index in 0..<250 { for _ in 0..<2 { LinkRoutePreference.noteMove(url("https://site\(index).example/"), toSpace: 1) } }
        let kept = (defaults.dictionary(forKey: LinkRoutePreference.movesKey) ?? [:]).count
        require(kept <= 200, "the move counter stays bounded when every site has two moves (kept \(kept))")
        LinkRoutePreference.forgetMoves()
        require(defaults.dictionary(forKey: LinkRoutePreference.movesKey) == nil && defaults.stringArray(forKey: LinkRoutePreference.dismissedKey) == nil,
                "clearing history forgets moved sites and declined suggestions")
        defaults.removePersistentDomain(forName: suite)
        LinkRoutePreference.defaults = saved

        // Codable shape for each destination.
        for destination in [LinkDestination.space(7), .mostRecentSpace, .littleBam] {
            let data = try! JSONEncoder().encode(destination)
            require(try! JSONDecoder().decode(LinkDestination.self, from: data) == destination, "\(destination) round-trips")
        }
        print("PASS: \(checks) Air Traffic Control checks")
    }
}
