import AppKit

@main enum SiteSearchTests {
    @MainActor static func main() {
        var checks = 0
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            checks += 1
        }
        require(SiteSearchCatalog.match("youtube")?.name == "YouTube", "A name prefix offers the engine")
        require(SiteSearchCatalog.match("youtube.com")?.name == "YouTube", "The full domain offers the engine")
        require(SiteSearchCatalog.match("https://www.youtube.com")?.name == "YouTube", "Scheme and www prefixes are ignored")
        require(SiteSearchCatalog.match(" YT ")?.name == "YouTube", "Aliases match after trimming, ignoring case")
        require(SiteSearchCatalog.match("wiki")?.name == "Wikipedia", "Aliases resolve Wikipedia")
        require(SiteSearchCatalog.match("youtube.com/watch?v=1") == nil, "Paths never hijack Tab")
        require(SiteSearchCatalog.match("how to cook") == nil, "Sentences never hijack Tab")
        require(SiteSearchCatalog.match("y") == nil, "A single character is too ambiguous to offer")
        require(SiteSearchCatalog.match("") == nil, "Empty text never matches")
        require(SiteSearchCatalog.match("ww") == nil && SiteSearchCatalog.match("www") == nil && SiteSearchCatalog.match("www.") == nil,
                "A bare www prefix mid-URL never offers an engine")
        require(SiteSearchCatalog.match("google")?.name == "Google", "Google outranks its sibling properties")
        require(SiteSearchCatalog.match("maps")?.name == "Google Maps", "The maps alias scopes Google Maps")
        require(SiteSearchCatalog.match("hn")?.name == "Hacker News", "The hn alias scopes Hacker News")

        let youtube = SiteSearchCatalog.match("youtube")!
        require(youtube.searchURL(for: "sam & victor seattle") == "https://www.youtube.com/results?search_query=sam%20%26%20victor%20seattle",
                "Queries are fully percent-escaped into the search template")
        require(youtube.searchURL(for: "café") == "https://www.youtube.com/results?search_query=caf%C3%A9",
                "Non-ASCII characters are percent-escaped, not passed through raw")

        let payload = #"["q",["one","two"]]"#.data(using: .utf8)
        require(SearchSuggestionFetcher.parse(data: payload) == ["one", "two"], "OpenSearch suggestion payloads parse")
        require(SearchSuggestionFetcher.parse(data: "junk".data(using: .utf8)).isEmpty, "Non-JSON yields no suggestions")
        require(SearchSuggestionFetcher.parse(data: nil).isEmpty, "Missing data yields no suggestions")

        let tab = BrowserTab(title: "cats", address: "https://example.com/cats", space: 0)
        let results = TabSearchResultsView(frame: NSRect(x: 0, y: 0, width: 540, height: 320))
        var searched: String?
        var chosen: UUID?
        results.onSearch = { searched = $0 }
        results.onSelect = { chosen = $0 }
        results.update(tabs: [tab], query: "cats", activeID: tab.id, canCreate: true,
                       engine: youtube, suggestions: ["cats compilation", "CATS"])
        require(results.activateSelection() && searched == "cats", "The scoped first row searches the typed text")
        results.moveSelection(delta: 1)
        require(results.activateSelection() && searched == "cats compilation",
                "Scoped suggestion rows search the suggestion; duplicates of the typed text are dropped")
        results.moveSelection(delta: 1)
        require(results.selectedIndex == 0 && chosen == nil, "Scoped mode has exactly two rows here and never offers tab rows")

        var submitted: String?
        results.onSubmitQuery = { submitted = $0 }
        results.update(tabs: [tab], query: "cats", activeID: tab.id, canCreate: true, suggestions: ["cats compilation"])
        require(results.activateSelection() && submitted == "cats", "Without a scope the first row still opens or searches the typed text")
        results.moveSelection(delta: -1)
        searched = nil
        require(results.activateSelection() && searched == "cats compilation",
                "Unscoped suggestion rows search through the parent, after the tab rows")
        print("PASS: \(checks) site search matching, escaping, parsing and scoped-entry checks")
    }
}
