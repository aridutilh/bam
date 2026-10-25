import Foundation
import WebKit

/// Chrome-style explicit consent, through the runtime's own WebKit delegate methods on a real loaded context (in-process,
/// non-persistent controller and store, no windows or app). Implicit URL requests (WebKit's tab reads, injection, cookies,
/// CORS) are answered empty with no review and no record change; explicit pattern requests (`permissions.request`
/// origins) keep their review, approval, declined-means-denied and stale-answer guards. Which WebKit API reaches which
/// delegate is engine routing, checked by the native acceptance, not here.
@main @MainActor enum ExtensionExplicitConsentTests {
    struct Failure: Error { let message: String }
    static func main() async {
        guard #available(macOS 15.4, *) else { print("SKIP: extensions need macOS 15.4"); return }
        do { print("PASS: explicit consent (\(try await run()) checks)") }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @available(macOS 15.4, *)
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-explicit-consent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "name": "Explicit consent fixture", "version": "1.0", "description": "Original",
            "permissions": ["tabs"], "optional_permissions": ["alarms", "cookies"],
            "host_permissions": ["http://127.0.0.1/*"], "optional_host_permissions": ["http://localhost/*"]
        ]).write(to: package.appendingPathComponent("manifest.json"))

        let host = BrowserExtensions(storageURL: root.appendingPathComponent("Extensions", isDirectory: true), controllerStorage: .nonPersistent)
        defer { host.shutdown() }
        var reviews: [BrowserExtensionPermissionReview] = []
        var answer = true
        var duringReview: (() -> Void)?
        host.permissionPrompt = { review in reviews.append(review); duringReview?(); duringReview = nil; return answer }
        let profile = UUID()
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        host.configure(configuration, profileID: profile); await host.ready(profileID: profile)
        let id = try await host.importPackage(at: package, profileID: profile)
        guard let context = host.context(for: id), let controller = context.webExtensionController,
              let runtime = controller.delegate as? BrowserExtensionRuntime else { throw Failure(message: "Fixture did not load: \(host.errors)") }
        let site = try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*"), optionalSite = try WKWebExtension.MatchPattern(string: "http://localhost/*")
        let page = URL(string: "http://127.0.0.1/page")!, optionalPage = URL(string: "http://localhost/page")!, undeclared = URL(string: "https://undeclared.invalid/")!

        // The user withholds the requested site.
        guard let installed = host.siteAccess(id: id), let declarations = installed.declarations else { throw Failure(message: "No site access snapshot") }
        let withheld = try host.performSiteAccess(id: id, profileID: profile, revision: installed.revision, displayed: declarations, change: .choose(.withheld))
        reviews.removeAll()
        let recordBefore = host.records.first { $0.id == id }
        func status(_ url: URL) -> WKWebExtensionContext.PermissionStatus { context.permissionStatus(for: url) }
        func unchanged() -> Bool {
            let record = host.records.first { $0.id == id }
            return record?.siteAccess == recordBefore?.siteAccess && record?.patterns == recordBefore?.patterns &&
                record?.deniedPatterns == recordBefore?.deniedPatterns && record?.timedSiteGrants == recordBefore?.timedSiteGrants &&
                host.siteAccess(id: id)?.revision == withheld.revision
        }

        // MARK: Implicit URL requests: empty at once, no review, no denial, no record change (requested, optional, undeclared).
        for urls: Set<URL> in [[page], [optionalPage], [undeclared], [page, optionalPage, undeclared]] {
            var answered: Set<URL>? = nil
            runtime.webExtensionController(controller, promptForPermissionToAccess: urls, in: nil, for: context) { granted, expiry in answered = expiry == nil ? granted : nil }
            try check(answered == [], "An implicit URL request must be answered empty at once: \(urls)")
        }
        try check(reviews.isEmpty, "An implicit URL request must never show a review: \(reviews.map(\.websites))")
        try check(unchanged() && context.deniedPermissionMatchPatterns.isEmpty, "An implicit URL request must not record a grant or denial")
        try check(status(page) != .grantedExplicitly && status(page) != .deniedExplicitly && status(optionalPage) != .deniedExplicitly,
                  "An implicit URL request must leave WebKit's permission state unchanged")

        // MARK: Explicit pattern request (permissions.request origins): reviewed once; approval records a listed site.
        var granted: Set<WKWebExtension.MatchPattern>?
        runtime.webExtensionController(controller, promptForPermissionMatchPatterns: [site], in: nil, for: context) { value, _ in granted = value }
        try check(reviews.count == 1 && reviews[0].websites == [site.string] && granted == [site], "An explicit request must be reviewed once and granted on approval")
        try check(host.siteAccess(id: id)?.state.mode == .specific([site.string]) && status(page) == .grantedExplicitly,
                  "An approved explicit request must become a listed site: \(String(describing: host.siteAccess(id: id)?.state))")

        // MARK: Explicit decline: the user's decision is denied.
        answer = false
        granted = nil
        runtime.webExtensionController(controller, promptForPermissionMatchPatterns: [optionalSite], in: nil, for: context) { value, _ in granted = value }
        try check(reviews.count == 2 && granted == [] && status(optionalPage) == .deniedExplicitly, "A declined explicit request must be denied")
        context.deniedPermissionMatchPatterns.removeValue(forKey: optionalSite); host.persistPermissions(context)

        // MARK: Stale explicit answer: a panel change during the review grants and denies nothing.
        answer = true
        guard let current = host.siteAccess(id: id) else { throw Failure(message: "No snapshot before the stale review") }
        duringReview = { _ = try? host.performSiteAccess(id: id, profileID: profile, revision: current.revision, displayed: declarations, change: .choose(.withheld)) }
        granted = nil
        runtime.webExtensionController(controller, promptForPermissionMatchPatterns: [optionalSite], in: nil, for: context) { value, _ in granted = value }
        try check(reviews.count == 3 && granted == [] && status(optionalPage) != .grantedExplicitly && status(optionalPage) != .deniedExplicitly &&
                  host.siteAccess(id: id)?.state.mode == .withheld, "A stale explicit answer must neither grant nor deny")

        // MARK: Named permissions (permissions.request({permissions})): reviewed, bound to the state shown.
        func named(_ requested: Set<WKWebExtension.Permission>) -> Set<WKWebExtension.Permission>? {
            var answered: Set<WKWebExtension.Permission>?
            runtime.webExtensionController(controller, promptForPermissions: requested, in: nil, for: context) { value, _ in answered = value }
            return answered
        }
        func namedStatus(_ permission: WKWebExtension.Permission) -> WKWebExtensionContext.PermissionStatus { context.permissionStatus(for: permission) }
        let geolocation = WKWebExtension.Permission(rawValue: "geolocation")
        reviews.removeAll(); answer = true
        try check(named([.alarms]) == [.alarms] && reviews.count == 1 && reviews[0].permissions == ["alarms"] && namedStatus(.alarms) == .grantedExplicitly &&
                  host.records.first { $0.id == id }?.permissions["alarms"] != nil, "An approved named request must be reviewed once and granted")
        answer = false
        try check(named([.cookies, geolocation]) == [] && reviews.count == 2 && namedStatus(.cookies) == .deniedExplicitly && namedStatus(geolocation) != .deniedExplicitly,
                  "A declined named request must deny only what was offered, never an unsupported permission")
        context.deniedPermissions.removeValue(forKey: .cookies); host.persistPermissions(context)
        try check(named([geolocation]) == [] && reviews.count == 2 && namedStatus(geolocation) != .deniedExplicitly,
                  "A request with nothing supported must show no review and record no decision")

        // A Revoke while the review is open: the stale approval must not undo it, and nothing is denied.
        answer = true
        duringReview = { try? host.revokePermissions(id: id) }
        try check(named([.cookies]) == [] && reviews.count == 3, "A named answer made stale by Revoke must grant nothing")
        try check(namedStatus(.cookies) != .grantedExplicitly && namedStatus(.cookies) != .deniedExplicitly && namedStatus(.alarms) != .grantedExplicitly &&
                  host.records.first { $0.id == id }?.permissions.isEmpty == true && host.records.first { $0.id == id }?.deniedPermissions["cookies"] == nil,
                  "Revoke during a named review must stand: no grant restored, no denial added")

        // Another named-permission change while the review is open (approve or decline) is also stale.
        duringReview = { context.setPermissionStatus(.grantedExplicitly, for: .cookies); host.persistPermissions(context) }
        try check(named([.alarms]) == [] && reviews.count == 4 && namedStatus(.alarms) != .grantedExplicitly && namedStatus(.alarms) != .deniedExplicitly,
                  "A named approval made stale by another permission change must grant nothing")
        answer = false
        duringReview = { context.deniedPermissions.removeValue(forKey: .cookies); context.grantedPermissions.removeValue(forKey: .cookies); host.persistPermissions(context) }
        try check(named([.alarms]) == [] && reviews.count == 5 && namedStatus(.alarms) != .deniedExplicitly,
                  "A stale named decline must deny nothing")

        // MARK: Same-context ABA: All requested → Withheld → All requested during an explicit pattern review restores every
        // site-access value on the same live context; the permission epoch still makes the answer stale.
        duringReview = nil
        guard let beforeAll = host.siteAccess(id: id) else { throw Failure(message: "No snapshot before ABA") }
        let all = try host.performSiteAccess(id: id, profileID: profile, revision: beforeAll.revision, displayed: declarations, change: .choose(.allRequested))
        let abaRecord = host.records.first { $0.id == id }
        answer = true
        var restored: BrowserExtensionRecord?, restoredSnapshot: BrowserExtensionSiteAccessSnapshot?
        duringReview = {
            guard let w = try? host.performSiteAccess(id: id, profileID: profile, revision: all.revision, displayed: declarations, change: .choose(.withheld)) else { return }
            restoredSnapshot = try? host.performSiteAccess(id: id, profileID: profile, revision: w.revision, displayed: declarations, change: .choose(.allRequested))
            restored = host.records.first { $0.id == id }
        }
        let reviewsBeforeABA = reviews.count
        granted = nil
        runtime.webExtensionController(controller, promptForPermissionMatchPatterns: [optionalSite], in: nil, for: context) { value, _ in granted = value }
        // Captured inside the review, before its answer applies: a real ABA on the same live context.
        try check(reviews.count == reviewsBeforeABA + 1 && host.context(for: id) === context && restored?.siteAccess == abaRecord?.siteAccess &&
                  restored?.patterns == abaRecord?.patterns && restored?.timedSiteGrants == abaRecord?.timedSiteGrants && restoredSnapshot?.state == all.state,
                  "Fixture: the review must span a real ABA on the same context, with every site-access value restored")
        try check(granted == [] && status(optionalPage) != .grantedExplicitly && status(optionalPage) != .deniedExplicitly &&
                  host.siteAccess(id: id)?.state == all.state,
                  "An explicit answer made stale by a same-context ABA must neither grant nor deny")
        try check(restoredSnapshot.map { $0.revision != all.revision && $0.revision.permissionEpoch > all.revision.permissionEpoch } == true,
                  "The permission epoch must advance across the ABA")
        return checks
    }
}
