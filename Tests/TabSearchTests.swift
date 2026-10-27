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
        // Rows carry one quiet piece of context: the current tab says so; a tab in another Space names that Space.
        results.update(tabs: [research, personal], query: "tab", activeID: personal.id, canCreate: false, spaces: customSpaces)
        require(labels(in: results).contains("Research") && labels(in: results).contains("Current Tab"),
                "Search labels must resolve non-contiguous stable Space IDs")
        results.moveSelection(delta: 1)
        let renamedSpaces = [BrowserSpace(id: 41, name: "Lab", symbol: "book", colorIndex: 2), customSpaces[0]]
        results.update(tabs: [research, personal], query: "tab", activeID: personal.id, canCreate: false, spaces: renamedSpaces)
        require(labels(in: results).contains("Lab") && !labels(in: results).contains("Research"),
                "Rename/reorder refresh must show the current Space name")
        require(results.activateSelection() && chosen == research.id,
                "Renaming or reordering Spaces must retain the selected tab identity")
        results.update(tabs: [research], query: "tab", activeID: UUID(), canCreate: false, spaces: [])
        require(labels(in: results).contains("Unknown Space"),
                "An absent Space definition must not label a tab with another Space's name")
        results.update(tabs: [prefix], query: "arc", activeID: UUID(), canCreate: false)
        require(labels(in: results).contains("Studio"), "Legacy callers retain default Space names")
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
        results.update(tabs: [kept, favorite], query: "", activeID: UUID(), canCreate: false, spaces: renamedSpaces)
        require(labels(in: results).contains("Project Atlas") && labels(in: results).contains("Lab"),
                "A kept result uses its custom title and current Space name")
        results.update(tabs: [kept, favorite], query: "o", activeID: UUID(), canCreate: false, spaces: renamedSpaces)
        require(labels(in: results).filter { $0 == "Global Inbox" }.count == 1
                    && labels(in: results).contains("— favorite.example/home")
                    && !labels(in: results).contains { $0.hasPrefix("Sleeping") },
                "A sleeping Favorite shows one result, \"Title — saved address\" as Arc writes it")
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
        require(icon(originalRows[0]).imageScaling == .scaleProportionallyUpOrDown && icon(originalRows[0]).frame.size == NSSize(width: 18, height: 18),
                "Non-square and retina images fit the 18-point icon slot proportionally")
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
        // The palette never extends past the window: ten rows at the 540pt minimum rise and scroll; a short list
        // keeps the stable centered top, and the card's height follows its rows (Arc's).
        for (height, rows) in [(CGFloat(540), 10), (540, 3), (900, 10), (300, 10)] {
            let resultsHeight = CGFloat(rows) * PaletteGeometry.rowHeight
            let fit = PaletteGeometry.fit(windowHeight: height, resultsHeight: resultsHeight)
            let bottom = fit.top + PaletteGeometry.chromeHeight + fit.visibleResultsHeight
            require(fit.top >= 0 && bottom <= height - PaletteGeometry.margin + 0.001 || height < 2 * PaletteGeometry.margin + PaletteGeometry.chromeHeight,
                    "The palette fits a \(height)pt window with \(rows) rows (top \(fit.top), bottom \(bottom))")
        }
        let sixRows = 6 * PaletteGeometry.rowHeight
        let atMinimum = PaletteGeometry.fit(windowHeight: 540, resultsHeight: sixRows)
        require(atMinimum.visibleResultsHeight == sixRows && atMinimum.top <= PaletteGeometry.top(forWindowHeight: 540),
                "Six rows at the 540pt minimum show unclipped")
        let tenRows = 10 * PaletteGeometry.rowHeight
        let short = PaletteGeometry.fit(windowHeight: 400, resultsHeight: tenRows)
        require(short.visibleResultsHeight < tenRows && short.top == PaletteGeometry.margin,
                "Ten rows in a 400pt window: the card rises to the margin and its rows scroll")
        require(PaletteGeometry.fit(windowHeight: 900, resultsHeight: 3 * PaletteGeometry.rowHeight).top == PaletteGeometry.top(forWindowHeight: 900)
                    && PaletteGeometry.fit(windowHeight: 900, resultsHeight: 1 * PaletteGeometry.rowHeight).top == PaletteGeometry.top(forWindowHeight: 900),
                "Short lists keep the stable centered top")
        require(PaletteGeometry.width(forWindowWidth: 1512) == 764 && PaletteGeometry.width(forWindowWidth: 800) == 540
                    && PaletteGeometry.width(forWindowWidth: 500) == 460 && PaletteGeometry.width(forWindowWidth: 3000) == 820,
                "Width is about half the window, 540–820pt, as Arc's, and never wider than the window allows")
        // Scrolling results keep the keyboard selection in view.
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 120))
        let scrolled = TabSearchResultsView(frame: NSRect(x: 0, y: 0, width: 540, height: 400))
        scroller.documentView = scrolled
        let scrollRows = (0..<8).map { BrowserTab(title: "Row \($0)", address: "https://example.com/row/\($0)", space: 0) }
        scrolled.update(tabs: scrollRows, query: "row", activeID: UUID(), canCreate: false)
        scrolled.frame.size.height = scrolled.preferredHeight
        for _ in 0..<7 { scrolled.moveSelection(delta: 1, repeating: true) }
        let shown = scroller.contentView.documentVisibleRect
        let selectedTop = CGFloat(scrolled.selectedIndex) * PaletteGeometry.rowHeight
        require(selectedTop >= shown.minY - 0.5 && selectedTop + PaletteGeometry.rowHeight - 2 <= shown.maxY + 0.5,
                "The selected row scrolls into view (row \(scrolled.selectedIndex), visible \(shown.minY)–\(shown.maxY))")
        // Rebindable commands show their live chord in the palette, mapped to the same command the menu binds.
        for (id, shortcut) in [("new-tab", ShortcutCommand.newTab), ("next-space", .nextSpace), ("previous-space", .previousSpace),
                               ("settings", .settings), ("toggle-sidebar", .toggleSidebar)] {
            require(ShortcutCommand(paletteID: id) == shortcut && PaletteCommandCatalog.commands.contains { $0.id == id },
                    "Palette command \(id) shows the live \(shortcut) chord")
        }
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
        // Trailing actions, as Arc: other tabs say Switch to Tab; the current one says it is current.
        let current = held[0], other = held[1]
        results.update(tabs: [current, other], query: "held", activeID: current.id, canCreate: false)
        let actionLabels = labels(in: results)
        require(actionLabels.filter { $0 == "Switch to Tab" }.count == 1 && actionLabels.contains("Current Tab"),
                "Only the non-current tab offers Switch to Tab; the current one says so: \(actionLabels)")
        PaletteFieldChecks.run(require, labels: labels)
        print("PASS: \(checks) tab search ranking, command, favicon and selection checks")
    }
}

