import Foundation

/// One visit as the palette sees history: plain values, so this file stays free
/// of the library, AppKit and the controller (component tests compile it alone).
struct PaletteVisit: Equatable {
    var address: String
    var title: String
    var visitedAt: Date
}

/// A visited page offered under the typed words, merged from every visit to it.
struct PaletteHistoryHit: Equatable {
    let address: String
    let title: String
    /// Frequency and recency together; more is better.
    let score: Double
}

/// What inline autocompletion settled on: the typed text plus a gray tail.
struct PaletteCompletion: Equatable {
    /// Exactly what the person typed (their casing).
    let typed: String
    /// The text the field shows: `typed` followed by the completed ending.
    let text: String
    /// Where Return goes.
    let address: String
    /// The page's title when Bam knows the site's own page, else empty.
    let title: String
    var tail: String { String(text.dropFirst(typed.count)) }
}

/// Address keys shared by history merging, de-duplication and autocompletion:
/// no scheme, no leading "www.", no fragment and no trailing slash.
enum PaletteAddressKey {
    static func key(_ address: String) -> String {
        var value = address.lowercased()
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) { value = String(value.dropFirst(scheme.count)); break }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    /// The bare host of a web address ("github.com"), without "www.".
    static func host(_ address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }
    /// The host with its port when it has one ("localhost:3000"), without "www.": what a host completion shows.
    static func authority(_ address: String) -> String? {
        guard let host = host(address) else { return nil }
        return URL(string: address)?.port.map { "\(host):\($0)" } ?? host
    }
    /// How a row shows an address: no scheme, no "www.", no trailing slash.
    static func display(_ address: String) -> String {
        var value = address
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) { value = String(value.dropFirst(scheme.count)); break }
        if value.lowercased().hasPrefix("www.") { value = String(value.dropFirst(4)) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// History grouped by page once per palette, then searched on every keystroke.
struct PaletteHistoryIndex {
    struct Site {
        let key: String
        let address: String
        let title: String
        let host: String
        let normalizedTitle: String
        let score: Double
        let visits: Int
    }
    private(set) var sites: [Site] = []

    init(visits: [PaletteVisit], now: Date = Date()) {
        struct Accumulator { var address: String; var title: String; var latest: Date; var score: Double; var visits: Int }
        var merged: [String: Accumulator] = [:]
        var order: [String] = []
        for visit in visits {
            guard PaletteAddressKey.host(visit.address) != nil else { continue }
            let key = PaletteAddressKey.key(visit.address)
            // Each visit counts, newer ones more: a page opened daily this week beats one opened often last year.
            let ageDays = max(0, now.timeIntervalSince(visit.visitedAt) / 86_400)
            let weight = 1 / (1 + ageDays / 7)
            if var existing = merged[key] {
                existing.score += weight; existing.visits += 1
                if visit.visitedAt > existing.latest {
                    existing.latest = visit.visitedAt; existing.address = visit.address
                    if !visit.title.isEmpty { existing.title = visit.title }
                } else if existing.title.isEmpty { existing.title = visit.title }
                merged[key] = existing
            } else {
                merged[key] = Accumulator(address: visit.address, title: visit.title, latest: visit.visitedAt, score: weight, visits: 1)
                order.append(key)
            }
        }
        sites = order.compactMap { key in
            guard let entry = merged[key], let host = PaletteAddressKey.host(entry.address) else { return nil }
            return Site(key: key, address: entry.address, title: entry.title, host: host,
                        normalizedTitle: PaletteText.normalized(entry.title), score: entry.score, visits: entry.visits)
        }
    }

    /// Pages matching every typed word, best first: an address that starts with the
    /// words, then a title word that starts with them, then anything containing them.
    /// Pages whose key is in `excluding` (open tabs) are left out; the tab row wins.
    func matches(_ raw: String, excluding: Set<String> = [], limit: Int = 3) -> [PaletteHistoryHit] {
        let query = PaletteText.normalized(raw)
        guard !query.isEmpty, limit > 0 else { return [] }
        let tokens = query.split(separator: " ").map(String.init)
        let spacedQuery = " " + query
        var ranked: [(Site, Int)] = []
        for site in sites where !excluding.contains(site.key) {
            let rank: Int
            // Byte compares: both sides are already folded, and String's Unicode-aware search costs
            // milliseconds per keystroke across a full 5,000-page history.
            if PaletteBytes.hasPrefix(site.key, query) { rank = 0 }
            else if PaletteBytes.hasPrefix(site.normalizedTitle, query) || PaletteBytes.contains(site.normalizedTitle, spacedQuery) { rank = 1 }
            else if tokens.allSatisfy({ PaletteBytes.contains(site.normalizedTitle, $0) || PaletteBytes.contains(site.key, $0) }) { rank = 2 }
            else { continue }
            ranked.append((site, rank))
        }
        return ranked.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.score > rhs.0.score }
            .prefix(limit).map { PaletteHistoryHit(address: $0.0.address, title: $0.0.title, score: $0.0.score) }
    }
}

/// A place autocompletion may finish the typed text with.
struct PaletteCompletionCandidate {
    let address: String
    let title: String
    let weight: Double
    /// Parsed once when the palette opens, not on every keystroke: host with port, key, scheme.
    fileprivate let authority: String?
    fileprivate let key: String
    fileprivate let scheme: String
    init(address: String, title: String, weight: Double) {
        self.address = address; self.title = title; self.weight = weight
        authority = PaletteAddressKey.authority(address)
        key = PaletteAddressKey.key(address)
        scheme = address.lowercased().hasPrefix("http://") ? "http" : "https"
    }
}

/// Byte-level text tests for strings that are already case- and diacritic-folded.
enum PaletteBytes {
    static func hasPrefix(_ text: String, _ prefix: String) -> Bool { text.utf8.starts(with: prefix.utf8) }
    static func contains(_ text: String, _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard let first = n.first else { return true }
        return text.utf8.withContiguousStorageIfAvailable { h -> Bool in
            guard h.count >= n.count else { return false }
            var i = 0
            let last = h.count - n.count
            while i <= last {
                if h[i] == first {
                    var j = 1
                    while j < n.count && h[i + j] == n[j] { j += 1 }
                    if j == n.count { return true }
                }
                i += 1
            }
            return false
        } ?? text.contains(needle)
    }
}

/// Inline autocompletion: "git" → "github.com". Only address-shaped text completes
/// (one word, no scheme); hosts complete first, and a typed "/" completes a path.
enum PaletteAutocomplete {
    static func complete(_ typed: String, candidates: [PaletteCompletionCandidate]) -> PaletteCompletion? {
        guard !typed.isEmpty, !typed.contains(where: { $0.isWhitespace }), !typed.contains("://"),
              typed.rangeOfCharacter(from: CharacterSet(charactersIn: "+*=^()\"'")) == nil else { return nil }
        let lower = typed.lowercased()
        let wantsWWW = lower.hasPrefix("www.")
        let wantsPath = lower.contains("/")
        struct Option { var text: String; var weight: Double; var address: String; var addressWeight: Double; var title: String; var rootAddress: String? }
        var options: [String: Option] = [:]
        for candidate in candidates {
            // The host keeps its port ("localhost:3000"), and a site only ever visited over http stays http.
            guard let host = candidate.authority else { continue }
            let key = candidate.key
            let text = (wantsWWW ? "www." : "") + (wantsPath ? key : host)
            guard PaletteBytes.hasPrefix(text, lower) else { continue }
            let fallback = "\(candidate.scheme)://\(host)"
            var option = options[text] ?? Option(text: text, weight: 0, address: fallback, addressWeight: candidate.weight, title: "", rootAddress: nil)
            option.weight += candidate.weight
            if candidate.weight > option.addressWeight { option.address = fallback; option.addressWeight = candidate.weight }
            // The site's own front page names the completion ("github.com  GitHub").
            if wantsPath || key == host {
                if option.rootAddress == nil { option.rootAddress = candidate.address }
                if option.title.isEmpty { option.title = candidate.title }
            }
            options[text] = option
        }
        guard let best = options.values.max(by: { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight < rhs.weight : lhs.text.count > rhs.text.count
        }) else { return nil }
        let tail = String(best.text.dropFirst(typed.count))
        return PaletteCompletion(typed: typed, text: typed + tail, address: best.rootAddress ?? best.address, title: best.title)
    }
}

/// A short alias that opens a fresh document, meeting or sheet in a new tab.
struct PaletteQuickAction: Equatable {
    let id: String
    let title: String
    /// The *.new host, shown dimmed after the title.
    let host: String
    let aliases: [String]
    var address: String { "https://\(host)" }
}

enum PaletteQuickActionCatalog {
    static let actions: [PaletteQuickAction] = [
        PaletteQuickAction(id: "doc", title: "New document", host: "docs.new", aliases: ["doc", "docs", "new doc", "google doc"]),
        PaletteQuickAction(id: "meet", title: "New meeting", host: "meet.new", aliases: ["meet", "meeting", "new meet", "google meet"]),
        PaletteQuickAction(id: "sheet", title: "New spreadsheet", host: "sheets.new", aliases: ["sheet", "sheets", "spreadsheet", "new sheet"]),
        PaletteQuickAction(id: "slides", title: "New presentation", host: "slides.new", aliases: ["slides", "slide", "deck", "presentation"]),
        PaletteQuickAction(id: "cal", title: "New calendar event", host: "cal.new", aliases: ["cal", "event", "new event"]),
        PaletteQuickAction(id: "form", title: "New form", host: "forms.new", aliases: ["form", "forms"]),
        PaletteQuickAction(id: "notion", title: "New Notion page", host: "notion.new", aliases: ["notion"]),
        PaletteQuickAction(id: "figma", title: "New Figma file", host: "figma.new", aliases: ["figma"]),
        PaletteQuickAction(id: "linear", title: "New Linear issue", host: "linear.new", aliases: ["linear", "issue"]),
        PaletteQuickAction(id: "repo", title: "New GitHub repository", host: "repo.new", aliases: ["repo"]),
        PaletteQuickAction(id: "gist", title: "New gist", host: "gist.new", aliases: ["gist"]),
    ]
    /// Shown under the empty field.
    static let suggested = ["doc", "meet", "sheet"].compactMap { id in actions.first { $0.id == id } }

