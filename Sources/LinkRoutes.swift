import Foundation

/// Where a link from another app opens.
enum LinkDestination: Codable, Equatable, Hashable {
    /// One Space, by its stable id.
    case space(Int)
    /// Whichever Space the main window is showing.
    case mostRecentSpace
    case littleBam
}

/// One Air Traffic Control route: "URL contains figma.com → Design".
struct LinkRoute: Codable, Equatable, Identifiable {
    enum Match: String, Codable, CaseIterable {
        case contains, isEqualTo
        var title: String { self == .contains ? "Contains" : "Is equal to" }
    }
    var id = UUID()
    var match: Match = .contains
    var text: String = ""
    var destination: LinkDestination = .mostRecentSpace

    /// Case-insensitive. "Contains" looks anywhere in the address; "Is equal to" compares the whole
    /// address, ignoring a trailing slash (and the #fragment unless the route names one), and a value
    /// typed without "https://" compares without it. A route typed as "bücher.de" or "café" matches
    /// the punycode host and percent-encoded path a link actually carries. The address's user info is
    /// never compared: "https://figma.com@evil.com" goes to evil.com, so it must not match "figma.com".
    /// Contains is still a plain substring test, as in Arc: "figma.com.evil.com" and
    /// "evil.com/?u=figma.com" match a "figma.com" route.
    func matches(_ url: URL) -> Bool {
        let wanted = Self.ruleForms(text)
        guard !wanted.isEmpty else { return false }
        let addresses = Self.addressForms(url)
        switch match {
        case .contains:
            return addresses.contains { address in wanted.contains { address.contains($0) } }
        case .isEqualTo:
            func trimmed(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
            return wanted.contains { rule in
                addresses.contains { full in
                    var address = full
                    if !rule.contains("#"), let hash = address.firstIndex(of: "#") { address = String(address[..<hash]) }
                    if !rule.contains("://") { address = address.range(of: "://").map { String(address[$0.upperBound...]) } ?? address }
                    return trimmed(address) == trimmed(rule)
                }
            }
        }
    }
    /// The link as routes read it: lowercased, without user info, and also percent-decoded.
    static func addressForms(_ url: URL) -> [String] {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if parts?.user != nil || parts?.password != nil { parts?.user = nil; parts?.password = nil }
        let address = (parts?.url ?? url).absoluteString.lowercased()
        let decoded = address.removingPercentEncoding
        return decoded.map { $0 == address ? [address] : [address, $0] } ?? [address]
    }
    /// The route's text as typed, plus the form a link would carry (punycode host, encoded path).
    static func ruleForms(_ text: String) -> [String] {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return [] }
        let hasScheme = wanted.contains("://")
        guard let parsed = URL(string: hasScheme ? wanted : "https://" + wanted) else { return [wanted] }
        var encoded = parsed.absoluteString.lowercased()
        if !hasScheme, encoded.hasPrefix("https://") { encoded.removeFirst(8) }
        return encoded.isEmpty || encoded == wanted ? [wanted] : [wanted, encoded]
    }
}

/// Air Traffic Control: routes checked top to bottom, then the default.
struct LinkRouting: Codable, Equatable {
    var routes: [LinkRoute] = []
    /// Arc's default, and Bam's behavior before routes existed.
    var fallback: LinkDestination = .littleBam

    /// The first matching route's destination (and that route), else the default. A route whose
    /// Space no longer exists is skipped, so its links fall through rather than vanish.
    func destination(for url: URL, spaceExists: (Int) -> Bool = { _ in true }) -> (destination: LinkDestination, route: LinkRoute?) {
        for route in routes where route.matches(url) {
            if case .space(let id) = route.destination, !spaceExists(id) { continue }
            return (route.destination, route)
        }
        if case .space(let id) = fallback, !spaceExists(id) { return (.littleBam, nil) }
        return (fallback, nil)
    }

    /// A rule-shaped value for a site: "figma.com" from "https://www.figma.com/file/…".
    static func site(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// Saved routes, plus the moves that suggest new ones. Fresh previews and fixtures keep both in
/// memory so they never change the real app's routing.
enum LinkRoutePreference {
    static let defaultsKey = "LinkRoutes"
    static let movesKey = "LinkRouteMoves"
    static let dismissedKey = "LinkRouteDismissed"
    /// How many times the same site must be moved to the same Space before Bam suggests a route.
    static let suggestionThreshold = 3

    nonisolated(unsafe) static var defaults: UserDefaults? = isDisposableLaunch(CommandLine.arguments) ? nil : .standard
    nonisolated(unsafe) private static var memory = LinkRouting()
    nonisolated(unsafe) private static var memoryMoves: [String: Int] = [:]
    nonisolated(unsafe) private static var memoryDismissed: [String] = []

    static func isDisposableLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--fresh-preview" || $0 == "--vendor-extension-probe" || ($0.hasPrefix("--") && $0.hasSuffix("-test")) }
    }

    static var routing: LinkRouting {
        get {
            guard let defaults else { return memory }
            return defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(LinkRouting.self, from: $0) } ?? LinkRouting()
        }
        set {
            if let defaults { defaults.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) } else { memory = newValue }
        }
    }

    private static func key(site: String, space: Int) -> String { "\(site)|\(space)" }
    private static var moves: [String: Int] {
        get { defaults.map { ($0.dictionary(forKey: movesKey) as? [String: Int]) ?? [:] } ?? memoryMoves }
        set { if let defaults { defaults.set(newValue, forKey: movesKey) } else { memoryMoves = newValue } }
    }
    private static var dismissed: [String] {
        get { defaults?.stringArray(forKey: dismissedKey) ?? memoryDismissed }
        set { if let defaults { defaults.set(newValue, forKey: dismissedKey) } else { memoryDismissed = newValue } }
    }

    /// The person moved a page from `url` into a Space (Little Bam's Open in, or Move to Space).
    static func noteMove(_ url: URL, toSpace space: Int) {
        guard let site = LinkRouting.site(of: url) else { return }
        var counts = moves
        counts[key(site: site, space: space), default: 0] += 1
        // Bounded: past 200 sites, keep the 100 moved most (filtering by count alone never shrinks
        // once every entry has two moves).
        if counts.count > 200 {
            counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(100).map { ($0.key, $0.value) })
        }
        moves = counts
    }
    /// The moves are a record of sites visited, so clearing history clears them (and the declined list).
    static func forgetMoves() {
        moves = [:]; dismissed = []
        defaults?.removeObject(forKey: movesKey); defaults?.removeObject(forKey: dismissedKey)
    }

    /// A route worth offering: a site moved to the same Space at least three times, not already
    /// routed and not turned down. Among several, the most-moved first.
    static func suggestion(routing: LinkRouting, spaceExists: (Int) -> Bool) -> (site: String, space: Int)? {
        let turnedDown = Set(dismissed)
        let candidates = moves.compactMap { entry, count -> (String, Int, Int)? in
            let parts = entry.split(separator: "|", maxSplits: 1)
            guard count >= suggestionThreshold, parts.count == 2, let space = Int(parts[1]), spaceExists(space),
                  !turnedDown.contains(entry) else { return nil }
            let site = String(parts[0])
            guard let probe = URL(string: "https://\(site)/"), routing.destination(for: probe, spaceExists: spaceExists).route == nil else { return nil }
            return (site, space, count)
        }
        return candidates.max { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 > $1.0 }.map { ($0.0, $0.1) }
    }
    static func dismissSuggestion(site: String, space: Int) {
        var list = dismissed
        list.append(key(site: site, space: space))
        dismissed = Array(list.suffix(100))
    }
}
