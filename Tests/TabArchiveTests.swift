import AppKit

/// Auto-archive's rules: which tabs go, which never do, Splits as a whole, the preference's
/// defaults (fixtures never archive), and that the saved session and archive stay compatible.
@main enum TabArchiveTests {
    @MainActor static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("FAILED: \(message)"); exit(1) }; checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3600
        func tab(_ hoursAgo: Double?, _ change: (inout TabArchivePolicy.Candidate) -> Void = { _ in }) -> TabArchivePolicy.Candidate {
            var candidate = TabArchivePolicy.Candidate(id: UUID(), lastViewedAt: hoursAgo.map { now.addingTimeInterval(-$0 * hour) })
            change(&candidate); return candidate
        }
        let policy = TabArchivePolicy()
        let twelve = ArchiveInterval.twelveHours.seconds

        // Intervals: Arc's four, plus Never; 12 hours by default.
        require(ArchiveInterval.allCases.map(\.title) == ["12 hours", "24 hours", "7 days", "30 days", "Never"], "Arc's choices plus Never")
        require(ArchiveInterval.standard == .twelveHours && ArchiveInterval.never.seconds == nil, "12 hours default; Never has no time")
        require(ArchiveInterval.week.seconds == 7 * 86_400 && ArchiveInterval.month.seconds == 30 * 86_400, "day lengths")

        // Time.
        let old = tab(13), fresh = tab(11), edge = tab(12)
        require(policy.due([old, fresh, edge], now: now, after: twelve) == [old.id, edge.id], "past 12 hours goes, oldest first; under stays")
        require(policy.due([old], now: now, after: nil).isEmpty, "Never archives nothing")
        require(policy.due([tab(nil)], now: now, after: twelve).isEmpty, "a tab never seen yet is left alone")
        require(policy.due([tab(-2)], now: now, after: twelve).isEmpty, "a view time in the future (clock change) is left alone")
        require(policy.due([tab(25)], now: now, after: ArchiveInterval.day.seconds).count == 1 && policy.due([tab(23)], now: now, after: ArchiveInterval.day.seconds).isEmpty, "24 hours")

        // What is never archived, however old.
        let protected: [(String, (inout TabArchivePolicy.Candidate) -> Void)] = [
            ("kept tabs and Favorites", { $0.isSaved = true }), ("the tab on screen", { $0.isVisible = true }),
            ("a tab playing media", { $0.isPlayingMedia = true }), ("a tab in a call", { $0.isCapturing = true }),
            ("a tab in Picture in Picture", { $0.isPictureInPicture = true }), ("a tab downloading", { $0.isDownloading = true }),
            ("a tab under a Peek", { $0.hasPeek = true })
        ]
        for (name, change) in protected {
            require(policy.due([tab(1000, change)], now: now, after: twelve).isEmpty, "never archives \(name)")
        }

        // Splits leave whole, through their first tab, and only when both sides are due.
        let primary = UUID()
        var left = tab(20) { $0.splitPrimaryID = primary }; left.id = primary
        let right = tab(30) { $0.splitPrimaryID = primary }
        require(policy.due([left, right], now: now, after: twelve) == [primary], "a due Split is archived by its first tab")
        let playingRight = tab(30) { $0.splitPrimaryID = primary; $0.isPlayingMedia = true }
        require(policy.due([left, playingRight], now: now, after: twelve).isEmpty, "a Split with a protected side stays")
        let recentRight = tab(2) { $0.splitPrimaryID = primary }
        require(policy.due([left, recentRight], now: now, after: twelve).isEmpty, "a Split with a recently seen side stays")

        // The preference: fixtures and fresh previews never persist and start at Never.
        require(ArchivePreference.isDisposableLaunch(["Bam", "--fresh-preview"]) && ArchivePreference.isDisposableLaunch(["Bam", "--feature-test"]),
                "fresh previews and fixtures are disposable")
        require(!ArchivePreference.isDisposableLaunch(["Bam"]) && !ArchivePreference.isDisposableLaunch(["Bam", "--persistent-preview"]), "normal launches persist")
        let savedDefaults = ArchivePreference.defaults, savedEnvironment = ArchivePreference.environment
        ArchivePreference.defaults = nil; ArchivePreference.environment = [:]
        require(ArchivePreference.interval == .never && ArchivePreference.effectiveSeconds == nil, "a disposable launch starts at Never")
        ArchivePreference.environment = ["BAM_ARCHIVE_AFTER_SECONDS": "30"]
        require(ArchivePreference.effectiveSeconds == 30, "a fresh preview may shorten the clock for a trial")
        let suite = "bam.archive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        ArchivePreference.defaults = defaults
        require(ArchivePreference.interval == .twelveHours && ArchivePreference.effectiveSeconds == 12 * hour, "a real profile defaults to 12 hours")
        require(ArchivePreference.effectiveSeconds == 12 * hour, "and ignores the trial clock")
        ArchivePreference.interval = .week
        require(defaults.string(forKey: ArchivePreference.defaultsKey) == "week" && ArchivePreference.interval == .week, "a choice is saved")
        ArchivePreference.interval = .never
        require(ArchivePreference.effectiveSeconds == nil, "Never turns it off")
        defaults.removePersistentDomain(forName: suite)
        ArchivePreference.defaults = savedDefaults; ArchivePreference.environment = savedEnvironment

        // The session keeps view times; sessions from before decode without them.
        var stamped = BrowserTab(title: "A", address: "https://example.com", space: 0)
        stamped.lastViewedAt = now
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let roundTrip = try! decoder.decode(BrowserTab.self, from: encoder.encode(stamped))
        require(roundTrip.lastViewedAt == now, "last viewed time survives a relaunch")
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"Old","address":"https://example.com","space":0,"pinned":false}"#
        require(try! decoder.decode(BrowserTab.self, from: Data(legacy.utf8)).lastViewedAt == nil, "older sessions load with no view time")

        // Day headings.
        let calendar = Calendar(identifier: .gregorian)
        require(ArchiveDay.title(for: now, now: now, calendar: calendar) == "Today", "Today")
        require(ArchiveDay.title(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday", "Yesterday")
        print("PASS: \(checks) auto-archive checks")
    }
}
