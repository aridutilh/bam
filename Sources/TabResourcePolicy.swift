import Foundation

/// The evidence is intentionally short-lived and document-specific. A missing
/// probe, unsupported document, or any protection reason is never permission.
struct TabActivityEvidence: Equatable {
    var address: String
    var documentToken: String
    var observedAt: TimeInterval
    var reasons: [String]
    var isSafeToSleep: Bool { !documentToken.isEmpty && reasons.isEmpty }
}

/// Pure selection policy. The controller supplies its monotonic clock and an
/// observed/injected pressure level, then revalidates immediately before sleep.
struct TabResourcePolicy {
    enum Pressure { case normal, warning, critical }

    struct Candidate: Equatable {
        var id: UUID
        var address: String
        var lastUsedAt: TimeInterval?
        var isLoaded = true
        var isVisible = false
        var isPictureInPicture = false
        var isSaved = false
        var isLoading = false
        var hasError = false
        var hasPendingNavigation = false
        var hasRetainedPeek = false
        var hasHistory = false
        var siteKeepAwake = false
    }

    var minimumIdleTime: TimeInterval = 600
    var protectedRecentCount = 3
    var maximumProbeAge: TimeInterval = 1

    /// Potential candidates still need a successful activity probe. Protect the
    /// most recently used loaded pages even when all have been idle a long time.
    func candidates(_ tabs: [Candidate], now: TimeInterval, pressure: Pressure,
                    hasActiveDownloads: Bool) -> [Candidate] {
        guard pressure == .critical, !hasActiveDownloads, now.isFinite, now >= 0 else { return [] }
        let counts = Dictionary(grouping: tabs, by: \.id).mapValues(\.count)
        let validRecency = tabs.filter {
            guard $0.isLoaded, counts[$0.id] == 1, let used = $0.lastUsedAt else { return false }
            return used.isFinite && used >= 0 && used <= now
        }
        let recent = validRecency.sorted {
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt! > $1.lastUsedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }
        let protected = Set(recent.prefix(max(3, protectedRecentCount)).map(\.id))
        let idle = minimumIdleTime.isFinite ? max(600, minimumIdleTime) : .infinity
        return validRecency.filter { tab in
            guard !protected.contains(tab.id), !tab.isVisible, !tab.isPictureInPicture,
                  !tab.isSaved, !tab.isLoading, !tab.hasError, !tab.hasPendingNavigation,
                  !tab.hasRetainedPeek, !tab.hasHistory, !tab.siteKeepAwake,
                  now - tab.lastUsedAt! >= idle,
                  let url = URL(string: tab.address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { return false }
            return true
        }.sorted {
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt! < $1.lastUsedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Call with a freshly rebuilt candidate list after awaiting the probe. This
    /// prevents a stale selection/pressure/loading decision authorizing release.
    func permitsSleeping(_ candidate: Candidate, among tabs: [Candidate], activity: TabActivityEvidence?,
                         now: TimeInterval, pressure: Pressure, hasActiveDownloads: Bool) -> Bool {
        guard let activity, activity.isSafeToSleep, activity.address == candidate.address,
              activity.observedAt.isFinite, now.isFinite, activity.observedAt <= now,
              maximumProbeAge.isFinite, maximumProbeAge >= 0,
              now - activity.observedAt <= min(2, maximumProbeAge),
              tabs.first(where: { $0.id == candidate.id }) == candidate else { return false }
        return candidates(tabs, now: now, pressure: pressure, hasActiveDownloads: hasActiveDownloads)
            .contains { $0.id == candidate.id }
    }
}
