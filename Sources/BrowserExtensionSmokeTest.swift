import AppKit
import WebKit

/// Covers the real browser adapter, in addition to the isolated extension host.
@available(macOS 15.4, *)
@MainActor enum BrowserExtensionSmokeTest {
    static func run(fixtureURL: URL, pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ExtensionSmokeTest.Failure(description: message) }; checks += 1
        }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw ExtensionSmokeTest.Failure(description: message)
        }
        let controller = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-extension-session.json"), ephemeral: true)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let profile = controller.session.currentProfileID
        let other = controller.session.createProfile(name: "Other")!
        let otherSpace = controller.session.createSpace(name: "Other", symbol: "briefcase", colorIndex: 1, profileID: other)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller; window.makeKeyAndOrderFront(nil)
        defer { controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close() }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(config, profileID: profile)
        let extensionID = try await host.importPackage(at: fixtureURL, profileID: profile)
        let url = pageURL.appending(queryItems: [URLQueryItem(name: "profile", value: "browser-adapter")])
        guard let id = controller.openProfileTab(url, profileID: profile, active: true), let web = controller.browsers[id] else { throw ExtensionSmokeTest.Failure(description: "Browser adapter did not create its page") }
        try await wait("Browser adapter did not inject extension on first navigation") {
            (try? await web.evaluateJavaScript("document.documentElement.dataset.bamExtensionResult || ''") as? String)?.contains("browser-adapter") == true
        }
        func checkLiveLookup(_ profileID: UUID) throws {
            for surface in controller.extensionSurfaces(profileID: profileID) {
                guard let direct = controller.extensionSurface(profileID: profileID, id: surface.id) else {
                    throw ExtensionSmokeTest.Failure(description: "Live single-tab resolver omitted a listed page")
                }
                try check(direct.id == surface.id && direct.title == surface.title && direct.url == surface.url &&
                          direct.webView === surface.webView && direct.window === surface.window &&
                          direct.isActive == surface.isActive && direct.isSelected == surface.isSelected && direct.isPinned == surface.isPinned &&
                          direct.isLoading == surface.isLoading,
                          "Single-tab resolver diverged from the browser's live surface list")
            }
        }
        try checkLiveLookup(profile)
        guard let runtime = config.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let tabIndex = controller.session.tabs.firstIndex(where: { $0.id == id }) else {
            throw ExtensionSmokeTest.Failure(description: "Missing single-tab lookup fixture")
        }
        let originalSpace = controller.session.tabs[tabIndex].space
        controller.session.tabs[tabIndex].space = otherSpace
        let movedSurface = runtime.currentSurface(id)
        controller.session.tabs[tabIndex].space = originalSpace
        try check(movedSurface == nil, "A moved tab remained available through the direct resolver before reconciliation")
        controller.session.changeSpace(otherSpace); controller.showActive()
        try checkLiveLookup(profile); try checkLiveLookup(other)
        host.reconcile()
        guard let context = host.context(for: extensionID), let popup = context.action(for: nil)?.popupWebView else { throw ExtensionSmokeTest.Failure(description: "Missing browser-adapter action popup") }
        try await wait("Browser-adapter popup did not initialize") { (try? await popup.evaluateJavaScript("document.title")) as? String == "Bam fixture ready" }
        // A finished load must reach the extension as `tabs.onUpdated` with `status: "complete"`
        // even though the URL did not change after commit (Dashlane's sign-in check waits for it).
        try await wait("Browser adapter never reported the page load as complete to tabs.onUpdated") {
            let updates = try? await popup.callAsyncJavaScript("return JSON.stringify((await browser.runtime.sendMessage({kind: \"updates\"})).updates || []);", arguments: [:], contentWorld: .page)
            guard let text = updates as? String, let data = text.data(using: .utf8),
                  let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
            // The changeInfo must carry the status: a title-driven update also reads `status: "complete"` live.
            return records.contains { ($0["infoStatus"] as? String) == "complete" && ($0["url"] as? String)?.contains("extension-test.html") == true }
        }
        _ = try await popup.evaluateJavaScript("document.getElementById('open-page').click(); true")
        try await wait("Browser adapter did not open its own extension page") { controller.session.tabs.contains { URLInput.extensionURL($0.address) != nil } }
        guard let tab = controller.session.tabs.first(where: { URLInput.extensionURL($0.address) != nil }), let extensionWeb = controller.browsers[tab.id] else { throw ExtensionSmokeTest.Failure(description: "Missing extension renderer") }
        try await wait("Browser adapter used the wrong configuration for its extension page") { extensionWeb.title == "Bam extension page ready" }
        try check(controller.session.profileID(for: tab) == profile && controller.profileID(of: extensionWeb) == profile, "Extension-created page escaped its source profile")
        let extensionURL = URL(string: tab.address)!
        try check(controller.openProfileTab(extensionURL, profileID: other, active: false) == nil, "Browser adapter opened extension page in a foreign profile")
        controller.navigatePane(tab.id, address: url.absoluteString)
        try await wait("Extension-to-HTTP navigation did not replace renderer") { controller.browsers[tab.id] !== extensionWeb && controller.browsers[tab.id]?.url == url && controller.browsers[tab.id]?.isLoading == false }
        let normal = controller.browsers[tab.id]!
        controller.navigatePane(tab.id, address: extensionURL.absoluteString)
        try await wait("HTTP-to-extension navigation did not replace renderer") { controller.browsers[tab.id] !== normal && controller.browsers[tab.id]?.title == "Bam extension page ready" }
        try await host.setEnabled(false, id: extensionID)
        controller.navigatePane(tab.id, address: extensionURL.absoluteString)
        try check(controller.tabErrors[tab.id]?.contains("unavailable") == true, "Disabled extension page had no recoverable error")
        return checks
    }
}
