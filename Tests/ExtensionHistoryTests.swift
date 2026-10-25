import Foundation

/// history.search model: official-schema validation, documented subset semantics, bounded input and reply.
@main struct ExtensionHistoryTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension history — \(try run()) checks") }
        catch { fputs("FAIL: Extension history: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias H = ExtensionHistory
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }   // as the bridge receives params
        func parsed(_ text: String) -> H.Query? { if case .success(let query) = H.query(json(text), now: now) { return query }; return nil }
        func refused(_ raw: Any?) -> Bool { if case .failure = H.query(raw, now: now) { return true }; return false }

        // Official schema: text string required; startTime/endTime finite numbers; maxResults integer >= 0.
        try check(parsed(#"{"text": "", "maxResults": 2147483647}"#)?.maxResults == 2_147_483_647, "The Int32 maximum for maxResults was refused")
        let defaults = parsed(#"{"text": ""}"#)
        try check(defaults == H.Query(words: [], start: (now.timeIntervalSince1970 - 86_400) * 1_000, end: nil, maxResults: 100),
                  "Defaults were not 24 hours / no end / 100: \(String(describing: defaults))")
        try check(parsed(#"{"text": " a  b ", "startTime": 0, "endTime": 5.5, "maxResults": 20000}"#) == H.Query(words: ["a", "b"], start: 0, end: 5.5, maxResults: 20_000),
                  "A valid explicit query was not taken as given")
        try check(refused(nil) && refused(json("[]")) && refused(json("{}")) && refused(json(#"{"text": 3}"#)) && refused(json(#"{"text": true}"#)) &&
                  refused(json(#"{"text": "", "startTime": "0"}"#)) && refused(json(#"{"text": "", "startTime": true}"#)) && refused(json(#"{"text": "", "endTime": false}"#)) &&
                  refused(["text": "", "startTime": Double.infinity]) && refused(json(#"{"text": "", "maxResults": 1.5}"#)) &&
                  refused(json(#"{"text": "", "maxResults": -1}"#)) && refused(json(#"{"text": "", "maxResults": true}"#)) &&
                  refused(json(#"{"text": "", "startTime": null}"#)) && refused(json(#"{"text": "", "maxResults": 2147483648}"#)) && refused(json(#"{"text": "", "maxResults": 1e300}"#)),
                  "An invalid query (missing/non-string text, non-finite or boolean times, fractional/negative/boolean maxResults) was accepted")

        // Aggregation per URL: title and lastVisitTime from the latest visit; included if any visit is in [start, end).
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        func ok(_ result: Result<[[String: Any]], H.Failure>) -> [[String: Any]] { (try? result.get()) ?? [["failed": true]] }
        let visits = [H.Visit(url: "https://a.example/", title: "A new", visitedAt: at(500)),
                      H.Visit(url: "https://b.example/Page", title: "Beta", visitedAt: at(400)),
                      H.Visit(url: "https://a.example/", title: "A old", visitedAt: at(100)),
                      H.Visit(url: "https://c.example/", title: "Gamma", visitedAt: at(300))]
        func urls(_ query: H.Query) -> [String] { ok(H.search(visits, query)).map { $0["url"] as? String ?? "?" } }
        let all = ok(H.search(visits, H.Query(words: [], start: 0, end: nil, maxResults: 100)))
        try check(all.map { $0["url"] as? String } == ["https://a.example/", "https://b.example/Page", "https://c.example/"] &&
                  all[0]["title"] as? String == "A new" && all[0]["lastVisitTime"] as? Double == 500_000,
                  "Aggregation, newest-first order or latest title/time were wrong: \(all)")
        try check(urls(H.Query(words: [], start: 0, end: 200_000, maxResults: 100)) == ["https://a.example/"] &&
                  ok(H.search(visits, H.Query(words: [], start: 0, end: 200_000, maxResults: 100))).first?["lastVisitTime"] as? Double == 500_000,
                  "A URL with an older visit in range was not included, or did not report its latest visit")
        try check(urls(H.Query(words: [], start: 300_000, end: 400_000, maxResults: 100)) == ["https://c.example/"],
                  "Range boundaries were not start-inclusive and end-exclusive")
        try check(urls(H.Query(words: ["BETA"], start: 0, end: nil, maxResults: 100)) == ["https://b.example/Page"] &&
                  urls(H.Query(words: ["example", "page"], start: 0, end: nil, maxResults: 100)) == ["https://b.example/Page"] &&
                  urls(H.Query(words: ["missing"], start: 0, end: nil, maxResults: 100)).isEmpty,
                  "Word matching over title and URL was wrong")
        try check(urls(H.Query(words: [], start: 0, end: nil, maxResults: 2)).count == 2 && urls(H.Query(words: [], start: 0, end: nil, maxResults: 0)).isEmpty,
                  "maxResults was not applied")
        let item = all[0]
        try check(item["id"] as? String == H.id("https://a.example/") && (item["id"] as? String)?.count == 64 && item["visitCount"] == nil && item["typedCount"] == nil &&
                  Set(item.keys) == ["id", "url", "title", "lastVisitTime"], "Items invented counts or lacked a full SHA-256 ID: \(item)")

        // Input bound: only the first 5,000 visits (the library's maximum) are read.
        let many = (0...H.maximumVisits).map { H.Visit(url: "https://v\($0).example/", title: "v", visitedAt: at(Double(10_000 - $0))) }
        let found = ok(H.search(many, H.Query(words: [], start: 0, end: nil, maxResults: 20_000)))
        try check(found.count == H.maximumVisits && !found.contains { $0["url"] as? String == "https://v5000.example/" }, "Visits past 5,000 were read")
        // Reply bound from UTF-8 lengths: the estimate never undercounts the real encoding (escapes, non-ASCII), 5,000
        // short records fit, and a huge URL or title is refused before any item is built.
        let encoded = (try? JSONSerialization.data(withJSONObject: found))?.count ?? .max
        try check(encoded < H.maximumReplyBytes, "5,000 short records exceeded the reply bound: \(encoded)")
        let tricky = ["https://q.example/a\"b\\c/d", "ctl\u{01}\u{1F}\n\t", "ünïcødé 🙂 \u{2028}", "plain", ""]
        var undercounted: [String] = []
        for text in tricky {
            let actual = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]))?.count ?? 0
            if let estimate = H.encodedLength(text, limit: .max), estimate < actual - 2 { undercounted.append(text) }
            let one = H.item(url: text, title: text, lastVisit: at(1_799_999_999.123))
            let size = (try? JSONSerialization.data(withJSONObject: [one]))?.count ?? .max
            if size > 2 + H.itemOverhead + (H.encodedLength(text, limit: .max) ?? 0) * 2 { undercounted.append("item:" + text) }
        }
        try check(undercounted.isEmpty, "The encoded-size estimate undercounted: \(undercounted)")
        try check(H.encodedLength(String(repeating: "x", count: 1_000_000), limit: 10) == nil, "The length count did not stop at its limit")
        let hugeURL = H.Visit(url: "https://huge.example/" + String(repeating: "x", count: H.maximumReplyBytes), title: "t", visitedAt: at(1))
        let hugeTitle = H.Visit(url: "https://title.example/", title: String(repeating: "\"", count: H.maximumReplyBytes / 2), visitedAt: at(2))
        for visit in [hugeURL, hugeTitle] {
            if case .success = H.search([visit], H.Query(words: [], start: 0, end: nil, maxResults: 1)) { throw Failure(description: "An oversized reply was not refused") }
            checks += 1
        }
        print("history reply: 5,000 short records encode to \(encoded) bytes (bound \(H.maximumReplyBytes))")

        // Trim: only URLs with no retained visit, once each.
        try check(H.removedURLs(dropped: ["https://a.example/", "https://x.example/", "https://x.example/"], retained: visits) == ["https://x.example/"],
                  "Trimmed URLs with retained visits were listed, or duplicates repeated")
        return checks
    }
}
