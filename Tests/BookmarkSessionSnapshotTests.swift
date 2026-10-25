import Foundation

/// The session → bookmarks.getTree input adapter, on a synthetic two-profile session, checked both as input
/// and through the extension owner's ExtensionBookmarkTree model (the tree an extension would receive).
@main enum BookmarkSessionSnapshotTests {
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        typealias Tree = ExtensionBookmarkTree
        var session = BrowserSession.fresh()
        let profileA = BrowserProfile.defaultID
        let profileB = session.createProfile(name: "Work")!
        session.tabs = []
        session.spaces = []
        _ = session.createSpace(name: "Alpha", symbol: "globe", colorIndex: 0, profileID: profileA)
        _ = session.createSpace(name: "Beta", symbol: "globe", colorIndex: 1, profileID: profileA)
        _ = session.createSpace(name: "Other", symbol: "globe", colorIndex: 2, profileID: profileB)
        let alpha = session.spaces[0].id, beta = session.spaces[1].id, other = session.spaces[2].id

        func kept(_ title: String, _ address: String, space: Int, folder: UUID? = nil, custom: String? = nil) -> BrowserTab {
            BrowserTab(title: title, address: address, space: space,
                       saved: SavedTabState(kind: .kept, address: address, customTitle: custom), folderID: folder)
        }
        func favorite(_ title: String, _ address: String, profile: UUID) -> BrowserTab {
            BrowserTab(title: title, address: address, space: alpha, saved: SavedTabState(kind: .favorite, address: address, profileID: profile))
        }
        let favA1 = favorite("Mail", "https://mail.example/", profile: profileA)
        let favB = favorite("Other mail", "https://other-mail.example/", profile: profileB)
        let favA2 = favorite("Calendar", "https://calendar.example/", profile: profileA)
        let projects = BrowserFolder(name: "Projects", space: alpha)
        let nested = BrowserFolder(name: "Nested", space: alpha, parentID: projects.id)
        let otherFolder = BrowserFolder(name: "Other folder", space: other)
        // Detached cycle (corrupt data): neither is reachable from a root, and traversal must still end.
        var loopA = BrowserFolder(name: "Loop A", space: alpha), loopB = BrowserFolder(name: "Loop B", space: alpha)
        loopA.parentID = loopB.id; loopB.parentID = loopA.id
        var navigated = kept("Docs", "https://docs.example/start", space: alpha, custom: "Team Docs")
        navigated.address = "https://docs.example/somewhere-else"; navigated.title = "Somewhere else"
        let inFolder = kept("Spec", "https://spec.example/", space: alpha, folder: projects.id)
        let deep = kept("Deep", "https://deep.example/", space: alpha, folder: nested.id)
        let easel = kept("Sketch", ArcEaselReference.address(for: UUID()), space: alpha)
        let orbit = kept("Home", "orbit://newtab", space: alpha)
        let today = BrowserTab(title: "Loose", address: "https://loose.example/", space: alpha)
        let left = kept("Left", "https://left.example/", space: beta), right = kept("Right", "https://right.example/", space: beta)
        let lonePrimary = kept("Lone", "https://lone.example/", space: beta)
        let unsavedSecondary = BrowserTab(title: "Unsaved pane", address: "https://unsaved.example/", space: beta)
        let otherTab = kept("Secret", "https://secret.example/", space: other, folder: otherFolder.id)
        session.tabs = [favA1, favB, favA2, navigated, inFolder, deep, easel, orbit, today, left, right, lonePrimary, unsavedSecondary, otherTab]
        session.folders = [projects, nested, otherFolder, loopA, loopB]
        session.splits = [BrowserSplit(primaryID: left.id, secondaryID: right.id), BrowserSplit(primaryID: lonePrimary.id, secondaryID: unsavedSecondary.id)]

