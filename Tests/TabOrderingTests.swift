import Foundation

/// Behavior tests for Arc-style tab order and navigation: where new and link
/// tabs go, who takes over when a tab closes, reopen in place, the ⌃⇥ recent
/// list and the ⌘1–⌘9 mapping.
@main struct TabOrderingTests {
    nonisolated(unsafe) static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }; count += 1
    }
    static func page(_ title: String, space: Int = 0) -> BrowserTab {
        BrowserTab(title: title, address: "https://\(title.lowercased()).example", space: space)
    }
    /// Today rows of a Space, top to bottom.
    static func today(_ session: BrowserSession, _ space: Int = 0) -> [String] {
        session.tabs.filter { $0.space == space && !$0.isSaved }.map(\.title)
    }
    static func title(_ session: BrowserSession, _ id: UUID?) -> String? { session.tabs.first { $0.id == id }?.title }
    /// A Space 0 with Today rows "One", "Two", "Three" (top to bottom), "One" selected.
    static func base() -> BrowserSession {
        let tabs = [page("One"), page("Two"), page("Three"), page("Other", space: 1)]
        var session = BrowserSession(tabs: tabs, activeID: tabs[0].id, lastSelectedTabIDsBySpace: [0: tabs[0].id])
        session.sanitize()
        return session
    }
    static func id(_ session: BrowserSession, _ title: String) -> UUID { session.tabs.first { $0.title == title }!.id }

    static func main() throws {
        // ⌘T: a new tab opens at the top of Today, above everything already there.
        var s = base()
        let new = s.add(address: "https://new.example", title: "New")
        expect(today(s) == ["New", "One", "Two", "Three"], "New tabs open at the top of Today, got \(today(s))")
        expect(s.activeID == new, "The new tab is selected")
        expect(today(s, 1) == ["Other"], "Other Spaces are untouched")

        // Link tabs go right after their opener, in the order they were opened.
        s = base()
        let opener = id(s, "Two")
        s.select(opener)
        let a = s.add(address: "https://a.example", title: "A", opener: opener); s.select(opener)   // background, like ⌘-click
        _ = s.add(address: "https://b.example", title: "B", opener: opener); s.select(opener)
        let c = s.add(address: "https://c.example", title: "C", opener: opener)                    // foreground
        expect(today(s) == ["One", "Two", "A", "B", "C", "Three"], "Link tabs follow their opener in open order, got \(today(s))")
        expect(s.openers[a] == opener && s.openers[c] == opener, "Openers are remembered")

        // Closing a link tab hands over to the next sibling below, then above, then the opener.
        s.select(id(s, "B"))
        _ = s.close(id(s, "B"))
        expect(title(s, s.activeID) == "C", "Closing B selects its next sibling C, got \(title(s, s.activeID) ?? "nil")")
        _ = s.close(c)
        expect(title(s, s.activeID) == "A", "Closing the last sibling selects the one above, got \(title(s, s.activeID) ?? "nil")")
        _ = s.close(a)
        expect(title(s, s.activeID) == "Two", "Closing the only link tab returns to its opener, got \(title(s, s.activeID) ?? "nil")")

        // An opener that moved to another Space is not a landing spot: closing its link tab stays in this Space.
        s = base()
        let mover = id(s, "Two"); s.select(mover)
        let child = s.add(address: "https://child.example", title: "Child", opener: mover)
        expect(s.moveTab(id: mover, toSpace: 1), "Two moves to Space 1")
        s.select(child)
        _ = s.close(child)
        expect(s.space == 0 && s.active?.space == 0, "Closing a link tab whose opener moved away stays in its Space, got space \(s.space) on \(title(s, s.activeID) ?? "nil")")

        // Selecting a tab outside the family forgets openers, as browsers do: the next link tab goes right after its opener again.
        s = base()
        let two = id(s, "Two"); s.select(two)
        _ = s.add(address: "https://a.example", title: "A", opener: two); s.select(two)
        s.select(id(s, "Three"))
        expect(s.openers.isEmpty, "Leaving the family forgets openers")
        s.select(two)
        _ = s.add(address: "https://z.example", title: "Z", opener: two)
        expect(today(s) == ["One", "Two", "Z", "A", "Three"], "A fresh link run starts right after the opener, got \(today(s))")
        s.select(id(s, "A"))
        expect(s.openers[id(s, "Z")] == nil, "Z's opener was forgotten when the selection left Z's family")

        // Ordinary tabs: closing the selected one goes to the row below, the bottom row to the one above.
        s = base()
        s.select(id(s, "Two")); _ = s.close(id(s, "Two"))
        expect(title(s, s.activeID) == "Three", "Closing a middle tab selects the row below, got \(title(s, s.activeID) ?? "nil")")
        _ = s.close(id(s, "Three"))
        expect(title(s, s.activeID) == "One", "Closing the bottom tab selects the row above, got \(title(s, s.activeID) ?? "nil")")
        // Closing a tab that isn't selected leaves the selection alone.
        s = base(); s.select(id(s, "Three")); _ = s.close(id(s, "One"))
        expect(title(s, s.activeID) == "Three", "Closing a background tab keeps the selection")

        // Reopen in place: a closed tab returns below the row it sat under.
        s = base()
        var closed = s.tabs.first { $0.title == "Two" }!
        _ = s.close(closed.id)
        let originalID = closed.id; closed.id = UUID()
        s.insertRestored(closed, originalID: originalID)
        expect(today(s) == ["One", "Two", "Three"], "Reopened tab returns to its place, got \(today(s))")
        // The top row returns to the top; an unknown anchor falls back to the top.
        s = base()
        var top = s.tabs.first { $0.title == "One" }!
        _ = s.close(top.id); let topID = top.id; top.id = UUID()
        s.insertRestored(top, originalID: topID)
        expect(today(s) == ["One", "Two", "Three"], "The top tab reopens at the top, got \(today(s))")
        var stranger = page("Stranger"); let strangerID = stranger.id; stranger.id = UUID()
        s.insertRestored(stranger, originalID: strangerID)
        expect(today(s).first == "Stranger", "Without a remembered place, a reopened tab goes to the top")

        // ⌃⇥: most recent first, current tab leads, capped, only this Space.
        s = base()
        for title in ["Two", "Three", "One"] { s.select(id(s, title)); s.noteRecent(s.activeID) }
        expect(s.recentSwitcherTabs().map { title(s, $0)! } == ["One", "Three", "Two"], "Recent order newest first, got \(s.recentSwitcherTabs().map { title(s, $0)! })")
        s.select(id(s, "Three")); s.noteRecent(s.activeID)
        expect(s.recentSwitcherTabs().prefix(2).map { title(s, $0)! } == ["Three", "One"], "A quick ⌃⇥ goes to the previous tab")
        for n in 0..<8 { let extra = s.add(address: "https://x\(n).example", title: "X\(n)"); s.noteRecent(extra) }
        expect(s.recentSwitcherTabs().count == 5 && s.recentSwitcherTabs(limit: 3).count == 3, "The switcher shows at most five tiles")
        expect(!s.recentSwitcherTabs(limit: 20).contains(id(s, "Other")), "Tabs from other Spaces stay out")
        // Without history, the list fills up in sidebar order.
        s = base()
        expect(s.recentSwitcherTabs().map { title(s, $0)! } == ["One", "Two", "Three"], "Fresh sessions fall back to sidebar order")
        // Closed tabs drop out.
        s.noteRecent(id(s, "Three")); _ = s.close(id(s, "Three"))
        expect(!s.recentSwitcherTabs().contains { title(s, $0) == nil }, "Closed tabs never appear")
        // The recent list survives a save.
        s.noteRecent(id(s, "Two"))
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: try JSONEncoder().encode(s))
        expect(decoded.recentTabIDs?.first == id(s, "Two"), "Recent order is saved with the session")

        // ⌘1–⌘9: Favorites, then kept rows, then Today; ⌘9 is the last tab.
        s = base()
        let fav = page("Fav"), kept = page("Kept")
        s.tabs.insert(contentsOf: [fav, kept], at: 0)
        _ = s.setRetention(id: fav.id, kind: .favorite)
        _ = s.setRetention(id: kept.id, kind: .kept)
        let order = s.shortcutTabs().map { title(s, $0)! }
        expect(order == ["Fav", "Kept", "One", "Two", "Three"], "⌘N order is Favorites, kept, Today, got \(order)")
        expect(title(s, s.shortcutTab(1)) == "Fav" && title(s, s.shortcutTab(3)) == "One", "⌘1 and ⌘3")
        expect(title(s, s.shortcutTab(9)) == "Three", "⌘9 is the last tab")
        expect(s.shortcutTab(8) == nil, "⌘8 past the end does nothing")
        // A blank New Tab placeholder that isn't selected has no row, so no number.
        _ = s.add(); s.select(id(s, "One"))
        expect(s.shortcutTabs().count == 5, "Hidden blank tabs get no number")

        // Rename: any tab; empty restores the page title; the name follows keep/unkeep and survives a save.
        s = base()
        let renamed = id(s, "Two")
        expect(s.renameTab(id: renamed, title: "  My name  ") && s.tabs.first { $0.id == renamed }?.displayTitle == "My name", "Today tabs can be renamed")
        _ = s.setRetention(id: renamed, kind: .kept)
        expect(s.tabs.first { $0.id == renamed }?.saved?.customTitle == "My name", "Keeping a renamed tab keeps its name")
        _ = s.setRetention(id: renamed, kind: nil)
        expect(s.tabs.first { $0.id == renamed }?.displayTitle == "My name", "Letting it go keeps the name too")
        let roundTrip = try JSONDecoder().decode(BrowserSession.self, from: try JSONEncoder().encode(s))
        expect(roundTrip.tabs.first { $0.id == renamed }?.displayTitle == "My name", "Names are saved")
        expect(s.renameTab(id: renamed, title: "") && s.tabs.first { $0.id == renamed }?.displayTitle == "Two", "An empty name restores the page title")
        expect(!s.renameTab(id: renamed, title: String(repeating: "x", count: 81)), "Overlong names are refused")

        // Duplicate: just below the original, selected, same page and name.
        s = base()
        let original = id(s, "Two")
        _ = s.renameTab(id: original, title: "Named")
        let copy = s.duplicate(id: original)
        expect(copy != nil && s.activeID == copy, "The duplicate is selected")
        expect(today(s) == ["One", "Two", "Two", "Three"] && s.tabs.first { $0.id == copy }?.displayTitle == "Named",
               "The duplicate sits just below with the same page and name, got \(today(s))")
        expect(s.tabs.first { $0.id == copy }?.address == s.tabs.first { $0.id == original }?.address, "Same address")

        // Change Icon: ordinary tabs take an icon too; it follows keep/unkeep, survives a save and replaces the globe.
        s = base()
        let iconTab = id(s, "Three")
        expect(s.updateTab(id: iconTab, customTitle: "Iconic", customSymbol: "heart"), "Ordinary tabs take a name and icon")
        expect(s.tabs.first { $0.id == iconTab }?.symbol == "heart" && s.tabs.first { $0.id == iconTab }?.monogram == nil, "The icon shows instead of the monogram")
        expect(!s.updateTab(id: iconTab, customTitle: nil, customSymbol: "not-a-symbol"), "Unknown icons are refused")
        _ = s.setRetention(id: iconTab, kind: .kept)
        expect(s.tabs.first { $0.id == iconTab }?.saved?.customSymbol == "heart", "Keeping carries the icon")
        _ = s.setRetention(id: iconTab, kind: nil)
        expect(s.tabs.first { $0.id == iconTab }?.customSymbol == "heart", "Letting go carries it back")
        let iconTrip = try JSONDecoder().decode(BrowserSession.self, from: try JSONEncoder().encode(s))
        expect(iconTrip.tabs.first { $0.id == iconTab }?.symbol == "heart", "Icons are saved")
        expect(s.updateTab(id: iconTab, customTitle: nil, customSymbol: nil) && s.tabs.first { $0.id == iconTab }?.chosenSymbol == nil, "Automatic clears it")

        // Closing the last Today tab goes back to the open kept tab used before it, not to a new blank page.
        s = base()
        let lastKept = page("Kept open"); s.tabs.insert(lastKept, at: 0); _ = s.setRetention(id: lastKept.id, kind: .kept)
        s.select(lastKept.id); s.noteRecent(lastKept.id)
        for title in ["One", "Two"] { _ = s.close(id(s, title)) }
        s.select(id(s, "Three")); s.noteRecent(s.activeID)
        let before = s.tabs.count
        _ = s.close(id(s, "Three"))
        expect(s.activeID == lastKept.id && s.tabs.count == before - 1, "Closing the last Today tab returns to the recent kept tab: \(title(s, s.activeID) ?? "nil")")

        // Tabs below: Today rows under this one only.
        s = base()
        expect(s.todayTabs(below: id(s, "One")).map { title(s, $0)! } == ["Two", "Three"], "Tabs below One")
        expect(s.todayTabs(below: id(s, "Three")).isEmpty, "Nothing below the last row")

        print("PASS: \(count) tab ordering checks")
    }
}
