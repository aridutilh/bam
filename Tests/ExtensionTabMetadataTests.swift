import Foundation

/// Tab metadata model: token binding, observed-topology identity, request bounds, values and WebKit's title filter.
/// Pure; no WebKit.
@main struct ExtensionTabMetadataTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension tab metadata — \(try run()) checks") }
        catch { fputs("FAIL: Extension tab metadata: \(error)\n", stderr); exit(1) }
    }

    /// WebCore's `MatchTester` (UserContentURLPattern.cpp), ported literally as the reference for title filters.
    static func webKitWildcard(_ pattern: [UInt16], _ test: [UInt16]) -> Bool {
        let star = UInt16(UInt8(ascii: "*"))
        func run(_ pi0: Int, _ ti0: Int) -> Bool {
            var pi = pi0, ti = ti0
            while pi < pattern.count && ti < test.count { if pattern[pi] == star || pattern[pi] != test[ti] { break }; pi += 1; ti += 1 }
            if ti >= test.count { while pi < pattern.count && pattern[pi] == star { pi += 1 }; return pi >= pattern.count }
            if pi >= pattern.count { return false }
            if pattern[pi] != star { return false }
            while ti < test.count { if run(pi + 1, ti) { return true }; ti += 1 }
            while pi < pattern.count && pattern[pi] == star { pi += 1 }
            return pi >= pattern.count
        }
        return run(0, 0)
    }

    static func run() throws -> Int {
        typealias M = ExtensionTabMetadata
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        let profile = UUID()
        let binding = M.Binding(context: "context-a", runtime: 11, profile: profile, generation: 3, mutation: 7)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

        // Tokens: opaque, exact stored binding, single use, expiring at the boundary, capped, purged.
        var store = M.TokenStore()
        guard let token = store.issue(binding, now: t0) else { throw Failure(description: "No token issued") }
        try check(token.utf8.count == 22 && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                  && !token.contains("context") && !token.contains(profile.uuidString), "A token is not an opaque 16-byte base64url nonce: \(token)")
        try check(store.consume(token, now: t0.addingTimeInterval(1)) == binding, "A token did not return its exact binding")
        try check(store.consume(token, now: t0.addingTimeInterval(1)) == nil, "A token was usable twice")
        let tokens = Set((0..<200).compactMap { _ in M.randomNonce() })
        try check(tokens.count == 200, "Nonces repeated")
        // Every binding field is returned as stored, so the engine's comparison catches any change.
        for changed in [
            M.Binding(context: "context-b", runtime: 11, profile: profile, generation: 3, mutation: 7),
            M.Binding(context: "context-a", runtime: 12, profile: profile, generation: 3, mutation: 7),
            M.Binding(context: "context-a", runtime: 11, profile: UUID(), generation: 3, mutation: 7),
            M.Binding(context: "context-a", runtime: 11, profile: profile, generation: 4, mutation: 7),
            M.Binding(context: "context-a", runtime: 11, profile: profile, generation: 3, mutation: 8),
        ] {
            let issued = store.issue(binding, now: t0)!
            try check(store.consume(issued, now: t0) != changed, "A changed binding compared equal: \(changed)")
        }
        let expiring = store.issue(binding, now: t0)!
        try check(store.consume(expiring, now: t0.addingTimeInterval(M.tokenLifetime)) == nil, "A token was valid at its expiry")
        let almost = store.issue(binding, now: t0)!
        try check(store.consume(almost, now: t0.addingTimeInterval(M.tokenLifetime - 0.001)) == binding, "A token expired early")
        try check(store.consume("unknown", now: t0) == nil && store.consume(String(repeating: "a", count: 5_000), now: t0) == nil, "An unknown token was accepted")
        var capped = M.TokenStore()
        for _ in 0..<M.maxTokensPerContext { _ = capped.issue(binding, now: t0) }
        try check(capped.issue(binding, now: t0) == nil && capped.count(context: "context-a") == M.maxTokensPerContext, "The per-context cap was not enforced")
        let other = M.Binding(context: "context-b", runtime: 11, profile: profile, generation: 3, mutation: 7)
        try check(capped.issue(other, now: t0) != nil, "One context's cap blocked another")
        try check(capped.issue(binding, now: t0.addingTimeInterval(M.tokenLifetime)) != nil, "Expired tokens still counted toward the cap")
        var global = M.TokenStore()
        for index in 0..<M.maxTokens { _ = global.issue(M.Binding(context: "c\(index)", runtime: 1, profile: profile, generation: 0, mutation: 0), now: t0) }
        try check(global.issue(other, now: t0) == nil && global.count == M.maxTokens, "The global cap was not enforced")
        var purging = M.TokenStore()
        let kept = purging.issue(other, now: t0)!, dropped = purging.issue(binding, now: t0)!
        purging.purge(context: "context-a")
        try check(purging.consume(dropped, now: t0) == nil && purging.consume(kept, now: t0) == other, "Purging a context removed the wrong tokens")
        let otherRuntime = M.Binding(context: "context-a", runtime: 99, profile: profile, generation: 3, mutation: 7)
        let survivor = purging.issue(otherRuntime, now: t0)!, gone = purging.issue(binding, now: t0)!
        purging.purge(runtime: 11)
        try check(purging.consume(gone, now: t0) == nil && purging.consume(survivor, now: t0) == otherRuntime, "Purging a runtime removed the wrong tokens")
        _ = purging.issue(binding, now: t0); purging.purgeAll()
        try check(purging.count == 0, "purgeAll left tokens")
        var colliding = M.TokenStore()
        _ = colliding.issue(binding, now: t0, nonce: { "same" })
        try check(colliding.issue(binding, now: t0, nonce: { "same" }) == nil && colliding.issue(binding, now: t0, nonce: { "" }) == nil,
                  "A colliding or empty nonce was issued")

        // Generation: every distinct served topology advances it (ABA included); window order alone does not.
        var generation = M.Generation()
        let window = { (adapter: Int, single: Bool, tabs: [Int]) in M.ObservedWindow(adapter: adapter, isSinglePage: single, tabs: tabs) }
        try check(generation.record([window(1, false, [10, 11])]) == 1 && generation.record([window(1, false, [10, 11])]) == 1,
                  "An unchanged topology advanced the generation, or the first did not")
        try check(generation.record([window(1, false, [11, 10])]) == 2 && generation.record([window(1, false, [10, 11])]) == 3,
                  "A swap and swap back (ABA) did not advance the generation each time")
        try check(generation.record([window(1, false, [12, 11])]) == 4, "A replaced tab adapter did not advance the generation")
        try check(generation.record([window(2, false, [12, 11])]) == 5, "A replaced window adapter did not advance the generation")
        try check(generation.record([window(2, true, [12, 11])]) == 6, "A window kind change did not advance the generation")
        let pair = [window(2, false, [12, 11]), window(3, true, [13])]
        try check(generation.record(pair) == 7 && generation.record(pair.reversed()) == 7, "Membership did not count, or window order alone did")
        try check(generation.record([window(2, false, [12]), window(3, true, [13, 11])]) == 8, "A tab moving between windows did not advance the generation")

        // Request parsing: strict, bounded, Chrome's url shape.
        func params(_ entries: [Any], _ extra: [String: Any] = [:]) -> [String: Any] {
            ["token": "t", "normalCount": 1, "popupCount": 0, "entries": entries].merging(extra) { _, new in new }
        }
        let parsed = M.Request.parse(params([["window": "normal", "index": 0], ["window": "popup", "index": 0]], ["filter": ["url": "*://*/*", "title": "A*"]]))
        try check(parsed == M.Request(token: "t", normalCount: 1, popupCount: 0, entries: [M.Entry(window: .normal, index: 0), M.Entry(window: .popup, index: 0)],
                                      filter: M.Filter(urlPatterns: ["*://*/*"], title: "A*")), "A valid request was not parsed exactly")
        try check(M.Request.parse(params([], ["filter": ["url": ["a", "b"]]]))?.filter == M.Filter(urlPatterns: ["a", "b"], title: nil)
                  && M.Request.parse(params([], ["filter": ["title": "x"]]))?.filter == M.Filter(urlPatterns: nil, title: "x")
                  && M.Request.parse(params([]))?.filter == nil, "Filter shapes were not parsed")
        for bad: [String: Any] in [
            params([["window": "normal", "index": 1.5]]), params([["window": "normal", "index": true]]), params([["window": "normal", "index": "1"]]),
            params([["window": "normal", "index": -1]]), params([["window": "normal", "index": M.maxIndex + 1]]), params([["window": "other", "index": 0]]),
            params([["window": "normal", "index": 0, "extra": 1]]), params([["window": "normal"]]), params([], ["surprise": 1]),
            params([], ["normalCount": 2.5]), params([], ["normalCount": true]), params([], ["popupCount": M.maxWindowCount + 1]),
            params([], ["token": ""]), params([], ["token": String(repeating: "a", count: M.maxTokenUTF8 + 1)]), params([], ["token": 5]),
            params(Array(repeating: ["window": "normal", "index": 0] as [String: Any], count: M.maxEntries + 1)),
            params([], ["filter": ["url": Array(repeating: "*://*/*", count: M.maxURLPatterns + 1)]]),
            params([], ["filter": ["url": String(repeating: "x", count: M.maxPatternUTF8 + 1)]]), params([], ["filter": ["url": [3]]]),
            params([], ["filter": ["url": 3]]), params([], ["filter": ["title": String(repeating: "x", count: M.maxTitlePatternUTF8 + 1)]]),
            params([], ["filter": ["title": 3]]), params([], ["filter": [:]]), params([], ["filter": ["other": "x"]]), params([], ["filter": "x"]),
        ] {
            try check(M.Request.parse(bad) == nil, "An invalid request was accepted: \(bad)")
        }
        let largest = M.Request.parse(params(Array(repeating: ["window": "normal", "index": M.maxIndex] as [String: Any], count: M.maxEntries)))
        try check(largest?.entries.count == M.maxEntries, "The largest valid request was refused")

        // Values: http(s) only, exact byte bounds, never truncated.
        let page = URL(string: "https://example.com/a")!
        try check(M.admissible(url: page, title: "T") == M.Value(url: page.absoluteString, title: "T")
                  && M.admissible(url: URL(string: "HTTP://127.0.0.1:8000/x")!, title: nil) == M.Value(url: "HTTP://127.0.0.1:8000/x", title: nil),
                  "An ordinary web page was not admissible")
        for url in ["webkit-extension://abc/page.html", "orbit://newtab", "file:///tmp/a", "about:blank", "data:text/html,x", "ftp://example.com/", "http:///nohost"] {
            try check(M.admissible(url: URL(string: url), title: "T") == nil, "A non-web URL was admissible: \(url)")
        }
        try check(M.admissible(url: nil, title: "T") == nil, "A missing URL was admissible")
        let prefix = "https://example.com/"
        let atURL = URL(string: prefix + String(repeating: "x", count: M.maxURLUTF8 - prefix.utf8.count))!
        let overURL = URL(string: prefix + String(repeating: "x", count: M.maxURLUTF8 - prefix.utf8.count + 1))!
        try check(M.admissible(url: atURL, title: nil) != nil && M.admissible(url: overURL, title: nil) == nil, "The URL byte bound is not exact")
        try check(M.admissible(url: page, title: String(repeating: "é", count: M.maxTitleUTF8 / 2)) != nil
                  && M.admissible(url: page, title: String(repeating: "é", count: M.maxTitleUTF8 / 2) + "x") == nil,
                  "The title byte bound is not exact UTF-8, or an over-bound title was truncated")

        // Title filter: WebKit semantics, bounded work.
        var budget = M.titleMatchBudget
        try check(M.titleMatches("Inbox*", "Inbox (3)", budget: &budget) == .match && M.titleMatches("inbox*", "Inbox (3)", budget: &budget) == .noMatch
                  && M.titleMatches("Inbox", "Inbox (3)", budget: &budget) == .noMatch && M.titleMatches("*", "", budget: &budget) == .match
                  && M.titleMatches("", "", budget: &budget) == .match && M.titleMatches("", "x", budget: &budget) == .noMatch
                  && M.titleMatches("a?c", "a?c", budget: &budget) == .match && M.titleMatches("a?c", "abc", budget: &budget) == .noMatch
                  && M.titleMatches("**a**", "bab", budget: &budget) == .match && M.titleMatches("*é*", "café", budget: &budget) == .match
                  && M.titleMatches("*😀", "smile 😀", budget: &budget) == .match && M.titleMatches("?", "😀", budget: &budget) == .noMatch
                  && M.titleMatches("a😀*", "a😀b", budget: &budget) == .match,
                  "Title wildcard semantics differ from WebKit's (case, whole string, literal ?, empty, non-BMP)")
        // Many stars cannot cause exponential work (WebKit's recursive matcher would); this one is linear and correct.
        var roomy = M.titleMatchBudget
        try check(M.titleMatches(String(repeating: "*a", count: 200) + "b", String(repeating: "a", count: 4_000), budget: &roomy) == .noMatch
                  && roomy > M.titleMatchBudget - 20_000, "A many-star pattern was slow or wrong")
        // Quadratic work (each resume re-matches 1,000 characters) is stopped by the budget.
        var small = 10_000
        let started = Date()
        try check(M.titleMatches("*" + String(repeating: "a", count: 1_000) + "b", String(repeating: "a", count: 4_000), budget: &small) == .exhausted
                  && small < 0 && Date().timeIntervalSince(started) < 1, "A quadratic title pattern was not stopped by the budget")
        var shared = 50
        _ = M.titleMatches("*", String(repeating: "x", count: 40), budget: &shared)
        try check(M.titleMatches("*", String(repeating: "x", count: 40), budget: &shared) == .exhausted, "The budget is not shared across one request")
        let alphabet: [Character] = ["a", "b", "*", "?"]
        func strings(_ length: Int) -> [String] { length == 0 ? [""] : strings(length - 1).flatMap { prefix in alphabet.map { prefix + String($0) } } }
        let patterns = (0...4).flatMap(strings), titles = (0...4).flatMap(strings).filter { !$0.contains("*") }
        for pattern in patterns { for title in titles {
            var unlimited = Int.max
            let ours = M.titleMatches(pattern, title, budget: &unlimited)
            guard (ours == .match) == webKitWildcard(Array(pattern.utf16), Array(title.utf16)), ours != .exhausted else {
                throw Failure(description: "Title wildcard differs from WebKit for pattern \(pattern) title \(title)")
            }
        } }
        checks += 1

        // Response: shape, order, budget nulling, and the all-or-nothing rule for filtered requests.
        let reply = M.response([M.Value(url: "https://example.com/", title: "T"), nil, M.Value(url: "https://example.com/x", title: nil)])
        try check(reply.count == 3 && (reply[0] as? [String: Any])?["title"] as? String == "T" && reply[1] is NSNull
                  && (reply[2] as? [String: Any])?.keys.sorted() == ["url"] && JSONSerialization.isValidJSONObject(reply), "The response shape changed")
        let big = M.Value(url: prefix + String(repeating: "y", count: 30_000), title: nil)
        let many = Array(repeating: Optional(big), count: 40)
        let nulled = M.response(many)
        let firstNull = nulled.firstIndex { $0 is NSNull }
        try check(firstNull != nil && nulled[..<firstNull!].allSatisfy { $0 is [String: Any] } && nulled[firstNull!...].allSatisfy { $0 is NSNull },
                  "The response budget did not null later entries in order")
        try check(!M.responseFits(many) && M.responseFits(Array(many.prefix(firstNull!))), "responseFits disagrees with the response budget")
        return checks
    }
}
