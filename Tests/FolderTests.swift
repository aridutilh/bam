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
        expect(recovered.tabs.count == session.tabs.count && recovered.folders == session.folders, "One corrupt folder record costs only that record")

        // Splits move as one row and keep their companion in the folder.
        var splitting = BrowserSession(tabs: [kept("Left"), kept("Right")], activeID: UUID()); splitting.sanitize()
        let left = splitting.tabs[0].id, right = splitting.tabs[1].id
        expect(splitting.makeSplit(primary: left, secondary: right), "Split")
        let pane = splitting.createFolder(name: "Panes", space: 0, containing: [right])!
        expect(splitting.tabs.allSatisfy { $0.folderID == pane }, "Both Split members move together")
        expect(splitting.keptLayout(in: 0).map(\.id) == [pane, left], "Split is one row inside the folder")

        // Mixed retention: kept primary + Today companion, and the reverse.
        for keptPrimary in [true, false] {
            let first = keptPrimary ? kept("KeptPane") : BrowserTab(title: "TodayPane", address: "https://todaypane.example", space: 0)
            let second = keptPrimary ? BrowserTab(title: "TodayPane", address: "https://todaypane.example", space: 0) : kept("KeptPane")
            var mixed = BrowserSession(tabs: [first, second, kept("Other")], activeID: first.id); mixed.sanitize()
            expect(mixed.makeSplit(primary: first.id, secondary: second.id), "Mixed Split")
            guard let box = mixed.createFolder(name: "Box", space: 0, containing: [second.id]) else { expect(false, "Wrap mixed Split"); continue }
            let todayPane = mixed.tabs.first { $0.title == "TodayPane" }!
            expect(mixed.tabs.first { $0.id == first.id }?.saved?.kind == .kept, "The Split row becomes kept when it enters a folder")
            expect(todayPane.saved == nil || todayPane.id == first.id, "An ordinary companion keeps its retention")
            let layout = mixed.keptLayout(in: 0)
            let boxIndex = layout.firstIndex { $0.id == box }!
            expect(layout[boxIndex + 1].id == first.id && layout[boxIndex + 1].depth == 1 && !layout.contains { $0.id == second.id },
                   "Mixed Split is one row in the folder")
            expect(Set(mixed.tabIDs(inFolder: box)) == [first.id, second.id], "Folder membership includes both panes")
            // Cross-profile move carries both panes and keeps the pair.
            let other = mixed.createProfile(name: "Work")!
            let workSpace = mixed.createSpace(name: "Work", symbol: "briefcase", colorIndex: 1, profileID: other)!
            var moved = mixed
            expect(moved.moveFolder(id: box, toSpace: workSpace), "Move folder holding a mixed Split")
            expect(moved.tabs.filter { [first.id, second.id].contains($0.id) }.allSatisfy { $0.space == workSpace }, "Both panes move")
            expect(moved.split(for: first.id) == BrowserSplit(primaryID: first.id, secondaryID: second.id), "Pair survives the move")
            let roundTrip = fixtures.appendingPathComponent("mixed-\(keptPrimary).json")
            try SessionFile.save(moved, to: roundTrip)
            let reloaded = SessionFile.load(roundTrip)
            expect(reloaded.split(for: first.id) != nil && reloaded.folder(box)?.space == workSpace, "Mixed Split folder survives restart")
            // Unkeeping the primary while grouped takes the whole row out of the folder.
            var unkept = mixed
            expect(unkept.setRetention(id: first.id, kind: nil), "Unkeep grouped primary")
            expect(unkept.tabIDs(inFolder: box).isEmpty && unkept.tabs.allSatisfy { $0.folderID == nil }, "No pane is left behind in the folder")
            var afterUnkeep = unkept
            expect(afterUnkeep.moveFolder(id: box, toSpace: workSpace) && afterUnkeep.split(for: first.id) != nil
                   && afterUnkeep.tabs.first { $0.id == second.id }?.space == 0, "Moving the emptied folder leaves the Split intact")
        }

        // Wrapping is atomic: unsupported rows leave no empty folder behind.
        var atomic = BrowserSession(tabs: [kept("Keep"), BrowserTab(title: "Ext", address: "webkit-extension://\(UUID().uuidString)/popup.html", space: 0)], activeID: UUID())
        atomic.sanitize()
        let extID = atomic.tabs.first { $0.title == "Ext" }!.id
        let folderCount = atomic.folders.count
        expect(atomic.createFolder(name: "Nope", space: 0, containing: [extID]) == nil && atomic.folders.count == folderCount, "Extension pages cannot be wrapped and no folder remains")
        expect(atomic.createFolder(name: "Nope", space: 0, containing: [atomic.tabs[0].id, UUID()]) == nil && atomic.tabs[0].folderID == nil, "A stale item fails the whole wrap")
        expect(atomic.createFolder(name: "Cross", space: 1, containing: [atomic.tabs[0].id]) == nil, "Cross-Space wrap refused")
        expect(atomic.createFolder(name: "Plain", space: 0) != nil, "Plain creation still works")
        expect(atomic.createFolder(name: "Zero", space: 0, id: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) == nil, "Zero identifier refused")
        expect(!atomic.canMoveKeptItem(extID, into: nil) && atomic.canMoveKeptItem(atomic.tabs[0].id, into: atomic.folders.last!.id), "Move targets are prevalidated")

        // Dormant saved Splits (imported) persist until opened.
        var dormant = BrowserSession(tabs: [kept("One"), kept("Two"), today], activeID: today.id)
        dormant.tabs[0].saved?.isUnloaded = true; dormant.tabs[1].saved?.isUnloaded = true
        dormant.splits = [BrowserSplit(primaryID: dormant.tabs[0].id, secondaryID: dormant.tabs[1].id)]
        dormant.sanitize()
        expect(dormant.splits?.count == 1, "Unloaded saved Split pairs survive sanitation")
        dormant.select(dormant.tabs[1].id)
        expect(dormant.activeID == dormant.tabs[0].id && !dormant.tabs[0].isUnloaded && !dormant.tabs[1].isUnloaded, "Opening a dormant Split loads both panes")

        // Drag and drop within a Space.
        let p = kept("P"), q = kept("Q"), r = kept("R"), t1 = BrowserTab(title: "T1", address: "https://t1.example", space: 0),
            t2 = BrowserTab(title: "T2", address: "https://t2.example", space: 0)
        var dnd = BrowserSession(tabs: [p, q, r, t1, t2], activeID: t1.id); dnd.sanitize()
        let box = dnd.createFolder(name: "Box", space: 0)!
        let innerBox = dnd.createFolder(name: "Inner", space: 0, parent: box)!
        expect(rows(dnd) == ["P", "Q", "R", "[Box]", "  [Inner]"], "Drop fixture")
        expect(dnd.drop(r.id, at: .before(p.id), space: 0) && rows(dnd).prefix(3) == ["R", "P", "Q"], "Drop before a root row reorders")
        expect(dnd.drop(p.id, at: .into(box), space: 0) && rows(dnd) == ["R", "Q", "[Box]", "  [Inner]", "  P"], "Drop on a folder appends inside it")
        expect(dnd.drop(q.id, at: .before(innerBox), space: 0) && rows(dnd) == ["R", "[Box]", "  Q", "  [Inner]", "  P"], "Drop before a folder child lands in that folder")
        expect(dnd.drop(q.id, at: .keptEnd, space: 0) && rows(dnd).last == "Q" && dnd.tabs.first { $0.id == q.id }?.folderID == nil, "Drop at kept end leaves folders")
        expect(dnd.drop(t2.id, at: .before(r.id), space: 0) && dnd.tabs.first { $0.id == t2.id }?.saved?.kind == .kept && rows(dnd).first == "T2",
               "Dropping a Today tab in the kept section keeps it")
        expect(dnd.drop(r.id, at: .today(before: t1.id), space: 0) && dnd.tabs.first { $0.id == r.id }?.saved == nil
               && dnd.visibleTabs.filter { !$0.isSaved }.map(\.title) == ["R", "T1"], "Dropping a kept tab into Today unkeeps it at that position")
        expect(dnd.drop(r.id, at: .today(before: nil), space: 0) && dnd.visibleTabs.filter { !$0.isSaved }.map(\.title) == ["T1", "R"], "Today reorders")
        // Refusals leave the session untouched.
        let frozen = dnd
        func unchanged() -> Bool { dnd.tabs == frozen.tabs && dnd.folders == frozen.folders && dnd.rootOrder == frozen.rootOrder }
        expect(!dnd.drop(box, at: .into(innerBox), space: 0) && unchanged(), "A folder cannot drop into its descendant")
        expect(!dnd.drop(box, at: .before(p.id), space: 0) && unchanged(), "Nor before its own child")
        expect(!dnd.drop(box, at: .today(before: nil), space: 0) && unchanged(), "Folders cannot go to Today")
        expect(!dnd.drop(p.id, at: .keptEnd, space: 1) && unchanged(), "Rows from another Space are refused (cross-Space moves use moveTab)")
        expect(!dnd.drop(p.id, at: .before(UUID()), space: 0) && unchanged(), "Unknown targets are refused")
        expect(dnd.canDrop(p.id, at: .keptEnd, space: 0) && unchanged(), "canDrop never mutates")
        // Depth limit applies to drops.
        var deepDrop = BrowserSession(tabs: [kept("Leaf2")], activeID: UUID()); deepDrop.sanitize()
        var chain: UUID? = nil
        for level in 0..<BrowserSession.maximumFolderDepth { chain = deepDrop.createFolder(name: "D\(level)", space: 0, parent: chain) ?? chain }
        let loose = deepDrop.createFolder(name: "Loose", space: 0)!
        _ = deepDrop.createFolder(name: "Child", space: 0, parent: loose)
        expect(!deepDrop.canDrop(loose, at: .into(chain!), space: 0), "Drops that exceed the depth limit are refused")
        // Splits move together, including a mixed kept/Today pair.
        var splitDrop = BrowserSession(tabs: [kept("SL"), BrowserTab(title: "SR", address: "https://sr.example", space: 0), kept("Anchor")], activeID: UUID())
        splitDrop.sanitize()
        let sl = splitDrop.tabs[0].id, sr = splitDrop.tabs[1].id
        _ = splitDrop.makeSplit(primary: sl, secondary: sr)
        let splitBox = splitDrop.createFolder(name: "SplitBox", space: 0)!
        expect(splitDrop.drop(sr, at: .into(splitBox), space: 0) && Set(splitDrop.tabIDs(inFolder: splitBox)) == [sl, sr]
               && splitDrop.split(for: sl) != nil, "Dragging either pane moves the whole Split")
        expect(splitDrop.drop(sl, at: .today(before: nil), space: 0) && splitDrop.split(for: sl) != nil
               && splitDrop.tabIDs(inFolder: splitBox).isEmpty, "A Split dropped in Today stays a Split and leaves the folder")

        // Space emoji is validated and survives edits.
        var emoji = BrowserSession.fresh()
        expect(emoji.setSpaceEmoji(id: 0, emoji: "🚀") && emoji.spaceDefinition(0)?.emoji == "🚀", "Emoji icon set")
        expect(!emoji.setSpaceEmoji(id: 0, emoji: "abc") && !emoji.setSpaceEmoji(id: 0, emoji: "🚀🚀"), "Text or multiple emoji refused")
        _ = emoji.updateSpace(id: 0, name: "Renamed", symbol: "book", colorIndex: 1)
        expect(emoji.spaceDefinition(0)?.emoji == "🚀", "Editing a Space keeps its emoji")

        print("PASS: \(count) folder checks")
    }
}
