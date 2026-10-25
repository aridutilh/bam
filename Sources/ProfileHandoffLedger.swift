import Foundation

/// The owner's record of messages from duplicate launches of its profile.
///
/// A duplicate sends several messages: a startup focus notice, an
/// acknowledged focus-only request, and one request per batch of URLs, each
/// retried until acknowledged. The owner may receive them in any order. Every
/// message carries the duplicate's launch ID, so focus is applied once per
/// launch, and a focus-only message from a launch that already arrived (for
/// example after its URL opened Little Bam) never fronts the main window again.
/// Different launches are independent, however close together they occur.
struct ProfileHandoffLedger {
    struct Decision: Equatable {
        /// Front the owner's main window and activate the app. When URLs are
        /// also delivered, activation must happen first so the URL's window
        /// ends up in front.
        var activate = false
        var deliver: [URL] = []
        var acknowledge = false
    }

    /// Records outlive any duplicate's retry deadline; they are only pruned
    /// to bound memory, never to decide whether activation is legitimate.
    static let retention: TimeInterval = 60
    private var accepted: [UUID: Date] = [:]
    private var launches: [UUID: Date] = [:]

    /// - Parameters:
    ///   - launch: The sending launch, or nil for duplicates that predate
    ///     launch correlation (they always activate, as before).
    ///   - request: Present on acknowledged messages; retries reuse it.
    ///   - canDeliver: Whether the owner can accept URLs now. A refused URL
    ///     request is not acknowledged, so the duplicate retries or fails.
    mutating func receive(launch: UUID?, request: UUID?, urls: [URL], canDeliver: Bool,
                          now: Date = Date()) -> Decision {
        accepted = accepted.filter { $0.value > now }
        launches = launches.filter { $0.value > now }
        if let request, accepted[request] != nil {
            return Decision(acknowledge: true) // Transport retry: already applied.
        }
        if !urls.isEmpty && !canDeliver { return Decision() }
        if let request { accepted[request] = now.addingTimeInterval(Self.retention) }
        let seen = launch.map { launches[$0] != nil } ?? false
        if let launch { launches[launch] = now.addingTimeInterval(Self.retention) }
        return Decision(activate: !urls.isEmpty || !seen, deliver: urls, acknowledge: request != nil)
    }
}
