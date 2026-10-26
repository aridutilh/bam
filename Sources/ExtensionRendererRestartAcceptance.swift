import AppKit
import WebKit

/// Product acceptance for withdrawn website access reaching an extension's own pages shown in Bam tabs
/// (work/site-access-two-phase-final-contract.md: a withdrawal restarts the extension in two phases).
///
/// Real Bam tabs showing original fixture extensions' pages, against the loopback server (no CORS headers). For every
/// withdrawal path the restart must:
/// - at the withdrawal's return (phase A): advance the restart generation exactly once, be pending, have no context
///   and no renderer of the extension's pages;
/// - at the fresh load (the will-load seam, phase B): have every old renderer already deallocated;
/// - finish `.restarted` for that generation, with a NEW context of the same identity, the visible tab recreated
///   (background tabs stay renderer-less until selected), tab IDs and addresses kept, no access left in the fresh
///   context, and a credentialed fetch from the recreated product tab to the withdrawn host REFUSED.
/// Paths: the Site Access panel (Withhold), a restart whose fresh load fails (then Enable), an old renderer still held at
/// the release deadline (fail closed: no fresh load; then Enable), the extension's own permissions.remove, and a
/// time-limited grant lapsing. Re-allowing access must not restart.
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
        let earlierDeadline = BrowserExtensions.siteAccessRestartReleaseDeadline
        defer {
            host.permissionPrompt = earlierPrompt
            BrowserExtensions.siteAccessRestartLoadFault = nil
            BrowserExtensions.siteAccessRestartWillLoad = nil
            BrowserExtensions.siteAccessRestartReleaseDeadline = earlierDeadline
        }
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
            try await waitLoaded("the extension tab did not load", tab)
            return tab
        }
        func waitLoaded(_ message: String, _ tab: UUID) async throws {
            try await wait(message) { controller.browsers[tab]?.title == "renderer page" && controller.browsers[tab]?.isLoading == false }
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
        func site(_ id: UUID, _ choice: ExtensionSiteAccess.Mode) throws {
            guard let snapshot = host.siteAccess(id: id), let declarations = snapshot.declarations else { throw Failure(description: "Renderer restart: no Site Access snapshot") }
            _ = try host.performSiteAccess(id: id, profileID: profile, revision: snapshot.revision, displayed: declarations, change: .choose(choice))
        }
        /// An extension renderer for the tab: a page of the extension's own origin (an error page for a restarting or
        /// stopped extension is not one).
        func extensionRenderer(_ tab: UUID) -> Bool { controller.browsers[tab]?.url?.scheme == "webkit-extension" }

        /// One withdrawal and its restart, waited for by generation (contract review item 1). `withdraw` performs the
        /// withdrawal; `deferred` is true for the engine's native path (permissions.remove, expiry), which starts phase A
        /// later in its own task. `probes` are the old renderers, held only weakly; the will-load seam records whether
        /// all of them had deallocated when the fresh context was about to load (nil: phase B never loaded).
        struct Restart { let generation: UInt64; let result: BrowserExtensions.SiteAccessRestart; let releasedAtLoad: Bool? }
        func restart(_ label: String, _ id: UUID, tabs: [UUID], probes: [() -> WKWebView?], deferred: Bool = false, timeout: TimeInterval = 15,
                     withdraw: () async throws -> Void) async throws -> Restart {
            let before = generation(id)
            var releasedAtLoad: Bool?
            BrowserExtensions.siteAccessRestartWillLoad = { loading in if loading == id { releasedAtLoad = probes.allSatisfy { $0() == nil } } }
            defer { BrowserExtensions.siteAccessRestartWillLoad = nil }
            try await withdraw()
            if deferred { try await wait("\(label): the native withdrawal did not start a restart", timeout: timeout) { generation(id) > before } }
            let started = generation(id)
            try check(started == before + 1, "\(label): the restart generation is \(started) after \(before), not exactly one restart")
            if !deferred {
                // Phase A happened inside the withdrawal call: pending, no context, nothing of the extension rendered.
                try check(host.isRestarting(id: id) && host.context(for: id) == nil,
                          "\(label): at the withdrawal's return the restart was not pending, or a context was already loaded")
                try check(tabs.allSatisfy { !extensionRenderer($0) }, "\(label): an extension page was rendered while the restart was pending")
                try check(host.takeSiteAccessNotice(id: id)?.contains("Restarting") == true, "\(label): no restarting notice was recorded")
            }
            // nil would mean no retained result for this generation (unknown, or replaced by a newer restart).
            guard let result = await host.restartCompletion(id: id, generation: started) else {
                throw Failure(description: "Renderer restart: \(label): no result for restart generation \(started)")
            }
            try check(generation(id) == started, "\(label): another restart started while this one completed")
            return Restart(generation: started, result: result, releasedAtLoad: releasedAtLoad)
        }
        /// The shared post-restart contract for a completed restart of `id`. `oldContext` is the context captured
        /// (weakly) before the withdrawal: the fresh one must be a different object (if the old one is still alive it
        /// must not be the fresh one and must be unloaded; if it deallocated while the fresh one is alive, that proves it).
        func checkRestarted(_ label: String, _ id: UUID, _ restart: Restart, identity: (String, URL), oldContext: () -> WKWebExtensionContext?,
                            visible: UUID, background: UUID? = nil, addresses: [UUID: String?]) async throws {
            try check(restart.result == .restarted, "\(label): the restart finished \(restart.result), not .restarted")
            try check(restart.releasedAtLoad == true, "\(label): an old renderer was still allocated when the fresh context was about to load (seam: \(String(describing: restart.releasedAtLoad)))")
            guard let fresh = host.context(for: id) else { throw Failure(description: "Renderer restart: \(label): no context after the restart") }
            try check(!host.isRestarting(id: id) && fresh.isLoaded && fresh.uniqueIdentifier == identity.0 && fresh.baseURL == identity.1,
                      "\(label): the fresh context is not loaded, still restarting, or lost the extension's identity or base URL")
            if let old = oldContext() {
                try check(old !== fresh, "\(label): the restart kept the same context object instead of loading a new one")
                try check(!old.isLoaded && fresh.webExtensionController?.extensionContexts.contains(old) != true,
                          "\(label): the replaced context is still loaded or still in the extension controller")
            }
            if let background { try check(controller.browsers[background] == nil, "\(label): a background extension tab got a renderer during the restart") }
            try await waitLoaded("\(label): the visible extension tab was not recreated", visible)
            try check(addresses.allSatisfy { address($0.key) == $0.value }, "\(label): a tab's ID or address changed across the restart")
            try check(!fresh.hasAccess(to: targetURL) && !fresh.grantedPermissionMatchPatterns.keys.contains { $0.matches(targetURL) },
                      "\(label): the fresh context still holds access to the withdrawn host")
            try check(try await fetch(from: visible) == "refused", "\(label): the recreated extension tab could still read the withdrawn host")
        }

        // 0. Ordering discriminator (measured, not asserted; runs first so it reports even if a strict case fails): the
        // extension's tab is in the background when access is withheld; after the restart completes, the fixture waits
        // for the old renderer to deallocate, then selects the tab and fetches from a renderer created after the release.
        do {
            let ordering = try await install("ordering", ["host_permissions": ["http://127.0.0.1/*"]])
            let orderingTab = try await openTab(ordering, active: true)
            let grantedRead = try await fetch(from: orderingTab)
            var siteURL = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
            siteURL.path = "/index.html"; siteURL.query = "renderer-ordering"
            guard let siteTab = controller.openProfileTab(siteURL.url!, profileID: profile, active: true) else { throw Failure(description: "Renderer restart: no ordinary tab for the ordering stage") }
            opened.append(siteTab)
            try await wait("the ordinary tab did not load") { controller.browsers[siteTab]?.isLoading == false && controller.browsers[siteTab]?.url != nil }
            weak let oldRenderer = controller.browsers[orderingTab]
            let rendererBefore = oldRenderer != nil
            try site(ordering, .withheld)
            let allocatedAtReturn = oldRenderer != nil, pendingAtReturn = host.isRestarting(id: ordering)
            let completed = await host.restartCompletion(id: ordering, generation: generation(ordering)).map { "\($0)" } ?? "none"
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while oldRenderer != nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 40_000_000) }
            let releasedBeforeSelect = oldRenderer == nil
            controller.select(orderingTab)
            try await waitLoaded("the ordering tab did not load when selected", orderingTab)
            let afterRelease = try await fetch(from: orderingTab)
            print("RENDERER_ORDER stage=background-withhold grantedRead=\(grantedRead) backgroundRendererBefore=\(rendererBefore) " +
                  "oldAllocatedAtReturn=\(allocatedAtReturn) pendingAtReturn=\(pendingAtReturn) completed=\(completed) " +
                  "oldReleasedBeforeSelect=\(releasedBeforeSelect) fetchFromRendererCreatedAfterRelease=\(afterRelease)"); fflush(stdout)
            _ = host.takeSiteAccessNotice(id: ordering)
            try await host.remove(id: ordering)
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
            let panel = try await restart("panel withhold", requested, tabs: [visible, background], probes: [{ oldVisible }, { oldBackground }]) {
                try site(requested, .withheld)
            }
            try await checkRestarted("panel withhold", requested, panel, identity: requestedIdentity, oldContext: { oldContext },
                                     visible: visible, background: background, addresses: addresses)
        }
        // The background tab gets a fresh renderer when selected, also refused.
        controller.select(background)
        try await waitLoaded("the background extension tab did not load when selected", background)
        try check(try await fetch(from: background) == "refused", "a background extension tab selected after the restart could still read the withdrawn host")
        // Re-allowing access never restarts, and the current renderer then reads again.
        func reallow() async throws {
            weak let current = controller.browsers[background]
            let before = generation(requested)
            try site(requested, .allRequested)
            try check(generation(requested) == before && !host.isRestarting(id: requested) && controller.browsers[background] === current &&
                      host.takeSiteAccessNotice(id: requested) == nil, "re-allowing access restarted the extension or replaced its renderer")
            try check(try await fetch(from: background) == "read:200", "re-allowed access was not readable from the extension tab")
        }
        try await reallow()

        // 2. A restart whose fresh load fails: stopped, the visible tab shows the unavailable error; Enable restores it.
        do {
            weak let oldVisible = controller.browsers[background]
            BrowserExtensions.siteAccessRestartLoadFault = { id in id == requested ? Failure(description: "fixture load fault") : nil }
            defer { BrowserExtensions.siteAccessRestartLoadFault = nil }
            let failed = try await restart("failed restart", requested, tabs: [background], probes: [{ oldVisible }]) { try site(requested, .withheld) }
            if case .loadFailed = failed.result {} else { throw Failure(description: "Renderer restart: a faulted fresh load finished \(failed.result), not .loadFailed") }
            try check(failed.releasedAtLoad == true && host.context(for: requested) == nil && !host.isRestarting(id: requested) &&
                      host.records.first { $0.id == requested }?.enabled == false, "a failed restart did not leave the extension stopped and disabled after releasing its renderers")
            try await wait("the visible tab of a stopped extension did not show the unavailable error") { controller.tabErrors[background]?.contains("unavailable") == true }
        }
        func enableAndCheck(_ label: String) async throws {
            try await host.setEnabled(true, id: requested)
            try await wait("\(label): Enable did not restore the extension tab") {
                controller.browsers[background]?.title == "renderer page" && controller.browsers[background]?.isLoading == false && controller.tabErrors[background] == nil
            }
            let enabled = host.context(for: requested)
            try check(enabled?.isLoaded == true && enabled?.uniqueIdentifier == requestedIdentity.0 && enabled?.baseURL == requestedIdentity.1,
                      "\(label): Enable lost the extension's identity or base URL: \(String(describing: enabled?.uniqueIdentifier)) \(String(describing: enabled?.baseURL))")
            try check(try await fetch(from: background) == "refused", "\(label): after Enable, the extension tab could still read the withheld host")
        }
        try await enableAndCheck("after a failed load")

        // 3. Fail closed: an old renderer still allocated at the release deadline (the fixture holds it strongly) means
        // no fresh load at all; the extension stays off until Enable after the renderer is released.
        try await reallow()
        do {
            // Premise: a Bam renderer exists and the fixture holds it strongly through every await below (pinned with
            // withExtendedLifetime after the last one, so optimized ARC can't release it early); released at scope end.
            let held = controller.browsers[background]
            try check(held != nil, "the release-timeout case has no Bam renderer to hold (premise)")
            BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
            let timedOut = try await restart("release timeout", requested, tabs: [background], probes: [{ held }]) { try site(requested, .withheld) }
            BrowserExtensions.siteAccessRestartReleaseDeadline = earlierDeadline
            if case .releaseTimedOut = timedOut.result {} else { throw Failure(description: "Renderer restart: a held old renderer finished \(timedOut.result), not .releaseTimedOut") }
            try check(timedOut.releasedAtLoad == nil && host.context(for: requested) == nil && !host.isRestarting(id: requested) &&
                      host.records.first { $0.id == requested }?.enabled == false && timedOut.result.failure?.isEmpty == false,
                      "a release timeout loaded the fresh context, or did not leave the extension off with an error")
            try await wait("the visible tab of a timed-out restart did not show the unavailable error") { controller.tabErrors[background]?.contains("unavailable") == true }
            withExtendedLifetime(held) {}
        }
        try await enableAndCheck("after a release timeout")

        // 4 and 5. Native withdrawals of an optional host: the extension's own permissions.remove, and expiry.
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
            // The page's own call may hold its renderer until the call returns: phase B waits for that, the fixture
            // retires nothing itself.
            weak let oldVisible = controller.browsers[optionalTab]
            weak let oldContext = host.context(for: optional)
            let addresses = [optionalTab: address(optionalTab)]
            let removal = try await restart("permissions.remove", optional, tabs: [optionalTab], probes: [{ oldVisible }], deferred: true) {
                let removed = try await controller.browsers[optionalTab]?.callAsyncJavaScript(
                    "return await browser.permissions.remove({origins: ['http://127.0.0.1/*']});", arguments: [:], contentWorld: .page) as? Bool
                try check(removed == true, "permissions.remove did not report success")
            }
            try await checkRestarted("permissions.remove", optional, removal, identity: optionalIdentity, oldContext: { oldContext },
                                     visible: optionalTab, addresses: addresses)
            try check(host.records.first { $0.id == optional }?.patterns.keys.contains(loopback.string) != true, "the removed optional host stayed in the record")
        }
        do {
            let reapproved = try await request(), reapprovedRead = try await fetch(from: optionalTab)
            try check(reapproved && reapprovedRead == "read:200", "a re-approved optional host was not readable: approved=\(reapproved) fetch=\(reapprovedRead)")
            weak let oldVisible = controller.browsers[optionalTab]
            weak let oldContext = host.context(for: optional)
            let addresses = [optionalTab: address(optionalTab)]
            let before = generation(optional)
            let lapse = try await restart("expiry", optional, tabs: [optionalTab], probes: [{ oldVisible }], deferred: true) {
                // A short time limit on the existing grant through the exact public dictionary (the per-pattern setter
                // keeps an existing permanent expiry); shortening is not a withdrawal, the lapse is. Scoped, so the test
                // holds no strong reference to the context while it waits for the restart.
                guard let context = host.context(for: optional) else { throw Failure(description: "Renderer restart: no context before the expiry case") }
                var grants = context.grantedPermissionMatchPatterns
                try check(grants[loopback] != nil, "the re-approved grant is missing before the expiry case")
                grants[loopback] = Date(timeIntervalSinceNow: 2)
                context.grantedPermissionMatchPatterns = grants
                host.persistPermissions(context)
                try check(generation(optional) == before && !host.isRestarting(id: optional), "shortening a grant restarted the extension before it lapsed")
            }
            try await checkRestarted("expiry", optional, lapse, identity: optionalIdentity, oldContext: { oldContext },
                                     visible: optionalTab, addresses: addresses)
            try check(host.records.first { $0.id == optional }?.patterns.keys.contains(loopback.string) != true, "the lapsed grant stayed in the record")
        }

        try await host.remove(id: requested)
        try await host.remove(id: optional)
        return checks
    }
}
