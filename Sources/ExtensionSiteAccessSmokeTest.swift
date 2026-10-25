import AppKit
import WebKit

/// Site Access lifecycle on real WebKit content scripts: an original fixture extension marks every document it can
/// inject into (a DOM attribute from JS and a CSS custom property from its stylesheet). Each step proves a NEW document
/// by the page's own per-document identity, then reads both markers:
///   allow → markers; withhold → no access (global and in the exact tab) → controller.load (the Reload Pages path),
///   web.reload() (toolbar/previews), a fresh-query navigation, and a brand-new tab → no markers in any new document;
///   allow again → markers return.
/// Runtime prompts while withheld are declined and recorded. Native only (root wires the call into the extension
/// suite); no account, no vendor code, an ephemeral controller and an owned temporary package per variant.
///
/// Two variants, all-host first (WebKit has a separate all-host injection/coalescing path):
///   - all-host: host_permissions `*://*/*`, content scripts on `<all_urls>` (the shape Dark Reader requests),
///     visiting only the loopback page;
///   - single-host control: host_permissions and content scripts on `http://127.0.0.1/*`.
/// Both variants always run. Withheld findings don't stop a variant (its restoration control still runs); every
/// finding from every variant is reported together, and the suite fails if there is any.
@MainActor @available(macOS 15.4, *)
enum ExtensionSiteAccessSmokeTest {
    static let jsMarker = "bamSiteAccessMarker"
    static let cssProperty = "--bam-site-access-marker"

    struct Variant {
        let name: String
        let hostPermissions: [String]
        let matches: [String]
        static let allHost = Variant(name: "all-host", hostPermissions: ["*://*/*"], matches: ["<all_urls>"])
        static let singleHost = Variant(name: "single-host", hostPermissions: ["http://127.0.0.1/*"], matches: ["http://127.0.0.1/*"])
    }

    /// `pageURL` is any page on the loopback fixture origin; this suite uses its own `/site-access-lifecycle.html`.
    static func run(pageURL: URL) async throws -> Int {
        var checks = 0, failures: [String] = []
        for variant in [Variant.allHost, .singleHost] {
            do {
                let (passed, findings) = try await run(pageURL: pageURL, variant: variant)
                checks += passed
                failures += findings.map { "(\(variant.name)) \($0)" }
            } catch { failures.append("(\(variant.name)) \(error)") }
        }
        guard failures.isEmpty else {
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: \(failures.count) finding(s):\n- " + failures.joined(separator: "\n- "))
        }
        return checks
    }

