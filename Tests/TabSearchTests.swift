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
        // The same index survives typing and suggestion replies. Live values,
        // order and active identity must still win over cached normalized keys.
        var index = TabSearchMatcher.Index()
        require(index.matches(tabs: tabs, query: "arc", activeID: url.id).map(\.id) == [exact.id, prefix.id, substring.id, url.id],
                "A cold index preserves the established ranking")
        require(index.matches(tabs: tabs, query: "ARC", activeID: url.id).map(\.id) == [exact.id, prefix.id, substring.id, url.id],
                "A reused index preserves query normalization and ranking")
        var edited = exact
        edited.title = "Renamed project"; edited.address = "https://changed.example/current"
        require(index.matches(tabs: [edited], query: "arc", activeID: edited.id).isEmpty
                    && index.matches(tabs: [edited], query: "renamed", activeID: edited.id).map(\.id) == [edited.id],
                "A title mutation cannot reuse stale normalized text")
        require(index.matches(tabs: [edited], query: "changed.example/current", activeID: edited.id).map(\.id) == [edited.id],
                "Navigation refreshes the cached current URL")
        edited.saved = SavedTabState(kind: .kept, address: "https://saved.example/original", customTitle: "Saved Heading")
        require(index.matches(tabs: [edited], query: "saved heading", activeID: edited.id).map(\.id) == [edited.id]
                    && index.matches(tabs: [edited], query: "saved.example/original", activeID: edited.id).map(\.id) == [edited.id],
                "Adding saved metadata refreshes custom title and saved address keys")
        edited.saved?.address = "https://saved.example/replacement"; edited.saved?.customTitle = "Replacement heading"
        require(index.matches(tabs: [edited], query: "original", activeID: edited.id).isEmpty
                    && index.matches(tabs: [edited], query: "replacement", activeID: edited.id).map(\.id) == [edited.id],
                "Saved destination and custom-title edits invalidate reused entries")
        edited.saved?.isUnloaded = true; edited.space = 2
        require(index.matches(tabs: [edited], query: "replacement", activeID: edited.id).first == edited,
                "A cached text match returns current sleeping state and Space metadata")
        edited.saved = nil
        require(index.matches(tabs: [edited], query: "replacement", activeID: edited.id).isEmpty,
                "Removing saved metadata removes its search keys")
        require(index.matches(tabs: [], query: "renamed", activeID: edited.id).isEmpty,
                "Removed tabs cannot survive in cached results")
        edited.title = "Reinserted record"
        _ = index.matches(tabs: [edited], query: "", activeID: edited.id)
        require(index.matches(tabs: [edited], query: "renamed", activeID: edited.id).isEmpty
                    && index.matches(tabs: [edited], query: "reinserted", activeID: edited.id).map(\.id) == [edited.id],
                "An ID reinserted after an empty search uses its current metadata")
        let ties = (0..<3).map { BrowserTab(title: "Equal match", address: "https://same.example/\($0)", space: 0) }
        _ = index.matches(tabs: ties, query: "equal", activeID: UUID())
        let reordered = [ties[2], ties[0], ties[1]]
        require(index.matches(tabs: reordered, query: "equal", activeID: ties[1].id).map(\.id) == [ties[1].id, ties[2].id, ties[0].id],
                "Reordering and active-tab changes retain current tie-breaking order")
        require(index.matches(tabs: reordered, query: "", activeID: ties[1].id, limit: 2).map(\.id) == [ties[1].id, ties[2].id]
                    && index.matches(tabs: reordered, query: "equal", activeID: ties[1].id, limit: 0).isEmpty,
                "Empty and zero-limit searches preserve limits with a reused index")
        let wide = BrowserTab(title: "ＣＡＦＥ\tDesign", address: "HTTP://EXAMPLE.ORG/a%20b", space: 0)
        require(index.matches(tabs: [wide], query: "cafe design", activeID: UUID()).count == 1
                    && index.matches(tabs: [wide], query: "example.org/a b", activeID: UUID()).count == 1,
                "Cached keys preserve width, whitespace and decoded URL-prefix matching")
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
        @MainActor func resultRows() -> [NSView] {
            results.subviews.filter { $0.accessibilityRole() == .button }
        }
        @MainActor func icon(_ row: NSView) -> NSImageView { row.subviews.compactMap { $0 as? NSImageView }.first! }
        let red = NSImage(size: NSSize(width: 32, height: 16), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let blue = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        var cached = [kept.id: red, favorite.id: blue]
        var lookups: [UUID] = []
        results.faviconProvider = { id in lookups.append(id); return cached[id] }
        let originalRows = resultRows(), selectedBefore = results.selectedIndex
        let labelsBefore = originalRows.map { $0.accessibilityLabel() }
        require(icon(originalRows[0]).image === red && icon(originalRows[1]).image === blue,
                "Existing tab results obtain their own cached favicon")
        require(originalRows.allSatisfy { icon($0).contentTintColor == nil },
                "Selected and unselected favicons retain full color")
        originalRows.forEach { $0.layoutSubtreeIfNeeded() }
        require(icon(originalRows[0]).imageScaling == .scaleProportionallyUpOrDown && icon(originalRows[0]).frame.size == NSSize(width: 16, height: 16),
                "Non-square and retina images fit the existing 16-point slot proportionally")
        cached[kept.id] = blue; cached[favorite.id] = nil
        results.refreshFavicons()
        require(zip(originalRows, resultRows()).allSatisfy { $0 === $1 } && results.selectedIndex == selectedBefore,
                "An arriving icon refreshes the same panel rows without changing selection")
        require(icon(originalRows[0]).image === blue && icon(originalRows[1]).image !== blue && icon(originalRows[1]).contentTintColor != nil,
                "A missing provider result clears stale favicon pixels and restores the selected symbol tint")
        require(resultRows().map { $0.accessibilityLabel() } == labelsBefore && results.activateSelection() && chosen == favorite.id,
                "Favicon refresh preserves accessible names and the selected action")
        results.faviconProvider = nil
        require(resultRows().allSatisfy { icon($0).identifier == nil && icon($0).contentTintColor != nil },
                "Removing the provider resets every tab result to its own symbol")

        var siteCalls: [(URL, Bool)] = []
        results.siteFaviconProvider = { url, allowFetch in siteCalls.append((url, allowFetch)); return red }
        results.update(tabs: [], query: "example.org/path", activeID: UUID(), canCreate: true)
        require(siteCalls.count == 1 && siteCalls[0].0.absoluteString == "https://example.org/path" && !siteCalls[0].1,
                "An unsubmitted schemeless URL only asks for a cached icon")
        require(icon(resultRows()[0]).image === red && icon(resultRows()[0]).contentTintColor == nil,
                "A typed URL may display its cached full-color icon")
        siteCalls = []
        results.update(tabs: [], query: "https://example.org/another", activeID: UUID(), canCreate: true)
        require(siteCalls.count == 1 && !siteCalls[0].1, "An explicit typed URL never permits an icon fetch")
        siteCalls = []
        results.update(tabs: [], query: "find a website", activeID: UUID(), canCreate: true, suggestions: ["find a website guide"])
        require(siteCalls.isEmpty && resultRows().allSatisfy { icon($0).identifier == nil && icon($0).contentTintColor != nil },
                "Text queries and ordinary suggestions keep their magnifier without site lookup")
        let engine = SiteSearchCatalog.engines[0]
        results.update(tabs: [], query: "fixture", activeID: UUID(), canCreate: true, engine: engine, suggestions: ["fixture video"])
        require(siteCalls.count == 2 && siteCalls.allSatisfy { $0.0.absoluteString == "https://\(engine.host)" && $0.1 },
                "Scoped search rows may fetch only the chosen engine's HTTPS icon")
        let engineRows = resultRows()
        results.moveSelection(delta: 1)
        let engineSelection = results.selectedIndex
        results.siteFaviconProvider = { _, _ in nil }
        require(zip(engineRows, resultRows()).allSatisfy { $0 === $1 } && results.selectedIndex == engineSelection &&
                    engineRows.allSatisfy { icon($0).identifier == nil && icon($0).contentTintColor != nil },
                "Engine-icon replacement clears old images without rebuilding or losing keyboard selection")
        // Browser commands: typed names lead, loose matches trail the tabs.
        let settingsHit = PaletteCommandCatalog.matches("setting")
        require(settingsHit.first?.command.id == "settings" && settingsHit.first?.leading == true, "A typed command name leads")
        let preferences = PaletteCommandCatalog.matches("preferences")
        require(preferences.first?.command.id == "settings" && preferences.first?.leading == false, "Keywords find Settings but never lead")
        require(PaletteCommandCatalog.matches("pdf").first?.leading == false && PaletteCommandCatalog.matches("video").first?.leading == false, "Search-like keywords leave Return to the web search")
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
        // Every palette command runs a real handler: its selector is declared as an @objc action in the app's sources
        // (no decorative entries), and the browser actions people search for are all findable by name.
        let sourcesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let appSources = ((try? FileManager.default.contentsOfDirectory(at: sourcesURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" && !$0.lastPathComponent.contains("Test") && !$0.lastPathComponent.contains("Probe") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        require(!appSources.isEmpty, "The app sources are readable from the test")
        for command in PaletteCommandCatalog.commands {
            let name = String(command.action.dropLast())
            require(command.action.hasSuffix(":") && (appSources.contains("@objc func \(name)(_") || appSources.contains("@objc private func \(name)(_")),
                    "Palette command \(command.id) runs a real @objc handler (\(command.action))")
        }
        for (query, id) in [("manage extensions", "extensions"), ("add extension", "add-extension"), ("settings", "settings"),
                            ("downloads", "downloads"), ("history", "history"), ("new space", "new-space"), ("import from arc", "import-arc"),
                            ("dark appearance", "appearance-dark"), ("theme", "appearance-dark"), ("reopen closed", "reopen-tab")] {
            require(PaletteCommandCatalog.matches(query).contains { $0.command.id == id }, "\(query) finds \(id)")
        }
        require(Set(PaletteCommandCatalog.commands.map(\.id)).count == PaletteCommandCatalog.commands.count, "Command IDs are unique")
        // Held arrow keys (auto-repeat) step and stop at the ends; a discrete press still wraps.
        let held = (0..<4).map { BrowserTab(title: "Held \($0)", address: "https://example.com/held/\($0)", space: 0) }
        results.update(tabs: held, query: "held", activeID: UUID(), canCreate: false)
        let lastRow = results.selectedIndex + 3
        for _ in 0..<10 { results.moveSelection(delta: 1, repeating: true) }
        require(results.selectedIndex == lastRow, "A held Down arrow stops at the last row instead of wrapping (\(results.selectedIndex))")
        for _ in 0..<10 { results.moveSelection(delta: -1, repeating: true) }
        require(results.selectedIndex == 0, "A held Up arrow stops at the first row")
        results.moveSelection(delta: -1)
        require(results.selectedIndex == lastRow, "A discrete Up press at the top still wraps to the last row")
        // Trailing actions: other tabs say what Return does; the current tab keeps its Space context only.
        let current = held[0], other = held[1]
        results.update(tabs: [current, other], query: "held", activeID: current.id, canCreate: false)
        let actionLabels = labels(in: results)
        require(actionLabels.filter { $0 == "Switch to Tab" }.count == 1 && actionLabels.contains("Studio · Current"),
                "Only the non-current tab offers Switch to Tab; the current one keeps its context: \(actionLabels)")
        print("PASS: \(checks) tab search ranking, command, favicon and selection checks")
    }
}
