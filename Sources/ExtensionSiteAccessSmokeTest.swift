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

// MARK: - Restart candidate acceptance (all-host withdrawal restarts the extension)

@MainActor @available(macOS 15.4, *)
extension ExtensionSiteAccessSmokeTest {
    /// Two original extensions in one ephemeral controller:
    ///   A (subject): all-host (`*://*/*` + `<all_urls>`), JS and CSS markers, a background start counter in
    ///     storage.local, and an extension page to read storage and tab IDs;
    ///   B (unrelated): single host, its own marker and start counter.
    /// Withholding A must restart it: A's markers leave new documents, its storage survives, its background starts
    /// once more, B keeps marking and isn't restarted, and tab IDs are observed. Re-allowing restores A without a
    /// restart. Revoke Permissions has the same effect. A deliberate load failure leaves A unloaded with an
    /// actionable error, and Enable recovers its saved choice.
    static func runRestart(pageURL: URL) async throws -> (Int, [String]) {
        var checks = 0, findings: [String] = []
        func fail(_ message: String) -> ExtensionSmokeTest.Failure { .init(description: "Site access restart: " + message) }
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/site-access-lifecycle.html"; components.query = nil; components.fragment = nil
        guard let page = components.url, page.host == "127.0.0.1" else { throw fail("needs the loopback fixture origin") }

        // MARK: Packages (original source, owned temporary directories).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-site-access-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func package(_ name: String, hosts: [String], matches: [String], marker: String, css: Bool) throws -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var script: [String: Any] = ["matches": matches, "js": ["marker.js"], "run_at": "document_start"]
            if css { script["css"] = ["marker.css"] }
            let manifest: [String: Any] = [
                "manifest_version": 3, "name": "Bam Site Access Restart \(name)", "version": "1.0.0",
                "description": "Original fixture for the site-access restart.", "permissions": ["storage"],
                "host_permissions": hosts, "background": ["service_worker": "background.js"], "content_scripts": [script]
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("document.documentElement.dataset.\(marker) = 'js';\n".utf8).write(to: folder.appendingPathComponent("marker.js"))
            if css { try Data("html { \(cssProperty): injected; }\n".utf8).write(to: folder.appendingPathComponent("marker.css")) }
            // Counts every start of the background (initial and after a restart).
            try Data("chrome.storage.local.get('starts').then(v => chrome.storage.local.set({starts: (v.starts || 0) + 1}));\n".utf8)
                .write(to: folder.appendingPathComponent("background.js"))
            try Data("<!doctype html><meta charset='utf-8'><title>restart fixture page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
            return folder
        }
        let subjectPackage = try package("subject", hosts: ["*://*/*"], matches: ["<all_urls>"], marker: jsMarker, css: true)
        let otherPackage = try package("other", hosts: ["http://127.0.0.1/*"], matches: ["http://127.0.0.1/*"], marker: "bamOtherMarker", css: false)

        // MARK: Ephemeral browser.
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-site-access-restart-\(UUID().uuidString).json"), ephemeral: true)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let profile = controller.session.currentProfileID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 650))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        defer {
            BrowserExtensions.siteAccessRestartLoadFault = nil
            controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close()
        }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }      // install reviews
        host.onReloadNeeded = { _ in }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(configuration, profileID: profile)
        let subject = try await host.importPackage(at: subjectPackage, profileID: profile)
        let other = try await host.importPackage(at: otherPackage, profileID: profile)
        guard let subjectContext = host.context(for: subject), let otherContext = host.context(for: other) else {
            throw fail("fixtures did not load: \(host.errors[subject] ?? host.errors[other] ?? host.lastError ?? "no error")")
        }
        let runtime = configuration.webExtensionController?.delegate as? BrowserExtensionRuntime
        var prompts = 0
        host.permissionPrompt = { _ in prompts += 1; return false }   // runtime prompts declined; Enable re-allowed below

