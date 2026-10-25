import Foundation

/// Tab URL/title for extensions holding the `tabs` permission, without host access (Chrome's `tabs` contract).
///
/// WebKit redacts a tab's URL and title unless the extension has *host* access to it. Bam's compatibility facade
/// adds only those two values back, to tab objects WebKit itself returned, for a live context whose `tabs`
/// permission is granted. Nothing here grants an origin or bypasses a host check: scripting, cookies, fetch and
/// webRequest stay with WebKit's own checks.
///
/// Identity is never inferred from URLs. A WebKit tab is identified by the (window, index) WebKit reported, which is
/// only trusted when the observed topology provably did not change between issuing a token (before the extension's
/// WebKit call) and answering it (after). `Generation` records every distinct topology the runtime served, so a
/// reorder that is undone in between (ABA) still counts as a change.
///
/// Pure model: Foundation only. The runtime supplies snapshots, clocks and URL-pattern matching.
enum ExtensionTabMetadata {
    // MARK: Limits (all extension input is bounded before any work)

    static let tokenLifetime: TimeInterval = 10
    static let maximumTokensPerContext = 8
    static let maximumTokens = 256
    static let maximumTokenLength = 64
    static let maximumEntries = 512
    static let maximumIndex = 4_095
    static let maximumWindowCount = 64
    static let maximumURLPatterns = 32
    static let maximumURLPatternLength = 2_048
    static let maximumTitlePatternLength = 1_024
    /// Values over these are left redacted, never truncated.
    static let maximumURLBytes = 32 * 1_024
    static let maximumTitleBytes = 4 * 1_024
    /// A reply larger than this is refused as a whole (the facade then returns WebKit's own result).
    static let maximumReplyBytes = 1_024 * 1_024

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case notPermitted
        case unknownToken
        case expired
        case bindingChanged
        case topologyChanged
        case tooManyTokens
        case invalidRequest(String)
        case windowsChanged
        case replyTooLarge

