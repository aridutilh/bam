import Foundation
import WebKit

/// The engine glue around the site access model: fail-closed persistence, migration that never widens or extends an
/// expiry, time-limited grants by provenance, runtime prompt classification and WebKit-side reconciliation. Pure:
/// WebKit's public MatchPattern only (no controller, context, window or app).
@main enum ExtensionSiteAccessEngineTests {
    static func main() async throws {
        guard #available(macOS 15.4, *) else { print("SKIP: WKWebExtension needs macOS 15.4"); return }
        try await run()
    }

    @available(macOS 15.4, *) @MainActor static func run() async throws {
        typealias Engine = ExtensionSiteAccessEngine
        typealias Access = ExtensionSiteAccess
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let now = Date()
        let hour = now.addingTimeInterval(3_600), day = now.addingTimeInterval(86_400), past = now.addingTimeInterval(-60)
        let forever = Date.distantFuture
        let declarations = Access.Declarations(requested: ["https://*.docs.example/*", "https://mail.example/*"], optional: ["https://optional.example/*"])

        // MARK: Persistence fails closed; nothing stored reads as "not yet migrated".
        require((try? Engine.decode(nil)) == .some(nil), "No stored data must mean not yet migrated")
        let stored = Access.State.specific(["https://mail.example/*"], optionalGrants: ["https://optional.example/*"])
        require((try? Engine.decode(Engine.encode(stored))) == .some(stored), "Stored site access must round-trip")
        var unreadable = false
        do { _ = try Engine.decode(Data("not json".utf8)) } catch is Engine.Unreadable { unreadable = true }
        require(unreadable, "Unreadable site access must refuse the load, never fall back to a default grant")

        // MARK: Migration: permanent grants via the model, finite ones keep their own date and provenance.
        let migrated = Engine.migrate(patterns: [
            "https://*.docs.example/*": forever, "https://mail.example/*": forever,
            "https://a.docs.example/*": hour,            // finite, a request covers it → requested time-limited
            "https://optional.example/*": day,           // finite, optional only → optional time-limited
            "https://undeclared.example/*": forever,     // dropped
            "https://mail.example/old/*": past           // expired, dropped
        ], declarations: declarations, now: now)
        require(migrated.state.mode == .allRequested && Set(migrated.state.approvedRequests) == Set(declarations.requested),
                "Every requested string granted must migrate to All requested approving exactly those: \(migrated.state)")
        require(migrated.timed.requested == ["https://a.docs.example/*": hour], "A finite requested grant must keep its date: \(migrated.timed)")
        require(migrated.timed.optional == ["https://optional.example/*": day], "A finite optional grant must keep its date: \(migrated.timed)")
        let migratedTarget = Engine.target(migrated.state, timed: migrated.timed, declarations: declarations, now: now)
        require(migratedTarget["https://a.docs.example/*"] == hour && migratedTarget["https://optional.example/*"] == day,
                "Migration must never extend a finite expiry: \(migratedTarget)")
        require(migratedTarget["https://undeclared.example/*"] == nil && migratedTarget["https://mail.example/old/*"] == nil,
                "Migration must drop undeclared and expired grants")
        let partial = Engine.migrate(patterns: ["https://mail.example/*": forever], declarations: declarations, now: now)
        require(partial.state.mode == .specific(["https://mail.example/*"]), "A partial legacy grant must migrate narrower, never to All requested")

        // MARK: Time-limited grants by provenance across user changes.
        let timed = Engine.Timed(requested: ["https://a.docs.example/*": hour, "https://mail.example/inbox/*": hour], optional: ["https://optional.example/*": day])
        let listedMail = Access.State.specific(["https://mail.example/*"])
        let withheld = Engine.timed(timed, after: .choose(.withheld), from: listedMail, to: .withheld())
        require(withheld.requested.isEmpty && withheld.optional == timed.optional,
                "Withholding must end requested time-limited grants and keep optional ones: \(withheld)")
        require(Engine.target(.withheld(), timed: withheld, declarations: declarations, now: now).keys.sorted() == ["https://optional.example/*"],
                "Withheld must grant only the optional time-limited grant")
        let removed = Engine.timed(timed, after: .removeSite("https://mail.example/*"), from: listedMail, to: .withheld())
        require(removed.requested == ["https://a.docs.example/*": hour], "Removing a site must end the requested time-limited grants it covers: \(removed)")
        let docs = Access.State.specific(["https://a.docs.example/*"])
        require(Engine.timed(timed, after: .addSite(input: "a.docs.example", includeSubdomains: false), from: listedMail,
                             to: .specific(["https://a.docs.example/*", "https://mail.example/*"])) == timed,
                "Adding a site to an existing list must not touch time-limited grants")
        // Adding a site from Withheld or All requested starts a list with only that site: requested time-limited
        // grants outside it end; optional ones stay.
        for previous in [Access.State.withheld(), .allRequested(approving: declarations)] {
            let started = Engine.timed(timed, after: .addSite(input: "a.docs.example", includeSubdomains: false), from: previous, to: docs)
            require(started.requested == ["https://a.docs.example/*": hour] && started.optional == timed.optional,
                    "Starting a list must end requested time-limited grants outside it and keep optional ones: \(started)")
        }
        let narrowed = Engine.live(timed, declarations: .init(requested: ["https://mail.example/*"], optional: ["https://optional.example/*"]), now: now)
        require(narrowed.requested == ["https://mail.example/inbox/*": hour], "An update must drop requested time-limited grants no longer requested: \(narrowed)")
        require(Engine.live(timed, declarations: declarations, now: hour.addingTimeInterval(1)).requested.isEmpty, "Lapsed grants must drop")

        // MARK: Runtime prompts: requested vs optional provenance, refused otherwise.
        require(Engine.site(for: URL(string: "https://Mail.Example:8443/inbox?x=1")!) == "https://mail.example/*", "A prompt URL must become its site")
        require(Engine.site(for: URL(string: "file:///etc/hosts")!) == nil, "Non-web URLs must not become sites")
        require(Engine.provenance(of: "https://mail.example/*", declarations: declarations) == .requested("https://mail.example/*"), "A requested site must be requested access")
        require(Engine.provenance(of: "https://optional.example/*", declarations: declarations) == .optional("https://optional.example/*"), "An optional-only site must be an optional grant")
        require(Engine.provenance(of: "https://other.example/*", declarations: declarations) == .refused, "An undeclared site must be refused")
        let recorded = Engine.recording([.requested("https://mail.example/*"), .optional("https://optional.example/*")],
                                        in: .withheld(), timed: Engine.Timed(optional: ["https://optional.example/*": hour]))
        require(recorded.state.mode == .specific(["https://mail.example/*"]) && recorded.state.optionalGrants == ["https://optional.example/*"],
                "Prompt approvals must record provenance: \(recorded.state)")
        require(recorded.timed.optional.isEmpty, "A fresh approval must supersede the time-limited grant of the same site")
        let afterWithhold = Access.State.withheld(optionalGrants: recorded.state.optionalGrants)
        require(Access.grantedPatterns(afterWithhold, declarations: declarations) == ["https://optional.example/*"],
                "Withholding later must withhold the requested prompt site but keep the optional one")
        let pendingAll = Access.State(mode: .allRequested, approvedRequests: ["https://mail.example/*"])
        require(Engine.promptDecision("https://a.docs.example/*", in: pendingAll, declarations: declarations) == .refused,
                "A pending request under All requested must be reviewed in Manage Extensions, not granted from a prompt")
        require(Engine.promptDecision("https://optional.example/*", in: pendingAll, declarations: declarations) == .optional("https://optional.example/*"),
                "Optional prompts stay available under All requested")

        // MARK: WebKit-side changes.
        let specific = Access.State.specific(["https://mail.example/*"], optionalGrants: ["https://optional.example/*"])
        let applied = Engine.target(specific, timed: .init(), declarations: declarations, now: now)
        // The extension removed its optional grant (permissions.remove).
        let dropped = Engine.reconcile(specific, timed: .init(), applied: applied, live: ["https://mail.example/*": forever], declarations: declarations, now: now)
        require(dropped.state.optionalGrants.isEmpty && dropped.target.keys.sorted() == ["https://mail.example/*"],
                "A grant WebKit removed must leave the choice, so a reload doesn't restore it: \(dropped.state)")
        // A permanent grant shortened to a finite expiry: the explicit expiry constrains it until a fresh approval.
        let shortened = Engine.reconcile(specific, timed: .init(), applied: applied,
                                         live: ["https://mail.example/*": hour, "https://optional.example/*": day], declarations: declarations, now: now)
        require(shortened.state.mode == .withheld && shortened.state.optionalGrants.isEmpty,
                "Shortened grants must leave the permanent choice: \(shortened.state)")
        require(shortened.timed.requested == ["https://mail.example/*": hour] && shortened.timed.optional == ["https://optional.example/*": day],
                "Shortened grants must keep provenance and WebKit's date: \(shortened.timed)")
        require(shortened.target == ["https://mail.example/*": hour, "https://optional.example/*": day],
                "The next apply must keep the finite expiry, never restore distantFuture: \(shortened.target)")
        let reapplied = Engine.target(shortened.state, timed: shortened.timed, declarations: declarations, now: now)
        require(reapplied == shortened.target, "Reapplying (or reloading) must not widen a shortened grant")
        require(Engine.live(shortened.timed, declarations: declarations, now: day.addingTimeInterval(1)).isEmpty, "Shortened grants must end when they lapse")
        // Shortening an All requested approval makes it pending: it returns only through explicit review.
        let all = Access.State.allRequested(approving: declarations)
        let allApplied = Engine.target(all, timed: .init(), declarations: declarations, now: now)
        let allShortened = Engine.reconcile(all, timed: .init(), applied: allApplied,
                                            live: ["https://mail.example/*": hour, "https://*.docs.example/*": forever], declarations: declarations, now: now)
        require(Access.pendingRequests(allShortened.state, declarations: declarations) == ["https://mail.example/*"] && allShortened.target["https://mail.example/*"] == hour,
                "A shortened All requested approval must be time-limited, then pending: \(allShortened.state)")
        // A broad approval kept across a narrowing update: shortening one covered site splits it, never regrants it.
        let narrow = Access.Declarations(requested: ["https://a.example/*", "https://b.example/*"])
        let broad = Access.State(mode: .allRequested, approvedRequests: ["https://*.example/*"])
        let broadApplied = Engine.target(broad, timed: .init(), declarations: narrow, now: now)
        require(broadApplied == ["https://a.example/*": forever, "https://b.example/*": forever], "Fixture: the broad approval grants both requests")
        let split = Engine.reconcile(broad, timed: .init(), applied: broadApplied,
                                     live: ["https://a.example/*": hour, "https://b.example/*": forever], declarations: narrow, now: now)
        require(split.state.approvedRequests == ["https://b.example/*"] && split.timed.requested == ["https://a.example/*": hour],
                "A covering approval must be split around the shortened site: \(split.state) \(split.timed)")
        require(split.target == ["https://a.example/*": hour, "https://b.example/*": forever], "The shortened site must stay finite: \(split.target)")
        require(Engine.target(split.state, timed: split.timed, declarations: narrow, now: now) == split.target &&
                Access.pendingRequests(split.state, declarations: narrow) == ["https://a.example/*"],
                "Reapplying must not regrant the shortened site permanently; it returns only through review")
        // A broad listed site covering a shortened one leaves the permanent list too.
        let listedBroad = Access.State.specific(["https://*.example/*"])
        let broadDeclarations = Access.Declarations(requested: ["https://*.example/*"])
        let listedApplied = Engine.target(listedBroad, timed: .init(), declarations: broadDeclarations, now: now)
        let listedSplit = Engine.reconcile(listedBroad, timed: .init(), applied: listedApplied,
                                           live: listedApplied.merging(["https://a.example/*": hour]) { $1 }, declarations: broadDeclarations, now: now)
        require(listedSplit.state.mode == .withheld && listedSplit.target == ["https://a.example/*": hour],
                "A listed site covering a shortened one must not keep granting it permanently: \(listedSplit.target)")
        // Bam's own time-limited grant coming back unchanged constrains nothing.
        let ownTimed = Engine.Timed(requested: ["https://a.example/*": hour])
        let withBroad = Access.State.specific(["https://*.example/*"])
        let ownApplied = Engine.target(withBroad, timed: ownTimed, declarations: broadDeclarations, now: now)
        let unchanged = Engine.reconcile(withBroad, timed: ownTimed, applied: ownApplied, live: ownApplied, declarations: broadDeclarations, now: now)
        require(unchanged.state == withBroad && unchanged.target == ownApplied, "An unchanged time-limited grant must not narrow the list")
        // Permanent grants Bam didn't apply are not authority.
        let foreign = Engine.reconcile(specific, timed: .init(), applied: applied,
                                       live: applied.merging(["https://a.docs.example/*": forever]) { $1 }, declarations: declarations, now: now)
        require(foreign.state == specific && foreign.target == applied, "A permanent grant Bam didn't apply must be ignored")
        // A finite undeclared grant is not kept.
        let undeclared = Engine.reconcile(specific, timed: .init(), applied: applied,
                                          live: applied.merging(["https://other.example/*": hour]) { $1 }, declarations: declarations, now: now)
        require(undeclared.timed.isEmpty, "An undeclared finite grant must not be kept")

        // MARK: Refusal messages are user-facing.
        require(Engine.message(.notRequested).contains("doesn't request"), "Refusals must explain themselves")
        require(BrowserExtensionSiteAccessFailure.stale.errorDescription?.contains("changed") == true, "A stale action must say the settings changed")

        print("ExtensionSiteAccessEngineTests: \(checks) checks passed")
    }
}