        // MARK: Helpers.
        func evaluate(_ web: WKWebView, _ script: String) async -> [String: Any]? {
            guard let text = try? await web.callAsyncJavaScript(script, arguments: [:], contentWorld: .page) as? String,
                  let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        /// A fresh extension page for `id`'s current context (pages from before a restart are gone).
        func extensionPage(_ id: UUID) async throws -> WKWebView {
            guard let context = host.context(for: id), let pageConfiguration = context.webViewConfiguration else { throw fail("no loaded context for an extension page") }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: pageConfiguration)
            web.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while ProcessInfo.processInfo.systemUptime < deadline {
                if !web.isLoading, web.title == "restart fixture page" { return web }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw fail("the extension page did not load")
        }
        func storage(_ id: UUID) async throws -> (starts: Int, survivor: String, tabs: [Int]) {
            let web = try await extensionPage(id)
            guard let value = await evaluate(web, """
                const v = await browser.storage.local.get(['starts', 'survivor']);
                const tabs = (await browser.tabs.query({})).map(t => t.id).sort((a, b) => a - b);
                return JSON.stringify({starts: v.starts || 0, survivor: v.survivor || '', tabs});
                """) else { throw fail("could not read the extension's storage") }
            return ((value["starts"] as? Int) ?? 0, (value["survivor"] as? String) ?? "", (value["tabs"] as? [Int]) ?? [])
        }
        /// Waits for the background start counter to reach at least `minimum` (starting the background if needed).
        func starts(_ id: UUID, atLeast minimum: Int) async throws -> Int {
            host.context(for: id)?.loadBackgroundContent { _ in }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var last = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                last = try await storage(id).starts
                if last >= minimum { return last }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw fail("background start counter stayed at \(last), expected at least \(minimum)")
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
        func reload(_ tabID: UUID, after previous: String?) async throws -> [String: String] {
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

        // MARK: 1. Both allowed: A and B mark the page; record storage, starts and tab IDs.
        guard let tabID = controller.openProfileTab(page, profileID: profile, active: true) else { throw fail("could not open the fixture page") }
        let first = try await document(tabID, after: nil, expected: page)
        guard first["js"] == "js", first["css"] == "injected", first["other"] == "js" else { throw fail("allowed document isn't marked by both: \(first)") }
        let token = UUID().uuidString
        let writer = try await extensionPage(subject)
        _ = await evaluate(writer, "await browser.storage.local.set({survivor: '\(token)'}); return JSON.stringify({ok: true});")
        let subjectStartsBefore = try await starts(subject, atLeast: 1)
        let otherStartsBefore = try await starts(other, atLeast: 1)
        let tabsBefore = try await storage(subject).tabs
        _ = host.takeSiteAccessNotice(id: subject)

        // MARK: 2. Withhold A (all-host withdrawal): restart, same context, A's content gone, B untouched.
        try withhold(subject)
        let notice = host.takeSiteAccessNotice(id: subject)
        expect(notice?.contains("Restarted") == true, "withholding all-host access didn't report a restart \(state(subject))")
        expect(host.context(for: subject) === subjectContext && subjectContext.isLoaded, "the restart didn't keep the same loaded context \(state(subject))")
        expect(host.context(for: other) === otherContext && otherContext.isLoaded, "the unrelated extension's context changed \(state(other))")
        let withheld = try await reload(tabID, after: first["document"])
        expect((withheld["js"] ?? "").isEmpty && (withheld["css"] ?? "").isEmpty, "after the restart, A's content still reaches a new document: \(withheld) \(state(subject))")
        expect(withheld["other"] == "js", "the unrelated extension stopped marking new documents: \(withheld)")
        host.reconcile()
        let tabAccess = runtime?.tabs[tabID].map { subjectContext.hasAccess(to: page, in: $0) }
        expect(!subjectContext.hasAccess(to: page) && tabAccess != true, "A still has access after withholding (global \(subjectContext.hasAccess(to: page)), tab \(String(describing: tabAccess)))")
        let afterRestart = try await storage(subject)
        expect(afterRestart.survivor == token, "A's storage.local didn't survive the restart: \(afterRestart.survivor)")
        let subjectStartsAfter = try await starts(subject, atLeast: subjectStartsBefore + 1)
        expect(subjectStartsAfter == subjectStartsBefore + 1, "A's background started \(subjectStartsAfter - subjectStartsBefore) times across the restart, expected 1")
        let otherStartsAfter = try await storage(other).starts
        expect(otherStartsAfter == otherStartsBefore, "the unrelated extension's background restarted (\(otherStartsBefore) → \(otherStartsAfter))")
        let tabsAfter = try await storage(subject).tabs
        expect(!tabsAfter.isEmpty, "A sees no tabs after the restart")

        // MARK: 3. Allow again: A marks again, no restart (nothing all-host withdrawn).
        try allow(subject)
        expect(host.takeSiteAccessNotice(id: subject) == nil, "re-allowing restarted A")
        let reallowed = try await reload(tabID, after: withheld["document"])
        expect(reallowed["js"] == "js" && reallowed["css"] == "injected", "after re-allowing, A doesn't mark the new document: \(reallowed) \(state(subject))")
        let startsAfterAllow = try await storage(subject).starts
        expect(startsAfterAllow == subjectStartsAfter, "re-allowing restarted A's background (\(subjectStartsAfter) → \(startsAfterAllow))")

        // MARK: 4. Revoke Permissions: same restart effect.
        try host.revokePermissions(id: subject)
        expect(host.takeSiteAccessNotice(id: subject)?.contains("Restarted") == true, "Revoke Permissions didn't restart A \(state(subject))")
        let revoked = try await reload(tabID, after: reallowed["document"])
        expect((revoked["js"] ?? "").isEmpty && (revoked["css"] ?? "").isEmpty, "after Revoke Permissions, A's content still reaches a new document: \(revoked) \(state(subject))")
        expect(!subjectContext.hasAccess(to: page), "A still has access after Revoke Permissions \(state(subject))")
        try allow(subject)
        let afterRevokeAllow = try await reload(tabID, after: revoked["document"])
        expect(afterRevokeAllow["js"] == "js", "re-allowing after Revoke Permissions didn't restore A: \(afterRevokeAllow) \(state(subject))")

        // MARK: 5. Deliberate load failure: A stays unloaded with an actionable error; Enable recovers the saved choice.
        struct InjectedLoadFailure: LocalizedError { var errorDescription: String? { "injected restart load failure (test)" } }
        BrowserExtensions.siteAccessRestartLoadFault = { $0 == subject ? InjectedLoadFailure() : nil }
        var failedMessage: String?
        do { try withhold(subject) } catch BrowserExtensionSiteAccessFailure.failed(let message) { failedMessage = message }
        BrowserExtensions.siteAccessRestartLoadFault = nil
        expect(failedMessage?.contains("Enable it again") == true, "a failed restart didn't report an actionable failure: \(failedMessage ?? "no error")")
        expect(host.context(for: subject) == nil && host.records.first { $0.id == subject }?.enabled == false && (host.errors[subject] ?? "").contains("Enable"),
               "a failed restart didn't leave A unloaded and disabled with an error \(state(subject))")
        expect(host.siteAccess(id: subject)?.state.mode == .withheld, "the saved (withheld) choice wasn't kept after the failed restart \(state(subject))")
        let stopped = try await reload(tabID, after: afterRevokeAllow["document"])
        expect((stopped["js"] ?? "").isEmpty, "a stopped A still marks new documents: \(stopped)")
        host.permissionPrompt = { _ in true }
        try await host.setEnabled(true, id: subject)
        expect(host.context(for: subject)?.isLoaded == true && host.siteAccess(id: subject)?.state.mode == .withheld,
               "Enable didn't recover A with its saved choice \(state(subject))")
        try allow(subject)
        let recovered = try await reload(tabID, after: stopped["document"])
        expect(recovered["js"] == "js", "after Enable and re-allowing, A doesn't mark: \(recovered) \(state(subject))")

        let tabsJSON = "{\"before\":\(tabsBefore),\"after\":\(tabsAfter)}"
        print("BAM_SITE_ACCESS_RESTART {\"findings\":\(findings.count),\"tab_ids\":\(tabsJSON),\"subject_starts\":[\(subjectStartsBefore),\(subjectStartsAfter)],\"other_starts\":[\(otherStartsBefore),\(otherStartsAfter)],\"prompts\":\(prompts)}"); fflush(stdout)
        return (checks, findings)
    }
}
