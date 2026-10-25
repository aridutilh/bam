import Foundation

/// What the sidebar shows for session data. Display only: no tab, folder, Space or stored identifier changes.
enum SidebarDisplayPolicy {
    /// Bam's own pages (the blank New Tab landing page, the PiP demo). The legacy `orbit://` scheme stays in
    /// storage; it is never shown to people as an address, tooltip or accessibility value.
    static func isInternalAddress(_ address: String) -> Bool { address.lowercased().hasPrefix("orbit://") }
    /// The address as people should see it: empty for Bam's own pages.
    static func visibleAddress(_ address: String) -> String { isInternalAddress(address) ? "" : address }

    /// An unsaved tab still on the blank New Tab landing page that isn't the selected tab is a placeholder, not a
    /// page in use: Arc lists no row for it. It stays in the session (tab switching, restore, Close All Today);
    /// only its sidebar row is omitted. The selected one stays listed so the current tab is never invisible.
    static func hidesPlaceholder(_ tab: BrowserTab, activeID: UUID?, inSplit: Bool) -> Bool {
        !tab.isSaved && !inSplit && tab.id != activeID && tab.address == "orbit://newtab"
    }

    /// Folders the Arc import created, from the session's recorded provenance only (`arc:<id>` → `folder:<uuid>`).
    /// Nothing is inferred from names, and nothing about a source folder's live status is known or claimed.
    static func arcImportedFolderIDs(_ links: [String: String]?) -> Set<UUID> {
        var result = Set<UUID>()
        for (key, value) in links ?? [:] where key.hasPrefix("arc:") && value.hasPrefix("folder:") {
            if let id = UUID(uuidString: String(value.dropFirst("folder:".count))) { result.insert(id) }
        }
        return result
    }
    static let arcImportedFolderNote = "Imported from Arc as saved links. Bam doesn’t update this folder automatically."
}
