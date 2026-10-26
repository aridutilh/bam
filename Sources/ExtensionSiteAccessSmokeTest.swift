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
/// Variants, broad forms first (WebKit has a separate all-host injection/coalescing path), visiting only loopback:
///   - all-host: host_permissions `*://*/*`, content scripts on `<all_urls>` (the shape Dark Reader requests);
///   - canonical only: `*://*/*` for both; `<all_urls>` only: content scripts, no host_permissions;
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
        /// Both broad forms, as Dark Reader declares them (grants `*://*/*` and `<all_urls>`).
        static let allHost = Variant(name: "all-host", hostPermissions: ["*://*/*"], matches: ["<all_urls>"])
        /// Only the canonical form (grants `*://*/*`).
        static let canonicalOnly = Variant(name: "all-host-canonical-only", hostPermissions: ["*://*/*"], matches: ["*://*/*"])
        /// Only `<all_urls>` (content scripts, no host_permissions): WebKit coalesces its injection under the canonical
        /// key, which no granted key matches; expected to stay a finding until a different public path exists.
        static let allURLsOnly = Variant(name: "all-host-all-urls-only", hostPermissions: [], matches: ["<all_urls>"])
        static let singleHost = Variant(name: "single-host", hostPermissions: ["http://127.0.0.1/*"], matches: ["http://127.0.0.1/*"])
    }

    /// `pageURL` is any page on the loopback fixture origin; this suite uses its own `/site-access-lifecycle.html`.
    static func run(pageURL: URL) async throws -> Int {
        var checks = 0, failures: [String] = []
        for variant in [Variant.allHost, .canonicalOnly, .allURLsOnly, .singleHost] {
            do {
                let (passed, findings) = try await run(pageURL: pageURL, variant: variant)
                checks += passed
                failures += findings.map { "(\(variant.name)) \($0)" }
            } catch { failures.append("(\(variant.name)) \(error)") }
        }
        // The restart candidate's acceptance: storage, background restart, an unrelated extension, native IDs,
        // Revoke Permissions and a deliberate load failure with Enable recovery.
        do {
            let (passed, findings) = try await runRestart(pageURL: pageURL)
            checks += passed
            failures += findings.map { "(restart) \($0)" }
        } catch { failures.append("(restart) \(error)") }
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
        guard host.context(for: extensionID) != nil else {
            throw fail("fixture did not load: \(host.errors[extensionID] ?? host.lastError ?? "no error")")
        }
        /// A withdrawal restarts the extension into a fresh context (same identifier and base URL): always read the
        /// current one, never a context kept from before a step.
        func liveContext() -> WKWebExtensionContext? { host.context(for: extensionID) }
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
            guard let adapter = runtime?.tabs[tabID], let context = liveContext() else { return nil }
            return (context.hasAccess(to: page, in: adapter), context.permissionStatus(for: page, in: adapter).rawValue)
        }
        func diagnostics(_ tabID: UUID?, _ state: DocumentState?) -> String {
            let web = tabID.flatMap { controller.browsers[$0] }
            let snapshot = host.siteAccess(id: extensionID)
            let scoped = tabID.flatMap(tabAccess).map { "tabAccess=\($0.access) tabStatus=\($0.status)" } ?? "tabAdapter=missing"
            let context = liveContext()
            let granted = context?.grantedPermissionMatchPatterns.keys.map(\.string).sorted() ?? []
            let denied = context?.deniedPermissionMatchPatterns.keys.map(\.string).sorted() ?? []
            return "[state: \(state.map(String.init(describing:)) ?? "unreadable"); webURL=\(web?.url?.absoluteString ?? "nil") isLoading=\(web?.isLoading ?? false)"
                + "; context=\(context.map { "loaded:\($0.isLoaded)" } ?? "none") hasAccess=\(context?.hasAccess(to: page) ?? false) status=\(context?.permissionStatus(for: page).rawValue ?? -1) \(scoped) granted=\(granted) denied=\(denied)"
                + "; mode=\(snapshot.map { String(describing: $0.state.mode) } ?? "nil") effective=\(snapshot?.effective ?? [])"
                + "; hasInjectedContent(for:)=\(context?.hasInjectedContent(for: page) ?? false) prompts=\(prompts.map(\.websites)) reloadOffers=\(reloadOffers)"
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
            if let context = liveContext() { if context.hasAccess(to: page) { problems.append("global access") } } else { problems.append("no loaded context") }
            if let scoped = tabAccess(tabID) { if scoped.access { problems.append("access in the exact tab") } } else { problems.append("no tab adapter to check tab access") }
            if !state.js.isEmpty { problems.append("JS marker present") }
            if !state.css.isEmpty { problems.append("CSS property present") }
            if problems.isEmpty { checks += 1 } else { findings.append("\(step): " + problems.joined(separator: ", ") + " " + diagnostics(tabID, state)) }
        }

        // MARK: 1. Allowed: the first document is marked (positive control: the harness sees injection).
        guard host.siteAccess(id: extensionID)?.state.mode == .allRequested, liveContext()?.hasAccess(to: page) == true else {
            throw fail("the install did not allow the fixture site " + diagnostics(nil, nil))
        }
        guard let tabID = controller.openProfileTab(page, profileID: profile, active: true) else { throw fail("could not open the fixture page") }
        let allowed = try await newDocument(after: nil, in: tabID, expected: page, "allowed")
        guard injected(allowed) else { throw fail("allowed document lacks the JS marker or the CSS property " + diagnostics(tabID, allowed)) }
        checks += 1

        // MARK: 2. Withhold through the real engine API.
        guard let before = host.siteAccess(id: extensionID), let shown = before.declarations else { throw fail("no editable snapshot " + diagnostics(tabID, nil)) }
        preWithholdGranted = liveContext()?.grantedPermissionMatchPatterns.keys.map(\.string).sorted() ?? []
        let withheld = try host.performSiteAccess(id: extensionID, profileID: profile, revision: before.revision, displayed: shown, change: .choose(.withheld))
        // Two-phase restart (work/site-access-two-phase-final-contract.md): wait for this generation's result.
        let restartGeneration = host.restartGeneration[extensionID] ?? 0
        if host.isRestarting(id: extensionID) {
            let result = await host.restartCompletion(id: extensionID, generation: restartGeneration)
            guard result == .restarted else { throw fail("the withhold's restart ended \(String(describing: result)) " + diagnostics(nil, nil)) }
        }
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
        guard restored.state.mode == .allRequested, liveContext()?.hasAccess(to: page) == true else { throw fail("allowing again did not restore access " + diagnostics(tabID, nil)) }
        guard let again = controller.browsers[tabID] else { throw fail("the fixture tab disappeared") }
        controller.load(tab.address, in: again, id: tabID)
        let reallowed = try await newDocument(after: queried.document, in: tabID, expected: page, "allowed again")
        if injected(reallowed) { checks += 1 } else { findings.append("after allowing again, the new document isn't marked " + diagnostics(tabID, reallowed)) }

        // Prompts while withheld were declined and are reported, not asserted.
        print("BAM_SITE_ACCESS_LIFECYCLE " + "{\"variant\":\"\(variant.name)\",\"pre_withhold_granted\":\(preWithholdGranted),\"findings\":\(findings.count),\"prompts_while_withheld\":\(prompts.count),\"reload_offers\":\(reloadOffers),\"documents\":6}"); fflush(stdout)
        return (checks, findings)
    }
}

// MARK: - Restart acceptance (withdrawing a live host grant restarts the extension into a fresh context)

@MainActor @available(macOS 15.4, *)
extension ExtensionSiteAccessSmokeTest {
    /// A weak reference the fixture can hold without keeping a page alive.
    private final class WeakView { weak var web: WKWebView?; init(_ web: WKWebView?) { self.web = web } }

