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
        // Read the actual native labels, not a parallel naming helper.
        func labels(in view: NSView) -> [String] {
            view.subviews.flatMap { child -> [String] in
                let own = (child as? NSTextField).map { [$0.stringValue] } ?? []
                return own + labels(in: child)
            }
        }
        let research = BrowserTab(title: "Research tab", address: "https://example.com/research", space: 41)
        let personal = BrowserTab(title: "Personal tab", address: "https://example.com/personal", space: 7)
        let customSpaces = [BrowserSpace(id: 7, name: "Personal", symbol: "sun.max", colorIndex: 1),
                            BrowserSpace(id: 41, name: "Research", symbol: "book", colorIndex: 2)]
        results.update(tabs: [research, personal], query: "tab", activeID: research.id, canCreate: false, spaces: customSpaces)
        require(labels(in: results).contains("Research · Current") && labels(in: results).contains("Personal"),
                "Search labels must resolve non-contiguous stable Space IDs")
        results.moveSelection(delta: 1)
        let renamedSpaces = [BrowserSpace(id: 41, name: "Lab", symbol: "book", colorIndex: 2), customSpaces[0]]
        results.update(tabs: [research, personal], query: "tab", activeID: research.id, canCreate: false, spaces: renamedSpaces)
        require(labels(in: results).contains("Lab · Current") && !labels(in: results).contains("Research · Current"),
                "Rename/reorder refresh must show the current Space name")
        require(results.activateSelection() && chosen == personal.id,
                "Renaming or reordering Spaces must retain the selected tab identity")
        results.update(tabs: [research], query: "", activeID: research.id, canCreate: false, spaces: [])
        require(labels(in: results).contains("Unknown Space · Current"),
                "An absent Space definition must not label a tab with another Space's name")
        results.update(tabs: [prefix], query: "", activeID: prefix.id, canCreate: false)
        require(labels(in: results).contains("Studio · Current"), "Legacy callers retain default Space names")
        let kept = BrowserTab(title: "Unrelated live title", address: "https://example.com/current", space: 41,
                              saved: SavedTabState(kind: .kept, address: "https://saved.example/original", customTitle: "Project Atlas", customSymbol: "book"))
        let favorite = BrowserTab(title: "Old favorite title", address: "https://favorite.example/home", space: 7,
                                  saved: SavedTabState(kind: .favorite, address: "https://favorite.example/home", customTitle: "Global Inbox", customSymbol: "heart", isUnloaded: true))
        let ordinaryMatch = BrowserTab(title: "Notes about Project Atlas", address: "https://example.com/notes", space: 7)
        require(TabSearchMatcher.matches(tabs: [ordinaryMatch, kept], query: "Project Atlas", activeID: ordinaryMatch.id).first?.id == kept.id,
                "A custom saved title must rank as an exact title, not the live document title")
        require(TabSearchMatcher.matches(tabs: [kept], query: "saved.example", activeID: UUID()).map(\.id) == [kept.id],
                "A navigated kept tab remains searchable by its saved destination")
        require(TabSearchMatcher.matches(tabs: [kept], query: "example.com/current", activeID: UUID()).map(\.id) == [kept.id],
                "A saved destination must not hide the current navigation from search")
        require(TabSearchMatcher.matches(tabs: [favorite], query: "global inbox", activeID: UUID()).map(\.id) == [favorite.id],
                "Sleeping Favorites remain searchable with their original identity")
        results.update(tabs: [kept, favorite], query: "", activeID: kept.id, canCreate: false, spaces: renamedSpaces)
        require(labels(in: results).contains("Project Atlas") && labels(in: results).contains("Lab · Current"),
                "A kept result uses its custom title and current Space name")
        require(labels(in: results).filter { $0 == "Favorite · Default" }.count == 1
                    && labels(in: results).contains("Global Inbox")
                    && labels(in: results).contains("Sleeping · https://favorite.example/home"),
                "A sleeping Favorite must show one result with its login profile and state")
        results.moveSelection(delta: 1)
        require(results.activateSelection() && chosen == favorite.id,
                "Opening a sleeping search result passes the existing saved-tab identity to the controller")
        // Browser commands: typed names lead, loose matches trail the tabs.
        let settingsHit = PaletteCommandCatalog.matches("setting")
        require(settingsHit.first?.command.id == "settings" && settingsHit.first?.leading == true, "A typed command name leads")
        require(PaletteCommandCatalog.matches("preferences").first?.command.id == "settings", "Keywords find Settings")
        require(PaletteCommandCatalog.matches("se").first?.leading == false, "Two characters never lead, so Return still searches")
        require(PaletteCommandCatalog.matches("spaces").first?.command.id == "manage-spaces", "A keyword names Manage Spaces outright")
        let page = PaletteCommandCatalog.matches("page")
        require(page.map(\.command.id).contains("find") && page.count == 3 && page.allSatisfy { !$0.leading }, "A later title word matches but trails the tabs")
        require(PaletteCommandCatalog.matches("bam about").first?.command.id == "about", "Every token can start a different word")
        require(PaletteCommandCatalog.matches("zzz").isEmpty && PaletteCommandCatalog.matches("s").isEmpty, "No fake command hits")
        require(PaletteCommandCatalog.matches("s", limit: 0).isEmpty && PaletteCommandCatalog.matches("settings", limit: 1).count == 1, "Limit applies")
        let settingsTab = BrowserTab(title: "Settings guide", address: "https://example.com/settings", space: 0)
        var ran: PaletteCommand?
        results.onCommand = { ran = $0 }
        results.update(tabs: [settingsTab], query: "settings", activeID: settingsTab.id, canCreate: true,
                       commands: PaletteCommandCatalog.matches("settings"))
        require(results.activateSelection() && ran?.id == "settings", "A leading command is the first, selected row")
        results.update(tabs: [settingsTab], query: "page", activeID: settingsTab.id, canCreate: true,
                       commands: PaletteCommandCatalog.matches("page"))
        submitted = nil; ran = nil
        require(results.activateSelection() && submitted == "page" && ran == nil, "A trailing command leaves Open or Search first")
        results.moveSelection(delta: 1)
        require(results.activateSelection() && ran?.id == page.first?.command.id, "A trailing command follows the query row when no tab matches")
        print("PASS: \(checks) tab search ranking, command and selection checks")
    }
}
