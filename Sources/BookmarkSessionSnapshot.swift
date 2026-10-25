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
/// - Limits come first: if the profile has more candidate items than the model accepts, nothing is traversed.
///   Folders are walked with a worklist (no recursion); a folder reached twice (a cycle or a duplicate) is
///   collected once and referenced again, which the model rejects as inconsistent rather than looping.
/// - Returns nil when the profile is unknown or the budget is exceeded, so the extension gets an error,
///   never an empty or partial tree.
enum BookmarkSessionSnapshot {
    static func input(from session: BrowserSession, profileID: UUID) -> ExtensionBookmarkTree.Input? {
        guard session.profiles.contains(where: { $0.id == profileID }) else { return nil }
        let spaces = session.spaces.filter { $0.profileID == profileID }
        let spaceIDs = Set(spaces.map(\.id))
        // Bound the traversal before doing it: every Favorite, kept row and folder costs at least one item.
        let favorites = session.favorites(in: profileID)
        var candidates = favorites.count
        for tab in session.tabs where spaceIDs.contains(tab.space) && tab.saved?.kind == .kept { candidates += 1 }
        for folder in session.folders where spaceIDs.contains(folder.space) { candidates += 1 }
        guard candidates <= ExtensionBookmarkTree.maximumInputItems else { return nil }

        let tabsByID = Dictionary(session.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let foldersByID = Dictionary(session.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let secondaryByPrimary = Dictionary((session.splits ?? []).map { ($0.primaryID, $0.secondaryID) }, uniquingKeysWith: { first, _ in first })

        func page(_ tab: BrowserTab) -> ExtensionBookmarkTree.Page? {
            // Saved web pages of this profile only (the model would drop non-web ones too; they're not supplied).
            guard let saved = tab.saved, !tab.isArcEasel, !ArcEaselReference.isReference(saved.address),
                  ExtensionBookmarkTree.isWeb(saved.address), session.profileID(for: tab) == profileID else { return nil }
            return ExtensionBookmarkTree.Page(id: tab.id, title: tab.displayTitle, address: saved.address)
        }
        var builder = ExtensionBookmarkTree.Builder()
        var pending: [UUID] = []
        func children(_ container: BrowserSession.KeptContainer) -> [ExtensionBookmarkTree.Child] {
            session.keptChildren(of: container).compactMap { id in
                if foldersByID[id] != nil { pending.append(id); return .folder(id) }
                guard let tab = tabsByID[id], let primary = page(tab) else { return nil }
                if let secondaryID = secondaryByPrimary[id], let other = tabsByID[secondaryID], let secondary = page(other) {
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
            guard builder.addSpace(id: space.id, name: space.name, children: children(.root(space.id))) else { return nil }
        }
        var seen = Set<UUID>()
        while let id = pending.popLast() {
            // Each folder is collected once; a second reference stays in its parent for the model to reject.
            guard seen.insert(id).inserted, let folder = foldersByID[id], spaceIDs.contains(folder.space) else { continue }
            guard seen.count <= ExtensionBookmarkTree.maximumInputItems,
                  builder.addFolder(id: id, name: folder.name, children: children(.folder(id))) else { return nil }
        }
        return builder.result
    }
}
