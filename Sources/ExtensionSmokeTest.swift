import Foundation
import AppKit
import WebKit

/// Real WebKit extension execution. All packages are original bundled fixtures;
/// no vendor extension, account, browser profile, or remote page is used.
@available(macOS 15.4, *)
@MainActor enum ExtensionSmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run(fixtureURL: URL, pageURL: URL) async throws -> Int {
        var checks = 0
        @MainActor func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(description: message) }; checks += 1
        }
        @MainActor func javascript(_ web: WKWebView, _ expression: String) async -> Any? { try? await web.evaluateJavaScript(expression) }
        @MainActor func wait(_ message: String, timeout: TimeInterval = 12, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw Failure(description: message)
        }
        @MainActor func result(_ web: WKWebView) async -> [String: Any]? {
            guard let text = await javascript(web, "document.documentElement.dataset.bamExtensionResult || ''") as? String,
                  let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let host = BrowserExtensions(storageURL: nil, isPrivate: true)
        let profileA = UUID(), profileB = UUID(), tabA = UUID(), tabB = UUID()
        let configA = WKWebViewConfiguration(), configB = WKWebViewConfiguration()
        configA.websiteDataStore = .nonPersistent(); configB.websiteDataStore = .nonPersistent()
        host.configure(configA, profileID: profileA); host.configure(configB, profileID: profileB)
        await host.ready(profileID: profileA); await host.ready(profileID: profileB)
        try check(configA.webExtensionController !== configB.webExtensionController, "Login profiles shared an extension controller")
        try check(configA.websiteDataStore !== configB.websiteDataStore, "Login profiles shared a cookie store")
        let webA = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 340), configuration: configA)
        let webB = WKWebView(frame: webA.frame, configuration: configB)
        let window = NSWindow(contentRect: webA.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: webA.frame); window.contentView = container
        container.addSubview(webA); container.addSubview(webB); webB.isHidden = true
        window.orderFront(nil)
        defer { host.shutdown(); webA.stopLoading(); webB.stopLoading(); window.orderOut(nil); window.close() }
        let urlA = pageURL.appending(queryItems: [URLQueryItem(name: "profile", value: "profile-A")])
        let urlB = pageURL.appending(queryItems: [URLQueryItem(name: "profile", value: "profile-B")])
        var extensionPages: [UUID: WKWebView] = [:]
        var includeProfileATab = true
        host.surfaces = { profile in
            if profile == profileA { return (includeProfileATab ? [BrowserExtensionSurface(id: tabA, title: "Profile A", url: urlA, webView: webA, window: window, isActive: true, isSelected: true)] : []) + extensionPages.map { BrowserExtensionSurface(id: $0.key, title: "Extension page", url: $0.value.url, webView: $0.value, window: window) } }
            if profile == profileB { return [BrowserExtensionSurface(id: tabB, title: "Profile B", url: urlB, webView: webB, window: window)] }
            return []
        }
        host.createTab = { [weak host] url, profile, active in
            guard let host, profile == profileA, let configuration = host.configuration(forExtensionURL: url, profileID: profile) else { return nil }
            let web = WKWebView(frame: webA.frame, configuration: configuration), id = UUID()
            extensionPages[id] = web; container.addSubview(web); web.isHidden = true
            web.load(URLRequest(url: url)); return id
        }
        host.reconcile()
        // Deterministic readiness queues exercise real transient content/adoption.
        // No extension code is injected manually, and no profile data is persistent.
        var pending: [@MainActor () -> Void] = []
        let deferredConfiguration = WKWebViewConfiguration(); deferredConfiguration.websiteDataStore = .nonPersistent()
        let deferredWeb = PreviewWKWebView(frame: webA.frame, configuration: deferredConfiguration)
        try check(deferredWeb.configuration.webExtensionController == nil && deferredWeb.configuration.websiteDataStore !== configA.websiteDataStore && deferredWeb.configuration.websiteDataStore !== configB.websiteDataStore, "Readiness fixture unexpectedly reused an extension profile")
        let deferredContent = PreviewWebContent(webView: deferredWeb, beforeLoad: { pending.append($0) })
        try check(deferredContent.load(url: urlA) && deferredContent.load(url: urlB), "Deferred preview rejected valid HTTP pages")
        try check(deferredWeb.url == nil && !deferredWeb.isLoading && pending.count == 2, "Preview navigated before extension readiness")
        pending[0]()
        try check(deferredWeb.url == nil && !deferredWeb.isLoading, "Obsolete queued preview navigation was not cancelled")
        pending[1]()
        try await wait("Latest queued preview did not navigate after readiness") { await javascript(deferredWeb, "document.body.dataset.bamFixtureToken") as? String == "profile-B" }
        try check(deferredWeb.pendingReadyURL == nil, "Completed navigation retained a pending request")
        try check(deferredContent.load(url: urlA), "Could not queue a preview for promotion")
        let transferred = deferredContent.takeWebView()
        try check(transferred === deferredWeb && deferredWeb.pendingReadyURL == urlA, "Pending promotion lost its requested URL or view")
        var adoptedPending: [@MainActor () -> Void] = []
        let little = LittleBamController(websiteDataStore: deferredConfiguration.websiteDataStore, beforeLoad: { adoptedPending.append($0) })
        defer { little.close() }
        little.adopt(webView: deferredWeb)
        try check(adoptedPending.count == 1 && little.webView === deferredWeb, "Little Bam failed to adopt the pending navigation through its readiness gate")
        pending[2]()
        try check(deferredWeb.url == urlB && !deferredWeb.isLoading, "Obsolete source gate navigated a transferred view")
        adoptedPending[0]()
        try await wait("Adopted pending navigation did not resume") { await javascript(deferredWeb, "document.body.dataset.bamFixtureToken") as? String == "profile-A" }
        try check(!little.open(url: URL(string: "webkit-extension://00000000-0000-0000-0000-000000000001/page.html")!), "Preview accepted an extension-origin URL without an extension configuration")
        little.close()
        try check(little.webView == nil && deferredWeb.navigationDelegate == nil, "Readiness fixture retained its transient host before extension imports")
        var reviewed: [BrowserExtensionPermissionReview] = []
        host.permissionPrompt = { reviewed.append($0); return false }
        let catalogCandidate = ExtensionBuildCandidate(source: .amo, upstreamID: "bam-fixture@example.test", name: "Bam fixture", publisher: "Bam tests", version: "1", downloadURL: URL(string: "https://fixture.invalid/original.xpi"))
        let catalogRecord = ExtensionCatalogRecord(source: .amo, upstreamID: catalogCandidate.upstreamID, publisher: "Bam tests", version: "1", sha256: "fixture", provenance: "Original local test fixture", installedAt: Date())
        let extensionA = try await host.importPackage(at: fixtureURL, profileID: profileA, catalog: catalogRecord)
        try check(host.context(for: extensionA) == nil && host.items(profileID: profileA).first?.enabled == false, "Cancelled permission review still enabled the extension")
        try check(reviewed.count == 1 && reviewed[0].websites.contains("http://127.0.0.1/*") && reviewed[0].unsupported.contains("nativeMessaging"), "Permission review omitted required websites or unsupported native messaging")
        let installer = host.installer
        let canceledRetry = try await installer.install(catalogCandidate, profileID: profileA)
        try check(canceledRetry == extensionA && host.items(profileID: profileA).count == 1 && host.context(for: extensionA) == nil, "Retrying canceled activation duplicated or enabled the extension")
        try check(installer.installedRecord(for: catalogCandidate, profileID: profileB) == nil, "Installed state leaked into another profile")
        var otherSource = catalogCandidate; otherSource.source = .chromeWebStore
        try check(installer.installedRecord(for: otherSource, profileID: profileA) == nil, "Installed state silently treated a different store as the same build")
        host.permissionPrompt = { reviewed.append($0); return true }
        let enabledRetry = try await installer.install(catalogCandidate, profileID: profileA)
        try check(enabledRetry == extensionA && host.items(profileID: profileA).count == 1, "Enabling an existing install duplicated its record")
        let reviewCount = reviewed.count
        let repeatedInstall = try await installer.install(catalogCandidate, profileID: profileA)
        try check(repeatedInstall == extensionA && host.items(profileID: profileA).count == 1 && reviewed.count == reviewCount, "Adding an enabled extension repeated its download or permission review")
        guard let contextA = host.context(for: extensionA) else { throw Failure(description: "Extension A did not load: \(host.lastError ?? "unknown")") }
        try check(contextA.hasPermission(.storage) && contextA.hasPermission(.nativeMessaging) &&
            ExtensionServiceWorkerPreparation.isPrepared(manifest: contextA.webExtension.manifest), "Approved storage or the prepared worker's internal transport was omitted")
        webA.load(URLRequest(url: urlA)); webB.load(URLRequest(url: urlB))
        try await wait("Content script/background/storage did not run in profile A") { await result(webA)?["token"] as? String == "profile-A" }
        try await wait("MV3 runtime.connect handshake did not return profile A storage") { await javascript(webA, "document.documentElement.dataset.bamExtensionPort") as? String == "profile-A" }
        try await wait("Profile B page did not finish loading") { await javascript(webB, "document.body.dataset.bamFixtureToken") as? String == "profile-B" }
        try check(await result(webB) == nil, "Extension enabled only in A injected into B")
        let resultA = await result(webA)
        try check(resultA?["nativeMessagingExposed"] as? Bool == true && resultA?["externalNativeDenied"] as? Bool == true,
                  "The worker's internal transport was missing or allowed an external native application")
        let urlsA = resultA?["urls"] as? [String] ?? []
        try check(urlsA == [urlA.absoluteString], "Extension A enumerated a page from another profile: \(urlsA)")
        guard let runtimeA = configA.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let staleTab = runtimeA.tabs[tabA], let staleWindow = staleTab.window(for: contextA) as? BrowserExtensionWindow else { throw Failure(description: "Missing native fixture adapter") }
        var staleCallbacks = 0, refusedActions = 0
        host.closeTab = { _ in staleCallbacks += 1; return true }
        host.navigateTab = { _, _ in staleCallbacks += 1; return true }
        host.reloadTab = { _, _ in staleCallbacks += 1; return true }
        includeProfileATab = false // Simulate a profile move before queued reconciliation.
        staleTab.close(for: contextA) { if $0 != nil { refusedActions += 1 } }
        staleTab.loadURL(urlA, for: contextA) { if $0 != nil { refusedActions += 1 } }
        staleTab.reload(fromOrigin: true, for: contextA) { if $0 != nil { refusedActions += 1 } }
        try check(staleCallbacks == 0 && refusedActions == 3, "A stale extension adapter acted on a tab after its profile changed")
        try check(staleTab.webView(for: contextA) == nil && staleTab.url(for: contextA) == nil && staleWindow.tabs(for: contextA).isEmpty, "A stale extension adapter exposed another profile's page")
        includeProfileATab = true
        host.permissionPrompt = { _ in includeProfileATab = false; return true }
        var optionalGrant = Set<WKWebExtension.Permission>()
        runtimeA.webExtensionController(runtimeA.controller, promptForPermissions: [.alarms], in: staleTab, for: contextA) { granted, _ in optionalGrant = granted }
        try check(optionalGrant.isEmpty && !contextA.hasPermission(.alarms), "Permission prompt granted after its tab left the requesting profile")
        includeProfileATab = true; host.closeTab = nil; host.navigateTab = nil; host.reloadTab = nil
        host.permissionPrompt = { reviewed.append($0); return true }
        // Archives are deliberately rejected until expanded bounds can be enforced.
        let archiveFolder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-extension-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveFolder) }
        let archiveURL = archiveFolder.appendingPathComponent("fixture.zip")
        try Data([0x50, 0x4b, 0x05, 0x06]).write(to: archiveURL)
        var rejectedArchive = false
        do { _ = try await host.importPackage(at: archiveURL, profileID: profileB) } catch { rejectedArchive = true }
        try check(rejectedArchive && host.items(profileID: profileB).isEmpty, "Archive import was accepted without expanded-entry validation")
        // The hidden profile also exercises real MV2 background.scripts decoding.
        // Only our original fixture is copied/changed; no vendor logic is patched.
        let mv2Fixture = archiveFolder.appendingPathComponent("mv2-fixture", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureURL, to: mv2Fixture)
        let mv2ManifestURL = mv2Fixture.appendingPathComponent("manifest.json")
        guard var mv2Manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: mv2ManifestURL)) as? [String: Any] else { throw Failure(description: "Original fixture manifest is not an object") }
        mv2Manifest["manifest_version"] = 2
        let mv2Hosts = mv2Manifest.removeValue(forKey: "host_permissions") as? [String] ?? []
        // Firefox-style builds request APIs WebKit lacks; Bam's compatibility layer stands in.
        mv2Manifest["permissions"] = (mv2Manifest["permissions"] as? [String] ?? []).filter { $0 != "scripting" } + ["notifications", "idle"] + mv2Hosts
        mv2Manifest["optional_permissions"] = mv2Manifest.removeValue(forKey: "optional_host_permissions")
        mv2Manifest["browser_action"] = mv2Manifest.removeValue(forKey: "action")
        mv2Manifest["background"] = ["scripts": ["nonascii.js", "compat.js", "background.js"], "persistent": false]
        try ExtensionFrameMessagingSmokeTest.prepare(package: mv2Fixture, manifest: &mv2Manifest)
        let originalManifest = try JSONSerialization.data(withJSONObject: mv2Manifest, options: [.sortedKeys, .prettyPrinted])
        try originalManifest.write(to: mv2ManifestURL)
        let nonASCII = Data("globalThis.bamCafé = \"naïve ☕\";\n".utf8)
        try nonASCII.write(to: mv2Fixture.appendingPathComponent("nonascii.js"))
        // Exercises callback and promise styles of the shimmed namespaces from a real background page.
        let compatProbe = """
        globalThis.bamCompatProbe = (async () => {
          const api = globalThis.browser || globalThis.chrome;
          const out = { notifications: typeof api.notifications?.create, idle: typeof api.idle?.queryState,
            navigationTarget: typeof api.webNavigation?.onCreatedNavigationTarget?.addListener, downloads: typeof api.downloads, management: typeof api.management };
          try {
            out.idleState = await new Promise(resolve => api.idle.queryState(60, resolve));
            out.level = await api.notifications.getPermissionLevel();
            out.browser = (await api.runtime.getBrowserInfo()).name;
            out.updateCheck = (await api.runtime.requestUpdateCheck())[0];
            out.self = (await api.management.getSelf()).name;
            api.notifications.onClicked.addListener(() => {});
          } catch (error) { out.error = String(error); }
          return out;
        })();
        """
        try Data(compatProbe.utf8).write(to: mv2Fixture.appendingPathComponent("compat.js"))
        let extensionB = try await host.importPackage(at: mv2Fixture, profileID: profileB)
        let importedFolder = host.storageURL.appendingPathComponent(extensionB.uuidString)
        try check(host.items(profileID: profileB).first?.compatibilityNote != nil && reviewed.last?.compatibilityNote != nil, "MV2 compatibility preparation was not disclosed")
        try check(try Data(contentsOf: importedFolder.appendingPathComponent("original-manifest.json")) == originalManifest, "MV2 import did not preserve the byte-exact original manifest")
        try check(try Data(contentsOf: importedFolder.appendingPathComponent("package/nonascii.js")) == nonASCII && Data(contentsOf: mv2ManifestURL) == originalManifest, "MV2 preparation changed script bytes or the selected source package")
        guard let contextB = host.context(for: extensionB) else { throw Failure(description: "Extension B did not load") }
        try check(contextB.hasPermission(.init(rawValue: "webRequest")), "Isolated iframe fixture was not granted webRequest")
        guard let runtimeB = configB.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let backgroundTab = runtimeB.tabs[tabB], let backgroundWindow = backgroundTab.window(for: contextB) as? BrowserExtensionWindow else { throw Failure(description: "Missing background-profile native adapter") }
        try check(backgroundWindow.activeTab(for: contextB) as? BrowserExtensionTab === backgroundTab && backgroundTab.isSelected(for: contextB), "Inactive profile window did not retain a valid selected tab")
        try check(runtimeB.focusedWindow() == nil && webB.isHidden, "Background profile fixture became foreground to make messaging succeed")
        let profileBBeforeReload = await javascript(webB, "performance.timeOrigin") as? Double
        let profileBNavigation = webB.reload()
        do {
            try await wait("Profile B extension did not inject after enable/reload") { await result(webB)?["token"] as? String == "profile-B" }
        } catch {
            // Diagnostic only: forcing background startup after the failed assertion
            // cannot turn this run into a pass or conceal missed content injection.
            var background = "callback pending"
            contextB.loadBackgroundContent { error in
                Task { @MainActor in background = error?.localizedDescription ?? "loaded" }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.6
            while background == "callback pending" && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            let page = await javascript(webB, "({title:document.title,url:location.href,ready:document.readyState,visibility:document.visibilityState,token:document.body?.dataset.bamFixtureToken || '',injected:document.documentElement.dataset.bamExtensionStarted || '',result:document.documentElement.dataset.bamExtensionResult || '',error:document.documentElement.dataset.bamExtensionError || '',timeOrigin:performance.timeOrigin})")
            let diagnostics: [String: Any] = [
                "stage": "profile-B-after-enable-reload", "page": page ?? "unavailable",
                "profile_A_result": await result(webA) ?? [:], "before_reload_timeOrigin": profileBBeforeReload ?? -1,
                "navigation_returned": profileBNavigation != nil, "native_url": webB.url?.absoluteString ?? "nil",
                "native_title": webB.title ?? "nil", "loading": webB.isLoading, "hidden": webB.isHiddenOrHasHiddenAncestor,
                "context_loaded": contextB.isLoaded, "controller_matches": contextB.webExtensionController === webB.configuration.webExtensionController,
                "profile_controllers_distinct": contextA.webExtensionController !== contextB.webExtensionController,
                "profile_stores_distinct": webA.configuration.websiteDataStore !== webB.configuration.websiteDataStore,
                "background_load": background, "context_errors": contextB.errors.map(\.localizedDescription),
                "manifest_errors": contextB.webExtension.errors.map(\.localizedDescription),
                "permissions": contextB.grantedPermissions.keys.map(\.rawValue).sorted(),
                "patterns": contextB.grantedPermissionMatchPatterns.keys.map(\.string).sorted(),
                "has_page_access": contextB.hasAccess(to: urlB), "host_error": host.errors[extensionB] ?? host.lastError ?? "none"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
                print("EXTENSION_DIAGNOSTIC \(text)"); fflush(stdout)
            }
            throw error
        }
        try check(await result(webB)?["encoding"] as? String == "naïve ☕", "MV2 background did not execute its original non-ASCII JavaScript correctly")
        let compat = await result(webB)?["compat"] as? [String: Any] ?? [:]
        // webNavigation is not requested, so the layer must not conjure that namespace either.
        try check(compat["notifications"] as? String == "function" && compat["idle"] as? String == "function" && compat["navigationTarget"] as? String == "undefined" && compat["downloads"] as? String == "undefined" && compat["management"] as? String == "undefined",
                  "Compatibility layer did not provide exactly the requested namespaces: \(compat)")
        try check(["active", "idle", "locked"].contains(compat["idleState"] as? String ?? "") && compat["browser"] as? String == "Bam" && compat["updateCheck"] as? String == "no_update" && compat["self"] == nil && compat["error"] != nil,
                  "Compatibility layer answered unexpectedly: \(compat)")
        try check(Set(reviewed.last?.bridged ?? []) == ["notifications", "idle"] && reviewed.last?.unsupported == ["nativeMessaging"] && host.items(profileID: profileB).first?.compatibility.map(Set.init) == ["notifications", "idle"],
                  "Permission review did not disclose the compatibility layer: \(reviewed.last?.bridged ?? []) \(reviewed.last?.unsupported ?? [])")
        try check(await result(webA)?["compat"] as? String == "absent" && (host.items(profileID: profileA).first?.compatibility ?? []).isEmpty, "MV3 fixture without bridged permissions received the compatibility layer")
        try await wait("MV2 runtime.connect handshake did not return profile B storage") { await javascript(webB, "document.documentElement.dataset.bamExtensionPort") as? String == "profile-B" }
        // WebKit never answers callback-style sendMessage from content scripts on its own; the prepared
        // messaging adapter must, for both the (message, callback) and (extensionId, message, callback) forms.
        try await wait("Callback-style sendMessage from a content script was not answered") {
            let withID = await javascript(webA, "document.documentElement.dataset.bamExtensionCallbackID") as? String
            let plain = await javascript(webA, "document.documentElement.dataset.bamExtensionCallback") as? String
            return withID == "callback-id" && plain == "callback"
        }
        try await wait("Callback-style sendMessage from an MV2 content script was not answered") { await javascript(webB, "document.documentElement.dataset.bamExtensionCallbackID") as? String == "callback-id" }
        checks += try await ExtensionFrameMessagingSmokeTest.verify(web: webB, pageURL: urlB, label: "isolated MV2")
        try check(host.items(profileID: profileA).first?.compatibilityNote?.contains("messaging adapter") == true, "The content-script adaptation is not disclosed for the MV3 fixture")
        try check(await result(webA)?["token"] as? String == "profile-A", "Profile B overwrote profile A extension storage")
        try check(await result(webB)?["urls"] as? [String] == [urlB.absoluteString], "Extension B enumerated another profile")
        guard let popup = contextA.action(for: nil)?.popupWebView else { throw Failure(description: "Native WebKit action did not provide a real popup web view") }
        popup.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        try await wait("Extension action popup did not complete its background-message round trip") { await javascript(popup, "document.title") as? String == "Bam fixture ready" }
        @MainActor func fixtureMenuItem(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == "Bam fixture tab command" { return item }
                if let submenu = item.submenu, let result = fixtureMenuItem(in: submenu) { return result }
            }
            return nil
        }
        let commands = host.actionsMenu(profileID: profileA, tabID: tabA, anchor: container)
        guard let nativeCommand = fixtureMenuItem(in: commands), let action = nativeCommand.action else { throw Failure(description: "WebKit did not expose the real tab-context command") }
        try check(nativeCommand.isEnabled && NSApp.sendAction(action, to: nativeCommand.target, from: nativeCommand), "Native extension tab command was not dispatched")
        try await wait("Native context-menu action did not reach the real extension background") {
            guard let value = try? await popup.callAsyncJavaScript("const value = await browser.runtime.sendMessage({kind:'popup'}); return value.lastMenu || null;", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] else { return false }
            return value["id"] as? String == "bam-fixture-tab-command" && value["url"] as? String == urlA.absoluteString
        }
        let popupText = await javascript(popup, "document.getElementById('result').textContent") as? String ?? ""
        try check(popupText.contains("profile-A") && !popupText.contains("profile-B"), "Action popup used another profile’s extension storage")
        _ = await javascript(popup, "document.getElementById('open-page').click()")
        try await wait("browser.tabs.create did not open the extension’s own origin") { !extensionPages.isEmpty }
        guard let extensionPage = extensionPages.values.first else { throw Failure(description: "Missing created extension page") }
        try await wait("Created extension page did not execute with its extension configuration") { await javascript(extensionPage, "document.title") as? String == "Bam extension page ready" }
        let ownURL = contextA.baseURL.appendingPathComponent("page.html")
        try check(host.allowsExtensionURL(ownURL, profileID: profileA) && !host.allowsExtensionURL(ownURL, profileID: profileB), "Extension-origin validation crossed a login profile boundary")
        try check(host.configuration(forExtensionURL: contextB.baseURL.appendingPathComponent("page.html"), profileID: profileA) == nil, "Foreign-profile extension configuration was exposed")
        contextA.action(for: nil)?.closePopup()
        try host.revokePermissions(id: extensionA)
        try check(!contextA.hasPermission(.storage) && !contextA.hasAccess(to: urlA), "Revocation did not clear effective permissions")
        let previousA = await javascript(webA, "performance.timeOrigin") as? Double
        webA.reload()
        try await wait("Revoked page did not reload") {
            guard !webA.isLoading, let origin = await javascript(webA, "performance.timeOrigin") as? Double, origin != previousA else { return false }
            return await javascript(webA, "document.body.dataset.bamFixtureToken") as? String == "profile-A"
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(await result(webA) == nil, "Revoked host access still injected on a fresh page")
        try await host.setEnabled(false, id: extensionB)
        try check(!contextB.isLoaded && host.context(for: extensionB) == nil, "Disable left the extension context loaded")
        let previousB = await javascript(webB, "performance.timeOrigin") as? Double
        webB.reload()
        try await wait("Disabled page did not reload") {
            guard !webB.isLoading, let origin = await javascript(webB, "performance.timeOrigin") as? Double, origin != previousB else { return false }
            return await javascript(webB, "document.body.dataset.bamFixtureToken") as? String == "profile-B"
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(await result(webB) == nil, "Disabled extension still injected on a fresh page")
        for web in extensionPages.values { web.stopLoading(); web.removeFromSuperview() }; extensionPages.removeAll(); host.reconcile()
        try await host.remove(id: extensionA)
        try check(host.items(profileID: profileA).isEmpty && !FileManager.default.fileExists(atPath: host.storageURL.appendingPathComponent(extensionA.uuidString).path), "Remove retained its registry/package")
        return checks
    }
}
