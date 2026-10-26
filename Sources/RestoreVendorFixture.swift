import Foundation

/// Opt-in original fixture for a real extension's same-window restore acceptance (for example Session Buddy's
/// "Open in this window"). `BAM_VENDOR_RESTORE_FIXTURE=1`, only with the normal disposable probe and a literal
/// loopback `BAM_VENDOR_SITE`, makes the probe's start tab the run's own ordinary "today" fixture page instead of the
/// Bam-internal blank tab. The window then holds only ordinary http tabs (that page and the site page), with nothing
/// saved, pinned or in a folder, and no persistent user data. While it is on, an extension may open exactly those two
/// run-owned URLs (full address string) besides its own pages; everything else stays blocked. Fixture only: no
/// product API changes; the bookmark seed keeps its own narrower allowlist and cannot be combined with this.
enum RestoreVendorFixture {
    static let flag = "BAM_VENDOR_RESTORE_FIXTURE"
    static let startTitle = "Bam restore today"

    enum Decision: Equatable {
        case off
        /// The two run-owned ordinary pages an extension may reopen.
        case on(today: String, site: String)
        /// Requested but not allowed; the probe stops before creating anything.
        case refused(String)
    }

    /// Decided before any controller, session or view exists. Only "1" enables; anything else set is refused.
    static func decide(flag value: String?, isNormalMode: Bool, site: String?, seedFlag: String?) -> Decision {
        guard let value, !value.isEmpty else { return .off }
        guard value == "1" else { return .refused("\(flag) must be 1 when set") }
        guard seedFlag?.isEmpty ?? true else { return .refused("\(flag) cannot be combined with \(BookmarkVendorSeed.flag)") }
        guard isNormalMode else { return .refused("\(flag) needs the canonical normal disposable probe (BAM_VENDOR_PROFILE=normal)") }
        guard let origin = BookmarkVendorSeed.loopbackOrigin(site), let raw = site, let components = URLComponents(string: raw),
              components.query == nil, components.fragment == nil, components.path.count > 1,
              let siteURL = components.url, siteURL.absoluteString.hasPrefix(origin.absoluteString) else {
            return .refused("\(flag) needs BAM_VENDOR_SITE as a literal loopback http page URL with a path and no query or fragment")
        }
        let today = BookmarkVendorSeed.destination("today", origin: origin)
        guard today != siteURL.absoluteString else { return .refused("\(flag) needs BAM_VENDOR_SITE to differ from the today fixture page") }
        return .on(today: today, site: siteURL.absoluteString)
    }

    /// The extra navigation allowance while the fixture is on: exactly the two run-owned pages.
    static func destinations(_ decision: Decision) -> Set<String> {
        if case .on(let today, let site) = decision { return [today, site] }
        return []
    }
}