        var description: String {
            switch self {
            case .notPermitted: return "Tab metadata requires this extension's granted tabs permission."
            case .unknownToken: return "This tab metadata request is not known or was already answered."
            case .expired: return "This tab metadata request expired."
            case .bindingChanged: return "The extension context, profile or runtime changed during the request."
            case .topologyChanged: return "Tabs changed during the request."
            case .tooManyTokens: return "Too many tab metadata requests are pending."
            case .invalidRequest(let detail): return "Invalid tab metadata request: \(detail)"
            case .windowsChanged: return "The reported windows do not match Bam's windows."
            case .replyTooLarge: return "The tab metadata reply would be too large."
            }
        }
    }

    // MARK: Observed topology

    struct ObservedWindow: Equatable {
        /// The extension window adapter (one WebKit window ID per adapter).
        var adapter: ObjectIdentifier
        var isSinglePage: Bool
        /// Tab adapters in reported index order (one WebKit tab ID per adapter).
        var tabs: [ObjectIdentifier]
    }

    /// Advances whenever the runtime serves a topology different from the last one it served. Record every computed
    /// topology (not cache hits, which by definition repeat the last one) before handing any of it to WebKit.
    struct Generation {
        private(set) var value: UInt64 = 0
        private var last: [ObservedWindow]?

        /// Window order is not meaningful (the runtime groups windows in a dictionary); tab order is.
        @discardableResult mutating func record(_ windows: [ObservedWindow]) -> UInt64 {
            let normalized = windows.sorted { $0.adapter < $1.adapter }
            if normalized != last {
                last = normalized
                value &+= 1
            }
            return value
        }
    }

    // MARK: Tokens

    /// Everything a token is bound to. The runtime builds the current binding again when answering.
    struct Binding: Hashable {
        var context: String
        var runtime: ObjectIdentifier
        var profile: UUID
        /// `Generation.value` after recording the topology the request is answered from.
        var generation: UInt64
        /// The runtime's monotonic topology mutation counter.
        var mutation: UInt64
    }

    struct TokenStore {
        private struct Issued { var binding: Binding; var expires: TimeInterval }
        private var entries: [String: Issued] = [:]
        /// Opaque, unguessable token text. Replaceable for tests only.
        var makeToken: () -> String = {
            var generator = SystemRandomNumberGenerator()
            return (0..<2).map { _ in String(generator.next() as UInt64, radix: 16).leftPadded(to: 16) }.joined()
        }

        var count: Int { entries.count }
        func count(context: String) -> Int { entries.values.filter { $0.binding.context == context }.count }

        mutating func issue(_ binding: Binding, now: TimeInterval) -> Result<String, Refusal> {
            guard now.isFinite else { return .failure(.expired) }
            purgeExpired(now: now)
            guard count(context: binding.context) < ExtensionTabMetadata.maximumTokensPerContext,
                  entries.count < ExtensionTabMetadata.maximumTokens else { return .failure(.tooManyTokens) }
            var token = makeToken()
            var attempts = 0
            while entries[token] != nil || token.isEmpty || token.count > ExtensionTabMetadata.maximumTokenLength {
                attempts += 1
                guard attempts < 4 else { return .failure(.tooManyTokens) }
                token = makeToken()
            }
            entries[token] = Issued(binding: binding, expires: now + ExtensionTabMetadata.tokenLifetime)
            return .success(token)
        }

        /// Single use: the token is consumed whatever the outcome. `current` is the binding rebuilt from the live
        /// context, runtime, profile and freshly recorded topology at reply time.
        mutating func redeem(_ token: String, current: Binding, now: TimeInterval) -> Result<Binding, Refusal> {
            guard token.count <= ExtensionTabMetadata.maximumTokenLength, let entry = entries.removeValue(forKey: token) else {
                return .failure(.unknownToken)
            }
            guard now.isFinite, now < entry.expires else { return .failure(.expired) }
            let issued = entry.binding
            guard issued.context == current.context, issued.runtime == current.runtime, issued.profile == current.profile else {
                return .failure(.bindingChanged)
            }
            guard issued.generation == current.generation, issued.mutation == current.mutation else { return .failure(.topologyChanged) }
            return .success(issued)
        }

        mutating func purge(context: String) { entries = entries.filter { $0.value.binding.context != context } }
        mutating func purge(runtime: ObjectIdentifier) { entries = entries.filter { $0.value.binding.runtime != runtime } }
        mutating func purgeAll() { entries.removeAll() }
        mutating func purgeExpired(now: TimeInterval) { entries = entries.filter { now.isFinite && now < $0.value.expires } }
    }

    // MARK: Request (`tabs.metadata` bridge params)

    enum WindowKind: String { case normal, popup }

    struct Entry: Equatable {
        var window: WindowKind
        var index: Int
    }

    struct Request: Equatable {
        var token: String
        /// How many normal and popup windows the extension saw (from WebKit's windows API) during the request.
        var normalWindows: Int
        var popupWindows: Int
        var entries: [Entry]
        /// Present only for a `tabs.query` with `url` and/or `title` filters.
        var urlPatterns: [String]?
        var titlePattern: String?
        var hasFilter: Bool { urlPatterns != nil || titlePattern != nil }
    }

    static func request(from params: [String: Any]) -> Result<Request, Refusal> {
        let known: Set<String> = ["token", "normalWindows", "popupWindows", "entries", "urlPatterns", "title"]
        if let unknown = params.keys.first(where: { !known.contains($0) }) { return .failure(.invalidRequest("unknown field \(unknown)")) }
        guard let token = params["token"] as? String, !token.isEmpty, token.count <= maximumTokenLength else {
            return .failure(.invalidRequest("token"))
        }
        guard let normal = exactInt(params["normalWindows"], in: 0...maximumWindowCount),
              let popup = exactInt(params["popupWindows"], in: 0...maximumWindowCount) else {
            return .failure(.invalidRequest("window counts"))
        }
        guard let rawEntries = params["entries"] as? [Any], rawEntries.count <= maximumEntries else {
            return .failure(.invalidRequest("entries"))
        }
        var entries: [Entry] = []
        entries.reserveCapacity(rawEntries.count)
        for raw in rawEntries {
            guard let object = raw as? [String: Any], object.count == 2,
                  let kind = (object["window"] as? String).flatMap(WindowKind.init(rawValue:)),
                  let index = exactInt(object["index"], in: 0...maximumIndex) else {
                return .failure(.invalidRequest("entry"))
            }
            entries.append(Entry(window: kind, index: index))
        }
        var urlPatterns: [String]?
        if let raw = params["urlPatterns"] {
            guard let list = raw as? [Any], list.count <= maximumURLPatterns else { return .failure(.invalidRequest("urlPatterns")) }
            var patterns: [String] = []
            for item in list {
                guard let pattern = item as? String, !pattern.isEmpty, pattern.utf16.count <= maximumURLPatternLength else {
                    return .failure(.invalidRequest("urlPatterns"))
                }
                patterns.append(pattern)
            }
            urlPatterns = patterns
        }
        var titlePattern: String?
        if let raw = params["title"] {
            guard let pattern = raw as? String, pattern.utf16.count <= maximumTitlePatternLength else { return .failure(.invalidRequest("title")) }
            titlePattern = pattern
        }
        return .success(Request(token: token, normalWindows: normal, popupWindows: popup, entries: entries,
                                urlPatterns: urlPatterns, titlePattern: titlePattern))
    }

    /// A JSON number that is exactly an integer in range: no Booleans, fractions or strings.
    private static func exactInt(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= Double(range.lowerBound), double <= Double(range.upperBound) else { return nil }
        return Int(double)
    }

    // MARK: Answer

    struct LiveTab {
        var adapter: ObjectIdentifier
        /// What the tab adapter reports to WebKit (`url(for:)`, `title(for:)`).
        var url: URL?
        var title: String?
    }

    struct LiveWindow {
        var adapter: ObjectIdentifier
        var isSinglePage: Bool
        var tabs: [LiveTab]
    }

    /// The observation to record for a snapshot. Build both from the same snapshot.
    static func observed(_ windows: [LiveWindow]) -> [ObservedWindow] {
        windows.map { ObservedWindow(adapter: $0.adapter, isSinglePage: $0.isSinglePage, tabs: $0.tabs.map(\.adapter)) }
    }

    struct Metadata: Equatable {
        var url: String
        /// Nil when the tab has no title or the title is over the bound (left redacted).
        var title: String?
        /// Present only when the request had a filter.
        var matches: Bool?
    }

    /// Only ordinary web pages are disclosed; anything else stays as WebKit reported it.
    static func disclosableURL(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        let text = url.absoluteString
        return text.utf8.count <= maximumURLBytes ? text : nil
    }

    /// Answers each entry from the live snapshot (one entry per WebKit tab object, by the window and index WebKit
    /// reported). Call only after `TokenStore.redeem` succeeded against a binding built from this same snapshot.
    /// `urlMatches` evaluates the request's URL patterns with WebKit's public match patterns.
    static func answer(_ request: Request, windows: [LiveWindow], urlMatches: (URL) -> Bool) -> Result<[Metadata?], Refusal> {
        let normals = windows.filter { !$0.isSinglePage }, popups = windows.filter(\.isSinglePage)
        // The extension's window view and Bam's must agree; with an unchanged topology they always do.
        guard request.normalWindows == normals.count, request.popupWindows == popups.count else { return .failure(.windowsChanged) }
        if request.entries.contains(where: { $0.window == .normal }), normals.count != 1 { return .failure(.windowsChanged) }
        var answers: [Metadata?] = []
        answers.reserveCapacity(request.entries.count)
        var bytes = 0
        for entry in request.entries {
            let tab: LiveTab?
            switch entry.window {
            case .normal:
                tab = normals[0].tabs.indices.contains(entry.index) ? normals[0].tabs[entry.index] : nil
            case .popup:
                // Several single-page windows cannot be told apart by WebKit window ID here: stay redacted.
                tab = popups.count == 1 && entry.index == 0 ? popups[0].tabs.first : nil
            }
            guard let tab, let address = disclosableURL(tab.url) else { answers.append(nil); continue }
            let title = tab.title.flatMap { $0.utf8.count <= maximumTitleBytes ? $0 : nil }
            var matches: Bool?
            if request.hasFilter {
                let urlOK = request.urlPatterns.map { $0.isEmpty || urlMatches(tab.url!) } ?? true
                let titleOK = request.titlePattern.map { titleMatches(pattern: $0, title: title ?? "") } ?? true
                matches = urlOK && titleOK
            }
            bytes += address.utf8.count + (title?.utf8.count ?? 0) + 64
            guard bytes <= maximumReplyBytes else { return .failure(.replyTooLarge) }
            answers.append(Metadata(url: address, title: title, matches: matches))
        }
        return .success(answers)
    }

    /// The bridge reply value: `{entries: [null | {url, title?, matches?}]}`.
    static func reply(_ answers: [Metadata?]) -> [String: Any] {
        ["entries": answers.map { answer -> Any in
            guard let answer else { return NSNull() }
            var object: [String: Any] = ["url": answer.url]
            if let title = answer.title { object["title"] = title }
            if let matches = answer.matches { object["matches"] = matches }
            return object
        }]
    }

    // MARK: Title filter

    /// WebKit's `tabs.query` title semantics (WebCore `matchesWildcardPattern`): the whole title must match, `*`
    /// matches any run of UTF-16 code units (including none), every other character (including `?`) matches only
    /// itself, case-sensitively. Iterative, so many `*` cannot cause exponential backtracking.
    static func titleMatches(pattern: String, title: String) -> Bool {
        let p = Array(pattern.utf16), t = Array(title.utf16)
        let star = UInt16(UInt8(ascii: "*"))
        var pi = 0, ti = 0, lastStar = -1, resume = 0
        while ti < t.count {
            if pi < p.count && p[pi] != star && p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count && p[pi] == star { lastStar = pi; resume = ti; pi += 1 }
            else if lastStar >= 0 { pi = lastStar + 1; resume += 1; ti = resume }
            else { return false }
        }
        while pi < p.count && p[pi] == star { pi += 1 }
        return pi == p.count
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { count >= length ? self : String(repeating: "0", count: length - count) + self }
}
