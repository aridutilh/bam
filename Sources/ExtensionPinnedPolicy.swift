import Foundation

/// Chrome's `pinned` tab flag mapped onto Bam's saved tabs. Bam reports kept tabs and Favorites as pinned;
/// an extension can make an ordinary tab kept, or a kept tab ordinary again when nothing Bam stores would be
/// lost. It never creates, changes or removes a Favorite. Pure decisions only: the browser applies them.
enum ExtensionPinnedPolicy {
    enum Retention: Equatable { case ordinary, kept, favorite }

    /// What Bam holds for one tab, read from the session at the moment of the request.
    struct Tab: Equatable {
        var retention: Retention
        /// The page the tab is on now.
        var address: String
        /// The kept tab's original page, which Bam returns to when the tab is closed.
        var savedAddress: String?
        var inFolder = false
        var hasCustomTitle = false
        var hasCustomSymbol = false
        /// A closed kept row with no live page.
        var isUnloaded = false
        /// Either pane of a split view.
        var isSplitMember = false
    }

    enum Decision: Equatable {
        case unchanged
        case keep
        case release
        case refuse(String)
    }

    static let favoriteRefusal = "This tab is a Bam Favorite, shared by every Space in its profile. Extensions can’t unpin Favorites; change it in Bam."
    static let splitRefusal = "This tab is part of a split view in Bam. Extensions can’t pin or unpin one side of a split."
    static let unloadedRefusal = "This kept tab is closed in Bam. Unpinning it would reopen it, so Bam left it kept."
    static let folderRefusal = "This kept tab is in a folder in Bam. Unpinning would take it out of the folder, so Bam left it kept."
    static let customizedRefusal = "This kept tab has a custom name or icon in Bam. Unpinning would discard it, so Bam left it kept."
    static let movedRefusal = "This kept tab shows a different page than the one Bam keeps for it. Unpinning would forget the kept page, so Bam left it kept."
    static let addressRefusal = "Bam can pin (keep) only HTTP and HTTPS pages."

    /// Only ordinary web pages become kept tabs from an extension: not extension pages, Bam's own pages or Easels.
    static func keepable(_ address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return url.host?.isEmpty == false
    }

    /// `tabs.create`: nil when Bam can create the tab as requested.
    static func creationRefusal(url: URL, pinned: Bool) -> String? {
        guard pinned else { return nil }
        return keepable(url.absoluteString) ? nil : addressRefusal
    }

    /// `tabs.update({pinned})`. Requests that already hold succeed without changing anything,
    /// so `pinned: true` on a Favorite or kept tab never demotes or moves it.
    static func update(_ tab: Tab, pinned: Bool) -> Decision {
        switch (tab.retention, pinned) {
        case (.kept, true), (.favorite, true), (.ordinary, false): return .unchanged
        case (.favorite, false): return .refuse(favoriteRefusal)
        case (.ordinary, true):
            if tab.isSplitMember { return .refuse(splitRefusal) }
            return keepable(tab.address) ? .keep : .refuse(addressRefusal)
        case (.kept, false):
            if tab.isSplitMember { return .refuse(splitRefusal) }
            if tab.isUnloaded { return .refuse(unloadedRefusal) }
            if tab.inFolder { return .refuse(folderRefusal) }
            if tab.hasCustomTitle || tab.hasCustomSymbol { return .refuse(customizedRefusal) }
            if tab.savedAddress != tab.address { return .refuse(movedRefusal) }
            return .release
        }
    }
}