/// The field's newer behaviors: sections under an empty field, inline completion, visited pages, Quick Actions
/// and the calculator.
enum PaletteFieldChecks {
    @MainActor static func run(_ require: (Bool, String) -> Void, labels allLabels: (NSView) -> [String]) {
        // Shown text only: the hidden "No matching tabs" label and empty fields are left out.
        func labels(_ view: NSView) -> [String] { allLabels(view).filter { !$0.isEmpty && $0 != "No matching tabs" && $0 != "No tabs" } }
        let now = Date()
        // History merges visits per page and ranks address starts first, then frequency and recency.
        let visits = [
            PaletteVisit(address: "https://github.com/", title: "GitHub", visitedAt: now),
            PaletteVisit(address: "https://www.github.com", title: "GitHub", visitedAt: now.addingTimeInterval(-3600)),
            PaletteVisit(address: "https://github.com/aridutilh/bam#readme", title: "aridutilh/bam", visitedAt: now),
            PaletteVisit(address: "https://gitlab.com/", title: "GitLab", visitedAt: now.addingTimeInterval(-86_400 * 90)),
            PaletteVisit(address: "https://news.example/item", title: "Why git is hard", visitedAt: now),
            PaletteVisit(address: "file:///etc/passwd", title: "Not a web page", visitedAt: now),
        ]
        let index = PaletteHistoryIndex(visits: visits, now: now)
        require(index.sites.count == 4, "History merges www, trailing slash and fragments into one page and skips non-web addresses")
        let git = index.matches("git", limit: 5)
        require(git.map(\.address).prefix(3) == ["https://github.com/", "https://github.com/aridutilh/bam#readme", "https://gitlab.com/"]
                    && git.last?.address == "https://news.example/item",
                "Address starts outrank title words; more and newer visits rank higher: \(git.map(\.address))")
        require(index.matches("git", excluding: [PaletteAddressKey.key("https://github.com")], limit: 5).allSatisfy { $0.address != "https://github.com/" },
                "An open tab's page is left out of visited pages")
        require(index.matches("why hard", limit: 3).first?.title == "Why git is hard", "Every typed word can match the title")

        // Inline completion.
        let candidates = index.sites.map { PaletteCompletionCandidate(address: $0.address, title: $0.title, weight: $0.score) }
        let completion = PaletteAutocomplete.complete("Git", candidates: candidates)
        require(completion?.text == "Github.com" && completion?.tail == "hub.com" && completion?.typed == "Git"
                    && completion?.address == "https://github.com/" && completion?.title == "GitHub",
                "Typing completes to the most-visited host, keeping the typed casing: \(String(describing: completion))")
        require(PaletteAutocomplete.complete("github.com/ari", candidates: candidates)?.text == "github.com/aridutilh/bam",
                "A typed slash completes a visited path")
        require(PaletteAutocomplete.complete("www.git", candidates: candidates)?.text == "www.github.com", "A typed www. keeps it")
        require(PaletteAutocomplete.complete("git hub", candidates: candidates) == nil && PaletteAutocomplete.complete("https://git", candidates: candidates) == nil
                    && PaletteAutocomplete.complete("zz", candidates: candidates) == nil && PaletteAutocomplete.complete("", candidates: candidates) == nil,
                "Words, schemes and unknown text never complete")
        require(PaletteAutocomplete.complete("github.com", candidates: candidates)?.tail == "", "An exact host stays a completion with no ending")
        let dev = [PaletteCompletionCandidate(address: "http://localhost:3000/dashboard", title: "Dev", weight: 5),
                   PaletteCompletionCandidate(address: "http://192.168.1.10:8080/", title: "Router", weight: 1)]
        let local = PaletteAutocomplete.complete("localh", candidates: dev)
        require(local?.text == "localhost:3000" && local?.address == "http://localhost:3000",
                "A host completion keeps its port and an http-only site's scheme: \(String(describing: local))")
        require(PaletteAutocomplete.complete("192", candidates: dev)?.address == "http://192.168.1.10:8080/",
                "An IP with a port completes to the visited root")

        // Calculator.
        require(PaletteCalculator.evaluate("2*21+0.5")?.display == "42.5" && PaletteCalculator.evaluate("= (1+2)^2 × 3")?.value == 27
                    && PaletteCalculator.evaluate("1,000 + 234.5")?.display == "1,234.5" && PaletteCalculator.evaluate("1,000 + 234.5")?.plain == "1234.5"
                    && PaletteCalculator.evaluate("50%")?.value == 0.5 && PaletteCalculator.evaluate("10 / 4")?.display == "2.5"
                    && PaletteCalculator.evaluate("-3 - -3")?.display == "0",
                "Arithmetic with precedence, powers, percent, grouping and unicode operators")
        require(PaletteCalculator.evaluate("1,000,000*2")?.plain == "2000000" && PaletteCalculator.evaluate("2x4")?.value == 8,
                "Thousands grouping and x as times")
        for text in ["42", "3.14", "-5", "2026-10-27", "555-1234", "10/27/2026", "1.2.3", "1/0", "abc", "2+", "github.com", "(1+2",
                     "0x10", "0x1F+1", "1,5+1", "3,5", "2**999", "9^9^9^9", "(-8)^0.5", String(repeating: "(", count: 60) + "1"] {
            require(PaletteCalculator.evaluate(text) == nil, "\(text) is not a sum")
        }

        // The selected row's white text stays readable on every Space hue, light and dark.
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            for step in 0..<36 {
                let tint = NSColor(deviceHue: CGFloat(step) / 36, saturation: 0.6, brightness: 1, alpha: 1)
                let contrast = PaletteSelection.whiteContrast(on: PaletteSelection.fill(for: tint, in: appearance))
                require(contrast >= 4.5, "White on the \(appearanceName.rawValue) selection fill for hue \(step * 10)° reads at \(contrast):1")
            }
        }

