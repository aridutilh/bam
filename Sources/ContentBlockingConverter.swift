import Foundation

/// One WebKit content-blocker rule (the JSON `WKContentRuleListStore` compiles).
struct ContentBlockerRule: Encodable, Hashable {
    struct Trigger: Encodable, Hashable {
        var urlFilter: String
        var caseSensitive: Bool? = nil
        var resourceType: [String]? = nil
        var loadType: [String]? = nil
        var loadContext: [String]? = nil
        var ifDomain: [String]? = nil
        var unlessDomain: [String]? = nil
        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter", caseSensitive = "url-filter-is-case-sensitive", resourceType = "resource-type"
            case loadType = "load-type", loadContext = "load-context", ifDomain = "if-domain", unlessDomain = "unless-domain"
        }
    }
    struct Action: Encodable, Hashable {
        var type: String
        var selector: String? = nil
    }
    var trigger: Trigger
    var action: Action

    static func block(_ trigger: Trigger) -> Self { .init(trigger: trigger, action: .init(type: "block")) }
    static func allow(_ trigger: Trigger) -> Self { .init(trigger: trigger, action: .init(type: "ignore-previous-rules")) }
    static func hide(_ selector: String, _ trigger: Trigger) -> Self { .init(trigger: trigger, action: .init(type: "css-display-none", selector: selector)) }
}

/// Translates Adblock Plus / uBlock Origin filter syntax into WebKit content-blocker rules.
///
/// WebKit can't run uBO's engine, so this keeps the common, expressible subset: network filters
/// (`||host^`, anchors, wildcards, `$third-party`, `$domain=`, resource types, `@@` exceptions,
/// `$important`, `$badfilter`) and element hiding (`##`, `domain##`, `#@#`, `$elemhide`, `$generichide`).
/// Everything else (scriptlets, procedural cosmetics, redirects, CSP, regex filters) is skipped,
/// so a rule never does something different from what its list meant.
struct ContentBlockingConverter {
    /// Converted rules, grouped by where they must sit in a rule list. WebKit's
    /// `ignore-previous-rules` only reaches rules earlier in the *same* list, so every network
    /// list ends with all network exceptions and every cosmetic list with all cosmetic ones.
    struct Output {
        var blocks: [ContentBlockerRule] = []
        /// `$document` blocks, the only filters that stop a page you go to (see `opensPages`).
        var documents: [ContentBlockerRule] = []
        var exceptions: [ContentBlockerRule] = []
        /// `$important` blocks, which exceptions must not undo: compiled after them.
        var important: [ContentBlockerRule] = []
        var importantDocuments: [ContentBlockerRule] = []
        var cosmetic: [ContentBlockerRule] = []
        var cosmeticExceptions: [ContentBlockerRule] = []
        var skipped = 0
        var ruleCount: Int { blocks.count + documents.count + exceptions.count + important.count + importantDocuments.count + cosmetic.count + cosmeticExceptions.count }
    }

    /// WebKit refuses a list over 150,000 rules; stay clear of it.
    static let maximumRulesPerList = 140_000
    /// Generic selectors share one rule per batch; WebKit skips a whole rule if one selector is
    /// invalid, so batches stay small.
    static let selectorsPerRule = 20

    // MARK: Whole lists

