import AppKit
import Security
import WebKit

/// Runs an original, resource-only Safari bundle through WebKit's real bundle
/// initializer. Only this generated fixture accepts ad-hoc signing; production
/// importer tests separately reject it. No containing-app executable is created.
@available(macOS 15.4, *)
@MainActor enum SafariExtensionSmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: message) }; checks += 1
        }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw Failure(description: message)
        }
        func result(_ web: WKWebView) async -> String? {
            try? await web.evaluateJavaScript("document.documentElement.dataset.bamSafariResult || ''") as? String
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-safari-runtime-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let appex = app.appendingPathComponent("Contents/PlugIns/Fixture.appex", isDirectory: true)
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let appID = "com.ari.bam.tests.safari." + UUID().uuidString.lowercased()
        let extensionID = appID + ".extension"
        func plist(_ dictionary: [String: Any], at url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
        }
        try plist(["CFBundleIdentifier": appID, "CFBundleName": "Bam Safari fixture", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"], at: app.appendingPathComponent("Contents/Info.plist"))
        try plist(["CFBundleIdentifier": extensionID, "CFBundleName": "Bam Safari fixture", "CFBundleVersion": "1", "CFBundlePackageType": "XPC!",
                   "NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.web-extension"]], at: appex.appendingPathComponent("Contents/Info.plist"))
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Bam Safari fixture", "version": "1.0", "description": "Original fixture for Bam Safari WebExtension runtime tests",
            "permissions": ["storage", "nativeMessaging"], "host_permissions": ["http://127.0.0.1/*", "http://localhost/*"],
            "background": ["service_worker": "background.js"], "action": ["default_popup": "popup.html"],
            // An upstream signed package can forge Bam's informational marker.
            // Its presence must never enable the internal native transport here.
            "_bam_service_worker": ["schemaVersion": 2, "entry": "background.js", "original": "background.js", "adapter": "upstream.js", "source": "background.js"],
            "content_scripts": [["matches": ["http://127.0.0.1/*", "http://localhost/*"], "js": ["content.js"], "run_at": "document_end"]]]
        let manifestURL = resources.appendingPathComponent("manifest.json")
        let manifestBytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestBytes.write(to: manifestURL)
        let background = #"const api = globalThis.browser || globalThis.chrome; const token = 'safari-' + Math.random(); api.runtime.onMessage.addListener(message => message && message.kind === 'safari-probe' ? Promise.resolve({token}) : undefined);"#
        let content = #"(async () => { try { const value = await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind:'safari-probe'}); document.documentElement.dataset.bamSafariResult = value.token; } catch (error) { document.documentElement.dataset.bamSafariError = String(error); } })();"#
        try Data(background.utf8).write(to: resources.appendingPathComponent("background.js"))
        try Data(content.utf8).write(to: resources.appendingPathComponent("content.js"))
        try Data("<!doctype html><meta charset='utf-8'><title>Safari fixture</title><script src='content.js'></script>".utf8).write(to: resources.appendingPathComponent("popup.html"))
        // appExtensionBundle validates its resource seal independently of our
        // inspector, so even a synthetic fixture needs a valid ad-hoc seal.
        func seal() throws {
            for bundle in [appex, app] {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Failure(description: "Cannot seal generated Safari fixture resources") }
            }
        }
        try seal()
        let allowedIDs = Set([appID, extensionID])
        let importer = SafariExtensionImport { url in
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
                throw Failure(description: "Generated Safari fixture signature changed")
            }
            var raw: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                  let info = raw as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String, allowedIDs.contains(identifier),
                  let hash = info[kSecCodeInfoUnique as String] as? Data else { throw Failure(description: "Unexpected Safari fixture signing identity") }
            return SafariExtensionSigningIdentity(identifier: identifier, teamIdentifier: "BAMFIXTURE", codeHash: hash.base64EncodedString(), distribution: .appStore)
        }
        guard let descriptor = try importer.inspect(applicationURL: app, expectedApplicationBundleIdentifier: appID).first else { throw Failure(description: "Generated Safari WebExtension was not discovered") }
        let registry = root.appendingPathComponent("host", isDirectory: true)
        // Explicit disposable storage exercises registry persistence; both web
        // profiles use non-persistent data stores and never use a user's profile.
        let host = BrowserExtensions(storageURL: registry)
        host.safariImporter = importer
        let profile = UUID(), otherProfile = UUID(), tab = UUID(), otherTab = UUID()
        let configuration = WKWebViewConfiguration(), otherConfiguration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent(); otherConfiguration.websiteDataStore = .nonPersistent()
        host.configure(configuration, profileID: profile); host.configure(otherConfiguration, profileID: otherProfile)
        await host.ready(profileID: profile); await host.ready(profileID: otherProfile)
        let frame = NSRect(x: 0, y: 0, width: 500, height: 340)
        let web = WKWebView(frame: frame, configuration: configuration), otherWeb = WKWebView(frame: frame, configuration: otherConfiguration)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; let container = NSView(frame: frame); window.contentView = container
        container.addSubview(web); container.addSubview(otherWeb); otherWeb.isHidden = true; window.orderFront(nil)
        defer { host.shutdown(); web.stopLoading(); otherWeb.stopLoading(); window.orderOut(nil); window.close() }
        host.surfaces = { value in
            if value == profile { return [BrowserExtensionSurface(id: tab, title: "Safari fixture", url: pageURL, webView: web, window: window, isActive: true, isSelected: true)] }
            if value == otherProfile { return [BrowserExtensionSurface(id: otherTab, title: "Other fixture profile", url: pageURL, webView: otherWeb, window: window, isSelected: true)] }
            return []
        }
        var review: BrowserExtensionPermissionReview?
        host.permissionPrompt = { review = $0; return true }; host.reconcile()
        let id = try await host.importSafariBundle(descriptor, profileID: profile)
        guard let context = host.context(for: id) else { throw Failure(description: "Safari bundle did not load: \(host.errors)") }
        try check(review?.compatibilityNote?.contains("without modifying") == true && review?.unsupported.contains("nativeMessaging") == true,
                  "Safari import omitted its signed-bundle limitations or native-app permission disclosure")
        try check(ExtensionServiceWorkerPreparation.isPrepared(manifest: context.webExtension.manifest),
                  "Safari native-policy fixture did not exercise an upstream-forged Bam marker")
        try check(!context.hasPermission(.nativeMessaging) && context.unsupportedAPIs.contains("browser.runtime.sendNativeMessage") && context.unsupportedAPIs.contains("browser.runtime.connectNative"),
                  "Safari import silently enabled native companion-app access")
        let snapshot = registry.appendingPathComponent(id.uuidString + "/package/Extension.appex/Contents/Resources")
        try check(try Data(contentsOf: snapshot.appendingPathComponent("manifest.json")) == manifestBytes && Data(contentsOf: manifestURL) == manifestBytes &&
                  Data(contentsOf: snapshot.appendingPathComponent("background.js")) == Data(background.utf8), "Safari import modified signed resources")
        web.load(URLRequest(url: pageURL)); otherWeb.load(URLRequest(url: pageURL))
        try await wait("Safari background did not answer its content script") { await result(web)?.hasPrefix("safari-") == true }
        guard let popup = context.action(for: nil)?.popupWebView else { throw Failure(description: "Safari bundle has no action popup") }
        popup.frame = frame
        try await wait("Safari popup did not reach the same background as its page") {
            let pageToken = await result(web), popupToken = await result(popup)
            return pageToken?.hasPrefix("safari-") == true && pageToken == popupToken
        }
        try await wait("Other profile did not finish its fixture page") {
            guard !otherWeb.isLoading else { return false }
            return (try? await otherWeb.evaluateJavaScript("document.readyState")) as? String == "complete"
        }
        try check(await result(otherWeb) == "" && !host.allowsExtensionURL(context.baseURL, profileID: otherProfile), "Safari extension escaped its login profile")
        context.action(for: nil)?.closePopup(); host.shutdown()
        let restored = BrowserExtensions(storageURL: registry); restored.safariImporter = importer
        defer { restored.shutdown() }
        let restoredConfiguration = WKWebViewConfiguration(); restoredConfiguration.websiteDataStore = .nonPersistent()
        restored.configure(restoredConfiguration, profileID: profile); await restored.ready(profileID: profile)
        guard let restoredContext = restored.context(for: id), let restoredPopup = restoredContext.action(for: nil)?.popupWebView else { throw Failure(description: "Safari bundle did not reload from its registry: \(restored.errors)") }
        restoredPopup.frame = frame
        try check(restored.records.first?.safariBundle == descriptor && restoredContext.uniqueIdentifier == context.uniqueIdentifier,
                  "Safari registry reload lost signed provenance or extension identity")
        try await wait("Restored Safari bundle did not execute its background and popup") { await result(restoredPopup)?.hasPrefix("safari-") == true }
        try await restored.setEnabled(false, id: id)
        try Data((String(data: manifestBytes, encoding: .utf8)! + " ").utf8).write(to: manifestURL)
        var tamperRejected = false
        do { try await restored.setEnabled(true, id: id) } catch { tamperRejected = true }
        try check(tamperRejected && restored.context(for: id) == nil, "Tampered installed Safari resources were loaded")
        manifest["version"] = "1.1"
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL); try seal()
        var updateRejected = false
        do { try await restored.setEnabled(true, id: id) } catch { updateRejected = true }
        try check(updateRejected && restored.context(for: id) == nil && restored.records.first?.enabled == false,
                  "A new signed containing-app version silently reused the old Safari snapshot")
        try check(try Data(contentsOf: snapshot.appendingPathComponent("manifest.json")) == manifestBytes, "Refused app changes modified the reviewed private snapshot")
        return checks
    }
}