    /// `leading` when the text is an alias outright ("doc", "meet") or names the action ("new doc…"):
    /// then Return opens it. Looser prefix hits ("mee") trail the search row.
    static func matches(_ raw: String, limit: Int = 2) -> [(action: PaletteQuickAction, leading: Bool)] {
        let query = PaletteText.normalized(raw)
        guard query.count >= 3, limit > 0 else { return [] }
        var hits: [(PaletteQuickAction, Bool, Int)] = []
        for (index, action) in actions.enumerated() {
            let title = action.title.lowercased()
            if action.aliases.contains(query) || query == action.host || (query.count >= 5 && title.hasPrefix(query)) {
                hits.append((action, true, index))
            } else if action.aliases.contains(where: { $0.hasPrefix(query) }) || action.host.hasPrefix(query) || title.hasPrefix(query) {
                hits.append((action, false, index + actions.count))
            }
        }
        return hits.sorted { $0.2 < $1.2 }.prefix(limit).map { ($0.0, $0.1) }
    }
}

/// An arithmetic answer that leads the list; Return copies it.
struct PaletteCalculation: Equatable {
    let expression: String
    let value: Double
    /// "1,234.5" for the row.
    var display: String { PaletteCalculator.format(value, grouping: true) }
    /// "1234.5" for the clipboard.
    var plain: String { PaletteCalculator.format(value, grouping: false) }
}

/// + − × ÷ ^ % and parentheses over decimals. Text must hold at least one
/// operator between two numbers, so plain numbers, versions, dates and phone
/// numbers stay searches.
enum PaletteCalculator {
    static func evaluate(_ raw: String) -> PaletteCalculation? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty, text.count <= 120, text.contains(where: \.isNumber) else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/xX×÷^%() −")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Dates and phone numbers ("2026-10-27", "555-1234") are not sums.
        if text.range(of: #"^\d+(-\d+)+$"#, options: .regularExpression) != nil { return nil }
        if text.range(of: #"^\d+(/\d+){2}$"#, options: .regularExpression) != nil { return nil }
        // Hex ("0x1F") is not 0 × 1F; and a comma only groups thousands ("1,000"), so "1,5" isn't read as 15.
        if text.range(of: #"(^|[^0-9.])0[xX]"#, options: .regularExpression) != nil { return nil }
        if text.range(of: #",(?!\d{3}(\D|$))"#, options: .regularExpression) != nil { return nil }
        var parser = Parser(text)
        guard let value = parser.parse(), parser.sawBinaryOperator, value.isFinite else { return nil }
        return PaletteCalculation(expression: text, value: value)
    }

    static func format(_ value: Double, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = abs(value) >= 1e15 ? 0 : 10
        formatter.minimumFractionDigits = 0
        if abs(value) >= 1e15 || (abs(value) < 1e-6 && value != 0) {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 8
        }
        let zero = value == 0 ? 0 : value  // no "-0"
        return formatter.string(from: NSNumber(value: zero)) ?? String(value)
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private(set) var sawBinaryOperator = false
        init(_ text: String) {
            characters = Array(text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ""))
        }
        mutating func parse() -> Double? {
            guard let value = expression(), index == characters.count else { return nil }
            return value
        }
        private var current: Character? { index < characters.count ? characters[index] : nil }
        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = current, op == "+" || op == "-" || op == "−" {
                index += 1
                guard let rhs = term() else { return nil }
                sawBinaryOperator = true
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = current, "*/xX×÷".contains(op) {
                index += 1
                guard let rhs = power() else { return nil }
                sawBinaryOperator = true
                if op == "/" || op == "÷" { guard rhs != 0 else { return nil }; value /= rhs } else { value *= rhs }
            }
            return value
        }
        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if current == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                sawBinaryOperator = true
                return pow(base, exponent)
            }
            return base
        }
        private mutating func unary() -> Double? {
            if current == "-" || current == "−" { index += 1; return unary().map { -$0 } }
            if current == "+" { index += 1; return unary() }
            guard var value = primary() else { return nil }
            while current == "%" { index += 1; value /= 100; sawBinaryOperator = true }
            return value
        }
        private mutating func primary() -> Double? {
            if current == "(" {
                index += 1
                guard let value = expression(), current == ")" else { return nil }
                index += 1
                return value
            }
            var digits = ""
            while let character = current, character.isNumber || character == "." { digits.append(character); index += 1 }
            guard digits.filter({ $0 == "." }).count <= 1 else { return nil }
            return Double(digits)
        }
    }
}

enum PaletteText {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
