import Foundation

/// Builds the input for `bookmarks.getTree` (ExtensionBookmarkTree) from the session, for one login profile,
/// on demand. Read-only: nothing is loaded or woken and no file is read.
///
/// - Only that profile: its Favorites, then its Spaces in sidebar order, each Space's kept section in
///   sidebar order, folders by ID with their own ordered children.
/// - Pages are saved items only, with the address the user kept (`saved.address`) and the title Bam shows.
///   Today tabs, other profiles and Arc Easel references are never supplied.
/// - A kept Split is its primary then its secondary (each with its own ID), when the secondary is saved;
///   otherwise the primary alone.
/// - Cost: one pass over the session's tabs, one over its splits and one over its folders builds a bounded
///   index of just this profile's saved tabs (Split secondaries counted too), folders and the Split pairs that
///   touch them; expanding a folder is then a lookup,
///   never a rescan of the session. Container order is exactly `BrowserSession.keptChildren(of:)`'s:
///   stored order first, then members missing from it in tab-array order, then folder-array order.
/// - Limits come first: if the profile has more candidate items than the model accepts, nothing is expanded.
///   Folders are walked with a worklist (no recursion); a folder reached twice (a cycle or a duplicate) is
///   collected once and referenced again, which the model rejects as inconsistent rather than looping.
/// - Returns nil when the profile is unknown, the controller is closing or applying a profile change, or the
///   budget is exceeded, so the extension gets an error, never an empty or partial tree.
enum BookmarkSessionSnapshot {
    /// Work done by one snapshot, for tests (element visits, not time).
    struct Work: Equatable {
        var tabsScanned = 0, foldersScanned = 0, splitsScanned = 0, containersExpanded = 0
        /// Split pairs actually kept in the index (only those touching this profile's retained tabs).
        var splitsIndexed = 0
    }

    /// The integration hook's entry point: nil while the controller is closing or applying a profile change
    /// (the session may be mid-transition between profiles), otherwise the snapshot below.
    static func input(from session: BrowserSession, profileID: UUID, isShuttingDown: Bool, isApplyingProfileChange: Bool) -> ExtensionBookmarkTree.Input? {
        guard !isShuttingDown, !isApplyingProfileChange else { return nil }
        return input(from: session, profileID: profileID)
    }

    static func input(from session: BrowserSession, profileID: UUID) -> ExtensionBookmarkTree.Input? {
        var work = Work()
        return input(from: session, profileID: profileID, work: &work)
    }

    private struct Container: Hashable { let space: Int; let parent: UUID? }

