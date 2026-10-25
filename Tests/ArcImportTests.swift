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
        @discardableResult func space(_ title: String, profile: String?, emoji: Any? = nil, theme: (Double, Double, Double)? = nil, legacy: Bool = false,
                                      windowTheme: [String: Any]? = nil) -> (pinned: String, unpinned: String) {
            let id = newID()
            let pinned = container(["spaceItems": ["_0": id]]), unpinned = container(["spaceItems": ["_0": id]])
            var icon: [String: Any] = [:]
            if let text = emoji as? String { icon["emoji_v2"] = text } else if let code = emoji as? Int { icon["emoji"] = code }
            var custom: [String: Any] = ["iconType": icon]
            if let (r, g, b) = theme {
                custom["windowTheme"] = ["primaryColorPalette": ["midTone": ["red": r, "green": g, "blue": b, "alpha": 1, "colorSpace": "extendedSRGB"]]]
            }
            if let windowTheme { custom["windowTheme"] = windowTheme }
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
                print("space \(index): kept \(space.keptTabs), folders \(space.folders), today \(space.todayTabs), favorites \(space.favorites), splits \(space.splits), easel refs \(space.easels), emoji \(space.emoji != nil), theme \(space.theme)")
            }
            // Theme shape and contrast only, never color values.
            for theme in session.spaces.compactMap(\.theme) {
                let contrast = [false, true].map { dark in
                    theme.canvasStops(dark: dark).map { $0.contrast(with: (dark ? theme.dark : theme.light).title) }.min() ?? 0
                }
                print("theme: gradient stops \(theme.gradient.count), min text contrast light \(String(format: "%.1f", contrast[0])) dark \(String(format: "%.1f", contrast[1]))")
            }
            print("themes imported \(report.importedThemes), unreadable \(report.approximatedThemes)")
            print("tabs \(report.importedTabs), folders \(report.importedFolders), profiles new \(report.newProfiles.count), easel refs \(report.easelReferences), easels unplaced \(report.easels), live \(report.liveFolders), overflow \(report.favoriteOverflow), unattached \(report.unattachedProfiles)/\(report.unattachedFavorites), invalid \(report.invalidAddresses), missing \(report.missingItems), unknown \(report.unknownItems), depth \(report.depthLimited), refused \(report.refusal != nil)")
            print("max depth \(session.folders.map { session.folderDepth($0.id) }.max() ?? -1), dormant kept \(session.tabs.filter { $0.saved?.kind == .kept && !$0.isUnloaded }.count == 3)")
            let layout = URL(fileURLWithPath: arguments[2])
            if let directory = ArcIconImport.cacheDirectory(besideLayout: layout) {
                let added = ArcIconImport.addedTabs(before: nil, after: session.importLinks)
                print("icons \(ArcIconImport.loadIcons(for: added, in: directory).count)/\(added.count) imported tabs")
            } else { print("icons: no cache beside layout") }
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
                              "[Empty]", "Alpha Board copy", "Sketch", "Left Pane", "[Pull Requests]", "  PR 1", "Wide 1", "Wide 3"]
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
        expect(report.easelReferences == 1 && report.easels == 0 && report.liveFolders == 1 && report.invalidAddresses == 1,
               "Easel kept as a reference; live folder and file URL reported")
        let sketch = session.tabs.first { $0.title == "Sketch" }!
        expect(sketch.isArcEasel && sketch.saved?.kind == .kept && sketch.isUnloaded && session.split(for: sketch.id) == nil,
               "The Easel row is a dormant kept reference, never a web page")
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

        // Arrival: exactly one blank landing tab, whether or not the Space has a selectable tab.
        for includeToday in [true, false] {
            var arrival = ArcImport.Options(); arrival.includeToday = includeToday
            var landed = ArcImport.apply(source, to: BrowserSession.fresh(), options: arrival).session
            let before = Set(landed.tabs.map(\.id))
            let target = landed.spaces.first { $0.name == "Work" }!.id
            ArcImport.arrive(at: target, in: &landed)
            let added = landed.tabs.filter { !before.contains($0.id) }
            expect(added.count == 1 && added[0].isHome && landed.activeID == added[0].id && landed.space == target,
                   "Arrival creates exactly one blank tab (Today \(includeToday ? "on" : "off")): \(added.count)")
            expect(!landed.tabs.contains { before.contains($0.id) && $0.space == target && $0.id == landed.activeID },
                   "No imported tab is selected on arrival (Today \(includeToday ? "on" : "off"))")
        }

        // Undo after a failed save removes exactly the import, keeping later user changes.
        var afterImport = session
        let userTab = afterImport.add(address: "https://user.example.com/")
        let undone = ArcImport.undo(session, over: existing, in: afterImport)
        expect(Set(undone.spaces.map(\.id)) == Set(existing.spaces.map(\.id)) && undone.profiles.map(\.id) == existing.profiles.map(\.id),
               "Undo removes imported Spaces and profiles")
        expect(undone.folders.isEmpty && undone.importLinks == nil, "Undo removes imported folders and provenance")
        expect(existing.tabs.allSatisfy { tab in undone.tabs.contains { $0.id == tab.id } }, "Undo keeps every pre-import tab")
        expect(!undone.tabs.contains { tab in !existing.tabs.contains { $0.id == tab.id } && tab.id != userTab }, "Undo removes every imported tab")
        // A tab the user opened after the import survives the undo.
        expect(undone.tabs.contains { $0.id == userTab } && undone.spaceDefinition(undone.tabs.first { $0.id == userTab }!.space) != nil,
               "A Space the user filled after import keeps the user's tab")

        var filled = session
        filled.changeSpace(work.id)
        let inWork = filled.add(address: "https://work-note.example.com/")
        let keptSpace = ArcImport.undo(session, over: existing, in: filled)
        expect(keptSpace.tabs.first { $0.id == inWork }?.space == work.id && keptSpace.spaceDefinition(work.id) != nil
               && !keptSpace.tabs.contains { $0.title == "Team Docs" || $0.displayTitle == "Team Docs" },
               "An imported Space the user added a tab to is kept, minus the imported tabs")

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

        // Easels: kept as reference rows in place, with titles and identity.
        let easels = Fixture(); let easelSpace = easels.space("Canvas", profile: nil)
        let easelOuter = easels.folder("Outer", in: easelSpace.pinned), mid = easels.folder("Mid", in: easelOuter), deepFolder = easels.folder("Deep", in: mid)
        easels.tab("Before", "https://before.example/", in: deepFolder)
        let easelUUID = UUID()
        let payloadOnly = easels.node(["easel": ["easelID": easelUUID.uuidString, "title": "Payload Title", "creatorID": "x", "shareStatus": "y", "timeLastActiveAt": 0.0]],
                                      parent: deepFolder, title: nil)
        easels.tab("After", "https://after.example/", in: deepFolder)
        let renamedEasel = easels.node(["easel": ["easelID": UUID().uuidString, "title": "Old"]], parent: easelSpace.pinned, title: "Renamed In Arc")
        easels.node(["easel": ["easelID": "not-a-uuid"]], parent: easelSpace.pinned, title: nil)          // no title, odd ID
        easels.node(["easel": [:]], parent: easelSpace.unpinned, title: nil)                                // Today, nothing at all
        let easelSource = try ArcImport.parse(easels.json())
        let (easelSession, easelReport) = ArcImport.apply(easelSource, to: BrowserSession.fresh())
        let canvas = easelSession.spaces.first { $0.name == "Canvas" }!.id
        expect(rows(easelSession, canvas) == ["[Outer]", "  [Mid]", "    [Deep]", "      Before", "      Payload Title", "      After",
                                              "Renamed In Arc", "Arc Easel"],
               "Easels keep their exact folder and order, between their sibling tabs: \(rows(easelSession, canvas))")
        let payloadRow = easelSession.tabs.first { $0.title == "Payload Title" }!
        expect(ArcEaselReference.easelID(payloadRow.address) == easelUUID && payloadRow.isUnloaded,
               "Null top-level title uses the Easel's own title; its Easel ID is kept as identity")
        expect(easelSession.importLinks?["arc:\(payloadOnly)"] == "tab:\(payloadRow.id.uuidString)", "Source sidebar identity is kept in provenance")
        // The name survives the row being navigated to a page (which retitles
        // the tab) and then reset back to its reference.
        var wandered = easelSession
        let wanderIndex = wandered.tabs.firstIndex { $0.id == payloadRow.id }!
        wandered.tabs[wanderIndex].address = "https://example.invalid/elsewhere"; wandered.tabs[wanderIndex].title = "Some Page Title"
        expect(wandered.tabs[wanderIndex].displayTitle == "Payload Title", "A page's title doesn't replace the Easel's name on its kept row")
        expect(payloadRow.addressLabel == "Arc Easel" && ArcEaselReference.isReference(payloadRow.address),
               "The address bar shows a plain name for an Easel row; its reference address is unchanged")
        expect(wandered.tabs[wanderIndex].addressLabel == "example.invalid", "A row navigated to a page shows that page's host")
        expect(wandered.resetSavedTab(id: payloadRow.id), "Reset accepts an Easel reference")
        expect(wandered.tabs[wanderIndex].address == payloadRow.address && wandered.tabs[wanderIndex].displayTitle == "Payload Title",
               "Reset restores the reference and its name")
        expect(easelSession.tabs.contains { $0.title == "Renamed In Arc" && $0.isArcEasel }, "An Arc rename wins over the Easel's title")
        expect(easelSession.tabs.filter { $0.title == "Arc Easel" }.count == 2, "Missing titles fall back to a clear generic name")
        expect(easelSession.tabs.contains { $0.isArcEasel && !$0.isSaved && $0.space == canvas }, "A Today Easel stays in Today as a reference")
        expect(easelReport.easelReferences == 4 && easelReport.easels == 0 && easelReport.spaces.first?.easels == 4, "Every Easel is counted as kept")
        expect(easelReport.notices.contains { $0.contains("4 Easels will be kept as references") && $0.contains("stay in Arc") },
               "The preview says Easels are references and their canvases aren't imported")
        expect(!easelSession.tabs.contains { $0.isArcEasel && (URL(string: $0.address)?.scheme == "https" || URL(string: $0.address)?.scheme == "http") },
               "No web address is invented for an Easel")
        // Persistence and model behavior.
        let easelFile = fixtures.appendingPathComponent("easels.json")
        try SessionFile.save(easelSession, to: easelFile)
        var reloaded = SessionFile.load(easelFile)
        expect(reloaded.tabs.filter(\.isArcEasel).count == 4 && rows(reloaded, canvas) == rows(easelSession, canvas), "Easel rows survive restart")
        expect(!reloaded.makeSplit(primary: payloadRow.id, secondary: reloaded.tabs.first { $0.title == "Before" }!.id), "Easels can't join a Split")
        // Repeat import after local rename, move and delete: nothing comes back, nothing duplicates.
        let renamedRow = reloaded.tabs.first { $0.title == "Renamed In Arc" }!.id
        _ = reloaded.updateSavedTab(id: renamedRow, customTitle: "My Canvas", customSymbol: nil)
        _ = reloaded.drop(payloadRow.id, at: .keptEnd, space: canvas)
        let deletedEasel = reloaded.tabs.first { $0.title == "Arc Easel" && $0.isSaved }!.id
        _ = reloaded.setRetention(id: deletedEasel, kind: nil); _ = reloaded.close(deletedEasel)
        let (again2, againReport2) = ArcImport.apply(easelSource, to: reloaded)
        expect(again2.tabs.filter(\.isArcEasel).count == 3 && againReport2.easelReferences == 0 && againReport2.isEmpty,
               "Repeat import keeps local rename/move/delete of Easel rows and adds none")
        expect(again2.tabs.first { $0.id == renamedRow }?.displayTitle == "My Canvas" && rows(again2, canvas).last == "Payload Title",
               "Local rename and move survive")
        expect(againReport2.emptyReason == "All supported sidebar items in this layout are already in Bam.", "Repeat wording is precise")
        // Ungrouping a folder keeps its Easel row in place.
        var dissolved = again2
        let deepID = dissolved.folders.first { $0.name == "Deep" }!.id
        _ = dissolved.drop(payloadRow.id, at: .into(deepID), space: canvas)
        expect(dissolved.ungroupFolder(id: deepID) && dissolved.tabs.contains { $0.id == payloadRow.id && $0.folderID == dissolved.folders.first { $0.name == "Mid" }!.id },
               "Dissolving a folder keeps its Easel row with the other rows")

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

        var full = crowded; _ = full.createSpace(name: "Last", symbol: "globe", colorIndex: 0)
        let (_, fullReport) = ArcImport.apply(source, to: full, options: noToday)
        expect(fullReport.isEmpty && fullReport.emptyReason.contains("limit"), "A full Space list explains why nothing is added")
        expect(againReport.isEmpty && againReport.emptyReason.contains("already"), "A repeat import says everything is already in Bam")

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

        try themeChecks(fixtures)
        print("PASS: \(count) Arc import checks")
    }

    /// An original synthetic Arc window theme with the real schema's shape.
    static func arcTheme(gradient: [(Double, Double, Double)] = [(0.62, 0.78, 0.96), (0.95, 0.70, 0.80)],
                         colorSpace: String = "extendedSRGB", blended: Bool = true) -> [String: Any] {
        func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> [String: Any] {
            ["red": r, "green": g, "blue": b, "alpha": a, "colorSpace": colorSpace]
        }
        func roles(dark: Bool) -> [String: Any] {
            let bg = dark ? c(0.10, 0.10, 0.13) : c(0.95, 0.94, 0.97), ink = dark ? c(0.95, 0.95, 0.97) : c(0.08, 0.08, 0.10)
            return ["background": bg, "backgroundExtra": dark ? c(0.14, 0.13, 0.17) : c(0.99, 0.98, 1.0), "title": ink,
                    "subtitle": dark ? c(0.70, 0.70, 0.74) : c(0.35, 0.35, 0.40), "focus": c(0.40, 0.55, 0.90, 0.8),
                    "hover": c(0.5, 0.5, 0.5, 0.48), "foregroundPrimary": ink, "foregroundSecondary": c(0.6, 0.6, 0.6),
                    "foregroundTertiary": c(0.7, 0.7, 0.7), "cutoutColor": bg, "maxContrastColor": ink, "minContrastColor": bg]
        }
        let style: [String: Any] = blended
            ? ["color": ["_0": ["blendedGradient": ["_0": [
                "baseColors": gradient.map { c($0.0, $0.1, $0.2) }, "overlayColors": [Any](), "translucencyStyle": "light",
                "modifiers": ["intensityFactor": 0.0, "noiseFactor": 0.0, "overlay": "grain"], "wheel": ["complimentary": [:]]]]]]]
            : ["image": ["_0": ["name": "synthetic"]]]
        return [
            "primaryColorPalette": ["midTone": c(0.40, 0.55, 0.90), "shaded": c(0.30, 0.40, 0.70),
                                    "shadedDark": c(0.12, 0.16, 0.30), "tintedLight": c(0.80, 0.86, 0.98)],
            "semanticColorPalette": ["appearanceBased": ["light": roles(dark: false), "dark": roles(dark: true)]],
            "background": ["single": ["_0": ["style": style, "isVibrant": true, "contentOverBackgroundAppearance": "light"]]]
        ]
    }

    static func themeChecks(_ fixtures: URL) throws {
        // Full theme: typed, per appearance, with its two gradient colors.
        let themed = Fixture(); let themedSpace = themed.space("Themed", profile: nil, windowTheme: arcTheme())
        themed.tab("Inside", "https://inside.example/", in: themedSpace.pinned)
        themed.space("Plain", profile: nil)
        let source = try ArcImport.parse(themed.json())
        let (session, report) = ArcImport.apply(source, to: BrowserSession.fresh())
        let space = session.spaces.first { $0.name == "Themed" }!, plain = session.spaces.first { $0.name == "Plain" }!
        guard let theme = space.theme else { expect(false, "A complete Arc theme is imported"); return }
        expect(theme.gradient.count == 2 && theme.light != theme.dark && theme.accentLight != nil && theme.accentDark != nil,
               "Theme keeps both gradient colors, separate light/dark roles and accent variants")
        expect(space.colorIndex == 2 && plain.theme == nil, "A themed Space keeps the nearest flat color as fallback; an unthemed one has none")
        expect(report.importedThemes == 1 && report.approximatedThemes == 0
               && report.notices.contains { $0.contains("1 Space keeps its Arc theme colors and gradient") && $0.contains("grain and vibrancy aren’t reproduced") },
               "The preview says the theme comes over and what doesn't")

        // Drawing: readable text over every gradient color in both appearances,
        // a real two-color gradient, a dark window in dark, accent visible.
        for dark in [false, true] {
            let roles = dark ? theme.dark : theme.light, stops = theme.canvasStops(dark: dark)
            expect(stops.count == 2 && stops[0] != stops[1], "Two distinct gradient colors (dark: \(dark))")
            expect(stops.allSatisfy { $0.contrast(with: roles.title) >= SpaceTheme.minimumTextContrast }, "Title text stays readable over the gradient (dark: \(dark))")
            expect(stops.allSatisfy { $0.contrast(with: theme.accent(dark: dark)) >= SpaceTheme.minimumIconContrast - 0.001 }, "The Space accent stands out (dark: \(dark))")
        }
        expect(theme.canvasStops(dark: true).allSatisfy { $0.luminance < 0.2 } && theme.canvasStops(dark: false).allSatisfy { $0.luminance > 0.5 },
               "Dark mode gets a dark window, light mode a light one")
        let gray = try ArcImport.parse({ let f = Fixture(); f.space("Gray", profile: nil, windowTheme: arcTheme(gradient: [(0.5, 0.5, 0.5), (0.45, 0.45, 0.45)])); return f.json() }())
        let grayTheme = gray.spaces[0].theme!
        for dark in [false, true] {
            expect(grayTheme.canvasStops(dark: dark).allSatisfy { $0.contrast(with: (dark ? grayTheme.dark : grayTheme.light).title) >= SpaceTheme.minimumTextContrast },
                   "A mid-gray gradient is eased until text reads (dark: \(dark))")
        }

        // Fallbacks: unknown color space, unknown background variant, partial theme.
        let p3 = try ArcImport.parse({ let f = Fixture(); f.space("P3", profile: nil, windowTheme: arcTheme(colorSpace: "displayP3")); return f.json() }())
        let (p3Session, p3Report) = ArcImport.apply(p3, to: BrowserSession.fresh())
        expect(p3.spaces[0].theme == nil && p3Session.spaces.first { $0.name == "P3" }?.theme == nil && p3Report.approximatedThemes == 1
               && p3Report.notices.contains { $0.contains("couldn’t be read") }, "An unknown color space falls back to the flat color, with a notice")
        let image = try ArcImport.parse({ let f = Fixture(); f.space("Image", profile: nil, windowTheme: arcTheme(blended: false)); return f.json() }())
        let imageTheme = image.spaces[0].theme
        expect(imageTheme?.gradient.isEmpty == true && imageTheme.map { $0.canvasStops(dark: false)[0] == $0.light.background.mixed(toward: $0.light.background, by: 1) } == true,
               "An unknown background variant keeps the theme's colors over its own backgrounds")
        var partial = arcTheme(); partial["semanticColorPalette"] = ["appearanceBased": ["light": (arcTheme()["semanticColorPalette"] as! [String: Any])]]
        expect(ArcImport.spaceTheme(partial) == nil && ArcImport.spaceTheme(["primaryColorPalette": ["midTone": ["red": 2.0, "green": 0, "blue": 0]]]) == nil,
               "Missing appearances or out-of-range colors aren't imported")

        // Persistence: restart, sanitize, Space edits.
        let file = fixtures.appendingPathComponent("themes.json")
        try SessionFile.save(session, to: file)
        var restored = SessionFile.load(file)
        expect(restored.spaceDefinition(space.id)?.theme == theme, "The theme survives restart exactly")
        restored.sanitize()
        expect(restored.spaceDefinition(space.id)?.theme == theme, "Sanitizing keeps a valid theme")
        expect(restored.updateSpace(id: space.id, name: "Renamed", symbol: "book", colorIndex: space.colorIndex)
               && restored.spaceDefinition(space.id)?.theme == theme, "Renaming or a new icon keeps the theme")
        var recolored = restored
        expect(recolored.updateSpace(id: space.id, name: "Renamed", symbol: "book", colorIndex: 4) && recolored.spaceDefinition(space.id)?.theme == nil,
               "Choosing another Space color replaces the imported theme")
        var prism = restored
        expect(prism.updateSpace(id: space.id, name: "Renamed", symbol: "book", colorIndex: BrowserSpace.prismColorIndex)
               && prism.spaceDefinition(space.id)?.theme == nil && !prism.setSpaceTheme(id: space.id, theme: theme),
               "Prism and Clear never carry an imported theme")
        expect(BrowserSpace(id: 9, name: "X", symbol: "globe", colorIndex: BrowserSpace.clearColorIndex, theme: theme).theme == nil, "The model refuses a theme on Clear")

        // A damaged stored theme falls back to the flat color without losing the Space.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var spaces = json["spaces"] as! [[String: Any]]
        let themedIndex = spaces.firstIndex { ($0["id"] as? Int) == space.id }!
        var stored = spaces[themedIndex]["theme"] as! [String: Any]
        var accent = stored["accent"] as! [String: Any]; accent["red"] = 1.7; stored["accent"] = accent
        spaces[themedIndex]["theme"] = stored; json["spaces"] = spaces
        let damagedFile = fixtures.appendingPathComponent("themes-damaged.json")
        try JSONSerialization.data(withJSONObject: json).write(to: damagedFile)
        let damaged = SessionFile.load(damagedFile)
        expect(damaged.spaceDefinition(space.id)?.theme == nil && damaged.spaceDefinition(space.id)?.colorIndex == space.colorIndex
               && damaged.tabs.count == session.tabs.count, "A damaged stored theme falls back to the flat color; nothing else is lost")

        // Repeat import: nothing new; a Space imported before themes existed
        // gets its theme once, unless its color was changed locally.
        let (again, againReport) = ArcImport.apply(source, to: session)
        expect(againReport.isEmpty && againReport.importedThemes == 0 && again.spaces == session.spaces, "Importing again changes nothing")
        var older = session
        _ = older.setSpaceTheme(id: space.id, theme: nil); older.importLinks?.removeValue(forKey: "arc-theme:\(source.spaces[0].id)")
        let (upgraded, upgradeReport) = ArcImport.apply(source, to: older)
        expect(report.spaces.first { $0.title == "Themed" }?.theme == true && report.spaces.first { $0.title == "Plain" }?.theme == false,
               "The preview marks which Space gets a theme")
        expect(upgraded.spaceDefinition(space.id)?.theme == theme && upgradeReport.importedThemes == 1 && !upgradeReport.isEmpty
               && upgradeReport.spaces.first { $0.title == space.name }?.theme == true,
               "An earlier-imported Space still wearing Bam's chosen color gets its theme")
        var recoloredOlder = older
        _ = recoloredOlder.updateSpace(id: space.id, name: space.name, symbol: space.symbol, colorIndex: 4)
        expect(ArcImport.apply(source, to: recoloredOlder).session.spaceDefinition(space.id)?.theme == nil, "A locally chosen color is never overridden")
        var removedLocally = upgraded
        _ = removedLocally.updateSpace(id: space.id, name: space.name, symbol: space.symbol, colorIndex: 4)
        _ = removedLocally.updateSpace(id: space.id, name: space.name, symbol: space.symbol, colorIndex: space.colorIndex)
        expect(ArcImport.apply(source, to: removedLocally).session.spaceDefinition(space.id)?.theme == nil,
               "A theme the user replaced isn't brought back by a later import")
        // Undo after a failed save removes a theme the import added to an existing Space.
        let undone = ArcImport.undo(upgraded, over: older, in: upgraded)
        expect(undone.spaceDefinition(space.id)?.theme == nil && undone.importLinks == older.importLinks, "Undo removes the added theme")
    }
}