        guard let input = BookmarkSessionSnapshot.input(from: session, profileID: profileA) else { fatalError("Profile A produced no input") }
        require(input.favorites.map(\.id) == [favA1.id, favA2.id], "Only profile A's Favorites, in order")
        require(input.spaces.map(\.id) == [alpha, beta], "Only profile A's Spaces, in sidebar order")
        let alphaChildren = input.spaces[0].children
        let page = alphaChildren.compactMap { child -> Tree.Page? in if case .page(let p) = child { return p }; return nil }
        require(page.map(\.id) == [navigated.id], "Alpha's root holds its kept web page only (no Easel, orbit or Today rows)")
        require(page.first?.address == "https://docs.example/start" && page.first?.title == "Team Docs",
                "The kept (saved) address and the custom title are used, not where the tab has navigated")
        require(alphaChildren.contains(.folder(projects.id)) && !alphaChildren.contains(.folder(loopA.id)), "The root folder is referenced; a detached cycle isn't")
        let folderIDs = Set(input.folders.map(\.id))
        require(folderIDs == [projects.id, nested.id], "Folders collected once each, only reachable ones in A's Spaces")
        let projectsFolder = input.folders.first { $0.id == projects.id }!
        require(projectsFolder.children.contains(.folder(nested.id)) && projectsFolder.children.contains(.page(.init(id: inFolder.id, title: "Spec", address: "https://spec.example/"))),
                "Folder children: nested folder and its kept page")
        let betaChildren = input.spaces[1].children
        require(betaChildren.first == .split(primary: .init(id: left.id, title: "Left", address: "https://left.example/"),
                                             secondary: .init(id: right.id, title: "Right", address: "https://right.example/")),
                "A kept Split is primary then secondary, each with its own ID")
        require(betaChildren.contains(.page(.init(id: lonePrimary.id, title: "Lone", address: "https://lone.example/")))
                && !betaChildren.contains { if case .split(let p, _) = $0 { return p.id == lonePrimary.id }; return false },
                "A Split whose secondary isn't saved gives the primary alone")
        let allIDs = input.favorites.map(\.id) + input.spaces.flatMap(\.children).flatMap(Self.pageIDs) + input.folders.flatMap(\.children).flatMap(Self.pageIDs)
        require(!allIDs.contains(favB.id) && !allIDs.contains(otherTab.id) && !allIDs.contains(today.id) && !allIDs.contains(easel.id)
                && !allIDs.contains(unsavedSecondary.id) && Set(allIDs).count == allIDs.count,
                "No other profile, Today, Easel or unsaved tab; every page ID once")

