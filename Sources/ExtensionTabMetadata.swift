import Foundation

/// Tab URL/title for extensions holding the `tabs` permission, without host access (Chrome's `tabs` contract).
///
/// WebKit redacts a tab's URL and title unless the extension has *host* access to it. Bam's compatibility facade
/// adds only those two values back, to tab objects WebKit itself returned, for a live context whose `tabs`
/// permission is granted. Nothing here grants an origin or bypasses a host check: scripting, cookies, fetch and
/// webRequest stay with WebKit's own checks.
///
/// Identity is never inferred from URLs. A WebKit tab is identified by the (window, index) WebKit reported, trusted only
/// when the observed topology provably did not change between issuing a token (before the extension's WebKit call)
/// and answering it (after). `Generation` advances on every distinct topology served, so a reorder that is undone in
/// between (ABA) still counts as a change.
///
/// Pure model (Foundation only); the engine supplies snapshots, clocks and URL-pattern matching. API agreed in
/// work/chrome-tab-metadata-api.md.
enum ExtensionTabMetadata {
    static let tokenLifetime: TimeInterval = 10
    /// Outstanding, unexpired tokens; `issue` refuses beyond.
    static let maxTokensPerContext = 8
    /// Across all contexts of one store, so many contexts cannot grow host memory without bound.
    static let maxTokens = 256
    static let maxTokenUTF8 = 64
    static let maxEntries = 512
    static let maxIndex = 4_095
    static let maxWindowCount = 64
    static let maxURLUTF8 = 32_768, maxTitleUTF8 = 4_096
    /// Later entries become null once the budget is spent (see `responseFits` for filtered requests).
    static let maxResponseUTF8 = 1_048_576
    static let maxURLPatterns = 32, maxPatternUTF8 = 2_048
    static let maxTitlePatternUTF8 = 2_048
    /// Total title-matcher steps per request; exhausted → `.exhausted` (the whole request falls back).
    static let titleMatchBudget = 2_000_000

    // MARK: Tokens

    /// Everything a token is bound to (the engine fills every field, again at reply time, and compares).
    struct Binding: Equatable, Sendable {
        let context: String        // WKWebExtensionContext.uniqueIdentifier
        let runtime: Int           // ObjectIdentifier(runtime).hashValue
        let profile: UUID
        let generation: UInt64     // observed-topology generation
        let mutation: UInt64       // runtime adapter-mutation counter
    }

    struct TokenStore: Sendable {
        private struct Issued: Sendable { let binding: Binding; let expires: Date }
        private var issued: [String: Issued] = [:]
        init() {}

        var count: Int { issued.count }
        func count(context: String) -> Int { issued.values.filter { $0.binding.context == context }.count }

        /// Purges expired tokens first; nil when this context already holds `maxTokensPerContext`, the store holds
        /// `maxTokens`, or no fresh nonce could be made. `nonce` is injectable for tests.
        mutating func issue(_ binding: Binding, now: Date, nonce: () -> String = ExtensionTabMetadata.randomNonce) -> String? {
            purgeExpired(now: now)
            guard count(context: binding.context) < ExtensionTabMetadata.maxTokensPerContext,
                  issued.count < ExtensionTabMetadata.maxTokens else { return nil }
            for _ in 0..<3 {
                let token = nonce()
                guard !token.isEmpty, token.utf8.count <= ExtensionTabMetadata.maxTokenUTF8, issued[token] == nil else { continue }
                issued[token] = Issued(binding: binding, expires: now.addingTimeInterval(ExtensionTabMetadata.tokenLifetime))
                return token
            }
            return nil
        }

        /// Single use: the token is removed whatever the outcome. nil when unknown or expired.
        mutating func consume(_ token: String, now: Date) -> Binding? {
            guard token.utf8.count <= ExtensionTabMetadata.maxTokenUTF8, let entry = issued.removeValue(forKey: token) else { return nil }
            return now < entry.expires ? entry.binding : nil
        }

