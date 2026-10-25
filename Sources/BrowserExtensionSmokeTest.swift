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
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        // Attaching a controller lets AppKit adopt its initially empty root size.
        // Match App.swift: size the content after attachment before testing chrome.
        window.setContentSize(NSSize(width: 920, height: 650))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        defer { controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close() }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(config, profileID: profile)
        let sourceFixture = FileManager.default.temporaryDirectory.appendingPathComponent("bam-browser-extension-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtureURL, to: sourceFixture)
        defer { try? FileManager.default.removeItem(at: sourceFixture) }
        let sourceManifest = sourceFixture.appendingPathComponent("manifest.json")
        var sourceDefinition = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceManifest)) as! [String: Any]
        sourceDefinition["optional_permissions"] = ["alarms", "cookies", "webNavigation"]
        sourceDefinition["optional_host_permissions"] = ["http://localhost/*", "https://optional.invalid/*", "https://removed.invalid/*"]
        try JSONSerialization.data(withJSONObject: sourceDefinition).write(to: sourceManifest)
        let extensionID = try await host.importPackage(at: sourceFixture, profileID: profile)
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
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func actionButton() -> NSButton? {
            descendants(controller.sidebar).first { $0.identifier?.rawValue == "extension-action-\(extensionID.uuidString)" } as? NSButton
        }
        try await wait("Enabled extension did not appear as a visible sidebar action") { actionButton()?.isHidden == false }
        guard let button = actionButton(), let actionContext = host.context(for: extensionID),
              let liveRuntime = config.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let liveTab = liveRuntime.tabs[id], let tabAction = actionContext.action(for: liveTab) else {
            throw ExtensionSmokeTest.Failure(description: "Missing toolbar action fixture")
        }
        try check(button.accessibilityLabel() == actionContext.webExtension.displayName, "Extension button lost its vendor name")
        button.performClick(nil)
        try await wait("Clicking the sidebar action did not show WebKit's actual popup") { tabAction.popupPopover?.isShown == true }
        try check(tabAction.popupPopover?.behavior == .transient, "Extension popup cannot dismiss on outside click")
        try check(liveRuntime.popupAnchor == nil && liveRuntime.popupTabID == nil && liveRuntime.popupContextID == nil, "Presented popup retained a reusable invocation anchor")
        tabAction.closePopup()
        controller.setSidebar(false)
        try await wait("Sidebar did not finish collapsing around the extension shelf") { controller.sidebar.isHidden }
        let collapsedMenu = NSMenu(); controller.updateExtensionsMenu(collapsedMenu)
        try check(collapsedMenu.items.contains { $0.title == actionContext.webExtension.displayName } && collapsedMenu.items.contains { $0.title == "Add Extensions…" }, "Collapsed sidebar lost extension actions or library access")
        controller.setSidebar(true)
        try await wait("Extension shelf did not return when expanding the sidebar") { !controller.sidebar.isHidden && actionButton()?.isHidden == false }
        guard let runtime = config.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let tabIndex = controller.session.tabs.firstIndex(where: { $0.id == id }) else {
            throw ExtensionSmokeTest.Failure(description: "Missing single-tab lookup fixture")
        }
        let originalSpace = controller.session.tabs[tabIndex].space
        controller.session.tabs[tabIndex].space = otherSpace
        let movedSurface = runtime.currentSurface(id)
        controller.session.tabs[tabIndex].space = originalSpace
        try check(movedSurface == nil, "A moved tab remained available through the direct resolver before reconciliation")
        controller.session.changeSpace(otherSpace); controller.showActive(); controller.refresh()
        try check(actionButton() == nil, "Sidebar exposed an extension from another login profile")
        host.performAction(extensionID: extensionID, tabID: id, anchor: controller.sidebar)
        try check(liveRuntime.popupContextID == nil, "A stale menu invocation retained an inactive profile's popup request")
        var stalePopupError: Error?
        liveRuntime.webExtensionController(liveRuntime.controller, presentActionPopup: tabAction, for: actionContext) { stalePopupError = $0 }
        try check(stalePopupError != nil && tabAction.popupPopover?.isShown != true, "An asynchronously presented popup appeared over a different profile")
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
        // Cancellation is a no-op on the running package and signed-in storage.
        let updateFolder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-action-update-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: sourceFixture, to: updateFolder)
        defer { try? FileManager.default.removeItem(at: updateFolder) }
        let updateManifest = updateFolder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: updateManifest)) as! [String: Any]
        manifest["version"] = "2.0.0"
        manifest["optional_permissions"] = ["alarms", "cookies"]
        manifest["optional_host_permissions"] = ["http://localhost/*", "https://optional.invalid/*"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: updateManifest)
        let installedManifest = host.storageURL.appendingPathComponent(extensionID.uuidString).appendingPathComponent("package/manifest.json")
        let originalBytes = try Data(contentsOf: installedManifest)
        let grantExpiry = Date(timeIntervalSinceNow: 86_400)
        let optionalGranted = try WKWebExtension.MatchPattern(string: "http://localhost/kept/*")
        let optionalDenied = try WKWebExtension.MatchPattern(string: "https://optional.invalid/blocked/*")
        let removedScope = try WKWebExtension.MatchPattern(string: "https://removed.invalid/*")
        func seedOptionalPermissions(_ context: WKWebExtensionContext) {
            context.setPermissionStatus(.grantedExplicitly, for: .alarms, expirationDate: grantExpiry)
            context.setPermissionStatus(.deniedExplicitly, for: .cookies, expirationDate: grantExpiry)
            context.setPermissionStatus(.grantedExplicitly, for: .webNavigation, expirationDate: grantExpiry)
            context.setPermissionStatus(.grantedExplicitly, for: optionalGranted, expirationDate: grantExpiry)
            context.setPermissionStatus(.deniedExplicitly, for: optionalDenied, expirationDate: grantExpiry)
            context.setPermissionStatus(.grantedExplicitly, for: removedScope, expirationDate: grantExpiry)
            host.persistPermissions(context)
        }
        let originalContext = host.context(for: extensionID)!
        seedOptionalPermissions(originalContext)
        let originalRecord = host.items(profileID: profile).first { $0.id == extensionID }!
        let catalog = ExtensionCatalogRecord(source: .local, upstreamID: nil, listingURL: nil, downloadURL: nil,
            publisher: "Bam test fixture", version: "2.0.0", sha256: "", provenance: "Original local fixture", installedAt: Date())
        host.permissionPrompt = { _ in false }
        var cancelled = false
        do { try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog) }
        catch is BrowserExtensionUpdateCancelled { cancelled = true }
        let afterCancel = host.items(profileID: profile).first { $0.id == extensionID }
        try check(cancelled && host.context(for: extensionID) === originalContext && afterCancel?.enabled == true,
            "Canceling an update unloaded or disabled the working extension")
        try check(try Data(contentsOf: installedManifest) == originalBytes && afterCancel?.version == originalRecord.version &&
            afterCancel?.permissions == originalRecord.permissions && afterCancel?.patterns == originalRecord.patterns && afterCancel?.catalog == originalRecord.catalog,
            "Canceling an update replaced package bytes, grants or provenance")
        // The native initializer may finish synchronously for a tiny fixture.
        // Wrap the real parser so user changes happen before its result returns,
        // instead of relying on a queued Task winning an unspecified scheduling race.
        let nativeParser = host.packageParser
        defer { host.packageParser = nativeParser }
        host.permissionPrompt = { _ in true }
        var mutateStaging = true
        host.packageParser = { [weak host] package in
            let parsed = try await WKWebExtension(resourceBaseURL: package)
            if mutateStaging, let host {
                mutateStaging = false
                try await host.setEnabled(false, id: extensionID)
                try await host.setEnabled(true, id: extensionID)
            }
            return parsed
        }
        var stagingCancelled = false
        do { try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog) }
        catch is BrowserExtensionUpdateCancelled { stagingCancelled = true }
        let stagedRecord = host.items(profileID: profile).first { $0.id == extensionID }
        try check(!mutateStaging && stagingCancelled && stagedRecord?.version == originalRecord.version && host.context(for: extensionID) != nil,
            "Staging mutation was not preserved: ran=\(!mutateStaging), canceled=\(stagingCancelled), version=\(stagedRecord?.version ?? "missing"), loaded=\(host.context(for: extensionID) != nil)")
        // Review arms the next (activation) parse. Disabling then must restore
        // the prior bytes without resurrecting the explicitly disabled extension.
        var disableOnNextParse = false, activationDisableRan = false
        host.packageParser = { [weak host] package in
            let parsed = try await WKWebExtension(resourceBaseURL: package)
            if disableOnNextParse, let host {
                disableOnNextParse = false; activationDisableRan = true
                try await host.setEnabled(false, id: extensionID)
            }
            return parsed
        }
        host.permissionPrompt = { _ in disableOnNextParse = true; return true }
        var activationCancelled = false
        do { try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog) }
        catch is BrowserExtensionUpdateCancelled { activationCancelled = true }
        let interruptedRecord = host.items(profileID: profile).first { $0.id == extensionID }
        try check(activationDisableRan && activationCancelled && host.context(for: extensionID) == nil && interruptedRecord?.enabled == false,
            "Activation mutation was not preserved: ran=\(activationDisableRan), canceled=\(activationCancelled), enabled=\(String(describing: interruptedRecord?.enabled)), loaded=\(host.context(for: extensionID) != nil)")
        try check(try Data(contentsOf: installedManifest) == originalBytes, "Interrupted activation failed to restore the previous package")
        // Closing the library while a disabled extension is being parsed must
        // cancel before any new permission prompt or activation.
        var cancelledEnableReviews = 0
        host.permissionPrompt = { _ in cancelledEnableReviews += 1; return true }
        host.packageParser = { package in
            let parsed = try await WKWebExtension(resourceBaseURL: package)
            withUnsafeCurrentTask { $0?.cancel() }
            return parsed
        }
        let cancelledEnable = Task { @MainActor in try await host.setEnabled(true, id: extensionID) }
        var enableCancelled = false
        do { try await cancelledEnable.value }
        catch is CancellationError { enableCancelled = true }
        try check(enableCancelled && cancelledEnableReviews == 0 && host.context(for: extensionID) == nil &&
            host.items(profileID: profile).first { $0.id == extensionID }?.enabled == false && host.errors[extensionID] == nil,
            "Canceled re-enable prompted, activated, or reported a healthy disabled extension as broken")
        host.packageParser = nativeParser
        host.permissionPrompt = { _ in true }
        try await host.setEnabled(true, id: extensionID)
        guard let beforeUpdateContext = host.context(for: extensionID) else { throw ExtensionSmokeTest.Failure(description: "Update fixture could not re-enable") }
        seedOptionalPermissions(beforeUpdateContext)
        let grantedBeforeUpdate = host.items(profileID: profile).first { $0.id == extensionID }!
        // WebKit normalizes date precision. Preserve the expiry it actually
        // stored, rather than requiring the original sub-millisecond Date bits.
        let beforeValues = [grantedBeforeUpdate.permissions["alarms"], grantedBeforeUpdate.deniedPermissions["cookies"],
            grantedBeforeUpdate.patterns[optionalGranted.string], grantedBeforeUpdate.deniedPatterns[optionalDenied.string]]
        try check(beforeValues.allSatisfy { $0 != nil && abs($0!.timeIntervalSince(grantExpiry)) < 0.001 },
            "Native fixture did not store its optional grants/denials: \(beforeValues.map { $0?.timeIntervalSince1970 })")
        try await host.replacePackage(id: extensionID, with: updateFolder, catalog: catalog)
        let updatedRecord = host.items(profileID: profile).first { $0.id == extensionID }!
        let afterValues = [updatedRecord.permissions["alarms"], updatedRecord.deniedPermissions["cookies"],
            updatedRecord.patterns[optionalGranted.string], updatedRecord.deniedPatterns[optionalDenied.string]]
        try check(afterValues == beforeValues,
            "Update lost optional grants/denials: before=\(beforeValues.map { $0?.timeIntervalSince1970 }), after=\(afterValues.map { $0?.timeIntervalSince1970 }), grantedSites=\(updatedRecord.patterns.keys.sorted()), deniedSites=\(updatedRecord.deniedPatterns.keys.sorted())")
        try check(updatedRecord.permissions["webNavigation"] == nil && updatedRecord.patterns[removedScope.string] == nil && updatedRecord.permissions["storage"] != nil,
            "An update retained removed permissions or lost approved required permissions")
        try check(host.items(profileID: profile).first { $0.id == extensionID }?.version == "2.0.0" && host.context(for: extensionID) != nil,
            "Approved update did not activate its final package")
        guard let updatedPopup = host.context(for: extensionID)?.action(for: nil)?.popupWebView else { throw ExtensionSmokeTest.Failure(description: "Updated package has no popup") }
        try await wait("Updated extension still looked for scripts at the staging URL") { (try? await updatedPopup.evaluateJavaScript("document.title")) as? String == "Bam fixture ready" }
        try await host.setEnabled(false, id: extensionID)
        controller.refresh()
        try check(actionButton() == nil, "Disabling the extension left a stale sidebar action")
        controller.navigatePane(tab.id, address: extensionURL.absoluteString)
        try check(controller.tabErrors[tab.id]?.contains("unavailable") == true, "Disabled extension page had no recoverable error")
        return checks
    }
}