        // Quick Actions.
        for name in ["figma", "notion", "linear", "docs", "repo"] {
            require(PaletteQuickActionCatalog.matches(name).allSatisfy { !$0.leading }, "Typing the site name \(name) never makes Return create something")
        }
        require(PaletteQuickActionCatalog.matches("figma.new").first?.leading == true && PaletteQuickActionCatalog.matches("new notion").first?.leading == true,
                "The *.new host or the action's name still leads")
        let doc = PaletteQuickActionCatalog.matches("doc")
        require(doc.first?.action.host == "docs.new" && doc.first?.leading == true, "An alias names a Quick Action outright")
        require(PaletteQuickActionCatalog.matches("new meeting").first?.action.host == "meet.new"
                    && PaletteQuickActionCatalog.matches("mee").first?.leading == false
                    && PaletteQuickActionCatalog.matches("do").isEmpty,
                "Titles lead, partial aliases trail, two letters never match")

        // The results view, as Arc's: an empty field lists recent tabs, no headings, the previous tab first.
        let results = TabSearchResultsView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let a = BrowserTab(title: "Alpha", address: "https://alpha.example/", space: 0)
        let b = BrowserTab(title: "Beta", address: "https://beta.example/", space: 0)
        let c = BrowserTab(title: "Gamma", address: "https://gamma.example/", space: 0)
        let d = BrowserTab(title: "Delta", address: "https://delta.example/", space: 0)
        let blank = BrowserTab(title: "New tab", address: "orbit://newtab", space: 0)
        let fav = BrowserTab(title: "Mail", address: "https://mail.example/", space: 0, saved: SavedTabState(kind: .favorite, address: "https://mail.example/"))
        var chosen: UUID?, opened: [(String, Bool)] = [], copied: String?
        results.onSelect = { chosen = $0 }
        results.onOpenAddress = { opened.append(($0, $1)) }
        results.onCopy = { copied = $0 }
        results.update(tabs: [a, b, c, d, blank, fav], query: "", activeID: a.id, canCreate: true, recentTabIDs: [a.id, blank.id, c.id, d.id, b.id, fav.id])
        let empty = labels(results)
        require(empty.first == "Gamma" && empty.contains("Mail") && !empty.contains("New tab") && !empty.contains("Alpha")
                    && !empty.contains("Recent Tabs") && !empty.contains("docs.new"),
                "Empty field: recent tabs only, no current or blank tab, no headings: \(empty)")
        require(results.activateSelection() && chosen == c.id, "⌘T Return jumps back to the previous tab")
        if case .tab(let id, _) = results.selectedTarget { require(id == c.id, "The selected target is that tab") } else { require(false, "Selected target is a tab") }
        require(results.preferredHeight == 4 * PaletteGeometry.rowHeight, "Four roomy rows (Gamma, Delta, Beta, Mail), nothing else")
        // ⌘L before any edit: this page first (its title alone), then recent tabs.
        let copyLink = PaletteCommandCatalog.commands.filter { $0.id == "copy-url" }.map { PaletteCommandMatch(command: $0, leading: false) }
        results.update(tabs: [a, b, c], query: a.address, activeID: a.id, canCreate: true, commands: copyLink,
                       recentTabIDs: [a.id, c.id, b.id], editingAddress: true)
        let editing = labels(results)
        require(editing.first == "Alpha" && editing.dropFirst().first == "Gamma" && !editing.contains("— alpha.example")
                    && editing.contains("Copy URL") && editing.firstIndex(of: "Copy URL")! > editing.firstIndex(of: "Beta")!,
                "⌘L lists this page, then recent tabs, then Copy Link last: \(editing)")

