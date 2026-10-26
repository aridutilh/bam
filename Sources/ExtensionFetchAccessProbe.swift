import AppKit
import WebKit

/// Diagnostic for work/implicit-consent-native-fetch-failure-task.md: does an extension page's credentialed CORS fetch
/// to a loopback page follow the extension's *current* host access, or does access outlive a withdrawal?
///
/// Two original fixtures in the caller's profile, against the test server (no CORS headers):
/// - "optional": 127.0.0.1 only in optional_host_permissions. Fresh (never granted), after permissions.request,
///   after permissions.remove, and in a new page after the removal.
/// - "requested": 127.0.0.1 in host_permissions (granted at install). Granted, after Site Access withholds it (same
///   page), in a new page, and in a new context loaded while withheld (disable + enable).
/// Every stage prints one `FETCH_ACCESS` line: the fetch outcome (status, type, final URL, Access-Control-Allow-Origin,
/// body length, or the error) and the native state (permission status, hasAccess, granted and denied 127 keys).
/// Only the premises are asserted: a never-granted host is refused (the server and engine enforce CORS here) and a
/// granted host is readable. The stages after a withdrawal are measurements; the strict expectations are
/// BrowserExtensionSmokeTest's explicit-consent check and ExtensionRendererRestartAcceptance.
/// Scope: a lifetime diagnostic only (`--extension-fetch-only`, not in the full run). Its pages are raw WKWebViews Bam
/// doesn't manage, deliberately held across withdrawals, so the two-phase restart neither waits for nor retires them;
/// the probe only awaits each restart's completion (FETCH_ACCESS_RESTART) before building a page on the fresh context.
@available(macOS 15.4, *)
@MainActor enum ExtensionFetchAccessProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(controller: BrowserController, host: BrowserExtensions, profile: UUID, pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: "Fetch access: " + message) }; checks += 1
        }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw Failure(description: "Fetch access: " + message)
        }
        let earlierPrompt = host.permissionPrompt
        defer { host.permissionPrompt = earlierPrompt }
        host.permissionPrompt = { _ in true }
        var target = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        target.path = "/next.html"; target.query = "fetch-access"
        let targetURL = target.url!
        let loopback = try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*")

        func install(_ name: String, _ manifest: [String: Any]) async throws -> UUID {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-fetch-access-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var definition = manifest
            definition["manifest_version"] = 3; definition["name"] = "Bam fetch access \(name)"; definition["version"] = "1.0"
            definition["description"] = "Original Bam fixture measuring extension-page fetch access (\(name) host)."
            try JSONSerialization.data(withJSONObject: definition).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><meta charset='utf-8'><title>fetch access page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
            return try await host.importPackage(at: folder, profileID: profile)
        }
        /// Every probe-owned extension page, weakly, so the closed-pages stage can observe that each one was released.
        final class TrackedPage { weak var web: WKWebView?; let label: String; init(_ web: WKWebView, _ label: String) { self.web = web; self.label = label } }
        var tracked: [TrackedPage] = []
        func page(_ id: UUID, _ name: String) async throws -> WKWebView {
            guard let context = host.context(for: id), let configuration = context.webViewConfiguration else { throw Failure(description: "Fetch access: no context for \(id)") }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
            tracked.append(TrackedPage(web, "\(name)#\(tracked.count)"))
            web.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            try await wait("an extension page did not load") { web.title == "fetch access page" }
            return web
        }
        func js(_ web: WKWebView, _ body: String) async throws -> [String: Any] {
            let text = try await web.callAsyncJavaScript("return JSON.stringify(await (async () => {\n" + body + "\n})());",
                                                          arguments: ["target": targetURL.absoluteString], contentWorld: .page) as? String
            guard let data = text?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(description: "Fetch access: probe returned \(text ?? "nil")")
            }
            return value
        }
        /// One stage: the fetch outcome and the native state, printed and returned ("read" or "refused").
        func measure(_ stage: String, _ id: UUID, _ web: WKWebView) async throws -> String {
            let fetched = try await js(web, """
                try {
                  const r = await fetch(target, {credentials: 'include', cache: 'no-store'});
                  const body = await r.text();
                  return {outcome: 'read', status: r.status, type: r.type, url: r.url, acao: r.headers.get('access-control-allow-origin'), length: body.length};
                } catch (error) { return {outcome: 'refused', error: String(error && error.message || error)}; }
                """)
            let context = host.context(for: id)
            let granted = context?.grantedPermissionMatchPatterns.filter { $0.key.string.contains("127.0.0.1") }.map { "\($0.key.string)=\($0.value)" }.sorted() ?? []
            let denied = context?.deniedPermissionMatchPatterns.filter { $0.key.string.contains("127.0.0.1") }.map { "\($0.key.string)=\($0.value)" }.sorted() ?? []
            let native = "status=\(context.map { String($0.permissionStatus(for: targetURL).rawValue) } ?? "no-context") hasAccess=\(context?.hasAccess(to: targetURL) ?? false) " +
                "patternStatus=\(context.map { String($0.permissionStatus(for: loopback).rawValue) } ?? "-") granted=\(granted) denied=\(denied) " +
                "siteAccess=\(String(describing: host.siteAccess(id: id)?.state.mode))"
            print("FETCH_ACCESS stage=\(stage) fetch=\(fetched) native=\(native)"); fflush(stdout)
            return fetched["outcome"] as? String ?? "?"
        }
        /// A withdrawal restarts the extension in two phases (work/site-access-two-phase-final-contract.md): no context
        /// until it completes. Waits (bounded) for the restart after `before` to start, since the engine's native path
        /// starts it later, then for that generation's result, and reports both; the next page needs the fresh context.
        func settleRestart(_ stage: String, _ id: UUID, from before: UInt64) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while (host.restartGeneration[id] ?? 0) == before && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let started = host.restartGeneration[id] ?? 0
            let result = started == before ? "no-restart" : await host.restartCompletion(id: id, generation: started).map { "\($0)" } ?? "no-result"
            print("FETCH_ACCESS_RESTART stage=\(stage) generations=\(started - before) result=\(result)"); fflush(stdout)
        }

        let optionalID = try await install("optional", ["optional_host_permissions": ["http://127.0.0.1/*"]])
        let requestedID = try await install("requested", ["host_permissions": ["http://127.0.0.1/*"]])
        // On a failure these fixtures stay in the caller's ephemeral controller until it shuts down; on success they are
        // removed below.
        var optionalPage: WKWebView? = try await page(optionalID, "optional")
        // Premise: a host this extension was never granted is refused (no CORS headers; WebKit enforces CORS here).
        let fresh = try await measure("optional-fresh", optionalID, optionalPage!)
        try check(fresh == "refused", "a never-granted loopback page was readable by fetch, so the server or engine does not enforce CORS here and the consent fetch check has no valid premise")
        let requested = try await js(optionalPage!, "return {granted: await browser.permissions.request({origins: ['http://127.0.0.1/*']})};")
        let afterRequest = try await measure("optional-after-request(granted=\(requested["granted"] ?? "?"))", optionalID, optionalPage!)
        try check(requested["granted"] as? Bool == true && afterRequest == "read", "a granted loopback host was not readable by fetch (positive control)")
        let beforeRemove = host.restartGeneration[optionalID] ?? 0
        let removed = try await js(optionalPage!, "return {removed: await browser.permissions.remove({origins: ['http://127.0.0.1/*']})};")
        _ = try await measure("optional-after-remove(removed=\(removed["removed"] ?? "?"))-same-page", optionalID, optionalPage!)
        // The old page stays held (unmanaged by Bam, so the restart doesn't wait for it) until its successor exists, as
        // before two-phase: the lifetime evidence is unchanged; only the successor waits for the fresh context.
        optionalPage?.stopLoading()
        try await settleRestart("optional-after-remove", optionalID, from: beforeRemove)
        optionalPage = try await page(optionalID, "optional")
        _ = try await measure("optional-after-remove-new-page", optionalID, optionalPage!)
        optionalPage?.stopLoading()

        var requestedPage: WKWebView? = try await page(requestedID, "requested")
        _ = try await measure("requested-granted", requestedID, requestedPage!)
        guard let snapshot = host.siteAccess(id: requestedID), let declarations = snapshot.declarations else { throw Failure(description: "Fetch access: no Site Access snapshot") }
        let beforeWithhold = host.restartGeneration[requestedID] ?? 0
        _ = try host.performSiteAccess(id: requestedID, profileID: profile, revision: snapshot.revision, displayed: declarations, change: .choose(.withheld))
        _ = try await measure("requested-withheld-same-page", requestedID, requestedPage!)
        requestedPage?.stopLoading()
        try await settleRestart("requested-withheld", requestedID, from: beforeWithhold)
        requestedPage = try await page(requestedID, "requested")
        _ = try await measure("requested-withheld-new-page", requestedID, requestedPage!)
        requestedPage?.stopLoading()
        try await host.setEnabled(false, id: requestedID); try await host.setEnabled(true, id: requestedID)
        requestedPage = try await page(requestedID, "requested")
        _ = try await measure("requested-withheld-new-context", requestedID, requestedPage!)
        requestedPage?.stopLoading()

        // F1 discriminator: the same withheld state, but in a context loaded after every probe-owned extension page has
        // left the extension origin and been released (stopLoading alone keeps a document; a reassigned page used to be
        // released only after its successor existed). Separates "a held old client keeps the process and its CORS
        // allowlist" from "a context with no old clients". Nothing is deleted and no identity changes.
        // Two different facts, reported separately: whether a held page navigated off the extension origin, and
        // whether every page the probe created was deallocated. A failed navigation is not an allocated page.
        var navigationFailures: [String] = []
        for (name, web) in [("optional", optionalPage), ("requested", requestedPage)] {
            guard let web else { continue }
            web.stopLoading()
            web.load(URLRequest(url: URL(string: "about:blank")!))
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline, !(web.url?.absoluteString == "about:blank" && !web.isLoading) {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            if !(web.url?.absoluteString == "about:blank" && !web.isLoading) {
                navigationFailures.append("\(name): still url=\(web.url?.absoluteString ?? "nil") loading=\(web.isLoading) after 5 s")
            }
        }
        optionalPage = nil; requestedPage = nil
        let releaseDeadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < releaseDeadline, tracked.contains(where: { $0.web != nil }) {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let stillAllocated = tracked.filter { $0.web != nil }.map(\.label)
        print("FETCH_ACCESS_CLOSE pages=\(tracked.count) deallocated=\(tracked.count - stillAllocated.count) stillAllocated=\(stillAllocated) " +
              "navigationFailures=\(navigationFailures)"); fflush(stdout)
        try await host.setEnabled(false, id: requestedID); try await host.setEnabled(true, id: requestedID)
        let closedPagesPage = try await page(requestedID, "requested-after-close")
        _ = try await measure("requested-withheld-closed-pages-new-context(stillAllocated=\(stillAllocated.count),navigationFailures=\(navigationFailures.count))",
                              requestedID, closedPagesPage)
        closedPagesPage.stopLoading()

        try await host.remove(id: optionalID)
        try await host.remove(id: requestedID)
        return checks
    }
}
