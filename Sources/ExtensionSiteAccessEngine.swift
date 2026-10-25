import Foundation
import WebKit

/// What the engine reports for one extension (the panel adapter maps it to `ExtensionSiteAccessPanel.Snapshot`).
@available(macOS 15.4, *)
struct BrowserExtensionSiteAccessSnapshot: Equatable {
    /// What the snapshot was computed from; actions carry it back and are refused if it no longer matches.
    struct Revision: Equatable {
        let stored: Data?
        let timed: ExtensionSiteAccessEngine.Timed
        let patterns: [String: Date]
        let version: String
        let enabled: Bool
        let context: Int?
        let declarations: ExtensionSiteAccess.Declarations?
    }
    let id: UUID
    let profileID: UUID
    let revision: Revision
    let state: ExtensionSiteAccess.State
    /// nil while the extension isn't loaded: the choice can't be changed until it is enabled.
    let declarations: ExtensionSiteAccess.Declarations?
    /// Time-limited grants by provenance (requested: part of the site choice; optional: the extension's own request),
    /// honored until they lapse and never extended.
    let timed: ExtensionSiteAccessEngine.Timed
    /// What is granted right now.
    let effective: [String]
    /// activeTab is granted (effective permissions), so "On click" wording is allowed.
    let oneTimeAccess: Bool
    var editable: Bool { declarations != nil }
    var pending: [String] { declarations.map { ExtensionSiteAccess.pendingRequests(state, declarations: $0) } ?? [] }
}
/// The panel's actions, one to one.
@available(macOS 15.4, *)
enum BrowserExtensionSiteAccessChange: Equatable {
    /// `.withheld` or `.allRequested`; `.specific` starts with `.addSite`, never empty.
    case choose(ExtensionSiteAccess.Mode)
    /// From Withheld or All requested this starts a list with just this site.
    case addSite(input: String, includeSubdomains: Bool)
    case removeSite(String)
    /// Exactly the pending requests the user reviewed and allowed.
    case acceptPending([String])
}
@available(macOS 15.4, *)
enum BrowserExtensionSiteAccessFailure: Error, Equatable, LocalizedError {
    case refused(ExtensionSiteAccess.Refusal)
    /// The displayed snapshot is out of date (an update, reload or prompt changed it): nothing was applied.
    case stale
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .refused(let refusal): return ExtensionSiteAccessEngine.message(refusal)
        case .stale: return "This extension's site access changed. Review the current settings and try again."
        case .failed(let text): return text
        }
    }
}

/// The engine's glue around the pure `ExtensionSiteAccess` model: persistence that fails closed and works on records
/// that exist on older systems, migration that never widens or extends an expiry, the effective grants including
/// time-limited ones, and the provenance of runtime prompt approvals. Pure apart from WebKit's match patterns.
@available(macOS 15.4, *)
enum ExtensionSiteAccessEngine {
    typealias State = ExtensionSiteAccess.State
    typealias Declarations = ExtensionSiteAccess.Declarations
    struct Unreadable: Error, LocalizedError {
        var errorDescription: String? { "This extension's site access settings could not be read, so it was not loaded. Remove and reinstall it to choose site access again." }
    }

    // MARK: Persistence (the record stores plain Data, so it decodes on every supported system)

    /// nil when nothing is stored yet; throws when stored data is unreadable (fail closed: never a default grant).
    static func decode(_ data: Data?) throws -> State? {
        guard let data else { return nil }
        do { return try JSONDecoder().decode(State.self, from: data) } catch { throw Unreadable() }
    }
    static func encode(_ state: State) -> Data? { try? JSONEncoder().encode(state) }

    // MARK: Time-limited grants

    /// Grants WebKit holds with a finite expiry, by provenance. Requested ones belong to the user's site choice
    /// (withholding or removing the site drops them); optional ones came from the extension's optional requests
    /// (mode changes keep them, like `optionalGrants`). Never extended or re-dated; dropped when they lapse.
    struct Timed: Equatable {
        var requested: [String: Date] = [:]
        var optional: [String: Date] = [:]
        var isEmpty: Bool { requested.isEmpty && optional.isEmpty }
        var all: [String: Date] { requested.merging(optional) { min($0, $1) } }
    }

    /// WebKit's "no expiry" is `.distantFuture`; anything earlier is a real, finite expiry.
    static func isPermanent(_ date: Date) -> Bool { date >= Date.distantFuture.addingTimeInterval(-86_400) }

    /// Unexpired grants whose provenance the declarations still support (requested ones only while requested).
    static func live(_ timed: Timed, declarations: Declarations, now: Date = Date()) -> Timed {
        Timed(requested: timed.requested.filter { $0.value > now && ExtensionSiteAccess.isCovered($0.key, by: declarations.requested) },
              optional: timed.optional.filter { $0.value > now && isDeclared($0.key, declarations) })
    }