        // Through the extension owner's model: the tree an extension receives.
        guard case .success(let tree) = Tree.tree(input) else { fatalError("The model rejected a consistent input") }
        let json = String(data: try! JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]), encoding: .utf8)!
        require(json.contains("\"id\":\"favorites\"") && json.contains("\"id\":\"space-\(alpha)\"") && !json.contains("space-\(other)"),
                "Tree has Favorites and only A's Spaces")
        require(!json.contains("secret.example") && !json.contains("other-mail") && !json.contains("loose.example") && !json.contains("arc-easel")
                && !json.contains("somewhere-else") && !json.contains("dateAdded"),
                "No other profile, Today, Easel or navigated address, and no invented dates")
        guard case .success(let again) = Tree.tree(BookmarkSessionSnapshot.input(from: session, profileID: profileA)!) else { fatalError("Rebuild failed") }
        require(NSDictionary(dictionary: tree).isEqual(to: again), "Rebuilding gives the same tree (stable IDs and order)")
        var renamed = session; renamed.folders[0].name = "Renamed"
        guard case .success(let afterRename) = Tree.tree(BookmarkSessionSnapshot.input(from: renamed, profileID: profileA)!) else { fatalError("Rename rebuild failed") }
        let renamedJSON = String(data: try! JSONSerialization.data(withJSONObject: afterRename, options: [.sortedKeys]), encoding: .utf8)!
        require(renamedJSON.contains(projects.id.uuidString) && renamedJSON.contains("Renamed"), "A renamed folder keeps its ID")

        // Profile B sees only its own items.
        let inputB = BookmarkSessionSnapshot.input(from: session, profileID: profileB)!
        require(inputB.favorites.map(\.id) == [favB.id] && inputB.spaces.map(\.id) == [other] && inputB.folders.map(\.id) == [otherFolder.id],
                "Profile B: its Favorite, Space and folder only")
        require(BookmarkSessionSnapshot.input(from: session, profileID: UUID()) == nil, "An unknown profile gives nil (an error, not an empty tree)")
        // The hook's entry point (review of f6b2106): nothing while closing or mid profile change.
        let hook = { (closing: Bool, switching: Bool) in
            BookmarkSessionSnapshot.input(from: session, profileID: profileA, isShuttingDown: closing, isApplyingProfileChange: switching)
        }
        require(hook(false, false) == input, "In a steady state the hook returns the profile's snapshot")
        require(hook(false, true) == nil, "While a profile change is being applied the hook returns nil (an error, not a mid-transition tree)")
        require(hook(true, false) == nil && hook(true, true) == nil, "While closing the hook returns nil")

        // Limits before traversal: over the model's input budget, nothing is collected.
        var huge = session
        huge.tabs += (0...Tree.maximumInputItems).map { kept("Bulk \($0)", "https://bulk.example/\($0)", space: alpha) }
        var hugeWork = BookmarkSessionSnapshot.Work()
        require(BookmarkSessionSnapshot.input(from: huge, profileID: profileA, work: &hugeWork) == nil && hugeWork.containersExpanded == 0,
                "More candidates than the budget gives nil before any container is expanded")
        var justUnder = session
        // The model's Builder counts every input node: 2 Favorites + 2 Space nodes + Alpha's 1 page and Projects folder
        // + Beta's Split (2 pages) and Lone + Projects' Nested and Spec + Nested's Deep = 14 (Easel/orbit aren't supplied).
        let room = Tree.maximumInputItems - 14
        justUnder.tabs += (0..<room).map { kept("Bulk \($0)", "https://bulk.example/\($0)", space: beta) }
        require(BookmarkSessionSnapshot.input(from: justUnder, profileID: profileA) != nil, "Within the budget the snapshot is built")
        var oneOver = justUnder; oneOver.tabs.append(kept("One more", "https://bulk.example/over", space: beta))
        require(BookmarkSessionSnapshot.input(from: oneOver, profileID: profileA) == nil, "One candidate over the budget gives nil")

        // Review of f6b2106 (P2): same result as the session's own keptChildren, including stored order.
        var ordered = session
        let extra = kept("Late", "https://late.example/", space: alpha, folder: projects.id)
        ordered.tabs.append(extra)
        ordered.rootOrder = [alpha: [projects.id, UUID(), navigated.id, projects.id]]   // stale and repeated IDs are ignored
        ordered.folders[0].childOrder = [extra.id, nested.id]                            // inFolder isn't listed: it follows
        require(BookmarkSessionSnapshot.input(from: ordered, profileID: profileA) == Self.reference(ordered, profileA),
                "Indexed snapshot equals the keptChildren-based reference, with stored orders")
        require(BookmarkSessionSnapshot.input(from: session, profileID: profileA) == Self.reference(session, profileA)
                && BookmarkSessionSnapshot.input(from: session, profileID: profileB) == Self.reference(session, profileB),
                "And for both profiles of the base session")

        // Many folders plus many irrelevant tabs: one pass over each collection, one expansion per reached container.
        var wide = session
        let wideFolders = (0..<1_000).map { BrowserFolder(name: "F\($0)", space: alpha) }
        wide.folders += wideFolders
        wide.tabs += wideFolders.map { kept("In \($0.name)", "https://in.example/\($0.id)", space: alpha, folder: $0.id) }
        wide.tabs += (0..<20_000).map { BrowserTab(title: "Noise \($0)", address: "https://noise.example/\($0)", space: other) }  // other profile, Today
        var wideWork = BookmarkSessionSnapshot.Work()
        let wideInput = BookmarkSessionSnapshot.input(from: wide, profileID: profileA, work: &wideWork)
        require(wideInput != nil && wideInput == Self.reference(wide, profileA), "Wide session still matches the reference")
        require(wideWork.tabsScanned == wide.tabs.count && wideWork.foldersScanned == wide.folders.count
                && wideWork.splitsScanned == (wide.splits ?? []).count,
                "Each session collection is scanned exactly once, however many folders: \(wideWork)")
        require(wideWork.containersExpanded == 2 + 2 + 1_000,
                "One expansion per Space and per reachable folder (2 Spaces + Projects/Nested + 1,000), not per tab: \(wideWork)")

        // Review of 4731e41: every retained saved tab counts, Split secondaries included, before allocation;
        // a corrupt session of only secondaries over the budget is refused in the tab pass.
        var secondariesOnly = session
        let orphans = (0...Tree.maximumInputItems).map { kept("Pane \($0)", "https://pane.example/\($0)", space: alpha) }
        secondariesOnly.tabs += orphans
        secondariesOnly.splits = (secondariesOnly.splits ?? []) + orphans.map { BrowserSplit(primaryID: UUID(), secondaryID: $0.id) }
        var orphanWork = BookmarkSessionSnapshot.Work()
        require(BookmarkSessionSnapshot.input(from: secondariesOnly, profileID: profileA, work: &orphanWork) == nil
                && orphanWork.splitsIndexed == 0 && orphanWork.containersExpanded == 0,
                "Over 10k saved Split secondaries: nil before any split is indexed or container expanded: \(orphanWork)")
        // Irrelevant splits are scanned but not indexed: only pairs touching a retained tab are kept.
        var noisySplits = session
        noisySplits.splits = (noisySplits.splits ?? []) + (0..<20_000).map { _ in BrowserSplit(primaryID: UUID(), secondaryID: UUID()) }
        var noisyWork = BookmarkSessionSnapshot.Work()
        let noisyInput = BookmarkSessionSnapshot.input(from: noisySplits, profileID: profileA, work: &noisyWork)
        require(noisyInput == Self.reference(noisySplits, profileA) && noisyWork.splitsScanned == 20_002 && noisyWork.splitsIndexed == 2,
                "20,000 unrelated splits: scanned once, only this profile's 2 pairs indexed, same result: \(noisyWork)")
        print("PASS: \(checks) bookmark session snapshot checks")
    }
    /// The straightforward algorithm (session.keptChildren per container): the semantics the index must keep.
    static func reference(_ session: BrowserSession, _ profileID: UUID) -> ExtensionBookmarkTree.Input? {
        guard session.profiles.contains(where: { $0.id == profileID }) else { return nil }
        func page(_ tab: BrowserTab) -> ExtensionBookmarkTree.Page? {
            guard let saved = tab.saved, !tab.isArcEasel, !ArcEaselReference.isReference(saved.address),
                  ExtensionBookmarkTree.isWeb(saved.address), session.profileID(for: tab) == profileID else { return nil }
            return .init(id: tab.id, title: tab.displayTitle, address: saved.address)
        }
        var builder = ExtensionBookmarkTree.Builder(), pending: [UUID] = []
        func children(_ container: BrowserSession.KeptContainer) -> [ExtensionBookmarkTree.Child] {
            session.keptChildren(of: container).compactMap { id in
                if session.folder(id) != nil { pending.append(id); return .folder(id) }
                guard let tab = session.tabs.first(where: { $0.id == id }), let primary = page(tab) else { return nil }
                if let split = session.splits?.first(where: { $0.primaryID == id }),
                   let other = session.tabs.first(where: { $0.id == split.secondaryID }), let secondary = page(other) {
                    return .split(primary: primary, secondary: secondary)
                }
                return .page(primary)
            }
        }
        for tab in session.favorites(in: profileID) { if let p = page(tab) { builder.addFavorite(p) } }
        for space in session.spaces where space.profileID == profileID { builder.addSpace(id: space.id, name: space.name, children: children(.root(space.id))) }
        var seen = Set<UUID>()
        while let id = pending.popLast() {
            guard seen.insert(id).inserted, let folder = session.folder(id) else { continue }
            builder.addFolder(id: id, name: folder.name, children: children(.folder(id)))
        }
        return builder.result
    }
    static func pageIDs(_ child: ExtensionBookmarkTree.Child) -> [UUID] {
        switch child {
        case .page(let page): return [page.id]
        case .split(let primary, let secondary): return [primary.id, secondary.id]
        case .folder: return []
        }
    }
}
