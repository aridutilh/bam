import AppKit
import WebKit

/// Site Access lifecycle on real WebKit content scripts: an original fixture extension marks every document it can
/// inject into (a DOM attribute from JS and a CSS custom property from its stylesheet). Each step proves a NEW document
/// by the page's own per-document identity, then reads both markers:
///   allow → markers; withhold → no access → controller.load (the Reload Pages path) → no markers;
///   web.reload() (toolbar/previews) → no markers; allow again → markers return.
/// Runtime prompts while withheld are declined and recorded. Native only (root wires the call into the extension
/// suite); no account, no vendor code, an ephemeral controller and an owned temporary package per variant.
///
/// Two variants, all-host first (WebKit has a separate all-host injection/coalescing path):
///   - all-host: host_permissions `*://*/*`, content scripts on `<all_urls>` (the shape Dark Reader requests),
///     visiting only the loopback page;
///   - single-host control: host_permissions and content scripts on `http://127.0.0.1/*`.
/// Diagnostics include access and permission status both globally and for the exact extension tab adapter.
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
        var checks = 0
        for variant in [Variant.allHost, .singleHost] { checks += try await run(pageURL: pageURL, variant: variant) }
        return checks
    }

    static func run(pageURL: URL, variant: Variant) async throws -> Int {
        var checks = 0
        var prompts: [BrowserExtensionPermissionReview] = []
        var reloadOffers = 0
        func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            guard condition else { throw ExtensionSmokeTest.Failure(description: "Site access lifecycle (\(variant.name)): " + message()) }; checks += 1
        }

        // MARK: Page URL on the same fixture origin.
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/site-access-lifecycle.html"; components.query = nil; components.fragment = nil
        guard let page = components.url, page.scheme == "http", page.host == "127.0.0.1" else {
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: needs the loopback fixture origin, got \(pageURL)")
        }

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
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: fixture did not load: \(host.errors[extensionID] ?? host.lastError ?? "no error")")
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
        var observedTabID: UUID?
        func diagnostics(_ web: WKWebView?, _ state: DocumentState?) -> String {
            let snapshot = host.siteAccess(id: extensionID)
            host.reconcile()
            let adapter = observedTabID.flatMap { runtime?.tabs[$0] }
            let scoped = adapter.map { "tabAccess=\(context.hasAccess(to: page, in: $0)) tabStatus=\(context.permissionStatus(for: page, in: $0).rawValue)" } ?? "tabAdapter=missing"
            let granted = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
            let denied = context.deniedPermissionMatchPatterns.keys.map(\.string).sorted()
            return "[state: \(state.map(String.init(describing:)) ?? "unreadable"); webURL=\(web?.url?.absoluteString ?? "nil") isLoading=\(web?.isLoading ?? false)"
                + "; hasAccess=\(context.hasAccess(to: page)) status=\(context.permissionStatus(for: page).rawValue) \(scoped) granted=\(granted) denied=\(denied)"
                + "; mode=\(snapshot.map { String(describing: $0.state.mode) } ?? "nil") effective=\(snapshot?.effective ?? [])"
                + "; hasInjectedContent(for:)=\(context.hasInjectedContent(for: page)) prompts=\(prompts.map(\.websites)) reloadOffers=\(reloadOffers)]"
        }
        /// Waits until the tab shows a fully loaded document other than `previous` (the page's own identity), then
        /// returns its markers. Navigation completion is the evidence; polling only waits for it.
        func newDocument(after previous: String?, in tabID: UUID, _ step: String) async throws -> (WKWebView, DocumentState) {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var last: DocumentState?
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let web = controller.browsers[tabID], !web.isLoading, let state = await read(web) {
                    last = state
                    if !state.document.isEmpty, state.document != previous, state.readyState == "complete", state.url.hasPrefix(page.absoluteString) {
                        checks += 1; return (web, state)
                    }
                }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle (\(variant.name)): \(step): no new completed document " + diagnostics(controller.browsers[tabID], last))
        }
        func injected(_ state: DocumentState) -> Bool { state.js == "js" && state.css == "injected" }
        func absent(_ state: DocumentState) -> Bool { state.js.isEmpty && state.css.isEmpty }

        // MARK: 1. Allowed: the first document is marked (positive control: the harness sees injection).
        try check(host.siteAccess(id: extensionID)?.state.mode == .allRequested && context.hasAccess(to: page),
                  "the install did not allow the fixture site " + diagnostics(nil, nil))
        guard let openedTab = controller.openProfileTab(page, profileID: profile, active: true) else {
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle (\(variant.name)): could not open the fixture page")
        }
        observedTabID = openedTab
        let tabID = openedTab
        let (_, allowed) = try await newDocument(after: nil, in: tabID, "allowed")
        try check(injected(allowed), "allowed document lacks the JS marker or the CSS property " + diagnostics(controller.browsers[tabID], allowed))

        // MARK: 2. Withhold through the real engine API.
        guard let before = host.siteAccess(id: extensionID), let shown = before.declarations else {
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: no editable snapshot " + diagnostics(nil, nil))
        }
        let withheld = try host.performSiteAccess(id: extensionID, profileID: profile, revision: before.revision, displayed: shown, change: .choose(.withheld))
        try check(withheld.state.mode == .withheld && !context.hasAccess(to: page),
                  "withholding did not remove access " + diagnostics(controller.browsers[tabID], nil))

        // MARK: 3. The Reload Pages path: controller.load(tab.address, in:, id:) → new document, no markers.
        guard let web = controller.browsers[tabID], let tab = controller.session.tabs.first(where: { $0.id == tabID }) else {
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: the fixture tab disappeared")
        }
        controller.load(tab.address, in: web, id: tabID)
        let (_, reloaded) = try await newDocument(after: allowed.document, in: tabID, "withheld load")
        try check(absent(reloaded), "after withholding, a new document loaded through controller.load still has injected content "
                  + diagnostics(controller.browsers[tabID], reloaded))

        // MARK: 4. web.reload() (toolbar, previews) → another new document, still no markers.
        controller.browsers[tabID]?.reload()
        let (_, toolbar) = try await newDocument(after: reloaded.document, in: tabID, "withheld reload")
        try check(absent(toolbar), "after withholding, a document from web.reload() still has injected content " + diagnostics(controller.browsers[tabID], toolbar))
        try check(!context.hasAccess(to: page), "access returned while withheld " + diagnostics(controller.browsers[tabID], toolbar))

        // MARK: 5. Allow again → a new document is marked again.
        guard let current = host.siteAccess(id: extensionID), let declarations = current.declarations else {
            throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: no snapshot to allow again " + diagnostics(nil, nil))
        }
        let restored = try host.performSiteAccess(id: extensionID, profileID: profile, revision: current.revision, displayed: declarations, change: .choose(.allRequested))
        try check(restored.state.mode == .allRequested && context.hasAccess(to: page), "allowing again did not restore access " + diagnostics(controller.browsers[tabID], nil))
        guard let again = controller.browsers[tabID] else { throw ExtensionSmokeTest.Failure(description: "Site access lifecycle: the fixture tab disappeared") }
        controller.load(tab.address, in: again, id: tabID)
        let (_, reallowed) = try await newDocument(after: toolbar.document, in: tabID, "allowed again")
        try check(injected(reallowed), "after allowing again, the new document isn't marked " + diagnostics(controller.browsers[tabID], reallowed))

        // Prompts while withheld were declined and are reported, not asserted.
        print("BAM_SITE_ACCESS_LIFECYCLE " + "{\"variant\":\"\(variant.name)\",\"prompts_while_withheld\":\(prompts.count),\"reload_offers\":\(reloadOffers),\"documents\":4}"); fflush(stdout)
        return checks
    }
}
