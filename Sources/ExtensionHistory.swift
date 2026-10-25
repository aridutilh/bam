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
    /// Encoded search reply bound; larger replies are refused, never truncated. Checked from UTF-8 lengths before any
    /// item, hash or encoding is built.
    static let maximumReplyBytes = 4 * 1_048_576
    /// Chromium's schema types maxResults as an integer (Int32): 0...2147483647.
    static let maximumResultsValue = 2_147_483_647

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
        // Optional members are omitted or numbers; null is refused (as the adapter does).
        func number(_ key: String) -> Double?? {
            guard let value = object[key] else { return .some(nil) }
            guard !isBoolean(value), let double = (value as? NSNumber)?.doubleValue, double.isFinite else { return nil }
            return .some(double)
        }
        guard let start = number("startTime") else { return invalid("'startTime' must be a finite number") }
        guard let end = number("endTime") else { return invalid("'endTime' must be a finite number") }
        guard let max = number("maxResults") else { return invalid("'maxResults' must be a non-negative integer") }
        if let max, max < 0 || max > Double(maximumResultsValue) || max.rounded(.towardZero) != max {
            return invalid("'maxResults' must be an integer from 0 to \(maximumResultsValue)")
        }
        let limit = max.map { Int($0) } ?? 100
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
    /// newest first; every word must appear (case-insensitive) in the title or the URL. Only the first 5,000 visits
    /// are read. The reply's encoded size is bounded from UTF-8 lengths before any item, hash or encoding is built;
    /// an oversized reply is refused, never truncated.
    static func search(_ visits: [Visit], _ query: Query) -> Result<[[String: Any]], Failure> {
        var latest: [String: Visit] = [:], matched = Set<String>(), order: [String] = []
        for visit in visits.prefix(maximumVisits) {
            if let known = latest[visit.url] { if visit.visitedAt > known.visitedAt { latest[visit.url] = visit } }
            else { latest[visit.url] = visit; order.append(visit.url) }
            let time = visit.visitedAt.timeIntervalSince1970 * 1_000
            if time >= query.start, query.end.map({ time < $0 }) ?? true { matched.insert(visit.url) }
        }
        let selected = order.compactMap { url -> Visit? in
            guard matched.contains(url), let visit = latest[url] else { return nil }
            return query.words.allSatisfy { visit.title.localizedCaseInsensitiveContains($0) || visit.url.localizedCaseInsensitiveContains($0) } ? visit : nil
        }
        .sorted { $0.visitedAt > $1.visitedAt }
        .prefix(query.maxResults)
        var budget = maximumReplyBytes - 2
        for visit in selected {
            budget -= itemOverhead
            guard budget >= 0, let url = encodedLength(visit.url, limit: budget) else { return .failure(tooLarge) }
            budget -= url
            guard let title = encodedLength(visit.title, limit: budget) else { return .failure(tooLarge) }
            budget -= title
        }
        let items = selected.map { item(url: $0.url, title: $0.title, lastVisit: $0.visitedAt) }
        // Defense only: the preflight above is an upper bound, so this encoding is already bounded.
        guard let data = try? JSONSerialization.data(withJSONObject: items), data.count <= maximumReplyBytes else { return .failure(tooLarge) }
        return .success(items)
    }

    /// Per-event bound for onVisited / onVisitRemoved payloads (pages get them as script, workers through a port).
    static let maximumEventBytes = 1_048_576
    /// Fixed bytes of `{"allHistory":false,"urls":[]}` plus slack.
    static let removalOverhead = 40
    struct Events {
        /// (event name, payload) pairs to deliver, in order.
        var deliveries: [(String, Any)] = []
        /// Truthful diagnostics for changes that could not be delivered within the bound (no URLs or titles in them).
        var undeliverable: [String] = []
    }
    /// Event payloads for a library change, sized from UTF-8 lengths before any item, hash or message is built.
    /// Nothing is truncated or invented: an onVisited too large for one event is not delivered; removed URLs are split
    /// across several onVisitRemoved events that each fit (every URL once, in order); a single URL too large for any
    /// event is not delivered. Each undelivered change is reported in `undeliverable`.
    static func events(for change: Change) -> Events {
        var result = Events()
        switch change {
        case .visited(let visit):
            var budget = maximumEventBytes - itemOverhead
            guard let url = encodedLength(visit.url, limit: budget) else {
                result.undeliverable.append("history.onVisited was not delivered: the visit's URL alone exceeds \(maximumEventBytes) encoded bytes."); return result
            }
            budget -= url
            guard encodedLength(visit.title, limit: budget) != nil else {
                result.undeliverable.append("history.onVisited was not delivered: the visit's URL and title exceed \(maximumEventBytes) encoded bytes."); return result
            }
            result.deliveries.append(("history.onVisited", item(url: visit.url, title: visit.title, lastVisit: visit.visitedAt)))
        case .removed(let urls):
            var chunk: [String] = [], used = removalOverhead, oversized = 0
            for url in urls {
                guard let length = encodedLength(url, limit: maximumEventBytes - removalOverhead - 1) else { oversized += 1; continue }
                if used + length + 1 > maximumEventBytes, !chunk.isEmpty {
                    result.deliveries.append(("history.onVisitRemoved", ["allHistory": false, "urls": chunk])); chunk = []; used = removalOverhead
                }
                chunk.append(url); used += length + 1
            }
            if !chunk.isEmpty { result.deliveries.append(("history.onVisitRemoved", ["allHistory": false, "urls": chunk])) }
            if oversized > 0 {
                result.undeliverable.append("history.onVisitRemoved was not delivered for \(oversized) URL(s) whose encoding exceeds \(maximumEventBytes) bytes.")
            }
        case .cleared:
            result.deliveries.append(("history.onVisitRemoved", ["allHistory": true, "urls": [String]()]))
        }
        return result
    }
    static let tooLarge = Failure(description: "The history results are too large to deliver; request fewer with maxResults or a narrower time range.")
    /// Upper bound for one item's encoded bytes besides its URL and title: keys, quotes, separators, the 64-character
    /// ID and a millisecond time.
    static let itemOverhead = 160
    /// Bytes a string takes as a JSON string literal (quotes included), counting JSONSerialization's escapes (control
    /// characters up to 6 bytes; quote, backslash and slash 2); nil once over `limit`, without scanning further.
    static func encodedLength(_ string: String, limit: Int) -> Int? {
        var total = 2
        guard total <= limit else { return nil }
        for byte in string.utf8 {
            total += byte < 0x20 ? 6 : (byte == 0x22 || byte == 0x5C || byte == 0x2F) ? 2 : 1
            if total > limit { return nil }
        }
        return total
    }
}
