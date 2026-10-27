import Foundation

extension Notification.Name {
    /// The ad blocker was switched, a site was allowed or blocked again, or new lists finished compiling.
    static let contentBlockingChanged = Notification.Name("BamContentBlockingChanged")
    /// Settings › Update Now.
    static let contentBlockingUpdateRequested = Notification.Name("BamContentBlockingUpdateRequested")
}

/// Whether Bam blocks ads and trackers, globally and per site. Lists are global (every profile and
/// Space); the sites you allow ads on are remembered in preferences. Fresh previews and fixtures keep
/// both in memory so they never change the real app's choices.
enum ContentBlockingPreference {
    static let enabledKey = "BlockAdsAndTrackers"
    static let allowedSitesKey = "AdsAllowedSites"

    /// Live state from the blocker for Settings: how many rules are active and when lists last changed.
    struct Status: Equatable {
        var ruleCount = 0
        var listCount = 0
        var updated: Date?
        /// True while only Bam's small built-in list is in use (before the first download).
        var builtInOnly = true
        var updating = false
    }

    nonisolated(unsafe) static var status = Status()
    nonisolated(unsafe) static var defaults: UserDefaults? = isDisposableLaunch(CommandLine.arguments) ? nil : .standard
    nonisolated(unsafe) private static var memoryEnabled = true
    nonisolated(unsafe) private static var memorySites = Set<String>()

    /// Fresh previews and test fixtures must not write the real app's preferences.
    static func isDisposableLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--fresh-preview" || $0 == "--vendor-extension-probe" || ($0.hasPrefix("--") && $0.hasSuffix("-test")) }
    }

    static var isEnabled: Bool {
        get {
            guard let defaults else { return memoryEnabled }
            return defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
        }
        set {
            if let defaults { defaults.set(newValue, forKey: enabledKey) } else { memoryEnabled = newValue }
            NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
        }
    }

    static var allowedSites: Set<String> {
        get { defaults.map { Set($0.stringArray(forKey: allowedSitesKey) ?? []) } ?? memorySites }
        set {
            if let defaults { defaults.set(newValue.sorted(), forKey: allowedSitesKey) } else { memorySites = newValue }
        }
    }

    /// The site key for a URL: its lowercased host without `www.`; nil for pages that aren't on the web.
    static func site(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Whether `site` or a domain it belongs to is in `allowed` (allowing example.com covers news.example.com).
    static func isAllowed(_ site: String, in allowed: Set<String>) -> Bool {
        var candidate = Substring(site)
        while true {
            if allowed.contains(String(candidate)) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = candidate[candidate.index(after: dot)...]
            if !candidate.contains(".") { return false } // never match a bare TLD
        }
    }

    /// Whether blocking applies to pages at `url` right now.
    static func blocks(_ url: URL?) -> Bool {
        guard isEnabled else { return false }
        guard let site = site(url) else { return true }
        return !isAllowed(site, in: allowedSites)
    }

    /// Per-site switch from site controls. Turning blocking back on also clears a parent-domain allowance.
    static func setBlocks(_ on: Bool, for url: URL?) {
        guard let site = site(url) else { return }
        var sites = allowedSites
        if on {
            sites = sites.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        } else {
            sites.insert(site)
        }
        allowedSites = sites
        NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
    }

    /// Settings' one-line summary, like "118,302 rules from 7 lists · updated 2 days ago".
    static func summary(_ status: Status, enabled: Bool, now: Date = Date()) -> String {
        guard enabled else { return "Off. Pages load every ad and tracker." }
        if status.updating && status.ruleCount == 0 { return "Getting filter lists…" }
        let rules = NumberFormatter.localizedString(from: NSNumber(value: status.ruleCount), number: .decimal)
        if status.builtInOnly {
            return status.ruleCount == 0 ? "Starting…" : "\(rules) rules from Bam’s built-in list · full lists download shortly"
        }
        var text = "\(rules) rules from \(status.listCount) lists"
        if status.updating { text += " · updating…" }
        else if let updated = status.updated { text += " · updated " + relative(updated, now: now) }
        return text
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 86_400 { let h = Int(seconds / 3_600); return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = Int(seconds / 86_400); return d == 1 ? "1 day ago" : "\(d) days ago"
    }
}

/// "Page not working?": the same page reloaded three times within 20 seconds while blocking was on.
struct ContentBlockingBreakageDetector {
    var reloads = 3
    var window: TimeInterval = 20
    private var address: String?
    private var times: [TimeInterval] = []

    /// Call when a page starts loading. Returns true once when the reloads add up to a likely breakage.
    mutating func pageStarted(_ url: URL?, at time: TimeInterval) -> Bool {
        let key = url.map { u -> String in
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false); c?.fragment = nil
            return c?.string ?? u.absoluteString
        }
        guard let key, key == address else { address = key; times = []; return false }
        times.append(time)
        times.removeAll { time - $0 > window }
        guard times.count >= reloads else { return false }
        times = []
        return true
    }
}