    /// Returns the variant's passed checks and its findings (withheld-step failures). Setup and navigation failures throw.
    static func run(pageURL: URL, variant: Variant) async throws -> (Int, [String]) {
        var checks = 0, findings: [String] = []
        var prompts: [BrowserExtensionPermissionReview] = []
        var reloadOffers = 0
        /// The live granted keys just before withholding (broad-pattern coalescing diagnosis).
        var preWithholdGranted: [String] = []
        func fail(_ message: String) -> ExtensionSmokeTest.Failure { .init(description: "Site access lifecycle (\(variant.name)): " + message) }

        // MARK: Page URL on the same fixture origin.
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/site-access-lifecycle.html"; components.query = nil; components.fragment = nil
        guard let page = components.url, page.scheme == "http", page.host == "127.0.0.1" else {
            throw fail("needs the loopback fixture origin, got \(pageURL)")
        }
        func query(_ value: String) -> URL { page.appending(queryItems: [URLQueryItem(name: "fresh", value: value)]) }

        // MARK: Original fixture package in an owned temporary directory.
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("bam-site-access-lifecycle-\(variant.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Bam Site Access Lifecycle Fixture", "version": "1.0.0",
            "description": "Original fixture: marks each document its content script and stylesheet reach.",
            "host_permissions": variant.hostPermissions,
            "content_scripts": [["matches": variant.matches, "js": ["marker.js"], "css": ["marker.css"], "run_at": "document_start"]]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: package.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.\(jsMarker) = 'js';\n".utf8).write(to: package.appendingPathComponent("marker.js"))
        try Data("html { \(cssProperty): injected; }\n".utf8).write(to: package.appendingPathComponent("marker.css"))

        // MARK: Ephemeral browser, as the extension suite does.
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-site-access-session-\(UUID().uuidString).json"), ephemeral: true)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let profile = controller.session.currentProfileID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 650))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        defer { controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close() }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }                  // the install review only
        host.onReloadNeeded = { _ in reloadOffers += 1 }       // recorded; this suite reloads through the same calls itself
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(configuration, profileID: profile)
        let extensionID = try await host.importPackage(at: package, profileID: profile)
        guard let context = host.context(for: extensionID) else {
            throw fail("fixture did not load: \(host.errors[extensionID] ?? host.lastError ?? "no error")")
        }
        let runtime = configuration.webExtensionController?.delegate as? BrowserExtensionRuntime
        // After install, any runtime prompt is unexpected here: record and decline it.
        host.permissionPrompt = { review in prompts.append(review); return false }

        // MARK: Observation helpers.
        struct DocumentState: CustomStringConvertible {
            var document = "", js = "", css = "", readyState = "", url = ""
            var description: String { "document=\(document) js=\(js.isEmpty ? "absent" : js) css=\(css.isEmpty ? "absent" : css) readyState=\(readyState) url=\(url)" }
        }
        func read(_ web: WKWebView) async -> DocumentState? {
            let script = """
                JSON.stringify({document: document.documentElement.dataset.bamDocument || '', js: document.documentElement.dataset.\(jsMarker) || '',
                  css: getComputedStyle(document.documentElement).getPropertyValue('\(cssProperty)').trim(), readyState: document.readyState, url: location.href})
                """
            guard let text = try? await web.evaluateJavaScript(script) as? String, let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
            return DocumentState(document: value["document"] ?? "", js: value["js"] ?? "", css: value["css"] ?? "",
                                 readyState: value["readyState"] ?? "", url: value["url"] ?? "")
        }
        /// Access in the exact extension tab (runtime adapter), or nil when the adapter is missing.
        func tabAccess(_ tabID: UUID) -> (access: Bool, status: Int)? {
            host.reconcile()
            guard let adapter = runtime?.tabs[tabID] else { return nil }
            return (context.hasAccess(to: page, in: adapter), context.permissionStatus(for: page, in: adapter).rawValue)
        }
        func diagnostics(_ tabID: UUID?, _ state: DocumentState?) -> String {
            let web = tabID.flatMap { controller.browsers[$0] }
            let snapshot = host.siteAccess(id: extensionID)
            let scoped = tabID.flatMap(tabAccess).map { "tabAccess=\($0.access) tabStatus=\($0.status)" } ?? "tabAdapter=missing"
            let granted = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
            let denied = context.deniedPermissionMatchPatterns.keys.map(\.string).sorted()
            return "[state: \(state.map(String.init(describing:)) ?? "unreadable"); webURL=\(web?.url?.absoluteString ?? "nil") isLoading=\(web?.isLoading ?? false)"
                + "; hasAccess=\(context.hasAccess(to: page)) status=\(context.permissionStatus(for: page).rawValue) \(scoped) granted=\(granted) denied=\(denied)"
                + "; mode=\(snapshot.map { String(describing: $0.state.mode) } ?? "nil") effective=\(snapshot?.effective ?? [])"
                + "; hasInjectedContent(for:)=\(context.hasInjectedContent(for: page)) prompts=\(prompts.map(\.websites)) reloadOffers=\(reloadOffers)"
                + "; preWithholdGranted=\(preWithholdGranted)]"
        }
        /// Waits until the tab shows a fully loaded document other than `previous` (the page's own identity) whose URL
        /// starts with `expected`, then returns its markers. Navigation completion is the evidence; polling only waits.
        func newDocument(after previous: String?, in tabID: UUID, expected: URL, _ step: String) async throws -> DocumentState {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var last: DocumentState?
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let web = controller.browsers[tabID], !web.isLoading, let state = await read(web) {
                    last = state
                    if !state.document.isEmpty, state.document != previous, state.readyState == "complete", state.url.hasPrefix(expected.absoluteString) {
                        checks += 1; return state
                    }
                }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw fail("\(step): no new completed document " + diagnostics(tabID, last))
        }
        func injected(_ state: DocumentState) -> Bool { state.js == "js" && state.css == "injected" }
        func absent(_ state: DocumentState) -> Bool { state.js.isEmpty && state.css.isEmpty }
        /// A withheld step: no access globally or in the exact tab, and no marker in its new document. Findings are
        /// recorded with full diagnostics; the variant continues so the restoration control still runs.
        func expectWithheld(_ state: DocumentState, in tabID: UUID, _ step: String) {
            var problems: [String] = []
            if context.hasAccess(to: page) { problems.append("global access") }
            if let scoped = tabAccess(tabID) { if scoped.access { problems.append("access in the exact tab") } } else { problems.append("no tab adapter to check tab access") }
            if !state.js.isEmpty { problems.append("JS marker present") }
            if !state.css.isEmpty { problems.append("CSS property present") }
            if problems.isEmpty { checks += 1 } else { findings.append("\(step): " + problems.joined(separator: ", ") + " " + diagnostics(tabID, state)) }
        }

        // MARK: 1. Allowed: the first document is marked (positive control: the harness sees injection).
        guard host.siteAccess(id: extensionID)?.state.mode == .allRequested, context.hasAccess(to: page) else {
            throw fail("the install did not allow the fixture site " + diagnostics(nil, nil))
        }
        guard let tabID = controller.openProfileTab(page, profileID: profile, active: true) else { throw fail("could not open the fixture page") }
        let allowed = try await newDocument(after: nil, in: tabID, expected: page, "allowed")
        guard injected(allowed) else { throw fail("allowed document lacks the JS marker or the CSS property " + diagnostics(tabID, allowed)) }
        checks += 1

        // MARK: 2. Withhold through the real engine API.
        guard let before = host.siteAccess(id: extensionID), let shown = before.declarations else { throw fail("no editable snapshot " + diagnostics(tabID, nil)) }
        preWithholdGranted = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        let withheld = try host.performSiteAccess(id: extensionID, profileID: profile, revision: before.revision, displayed: shown, change: .choose(.withheld))
        guard withheld.state.mode == .withheld else { throw fail("the engine did not withhold " + diagnostics(tabID, nil)) }
        checks += 1

        // MARK: 3–6. Withheld documents: Reload Pages path, toolbar reload, fresh query, brand-new tab.
        guard let tab = controller.session.tabs.first(where: { $0.id == tabID }), let web = controller.browsers[tabID] else { throw fail("the fixture tab disappeared") }
        controller.load(tab.address, in: web, id: tabID)
        let reloaded = try await newDocument(after: allowed.document, in: tabID, expected: page, "withheld controller.load")
        expectWithheld(reloaded, in: tabID, "controller.load (Reload Pages path)")

        controller.browsers[tabID]?.reload()
        let toolbar = try await newDocument(after: reloaded.document, in: tabID, expected: page, "withheld web.reload")
        expectWithheld(toolbar, in: tabID, "web.reload (toolbar)")

        let fresh = query("withheld")
        if let current = controller.browsers[tabID] { controller.load(fresh.absoluteString, in: current, id: tabID) }
        let queried = try await newDocument(after: toolbar.document, in: tabID, expected: fresh, "withheld fresh query")
        expectWithheld(queried, in: tabID, "fresh query navigation")

        let newTabURL = query("new-tab")
        guard let newTab = controller.openProfileTab(newTabURL, profileID: profile, active: true) else { throw fail("could not open a new tab " + diagnostics(tabID, nil)) }
        let newTabDocument = try await newDocument(after: nil, in: newTab, expected: newTabURL, "withheld new tab")
        expectWithheld(newTabDocument, in: newTab, "brand-new tab (new web view)")

        // MARK: 7. Allow again → new documents are marked again (restoration control; runs whatever was found).
        guard let current = host.siteAccess(id: extensionID), let declarations = current.declarations else { throw fail("no snapshot to allow again " + diagnostics(tabID, nil)) }
        let restored = try host.performSiteAccess(id: extensionID, profileID: profile, revision: current.revision, displayed: declarations, change: .choose(.allRequested))
        guard restored.state.mode == .allRequested, context.hasAccess(to: page) else { throw fail("allowing again did not restore access " + diagnostics(tabID, nil)) }
        guard let again = controller.browsers[tabID] else { throw fail("the fixture tab disappeared") }
        controller.load(tab.address, in: again, id: tabID)
        let reallowed = try await newDocument(after: queried.document, in: tabID, expected: page, "allowed again")
        if injected(reallowed) { checks += 1 } else { findings.append("after allowing again, the new document isn't marked " + diagnostics(tabID, reallowed)) }

        // Prompts while withheld were declined and are reported, not asserted.
        print("BAM_SITE_ACCESS_LIFECYCLE " + "{\"variant\":\"\(variant.name)\",\"pre_withhold_granted\":\(preWithholdGranted),\"findings\":\(findings.count),\"prompts_while_withheld\":\(prompts.count),\"reload_offers\":\(reloadOffers),\"documents\":6}"); fflush(stdout)
        return (checks, findings)
    }
}