    static func input(from session: BrowserSession, profileID: UUID, work: inout Work) -> ExtensionBookmarkTree.Input? {
        guard session.profiles.contains(where: { $0.id == profileID }) else { return nil }
        let spaces = session.spaces.filter { $0.profileID == profileID }
        let spaceIDs = Set(spaces.map(\.id))
        let limit = ExtensionBookmarkTree.maximumInputItems

        // One pass over tabs: this profile's Favorites (in order) and every kept tab in its Spaces, by container
        // (tab-array order). Every saved tab retained, Split secondaries included, counts against the budget
        // before it is stored, so a huge or corrupt session is never collected in full.
        var candidates = 0
        var favorites: [BrowserTab] = []
        var keptByContainer: [Container: [UUID]] = [:]
        var relevant: [UUID: BrowserTab] = [:]
        for tab in session.tabs {
            work.tabsScanned += 1
            guard let saved = tab.saved else { continue }
            if saved.kind == .favorite {
                guard session.profileID(for: tab) == profileID else { continue }
                candidates += 1; guard candidates <= limit else { return nil }
                favorites.append(tab); if relevant[tab.id] == nil { relevant[tab.id] = tab }
            } else if saved.kind == .kept, spaceIDs.contains(tab.space) {
                candidates += 1; guard candidates <= limit else { return nil }
                keptByContainer[Container(space: tab.space, parent: tab.folderID), default: []].append(tab.id)
                if relevant[tab.id] == nil { relevant[tab.id] = tab }
            }
        }
        // One pass over splits, indexing only pairs that touch a retained tab (so at most as many as were
        // counted above): secondaries are never rows (as in keptChildren), and each primary's secondary.
        var secondaryIDs = Set<UUID>(), secondaryByPrimary: [UUID: UUID] = [:]
        for split in session.splits ?? [] {
            work.splitsScanned += 1
            let touchesSecondary = relevant[split.secondaryID] != nil, touchesPrimary = relevant[split.primaryID] != nil
            guard touchesSecondary || touchesPrimary else { continue }
            work.splitsIndexed += 1
            if touchesSecondary { secondaryIDs.insert(split.secondaryID) }
            if touchesPrimary, secondaryByPrimary[split.primaryID] == nil { secondaryByPrimary[split.primaryID] = split.secondaryID }
        }
        let keptRows = keptByContainer.mapValues { ids in ids.filter { !secondaryIDs.contains($0) } }
        // One pass over folders: this profile's folders by container (folder-array order); the first definition of an ID wins.
        var childFolders: [Container: [UUID]] = [:]
        var foldersByID: [UUID: BrowserFolder] = [:]
        for folder in session.folders {
            work.foldersScanned += 1
            guard spaceIDs.contains(folder.space) else { continue }
            candidates += 1; guard candidates <= limit else { return nil }
            childFolders[Container(space: folder.space, parent: folder.parentID), default: []].append(folder.id)
            if foldersByID[folder.id] == nil { foldersByID[folder.id] = folder }
        }

        func page(_ tab: BrowserTab) -> ExtensionBookmarkTree.Page? {
            // Saved web pages of this profile only (the model would drop non-web ones too; they're not supplied).
            guard let saved = tab.saved, !tab.isArcEasel, !ArcEaselReference.isReference(saved.address),
                  ExtensionBookmarkTree.isWeb(saved.address), session.profileID(for: tab) == profileID else { return nil }
            return ExtensionBookmarkTree.Page(id: tab.id, title: tab.displayTitle, address: saved.address)
        }
        /// Exactly keptChildren(of:): stored order first (members only, once each), then the rest in member order.
        func ordered(_ members: [UUID], stored: [UUID]?) -> [UUID] {
            guard let stored, !stored.isEmpty else { return members }
            let memberSet = Set(members); var seen = Set<UUID>()
            let known = stored.filter { memberSet.contains($0) && seen.insert($0).inserted }
            return known + members.filter { !seen.contains($0) }
        }
        var builder = ExtensionBookmarkTree.Builder()
        var pending: [UUID] = []
        func children(_ container: Container, stored: [UUID]?) -> [ExtensionBookmarkTree.Child] {
            work.containersExpanded += 1
            let members = (keptRows[container] ?? []) + (childFolders[container] ?? [])
            return ordered(members, stored: stored).compactMap { id in
                if foldersByID[id] != nil { pending.append(id); return .folder(id) }
                guard let tab = relevant[id], let primary = page(tab) else { return nil }
                if let secondaryID = secondaryByPrimary[id], let other = relevant[secondaryID], let secondary = page(other) {
                    return .split(primary: primary, secondary: secondary)
                }
                return .page(primary)
            }
        }
        for tab in favorites {
            guard let favorite = page(tab) else { continue }
            guard builder.addFavorite(favorite) else { return nil }
        }
        for space in spaces {
            let kids = children(Container(space: space.id, parent: nil), stored: session.rootOrder?[space.id])
            guard builder.addSpace(id: space.id, name: space.name, children: kids) else { return nil }
        }
        var seen = Set<UUID>()
        while let id = pending.popLast() {
            // Each folder is collected once; a second reference stays in its parent for the model to reject.
            guard seen.insert(id).inserted, let folder = foldersByID[id] else { continue }
            let kids = children(Container(space: folder.space, parent: id), stored: folder.childOrder)
            guard builder.addFolder(id: id, name: folder.name, children: kids) else { return nil }
        }
        return builder.result
    }
}