    /// Converts the text of one or more filter lists at once (exceptions apply across them, as in uBO).
    static func convert(_ lists: [String]) -> Output {
        var lines: [Substring] = []
        for list in lists { lines.append(contentsOf: activeLines(list)) }
        // `$badfilter` cancels the identical filter without it, in any list.
        var cancelled = Set<String>()
        for line in lines where line.contains("badfilter") {
            if let undone = withoutBadfilter(String(line)) { cancelled.insert(undone) }
        }
        var output = Output()
        var generic: [String] = []                    // generic `##selector`s, in order
        var genericSeen = Set<String>()
        var genericUnless: [String: Set<String>] = [:] // `~domain##sel`
        var specific: [String: [String]] = [:]        // selector → domains, in order
        var selectorExceptions: [String: Set<String>] = [:] // `domain#@#sel`
        var globallyAllowed = Set<String>()            // `#@#sel` with no domain
        var genericHide = Set<String>()                // `$generichide` domains
        var seenNetwork = Set<ContentBlockerRule>()

        for raw in lines {
            let line = String(raw)
            if cancelled.contains(line) || line.contains("badfilter") { continue }
            if let cosmetic = parseCosmetic(line) {
                switch cosmetic {
                case .skip: output.skipped += 1
                case let .hide(selector, positive, negative):
                    if positive.isEmpty {
                        if negative.isEmpty { if genericSeen.insert(selector).inserted { generic.append(selector) } }
                        else { genericUnless[selector, default: []].formUnion(negative) }
                    } else {
                        specific[selector, default: []].append(contentsOf: positive)
                    }
                case let .allow(selector, domains):
                    if domains.isEmpty { globallyAllowed.insert(selector) }
                    else { selectorExceptions[selector, default: []].formUnion(domains) }
                }
                continue
            }
            switch parseNetwork(line) {
            case .skip: output.skipped += 1
            case let .rules(rules, kind):
                for rule in rules where seenNetwork.insert(rule).inserted {
                    switch kind {
                    case .block: if stopsPages(rule) { output.documents.append(rule) } else { output.blocks.append(rule) }
                    case .important: if stopsPages(rule) { output.importantDocuments.append(rule) } else { output.important.append(rule) }
                    case .exception: output.exceptions.append(rule)
                    }
                }
            case let .pageException(domain, network, cosmetic, generic):
                let page = ContentBlockerRule.Trigger(urlFilter: ".*", ifDomain: ["*" + domain])
                if network { output.exceptions.append(.allow(page)) }
                if cosmetic { output.cosmeticExceptions.append(.allow(page)) }
                if generic { genericHide.insert(domain) }
            }
        }

        // Generic selectors: batched, except those some sites opt out of.
        var batch: [String] = []
        let pageOptOut = genericHide.sorted().map { "*" + $0 }
        func flush() {
            guard !batch.isEmpty else { return }
            output.cosmetic.append(.hide(batch.joined(separator: ", "),
                                         .init(urlFilter: ".*", unlessDomain: pageOptOut.isEmpty ? nil : pageOptOut)))
            batch.removeAll()
        }
        var individually: [String: Set<String>] = genericUnless
        for selector in generic where !globallyAllowed.contains(selector) {
            if let except = selectorExceptions[selector] { individually[selector, default: []].formUnion(except); continue }
            if individually[selector] != nil { continue }
            batch.append(selector)
            if batch.count == selectorsPerRule { flush() }
        }
        flush()
        for selector in individually.keys.sorted() where !globallyAllowed.contains(selector) {
            var unless = individually[selector] ?? []
            unless.formUnion(selectorExceptions[selector] ?? [])
            unless.formUnion(genericHide)
            output.cosmetic.append(.hide(selector, .init(urlFilter: ".*", unlessDomain: unless.sorted().map { "*" + $0 })))
        }
        // Site-specific selectors, minus sites that opted out of that selector.
        for selector in specific.keys.sorted() where !globallyAllowed.contains(selector) {
            let except = selectorExceptions[selector] ?? []
            var seen = Set<String>()
            let domains = (specific[selector] ?? []).filter { !except.contains($0) && seen.insert($0).inserted }
            guard !domains.isEmpty else { continue }
            output.cosmetic.append(.hide(selector, .init(urlFilter: ".*", ifDomain: domains.map { "*" + $0 })))
        }
        return output
    }

    /// Placed after the ordinary blocks: a page you go to (top frame) always opens, even on a host a
    /// whole-host filter like `||googleadservices.com^` blocks, so ad and affiliate links still work.
    /// That host's scripts, images, frames and popups stay blocked. Only `$document` filters, which
    /// come after this, stop the page itself (malware and scam lists use them for exactly that).
    static let opensPages = ContentBlockerRule.allow(.init(urlFilter: ".*", resourceType: ["document"], loadContext: ["top-frame"]))

    /// A block that applies to the page itself, not only to what it loads.
    static func stopsPages(_ rule: ContentBlockerRule) -> Bool {
        rule.action.type == "block" && rule.trigger.loadContext == nil && rule.trigger.resourceType?.contains("document") == true
    }

