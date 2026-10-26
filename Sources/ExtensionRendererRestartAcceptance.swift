import AppKit
import WebKit

/// Product acceptance for withdrawn website access reaching an extension's own pages shown in Bam tabs
/// (work/extension-renderer-restart-fixture-contract.md, work/native-host-withdrawal-restart-contract.md).
///
/// Real Bam tabs showing original fixture extensions' pages, against the loopback server (no CORS headers). For every
/// withdrawal path, a restart must advance the restart generation exactly once, load a NEW context with the same
/// identity, recreate the visible tab's renderer (background tabs stay renderer-less until selected), keep tab IDs and
/// addresses, let the old WKWebView deallocate, and make a credentialed fetch from the recreated product tab to the
/// withdrawn host REFUSED. Paths: the Site Access panel (Withhold), a restart whose fresh load fails (then Enable), the
/// extension's own permissions.remove, and a time-limited grant lapsing. Re-allowing access must not restart.
/// Storage preservation is the UI owner's lifecycle fixture (it needs a persistent controller store), not this one.
@available(macOS 15.4, *)
@MainActor enum ExtensionRendererRestartAcceptance {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(controller: BrowserController, host: BrowserExtensions, pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: "Renderer restart: " + message) }; checks += 1
        }
        func wait(_ message: String, timeout: TimeInterval = 12, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw Failure(description: "Renderer restart: " + message)
        }
        let profile = controller.session.currentProfileID
        let earlierPrompt = host.permissionPrompt
        defer { host.permissionPrompt = earlierPrompt; BrowserExtensions.siteAccessRestartLoadFault = nil }
        host.permissionPrompt = { _ in true }
        var target = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        target.path = "/next.html"; target.query = "renderer-restart"
        let targetURL = target.url!, loopback = try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*")

        func install(_ name: String, _ manifest: [String: Any]) async throws -> UUID {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-renderer-restart-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var definition = manifest
            definition["manifest_version"] = 3; definition["name"] = "Bam renderer restart \(name)"; definition["version"] = "1.0"
            definition["description"] = "Original Bam fixture for extension tab restarts (\(name))."
            try JSONSerialization.data(withJSONObject: definition).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><meta charset='utf-8'><title>renderer page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
            return try await host.importPackage(at: folder, profileID: profile)
        }
        var opened: [UUID] = []
        defer { for tab in opened { _ = host.closeTab?(tab) } }
        func openTab(_ id: UUID, active: Bool) async throws -> UUID {
            guard let base = host.context(for: id)?.baseURL,
                  let tab = controller.openProfileTab(base.appendingPathComponent("page.html"), profileID: profile, active: active) else {
                throw Failure(description: "Renderer restart: could not open the extension's page in a Bam tab")
            }
            opened.append(tab)
            try await wait("the extension tab did not load") { controller.browsers[tab]?.title == "renderer page" && controller.browsers[tab]?.isLoading == false }
            return tab
        }
        /// A credentialed fetch from the tab's current renderer: "read:<status>" or "refused".
        func fetch(from tab: UUID) async throws -> String {
            guard let web = controller.browsers[tab] else { throw Failure(description: "Renderer restart: the tab has no renderer to fetch from") }
            let result = try await web.callAsyncJavaScript("""
                return await fetch(target, {credentials: 'include', cache: 'no-store'}).then(async (r) => { await r.text(); return 'read:' + r.status; }, () => 'refused');
                """, arguments: ["target": targetURL.absoluteString], contentWorld: .page) as? String
            return result ?? "nil"
        }
        func generation(_ id: UUID) -> UInt64 { host.restartGeneration[id] ?? 0 }
        func address(_ tab: UUID) -> String? { controller.session.tabs.first { $0.id == tab }?.address }
        /// Waits until every given old view deallocated (Bam dropped it; the fixture holds them only weakly).
        func waitReleased(_ label: String, _ views: [() -> WKWebView?]) async throws {
            try await wait("\(label): an old extension tab renderer was not deallocated after the restart", timeout: 5) { views.allSatisfy { $0() == nil } }
        }
        /// The shared post-restart contract for one restart of `id`.
        /// `oldContext` is the context captured (weakly) just before the withdrawal. The fresh context must be a different
        /// object: either the old one is still alive and is not the fresh one (then it must be unloaded and no longer
        /// owned), or it has deallocated while the fresh one is alive, which proves the same.
        func checkRestarted(_ label: String, _ id: UUID, from before: UInt64, identity: (String, URL), oldContext: () -> WKWebExtensionContext?,
                            visible: UUID, oldVisible: @escaping () -> WKWebView?,
                            background: UUID? = nil, oldBackground: (() -> WKWebView?)? = nil, addresses: [UUID: String?]) async throws {
            try check(generation(id) == before + 1, "\(label): the restart generation is \(generation(id)) after \(before), not exactly one restart")
            guard let fresh = host.context(for: id) else { throw Failure(description: "Renderer restart: \(label): no context after the restart") }
            try check(fresh.isLoaded && fresh.uniqueIdentifier == identity.0 && fresh.baseURL == identity.1, "\(label): the fresh context lost the extension's identity or base URL")
            if let old = oldContext() {
                try check(old !== fresh, "\(label): the restart kept the same context object instead of loading a new one")
                try check(!old.isLoaded && fresh.webExtensionController?.extensionContexts.contains(old) != true,
                          "\(label): the replaced context is still loaded or still in the extension controller")
            }
            try check(host.takeSiteAccessNotice(id: id)?.contains("Restarted") == true, "\(label): no restart notice was recorded")
            if let background { try check(controller.browsers[background] == nil, "\(label): a background extension tab kept a renderer through the restart") }
            try await wait("\(label): the visible extension tab was not recreated") {
                controller.browsers[visible] != nil && (oldVisible() == nil || controller.browsers[visible] !== oldVisible())
                    && controller.browsers[visible]?.title == "renderer page" && controller.browsers[visible]?.isLoading == false
            }
            try await waitReleased(label, [oldVisible] + (oldBackground.map { [$0] } ?? []))
            try check(addresses.allSatisfy { address($0.key) == $0.value }, "\(label): a tab's ID or address changed across the restart")
            try check(!fresh.hasAccess(to: targetURL) && !fresh.grantedPermissionMatchPatterns.keys.contains { $0.matches(targetURL) },
                      "\(label): the fresh context still holds access to the withdrawn host")
            try check(try await fetch(from: visible) == "refused", "\(label): the recreated extension tab could still read the withdrawn host")
        }

        // 1. Site Access panel: Withhold the requested host.
        let requested = try await install("requested", ["host_permissions": ["http://127.0.0.1/*"]])
        // Identity only: the fixture never holds a context strongly, so a replaced one can deallocate.
        guard let requestedIdentity = host.context(for: requested).map({ ($0.uniqueIdentifier, $0.baseURL) }) else {
            throw Failure(description: "Renderer restart: no context for the requested fixture")
        }
        let visible = try await openTab(requested, active: true)
        let background = try await openTab(requested, active: false)
        try check(try await fetch(from: visible) == "read:200", "a granted requested host was not readable from the extension tab (positive control)")
        do {
            weak let oldVisible = controller.browsers[visible]
            weak let oldBackground = controller.browsers[background]
            weak let oldContext = host.context(for: requested)
            let addresses = [visible: address(visible), background: address(background)]
            let before = generation(requested)
            guard let snapshot = host.siteAccess(id: requested), let declarations = snapshot.declarations else { throw Failure(description: "Renderer restart: no Site Access snapshot") }
            _ = try host.performSiteAccess(id: requested, profileID: profile, revision: snapshot.revision, displayed: declarations, change: .choose(.withheld))
            try await checkRestarted("panel withhold", requested, from: before, identity: requestedIdentity, oldContext: { oldContext }, visible: visible, oldVisible: { oldVisible },
                                     background: background, oldBackground: { oldBackground }, addresses: addresses)
        }
        // The background tab gets a fresh renderer when selected, also refused.
        controller.select(background)
        try await wait("the background extension tab did not load when selected") { controller.browsers[background]?.title == "renderer page" && controller.browsers[background]?.isLoading == false }
        try check(try await fetch(from: background) == "refused", "a background extension tab selected after the restart could still read the withdrawn host")
        // Re-allowing access never restarts, and the current renderer then reads again.
        do {
            weak let current = controller.browsers[background]
            let before = generation(requested)
            guard let snapshot = host.siteAccess(id: requested), let declarations = snapshot.declarations else { throw Failure(description: "Renderer restart: no Site Access snapshot") }
            _ = try host.performSiteAccess(id: requested, profileID: profile, revision: snapshot.revision, displayed: declarations, change: .choose(.allRequested))
            try check(generation(requested) == before && controller.browsers[background] === current && host.takeSiteAccessNotice(id: requested) == nil,
                      "re-allowing access restarted the extension or replaced its renderer")
            try check(try await fetch(from: background) == "read:200", "re-allowed access was not readable from the extension tab")
        }

        // 2. A restart whose fresh load fails: stopped, the visible tab shows the unavailable error; Enable restores it.
        do {
            weak let oldVisible = controller.browsers[background]
            let before = generation(requested)
            BrowserExtensions.siteAccessRestartLoadFault = { id in id == requested ? Failure(description: "fixture load fault") : nil }
            guard let snapshot = host.siteAccess(id: requested), let declarations = snapshot.declarations else { throw Failure(description: "Renderer restart: no Site Access snapshot") }
            _ = try? host.performSiteAccess(id: requested, profileID: profile, revision: snapshot.revision, displayed: declarations, change: .choose(.withheld))
            BrowserExtensions.siteAccessRestartLoadFault = nil
            try check(generation(requested) == before + 1 && host.context(for: requested) == nil &&
                      host.records.first { $0.id == requested }?.enabled == false, "a failed restart did not leave the extension stopped and disabled")
            try await waitReleased("failed restart", [{ oldVisible }])
            try await wait("the visible tab of a stopped extension did not show the unavailable error") { controller.tabErrors[background]?.contains("unavailable") == true }
            try await host.setEnabled(true, id: requested)
            try await wait("Enable did not restore the extension tab") {
                controller.browsers[background]?.title == "renderer page" && controller.browsers[background]?.isLoading == false && controller.tabErrors[background] == nil
            }
            try check(host.context(for: requested)?.uniqueIdentifier == requestedIdentity.0, "Enable lost the extension's identity")
            try check(try await fetch(from: background) == "refused", "after Enable, the extension tab could still read the host withheld before the failed restart")
        }

        // 3 and 4. Native withdrawals of an optional host: the extension's own permissions.remove, and expiry.
        let optional = try await install("optional", ["optional_host_permissions": ["http://127.0.0.1/*"]])
        guard let optionalIdentity = host.context(for: optional).map({ ($0.uniqueIdentifier, $0.baseURL) }) else {
            throw Failure(description: "Renderer restart: no context for the optional fixture")
        }
        let optionalTab = try await openTab(optional, active: true)
        func request() async throws -> Bool {
            guard let web = controller.browsers[optionalTab] else { return false }
            return try await web.callAsyncJavaScript("return await browser.permissions.request({origins: ['http://127.0.0.1/*']});", arguments: [:], contentWorld: .page) as? Bool == true
        }
        try check(try await fetch(from: optionalTab) == "refused", "a never-granted optional host was readable (premise)")
        let approved = try await request(), approvedRead = try await fetch(from: optionalTab)
        try check(approved && approvedRead == "read:200", "an approved optional host was not readable (positive control): approved=\(approved) fetch=\(approvedRead)")
        do {
            weak let oldVisible = controller.browsers[optionalTab]
            weak let oldContext = host.context(for: optional)
            let addresses = [optionalTab: address(optionalTab)]
            let before = generation(optional)
            let removed = try await controller.browsers[optionalTab]?.callAsyncJavaScript(
                "return await browser.permissions.remove({origins: ['http://127.0.0.1/*']});", arguments: [:], contentWorld: .page) as? Bool
            try check(removed == true, "permissions.remove did not report success")
            try await wait("the extension's own permissions.remove did not restart it") { generation(optional) > before }
            try await checkRestarted("permissions.remove", optional, from: before, identity: optionalIdentity, oldContext: { oldContext },
                                     visible: optionalTab, oldVisible: { oldVisible }, addresses: addresses)
            try check(host.records.first { $0.id == optional }?.patterns.keys.contains(loopback.string) != true, "the removed optional host stayed in the record")
        }
        do {
            let reapproved = try await request(), reapprovedRead = try await fetch(from: optionalTab)
            try check(reapproved && reapprovedRead == "read:200", "a re-approved optional host was not readable: approved=\(reapproved) fetch=\(reapprovedRead)")
            weak let oldVisible = controller.browsers[optionalTab]
            weak let oldContext = host.context(for: optional)
            let addresses = [optionalTab: address(optionalTab)]
            let before = generation(optional)
            // A short time limit on the existing grant through the exact public dictionary (the per-pattern setter
            // keeps an existing permanent expiry); shortening is not a withdrawal, the lapse is. Scoped, so the test
            // holds no strong reference to the context while it waits for the restart.
            do {
                guard let context = host.context(for: optional) else { throw Failure(description: "Renderer restart: no context before the expiry case") }
                var grants = context.grantedPermissionMatchPatterns
                try check(grants[loopback] != nil, "the re-approved grant is missing before the expiry case")
                grants[loopback] = Date(timeIntervalSinceNow: 2)
                context.grantedPermissionMatchPatterns = grants
                host.persistPermissions(context)
            }
            try check(generation(optional) == before, "shortening a grant restarted the extension before it lapsed")
            try await wait("a lapsed time-limited grant did not restart the extension", timeout: 15) { generation(optional) > before }
            try await checkRestarted("expiry", optional, from: before, identity: optionalIdentity, oldContext: { oldContext },
                                     visible: optionalTab, oldVisible: { oldVisible }, addresses: addresses)
            try check(host.records.first { $0.id == optional }?.patterns.keys.contains(loopback.string) != true, "the lapsed grant stayed in the record")
        }

        try await host.remove(id: requested)
        try await host.remove(id: optional)
        return checks
    }
}
