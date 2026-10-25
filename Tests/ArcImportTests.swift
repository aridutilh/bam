import Foundation

/// Arc layout import against an original synthetic StorableSidebar.json.
/// No personal Arc data is used. Run with `--write-fixture <path>` to emit the
/// fixture used for canonical Bam Preview runtime checks.
@main struct ArcImportTests {
    nonisolated(unsafe) static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }; count += 1
    }

    /// Builds Arc's shape: alternating ID/object arrays, enum-keyed containers,
    /// per-profile Favorites roots, and separate sync sections that must be ignored.
    final class Fixture {
        var order: [String] = []
        var nodes: [String: [String: Any]] = [:]
        var spaces: [Any] = []
        var topApps: [Any] = []
        private var counter = 0
        func newID() -> String {
            counter += 1
            return String(format: "00000000-0000-4000-8000-%012d", counter)
        }
        @discardableResult func node(_ data: [String: Any], parent: String?, title: String? = nil, id: String? = nil) -> String {
            let id = id ?? newID()
            var object: [String: Any] = ["id": id, "childrenIds": [String](), "data": data, "createdAt": 0.0,
                                         "isUnread": false, "originatingDevice": "fixture"]
            object["parentID"] = parent ?? NSNull()
            object["title"] = title ?? NSNull()
            nodes[id] = object; order.append(id)
            if let parent { var p = nodes[parent]!; p["childrenIds"] = (p["childrenIds"] as! [String]) + [id]; nodes[parent] = p }
            return id
        }
        @discardableResult func tab(_ savedTitle: String, _ url: String, in parent: String, custom: String? = nil) -> String {
            node(["tab": ["savedURL": url, "savedTitle": savedTitle, "timeLastActiveAt": 0.0]], parent: parent, title: custom)
        }
        @discardableResult func folder(_ title: String, in parent: String, live: Bool = false) -> String {
            node(["list": live ? ["automaticLiveFolderData": ["dataSource": ["github": [:]]]] : [:]], parent: parent, title: title)
        }
        func container(_ type: [String: Any]) -> String { node(["itemContainer": ["containerType": type]], parent: nil) }
        static func profile(_ key: String?) -> [String: Any] {
            guard let key else { return ["default": true] }
            return ["custom": ["_0": ["directoryBasename": key, "machineID": "machine-\(key)"]]]
        }
        @discardableResult func space(_ title: String, profile: String?, emoji: Any? = nil, theme: (Double, Double, Double)? = nil, legacy: Bool = false) -> (pinned: String, unpinned: String) {
            let id = newID()
            let pinned = container(["spaceItems": ["_0": id]]), unpinned = container(["spaceItems": ["_0": id]])
            var icon: [String: Any] = [:]
            if let text = emoji as? String { icon["emoji_v2"] = text } else if let code = emoji as? Int { icon["emoji"] = code }
            var custom: [String: Any] = ["iconType": icon]
            if let (r, g, b) = theme {
                custom["windowTheme"] = ["primaryColorPalette": ["midTone": ["red": r, "green": g, "blue": b, "alpha": 1, "colorSpace": "extendedSRGB"]]]
            }
            var object: [String: Any] = ["id": id, "title": title, "profile": Self.profile(profile), "customInfo": custom,
                                         "containerIDs": ["pinned", pinned, "unpinned", unpinned]]
            object["newContainerIDs"] = legacy ? [Any]() : [["pinned": [:]], pinned, ["unpinned": [:]], unpinned] as [Any]
            spaces += [id, object]
            return (pinned, unpinned)
        }
        func favorites(profile: String?) -> String {
            let root = container(["topApps": ["_0": Self.profile(profile)]])
            topApps += [Self.profile(profile), root]
            return root
        }
        func json(version: Int = 1) -> Data {
            let items: [Any] = order.flatMap { [$0, nodes[$0]!] as [Any] }
            let decoy: [Any] = [newID(), ["id": "decoy", "title": "Deleted elsewhere"]]
            let root: [String: Any] = [
                "version": version,
                "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": items, "topAppsContainerIDs": topApps]]],
                // Sync snapshots differ from the local tree and must never be merged.
                "sidebarSyncState": ["spaceModels": decoy, "items": decoy],
                "firebaseSyncState": ["syncData": ["spaces": decoy]]
            ]
            return try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        }
    }

    struct Built { let fixture: Fixture; let ids: [String: String] }
    static func standardFixture() -> Built {
        let f = Fixture(); var ids: [String: String] = [:]
        let work = f.space("Work", profile: nil, emoji: "💼", theme: (0.2, 0.4, 0.9))
        ids["docs"] = f.tab("Docs Home", "https://docs.example.com/", in: work.pinned, custom: "Team Docs")
        let projects = f.folder("Projects", in: work.pinned); ids["projects"] = projects
        ids["a"] = f.tab("Alpha Board", "https://board.example.com/a", in: projects)
        let alpha = f.folder("Alpha", in: projects)
        let l2 = f.folder("Level 2", in: alpha), l3 = f.folder("Level 3", in: l2), l4 = f.folder("Level 4", in: l3)
        ids["deep"] = f.tab("Deep Page", "https://deep.example.com/", in: l4)
        ids["b"] = f.tab("Beta Board", "https://board.example.com/b", in: projects)
        f.folder("Empty", in: work.pinned)
        ids["dup"] = f.tab("Alpha Board copy", "https://board.example.com/a", in: work.pinned)
        f.node(["easel": ["title": "Sketch"]], parent: work.pinned)
        let split = f.node(["splitView": ["layoutOrientation": "horizontal"]], parent: work.pinned)
        ids["left"] = f.tab("Left Pane", "https://left.example.com/", in: split)
        ids["right"] = f.tab("Right Pane", "https://right.example.com/", in: split)
        let prs = f.folder("Pull Requests", in: work.pinned, live: true)
        f.tab("PR 1", "https://code.example.com/pr/1", in: prs)
        let wide = f.node(["splitView": [:]], parent: work.pinned)
        for n in 1...3 { f.tab("Wide \(n)", "https://wide.example.com/\(n)", in: wide) }
        f.tab("Local File", "file:///etc/hosts", in: work.pinned)
        ids["today1"] = f.tab("Today One", "https://today.example.com/1", in: work.unpinned)
        f.tab("Today Two", "http://today.example.com/2", in: work.unpinned)
        let home = f.space("Home", profile: "Profile 1", emoji: 0x1F3E0, legacy: true)
        ids["h1"] = f.tab("Recipes", "https://food.example.com/", in: home.pinned)
        let loose = f.folder("Loose", in: home.unpinned)
        f.tab("Loose Today", "https://loose.example.com/", in: loose)
        let side = f.space("Side", profile: nil, emoji: "🧪")
        f.tab("Lab", "https://lab.example.com/", in: side.pinned)
        let defaultFavorites = f.favorites(profile: nil)
        for n in 1...14 { f.tab("Fav \(n)", "https://fav.example.com/\(n)", in: defaultFavorites) }
        let p1Favorites = f.favorites(profile: "Profile 1")
        ids["p1fav"] = f.tab("Home Mail", "https://mail.example.com/", in: p1Favorites)
        let other = f.favorites(profile: "Profile 9")
        for n in 1...3 { f.tab("Other \(n)", "https://other.example.com/\(n)", in: other) }
        return Built(fixture: f, ids: ids)
    }

    static func rows(_ session: BrowserSession, _ space: Int) -> [String] {
        session.keptLayout(in: space).map { entry in
            let name = entry.isFolder ? "[" + (session.folder(entry.id)?.name ?? "?") + "]"
                : session.tabs.first { $0.id == entry.id }.map { $0.displayTitle } ?? "?"
            return String(repeating: "  ", count: entry.depth) + name
        }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count > 2, arguments[1] == "--write-fixture" {
            try standardFixture().fixture.json().write(to: URL(fileURLWithPath: arguments[2]))
            print("Wrote synthetic Arc fixture to \(arguments[2])"); return
        }
        if arguments.count > 2, arguments[1] == "--dry-run" {
            // Counts only: never prints titles, URLs or profile identifiers.
            let (session, report) = ArcImport.apply(try ArcImport.load(from: URL(fileURLWithPath: arguments[2])), to: .fresh())
            for (index, space) in report.spaces.enumerated() {
                print("space \(index): kept \(space.keptTabs), folders \(space.folders), today \(space.todayTabs), favorites \(space.favorites), splits \(space.splits), emoji \(space.emoji != nil)")
            }
            print("tabs \(report.importedTabs), folders \(report.importedFolders), profiles new \(report.newProfiles.count), easels \(report.easels), live \(report.liveFolders), overflow \(report.favoriteOverflow), unattached \(report.unattachedProfiles)/\(report.unattachedFavorites), invalid \(report.invalidAddresses), missing \(report.missingItems), unknown \(report.unknownItems), depth \(report.depthLimited), refused \(report.refusal != nil)")
            print("max depth \(session.folders.map { session.folderDepth($0.id) }.max() ?? -1), dormant kept \(session.tabs.filter { $0.saved?.kind == .kept && !$0.isUnloaded }.count == 3)")
            return
        }
        let fixtures = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

        let built = standardFixture()
        let data = built.fixture.json()
        let source = try ArcImport.parse(data)
        expect(source.spaces.map(\.title) == ["Work", "Home", "Side"], "Only the local tree's Spaces are read; sync snapshots ignored")
        expect(source.spaces[1].pinnedRoot != nil && source.spaces[1].emoji == "🏠", "Legacy container IDs and numeric emoji are understood")
        expect(source.favoriteRoots.count == 3, "Favorites roots pair with profiles")

        // Existing user state that the import must not disturb.
        var existing = BrowserSession.fresh()
        let originalActive = existing.activeID, originalSpace = existing.space
        let originalTabs = existing.tabs
        let before = existing
        let (session, report) = ArcImport.apply(source, to: existing)
        expect(existing.tabs == before.tabs && existing.importLinks == nil, "Preview/apply never mutates the input session")
        expect(report.refusal == nil, "Import accepted")
        expect(session.activeID == originalActive && session.space == originalSpace, "Import keeps the current selection")
        expect(originalTabs.allSatisfy { tab in session.tabs.contains { $0.id == tab.id && $0.address == tab.address } }, "Existing tabs survive unchanged")

        // Spaces and appearance.
        let work = session.spaces.first { $0.name == "Work" }!, home = session.spaces.first { $0.name == "Home" }!
        let sideSpace = session.spaces.first { $0.name == "Side" }!
        expect(work.emoji == "💼" && home.emoji == "🏠" && sideSpace.emoji == "🧪", "Space emoji preserved")
        expect(work.colorIndex == 2 || work.colorIndex == 0, "Blue Arc theme maps to a cool Bam color")
        expect(work.profileID == BrowserProfile.defaultID && sideSpace.profileID == BrowserProfile.defaultID, "Default Arc profile maps to Bam's default profile")
        expect(home.profileID != BrowserProfile.defaultID && session.profiles.contains { $0.id == home.profileID }, "Custom Arc profile gets its own Bam profile")
        expect(report.spaces.count == 3 && report.firstSpaceID == work.id, "Report lists each imported Space")

        // Faithful hierarchy and order, including empty folders and duplicates by URL.
        let workRows = rows(session, work.id)
        let expectedPrefix = ["[More Favorites]", "  Fav 13", "  Fav 14", "Team Docs", "[Projects]", "  Alpha Board", "  [Alpha]",
                              "    [Level 2]", "      [Level 3]", "        [Level 4]", "          Deep Page", "  Beta Board",
                              "[Empty]", "Alpha Board copy", "Left Pane", "[Pull Requests]", "  PR 1", "Wide 1", "Wide 3"]
        expect(workRows == expectedPrefix, "Work hierarchy matches Arc order: \(workRows)")
        let workTabs = session.tabs.filter { $0.space == work.id }
        expect(workTabs.filter { $0.address == "https://board.example.com/a" }.count == 2, "Same URL in different places stays distinct")
        expect(session.folders.first { $0.name == "Projects" }?.isCollapsed == true, "Imported folders start collapsed like Arc")
        expect(session.tabs.first { $0.displayTitle == "Team Docs" }?.title == "Docs Home", "Arc custom title is the saved name; page title kept")

        // Dormancy: kept rows are unloaded; Today stays Today (ordinary) and is not relabeled.
        let kept = workTabs.filter { $0.saved?.kind == .kept }
        expect(!kept.isEmpty && kept.allSatisfy(\.isUnloaded), "Imported kept tabs are dormant")
        let today = workTabs.filter { !$0.isSaved }
        expect(Set(today.map(\.title)) == ["Today One", "Today Two"], "Today tabs remain ordinary Today tabs")
        expect(session.visibleTabs.isEmpty || !session.visibleTabs.contains { $0.space == work.id && !$0.isFavorite }, "Imported Space is not selected implicitly")

        // Splits: two-pane pair is kept and dormant; three panes keep two plus a tab.
        let left = session.tabs.first { $0.title == "Left Pane" }!, right = session.tabs.first { $0.title == "Right Pane" }!
        expect(session.split(for: left.id) == BrowserSplit(primaryID: left.id, secondaryID: right.id), "Arc Split becomes a Bam Split")
        expect(session.tabs.contains { $0.title == "Wide 3" } && report.oversizedSplits == 1, "Extra Split panes stay accessible and are reported")

        // Favorites per profile with overflow kept and reported.
        expect(session.favorites(in: BrowserProfile.defaultID).count == 12, "Twelve Favorites in the default profile")
        expect(report.favoriteOverflow == 2, "Overflow reported")
        expect(session.favorites(in: home.profileID).map(\.title) == ["Home Mail"], "Custom profile Favorites stay in that profile")
        expect(!session.favorites(in: BrowserProfile.defaultID).contains { $0.title == "Home Mail" }, "Favorites are not shared across profiles")
        expect(report.unattachedProfiles == 1 && report.unattachedFavorites == 3, "Unattached profile Favorites are reported")
        expect(!session.tabs.contains { $0.title.hasPrefix("Other ") }, "Unattached profile Favorites are not placed in unrelated profiles")

        // Unsupported items are counted, not silently dropped.
        expect(report.easels == 1 && report.liveFolders == 1 && report.invalidAddresses == 1, "Easel, live folder and file URL reported")
        expect(report.flattenedTodayFolders == 1 && session.tabs.contains { $0.title == "Loose Today" && !$0.isSaved }, "Folders in Today flatten with a notice")
        expect(report.notices.contains { $0.contains("Easel") } && report.notices.last?.contains("passwords") == true, "Notices explain limits honestly")

        // Persistence and idempotency.
        let file = fixtures.appendingPathComponent("arc-imported.json")
        try SessionFile.save(session, to: file)
        let restored = SessionFile.load(file)
        expect(restored.tabs == session.tabs && restored.folders == session.folders && restored.importLinks == session.importLinks, "Imported state survives restart")
        expect(restored.split(for: left.id) != nil, "Dormant imported Split survives restart")
        let (again, againReport) = ArcImport.apply(try ArcImport.parse(data), to: restored)
        expect(again.tabs.count == restored.tabs.count && again.folders.count == restored.folders.count && again.spaces.count == restored.spaces.count,
               "Re-importing the same layout adds nothing")
        expect(againReport.alreadyImported > 0 && againReport.importedTabs == 0, "Repeat import reports skipped items")

        // Local edits survive a repeat; deleted imported items do not come back.
        var edited = restored
        let projects = edited.folders.first { $0.name == "Projects" }!.id
        _ = edited.renameFolder(id: projects, name: "My Projects")
        _ = edited.reorderKeptItem(id: projects, by: -1)
        let docs = edited.tabs.first { $0.displayTitle == "Team Docs" }!.id
        edited.tabs.removeAll { $0.id == docs }
        let editedRows = rows(edited, work.id)
        // Add one new item to the source next to an existing one.
        let revised = standardFixture()
        revised.fixture.tab("Gamma Board", "https://board.example.com/g", in: revised.ids["projects"]!)
        let (merged, mergedReport) = ArcImport.apply(try ArcImport.parse(revised.fixture.json()), to: edited)
        expect(mergedReport.importedTabs == 1 && merged.tabs.count == edited.tabs.count + 1, "Only the new source item is imported")
        expect(!merged.tabs.contains { $0.displayTitle == "Team Docs" }, "Locally deleted items are not resurrected")
        expect(merged.folder(projects)?.name == "My Projects", "Local rename survives a repeat import")
        let mergedRows = rows(merged, work.id)
        expect(mergedRows.filter { $0 != "  Gamma Board" } == editedRows, "Local order survives a repeat import")
        expect(mergedRows.firstIndex(of: "  Gamma Board") == mergedRows.firstIndex(of: "  Beta Board")! + 1, "New item lands after its source sibling")

        // Renamed/copied source file: identity is the Arc item ID, not the path.
        let copy = fixtures.appendingPathComponent("Renamed Copy.json")
        try data.write(to: copy)
        let (fromCopy, _) = ArcImport.apply(try ArcImport.load(from: copy), to: restored)
        expect(fromCopy.tabs.count == restored.tabs.count, "A copied or renamed source adds nothing")

        // A removed imported Space stays removed when Arc has nothing new for it…
        var removed = restored
        let homeSpace = removed.spaces.first { $0.name == "Home" }!.id
        _ = removed.deleteSpace(id: homeSpace, movingTabsTo: work.id)
        removed.tabs.removeAll { $0.space == work.id && $0.title == "Recipes" }
        let spacesBefore = removed.spaces.count
        let (afterRemoval, removalReport) = ArcImport.apply(source, to: removed)
        expect(afterRemoval.spaces.count == spacesBefore && removalReport.removedSpaces == 1 && removalReport.importedTabs == 0,
               "A deleted imported Space is not recreated empty")
        // …but returns for genuinely new Arc items.
        let grown = standardFixture()
        let homePinned = (try ArcImport.parse(grown.fixture.json())).spaces[1].pinnedRoot!
        grown.fixture.tab("New Home Item", "https://new.example.com/", in: homePinned)
        let (regrown, regrownReport) = ArcImport.apply(try ArcImport.parse(grown.fixture.json()), to: removed)
        expect(regrown.spaces.count == spacesBefore + 1 && regrownReport.importedTabs == 1, "New items in a removed Space bring it back with only the new items")

        // Space selection is independent of Favorites orphan detection.
        var onlyWork = ArcImport.Options(); onlyWork.spaceIDs = [source.spaces[0].id]; onlyWork.includeUnattachedProfiles = true
        let (workOnly, workOnlyReport) = ArcImport.apply(source, to: BrowserSession.fresh(), options: onlyWork)
        expect(!workOnly.spaces.contains { $0.name == "Home" } && !workOnly.tabs.contains { $0.title == "Home Mail" },
               "Favorites of a left-out Space are not imported into a recovery Space")
        expect(workOnlyReport.excludedFavorites == 1 && workOnly.spaces.filter { $0.name.hasPrefix("Arc Favorites") }.count == 1,
               "Only true orphan profiles get recovery Spaces")

        // Damaged references are reported, not silently omitted; huge emoji codes don't trap.
        var damaged = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var dSidebar = damaged["sidebar"] as! [String: Any]; var dContainers = dSidebar["containers"] as! [Any]
        var dMain = dContainers[1] as! [String: Any]; var dSpaces = dMain["spaces"] as! [Any]
        var firstSpace = dSpaces[1] as! [String: Any]
        firstSpace["newContainerIDs"] = [["pinned": [:]], "missing-root", ["unpinned": [:]], "missing-today"] as [Any]
        firstSpace["customInfo"] = ["iconType": ["emoji": Int.max]]
        dSpaces[1] = firstSpace; dMain["spaces"] = dSpaces
        dMain["topAppsContainerIDs"] = (dMain["topAppsContainerIDs"] as! [Any]) + [["default": true], "missing-favorites"]
        dContainers[1] = dMain; dSidebar["containers"] = dContainers; damaged["sidebar"] = dSidebar
        let damagedSource = try ArcImport.parse(try JSONSerialization.data(withJSONObject: damaged))
        expect(damagedSource.spaces[0].emoji == nil, "Out-of-range numeric emoji is ignored safely")
        let (_, damagedReport) = ArcImport.apply(damagedSource, to: BrowserSession.fresh())
        expect(damagedReport.missingItems >= 3, "Missing pinned, Today and Favorites roots are reported")

        // Optional recovery of unattached profiles into their own Space and profile.
        var options = ArcImport.Options(); options.includeUnattachedProfiles = true
        let (recovered, recoveredReport) = ArcImport.apply(source, to: BrowserSession.fresh(), options: options)
        let recoverySpace = recovered.spaces.first { $0.name.hasPrefix("Arc Favorites") }
        expect(recoverySpace != nil && recoveredReport.unattachedProfiles == 0, "Recovery creates a Space for the other profile")
        expect(recovered.favorites(in: recoverySpace!.profileID).count == 3 && recoverySpace!.profileID != BrowserProfile.defaultID,
               "Recovered Favorites keep their own profile")

        // Options: Today can be left out.
        var noToday = ArcImport.Options(); noToday.includeToday = false
        let (withoutToday, _) = ArcImport.apply(source, to: BrowserSession.fresh(), options: noToday)
        expect(!withoutToday.tabs.contains { $0.title.hasPrefix("Today") }, "Excluding Today skips Today tabs")

        // Malformed and foreign inputs fail without partial import.
        func failure(_ data: Data) -> ArcImport.Failure? {
            do { _ = try ArcImport.parse(data); return nil } catch let error as ArcImport.Failure { return error } catch { return nil }
        }
        expect(failure(Data("not json".utf8)) == .notArcLayout, "Non-JSON rejected")
        let chromeLike = try JSONSerialization.data(withJSONObject: ["roots": [:]])
        expect(failure(chromeLike) == .notArcLayout, "Chrome-style JSON rejected")
        expect(failure(built.fixture.json(version: 9)) == .unsupportedVersion(9), "Unknown version rejected")
        var odd = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var sidebar = odd["sidebar"] as! [String: Any]; var containers = sidebar["containers"] as! [Any]
        var main = containers[1] as! [String: Any]; var items = main["items"] as! [Any]; items.removeLast()
        main["items"] = items; containers[1] = main; sidebar["containers"] = containers; odd["sidebar"] = sidebar
        if case .malformed = failure(try JSONSerialization.data(withJSONObject: odd)) {} else { expect(false, "Odd ID/object list rejected") }
        items = (main["items"] as! [Any]); items[0] = "mismatched-id"; main["items"] = items + [""]
        if case .malformed = failure(try JSONSerialization.data(withJSONObject: ["version": 1, "sidebar": ["containers": [["global": [:]], main]]])) {}
        else { expect(false, "Mismatched item identifier rejected") }

        // Damaged child lists and hostile nesting refuse the whole import.
        let badChildren = Fixture(); let badSpace = badChildren.space("Bad", profile: nil)
        var badRoot = badChildren.nodes[badSpace.pinned]!; badRoot["childrenIds"] = [1, 2]; badChildren.nodes[badSpace.pinned] = badRoot
        if case .malformed = failure(badChildren.json()) {} else { expect(false, "Non-string child IDs refused") }
        let hostile = Fixture(); let hostileSpace = hostile.space("Deep", profile: nil)
        var level = hostileSpace.pinned
        for _ in 0...(ArcImport.maximumNesting + 1) { level = hostile.node(["list": [:]], parent: level) }
        if case .malformed = failure(hostile.json()) {} else { expect(false, "Excessive nesting refused before traversal") }
        // A renamed Today tab keeps its Arc name.
        let renamed = Fixture(); let renamedSpace = renamed.space("Renamed", profile: nil)
        renamed.tab("Page Title", "https://renamed.example.com/", in: renamedSpace.unpinned, custom: "My Name")
        let (renamedSession, _) = ArcImport.apply(try ArcImport.parse(renamed.json()), to: BrowserSession.fresh())
        expect(renamedSession.tabs.contains { $0.title == "My Name" && !$0.isSaved }, "Renamed Today tab keeps its name")

        // Cycles and missing children are survived and reported.
        let cyclic = Fixture()
        let cycleSpace = cyclic.space("Loop", profile: nil)
        let outer = cyclic.folder("Outer", in: cycleSpace.pinned)
        let inner = cyclic.folder("Inner", in: outer)
        var innerNode = cyclic.nodes[inner]!; innerNode["childrenIds"] = [outer, "missing-child"]; cyclic.nodes[inner] = innerNode
        let (cycleSession, cycleReport) = ArcImport.apply(try ArcImport.parse(cyclic.json()), to: BrowserSession.fresh())
        expect(cycleReport.missingItems == 2 && cycleSession.folders.count == 2, "Cycle and missing child are reported, not looped")

        // Space limit: no partial Space creation beyond the cap.
        var crowded = BrowserSession.fresh()
        while crowded.spaces.count < BrowserSession.maximumSpaces - 1 { _ = crowded.createSpace(name: "S\(crowded.spaces.count)", symbol: "globe", colorIndex: 0) }
        let (capped, cappedReport) = ArcImport.apply(source, to: crowded)
        expect(capped.spaces.count == BrowserSession.maximumSpaces && cappedReport.skippedSpaces == 2, "Spaces beyond the limit are reported")

        // Large import stays bounded and dormant.
        let big = Fixture(); let bigSpace = big.space("Big", profile: nil)
        var parent = bigSpace.pinned
        for level in 0..<20 { parent = big.folder("Nest \(level)", in: parent); for n in 0..<40 { big.tab("Item \(level)-\(n)", "https://big.example.com/\(level)/\(n)", in: parent) } }
        let started = Date()
        let (bigSession, bigReport) = ArcImport.apply(try ArcImport.parse(big.json()), to: BrowserSession.fresh())
        expect(Date().timeIntervalSince(started) < 5, "800-tab import completes quickly")
        let bigID = bigSession.spaces.first { $0.name == "Big" }!.id
        let bigTabs = bigSession.tabs.filter { $0.space == bigID }
        expect(bigReport.depthLimited == 20 - BrowserSession.maximumFolderDepth && bigTabs.count == 800
               && bigSession.keptLayout(in: bigID).filter { !$0.isFolder }.count == 800,
               "Over-deep folders fold into their nearest allowed parent without losing tabs")
        expect(bigTabs.allSatisfy(\.isUnloaded), "Hundreds of imported tabs stay dormant")

        print("PASS: \(count) Arc import checks")
    }
}
