import Foundation

/// Tab metadata model: token binding, observed-topology identity, request bounds and answers. Pure; no WebKit.
@main struct ExtensionTabMetadataTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension tab metadata — \(try run()) checks") }
        catch { fputs("FAIL: Extension tab metadata: \(error)\n", stderr); exit(1) }
    }
    final class Object {}

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
        func failure<T>(_ result: Result<T, M.Refusal>) -> M.Refusal? { if case .failure(let refusal) = result { return refusal }; return nil }
        func success<T>(_ result: Result<T, M.Refusal>) -> T? { if case .success(let value) = result { return value }; return nil }

        let objects = (0..<12).map { _ in Object() }
        let ids = objects.map(ObjectIdentifier.init)
        let runtimeA = ids[10], runtimeB = ids[11]
        let profile = UUID(), otherProfile = UUID()
        let binding = M.Binding(context: "context-a", runtime: runtimeA, profile: profile, generation: 3, mutation: 7)

        // Tokens: opaque, unique, bound, single use, expiring, capped, purged.
        var store = M.TokenStore()
        guard let token = success(store.issue(binding, now: 100)) else { throw Failure(description: "No token issued") }
        try check(token.count == 32 && token.allSatisfy(\.isHexDigit) && !token.contains("context") && !token.contains(profile.uuidString),
                  "A token is not opaque 128-bit hex: \(token)")
        try check(success(store.redeem(token, current: binding, now: 101)) == binding, "A valid token was not redeemed")
        try check(failure(store.redeem(token, current: binding, now: 101)) == .unknownToken, "A token was usable twice")
        for (changed, expected) in [
            (M.Binding(context: "context-b", runtime: runtimeA, profile: profile, generation: 3, mutation: 7), M.Refusal.bindingChanged),
            (M.Binding(context: "context-a", runtime: runtimeB, profile: profile, generation: 3, mutation: 7), .bindingChanged),
            (M.Binding(context: "context-a", runtime: runtimeA, profile: otherProfile, generation: 3, mutation: 7), .bindingChanged),
            (M.Binding(context: "context-a", runtime: runtimeA, profile: profile, generation: 4, mutation: 7), .topologyChanged),
            (M.Binding(context: "context-a", runtime: runtimeA, profile: profile, generation: 3, mutation: 8), .topologyChanged),
        ] {
            let issued = success(store.issue(binding, now: 100))!
            try check(failure(store.redeem(issued, current: changed, now: 101)) == expected, "A changed binding was not refused as \(expected): \(changed)")
            try check(failure(store.redeem(issued, current: binding, now: 101)) == .unknownToken, "A refused token stayed usable")
        }
        let expiring = success(store.issue(binding, now: 100))!
        try check(failure(store.redeem(expiring, current: binding, now: 100 + M.tokenLifetime)) == .expired, "An expired token was redeemed")
        try check(failure(store.redeem("not-a-token", current: binding, now: 100)) == .unknownToken
                  && failure(store.redeem(String(repeating: "a", count: 5_000), current: binding, now: 100)) == .unknownToken, "An unknown token was accepted")
        var capped = M.TokenStore()
        for _ in 0..<M.maximumTokensPerContext { _ = capped.issue(binding, now: 0) }
        try check(failure(capped.issue(binding, now: 0)) == .tooManyTokens && capped.count(context: "context-a") == M.maximumTokensPerContext,
                  "The per-context token cap was not enforced")
        var other = binding; other.context = "context-b"
        try check(success(capped.issue(other, now: 0)) != nil, "One context's cap blocked another context")
        try check(success(capped.issue(binding, now: M.tokenLifetime + 1)) != nil, "Expired tokens still counted toward the cap")
        var global = M.TokenStore()
        for index in 0..<M.maximumTokens { var each = binding; each.context = "c\(index)"; _ = global.issue(each, now: 0) }
        var extra = binding; extra.context = "extra"
        try check(failure(global.issue(extra, now: 0)) == .tooManyTokens && global.count == M.maximumTokens, "The global token cap was not enforced")
        var purging = M.TokenStore()
        let keptToken = success(purging.issue(other, now: 0))!
        let purged = success(purging.issue(binding, now: 0))!
        purging.purge(context: "context-a")
        try check(failure(purging.redeem(purged, current: binding, now: 1)) == .unknownToken && success(purging.redeem(keptToken, current: other, now: 1)) != nil,
                  "Purging a context removed the wrong tokens")
        var runtimeBound = binding; runtimeBound.runtime = runtimeB
        let otherRuntimeToken = success(purging.issue(runtimeBound, now: 0))!
        let thisRuntimeToken = success(purging.issue(binding, now: 0))!
        purging.purge(runtime: runtimeA)
        try check(failure(purging.redeem(thisRuntimeToken, current: binding, now: 1)) == .unknownToken
                  && success(purging.redeem(otherRuntimeToken, current: runtimeBound, now: 1)) != nil, "Purging a runtime removed the wrong tokens")
        _ = purging.issue(binding, now: 0); purging.purgeAll()
        try check(purging.count == 0, "purgeAll left tokens")
        var colliding = M.TokenStore(); colliding.makeToken = { "same" }
        _ = colliding.issue(binding, now: 0)
        try check(failure(colliding.issue(binding, now: 0)) == .tooManyTokens, "A colliding token replaced an outstanding one")

        // Generation: every distinct served topology advances it; window order alone does not.
        let w1 = ids[0], w2 = ids[1], a = ids[2], b = ids[3], c = ids[4], a2 = ids[5], w1b = ids[6]
        var generation = M.Generation()
        let first = generation.record([M.ObservedWindow(adapter: w1, isSinglePage: false, tabs: [a, b])])
        try check(first == 1 && generation.record([M.ObservedWindow(adapter: w1, isSinglePage: false, tabs: [a, b])]) == 1,
                  "An unchanged topology advanced the generation, or the first did not")
        let swapped = generation.record([M.ObservedWindow(adapter: w1, isSinglePage: false, tabs: [b, a])])
        let restored = generation.record([M.ObservedWindow(adapter: w1, isSinglePage: false, tabs: [a, b])])
        try check(swapped == 2 && restored == 3, "A swap and swap back (ABA) did not advance the generation each time")
        try check(generation.record([M.ObservedWindow(adapter: w1, isSinglePage: false, tabs: [a2, b])]) == 4, "A replaced tab adapter did not advance the generation")
        try check(generation.record([M.ObservedWindow(adapter: w1b, isSinglePage: false, tabs: [a2, b])]) == 5, "A replaced window adapter did not advance the generation")
        try check(generation.record([M.ObservedWindow(adapter: w1b, isSinglePage: true, tabs: [a2, b])]) == 6, "A window kind change did not advance the generation")
        let two = [M.ObservedWindow(adapter: w1b, isSinglePage: true, tabs: [a2, b]), M.ObservedWindow(adapter: w2, isSinglePage: true, tabs: [c])]
        let withPopup = generation.record(two)
        try check(withPopup == 7 && generation.record(two.reversed()) == 7, "Window membership did not count, or window order alone did")
        try check(generation.record([M.ObservedWindow(adapter: w1b, isSinglePage: true, tabs: [a2, b]), M.ObservedWindow(adapter: w2, isSinglePage: true, tabs: [c, a])]) == 8,
                  "A tab joining another window did not advance the generation")

        // Request parsing: strict and bounded.
        func params(_ entries: [Any], extra: [String: Any] = [:]) -> [String: Any] {
            ["token": "t", "normalWindows": 1, "popupWindows": 0, "entries": entries].merging(extra) { _, new in new }
        }
        let parsed = success(M.request(from: params([["window": "normal", "index": 0], ["window": "popup", "index": 0]], extra: ["urlPatterns": ["*://*/*"], "title": "A*"])))
        try check(parsed?.entries == [M.Entry(window: .normal, index: 0), M.Entry(window: .popup, index: 0)] && parsed?.urlPatterns == ["*://*/*"]
                  && parsed?.titlePattern == "A*" && parsed?.hasFilter == true, "A valid request was not parsed exactly")
        for bad: [String: Any] in [
            params([["window": "normal", "index": 1.5]]), params([["window": "normal", "index": true]]), params([["window": "normal", "index": "1"]]),
            params([["window": "normal", "index": -1]]), params([["window": "normal", "index": M.maximumIndex + 1]]), params([["window": "other", "index": 0]]),
            params([["window": "normal", "index": 0, "extra": 1]]), params([], extra: ["surprise": 1]), params([], extra: ["normalWindows": 2.5]),
            params([], extra: ["popupWindows": M.maximumWindowCount + 1]), params([], extra: ["token": ""]), params([], extra: ["token": String(repeating: "a", count: 65)]),
            params(Array(repeating: ["window": "normal", "index": 0] as [String: Any], count: M.maximumEntries + 1)),
            params([], extra: ["urlPatterns": Array(repeating: "*://*/*", count: M.maximumURLPatterns + 1)]), params([], extra: ["urlPatterns": [""]]),
            params([], extra: ["urlPatterns": "*://*/*"]), params([], extra: ["title": String(repeating: "x", count: M.maximumTitlePatternLength + 1)]),
            params([], extra: ["title": 3]),
        ] {
            guard case .failure(.invalidRequest) = M.request(from: bad) else { throw Failure(description: "An invalid request was accepted: \(bad)") }
            checks += 1
        }

        // Answers: identity by the reported window and index only; identical URLs stay distinct.
        let same = URL(string: "https://example.com/same")!
        let main = M.LiveWindow(adapter: w1, isSinglePage: false, tabs: [
            M.LiveTab(adapter: a, url: same, title: "First"), M.LiveTab(adapter: b, url: same, title: "Second"),
            M.LiveTab(adapter: c, url: URL(string: "webkit-extension://abc/page.html"), title: "Own page"),
            M.LiveTab(adapter: a2, url: URL(string: "orbit://newtab"), title: "New tab"),
        ])
        func ask(_ entries: [M.Entry], normal: Int = 1, popup: Int = 0, urls: [String]? = nil, title: String? = nil, windows: [M.LiveWindow]) -> Result<[M.Metadata?], M.Refusal> {
            M.answer(M.Request(token: "t", normalWindows: normal, popupWindows: popup, entries: entries, urlPatterns: urls, titlePattern: title),
                     windows: windows, urlMatches: { $0.host == "example.com" })
        }
        let answered = success(ask([M.Entry(window: .normal, index: 1), M.Entry(window: .normal, index: 0), M.Entry(window: .normal, index: 2),
                                    M.Entry(window: .normal, index: 3), M.Entry(window: .normal, index: 9)], windows: [main]))
        try check(answered == [M.Metadata(url: same.absoluteString, title: "Second"), M.Metadata(url: same.absoluteString, title: "First"), nil, nil, nil],
                  "Same-URL tabs were not answered by index, or a non-web/out-of-range tab was disclosed: \(String(describing: answered))")
        try check(failure(ask([M.Entry(window: .normal, index: 0)], normal: 2, windows: [main])) == .windowsChanged
                  && failure(ask([], popup: 1, windows: [main])) == .windowsChanged
                  && failure(ask([M.Entry(window: .normal, index: 0)], normal: 2, windows: [main, M.LiveWindow(adapter: w2, isSinglePage: false, tabs: [])])) == .windowsChanged,
                  "Disagreeing or ambiguous normal windows were answered")
        let popupOne = M.LiveWindow(adapter: w2, isSinglePage: true, tabs: [M.LiveTab(adapter: ids[7], url: URL(string: "http://127.0.0.1:8000/p")!, title: "Popup")])
        let popupTwo = M.LiveWindow(adapter: w1b, isSinglePage: true, tabs: [M.LiveTab(adapter: ids[8], url: URL(string: "http://127.0.0.1:8000/q")!, title: "Other")])
        try check(success(ask([M.Entry(window: .popup, index: 0)], popup: 1, windows: [main, popupOne])) == [M.Metadata(url: "http://127.0.0.1:8000/p", title: "Popup")],
                  "The only Little Bam window was not answered")
        try check(success(ask([M.Entry(window: .popup, index: 0), M.Entry(window: .normal, index: 0)], popup: 2, windows: [main, popupOne, popupTwo]))
                  == [nil, M.Metadata(url: same.absoluteString, title: "First")] && success(ask([M.Entry(window: .popup, index: 1)], popup: 1, windows: [main, popupOne])) == [nil],
                  "An ambiguous Little Bam window, or a popup index other than 0, was disclosed")
        let longURL = URL(string: "https://example.com/" + String(repeating: "x", count: M.maximumURLBytes))!
        let bounded = M.LiveWindow(adapter: w1, isSinglePage: false, tabs: [
            M.LiveTab(adapter: a, url: longURL, title: "Long"), M.LiveTab(adapter: b, url: same, title: String(repeating: "t", count: M.maximumTitleBytes + 1)),
            M.LiveTab(adapter: c, url: same, title: nil)])
        try check(success(ask((0..<3).map { M.Entry(window: .normal, index: $0) }, windows: [bounded]))
                  == [nil, M.Metadata(url: same.absoluteString, title: nil), M.Metadata(url: same.absoluteString, title: nil)],
                  "An over-bound URL or title was disclosed or truncated")
        let big = M.LiveWindow(adapter: w1, isSinglePage: false, tabs: (0..<M.maximumEntries).map { _ in
            M.LiveTab(adapter: a, url: URL(string: "https://example.com/" + String(repeating: "y", count: 8_000))!, title: nil) })
        try check(failure(ask((0..<M.maximumEntries).map { M.Entry(window: .normal, index: $0) }, windows: [big])) == .replyTooLarge,
                  "An oversized reply was not refused as a whole")

        // Filters: URL patterns via the runtime's matcher, title by WebKit's wildcard; unanswerable tabs never match.
        let filtered = success(ask((0..<3).map { M.Entry(window: .normal, index: $0) }, urls: ["https://example.com/*"], title: "F*", windows: [main]))
        try check(filtered?.map { $0?.matches } == [true, false, nil], "URL and title filters were not both applied: \(String(describing: filtered))")
        let otherHost = M.LiveWindow(adapter: w1, isSinglePage: false, tabs: [M.LiveTab(adapter: a, url: URL(string: "https://other.test/")!, title: "First")])
        try check(success(ask([M.Entry(window: .normal, index: 0)], urls: ["https://example.com/*"], windows: [otherHost]))?.first??.matches == false
                  && success(ask([M.Entry(window: .normal, index: 0)], windows: [otherHost]))?.first??.matches == nil,
                  "A URL filter matched another host, or an unfiltered answer carried a match")
        try check(M.titleMatches(pattern: "Inbox*", title: "Inbox (3)") && !M.titleMatches(pattern: "inbox*", title: "Inbox (3)")
                  && !M.titleMatches(pattern: "Inbox", title: "Inbox (3)") && M.titleMatches(pattern: "*", title: "") && M.titleMatches(pattern: "", title: "")
                  && !M.titleMatches(pattern: "", title: "x") && M.titleMatches(pattern: "a?c", title: "a?c") && !M.titleMatches(pattern: "a?c", title: "abc")
                  && M.titleMatches(pattern: "*é*", title: "café") && M.titleMatches(pattern: "**a**", title: "bab"),
                  "Title wildcard semantics differ from WebKit's (case, whole string, literal ?, empty)")
        let pathological = String(repeating: "*a", count: 200) + "b"
        let start = Date()
        try check(!M.titleMatches(pattern: pathological, title: String(repeating: "a", count: 4_000)) && Date().timeIntervalSince(start) < 2,
                  "A pathological title pattern took too long")
        // Exhaustive equivalence with WebCore's MatchTester on a small alphabet.
        let alphabet: [Character] = ["a", "b", "*", "?"]
        func strings(_ length: Int) -> [String] { length == 0 ? [""] : strings(length - 1).flatMap { prefix in alphabet.map { prefix + String($0) } } }
        let patterns = (0...4).flatMap(strings), titles = (0...4).flatMap(strings).filter { !$0.contains("*") }
        for pattern in patterns { for title in titles {
            guard M.titleMatches(pattern: pattern, title: title) == webKitWildcard(Array(pattern.utf16), Array(title.utf16)) else {
                throw Failure(description: "Title wildcard differs from WebKit for pattern \(pattern) title \(title)")
            }
        } }
        checks += 1

        // Reply shape for the bridge.
        let reply = M.reply([M.Metadata(url: "https://example.com/", title: "T", matches: true), nil, M.Metadata(url: "https://example.com/x", title: nil)])
        let replied = reply["entries"] as? [Any]
        try check(replied?.count == 3 && (replied?[0] as? [String: Any])?["title"] as? String == "T" && (replied?[0] as? [String: Any])?["matches"] as? Bool == true
                  && replied?[1] is NSNull && (replied?[2] as? [String: Any])?.keys.sorted() == ["url"], "The bridge reply shape changed")
        try check(JSONSerialization.isValidJSONObject(reply), "The bridge reply is not JSON")
        return checks
    }
}
