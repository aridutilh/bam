import Foundation

/// How long a Today tab may go unviewed before Bam archives it. Arc's choices, plus Never.
enum ArchiveInterval: String, CaseIterable, Codable {
    case twelveHours, day, week, month, never

    var seconds: TimeInterval? {
        switch self {
        case .twelveHours: return 12 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .never: return nil
        }
    }
    var title: String {
        switch self {
        case .twelveHours: return "12 hours"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        case .never: return "Never"
        }
    }
    /// Arc's default.
    static let standard = ArchiveInterval.twelveHours
}

/// Settings › General › Archive tabs after. Saved in preferences for normal launches. Fresh
/// previews and test fixtures keep it in memory and start at Never, so nothing they open is
/// archived mid-test; `BAM_ARCHIVE_AFTER_SECONDS` lets a fresh preview try the sweep on a short clock.
enum ArchivePreference {
    static let defaultsKey = "ArchiveTabsAfter"
    nonisolated(unsafe) static var defaults: UserDefaults? = isDisposableLaunch(CommandLine.arguments) ? nil : .standard
    nonisolated(unsafe) private static var memory = ArchiveInterval.never
    nonisolated(unsafe) static var environment = ProcessInfo.processInfo.environment

    /// Fresh previews and fixtures (`--fresh-preview`, `--…-test`, the vendor probe) never persist or archive by default.
    static func isDisposableLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--fresh-preview" || $0 == "--vendor-extension-probe" || ($0.hasPrefix("--") && $0.hasSuffix("-test")) }
    }

    static var interval: ArchiveInterval {
        get {
            guard let defaults else { return memory }
            return defaults.string(forKey: defaultsKey).flatMap(ArchiveInterval.init(rawValue:)) ?? .standard
        }
        set {
            if let defaults { defaults.set(newValue.rawValue, forKey: defaultsKey) } else { memory = newValue }
        }
    }

    /// How long a tab may go unviewed right now; nil when archiving is off.
    static var effectiveSeconds: TimeInterval? {
        if defaults == nil, let raw = environment["BAM_ARCHIVE_AFTER_SECONDS"], let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 {
            return seconds
        }
        return interval.seconds
    }
    /// How often to sweep: every five minutes, or twice per trial interval on a fresh preview's short clock.
    static var sweepPeriod: TimeInterval {
        guard defaults == nil, let seconds = effectiveSeconds else { return 300 }
        return min(300, max(5, seconds / 2))
    }
}

/// Which tabs auto-archive closes. Pure, so the rules are tested without a browser.
struct TabArchivePolicy {
    struct Candidate: Equatable {
        var id: UUID
        var lastViewedAt: Date?
        /// Kept tabs and Favorites are never archived.
        var isSaved = false
        /// On screen now (the active tab, or either side of the visible Split).
        var isVisible = false
        var isPlayingMedia = false
        /// Using the camera, microphone or screen (a call).
        var isCapturing = false
        var isPictureInPicture = false
        var isDownloading = false
        /// A Peek is open over it.
        var hasPeek = false
        /// The Split this tab belongs to, named by its first tab. A Split is archived only as a whole.
        var splitPrimaryID: UUID?
    }

    /// Tabs (and Splits, by their first tab) that have gone unviewed for `after` seconds, oldest first.
    /// A tab never seen (no `lastViewedAt`) or seen "in the future" (a clock change) is left alone.
    func due(_ tabs: [Candidate], now: Date, after: TimeInterval?) -> [UUID] {
        guard let after, after.isFinite, after > 0, now.timeIntervalSince1970.isFinite else { return [] }
        func eligible(_ tab: Candidate) -> Bool {
            guard !tab.isSaved, !tab.isVisible, !tab.isPlayingMedia, !tab.isCapturing, !tab.isPictureInPicture,
                  !tab.isDownloading, !tab.hasPeek, let viewed = tab.lastViewedAt,
                  viewed.timeIntervalSince1970.isFinite, viewed <= now else { return false }
            return now.timeIntervalSince(viewed) >= after
        }
        var groups: [UUID: [Candidate]] = [:]
        for tab in tabs { groups[tab.splitPrimaryID ?? tab.id, default: []].append(tab) }
        let due = groups.compactMap { key, members -> (UUID, Date)? in
            // A Split goes only when every side is due, and leaves through its first tab.
            guard members.allSatisfy(eligible) else { return nil }
            if members.count > 1 || members[0].splitPrimaryID != nil {
                guard members.contains(where: { $0.id == key }) else { return nil }
            }
            return (key, members.compactMap(\.lastViewedAt).max()!)
        }
        return due.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.uuidString < $1.0.uuidString }.map(\.0)
    }
}

/// How an archive list groups its days: "Today", "Yesterday", a weekday this week, then a date.
enum ArchiveDay {
    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = .current
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMM d y")
        }
        return formatter.string(from: date)
    }
}
