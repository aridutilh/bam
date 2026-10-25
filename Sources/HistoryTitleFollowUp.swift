import Foundation

/// One per main tab view: the visit its current document recorded at didFinish, so that document's title,
/// which WebKit often reports only after didFinish, can correct that one history entry. Pure: no WebKit.
///
/// The controller drops it whenever the document changes or the view goes away (a new navigation, a failure,
/// a crash, sleep, close or retirement), so a late title from an older document never applies.
struct HistoryTitleFollowUp: Equatable {
    /// Bounds writes from pages that keep changing their title. Only accepted changes count.
    static let maximumUpdates = 5

    let profileID: UUID
    let visit: BrowserLibrary.VisitToken
    private(set) var updates = 0

    init(profileID: UUID, visit: BrowserLibrary.VisitToken) {
        self.profileID = profileID; self.visit = visit
    }

    var isSpent: Bool { updates >= Self.maximumUpdates }

    /// The title to offer the library, or nil: the view must still show the recorded document's address
    /// (a pushState or fragment change, or another document, is skipped), from the same profile, with a
    /// non-empty title, and the budget not spent. Asking never uses the budget.
    func candidate(url: URL?, title: String?, profileID current: UUID?) -> String? {
        guard !isSpent, current == profileID, url?.absoluteString == visit.address,
              let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// Offers the current title to the profile's library. Counts only a change the library accepted, so
    /// empty, unchanged or refused titles leave the budget alone.
    @MainActor mutating func apply(url: URL?, title: String?, profileID current: UUID?, library: BrowserLibrary?) -> Bool {
        guard let library, let title = candidate(url: url, title: title, profileID: current),
              library.updateVisitTitle(title, for: visit) else { return false }
        updates += 1
        return true
    }
}
