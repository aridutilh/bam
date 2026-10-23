import AppKit

@main enum TabSearchTests {
    @MainActor static func main() {
        var checks = 0
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            checks += 1
        }
        let url = BrowserTab(title: "Project hub", address: "https://example.com/arc", space: 2)
        let substring = BrowserTab(title: "My Arc notes", address: "https://example.com/notes", space: 1)
        let prefix = BrowserTab(title: "Arc handbook", address: "https://example.com/guide", space: 0)
        let exact = BrowserTab(title: "ARC", address: "https://example.com", space: 1)
        let tabs = [url, substring, prefix, exact]
        require(TabSearchMatcher.matches(tabs: tabs, query: " arc ", activeID: url.id).map(\.id) == [exact.id, prefix.id, substring.id, url.id], "Title rank must outrank an active URL match across Spaces")
        require(TabSearchMatcher.matches(tabs: tabs, query: "", activeID: prefix.id).first?.id == prefix.id, "Empty query should put current tab first")
        require(TabSearchMatcher.matches(tabs: tabs, query: "example notes", activeID: url.id).map(\.id) == [substring.id], "Multiple query terms can match across title and URL")
        let unicode = BrowserTab(title: "Café design", address: "https://example.org/a%20b", space: 0)
        require(TabSearchMatcher.matches(tabs: [unicode], query: "CAFE", activeID: UUID()).first?.id == unicode.id, "Matching ignores case and diacritics")
        require(TabSearchMatcher.matches(tabs: [unicode], query: "a b", activeID: UUID()).count == 1, "Percent-encoded URL terms can be found")
        let many = (0..<10).map { BrowserTab(title: "Tab \($0)", address: "https://example.org/\($0)", space: $0 % 3) }
        require(TabSearchMatcher.matches(tabs: many, query: "tab", activeID: UUID()).count == 6, "At most six existing tabs")
        require(TabSearchMatcher.matches(tabs: many, query: "", activeID: UUID(), limit: 0).isEmpty, "Zero limit is valid")
        require(TabSearchMatcher.matches(tabs: tabs, query: "absent", activeID: url.id).isEmpty, "Unmatched query has no fake tab results")
        let results = TabSearchResultsView(frame: NSRect(x: 0, y: 0, width: 540, height: 320))
        var chosen: UUID?
        var submitted: String?
        results.onSelect = { chosen = $0 }
        results.onSubmitQuery = { submitted = $0 }
        results.update(tabs: tabs, query: "arc", activeID: url.id, canCreate: true)
        require(results.activateSelection() && submitted == "arc", "Initial nonempty query row submits typed query")
        results.moveSelection(delta: 1)
        require(results.activateSelection() && chosen == exact.id, "Down selects best existing tab")
        results.update(tabs: tabs, query: "arc", activeID: url.id, canCreate: true)
        require(results.selectedIndex == 1, "Metadata refresh preserves selected result")
        results.moveSelection(delta: -2)
        require(results.activateSelection() && chosen == url.id, "Up wraps through all results")
        results.update(tabs: tabs, query: "arc", activeID: url.id, canCreate: false)
        require(results.activateSelection() && chosen == url.id, "Removing query row keeps selected tab identity")
        results.update(tabs: [], query: "missing", activeID: url.id, canCreate: false)
        require(!results.activateSelection() && results.preferredHeight == 44, "Empty list remains safely inert")
        results.moveSelection(delta: Int.min)
        require(results.selectedIndex == 0, "Arrow handling on empty list is safe")
        print("PASS: \(checks) tab search ranking and selection checks")
    }
}
