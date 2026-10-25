import Foundation
import WebKit

/// Per-extension site access, as in Chrome's "This extension can read and change site data": which of the sites an
/// extension's manifest requests it may use. Pure model on WebKit's public `WKWebExtension.MatchPattern`: no context,
/// controller, record or UI state. The engine stores `State`, applies `grantedPatterns` to its context and chooses
/// the honest wording (see `providesOneTimeAccess`).
///
/// Requested vs optional, as the SDK distinguishes them:
/// - `Declarations.requested` is `WKWebExtension.allRequestedMatchPatterns`: `host_permissions` plus content-script
///   and externally-connectable matches, i.e. everything the extension needs for its base functionality. The mode
///   decides how much of this is granted.
/// - `Declarations.optional` is `optionalPermissionMatchPatterns`: sites the extension may ask for later
///   (`permissions.request`). What the user allowed that way is `State.optionalGrants`, kept apart from the mode:
///   withholding requested sites never revokes an optional grant.
@available(macOS 15.4, *)
enum ExtensionSiteAccess {
    /// What the user chose for the requested sites.
    enum Mode: Equatable, Sendable {
        /// No requested site is granted up front. Whether a click on the extension's action can then grant one tab
        /// depends on the extension (`providesOneTimeAccess`); the engine words the choice accordingly.
        case withheld
        /// Only these sites: normalized http(s) patterns, sorted, unique, each covered by a request. Never empty
        /// (removing the last site is `.withheld`).
        case specific([String])
        /// Every requested site.
        case allRequested
    }

    /// Persisted by the engine next to the extension's record.
    struct State: Equatable, Sendable {
        var mode: Mode
        /// Sites the extension asked for itself (optional permissions) and the user allowed. Sorted, unique.
        var optionalGrants: [String]
        init(mode: Mode, optionalGrants: [String] = []) {
            self.mode = mode; self.optionalGrants = Array(Set(optionalGrants)).sorted()
        }
    }

    /// An extension's site declarations as WebKit reports them (pattern strings).
    struct Declarations: Equatable, Sendable {
        var requested: [String]
        var optional: [String]
        init(requested: [String], optional: [String] = []) { self.requested = requested; self.optional = optional }
        @MainActor init(_ webExtension: WKWebExtension) {
            requested = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
            optional = webExtension.optionalPermissionMatchPatterns.map(\.string).sorted()
        }
    }

    /// Why a typed site can't be added.
    enum Refusal: Error, Equatable, Sendable {
        case empty
        /// Not a website address Bam can turn into a site pattern.
        case invalid
        /// Only http and https sites are offered.
        case unsupportedScheme(String)
        /// "All sites" is the All requested sites choice, not a list entry.
        case allSites
        /// The extension's manifest doesn't request this site; access is only ever narrowed, never widened.
        case notRequested
    }

    // MARK: Sites