    /// A record from before site access existed: permanent unexpired grants go through the model's conservative
    /// migration; finite unexpired grants stay time-limited with their own dates, classified like the model does
    /// (a request covers it → requested); expired or undeclared ones go.
    static func migrate(patterns: [String: Date], declarations: Declarations, now: Date = Date()) -> (state: State, timed: Timed) {
        let unexpired = patterns.filter { $0.value > now }
        var timed = Timed()
        for (pattern, expiry) in unexpired where !isPermanent(expiry) { classify(pattern, expiry, into: &timed, declarations) }
        return (ExtensionSiteAccess.migrate(granted: unexpired.filter { isPermanent($0.value) }.map(\.key), declarations: declarations), timed)
    }

    /// Exactly what to grant: the model's patterns (no expiry) plus live time-limited grants. A pattern is never
    /// both: a finite grant only stands where the model doesn't grant it permanently (see `reconcile`).
    static func target(_ state: State, timed: Timed, declarations: Declarations, now: Date = Date()) -> [String: Date] {
        var result: [String: Date] = [:]
        for pattern in ExtensionSiteAccess.grantedPatterns(state, declarations: declarations) { result[pattern] = .distantFuture }
        for (pattern, expiry) in live(timed, declarations: declarations, now: now).all where result[pattern] == nil { result[pattern] = expiry }
        return result
    }

    /// Time-limited grants after a user change (`previous` is the state before it). Withholding or choosing All
    /// requested ends requested time-limited grants (the choice now decides those sites); removing a site ends those
    /// it covers; adding a site that starts a new list (from Withheld or All requested) ends those outside the list.
    /// Optional ones always stay.
    static func timed(_ timed: Timed, after change: BrowserExtensionSiteAccessChange, from previous: State, to next: State) -> Timed {
        var result = timed
        switch change {
        case .choose(.withheld), .choose(.allRequested): result.requested = [:]
        case .removeSite(let site): result.requested = timed.requested.filter { $0.key != site && !ExtensionSiteAccess.isCovered($0.key, by: [site]) }
        case .addSite:
            if case .specific = previous.mode { break }
            guard case .specific(let sites) = next.mode else { break }
            result.requested = timed.requested.filter { ExtensionSiteAccess.isCovered($0.key, by: sites) }
        default: break
        }
        return result
    }

    private static func isDeclared(_ pattern: String, _ declarations: Declarations) -> Bool {
        ExtensionSiteAccess.isCovered(pattern, by: declarations.requested + declarations.optional)
    }
    private static func classify(_ pattern: String, _ expiry: Date, into timed: inout Timed, _ declarations: Declarations) {
        if ExtensionSiteAccess.isCovered(pattern, by: declarations.requested) { timed.requested[pattern] = expiry }
        else if ExtensionSiteAccess.isCovered(pattern, by: declarations.optional) { timed.optional[pattern] = expiry }
    }

    // MARK: Runtime prompts

    enum Provenance: Equatable { case requested(String), optional(String), refused }
    /// A site the user approved in a runtime prompt: requested access when a requested declaration covers it, an
    /// optional grant when only an optional declaration does, refused otherwise.
    static func provenance(of site: String, declarations: Declarations) -> Provenance {
        if ExtensionSiteAccess.isCovered(site, by: declarations.requested) { return .requested(site) }
        if ExtensionSiteAccess.isCovered(site, by: declarations.optional) { return .optional(site) }
        return .refused
    }
    /// The site pattern for a URL a prompt asked about (nil for anything that isn't an http(s) site).
    static func site(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host else { return nil }
        if case .success(let pattern) = ExtensionSiteAccess.normalizeSite("\(scheme)://\(host)/") { return pattern }
        return nil
    }
    /// The prompt decision in the current state. Under All requested a requested site the user hasn't approved is
    /// pending: it is reviewed in Manage Extensions, not granted piecemeal from a prompt (refused here).
    static func promptDecision(_ site: String, in state: State, declarations: Declarations) -> Provenance {
        let decision = provenance(of: site, declarations: declarations)
        if case .requested = decision, case .allRequested = state.mode,
           !ExtensionSiteAccess.isCovered(site, by: Array(ExtensionSiteAccess.grantedPatterns(state, declarations: declarations))) { return .refused }
        return decision
    }
    /// Records approved prompt sites (a fresh explicit approval, so permanent): requested ones join the listed
    /// sites (All requested already grants them, see `promptDecision`), optional ones become optional grants. A
    /// time-limited grant of the same site is superseded.
    static func recording(_ approved: [Provenance], in state: State, timed: Timed) -> (state: State, timed: Timed) {
        var next = state, nextTimed = timed
        let requested = approved.compactMap { if case .requested(let site) = $0 { return site }; return nil }
        let optional = approved.compactMap { if case .optional(let site) = $0 { return site }; return nil }
        switch state.mode {
        case .withheld where !requested.isEmpty: next = .specific(requested, optionalGrants: state.optionalGrants)
        case .specific(let sites) where !requested.isEmpty: next = .specific(sites + requested, optionalGrants: state.optionalGrants)
        default: break
        }
        if !optional.isEmpty { next = State(mode: next.mode, optionalGrants: next.optionalGrants + optional, approvedRequests: next.approvedRequests) }
        for site in requested + optional { nextTimed.requested.removeValue(forKey: site); nextTimed.optional.removeValue(forKey: site) }
        return (next, nextTimed)
    }