        mutating func purge(context: String) { issued = issued.filter { $0.value.binding.context != context } }
        mutating func purge(runtime: Int) { issued = issued.filter { $0.value.binding.runtime != runtime } }
        mutating func purgeAll() { issued.removeAll() }
        mutating func purgeExpired(now: Date) { issued = issued.filter { now < $0.value.expires } }
    }

    /// 16 random bytes, base64url without padding.
    static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Observed topology (optional helper for the engine's generation)

    struct ObservedWindow: Equatable, Sendable {
        /// The window adapter (one WebKit window ID per adapter) and its tab adapters in reported index order.
        let adapter: Int
        let isSinglePage: Bool
        let tabs: [Int]
    }

    /// Advances whenever the served topology differs from the last recorded one. Record every *computed* topology
    /// (cache hits repeat the last one) before any of it reaches WebKit. Window order is ignored; tab order,
    /// membership, adapter identity and window kind count.
    struct Generation: Sendable {
        private(set) var value: UInt64 = 0
        private var last: [ObservedWindow]?
        init() {}
        @discardableResult mutating func record(_ windows: [ObservedWindow]) -> UInt64 {
            let normalized = windows.sorted { $0.adapter < $1.adapter }
            if normalized != last { last = normalized; value &+= 1 }
            return value
        }
    }

    // MARK: Request (`tabs.metadata` params)

    enum WindowKind: String, Sendable { case normal, popup }
    struct Entry: Equatable, Sendable { let window: WindowKind; let index: Int }
    struct Filter: Equatable, Sendable { let urlPatterns: [String]?; let title: String? }

    struct Request: Equatable, Sendable {
        let token: String; let normalCount: Int; let popupCount: Int; let entries: [Entry]; let filter: Filter?

        /// Strict: unknown fields, wrong types, Booleans, fractions, negative or over-limit numbers, unknown window
        /// kinds and over-limit counts or sizes → nil. `filter.url` may be a string or an array of strings (Chrome's shape).
        static func parse(_ params: [String: Any]) -> Request? {
            guard Set(params.keys).isSubset(of: ["token", "normalCount", "popupCount", "entries", "filter"]),
                  let token = params["token"] as? String, !token.isEmpty, token.utf8.count <= maxTokenUTF8,
                  let normal = exactInt(params["normalCount"], max: maxWindowCount),
                  let popup = exactInt(params["popupCount"], max: maxWindowCount),
                  let rawEntries = params["entries"] as? [Any], rawEntries.count <= maxEntries else { return nil }
            var entries: [Entry] = []
            entries.reserveCapacity(rawEntries.count)
            for raw in rawEntries {
                guard let object = raw as? [String: Any], Set(object.keys) == ["window", "index"],
                      let kind = (object["window"] as? String).flatMap(WindowKind.init(rawValue:)),
                      let index = exactInt(object["index"], max: maxIndex) else { return nil }
                entries.append(Entry(window: kind, index: index))
            }
            var filter: Filter?
            if let raw = params["filter"] {
                guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: ["url", "title"]), !object.isEmpty else { return nil }
                var patterns: [String]?
                if let url = object["url"] {
                    let list: [Any] = (url as? String).map { [$0] } ?? (url as? [Any]) ?? []
                    guard url is String || url is [Any], list.count <= maxURLPatterns else { return nil }
                    var parsed: [String] = []
                    for item in list {
                        guard let pattern = item as? String, pattern.utf8.count <= maxPatternUTF8 else { return nil }
                        parsed.append(pattern)
                    }
                    patterns = parsed
                }
                var title: String?
                if let raw = object["title"] {
                    guard let value = raw as? String, value.utf8.count <= maxTitlePatternUTF8 else { return nil }
                    title = value
                }
                filter = Filter(urlPatterns: patterns, title: title)
            }
            return Request(token: token, normalCount: normal, popupCount: popup, entries: entries, filter: filter)
        }
    }

    /// A JSON number that is exactly an integer in 0...max: no Booleans, fractions or strings.
    private static func exactInt(_ value: Any?, max: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= 0, double <= Double(max) else { return nil }
        return Int(double)
    }

    // MARK: Values

    struct Value: Equatable, Sendable { let url: String; let title: String? }

