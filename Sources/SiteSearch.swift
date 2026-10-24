import AppKit

/// A site-specific search provider for the command palette, mirroring Arc's
/// Tab-to-search flow: typing a known site offers "Search <Site>", and Tab
/// scopes the palette to that site until Backspace removes the pill.
struct SiteSearchEngine: Equatable {
    let name: String
    let host: String
    let aliases: [String]
    let color: NSColor
    let symbol: String
    /// Percent-escaped search results URL for a query.
    let searchTemplate: String
    /// Suggestion endpoint returning OpenSearch JSON `["q", ["s", …]]`, if any.
    let suggestTemplate: String?

    static func == (lhs: SiteSearchEngine, rhs: SiteSearchEngine) -> Bool { lhs.host == rhs.host }

    func searchURL(for query: String) -> String? {
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return searchTemplate.replacingOccurrences(of: "%@", with: escaped)
    }
    func suggestURL(for query: String) -> URL? {
        guard let template = suggestTemplate,
              let escaped = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%@", with: escaped))
    }
}

enum SiteSearchCatalog {
    static let engines: [SiteSearchEngine] = [
        SiteSearchEngine(name: "YouTube", host: "youtube.com", aliases: ["yt"],
                         color: NSColor(srgbRed: 1.00, green: 0.12, blue: 0.15, alpha: 1), symbol: "play.rectangle.fill",
                         searchTemplate: "https://www.youtube.com/results?search_query=%@",
                         suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=%@"),
        SiteSearchEngine(name: "Google", host: "google.com", aliases: [],
                         color: NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1), symbol: "magnifyingglass",
                         searchTemplate: "https://www.google.com/search?q=%@",
                         suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q=%@"),
        SiteSearchEngine(name: "Wikipedia", host: "wikipedia.org", aliases: ["wiki"],
                         color: NSColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1), symbol: "book.closed.fill",
                         searchTemplate: "https://en.wikipedia.org/wiki/Special:Search?search=%@",
                         suggestTemplate: "https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=6&search=%@"),
        SiteSearchEngine(name: "Amazon", host: "amazon.com", aliases: [],
                         color: NSColor(srgbRed: 1.00, green: 0.60, blue: 0.00, alpha: 1), symbol: "cart.fill",
                         searchTemplate: "https://www.amazon.com/s?k=%@", suggestTemplate: nil),
        SiteSearchEngine(name: "Reddit", host: "reddit.com", aliases: [],
                         color: NSColor(srgbRed: 1.00, green: 0.27, blue: 0.00, alpha: 1), symbol: "bubble.left.and.bubble.right.fill",
                         searchTemplate: "https://www.reddit.com/search/?q=%@", suggestTemplate: nil),
        SiteSearchEngine(name: "GitHub", host: "github.com", aliases: ["gh"],
                         color: NSColor(srgbRed: 0.14, green: 0.16, blue: 0.18, alpha: 1), symbol: "chevron.left.forwardslash.chevron.right",
                         searchTemplate: "https://github.com/search?q=%@", suggestTemplate: nil),
        SiteSearchEngine(name: "X", host: "x.com", aliases: ["twitter", "twitter.com"],
                         color: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1), symbol: "number",
                         searchTemplate: "https://x.com/search?q=%@", suggestTemplate: nil),
        SiteSearchEngine(name: "DuckDuckGo", host: "duckduckgo.com", aliases: ["ddg"],
                         color: NSColor(srgbRed: 0.87, green: 0.35, blue: 0.20, alpha: 1), symbol: "shield.lefthalf.filled",
                         searchTemplate: "https://duckduckgo.com/?q=%@",
                         suggestTemplate: "https://duckduckgo.com/ac/?type=list&q=%@")
    ]

    /// Matches bare typed text ("youtu", "youtube.com", "yt") to an engine the
    /// palette can offer for Tab-to-search. Paths, queries and multi-word text
    /// never match, so pasted URLs and sentences keep their normal behavior.
    static func match(_ raw: String) -> SiteSearchEngine? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        guard text.count >= 2, !text.contains(" "), !text.contains("/") else { return nil }
        return engines.first { engine in
            engine.aliases.contains(text) || engine.host.hasPrefix(text) || engine.name.lowercased().hasPrefix(text)
                || ("www." + engine.host).hasPrefix(text)
        }
    }
}

/// Debounced autocomplete fetcher. Parses OpenSearch JSON (Google, Wikipedia,
/// DuckDuckGo `type=list`) on a background session and reports on the main actor.
@MainActor final class SearchSuggestionFetcher {
    private var task: URLSessionDataTask?
    private var debounce: DispatchWorkItem?
    private let session: URLSession
    private(set) var lastQuery = ""

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        session = URLSession(configuration: configuration)
    }

    func fetch(url: URL?, query: String, completion: @escaping @MainActor ([String]) -> Void) {
        cancel()
        lastQuery = query
        guard let url, !query.trimmingCharacters(in: .whitespaces).isEmpty else { completion([]); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let task = self.session.dataTask(with: url) { data, _, _ in
                let suggestions = Self.parse(data: data)
                Task { @MainActor [weak self] in
                    guard self?.lastQuery == query else { return }
                    completion(suggestions)
                }
            }
            self.task = task
            task.resume()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancel() {
        debounce?.cancel(); debounce = nil
        task?.cancel(); task = nil
    }

    nonisolated static func parse(data: Data?) -> [String] {
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any], payload.count >= 2,
              let phrases = payload[1] as? [String] else { return [] }
        return Array(phrases.prefix(6))
    }
}