    // MARK: WebKit-side changes

    /// WebKit-side host changes since the last apply (`applied`, Bam's own target):
    /// - a pattern Bam applied that is no longer live was removed (the extension's permissions.remove, or a lapse):
    ///   it leaves the listed sites, optional grants and time-limited grants (All requested approvals stay: an
    ///   extension can't remove a required host);
    /// - a declared live pattern with a finite expiry is time-limited with WebKit's date. If the model granted that
    ///   same pattern permanently, the explicit expiry constrains it: it leaves the permanent choice (a listed site,
    ///   an optional grant, or an All requested approval, which then reads as pending) until a fresh approval;
    /// - permanent patterns Bam didn't apply are not authority and are ignored.
    static func reconcile(_ state: State, timed: Timed, applied: [String: Date], live liveGrants: [String: Date], declarations: Declarations, now: Date = Date())
        -> (state: State, timed: Timed, target: [String: Date]) {
        let removed = Set(applied.keys).subtracting(liveGrants.keys)
        // Only a finite grant that differs from what Bam applied is a new constraint (Bam's own time-limited grants
        // come back unchanged and constrain nothing).
        let shortened = Dictionary(uniqueKeysWithValues: liveGrants.filter {
            !isPermanent($0.value) && $0.value > now && isDeclared($0.key, declarations) && applied[$0.key] != $0.value }.map { ($0.key, $0.value) })
        // Permanent authority overlapping a constrained pattern (equal, broader or narrower) can't stay permanent: a
        // broader one would keep granting it forever. Listed sites and optional grants that overlap leave; a broad
        // All requested approval is split into the requests it covered that don't overlap (never wider).
        func constrained(_ pattern: String) -> Bool {
            shortened.keys.contains { $0 == pattern || ExtensionSiteAccess.isCovered($0, by: [pattern]) || ExtensionSiteAccess.isCovered(pattern, by: [$0]) }
        }
        var next = state
        if !removed.isEmpty || !shortened.isEmpty {
            let optional = state.optionalGrants.filter { !removed.contains($0) && !constrained($0) }
            switch state.mode {
            case .specific(let sites): next = .specific(sites.filter { !removed.contains($0) && !constrained($0) }, optionalGrants: optional)
            case .withheld: next = .withheld(optionalGrants: optional)
            case .allRequested:
                let covering = state.approvedRequests.filter(constrained)
                let split = declarations.requested.filter { request in
                    !constrained(request) && covering.contains { ExtensionSiteAccess.isCovered(request, by: [$0]) } }
                next = State(mode: .allRequested, optionalGrants: optional, approvedRequests: state.approvedRequests.filter { !constrained($0) } + split)
            }
        }
        var nextTimed = live(timed, declarations: declarations, now: now)
        nextTimed.requested = nextTimed.requested.filter { !removed.contains($0.key) }
        nextTimed.optional = nextTimed.optional.filter { !removed.contains($0.key) }
        for (pattern, expiry) in shortened {
            // Provenance: a pattern the user's choice granted stays requested; one from optional grants stays optional.
            if state.optionalGrants.contains(pattern) { nextTimed.requested.removeValue(forKey: pattern); nextTimed.optional[pattern] = expiry }
            else if nextTimed.optional[pattern] != nil { nextTimed.optional[pattern] = expiry }
            else { var classified = Timed(); classify(pattern, expiry, into: &classified, declarations); nextTimed.requested.merge(classified.requested) { $1 }; nextTimed.optional.merge(classified.optional) { $1 } }
        }
        return (next, nextTimed, target(next, timed: nextTimed, declarations: declarations, now: now))
    }

    // MARK: Panel

    static func message(_ refusal: ExtensionSiteAccess.Refusal) -> String {
        switch refusal {
        case .empty: return "Enter a website."
        case .invalid: return "That isn't a website address."
        case .unsupportedScheme(let scheme): return "Only http and https sites can be allowed, not \(scheme)."
        case .allSites: return "To allow every site this extension requests, choose All requested sites."
        case .notRequested: return "This extension doesn't request access to that site."
        }
    }
}