    /// A typed site as a site-level pattern: `github.com` → `*://github.com/*`; `https://GitHub.com/a?b` →
    /// `https://github.com/*`; `*.github.com` (or `includeSubdomains`) → `*://*.github.com/*`. Hosts are lowercased
    /// and internationalized names become their ASCII (punycode) form, which is what page URLs carry. Ports are
    /// dropped: match patterns can't name one and always match every port. Paths are ignored (access is per site).
    static func normalizeSite(_ input: String, includeSubdomains: Bool = false) -> Result<String, Refusal> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if text == "<all_urls>" || text == "*" { return .failure(.allSites) }
        var scheme = "*"
        if let range = text.range(of: "://") {
            scheme = text[..<range.lowerBound].lowercased()
            text = String(text[range.upperBound...])
            guard ["http", "https", "*"].contains(scheme) else { return .failure(.unsupportedScheme(scheme)) }
        } else if let colon = text.firstIndex(of: ":"), text[..<colon].allSatisfy(\.isLetter),
                  !text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            // `mailto:`, `about:blank`, `chrome:settings`: a scheme, not a host with a port.
            return .failure(.unsupportedScheme(text[..<colon].lowercased()))
        }
        var authority = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.contains("@") else { return .failure(.invalid) }
        var subdomains = includeSubdomains
        if authority.hasPrefix("*.") { subdomains = true; authority.removeFirst(2) }
        if authority == "*" || authority.isEmpty { return .failure(authority.isEmpty ? .invalid : .allSites) }
        guard !authority.contains("*") else { return .failure(.invalid) }
        // Let URL parse the host (IDNA, IPv6 brackets, port) instead of hand-splitting it.
        guard let host = URL(string: "http://\(authority)/")?.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return .failure(.invalid) }
        let lowered = host.lowercased()
        let isIPv6 = lowered.contains(":")
        let isIP = isIPv6 || lowered.split(separator: ".").count == 4 && lowered.split(separator: ".").allSatisfy { UInt8($0) != nil }
        guard !(subdomains && isIP) else { return .failure(.invalid) }
        let pattern = "\(scheme)://\(subdomains ? "*." : "")\(isIPv6 ? "[\(lowered)]" : lowered)/*"
        guard (try? WKWebExtension.MatchPattern(string: pattern)) != nil else { return .failure(.invalid) }
        return .success(pattern)
    }

    /// Whether some declaration includes everything `site` matches (WebKit's own pattern comparison).
    static func isCovered(_ site: String, by declarations: [String]) -> Bool {
        guard let candidate = try? WKWebExtension.MatchPattern(string: site) else { return false }
        return declarations.contains { (try? WKWebExtension.MatchPattern(string: $0))?.matches(candidate) == true }
    }

    /// Adds a typed site to the user's list. Only requested sites are accepted. A site typed without a scheme is
    /// narrowed to the schemes actually requested (an https-only request accepts `github.com` as
    /// `https://github.com/*`). `.allRequested` already includes every requested site and is returned unchanged.
    static func addSite(_ input: String, includeSubdomains: Bool = false, to mode: Mode, declarations: Declarations) -> Result<Mode, Refusal> {
        let normalized: String
        switch normalizeSite(input, includeSubdomains: includeSubdomains) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): normalized = value
        }
        var additions: [String] = []
        if isCovered(normalized, by: declarations.requested) {
            additions = [normalized]
        } else if normalized.hasPrefix("*://") {
            let rest = normalized.dropFirst("*://".count)
            additions = ["https", "http"].map { "\($0)://\(rest)" }.filter { isCovered($0, by: declarations.requested) }
        }
        guard !additions.isEmpty else { return .failure(.notRequested) }
        switch mode {
        case .allRequested: return .success(.allRequested)
        case .withheld: return .success(.specific(additions.sorted()))
        case .specific(let sites): return .success(.specific(Array(Set(sites + additions)).sorted()))
        }
    }

    /// Removes one listed site; removing the last one withholds access.
    static func removeSite(_ site: String, from mode: Mode) -> Mode {
        guard case .specific(let sites) = mode else { return mode }
        let remaining = sites.filter { $0 != site }
        return remaining.isEmpty ? .withheld : .specific(remaining)
    }

    // MARK: Grants

    /// Exactly the patterns the engine should grant: the mode's requested sites plus optional grants that are
    /// still declared. Nothing outside the declarations is ever returned.
    static func grantedPatterns(_ state: State, declarations: Declarations) -> Set<String> {
        let mode: [String]
        switch state.mode {
        case .withheld: mode = []
        case .specific(let sites): mode = sites.filter { isCovered($0, by: declarations.requested) }
        case .allRequested: mode = declarations.requested
        }
        let optional = state.optionalGrants.filter { isCovered($0, by: declarations.optional + declarations.requested) }
        return Set(mode + optional)
    }

    /// What applying `target` changes on a context currently granting `current`.
    static func diff(current: Set<String>, target: Set<String>) -> (grant: Set<String>, revoke: Set<String>) {
        (target.subtracting(current), current.subtracting(target))
    }

    /// Whether one click on the extension's action can grant access to that one tab: WebKit's `activeTab`
    /// through `performAction(for:)`, which needs the permission granted. Without it there is no public one-time
    /// access, so the engine must not call `.withheld` "On click".
    static func providesOneTimeAccess(grantedPermissions: Set<String>) -> Bool { grantedPermissions.contains("activeTab") }

    // MARK: Legacy records and updates (never widen)

    /// A record from before site access existed: only its granted pattern strings (Bam granted exactly the
    /// requested strings on approval, and prompts added optional ones). The result never grants more than
    /// `granted` did:
    /// - an exact requested string is the user's install approval;
    /// - anything else covered by an optional declaration came from an optional prompt and stays an optional grant;
    /// - anything else covered by a request (a narrower grant kept across an update) stays as a specific site;
    /// - anything undeclared is dropped.
    static func migrate(granted: [String], declarations: Declarations) -> State {
        let requested = Set(declarations.requested)
        var approved: [String] = [], optional: [String] = [], narrower: [String] = []
        for pattern in Set(granted) {
            if requested.contains(pattern) { approved.append(pattern) }
            else if isCovered(pattern, by: declarations.optional) { optional.append(pattern) }
            else if isCovered(pattern, by: declarations.requested) { narrower.append(pattern) }
        }
        let mode: Mode
        // Every requested string approved: All requested (any narrower grant is inside it). Nothing requested:
        // nothing to choose.
        if requested.isSubset(of: approved) { mode = .allRequested }
        else if approved.isEmpty && narrower.isEmpty { mode = .withheld }
        else { mode = .specific(Array(Set(approved + narrower)).sorted()) }
        return State(mode: mode, optionalGrants: optional)
    }

    /// The state for a new package version, never wider than before. `.allRequested` stays: requests the new
    /// version adds (`newlyRequested`) need the user's review before the engine applies them. Listed sites keep
    /// only those the new version still requests; optional grants keep only those it still declares.
    static func updated(_ state: State, to declarations: Declarations) -> State {
        let mode: Mode
        switch state.mode {
        case .withheld, .allRequested: mode = state.mode
        case .specific(let sites):
            let kept = sites.filter { isCovered($0, by: declarations.requested) }
            mode = kept.isEmpty ? .withheld : .specific(kept)
        }
        return State(mode: mode, optionalGrants: state.optionalGrants.filter { isCovered($0, by: declarations.optional + declarations.requested) })
    }

    /// Requests in `new` that `old` didn't already cover: what an `.allRequested` update must show for review.
    static func newlyRequested(from old: Declarations, to new: Declarations) -> [String] {
        new.requested.filter { !isCovered($0, by: old.requested) }.sorted()
    }
}

// MARK: Persistence: a small explicit shape; an unknown mode reads back as `.withheld` (never wider).
@available(macOS 15.4, *)
extension ExtensionSiteAccess.State: Codable {
    private enum Keys: String, CodingKey { case mode, sites, optionalGrants }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let optional = (try? values.decodeIfPresent([String].self, forKey: .optionalGrants)) ?? []
        let sites = (try? values.decodeIfPresent([String].self, forKey: .sites)) ?? []
        let mode: ExtensionSiteAccess.Mode
        switch (try? values.decode(String.self, forKey: .mode)) ?? "" {
        case "allRequested": mode = .allRequested
        case "specific": mode = sites.isEmpty ? .withheld : .specific(Array(Set(sites)).sorted())
        default: mode = .withheld
        }
        self.init(mode: mode, optionalGrants: optional)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch mode {
        case .withheld: try values.encode("withheld", forKey: .mode)
        case .allRequested: try values.encode("allRequested", forKey: .mode)
        case .specific(let sites): try values.encode("specific", forKey: .mode); try values.encode(sites, forKey: .sites)
        }
        if !optionalGrants.isEmpty { try values.encode(optionalGrants, forKey: .optionalGrants) }
    }
}
