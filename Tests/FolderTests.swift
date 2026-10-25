import Foundation

/// Behavior tests for kept-section folders: hierarchy, ordering, collapse,
/// selection visibility, migration and repair of damaged sessions.
@main struct FolderTests {
    nonisolated(unsafe) static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }; count += 1
    }
    static func kept(_ title: String, space: Int = 0) -> BrowserTab {
        BrowserTab(title: title, address: "https://\(title.lowercased()).example", space: space, pinned: true)
    }
    static func rows(_ session: BrowserSession, _ space: Int = 0) -> [String] {
        session.keptLayout(in: space).map { entry in
            let name = entry.isFolder ? "[" + (session.folder(entry.id)?.name ?? "?") + "]"
                : session.tabs.first { $0.id == entry.id }?.title ?? "?"
            return String(repeating: "  ", count: entry.depth) + name
        }
    }

    static func main() throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

        // Legacy sessions keep their kept order and gain no folders.
        let a = kept("A"), b = kept("B"), c = kept("C"), today = BrowserTab(title: "Today", address: "https://today.example", space: 0)
        var session = BrowserSession(tabs: [a, b, c, today], activeID: today.id)
        expect(rows(session) == ["A", "B", "C"], "Legacy kept order is tab-array order")
        expect(session.visibleTabs.map(\.title) == ["A", "B", "C", "Today"], "Visible order keeps kept before Today")

        // Creating a folder from a row takes the row's place.
        let work = session.createFolder(name: "Work", space: 0, containing: [b.id])!
        expect(rows(session) == ["A", "[Work]", "  B", "C"], "Folder replaces its first row in place")
        expect(session.tabs.first { $0.id == b.id }?.folderID == work, "Tab records its folder")
        expect(session.createFolder(name: "  ", space: 0) == nil && session.createFolder(name: "X", space: 99) == nil, "Invalid folder names and Spaces are refused")

        // Nesting, moving, ordinary tabs becoming kept.
        let nested = session.createFolder(name: "Nested", space: 0, parent: work)!
        expect(session.moveKeptItem(today.id, into: nested), "Ordinary tab moves into a folder")
        expect(session.tabs.first { $0.id == today.id }?.saved?.kind == .kept, "Moving into a folder keeps the tab")
        expect(rows(session) == ["A", "[Work]", "  B", "  [Nested]", "    Today", "C"], "Nested hierarchy is depth-first")

        // Cycle prevention.
        expect(!session.moveKeptItem(work, into: nested), "A folder cannot move into its own descendant")
        expect(!session.moveKeptItem(work, into: work), "A folder cannot contain itself")

        // Reordering among siblings (tabs and folders).
        expect(session.reorderKeptItem(id: work, by: 1), "Folder reorders among root rows")
        expect(rows(session) == ["A", "C", "[Work]", "  B", "  [Nested]", "    Today"], "Folder moved after C")
        expect(session.reorderSavedTab(id: a.id, by: 1), "Kept row reorder uses folder-aware order")
        expect(rows(session).prefix(2) == ["C", "A"], "Kept tab moved after C")
        expect(!session.reorderKeptItem(id: b.id, by: -1) && session.reorderKeptItem(id: b.id, by: 1), "Reorder stays within the container")
        expect(rows(session) == ["C", "A", "[Work]", "  [Nested]", "    Today", "  B"], "Child order updated")

        // Moving to a position within the same container.
        expect(session.moveKeptItem(b.id, into: work, at: 0), "Move to front of the same folder")
        expect(rows(session)[3] == "  B", "B is first in Work")
        expect(session.moveKeptItem(b.id, into: nil, at: 0), "Move out of folder to root front")
        expect(rows(session).first == "B" && session.tabs.first { $0.id == b.id }?.folderID == nil, "Row is at root")

        // Collapse hides children, but the selected tab stays discoverable.
        expect(session.setFolderCollapsed(id: work, collapsed: true), "Collapse")
        session.select(today.id)
        let visible = session.visibleKeptLayout(in: 0, revealing: session.activeID)
        expect(visible.map(\.id) == [b.id, c.id, a.id, work, today.id], "Collapsed folder reveals only the selected descendant")
        expect(visible.last?.depth == 1 && visible.last?.parentID == work, "Revealed row sits just inside the collapsed folder")
        session.select(c.id)
        expect(session.visibleKeptLayout(in: 0, revealing: session.activeID).map(\.id) == [b.id, c.id, a.id, work], "Unselected children stay hidden")
        expect(session.visibleTabs.contains { $0.id == today.id }, "Collapsed tabs remain part of the Space for search and cycling")

        // Unkeeping removes a tab from its folder; closing a kept tab only unloads it.
        session.setFolderCollapsed(id: work, collapsed: false)
        let d = kept("D"); session.tabs.append(d); _ = session.moveKeptItem(d.id, into: nested)
        session.select(d.id)
        _ = session.close(d.id)
        expect(session.tabs.first { $0.id == d.id }?.isUnloaded == true && session.tabs.first { $0.id == d.id }?.folderID == nested, "Closing a kept folder tab unloads it in place")
        expect(session.setRetention(id: today.id, kind: nil) && session.tabs.first { $0.id == today.id }?.folderID == nil, "Unkeeping leaves the folder")
        expect(session.setRetention(id: c.id, kind: .favorite) && session.tabs.first { $0.id == c.id }?.folderID == nil, "Favorites never live in folders")
        expect(!session.moveKeptItem(c.id, into: work), "Favorites cannot move into folders")
        _ = session.setRetention(id: c.id, kind: .kept)

        // Persistence round-trip keeps hierarchy, collapse and order.
        _ = session.setFolderCollapsed(id: nested, collapsed: true)
        let file = fixtures.appendingPathComponent("folders.json")
        try SessionFile.save(session, to: file)
        let restored = SessionFile.load(file)
        expect(restored.folders == session.folders && rows(restored) == rows(session), "Folders survive save and load")
        expect(restored.folder(nested)?.isCollapsed == true, "Collapse state persists")

        // Ungroup puts contents back where the folder was.
        var ungrouped = restored
        let before = rows(ungrouped)
        expect(ungrouped.ungroupFolder(id: work), "Ungroup")
        expect(ungrouped.folder(work) == nil && ungrouped.folder(nested)?.parentID == nil, "Nested folder lifts to the root")
        expect(rows(ungrouped).count == before.count - 1, "Ungroup keeps every other row")
        expect(ungrouped.tabs.count == restored.tabs.count, "Ungroup never closes tabs")

        // Rename validation.
        expect(ungrouped.renameFolder(id: nested, name: " Reading ") && ungrouped.folder(nested)?.name == "Reading", "Rename trims")
        expect(!ungrouped.renameFolder(id: nested, name: "\n"), "Empty rename refused")

        // Moving a folder to another Space carries its subtree.
        var moving = restored
        let inner = moving.tabIDs(inFolder: work)
        expect(moving.moveFolder(id: work, toSpace: 1), "Move folder to Space")
        expect(moving.folder(work)?.space == 1 && moving.folder(nested)?.space == 1, "Nested folders follow")
        expect(inner.allSatisfy { id in moving.tabs.first { $0.id == id }?.space == 1 }, "Folder tabs follow")
        expect(moving.keptLayout(in: 1).first?.id == work, "Folder lands at the destination root")
        expect(!moving.keptLayout(in: 0).contains { inner.contains($0.id) }, "Source no longer lists moved tabs")

        // Moving a tab to another Space leaves its folder.
        var tabMove = restored
        let inFolder = tabMove.tabs.first { $0.folderID == nested }!.id
        expect(tabMove.moveTab(id: inFolder, toSpace: 2) && tabMove.tabs.first { $0.id == inFolder }?.folderID == nil, "Cross-Space tab move leaves folder")

        // Deleting a Space carries its folders to the destination.
        var deleting = restored
        expect(deleting.deleteSpace(id: 0, movingTabsTo: 1), "Delete Space")
        expect(deleting.folder(work)?.space == 1 && deleting.keptLayout(in: 1).contains { $0.id == work }, "Folders follow deleted Space's tabs")

        // Depth limit.
        var deep = BrowserSession(tabs: [kept("Leaf")], activeID: UUID())
        deep.sanitize()
        var parent: UUID? = nil
        for level in 0..<BrowserSession.maximumFolderDepth { parent = deep.createFolder(name: "L\(level)", space: 0, parent: parent) ?? parent }
        expect(deep.folders.count == BrowserSession.maximumFolderDepth, "Folders nest to the limit")
        expect(deep.createFolder(name: "Too deep", space: 0, parent: parent) == nil, "Nesting beyond the limit is refused")

        // Damaged data is repaired without losing tabs.
        var damaged = restored
        let loopA = UUID(), loopB = UUID()
        damaged.folders.append(BrowserFolder(id: loopA, name: "Loop A", space: 0, parentID: loopB))
        damaged.folders.append(BrowserFolder(id: loopB, name: "Loop B", space: 0, parentID: loopA))
        damaged.folders.append(BrowserFolder(id: UUID(), name: "Lost", space: 77))
        damaged.folders.append(damaged.folders[0])
        var orphanTab = kept("Orphan"); orphanTab.folderID = UUID(); damaged.tabs.append(orphanTab)
        let ordinaryInFolder = BrowserTab(title: "Loose", address: "https://loose.example", space: 0, folderID: work); damaged.tabs.append(ordinaryInFolder)
        damaged.sanitize()
        expect(Set(damaged.folders.map(\.id)).count == damaged.folders.count, "Duplicate folders removed")
        expect(!damaged.folders.contains { $0.space == 77 }, "Folders in missing Spaces removed")
        expect(damaged.folder(loopA)?.parentID == nil || damaged.folder(loopB)?.parentID == nil, "Cycles are broken")
        expect(damaged.tabs.first { $0.id == orphanTab.id }?.folderID == nil, "Dangling folder references repair to root")
        expect(damaged.tabs.first { $0.id == ordinaryInFolder.id }?.folderID == nil, "Ordinary tabs cannot stay in folders")
        let keptCount = damaged.tabs.filter { $0.space == 0 && $0.saved?.kind == .kept && damaged.split(for: $0.id)?.secondaryID != $0.id }.count
        expect(damaged.keptLayout(in: 0).filter { !$0.isFolder }.count == keptCount, "Every kept tab is reachable in the layout")

        // A corrupt folder list never discards the tabs.
        let json = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"folders\" : [", with: "\"folders\" : [ 42, ")
        try json.write(to: fixtures.appendingPathComponent("corrupt-folders.json"), atomically: true, encoding: .utf8)
        let recovered = SessionFile.load(fixtures.appendingPathComponent("corrupt-folders.json"))
        expect(recovered.tabs.count == session.tabs.count && recovered.folders.isEmpty, "Corrupt folder metadata degrades to unfoldered kept tabs")

        // Splits move as one row and keep their companion in the folder.
        var splitting = BrowserSession(tabs: [kept("Left"), kept("Right")], activeID: UUID()); splitting.sanitize()
        let left = splitting.tabs[0].id, right = splitting.tabs[1].id
        expect(splitting.makeSplit(primary: left, secondary: right), "Split")
        let pane = splitting.createFolder(name: "Panes", space: 0, containing: [right])!
        expect(splitting.tabs.allSatisfy { $0.folderID == pane }, "Both Split members move together")
        expect(splitting.keptLayout(in: 0).map(\.id) == [pane, left], "Split is one row inside the folder")

        // Dormant saved Splits (imported) persist until opened.
        var dormant = BrowserSession(tabs: [kept("One"), kept("Two"), today], activeID: today.id)
        dormant.tabs[0].saved?.isUnloaded = true; dormant.tabs[1].saved?.isUnloaded = true
        dormant.splits = [BrowserSplit(primaryID: dormant.tabs[0].id, secondaryID: dormant.tabs[1].id)]
        dormant.sanitize()
        expect(dormant.splits?.count == 1, "Unloaded saved Split pairs survive sanitation")
        dormant.select(dormant.tabs[1].id)
        expect(dormant.activeID == dormant.tabs[0].id && !dormant.tabs[0].isUnloaded && !dormant.tabs[1].isUnloaded, "Opening a dormant Split loads both panes")

        // Space emoji is validated and survives edits.
        var emoji = BrowserSession.fresh()
        expect(emoji.setSpaceEmoji(id: 0, emoji: "🚀") && emoji.spaceDefinition(0)?.emoji == "🚀", "Emoji icon set")
        expect(!emoji.setSpaceEmoji(id: 0, emoji: "abc") && !emoji.setSpaceEmoji(id: 0, emoji: "🚀🚀"), "Text or multiple emoji refused")
        _ = emoji.updateSpace(id: 0, name: "Renamed", symbol: "book", colorIndex: 1)
        expect(emoji.spaceDefinition(0)?.emoji == "🚀", "Editing a Space keeps its emoji")

        print("PASS: \(count) folder checks")
    }
}
