import CryptoKit
import Foundation

/// Read-only `history.search` and genuine `history.onVisited` / `onVisitRemoved` for one login profile, from Bam's
/// in-memory `BrowserLibrary` history. Pure: no AppKit, no library, no I/O.
///
/// Hook contract (the library/integration side, Arc owner):
/// - `BrowserExtensions.historySnapshot(profileID)` returns that profile's library visits, newest first (the library
///   keeps at most 5,000), mapped to `Visit`; nil when unavailable (unknown profile, shutting down, private).
/// - `BrowserExtensions.historyChanged(profileID:change:)` is called after the library changed:
///   - `.visited(visit)` after `recordVisit` accepted a visit into in-memory history (also a coalesced revisit), even
///     if the later asynchronous disk write fails, exactly as search would show it;
///   - `.removed(urls:)` after that same visit trimmed old entries, listing only URLs with no retained visit
///     (use `removedURLs(dropped:retained:)`), sent after the `.visited` it caused;
///   - `.cleared` only after `clearHistory` committed successfully (a failed, rolled-back clear sends nothing).
///   - Startup load sends nothing.
enum ExtensionHistory {
    static let maximumVisits = 5_000
    /// Encoded search reply bound; larger replies are refused, never truncated.
    static let maximumReplyBytes = 4 * 1_048_576

    struct Visit: Equatable, Sendable {
        let url: String
        let title: String
        let visitedAt: Date
        init(url: String, title: String, visitedAt: Date) { self.url = url; self.title = title; self.visitedAt = visitedAt }
    }
    enum Change: Equatable, Sendable {
        case visited(Visit)
        case removed(urls: [String])
        case cleared
    }

    /// URLs among `dropped` that no retained visit still has (Chrome purges a URL only when all its visits are gone).
    static func removedURLs(dropped: [String], retained: [Visit]) -> [String] {
        let kept = Set(retained.map(\.url)); var seen = Set<String>()
        return dropped.filter { !kept.contains($0) && seen.insert($0).inserted }
    }

    struct Failure: Error, Equatable, CustomStringConvertible { let description: String }

    /// Validated `history.search` query (official schema: text string required; startTime/endTime numbers in ms;
    /// maxResults integer >= 0, default 100; startTime defaults to 24 hours ago).
    struct Query: Equatable {
        let words: [String]
        let start: Double
        let end: Double?
        let maxResults: Int
    }
    static func query(_ raw: Any?, now: Date) -> Result<Query, Failure> {
        func invalid(_ detail: String) -> Result<Query, Failure> { .failure(Failure(description: "Invalid history.search query: \(detail).")) }
        guard let object = raw as? [String: Any] else { return invalid("a query object is required") }
        guard let text = object["text"] as? String, !isBoolean(object["text"]) else { return invalid("'text' must be a string") }
        func number(_ key: String) -> Double?? {
            guard let value = object[key], !(value is NSNull) else { return .some(nil) }
            guard !isBoolean(value), let double = (value as? NSNumber)?.doubleValue, double.isFinite else { return nil }
            return .some(double)
        }
        guard let start = number("startTime") else { return invalid("'startTime' must be a finite number") }
        guard let end = number("endTime") else { return invalid("'endTime' must be a finite number") }
        guard let max = number("maxResults") else { return invalid("'maxResults' must be a non-negative integer") }
        if let max, max < 0 || max.rounded(.towardZero) != max { return invalid("'maxResults' must be a non-negative integer") }
        let limit = max.map { $0 >= Double(Int.max) ? Int.max : Int($0) } ?? 100
        return .success(Query(words: text.split(whereSeparator: \.isWhitespace).map(String.init),
                              start: start ?? (now.timeIntervalSince1970 - 86_400) * 1_000, end: end, maxResults: limit))
    }
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Chrome-shaped item for a URL: full SHA-256 of the URL as a stable ID; no visit or typed counts (Bam coalesces
    /// consecutive visits and keeps 5,000, so counts would be untrue).
    static func item(url: String, title: String, lastVisit: Date) -> [String: Any] {
        ["id": id(url), "url": url, "title": title, "lastVisitTime": (lastVisit.timeIntervalSince1970 * 1_000).rounded()]
    }
    static func id(_ url: String) -> String { SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// One item per URL with a visit in [start, end); title and lastVisitTime from its most recent visit overall;
    /// newest first; words must all appear (case-insensitive) in title + URL. Only the first 5,000 visits are read.
    static func search(_ visits: [Visit], _ query: Query) -> [[String: Any]] {
        var latest: [String: Visit] = [:], matched = Set<String>(), order: [String] = []
        for visit in visits.prefix(maximumVisits) {
            if let known = latest[visit.url] { if visit.visitedAt > known.visitedAt { latest[visit.url] = visit } }
            else { latest[visit.url] = visit; order.append(visit.url) }
            let time = visit.visitedAt.timeIntervalSince1970 * 1_000
            if time >= query.start, query.end.map({ time < $0 }) ?? true { matched.insert(visit.url) }
        }
        let items = order.compactMap { url -> Visit? in
            guard matched.contains(url), let visit = latest[url] else { return nil }
            let text = visit.title + " " + visit.url
            return query.words.allSatisfy { text.localizedCaseInsensitiveContains($0) } ? visit : nil
        }
        .sorted { $0.visitedAt > $1.visitedAt }
        .prefix(query.maxResults)
        return items.map { item(url: $0.url, title: $0.title, lastVisit: $0.visitedAt) }
    }

    /// The reply, or a refusal when its encoded size exceeds the bound (never truncated).
    static func reply(_ items: [[String: Any]]) -> Result<[[String: Any]], Failure> {
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return .failure(Failure(description: "The history results could not be encoded.")) }
        guard data.count <= maximumReplyBytes else {
            return .failure(Failure(description: "The history results are too large to deliver (\(data.count) bytes); request fewer with maxResults or a narrower time range."))
        }
        return .success(items)
    }
}