    /// The value to disclose, or nil to leave the entry redacted: http(s) URL with a host only; URL and title within
    /// their UTF-8 bounds (never truncated: either over → nil for the whole entry).
    static func admissible(url: URL?, title: String?) -> Value? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        let text = url.absoluteString
        guard text.utf8.count <= maxURLUTF8, (title?.utf8.count ?? 0) <= maxTitleUTF8 else { return nil }
        return Value(url: text, title: title)
    }

    enum TitleMatch: Equatable, Sendable { case match, noMatch, exhausted }

    /// WebKit-equivalent (WebCore::matchesWildcardPattern via WebExtensionTab::matches): the whole title must match;
    /// only `*` is a wildcard (any run, including empty); every other character, `?` included, is literal;
    /// case-sensitive; compared as UTF-16 code units. Iterative; every step counts against `budget`.
    static func titleMatches(_ pattern: String, _ title: String, budget: inout Int) -> TitleMatch {
        let p = Array(pattern.utf16), t = Array(title.utf16)
        let star = UInt16(UInt8(ascii: "*"))
        var pi = 0, ti = 0, lastStar = -1, resume = 0
        while ti < t.count {
            budget -= 1
            if budget < 0 { return .exhausted }
            if pi < p.count && p[pi] != star && p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count && p[pi] == star { lastStar = pi; resume = ti; pi += 1 }
            else if lastStar >= 0 { pi = lastStar + 1; resume += 1; ti = resume }
            else { return .noMatch }
        }
        while pi < p.count && p[pi] == star {
            budget -= 1
            if budget < 0 { return .exhausted }
            pi += 1
        }
        return pi == p.count ? .match : .noMatch
    }

    // MARK: Response size (an upper bound for any standard JSON encoding of the reply)

    /// Encoded bytes of a JSON string, assuming the most expansive standard encoder: quotes; `"` `\` `/` as two-byte
    /// escapes; control characters as `\u00XX`; every non-ASCII scalar as `\uXXXX` (a surrogate pair for non-BMP).
    static func encodedUpperBound(_ string: String) -> Int {
        var bytes = 2
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C, 0x2F: bytes += 2
            case 0..<0x20, 0x7F: bytes += 6
            case 0x80..<0x10000: bytes += 6
            case 0x10000...: bytes += 12
            default: bytes += 1
            }
        }
        return bytes
    }
    private static let nullBytes = 4                               // null
    /// `{"url":…}` or `{"url":…,"title":…}` with the keys' own bytes.
    private static func encodedUpperBound(_ value: Value) -> Int {
        1 + encodedUpperBound("url") + 1 + encodedUpperBound(value.url)
            + (value.title.map { 1 + encodedUpperBound("title") + 1 + encodedUpperBound($0) } ?? 0) + 1
    }

    /// The array's brackets and commas plus every slot as `null`: what a reply of `count` entries costs at least.
    private static func baseline(_ count: Int) -> Int { 2 + max(0, count - 1) + count * nullBytes }

    /// False when `response` would null any value for size. For a *filtered* request a nulled entry would read as
    /// "doesn't match" and drop a matching tab, so the engine must answer such a request null (fallback) instead.
    static func responseFits(_ values: [Value?]) -> Bool {
        values.reduce(baseline(values.count)) { $0 + ($1.map { encodedUpperBound($0) - nullBytes } ?? 0) } <= maxResponseUTF8
    }

    /// JSON-ready reply: one element per entry, `["url": …, "title": …]` (title omitted when nil) or NSNull, in order.
    /// Once including a value would take the encoded reply past `maxResponseUTF8`, it and every later value are nulled,
    /// so the encoded reply never exceeds the limit (slots are reserved as `null` up front).
    static func response(_ values: [Value?]) -> [Any] {
        var spent = baseline(values.count), full = false
        return values.map { value -> Any in
            guard let value, !full else { return NSNull() }
            let extra = encodedUpperBound(value) - nullBytes
            guard spent + extra <= maxResponseUTF8 else { full = true; return NSNull() }
            spent += extra
            var object: [String: Any] = ["url": value.url]
            if let title = value.title { object["title"] = title }
            return object
        }
    }
}