        // Typed: the completed site leads, then the search, then pages; an open tab wins over its visited page.
        let hub = BrowserTab(title: "Bam repo", address: "https://github.com/aridutilh/bam", space: 0)
        let siteCompletion = PaletteAutocomplete.complete("git", candidates: candidates)
        results.update(tabs: [a, hub], query: "git", activeID: a.id, canCreate: true,
                       history: index.matches("git", excluding: [PaletteAddressKey.key(hub.address)], limit: 3),
                       completion: siteCompletion)
        let typed = labels(results)
        require(typed.first == "GitHub" && typed.dropFirst().first == "— github.com" && typed.contains("git") && typed.contains("Bam repo")
                    && typed.contains("GitLab") && !typed.contains("aridutilh/bam") && typed.filter({ $0 == "— github.com" }).count == 1,
                "\"GitHub — github.com\", the search, the open tab, visited pages, without duplicates: \(typed)")
        require(results.activateSelection() && opened.last?.0 == "https://github.com/" && opened.last?.1 == false,
                "Return on the completed site opens it")
        // A completion whose page is already open shows that tab, and Return switches to it.
        let open = PaletteAutocomplete.complete("github.com/ar", candidates: candidates)
        results.update(tabs: [a, hub], query: "github.com/ar", activeID: a.id, canCreate: true, completion: open)
        require(results.activateSelection() && chosen == hub.id && labels(results).contains("Switch to Tab"), "An open completion switches to its tab")

        // Calculator and Quick Action rows.
        let sum = PaletteCalculator.evaluate("6*7")
        results.update(tabs: [], query: "6*7", activeID: UUID(), canCreate: true, calculation: sum)
        require(labels(results).first == "42" && labels(results).contains("— 6*7") && labels(results).contains("Copy")
                    && results.activateSelection() && copied == "42",
                "An answer leads and Return copies it")
        results.update(tabs: [], query: "doc", activeID: UUID(), canCreate: true, quickActions: PaletteQuickActionCatalog.matches("doc"))
        require(labels(results).first == "New document" && results.activateSelection() && opened.last?.0 == "https://docs.new" && opened.last?.1 == true,
                "A Quick Action alias leads and always opens a new tab")
        require(TabSearchResultsView.looksLikeAddress("example.com/a") && TabSearchResultsView.looksLikeAddress("localhost:3000")
                    && !TabSearchResultsView.looksLikeAddress("2*21+0.5") && !TabSearchResultsView.looksLikeAddress("find a site"),
                "Address-shaped text is told apart from words and sums")
    }
}
