import Foundation

/// The restore fixture is off unless explicitly enabled, refuses every unsafe combination before anything exists, and
/// allows exactly the two run-owned ordinary pages; the bookmark seed's own allowlist is unchanged.
@main enum RestoreVendorFixtureTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Restore vendor fixture — \(try run()) checks") }
        catch { fputs("FAIL: Restore vendor fixture: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias R = RestoreVendorFixture
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        func refused(_ decision: R.Decision) -> Bool { if case .refused = decision { return true }; return false }
        let site = "http://127.0.0.1:64731/passwords/plain.html", today = "http://127.0.0.1:64731/bookmarks/today.html"

        try check(R.decide(flag: nil, isNormalMode: true, site: site, seedFlag: nil) == .off && R.decide(flag: "", isNormalMode: true, site: site, seedFlag: nil) == .off,
                  "The fixture was on without its flag")
        try check(R.decide(flag: "1", isNormalMode: true, site: site, seedFlag: nil) == .on(today: today, site: site), "A valid request did not name the two run-owned pages")
        try check(refused(R.decide(flag: "yes", isNormalMode: true, site: site, seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: site, seedFlag: "1")) &&
                  refused(R.decide(flag: "1", isNormalMode: false, site: site, seedFlag: nil)),
                  "A non-1 flag, the bookmark seed combination or the private probe was accepted")
        try check(refused(R.decide(flag: "1", isNormalMode: true, site: nil, seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: "http://example.com/a.html", seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: "http://localhost:64731/a.html", seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: "https://127.0.0.1:64731/a.html", seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: "http://user@127.0.0.1:64731/a.html", seedFlag: nil)),
                  "A missing, non-loopback, named-host, non-http or credentialed site was accepted")
        try check(refused(R.decide(flag: "1", isNormalMode: true, site: "http://127.0.0.1:64731/a.html?x=1", seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: "http://127.0.0.1:64731/a.html#f", seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: "http://127.0.0.1:64731/", seedFlag: nil)) &&
                  refused(R.decide(flag: "1", isNormalMode: true, site: today, seedFlag: nil)),
                  "A site with a query, fragment, no path, or equal to the today page was accepted")

        // Exactly the two run-owned pages; everything else stays blocked by the shared exact-match gate.
        let allowed = R.destinations(R.decide(flag: "1", isNormalMode: true, site: site, seedFlag: nil))
        func allows(_ raw: String) -> Bool { BookmarkVendorSeed.allowsSeededNavigation(URL(string: raw)!, destinations: allowed) }
        try check(allowed == [today, site] && allows(today) && allows(site), "The two run-owned pages were not allowed")
        try check(!allows("http://127.0.0.1:64731/bookmarks/alpha.html") && !allows("http://127.0.0.1:64731/passwords/plain.html?x=1") &&
                  !allows("http://127.0.0.1:64732/passwords/plain.html") && !allows("http://localhost:64731/bookmarks/today.html") &&
                  !allows("https://127.0.0.1:64731/bookmarks/today.html") && !allows("orbit://newtab"),
                  "A page other than the two run-owned pages was allowed")
        try check(R.destinations(.off).isEmpty && R.destinations(.refused("x")).isEmpty && !BookmarkVendorSeed.allowsSeededNavigation(URL(string: today)!, destinations: []),
                  "An off or refused fixture allowed anything")
        return checks
    }
}