    /// Two original extensions in one ephemeral window whose extension host uses an **owned persistent**
    /// extension-controller store (a non-persistent store resets storage.local on unload; native 297f6eb), removed
    /// and verified afterwards:
    ///   A (subject): all-host (`*://*/*` + `<all_urls>`), JS and CSS markers, a background run counter and nonce in
    ///     storage.local, and `page.html`, opened as a real Bam tab (E);
    ///   B (unrelated): single host, its own marker and counter, its page also a Bam tab (F).
    /// Contract (work/extension-renderer-restart-fixture-contract.md): every withdrawal goes through public paths
    /// (performSiteAccess, revokePermissions); the context is re-read after each (a restart makes a fresh one with the
    /// same identifier and base URL); Bam retires and recreates E's renderer, keeping its tab ID and address.
    static func runRestart(pageURL: URL) async throws -> (Int, [String]) {
        var checks = 0, findings: [String] = []
        func fail(_ message: String) -> ExtensionSmokeTest.Failure { .init(description: "Site access restart: " + message) }
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/site-access-lifecycle.html"; components.query = nil; components.fragment = nil
        guard let page = components.url, page.host == "127.0.0.1" else { throw fail("needs the loopback fixture origin") }

        // MARK: Packages (original source, owned temporary directories).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-site-access-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func package(_ name: String, hosts: [String], matches: [String], marker: String, css: Bool, popup: Bool = false) throws -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var script: [String: Any] = ["matches": matches, "js": ["marker.js"], "run_at": "document_start"]
            if css { script["css"] = ["marker.css"] }
            var manifest: [String: Any] = [
                "manifest_version": 3, "name": "Bam Site Access Restart \(name)", "version": "1.0.0",
                "description": "Original fixture for the site-access restart.", "permissions": ["storage"],
                "host_permissions": hosts, "background": ["service_worker": "background.js"], "content_scripts": [script]
            ]
            if popup {
                manifest["action"] = ["default_popup": "popup.html"]
                try Data("<!doctype html><meta charset='utf-8'><title>restart fixture popup</title><p>popup</p>".utf8).write(to: folder.appendingPathComponent("popup.html"))
            }
            try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("document.documentElement.dataset.\(marker) = 'js';\n".utf8).write(to: folder.appendingPathComponent("marker.js"))
            if css { try Data("html { \(cssProperty): injected; }\n".utf8).write(to: folder.appendingPathComponent("marker.css")) }
            // Counts every evaluation of the background script (initial and after a restart), with a per-evaluation nonce.
            try Data("const run = crypto.randomUUID(); chrome.storage.local.get('starts').then(v => chrome.storage.local.set({starts: (v.starts || 0) + 1, lastRun: run}));\n".utf8)
                .write(to: folder.appendingPathComponent("background.js"))
            try Data("<!doctype html><meta charset='utf-8'><title>restart fixture page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
            return folder
        }
        let subjectPackage = try package("subject", hosts: ["*://*/*"], matches: ["<all_urls>"], marker: jsMarker, css: true, popup: true)
        let otherPackage = try package("other", hosts: ["http://127.0.0.1/*"], matches: ["http://127.0.0.1/*"], marker: "bamOtherMarker", css: false)

        // MARK: Ephemeral window, owned persistent extension-controller store.
        let storeID = UUID()
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-site-access-restart-\(UUID().uuidString).json"), ephemeral: true)
        controller.extensionHostOverride = ExtensionHostOverride(storageURL: root.appendingPathComponent("host", isDirectory: true), controllerIdentifier: storeID)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let profile = controller.session.currentProfileID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 650))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        let host = controller.browserExtensions
        var diagnostic: [String: Any] = ["store": "owned-persistent"]
        /// The persistent extension data an owned store holds (session storage is in memory and not part of it).
        let persistentDataTypes: Set<WKWebExtension.DataType> = [.local, .synchronized]
        var bodyError: Error?

        do {
            host.permissionPrompt = { _ in true }      // install reviews
            host.onReloadNeeded = { _ in }
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = controller.profileStores.store(for: profile)
            host.configure(configuration, profileID: profile)
            let subject = try await host.importPackage(at: subjectPackage, profileID: profile)
            let other = try await host.importPackage(at: otherPackage, profileID: profile)
            guard let firstContext = host.context(for: subject), let otherContext = host.context(for: other) else {
                throw fail("fixtures did not load: \(host.errors[subject] ?? host.errors[other] ?? host.lastError ?? "no error")")
            }
            let identity = (firstContext.uniqueIdentifier, firstContext.baseURL)
            let runtime = configuration.webExtensionController?.delegate as? BrowserExtensionRuntime
            var prompts = 0
            host.permissionPrompt = { _ in prompts += 1; return false }   // runtime prompts declined; Enable re-allowed below

            // MARK: Helpers.
            func evaluate(_ web: WKWebView, _ script: String) async -> [String: Any]? {
                guard let text = try? await web.callAsyncJavaScript(script, arguments: [:], contentWorld: .page) as? String,
                      let data = text.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            var rawPages: [WeakView] = []
            /// A raw (unmanaged, fixture-owned) page of `id`'s current context, for storage reads. Not a Bam tab: Bam's
            /// restart can't retire it, so it's always dropped right after use and tracked weakly.
            func extensionPage(_ id: UUID) async throws -> WKWebView {
                guard let context = host.context(for: id), let pageConfiguration = context.webViewConfiguration else { throw fail("no loaded context for an extension page \(state(id))") }
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: pageConfiguration)
                rawPages.append(WeakView(web))
                web.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if !web.isLoading, web.title == "restart fixture page" { return web }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
                throw fail("the extension page did not load")
            }
            func rawPagesAlive() -> Int { rawPages.filter { $0.web != nil }.count }
            struct Stored { var starts = 0; var survivor = ""; var lastRun = ""; var tabs: [Int] = [] }
            /// Never throws: a page that doesn't load or a read that isn't allowed is returned as an error.
            func readStorage(_ id: UUID) async -> Result<Stored, ExtensionSmokeTest.Failure> {
                let value: [String: Any]?
                do {
                    let web = try await extensionPage(id)
                    value = await evaluate(web, """
                        try {
                          const v = await browser.storage.local.get(['starts', 'survivor', 'lastRun']);
                          const tabs = (await browser.tabs.query({})).map(t => t.id).sort((a, b) => a - b);
                          return JSON.stringify({starts: v.starts || 0, survivor: v.survivor || '', lastRun: v.lastRun || '', tabs});
                        } catch (e) { return JSON.stringify({error: String((e && e.message) || e)}); }
                        """)
                } catch { return .failure(fail("extension page: \(error)")) }
                guard let value else { return .failure(fail("no result from the extension page")) }
                if let error = value["error"] as? String { return .failure(fail("storage read: \(error)")) }
                return .success(Stored(starts: (value["starts"] as? Int) ?? 0, survivor: (value["survivor"] as? String) ?? "",
                                       lastRun: (value["lastRun"] as? String) ?? "", tabs: (value["tabs"] as? [Int]) ?? []))
            }
            func storage(_ id: UUID) async throws -> Stored { try await readStorage(id).get() }
            struct Background { var starts = 0; var lastRun = ""; var load = "pending"; var loaded = false; var errors: [String] = []; var readError: String? }
            /// Waits up to 15 s for the run counter to reach `minimum` and for loadBackgroundContent's own result. Never throws.
            func background(_ id: UUID, atLeast minimum: Int) async -> Background {
                var result = Background()
                let context = host.context(for: id)
                if let context {
                    context.loadBackgroundContent { error in result.load = error.map { "error: \($0.localizedDescription)" } ?? "ok" }
                } else { result.load = "no context" }
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline {
                    switch await readStorage(id) {
                    case .success(let stored): result.starts = stored.starts; result.lastRun = stored.lastRun; result.readError = nil
                    case .failure(let failure): result.readError = failure.description
                    }
                    if result.readError == nil, result.starts >= minimum, result.load != "pending" { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                result.loaded = context?.isLoaded ?? false
                result.errors = context?.errors.map(\.localizedDescription) ?? []
                return result
            }
            func record(_ value: Background) -> [String: Any] {
                ["starts": value.starts, "last_run": value.lastRun, "load": value.load, "loaded": value.loaded,
                 "errors": value.errors, "read_error": value.readError ?? NSNull()]
            }
            func describe(_ value: Background) -> String {
                guard let data = try? JSONSerialization.data(withJSONObject: record(value), options: .sortedKeys) else { return "[unencodable]" }
                return String(decoding: data, as: UTF8.self)
            }
            func document(_ tabID: UUID, after previous: String?, expected: URL) async throws -> [String: String] {
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                var last: [String: String] = [:]
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if let web = controller.browsers[tabID], !web.isLoading,
                       let text = try? await web.evaluateJavaScript("""
                            JSON.stringify({document: document.documentElement.dataset.bamDocument || '', js: document.documentElement.dataset.\(jsMarker) || '',
                              css: getComputedStyle(document.documentElement).getPropertyValue('\(cssProperty)').trim(),
                              other: document.documentElement.dataset.bamOtherMarker || '', readyState: document.readyState, url: location.href})
                            """) as? String,
                       let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                        last = value
                        if let doc = value["document"], !doc.isEmpty, doc != previous, value["readyState"] == "complete", value["url"]?.hasPrefix(expected.absoluteString) == true {
                            checks += 1; return value
                        }
                    }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
                throw fail("no new completed document: \(last)")
            }
            /// Selects the site tab and loads a new document in it.
            func reload(_ tabID: UUID, after previous: String?) async throws -> [String: String] {
                controller.select(tabID); controller.view.layoutSubtreeIfNeeded()
                guard let web = controller.browsers[tabID], let tab = controller.session.tabs.first(where: { $0.id == tabID }) else { throw fail("the fixture tab disappeared") }
                controller.load(tab.address, in: web, id: tabID)
                return try await document(tabID, after: previous, expected: page)
            }
            func state(_ id: UUID) -> String {
                let context = host.context(for: id)
                let snapshot = host.siteAccess(id: id)
                return "[loaded=\(context?.isLoaded ?? false) enabled=\(host.records.first { $0.id == id }?.enabled ?? false) error=\(host.errors[id] ?? "none")"
                    + " mode=\(snapshot.map { String(describing: $0.state.mode) } ?? "nil") granted=\(context?.grantedPermissionMatchPatterns.keys.map(\.string).sorted() ?? [])]"
            }
            func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if condition { checks += 1 } else { findings.append(message()) } }
            func withhold(_ id: UUID) throws {
                guard let snapshot = host.siteAccess(id: id), let shown = snapshot.declarations else { throw fail("no editable snapshot \(state(id))") }
                _ = try host.performSiteAccess(id: id, profileID: profile, revision: snapshot.revision, displayed: shown, change: .choose(.withheld))
            }
            func allow(_ id: UUID) throws {
                guard let snapshot = host.siteAccess(id: id), let shown = snapshot.declarations else { throw fail("no editable snapshot to allow \(state(id))") }
                _ = try host.performSiteAccess(id: id, profileID: profile, revision: snapshot.revision, displayed: shown, change: .choose(.allRequested))
            }
            /// The restart the previous (synchronous) call started, by its generation; nil if it started none.
            func awaitRestart(_ id: UUID) async -> BrowserExtensions.SiteAccessRestart? {
                await host.restartCompletion(id: id, generation: host.restartGeneration[id] ?? 0)
            }
            func address(_ id: UUID) -> String? { controller.session.tabs.first(where: { $0.id == id })?.address }
            func renderer(_ id: UUID) -> ObjectIdentifier? { controller.browsers[id].map(ObjectIdentifier.init) }
            /// Selects an extension tab and waits for its page (in its current renderer) to load.
            func showExtensionTab(_ id: UUID) async throws {
                controller.select(id); controller.view.layoutSubtreeIfNeeded()
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if let web = controller.browsers[id], !web.isLoading, web.title == "restart fixture page" { return }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
                throw fail("extension tab didn't load: error \(controller.tabErrors[id] ?? "none"), url \(controller.browsers[id]?.url?.absoluteString ?? "none")")
            }
            /// A credentialed fetch of the loopback page from an extension tab's current renderer: "read" (status and
            /// body length) or "refused" (the error), never inferred.
            func fetch(fromTab id: UUID) async -> [String: Any] {
                guard let web = controller.browsers[id] else { return ["result": "no renderer"] }
                let target = page.absoluteString + "?fetch=\(UUID().uuidString)"
                return await evaluate(web, """
                    try { const r = await fetch('\(target)', {credentials: 'include', cache: 'no-store'}); const t = await r.text();
                          return JSON.stringify({result: 'read', status: r.status, length: t.length}); }
                    catch (e) { return JSON.stringify({result: 'refused', error: String((e && e.message) || e)}); }
                    """) ?? ["result": "no result"]
            }
            func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + seconds
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if condition() { return true }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                return condition()
            }
            /// The handoff boundary (old unloaded, renderers retired, fresh not yet loaded): records whether the watched
            /// Bam renderer is already gone and how many raw fixture pages are still alive.
            var handoffs: [[String: Any]] = []
            var watched = WeakView(nil)
            BrowserExtensions.siteAccessRestartWillLoad = { id in
                guard id == subject else { return }
                handoffs.append(["old_renderer_released": watched.web == nil, "raw_pages_alive": rawPagesAlive(),
                                 "bam_retired_alive": controller.retiredRenderersAlive()])
            }

            // MARK: 1. Both allowed: tabs T (site), E (A's page), F (B's page); storage, runs, fetch positive control.
            guard let siteTab = controller.openProfileTab(page, profileID: profile, active: true) else { throw fail("could not open the fixture page") }
            let first = try await document(siteTab, after: nil, expected: page)
            guard first["js"] == "js", first["css"] == "injected", first["other"] == "js" else { throw fail("allowed document isn't marked by both: \(first)") }
            let token = UUID().uuidString
            do {
                let writer = try await extensionPage(subject)
                _ = await evaluate(writer, "await browser.storage.local.set({survivor: '\(token)'}); return JSON.stringify({ok: true});")
            }
            let subjectBefore = await background(subject, atLeast: 1)
            let otherBefore = await background(other, atLeast: 1)
            guard subjectBefore.starts >= 1, otherBefore.starts >= 1 else {
                throw fail("the backgrounds never started: A \(describe(subjectBefore)), B \(describe(otherBefore))")
            }
            let tabsBefore = try await storage(subject).tabs
            let pagePath = "page.html"
            guard let extensionTab = controller.openProfileTab(identity.1.appendingPathComponent(pagePath), profileID: profile, active: true),
                  let otherTab = controller.openProfileTab(otherContext.baseURL.appendingPathComponent(pagePath), profileID: profile, active: false) else {
                throw fail("could not open the extension tabs")
            }
            try await showExtensionTab(extensionTab)
            let extensionAddress = address(extensionTab)
            let allowedFetch = await fetch(fromTab: extensionTab)
            expect(allowedFetch["result"] as? String == "read", "positive control: E couldn't read the loopback page while allowed: \(allowedFetch)")
            try await showExtensionTab(otherTab)
            controller.select(extensionTab); controller.view.layoutSubtreeIfNeeded()
            let siteRenderer = renderer(siteTab), otherRenderer = renderer(otherTab)
            _ = host.takeSiteAccessNotice(id: subject)

            // MARK: 2. Withhold A with E visible: fresh context, E's renderer retired before the load and recreated.
            watched = WeakView(controller.browsers[extensionTab])
            let wasFirstResponder = controller.browsers[extensionTab].map { web in window.firstResponder.map { ($0 as? NSView)?.isDescendant(of: web) ?? false } ?? false } ?? false
            try withhold(subject)
            // Phase A returned (old context unloaded, E retired); phase B loads once E's old renderer is gone.
            var release: [String: Any] = ["was_first_responder": wasFirstResponder, "alive_on_return": watched.web != nil,
                                          "pending_on_return": host.isRestarting(id: subject)]
            let notice = host.takeSiteAccessNotice(id: subject)
            expect(notice?.contains("Restarting") == true && host.isRestarting(id: subject) && host.context(for: subject) == nil,
                   "withholding didn't start a pending restart: notice \(notice ?? "none") \(state(subject))")
            let firstResult = await awaitRestart(subject)
            release["result"] = String(describing: firstResult)
            diagnostic["first_restart_release"] = release
            expect(firstResult == .restarted, "the withhold's restart ended \(String(describing: firstResult)) \(state(subject))")
            let secondContext = host.context(for: subject)
            expect(secondContext != nil && secondContext !== firstContext && secondContext?.isLoaded == true,
                   "the restart didn't produce a fresh loaded context \(state(subject))")
            expect(secondContext?.uniqueIdentifier == identity.0 && secondContext?.baseURL == identity.1,
                   "the fresh context changed identity: \(secondContext?.uniqueIdentifier ?? "nil") \(secondContext?.baseURL.absoluteString ?? "nil")")
            expect(host.context(for: other) === otherContext && otherContext.isLoaded, "the unrelated extension's context changed \(state(other))")
            expect(handoffs.last?["old_renderer_released"] as? Bool == true, "E's old renderer was still alive when the fresh context loaded: \(handoffs)")
            expect(watched.web == nil, "E's old renderer is still alive after the restart")
            expect(address(extensionTab) == extensionAddress && controller.session.tabs.contains(where: { $0.id == extensionTab }),
                   "E's tab ID or address changed: \(address(extensionTab) ?? "missing") (was \(extensionAddress ?? "nil"))")
            try await showExtensionTab(extensionTab)
            let withheldFetch = await fetch(fromTab: extensionTab)
            expect(withheldFetch["result"] as? String == "refused", "after withholding, the recreated E still reads the loopback page: \(withheldFetch) (handoff \(handoffs.last ?? [:]))")
            expect(renderer(siteTab) == siteRenderer && renderer(otherTab) == otherRenderer, "the site tab's or B's tab's renderer was replaced")
            let withheld = try await reload(siteTab, after: first["document"])
            expect((withheld["js"] ?? "").isEmpty && (withheld["css"] ?? "").isEmpty, "after the restart, A's content still reaches a new document: \(withheld) \(state(subject))")
            expect(withheld["other"] == "js", "the unrelated extension stopped marking new documents: \(withheld)")
            host.reconcile()
            let tabAccess = runtime?.tabs[siteTab].flatMap { tab in host.context(for: subject).map { $0.hasAccess(to: page, in: tab) } }
            expect(runtime != nil && tabAccess != nil, "no runtime or tab adapter to check A's tab access (runtime \(runtime != nil), tab \(String(describing: tabAccess)))")
            expect(host.context(for: subject)?.hasAccess(to: page) == false && tabAccess == false, "A still has access after withholding (tab \(String(describing: tabAccess))) \(state(subject))")
            let afterRestart = try await storage(subject)
            expect(afterRestart.survivor == token, "A's storage.local didn't survive the restart: '\(afterRestart.survivor)'")
            let subjectAfter = await background(subject, atLeast: subjectBefore.starts + 1)
            expect(subjectAfter.lastRun != subjectBefore.lastRun && !subjectAfter.lastRun.isEmpty, "A's background didn't run again (same nonce) \(describe(subjectAfter))")
            expect(subjectAfter.starts == subjectBefore.starts + 1,
                   "A's background run count went \(subjectBefore.starts) → \(subjectAfter.starts), expected +1 (before \(describe(subjectBefore)), after \(describe(subjectAfter)))")
            let otherAfter = await background(other, atLeast: otherBefore.starts)
            expect(otherAfter.starts == otherBefore.starts && otherAfter.lastRun == otherBefore.lastRun,
                   "the unrelated extension's background ran again (\(describe(otherBefore)) → \(describe(otherAfter)))")
            let tabsAfter = try await storage(subject).tabs
            expect(!tabsAfter.isEmpty, "A sees no tabs after the restart")

            // MARK: 3. Allow again: A marks again; no restart, same context.
            try allow(subject)
            expect(host.takeSiteAccessNotice(id: subject) == nil && !host.isRestarting(id: subject) && host.context(for: subject) === secondContext, "re-allowing restarted A")
            let reallowed = try await reload(siteTab, after: withheld["document"])
            expect(reallowed["js"] == "js" && reallowed["css"] == "injected", "after re-allowing, A doesn't mark the new document: \(reallowed) \(state(subject))")
            let afterAllow = try await storage(subject)
            expect(afterAllow.starts == subjectAfter.starts && afterAllow.lastRun == subjectAfter.lastRun, "re-allowing ran A's background again")

            // MARK: 4. Revoke Permissions with E in the background: E retired (no renderer until selected), then recreated.
            // (Revoke also withdraws storage, so nothing here reads it.)
            expect(renderer(extensionTab) != nil, "E lost its renderer before Revoke")
            watched = WeakView(controller.browsers[extensionTab])
            try host.revokePermissions(id: subject)
            expect(host.takeSiteAccessNotice(id: subject)?.contains("Restarting") == true, "Revoke Permissions didn't restart A \(state(subject))")
            let revokeResult = await awaitRestart(subject)
            expect(revokeResult == .restarted, "Revoke's restart ended \(String(describing: revokeResult)) \(state(subject))")
            expect(host.context(for: subject) !== secondContext, "Revoke Permissions didn't make a fresh context")
            expect(renderer(extensionTab) == nil && address(extensionTab) == extensionAddress, "background E wasn't retired with its tab kept (renderer \(renderer(extensionTab) != nil), address \(address(extensionTab) ?? "missing"))")
            expect(handoffs.last?["old_renderer_released"] as? Bool == true && watched.web == nil, "background E's old renderer stayed alive: \(handoffs.last ?? [:])")
            let revoked = try await reload(siteTab, after: reallowed["document"])
            expect((revoked["js"] ?? "").isEmpty && (revoked["css"] ?? "").isEmpty, "after Revoke Permissions, A's content still reaches a new document: \(revoked) \(state(subject))")
            expect(host.context(for: subject)?.hasAccess(to: page) == false, "A still has access after Revoke Permissions \(state(subject))")
            try await showExtensionTab(extensionTab)
            let revokedFetch = await fetch(fromTab: extensionTab)
            expect(revokedFetch["result"] as? String == "refused", "after Revoke Permissions, the recreated E still reads the loopback page: \(revokedFetch)")
            try allow(subject)
            let afterRevokeAllow = try await reload(siteTab, after: revoked["document"])
            expect(afterRevokeAllow["js"] == "js", "re-allowing after Revoke Permissions didn't restore A: \(afterRevokeAllow) \(state(subject))")

            // MARK: 5. Deliberate load failure with E visible: stopped, E's tab kept with the unavailable error; Enable recovers.
            controller.select(extensionTab); controller.view.layoutSubtreeIfNeeded()
            struct InjectedFailure: LocalizedError { let text: String; var errorDescription: String? { text } }
            BrowserExtensions.siteAccessRestartLoadFault = { $0 == subject ? InjectedFailure(text: "injected restart load failure (test)") : nil }
            try withhold(subject)
            let loadFailure = await awaitRestart(subject)
            var failedMessage: String?
            if case .loadFailed(let message) = loadFailure { failedMessage = message }
            BrowserExtensions.siteAccessRestartLoadFault = nil
            expect(failedMessage?.contains("Enable it again") == true, "a failed restart didn't report an actionable failure: \(failedMessage ?? "no error")")
            expect(host.context(for: subject) == nil && host.records.first { $0.id == subject }?.enabled == false && (host.errors[subject] ?? "").contains("Enable"),
                   "a failed restart didn't leave A unloaded and disabled with an error \(state(subject))")
            expect(host.siteAccess(id: subject)?.state.mode == .withheld, "the saved (withheld) choice wasn't kept after the failed restart \(state(subject))")
            let unavailableShown = await waitUntil({ (controller.tabErrors[extensionTab] ?? "").contains("unavailable") })
            expect(unavailableShown && address(extensionTab) == extensionAddress,
                   "visible E didn't show the unavailable error with its tab kept: \(controller.tabErrors[extensionTab] ?? "no error"), address \(address(extensionTab) ?? "missing")")
            expect(!host.allowsExtensionURL(identity.1.appendingPathComponent(pagePath), profileID: profile), "a stopped A still backs extension pages")
            let stopped = try await reload(siteTab, after: afterRevokeAllow["document"])
            expect((stopped["js"] ?? "").isEmpty && (stopped["css"] ?? "").isEmpty, "a stopped A still marks new documents (JS or CSS): \(stopped)")
            host.permissionPrompt = { _ in true }
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true && host.siteAccess(id: subject)?.state.mode == .withheld,
                   "Enable didn't recover A with its saved choice \(state(subject))")
            expect(renderer(extensionTab) == nil, "Enable left E's unavailable renderer in place (it should be retired until shown)")
            // Before re-allowing, the recovered context must have no effective access (global and this exact tab) and
            // must not mark a new document: a stored withheld state alone could hide accidental broad access.
            host.reconcile()
            let recoveredContext = host.context(for: subject)
            let recoveredGlobal = recoveredContext?.hasAccess(to: page)
            let recoveredTab = recoveredContext.flatMap { context in runtime?.tabs[siteTab].map { context.hasAccess(to: page, in: $0) } }
            expect(recoveredGlobal == false && recoveredTab == false,
                   "after Enable, A has access or can't be checked before re-allowing (global \(String(describing: recoveredGlobal)), tab \(String(describing: recoveredTab))) \(state(subject))")
            let recoveredWithheld = try await reload(siteTab, after: stopped["document"])
            expect((recoveredWithheld["js"] ?? "").isEmpty && (recoveredWithheld["css"] ?? "").isEmpty,
                   "after Enable (still withheld), A marks a new document (JS or CSS): \(recoveredWithheld) \(state(subject))")
            try allow(subject)
            let recovered = try await reload(siteTab, after: recoveredWithheld["document"])
            expect(recovered["js"] == "js" && recovered["css"] == "injected", "after Enable and re-allowing, A doesn't mark with both JS and CSS: \(recovered) \(state(subject))")
            try await showExtensionTab(extensionTab)
            expect(controller.tabErrors[extensionTab] == nil, "E still shows an error after Enable: \(controller.tabErrors[extensionTab] ?? "")")

            // MARK: 6. Unload failure (WebKit keeps running it): quarantined, Bam stops owning it; Enable retries the unload.
            let beforeQuarantine = host.context(for: subject)
            var quarantineHeld: WKWebView? = controller.browsers[extensionTab]   // an old view held across the quarantine
            BrowserExtensions.siteAccessRestartUnloadFault = { $0 == subject ? InjectedFailure(text: "injected restart unload failure (test)") : nil }
            var quarantineMessage: String?
            do { try withhold(subject) } catch BrowserExtensionSiteAccessFailure.failed(let message) { quarantineMessage = message }
            BrowserExtensions.siteAccessRestartUnloadFault = nil
            expect(quarantineMessage?.contains("couldn’t be stopped") == true && quarantineMessage?.contains("may still run it") == true,
                   "an unload failure wasn't reported honestly: \(quarantineMessage ?? "no error")")
            expect(host.context(for: subject) == nil && host.records.first { $0.id == subject }?.enabled == false,
                   "a quarantined A is still Bam-owned or enabled \(state(subject))")
            expect(!host.allowsExtensionURL(identity.1.appendingPathComponent(pagePath), profileID: profile)
                   && host.configuration(forExtensionURL: identity.1.appendingPathComponent(pagePath), profileID: profile) == nil,
                   "a quarantined context still backs extension pages")
            let quarantinedShown = await waitUntil({ (controller.tabErrors[extensionTab] ?? "").contains("unavailable") })
            expect(quarantinedShown, "visible E didn't show the unavailable error while A is quarantined: \(controller.tabErrors[extensionTab] ?? "no error")")
            expect(beforeQuarantine?.isLoaded == true, "the injected unload failure unexpectedly unloaded the context (fixture premise)")
            // The quarantined context still runs in WebKit: a page of it asks Bam to open a tab and a window. Bam's
            // shared delegate gate must refuse both (no session tab, no Little Bam window).
            var mutationAttempt: [String: Any] = ["result": "not attempted"]
            if let quarantined = beforeQuarantine, let quarantinedConfiguration = quarantined.webViewConfiguration {
                expect(runtime?.owns(quarantined) == false, "the runtime's shared gate still accepts the quarantined context")
                let tabCount = controller.session.tabs.count, littleCount = controller.littleWindows.count
                do {
                    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: quarantinedConfiguration)
                    web.load(URLRequest(url: identity.1.appendingPathComponent(pagePath)))
                    _ = await waitUntil({ !web.isLoading && web.title == "restart fixture page" }, seconds: 15)
                    mutationAttempt = await evaluate(web, """
                        const out = {};
                        try { const t = await browser.tabs.create({url: '\(page.absoluteString)?quarantine=tab'}); out.tab = 'created ' + (t && t.id); }
                        catch (e) { out.tab = 'refused: ' + String((e && e.message) || e); }
                        try { await browser.windows.create({url: '\(page.absoluteString)?quarantine=window'}); out.window = 'created'; }
                        catch (e) { out.window = 'refused: ' + String((e && e.message) || e); }
                        return JSON.stringify(out);
                        """) ?? ["result": "no result"]
                    web.stopLoading()
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                expect(controller.session.tabs.count == tabCount && controller.littleWindows.count == littleCount
                       && (mutationAttempt["tab"] as? String)?.hasPrefix("refused") == true && (mutationAttempt["window"] as? String)?.hasPrefix("refused") == true,
                       "the quarantined context could still open a tab or window: \(mutationAttempt) (tabs \(tabCount) → \(controller.session.tabs.count))")
            } else { findings.append("no quarantined context page to attempt a host mutation \(state(subject))") }
            // Remove while it still can't be stopped: refused, record and its data kept.
            BrowserExtensions.siteAccessRestartUnloadFault = { $0 == subject ? InjectedFailure(text: "injected quarantine unload failure (test)") : nil }
            var removeFailure: String?
            do { try await host.remove(id: subject) } catch { removeFailure = error.localizedDescription }
            BrowserExtensions.siteAccessRestartUnloadFault = nil
            let keptRecords = (await host.extensionController(profileID: profile)?.dataRecords(ofTypes: persistentDataTypes) ?? [])
                .filter { $0.uniqueIdentifier == identity.0 }
            let keptData = keptRecords.map(\.totalSizeInBytes).reduce(0, +)
            let keptErrors = keptRecords.flatMap(\.errors).map(\.localizedDescription)
            let recordKept = host.records.contains(where: { $0.id == subject })
            expect(removeFailure?.contains("couldn’t be stopped") == true && recordKept && keptData > 0 && keptErrors.isEmpty,
                   "a Remove that couldn't stop the quarantined context didn't fail safely: \(removeFailure ?? "no error"), record kept \(recordKept), data \(keptData) bytes, query errors \(keptErrors)")
            // Disable stops it for real.
            try await host.setEnabled(false, id: subject)
            expect(beforeQuarantine?.isLoaded == false && host.context(for: subject) == nil, "Disable didn't stop the quarantined context \(state(subject))")
            // The quarantine's release barrier still holds: Enable while the old view is alive must not load.
            BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
            var quarantineEnableError: String?
            do { try await host.setEnabled(true, id: subject) } catch { quarantineEnableError = error.localizedDescription }
            withExtendedLifetime(quarantineHeld) {}
            expect(quarantineEnableError?.contains("haven’t closed yet") == true && host.context(for: subject) == nil,
                   "after a quarantine, Enable loaded while an old view was held: \(quarantineEnableError ?? "no error") \(state(subject))")
            BrowserExtensions.siteAccessRestartReleaseDeadline = 2
            quarantineHeld = nil
            try await host.setEnabled(true, id: subject)
            let afterQuarantine = host.context(for: subject)
            expect(afterQuarantine?.isLoaded == true && afterQuarantine !== beforeQuarantine,
                   "Enable didn't load a fresh context after the quarantine \(state(subject))")
            diagnostic["quarantine_mutation"] = mutationAttempt
            try await showExtensionTab(extensionTab)
            let quarantineRecovered = try await reload(siteTab, after: recovered["document"])
            expect((quarantineRecovered["js"] ?? "").isEmpty && (quarantineRecovered["css"] ?? "").isEmpty,
                   "after the quarantine recovery (withheld), A marks a new document: \(quarantineRecovered) \(state(subject))")

            // MARK: 7. Fail closed: an old view still alive at the deadline (the fixture holds E's renderer) and the
            // disable can't be saved (this run's own host directory made read-only): no fresh load, honest message.
            try allow(subject)
            try await showExtensionTab(extensionTab)
            let hostDirectory = root.appendingPathComponent("host", isDirectory: true)
            BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
            var heldRenderer: WKWebView? = controller.browsers[extensionTab]
            try withhold(subject)
            let timeoutGeneration = host.restartGeneration[subject] ?? 0
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hostDirectory.path)
            let timeoutResult = await host.restartCompletion(id: subject, generation: timeoutGeneration)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostDirectory.path)
            // Enable WHILE the old renderer is still held: the release barrier must refuse it (nothing loads).
            host.permissionPrompt = { _ in true }
            var heldEnableError: String?
            do { try await host.setEnabled(true, id: subject) } catch { heldEnableError = error.localizedDescription }
            expect(heldEnableError?.contains("haven’t closed yet") == true && host.context(for: subject) == nil,
                   "Enable loaded while the timed-out restart's old renderer was still alive: \(heldEnableError ?? "no error") \(state(subject))")
            // An Enable waiting on the barrier, then a newer Revoke, then the release: the older Enable must not load.
            BrowserExtensions.siteAccessRestartReleaseDeadline = 2
            let staleEnable = Task { @MainActor in try await host.setEnabled(true, id: subject) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            try host.revokePermissions(id: subject)
            withExtendedLifetime(heldRenderer) {}   // the strong hold provably spans the timeout, both Enables and the Revoke
            heldRenderer = nil
            var staleEnableError: String?
            if case .failure(let error) = await staleEnable.result { staleEnableError = error.localizedDescription }
            expect(staleEnableError?.contains("changed while it waited") == true && host.context(for: subject) == nil
                   && host.records.first { $0.id == subject }?.patterns.isEmpty == true,
                   "an Enable waiting on the barrier continued after a newer Revoke: \(staleEnableError ?? "no error") \(state(subject))")
            var timeoutMessage = ""
            if case .releaseTimedOut(let message) = timeoutResult { timeoutMessage = message }
            expect(timeoutMessage.contains("couldn’t finish restarting") && timeoutMessage.contains("couldn’t save that it’s off")
                   && timeoutMessage.contains("may load again") && !timeoutMessage.contains("stays off"),
                   "the fail-closed timeout with a failed save wasn't reported honestly: \(String(describing: timeoutResult))")
            expect(host.context(for: subject) == nil && !host.isRestarting(id: subject) && host.records.first { $0.id == subject }?.enabled == false,
                   "the timeout loaded or kept a context \(state(subject))")
            let timeoutTabError = await waitUntil({ (controller.tabErrors[extensionTab] ?? "").contains("unavailable") })
            expect(timeoutTabError, "after the timeout, E doesn't show the unavailable error (not 'restarting'): \(controller.tabErrors[extensionTab] ?? "none")")
            let lateResult = await host.restartCompletion(id: subject, generation: timeoutGeneration)
            expect(lateResult == timeoutResult, "a late waiter didn't get the retained result: \(String(describing: lateResult))")
            host.permissionPrompt = { _ in true }
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true && host.siteAccess(id: subject)?.state.mode == .withheld,
                   "Enable didn't recover A after the timeout \(state(subject))")

            // MARK: 7b. Disable cancels a pending restart while the old renderer is held: Enable still waits for it.
            try allow(subject)
            try await showExtensionTab(extensionTab)
            BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
            var cancelHeld: WKWebView? = controller.browsers[extensionTab]
            try withhold(subject)
            let cancelGeneration = host.restartGeneration[subject] ?? 0
            try host.disable(id: subject)
            let cancelResult = await host.restartCompletion(id: subject, generation: cancelGeneration)
            var cancelEnableError: String?
            do { try await host.setEnabled(true, id: subject) } catch { cancelEnableError = error.localizedDescription }
            expect(cancelResult == .superseded && cancelEnableError?.contains("haven’t closed yet") == true && host.context(for: subject) == nil,
                   "after a cancelled restart, Enable loaded while the old renderer was held: \(String(describing: cancelResult)), \(cancelEnableError ?? "no error") \(state(subject))")
            BrowserExtensions.siteAccessRestartReleaseDeadline = 2
            let staleEnableAfterCancel = Task { @MainActor in try await host.setEnabled(true, id: subject) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            try host.disable(id: subject)
            withExtendedLifetime(cancelHeld) {}
            cancelHeld = nil
            var staleCancelError: String?
            if case .failure(let error) = await staleEnableAfterCancel.result { staleCancelError = error.localizedDescription }
            expect(staleCancelError?.contains("changed while it waited") == true && host.context(for: subject) == nil
                   && host.records.first { $0.id == subject }?.enabled == false,
                   "an Enable waiting on the barrier continued after a newer Disable: \(staleCancelError ?? "no error") \(state(subject))")
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true, "Enable didn't load once the cancelled restart's renderer was released \(state(subject))")

            // MARK: 7c. A popup Bam presented, then closed, whose actual view is still retained: the restart's release
            // barrier must hold it (fail closed) until it is released; Enable then recovers.
            try allow(subject)
            controller.select(siteTab); controller.view.layoutSubtreeIfNeeded()
            var popupPremise = false
            var popupResult: BrowserExtensions.SiteAccessRestart?
            if let liveContext = host.context(for: subject), let runtime {
                host.performAction(extensionID: subject, tabID: siteTab, anchor: controller.sidebar)
                let presented = await waitUntil({ !runtime.presentedPopupViews(of: liveContext).isEmpty }, seconds: 10)
                var heldPopup: WKWebView? = runtime.presentedPopupViews(of: liveContext).first
                popupPremise = presented && heldPopup != nil
                runtime.closePopup(for: liveContext)
                if popupPremise {
                    BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
                    try withhold(subject)
                    popupResult = await awaitRestart(subject)
                    withExtendedLifetime(heldPopup) {}   // the closed popup's view provably stays alive through the restart
                    BrowserExtensions.siteAccessRestartReleaseDeadline = 2
                }
                heldPopup = nil
            }
            expect(popupPremise, "premise: the fixture popup couldn't be presented through Bam \(state(subject))")
            if popupPremise {
                var timedOut = false
                if case .releaseTimedOut = popupResult { timedOut = true }
                expect(timedOut && host.context(for: subject) == nil,
                       "a closed but retained popup didn't hold the release barrier: \(String(describing: popupResult)) \(state(subject))")
                host.permissionPrompt = { _ in true }
                try await host.setEnabled(true, id: subject)
                expect(host.context(for: subject)?.isLoaded == true, "Enable didn't recover once the retained popup was released \(state(subject))")
            }
            diagnostic["closed_popup_barrier"] = ["premise": popupPremise, "result": String(describing: popupResult)]

            // MARK: 8. Post-load reentrancy: a Disable while the fresh context loads (seam right after load) cancels it;
            // the loaded fresh context is unloaded, never published.
            try allow(subject)
            var reentrantContext: WKWebExtensionContext?
            BrowserExtensions.siteAccessRestartDidLoad = { id in
                guard id == subject else { return }
                reentrantContext = host.context(for: subject)   // nil: not yet published
                try? host.disable(id: subject)
            }
            try withhold(subject)
            let reentrantResult = await awaitRestart(subject)
            BrowserExtensions.siteAccessRestartDidLoad = nil
            expect(reentrantResult == .superseded && reentrantContext == nil && host.context(for: subject) == nil
                   && host.records.first { $0.id == subject }?.enabled == false && !host.isRestarting(id: subject),
                   "a Disable during the fresh load didn't cancel it cleanly: \(String(describing: reentrantResult)) \(state(subject))")
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true, "Enable didn't recover A after the cancelled load \(state(subject))")

            // MARK: 8b. Cancelled during load AND the fresh context can't be unloaded: quarantined, not dropped.
            try allow(subject)
            var cancelledFresh: WKWebExtensionContext?
            BrowserExtensions.siteAccessRestartDidLoad = { id in
                guard id == subject else { return }
                cancelledFresh = runtime?.controller.extensionContexts.first { $0.baseURL == identity.1 }
                try? host.disable(id: subject)
                BrowserExtensions.siteAccessRestartUnloadFault = { $0 == subject ? InjectedFailure(text: "injected cancelled-load unload failure (test)") : nil }
            }
            try withhold(subject)
            let cancelledResult = await awaitRestart(subject)
            BrowserExtensions.siteAccessRestartDidLoad = nil; BrowserExtensions.siteAccessRestartUnloadFault = nil
            expect(cancelledResult == .superseded && cancelledFresh.map { host.isQuarantined($0) && runtime?.owns($0) == false } == true
                   && (host.errors[subject] ?? "").contains("couldn’t be stopped") && host.context(for: subject) == nil,
                   "an unstoppable cancelled fresh context wasn't quarantined: \(String(describing: cancelledResult)), error \(host.errors[subject] ?? "none")")
            try await host.setEnabled(false, id: subject)   // stops it for real
            expect(cancelledFresh?.isLoaded == false, "Disable didn't stop the quarantined cancelled context")
            cancelledFresh = nil
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true, "Enable didn't recover A after the quarantined cancelled load \(state(subject))")
            diagnostic["fail_closed"] = ["timeout": String(describing: timeoutResult), "reentrant": String(describing: reentrantResult)]

            // MARK: 9. Update with an old view held: the updated same-identity context must not load while a Bam-retired
            // view of the old context is alive (fail closed); after release, Enable recovers and a clean update succeeds.
            func updatePackage(version: String) throws -> URL {
                let folder = root.appendingPathComponent("subject-\(version)", isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                try FileManager.default.copyItem(at: subjectPackage, to: folder)
                let manifestURL = folder.appendingPathComponent("manifest.json")
                guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else { throw fail("unreadable fixture manifest") }
                manifest["version"] = version
                try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: manifestURL)
                return folder
            }
            let catalog = ExtensionCatalogRecord(source: .local, upstreamID: nil, listingURL: nil, downloadURL: nil,
                publisher: "Bam test fixture", version: "1.0.1", sha256: "", provenance: "Original local fixture", installedAt: Date())
            host.permissionPrompt = { _ in true }   // the update's own review approves
            if host.context(for: subject) == nil { try await host.setEnabled(true, id: subject) }
            try await showExtensionTab(extensionTab)
            let versionBefore = host.context(for: subject)?.webExtension.version
            BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
            var heldOldView: WKWebView? = controller.browsers[extensionTab]
            var heldUpdateError: String?
            do { try await host.replacePackage(id: subject, with: try updatePackage(version: "1.0.1"), catalog: catalog) }
            catch { heldUpdateError = error.localizedDescription }
            withExtendedLifetime(heldOldView) {}   // the old renderer provably stays alive through the update attempt
            BrowserExtensions.siteAccessRestartReleaseDeadline = 2
            heldOldView = nil
            expect(heldUpdateError?.contains("haven’t closed yet") == true && host.context(for: subject) == nil
                   && host.records.first { $0.id == subject }?.enabled == false && host.records.first { $0.id == subject }?.version == versionBefore,
                   "an update loaded while an old view was held, or didn't fail closed with the old version kept: \(heldUpdateError ?? "no error") \(state(subject))")
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true && host.context(for: subject)?.webExtension.version == versionBefore,
                   "Enable didn't recover the old version after the failed update \(state(subject))")
            // Held again, and saving "off" fails during the rollback (this run's own host directory made read-only once
            // the update has saved its replacement): the error the update THROWS must carry the disclosure, so a caller
            // that stores it (as Manage Extensions' update path does with setError) shows it.
            try await showExtensionTab(extensionTab)
            BrowserExtensions.siteAccessRestartReleaseDeadline = 1
            var heldForSave: WKWebView? = controller.browsers[extensionTab]
            let unsavedUpdate = Task { @MainActor in try await host.replacePackage(id: subject, with: try updatePackage(version: "1.0.1"), catalog: catalog) }
            _ = await waitUntil({ host.records.first { $0.id == subject }?.version == "1.0.1" }, seconds: 10)   // replacement saved
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hostDirectory.path)
            var thrownByUpdate: String?
            if case .failure(let error) = await unsavedUpdate.result {
                thrownByUpdate = error.localizedDescription
                host.setError(error, for: subject)   // what the caller does with it
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostDirectory.path)
            withExtendedLifetime(heldForSave) {}
            BrowserExtensions.siteAccessRestartReleaseDeadline = 2
            heldForSave = nil
            expect(thrownByUpdate?.contains("haven’t closed yet") == true && thrownByUpdate?.contains("couldn’t save that it’s off") == true
                   && (host.errors[subject] ?? "").contains("couldn’t save that it’s off") && host.context(for: subject) == nil,
                   "the update's thrown error (stored by its caller) didn't disclose the failed save of off: \(thrownByUpdate ?? "no error"), stored \(host.errors[subject] ?? "none")")
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true && host.context(for: subject)?.webExtension.version == versionBefore,
                   "Enable didn't recover the old version after the unsaved failed update \(state(subject))")
            // Clean update: the old renderer is retired and released before the updated context loads; E keeps its tab.
            try await showExtensionTab(extensionTab)
            let oldUpdateRenderer = WeakView(controller.browsers[extensionTab])
            let contextBeforeUpdate = host.context(for: subject)
            try await host.replacePackage(id: subject, with: try updatePackage(version: "1.0.2"), catalog: catalog)
            let updatedContext = host.context(for: subject)
            expect(updatedContext?.isLoaded == true && updatedContext !== contextBeforeUpdate && updatedContext?.webExtension.version == "1.0.2"
                   && updatedContext?.uniqueIdentifier == identity.0 && updatedContext?.baseURL == identity.1,
                   "a clean update didn't load the new version with the same identity \(state(subject))")
            expect(oldUpdateRenderer.web == nil && address(extensionTab) == extensionAddress,
                   "the update didn't release E's old renderer or kept a different tab address: alive \(oldUpdateRenderer.web != nil), \(address(extensionTab) ?? "missing")")
            try await showExtensionTab(extensionTab)
            diagnostic["update_barrier"] = ["held_error": heldUpdateError ?? "none", "clean_version": updatedContext?.webExtension.version ?? "none"]

            // MARK: 10. Update comparison (native 8501db3: the full-suite consent check reads 200 after an earlier Update,
            // with no observed subject view alive at the fresh load). Same order as there: allowed → Update while allowed
            // → withhold → a new document's fetch from the recreated extension tab. Stage 2 (never updated, same fetch)
            // is a comparison, not causal proof: this stage also follows every earlier stage here, including the fault
            // stages and stage 9's updates. It is interpreted only when the post-update positive control read.
            try allow(subject)
            try await showExtensionTab(extensionTab)
            let beforeUpdateFetch = await fetch(fromTab: extensionTab)
            expect(beforeUpdateFetch["result"] as? String == "read", "comparison control: E couldn't read while allowed before the update: \(beforeUpdateFetch)")
            try await host.replacePackage(id: subject, with: try updatePackage(version: "1.0.3"), catalog: catalog)
            try await showExtensionTab(extensionTab)
            let afterUpdateFetch = await fetch(fromTab: extensionTab)
            expect(afterUpdateFetch["result"] as? String == "read",
                   "comparison premise: E couldn't read while allowed after the update, so the comparison can't be interpreted: \(afterUpdateFetch)")
            try withhold(subject)
            let updateWithholdResult = await awaitRestart(subject)
            expect(updateWithholdResult == .restarted, "the withhold after an update ended \(String(describing: updateWithholdResult)) \(state(subject))")
            try await showExtensionTab(extensionTab)
            let afterUpdateWithholdFetch = await fetch(fromTab: extensionTab)
            expect(afterUpdateWithholdFetch["result"] as? String == "refused",
                   "after an Update while allowed and then a withhold, the recreated E still reads the loopback page: \(afterUpdateWithholdFetch) (never-updated control: \(withheldFetch))")
            diagnostic["update_comparison"] = ["before_update": beforeUpdateFetch, "after_update_allowed": afterUpdateFetch,
                                               "after_update_withheld": afterUpdateWithholdFetch, "never_updated_withheld": withheldFetch]

            // MARK: 11. Disable with the extension tab open and its old renderer held: Disable retires it (same tab ID and
            // address, shown unavailable), and Enable (same identity) must not load while it's alive; after the release
            // Enable recovers with a new renderer. Then Disable → Enable back to back, no hold, works (as in the suite).
            if host.context(for: subject) == nil { try await host.setEnabled(true, id: subject) }
            try await showExtensionTab(extensionTab)
            BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
            var heldDisabled: WKWebView? = controller.browsers[extensionTab]
            let heldWatch = WeakView(heldDisabled)
            try host.disable(id: subject)
            let disabledShown = await waitUntil({ (controller.tabErrors[extensionTab] ?? "").contains("unavailable") })
            expect(host.context(for: subject) == nil && address(extensionTab) == extensionAddress && controller.browsers[extensionTab] !== heldDisabled && disabledShown,
                   "Disable didn't retire E with its tab kept and shown unavailable: \(controller.tabErrors[extensionTab] ?? "no error"), address \(address(extensionTab) ?? "missing") \(state(subject))")
            var disabledEnableError: String?
            do { try await host.setEnabled(true, id: subject) } catch { disabledEnableError = error.localizedDescription }
            withExtendedLifetime(heldDisabled) {}   // the old renderer provably stays alive through Disable and the Enable attempt
            expect(disabledEnableError?.contains("haven’t closed yet") == true && host.context(for: subject) == nil,
                   "Enable loaded next to the disabled context's still-alive renderer: \(disabledEnableError ?? "no error") \(state(subject))")
            BrowserExtensions.siteAccessRestartReleaseDeadline = 2
            heldDisabled = nil
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true, "Enable didn't recover after the old renderer was released \(state(subject))")
            try await showExtensionTab(extensionTab)
            expect(heldWatch.web == nil && address(extensionTab) == extensionAddress && controller.tabErrors[extensionTab] == nil,
                   "after Enable, E isn't a new renderer with its tab kept: old alive \(heldWatch.web != nil), address \(address(extensionTab) ?? "missing"), error \(controller.tabErrors[extensionTab] ?? "none")")
            try host.disable(id: subject)
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true, "Disable then Enable back to back (no hold) didn't load \(state(subject))")
            try await showExtensionTab(extensionTab)
            diagnostic["disable_barrier"] = ["held_enable_error": disabledEnableError ?? "none"]

            // MARK: 11b. Disable whose unload throws. Still listed by WebKit: the disable fails, the context stays loaded
            // and owned, and E comes back on it. No longer listed: it's off, honestly reported, with E unavailable.
            try await showExtensionTab(extensionTab)
            let stillLoadedContext = host.context(for: subject)
            BrowserExtensions.siteAccessRestartUnloadFault = { $0 == subject ? InjectedFailure(text: "injected disable unload failure (test)") : nil }
            var listedError: String?
            do { try host.disable(id: subject) } catch { listedError = error.localizedDescription }
            BrowserExtensions.siteAccessRestartUnloadFault = nil
            expect(listedError?.contains("injected disable unload failure") == true && host.context(for: subject) === stillLoadedContext
                   && stillLoadedContext?.isLoaded == true && host.records.first { $0.id == subject }?.enabled == true,
                   "an unload failure WebKit still lists didn't leave the extension loaded and owned: \(listedError ?? "no error") \(state(subject))")
            try await showExtensionTab(extensionTab)   // E restored on the still-loaded context
            BrowserExtensions.disableUnloadFaultAfterUnload = { $0 == subject ? InjectedFailure(text: "injected post-unload report (test)") : nil }
            var unlistedError: String?
            do { try host.disable(id: subject) } catch { unlistedError = error.localizedDescription }
            BrowserExtensions.disableUnloadFaultAfterUnload = nil
            let unlistedShown = await waitUntil({ (controller.tabErrors[extensionTab] ?? "").contains("unavailable") })
            expect(unlistedError == nil && host.context(for: subject) == nil && stillLoadedContext?.isLoaded == false
                   && host.records.first { $0.id == subject }?.enabled == false
                   && (host.errors[subject] ?? "").contains("WebKit reported an error") && unlistedShown,
                   "an unload error after WebKit stopped it wasn't finished as off: \(unlistedError ?? "no throw"), error \(host.errors[subject] ?? "none") \(state(subject))")
            try await host.setEnabled(true, id: subject)
            expect(host.context(for: subject)?.isLoaded == true, "Enable didn't recover after the reported unload error \(state(subject))")
            try await showExtensionTab(extensionTab)

            diagnostic["findings"] = findings.count
            diagnostic["tab_ids"] = ["before": tabsBefore, "after": tabsAfter]
            diagnostic["subject_before"] = record(subjectBefore); diagnostic["subject_after"] = record(subjectAfter)
            diagnostic["other_before"] = record(otherBefore); diagnostic["other_after"] = record(otherAfter)
            diagnostic["fetch"] = ["allowed": allowedFetch, "withheld": withheldFetch, "revoked": revokedFetch]
            diagnostic["handoffs"] = handoffs
            diagnostic["raw_pages_alive_at_end"] = rawPagesAlive()
            diagnostic["prompts"] = prompts
        } catch { bodyError = error }

        // MARK: Cleanup: the owned persistent store (data, then its directory), verified.
        BrowserExtensions.siteAccessRestartLoadFault = nil; BrowserExtensions.siteAccessRestartUnloadFault = nil
        BrowserExtensions.siteAccessRestartWillLoad = nil; BrowserExtensions.siteAccessRestartDidLoad = nil
        BrowserExtensions.disableUnloadFaultAfterUnload = nil
        BrowserExtensions.siteAccessRestartReleaseDeadline = 2
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("host", isDirectory: true).path)
        var cleanup: [String: Any] = [:]
        var dataBytesBefore: Int?, dataBytesAfter: Int?
        var dataErrors: [String] = []
        if let extensionController = host.extensionController(profileID: profile) {
            let records = await extensionController.dataRecords(ofTypes: persistentDataTypes)
            let queryErrors = records.map { record in record.errors.map(\.localizedDescription) }
            dataErrors += zip(records, queryErrors).flatMap { record, errors in errors.map { "query \(record.uniqueIdentifier): \($0)" } }
            await extensionController.removeData(ofTypes: persistentDataTypes, from: records)
            // removeData reports failures on the records it was given: read them right after it returns.
            for (record, seen) in zip(records, queryErrors) {
                var remaining = seen
                for error in record.errors.map(\.localizedDescription) {
                    if let index = remaining.firstIndex(of: error) { remaining.remove(at: index); continue }   // already reported by the query
                    dataErrors.append("removal \(record.uniqueIdentifier): \(error)")
                }
            }
            let after = await extensionController.dataRecords(ofTypes: persistentDataTypes)
            dataErrors += after.flatMap { record in record.errors.map { "after removal \(record.uniqueIdentifier): \($0.localizedDescription)" } }
            dataBytesBefore = records.map(\.totalSizeInBytes).reduce(0, +)
            dataBytesAfter = after.map(\.totalSizeInBytes).reduce(0, +)
            cleanup["data_records"] = [records.count, after.count]
        } else { dataErrors.append("no extension controller to remove the owned store's data") }
        cleanup["data_bytes_before"] = dataBytesBefore.map { NSNumber(value: $0) } ?? NSNull()
        cleanup["data_bytes_after"] = dataBytesAfter.map { NSNumber(value: $0) } ?? NSNull()
        cleanup["data_errors"] = dataErrors
        controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close()
        try? await Task.sleep(nanoseconds: 500_000_000)   // WebKit writes context state on unload
        // WebKit's persistent store for Configuration(identifier:): Library/WebKit/<bundle or process>/WebExtensions/<UUID>
        // (unsandboxed) or Library/WebKit/WebExtensions/<UUID> (sandboxed). Only this run's fresh identifier is removed.
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("WebKit", isDirectory: true)
        let name = storeID.uuidString.uppercased()
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let candidates = [library.appendingPathComponent(app).appendingPathComponent("WebExtensions").appendingPathComponent(name),
                          library.appendingPathComponent("WebExtensions").appendingPathComponent(name)]
        var removed: [String] = [], removalErrors: [String] = []
        for directory in candidates where directory.lastPathComponent == name && directory.deletingLastPathComponent().lastPathComponent == "WebExtensions"
            && FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory); removed.append(directory.path) }
            catch { removalErrors.append("\(directory.path): \(error.localizedDescription)") }
        }
        cleanup["store_directory_errors"] = removalErrors
        try? await Task.sleep(nanoseconds: 300_000_000)
        let remaining = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        cleanup["store_directories_removed"] = removed; cleanup["store_directories_remaining"] = remaining
        diagnostic["cleanup"] = cleanup
        if !remaining.isEmpty { findings.append("the owned extension store wasn't removed: \(remaining)") }
        if dataBytesAfter != 0 { findings.append("the owned extension store's data wasn't verifiably removed: \(dataBytesAfter.map(String.init) ?? "unknown") bytes after removal") }
        if !dataErrors.isEmpty { findings.append("the owned extension store's data reported errors: \(dataErrors)") }
        if !removalErrors.isEmpty { findings.append("the owned extension store's directory couldn't be removed: \(removalErrors)") }
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: .sortedKeys) {
            print("BAM_SITE_ACCESS_RESTART " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        if let bodyError { throw ExtensionSmokeTest.Failure(description: "\(bodyError) (also: \(findings.joined(separator: "; ")))") }
        return (checks, findings)
    }
}
