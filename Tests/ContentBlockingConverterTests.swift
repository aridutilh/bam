import Foundation
import WebKit

/// Ad-blocker filter translation (ABP/uBO syntax → WebKit content rules), the per-site switch,
/// the "Page not working?" heuristic, and that WebKit accepts what the converter emits.
@main struct ContentBlockingConverterTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func main() {
        do {
            try run()
            compileCheck()
        } catch { print("FAIL: Content blocking — \(error)"); exit(1) }
    }

    typealias T = ContentBlockerRule.Trigger
    static func rules(_ line: String) -> [ContentBlockerRule] {
        if case let .rules(rules, _) = ContentBlockingConverter.parseNetwork(line) { return rules }
        return []
    }
    static func kind(_ line: String) -> ContentBlockingConverter.Kind? {
        if case let .rules(_, kind) = ContentBlockingConverter.parseNetwork(line) { return kind }
        return nil
    }
    static let host = "^[^:]+://+([^:/]+\\.)?"
    static let allTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]

    static func run() throws {
        // Host anchors and separators.
        try check(ContentBlockingConverter.urlFilter("||ads.example.com^") == host + "ads\\.example\\.com[/:?=&]", "||host^ was mistranslated")
        try check(ContentBlockingConverter.urlFilter("|https://x.com/a*b|") == "^https://x\\.com/a.*b$", "| anchors or * were mistranslated")
        try check(ContentBlockingConverter.urlFilter("/banner/*/img^") == "/banner/.*/img[/:?=&]", "A path filter was mistranslated")
        try check(ContentBlockingConverter.urlFilter("*ads*") == "ads", "Leading/trailing wildcards were kept")
        try check(ContentBlockingConverter.urlFilter("/ad[0-9]+\\.js/") == nil, "A regex filter was accepted")
        try check(ContentBlockingConverter.urlFilter("ad") == nil, "A two-letter filter that matches everything was accepted")
        try check(ContentBlockingConverter.urlFilter("||exämple.com^") == nil, "A non-ASCII filter was accepted")

        // A whole-host filter blocks everything from that host, pages included (uBO's strict blocking).
        let whole = rules("||tracker.example^")
        try check(whole.count == 1 && whole[0].action.type == "block" && whole[0].trigger.resourceType == nil, "||host^ didn't block all of the host")
        // Any other untyped pattern never blocks a page you open, only what pages load.
        let path = rules("/ads/banner.")
        try check(path.count == 1 && path[0].trigger.resourceType == allTypes, "An untyped path filter could block top-level pages")

        // Options.
        let third = rules("||cdn.example^$third-party,script")
        try check(third.count == 1 && third[0].trigger.loadType == ["third-party"] && third[0].trigger.resourceType == ["script"], "$third-party,script lost")
        try check(rules("||a.example^$~third-party,image")[0].trigger.loadType == ["first-party"], "$~third-party wasn't first-party")
        try check(rules("||a.example^$1p")[0].trigger.loadType == ["first-party"], "$1p alias wasn't first-party")
        let types = rules("||a.example^$stylesheet,xmlhttprequest,media,font,popup,ping")
        try check(types.first?.trigger.resourceType == ["style-sheet", "raw", "media", "font", "popup", "ping"], "Resource types were mapped wrong: \(types)")
        let frame = rules("||frames.example^$subdocument")
        try check(frame.count == 1 && frame[0].trigger.resourceType == ["document"] && frame[0].trigger.loadContext == ["child-frame"],
                  "$subdocument didn't become a child-frame document rule")
        let mixed = rules("||m.example^$script,subdocument")
        try check(mixed.count == 2 && mixed[0].trigger.resourceType == ["script"] && mixed[1].trigger.loadContext == ["child-frame"],
                  "$script,subdocument didn't split into two rules")
        let negatedTypes = rules("||n.example^$~image,~script")
        try check(negatedTypes.first?.trigger.resourceType == allTypes.filter { $0 != "image" && $0 != "script" } && negatedTypes.count == 2,
                  "Negated types weren't the complement")
        let domains = rules("/ad.js$domain=news.example|blog.example")
        try check(domains[0].trigger.ifDomain == ["*news.example", "*blog.example"] && domains[0].trigger.unlessDomain == nil, "$domain= wasn't if-domain")
        try check(rules("/ad.js$domain=~shop.example")[0].trigger.unlessDomain == ["*shop.example"], "$domain=~ wasn't unless-domain")
        try check(rules("/ad.js$domain=google.*").isEmpty, "An entity-only $domain= was kept (would block everywhere)")
        try check(rules("/Ads.JS$match-case")[0].trigger.caseSensitive == true, "$match-case was dropped")
        try check(kind("||imp.example^$important") == .important, "$important wasn't kept after exceptions")

        // Unsupported options skip the filter instead of changing what it does.
        for line in ["||x.example^$redirect=noop.js", "||x.example^$csp=script-src 'none'", "||x.example^$removeparam=utm",
                     "||x.example^$to=y.example", "||x.example^$object", "||x.example^$elemhide"] {
            try check(rules(line).isEmpty, "\(line) should be skipped")
        }
        try check(rules("*").isEmpty && rules("|").isEmpty, "A filter blocking every URL everywhere was accepted")

        // Exceptions.
        let allow = rules("@@||good.example/ads.js")
        try check(allow.count == 1 && allow[0].action.type == "ignore-previous-rules" && kind("@@||good.example/ads.js") == .exception,
                  "@@ wasn't ignore-previous-rules")
        try check(ContentBlockingConverter.parseNetwork("@@||site.example^$document")
                  == .pageException(domain: "site.example", network: true, cosmetic: true, generic: false), "@@$document wasn't a page exception")
        try check(ContentBlockingConverter.parseNetwork("@@||site.example^$generichide")
                  == .pageException(domain: "site.example", network: false, cosmetic: false, generic: true), "$generichide wasn't generic-only")

        // Element hiding.
        try check(ContentBlockingConverter.parseCosmetic("##.ad-banner") == .hide(selector: ".ad-banner", positive: [], negative: []), "Generic ## lost")
        try check(ContentBlockingConverter.parseCosmetic("news.example,~m.news.example##.promo")
                  == .hide(selector: ".promo", positive: ["news.example"], negative: []), "domain## lost")
        try check(ContentBlockingConverter.parseCosmetic("example.com#@#.ad") == .allow(selector: ".ad", domains: ["example.com"]), "#@# lost")
        for line in ["example.com##+js(set, a, 1)", "example.com#?#div:has-text(Ad)", "##div:style(color: red)", "example.com#$#body { x }",
                     "example.com##^script", "google.*##.ad", "##.a:upward(2)"] {
            try check(ContentBlockingConverter.parseCosmetic(line) == .skip, "\(line) should be skipped")
        }
        try check(ContentBlockingConverter.parseCosmetic("||x.example/#ad") == nil, "A network filter with # was read as cosmetic")
        try check(ContentBlockingConverter.parseCosmetic("##div[class=\"ad\"") == .skip, "An unbalanced selector was accepted")
        try check(ContentBlockingConverter.parseCosmetic("##.x:has(> .ad)") == .hide(selector: ".x:has(> .ad)", positive: [], negative: []),
                  "Standard :has() was rejected")

        // Whole lists: batching, exceptions, badfilter, preprocessor.
        let list = """
        [Adblock Plus 2.0]
        ! comment
        ||ads.example^
        ||ads.example^$badfilter
        ||track.example^$third-party
        @@||track.example/ok.js
        ##.ad
        ##.sponsor
        ##.allowed
        #@#.allowed
        example.com#@#.sponsor
        ~shop.example##.promo
        site.example##.banner
        @@||quiet.example^$generichide
        !#if env_firefox
        ||firefox-only.example^
        !#endif
        !#if !env_firefox
        ||not-firefox.example^
        !#endif
        """
        let output = ContentBlockingConverter.convert([list])
        let filters = output.blocks.map(\.trigger.urlFilter)
        try check(!filters.contains { $0.contains("ads\\.example") }, "$badfilter didn't cancel its filter")
        try check(filters.contains { $0.contains("not-firefox") } && !filters.contains { $0.contains("firefox-only") }, "!#if wasn't evaluated for Safari")
        try check(output.exceptions.count == 1, "The exception wasn't kept")
        let generic = output.cosmetic.first { $0.action.selector == ".ad" }
        try check(generic?.trigger.unlessDomain == ["*quiet.example"], "$generichide sites weren't excluded from generic hiding: \(output.cosmetic)")
        try check(!output.cosmetic.contains { $0.action.selector?.contains(".allowed") == true }, "#@# with no site didn't drop the selector")
        try check(output.cosmetic.contains { $0.action.selector == ".sponsor" && $0.trigger.unlessDomain?.contains("*example.com") == true },
                  "A site's #@# didn't exclude it from the generic selector")
        try check(output.cosmetic.contains { $0.action.selector == ".promo" && $0.trigger.unlessDomain?.contains("*shop.example") == true }, "~site## lost")
        try check(output.cosmetic.contains { $0.action.selector == ".banner" && $0.trigger.ifDomain == ["*site.example"] }, "site## lost")

        // Lists are split under WebKit's limit, each ending with every exception.
        var big = ContentBlockingConverter.Output()
        big.blocks = (0..<25).map { .block(T(urlFilter: "b\($0)")) }
        big.exceptions = [.allow(T(urlFilter: "ok"))]
        big.important = [.block(T(urlFilter: "imp"))]
        big.cosmetic = [.hide(".x", T(urlFilter: ".*"))]
        let encoded = ContentBlockingConverter.encodedLists(big, maximum: 10)
        try check(encoded.count == 5, "Wrong number of lists: \(encoded.count)")
        let decoded = encoded.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [[String: Any]] ?? [] }
        try check(decoded.prefix(3).allSatisfy { $0.count <= 10 && ($0.last?["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" },
                  "A network list was over the limit or missed the exceptions")
        try check(encoded[0].contains("\"url-filter\":\"b0\"") && encoded[3].contains("imp") && !encoded[3].contains("\"ok\""),
                  "Important rules weren't kept apart from exceptions")

        // Per-site switch and site keys.
        try check(ContentBlockingPreference.site(URL(string: "https://www.Example.com/a")) == "example.com", "www. wasn't dropped from the site")
        try check(ContentBlockingPreference.site(URL(string: "file:///tmp/a.html")) == nil, "A file page got a site")
        try check(ContentBlockingPreference.isAllowed("news.example.com", in: ["example.com"]), "Allowing a domain didn't cover its subdomains")
        try check(!ContentBlockingPreference.isAllowed("example.com", in: ["news.example.com"]), "Allowing a subdomain covered its parent")
        try check(!ContentBlockingPreference.isAllowed("evil.com", in: ["com"]), "A bare TLD matched")
        ContentBlockingPreference.defaults = nil // in memory: never touch any real preferences
        let page = URL(string: "https://www.news.example/story")
        try check(ContentBlockingPreference.blocks(page), "Blocking wasn't on by default")
        ContentBlockingPreference.setBlocks(false, for: page)
        try check(!ContentBlockingPreference.blocks(URL(string: "https://news.example/other")), "Allowing ads on a site didn't stick")
        ContentBlockingPreference.setBlocks(true, for: page)
        try check(ContentBlockingPreference.blocks(page) && ContentBlockingPreference.allowedSites.isEmpty, "Blocking again didn't clear the site")
        ContentBlockingPreference.isEnabled = false
        try check(!ContentBlockingPreference.blocks(page), "The global switch didn't turn blocking off")
        ContentBlockingPreference.isEnabled = true

        // Settings summary.
        var status = ContentBlockingPreference.Status(ruleCount: 118_302, listCount: 7, updated: Date(timeIntervalSince1970: 0), builtInOnly: false)
        let now = Date(timeIntervalSince1970: 2 * 86_400 + 60)
        try check(ContentBlockingPreference.summary(status, enabled: true, now: now).hasSuffix("rules from 7 lists · updated 2 days ago"), "Summary was wrong")
        try check(ContentBlockingPreference.summary(status, enabled: false, now: now).hasPrefix("Off"), "Off summary was wrong")
        status.builtInOnly = true
        try check(ContentBlockingPreference.summary(status, enabled: true, now: now).contains("built-in list"), "Seed summary was wrong")

        // "Page not working?": three reloads of the same page within 20 seconds, once.
        var detector = ContentBlockingBreakageDetector()
        let story = URL(string: "https://news.example/story#top")!, same = URL(string: "https://news.example/story")!
        try check(!detector.pageStarted(story, at: 0), "The first load tripped")
        try check(!detector.pageStarted(same, at: 5) && !detector.pageStarted(story, at: 10), "Two reloads tripped")
        try check(detector.pageStarted(same, at: 15), "Three reloads in 20s didn't trip")
        try check(!detector.pageStarted(same, at: 16), "It tripped again right away")
        var slow = ContentBlockingBreakageDetector()
        _ = slow.pageStarted(same, at: 0); _ = slow.pageStarted(same, at: 1); _ = slow.pageStarted(same, at: 15)
        try check(!slow.pageStarted(same, at: 30), "Reloads spread over more than 20s tripped")
        var moving = ContentBlockingBreakageDetector()
        _ = moving.pageStarted(same, at: 0); _ = moving.pageStarted(same, at: 1); _ = moving.pageStarted(same, at: 2)
        try check(!moving.pageStarted(URL(string: "https://news.example/next"), at: 3), "A different page counted as a reload")
    }

    /// WebKit must accept every construct the converter emits (its regex dialect is a small subset).
    static func compileCheck() {
        let sample = """
        ||ads.example^
        ||cdn.example^$third-party,script,image
        |https://x.example/a*b|
        /banner/*/img^
        ||frames.example^$subdocument
        /ad.js$domain=news.example|~m.news.example
        ||pop.example^$popup
        ||ping.example^$ping
        ||n.example^$~image
        @@||good.example/ads.js
        @@||site.example^$document
        ||imp.example^$important
        ##.ad
        ##.x:has(> .ad)
        site.example##.banner
        ~shop.example##.promo
        """
        let lists = ContentBlockingConverter.encodedLists(ContentBlockingConverter.convert([sample]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bam-content-rules-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: directory) else { print("FAIL: Content blocking — no rule list store"); exit(1) }
        func next(_ index: Int) {
            guard index < lists.count else {
                try? FileManager.default.removeItem(at: directory)
                print("PASS: \(checks + lists.count) content blocking checks")
                exit(0)
            }
            store.compileContentRuleList(forIdentifier: "test-\(index)", encodedContentRuleList: lists[index]) { list, error in
                guard list != nil else { print("FAIL: Content blocking — WebKit rejected list \(index): \(error.map { "\($0)" } ?? "")"); exit(1) }
                next(index + 1)
            }
        }
        next(0)
        RunLoop.main.run()
    }
}