    /// The rule lists to compile, each a JSON array under WebKit's per-list limit.
    static func encodedLists(_ output: Output, maximum: Int = maximumRulesPerList) -> [String] {
        var lists: [[ContentBlockerRule]] = []
        func chunk(_ rules: [ContentBlockerRule], tail: [ContentBlockerRule]) {
            guard !rules.isEmpty else { return }
            let room = max(1, maximum - tail.count)
            var start = 0
            while start < rules.count {
                let end = min(rules.count, start + room)
                lists.append(Array(rules[start..<end]) + tail)
                start = end
            }
        }
        func network(_ rules: [ContentBlockerRule], pages: [ContentBlockerRule], exceptions: [ContentBlockerRule]) {
            if rules.isEmpty { chunk(pages, tail: exceptions) } else { chunk(rules, tail: [opensPages] + pages + exceptions) }
        }
        network(output.blocks, pages: output.documents, exceptions: output.exceptions)
        network(output.important, pages: output.importantDocuments, exceptions: [])
        chunk(output.cosmetic, tail: output.cosmeticExceptions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return lists.compactMap { (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
    }

    // MARK: Preprocessing

    /// Lines that apply to WebKit: comments dropped, `!#if` blocks evaluated for Safari.
    static func activeLines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var stack: [Bool] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") { stack.append(evaluate(String(line.dropFirst(5)))); continue }
            if line.hasPrefix("!#else") { if let last = stack.popLast() { stack.append(!last) }; continue }
            if line.hasPrefix("!#endif") { _ = stack.popLast(); continue }
            if stack.contains(false) { continue }
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            result.append(Substring(line))
        }
        return result
    }

    /// uBO preprocessor conditions as seen from a WebKit browser.
    static func evaluate(_ condition: String) -> Bool {
        let truthy: Set<String> = ["env_safari", "env_mv3", "ext_ublock"]
        return condition.components(separatedBy: "||").contains { clause in
            clause.components(separatedBy: "&&").allSatisfy { term in
                var token = term.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "()")))
                var negate = false
                while token.hasPrefix("!") { negate.toggle(); token.removeFirst() }
                return truthy.contains(token) != negate
            }
        }
    }

    static func withoutBadfilter(_ line: String) -> String? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
        guard options.count < line[line.index(after: dollar)...].split(separator: ",").count else { return nil }
        let pattern = String(line[..<dollar])
        return options.isEmpty ? pattern : pattern + "$" + options.joined(separator: ",")
    }

    // MARK: Element hiding

    enum Cosmetic: Equatable {
        case hide(selector: String, positive: [String], negative: [String])
        case allow(selector: String, domains: [String])
        case skip
    }

    private static let cosmeticSeparators = ["#@?#", "#@$#", "#@%#", "#?#", "#$#", "#%#", "#@#", "##"]
    /// Procedural or uBO-only syntax a stylesheet can't express.
    private static let proceduralMarkers = [":has-text(", ":-abp-", ":contains(", ":upward(", ":xpath(", ":style(", ":remove(",
                                            ":matches-css", ":matches-path(", ":matches-attr(", ":matches-prop(", ":min-text-length(",
                                            ":watch-attr(", ":nth-ancestor(", ":spath(", ":others(", ":if(", ":if-not(",
                                            ":remove-attr(", ":remove-class(", ":matches-media(", ":shadow(", ":properties("]

    /// nil when the line isn't an element-hiding filter at all.
    static func parseCosmetic(_ line: String) -> Cosmetic? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let tail = line[hash...]
        guard let separator = cosmeticSeparators.first(where: { tail.hasPrefix($0) }) else { return nil }
        let prefix = String(line[..<hash])
        // A '/' or '$' before the '#' means a network filter whose URL contains '#'.
        if prefix.contains("/") || prefix.contains("$") || prefix.contains("|") { return nil }
        guard separator == "##" || separator == "#@#" else { return .skip }
        let selector = String(tail.dropFirst(separator.count)).trimmingCharacters(in: .whitespaces)
        guard isUsableSelector(selector) else { return .skip }
        var positive: [String] = [], negative: [String] = []
        var droppedPositive = false
        for item in prefix.split(separator: ",") {
            var name = item.trimmingCharacters(in: .whitespaces)
            let negated = name.hasPrefix("~")
            if negated { name.removeFirst() }
            guard let domain = normalizedDomain(name) else { if !negated { droppedPositive = true }; continue }
            if negated { negative.append(domain) } else { positive.append(domain) }
        }
        // Every site it named was unusable (e.g. `google.*`): skip rather than hide everywhere.
        if droppedPositive && positive.isEmpty { return .skip }
        if separator == "#@#" { return .allow(selector: selector, domains: positive) }
        return .hide(selector: selector, positive: positive, negative: positive.isEmpty ? negative : [])
    }

    static func isUsableSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 1_000, selector.allSatisfy({ $0.isASCII }) else { return false }
        if selector.hasPrefix("+js(") || selector.hasPrefix("^") || selector.hasPrefix("//") { return false }
        if selector.contains("{") || selector.contains("}") { return false }
        if proceduralMarkers.contains(where: { selector.contains($0) }) { return false }
        // Balanced brackets and quotes, or WebKit rejects the whole rule.
        var depth = (paren: 0, square: 0), quote: Character?
        for c in selector {
            if let q = quote { if c == q { quote = nil }; continue }
            switch c {
            case "\"", "'": quote = c
            case "(": depth.paren += 1
            case ")": depth.paren -= 1
            case "[": depth.square += 1
            case "]": depth.square -= 1
            default: break
            }
            if depth.paren < 0 || depth.square < 0 { return false }
        }
        return quote == nil && depth.paren == 0 && depth.square == 0
    }

    /// A lowercase ASCII host WebKit's `if-domain` accepts, or nil (entities, regexes, IDNs, IPs with ports).
    static func normalizedDomain(_ raw: String) -> String? {
        let name = raw.lowercased()
        guard !name.isEmpty, name.count < 254, !name.hasPrefix("."), !name.hasSuffix("."), !name.hasSuffix(".*"),
              name.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return name
    }

    // MARK: Network filters

    enum Kind { case block, important, exception }
    enum Network: Equatable {
        case rules([ContentBlockerRule], Kind)
        /// `@@||host^$document` / `$elemhide` / `$generichide`: a whole page opts out.
        case pageException(domain: String, network: Bool, cosmetic: Bool, generic: Bool)
        case skip
    }

    /// Options WebKit can't honor; a filter using any of them is left out.
    private static let unsupportedOptions: Set<String> = [
        "redirect", "redirect-rule", "rewrite", "csp", "removeparam", "queryprune", "header", "permissions", "replace", "urlskip",
        "uritransform", "urltransform", "empty", "mp4", "inline-script", "inline-font", "cname", "genericblock", "webrtc",
        "object", "object-subrequest", "to", "denyallow", "method", "popunder", "specifichide", "shide", "reason", "ipaddress",
        "_", "1p-strict", "3p-strict"
    ]
    private static let allTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]

    static func parseNetwork(_ line: String) -> Network {
        var text = Substring(line)
        let isException = text.hasPrefix("@@")
        if isException { text = text.dropFirst(2) }
        var pattern = text, optionText: Substring = ""
        // Options follow the last '$' unless that '$' belongs to a regex filter.
        if let dollar = text.lastIndex(of: "$"), !(text.hasPrefix("/") && text[text.index(after: dollar)...].contains("/")) {
            pattern = text[..<dollar]; optionText = text[text.index(after: dollar)...]
        }
        var trigger = ContentBlockerRule.Trigger(urlFilter: "")
        var types: [String] = [], negatedTypes = Set<String>(), frames = false
        var important = false, page = (document: false, elemhide: false, generic: false)
        var positive: [String] = [], negative: [String] = []

        for option in optionText.split(separator: ",") {
            var name = option.lowercased(), value: String?
            if let equals = name.firstIndex(of: "=") { value = String(name[name.index(after: equals)...]); name = String(name[..<equals]) }
            let negated = name.hasPrefix("~")
            if negated { name.removeFirst() }
            if unsupportedOptions.contains(name) { return .skip }
            switch name {
            case "third-party", "3p", "strict3p": trigger.loadType = [negated ? "first-party" : "third-party"]
            case "first-party", "1p", "strict1p": trigger.loadType = [negated ? "third-party" : "first-party"]
            case "match-case": trigger.caseSensitive = true
            case "important": important = true
            case "domain", "from":
                var droppedPositive = false
                for item in (value ?? "").split(separator: "|") {
                    var host = String(item); let not = host.hasPrefix("~"); if not { host.removeFirst() }
                    guard let domain = normalizedDomain(host) else { if !not { droppedPositive = true }; continue }
                    if not { negative.append(domain) } else { positive.append(domain) }
                }
                if droppedPositive && positive.isEmpty { return .skip }
            case "document", "doc":
                if isException { page.document = true } else if negated { negatedTypes.insert("document") } else { types.append("document") }
            case "elemhide", "ehide": if isException { page.elemhide = true } else { return .skip }
            case "generichide", "ghide": if isException { page.generic = true } else { return .skip }
            case "all": types.append(contentsOf: allTypes + ["popup"]); frames = true
            case "popup": if negated { return .skip } else { types.append("popup") }
            case "subdocument", "frame": if negated { negatedTypes.insert("frame") } else { frames = true }
            default:
                guard let mapped = resourceType(name) else { return .skip }
                if negated { negatedTypes.insert(mapped) } else { types.append(mapped) }
            }
        }
        if !negatedTypes.isEmpty {
            guard types.isEmpty, !frames else { return .skip }
            types = allTypes.filter { !negatedTypes.contains($0) }
            frames = !negatedTypes.contains("frame")
        }
        // A whole page opting out of blocking or hiding.
        if page.document || page.elemhide || page.generic {
            guard let host = anchoredHost(String(pattern)) else { return .skip }
            return .pageException(domain: host, network: page.document, cosmetic: page.document || page.elemhide, generic: page.generic)
        }
        guard let filter = urlFilter(String(pattern)) else { return .skip }
        trigger.urlFilter = filter
        // WebKit can't both include and exclude sites in one rule.
        if !positive.isEmpty { trigger.ifDomain = positive.map { "*" + $0 } }
        else if !negative.isEmpty { trigger.unlessDomain = negative.map { "*" + $0 } }
        // Never block everything everywhere.
        if !isException && filter == ".*" && trigger.ifDomain == nil && types.isEmpty && !frames { return .skip }

        var rules: [ContentBlockerRule] = []
        func add(_ t: ContentBlockerRule.Trigger) { rules.append(isException ? .allow(t) : .block(t)) }
        var unique: [String] = []
        for type in types where !unique.contains(type) { unique.append(type) }
        if !unique.isEmpty { var t = trigger; t.resourceType = unique; add(t) }
        if frames { var t = trigger; t.resourceType = ["document"]; t.loadContext = ["child-frame"]; add(t) }
        if unique.isEmpty && !frames {
            // No type named. A whole-host filter (`||ads.example^`) covers everything from that host, frames
            // included (a page you go to directly still opens: see `opensPages`); any other pattern only
            // covers what pages load.
            if isException || anchoredHost(String(pattern)) != nil { add(trigger) }
            else { var t = trigger; t.resourceType = allTypes; add(t) }
        }
        return .rules(rules, isException ? .exception : important ? .important : .block)
    }

    static func resourceType(_ option: String) -> String? {
        switch option {
        case "script": return "script"
        case "image": return "image"
        case "stylesheet", "css": return "style-sheet"
        case "xmlhttprequest", "xhr", "websocket", "other": return "raw"
        case "media": return "media"
        case "font": return "font"
        case "ping", "beacon": return "ping"
        default: return nil
        }
    }

    /// `||host^` or `||host` (a whole site), as used by page-level exceptions.
    static func anchoredHost(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = String(pattern.dropFirst(2))
        if host.hasSuffix("^") { host.removeLast() }
        if host.hasSuffix("/") { host.removeLast() }
        return normalizedDomain(host)
    }

    /// The pattern as a WebKit `url-filter` (its small regex dialect), or nil when it can't be expressed.
    static func urlFilter(_ pattern: String) -> String? {
        var p = Substring(pattern)
        if p.count > 2, p.hasPrefix("/"), p.hasSuffix("/") { return nil } // regex filters
        guard p.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        var out = ""
        if p.hasPrefix("||") {
            out = "^[^:]+://+([^:/]+\\.)?"; p = p.dropFirst(2)
            guard let first = p.first, first.isLetter || first.isNumber else { return nil }
        } else if p.hasPrefix("|") {
            out = "^"; p = p.dropFirst()
        }
        var endAnchor = false
        if p.hasSuffix("|") { endAnchor = true; p = p.dropLast() }
        // Leading and trailing wildcards add nothing to a search.
        while p.hasPrefix("*") { p = p.dropFirst(); if out == "^" { out = "" } }
        while p.hasSuffix("*") && !endAnchor { p = p.dropLast() }
        for c in p {
            switch c {
            case "*": out += ".*"
            case "^": out += "[/:?=&]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(c)
            default: out.append(c)
            }
        }
        if endAnchor { out += "$" }
        if out.isEmpty { return ".*" }
        // A bare scheme-only anchor matches every URL.
        if out == "^" { return ".*" }
        // Filters this short match too much to be worth the risk.
        if !pattern.hasPrefix("|") && p.count < 3 && !p.isEmpty { return nil }
        return out
    }
}
