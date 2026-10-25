import Foundation

/// Maps a profile library's genuine history changes to the extension engine's `history` events, and its
/// in-memory history to the engine's read-only snapshot. Pure: no AppKit, no controller.
enum LibraryHistoryEvents {
    static func visit(_ entry: BrowserHistoryEntry) -> ExtensionHistory.Visit {
        ExtensionHistory.Visit(url: entry.address, title: entry.title, visitedAt: entry.visitedAt)
    }
    /// Newest first, as the library keeps it (at most 5,000).
    static func snapshot(_ history: [BrowserHistoryEntry]) -> [ExtensionHistory.Visit] { history.map(visit) }
    /// The engine's snapshot for a profile: only an already-loaded library is read (memory only); an absent one
    /// is nil, an error for the extension, never a trigger to load it from disk.
    @MainActor static func snapshot(of library: BrowserLibrary?, available: Bool) -> [ExtensionHistory.Visit]? {
        guard available, let library else { return nil }
        return snapshot(library.history)
    }

    /// The engine event for one library change; nil when there's nothing to tell (a trim that removed no URL
    /// entirely, because a retained visit still has it). `history` is the library's history after the change.
    static func change(_ change: BrowserLibrary.HistoryChange, history: [BrowserHistoryEntry]) -> ExtensionHistory.Change? {
        switch change {
        case .visited(let entry): return .visited(visit(entry))
        case .trimmed(let addresses):
            let urls = ExtensionHistory.removedURLs(dropped: addresses, retained: snapshot(history))
            return urls.isEmpty ? nil : .removed(urls: urls)
        case .cleared: return .cleared
        }
    }
}
