import Foundation
import WebKit

/// Capability evidence only: an original HTML background page and a harmless,
/// temporary namespace property. This does not implement or stub any browser API.
@available(macOS 15.4, *)
@MainActor enum ExtensionBridgeCapabilityProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Receiver: NSObject, WKScriptMessageHandler {
        let handlerName: String
        let nonce: String
        let expectedURL: URL
        weak var context: WKWebExtensionContext?
        weak var controller: WKWebExtensionController?
        weak var store: WKWebsiteDataStore?
        weak var contentController: WKUserContentController?
        weak var backgroundView: WKWebView?
        var phases: [String: [String: Any]] = [:]
        var failure: String?
        var loadFinished = false

        init(handlerName: String, nonce: String, expectedURL: URL) {
            self.handlerName = handlerName; self.nonce = nonce; self.expectedURL = expectedURL
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard failure == nil else { return }
            guard let context, let controller, let store, let contentController,
                  context.isLoaded, context.webExtensionController === controller,
                  userContentController === contentController,
                  message.name == handlerName, message.world === WKContentWorld.page,
                  let web = message.webView, message.frameInfo.webView === web,
                  web.configuration.webExtensionController === controller,
                  web.configuration.websiteDataStore === store,
                  web.configuration.userContentController === contentController,
                  message.frameInfo.isMainFrame,
                  message.frameInfo.request.url == expectedURL,
                  message.frameInfo.securityOrigin.protocol == expectedURL.scheme,
                  message.frameInfo.securityOrigin.host == expectedURL.host,
                  message.frameInfo.securityOrigin.port == (expectedURL.port ?? 0),
                  controller.extensionContext(for: expectedURL) === context else {
                failure = "Background bridge message failed native frame/origin/controller/store authentication"
                return
            }
            if let backgroundView, backgroundView !== web {
                failure = "Capability handshake changed its background view"; return
            }
            backgroundView = web
            guard let body = message.body as? [String: Any], body["nonce"] as? String == nonce,
                  let phase = body["phase"] as? String, ["injected", "background"].contains(phase),
                  phases[phase] == nil else {
                failure = "Capability handshake had a wrong nonce, phase, or duplicate message"; return
            }
            if let error = body["error"] as? String {
                failure = "Capability \(phase) script failed: \(error)"; return
            }
            phases[phase] = body
        }
    }

    static func run() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(description: message) }; checks += 1
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let nonce = "bam-capability-" + token
        let handlerName = "bamCapability" + token
        let property = "__bamCapability_" + token
        let marker = "__bamInjected_" + token
        let ran = "__bamBackgroundRan_" + token
        let base = URL(string: "webkit-extension://\(UUID().uuidString.lowercased())/")!
        let backgroundURL = base.appendingPathComponent("background.html")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bam-extension-capability-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = [
            "manifest_version": 2, "name": "Bam original bridge capability fixture", "version": "1.0",
            "description": "Original local fixture checking background user-script ordering and harmless namespace property mutation.",
            "background": ["page": "background.html", "persistent": false]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><meta charset=\"utf-8\"><title>Bam bridge capability</title><script src=\"background.js\"></script>".utf8).write(to: directory.appendingPathComponent("background.html"))
        let backgroundScript = """
        (() => {
          const result = { nonce: '\(nonce)', phase: 'background' };
          try {
            const prior = globalThis['\(marker)'];
            result.injectedBeforeBackground = prior?.nonce === '\(nonce)';
            result.priorMutationSucceeded = prior?.addReadDelete === true;
            result.browserAndChromeStillIdentical = browser === chrome;
            result.nativeRuntimeStillWorks = browser.runtime.getURL('background.html') === location.href;
            result.temporaryPropertyAbsent = !Object.prototype.hasOwnProperty.call(browser, '\(property)');
            globalThis['\(ran)'] = true;
            delete globalThis['\(marker)'];
          } catch (error) { result.error = String(error); }
          window.webkit.messageHandlers['\(handlerName)'].postMessage(result);
        })();
        """
        try Data(backgroundScript.utf8).write(to: directory.appendingPathComponent("background.js"))
        let injectedScript = """
        (() => {
          if (location.href !== '\(backgroundURL.absoluteString)') return;
          const result = { nonce: '\(nonce)', phase: 'injected' };
          try {
            const b = globalThis.browser, c = globalThis.chrome;
            result.namespacePresent = typeof b === 'object' && b !== null && typeof c === 'object' && c !== null;
            result.sameNamespace = b === c;
            result.extensible = Object.isExtensible(b) && Object.isExtensible(c);
            result.beforeBackground = globalThis['\(ran)'] === undefined;
            result.propertyInitiallyAbsent = !Object.prototype.hasOwnProperty.call(b, '\(property)');
            Object.defineProperty(b, '\(property)', { value: '\(nonce)', writable: true, configurable: true, enumerable: false });
            const descriptor = Object.getOwnPropertyDescriptor(c, '\(property)');
            result.addRead = b['\(property)'] === '\(nonce)' && c['\(property)'] === '\(nonce)';
            result.descriptorPreserved = descriptor?.writable === true && descriptor?.configurable === true && descriptor?.enumerable === false;
            result.deleted = delete b['\(property)'];
            result.absentAfterDelete = !Object.prototype.hasOwnProperty.call(b, '\(property)') && !Object.prototype.hasOwnProperty.call(c, '\(property)');
            result.nativeIdentityPreserved = globalThis.browser === b && globalThis.chrome === c && typeof b.runtime.getURL === 'function';
            result.addReadDelete = result.addRead && result.deleted && result.absentAfterDelete;
          } catch (error) { result.error = String(error); }
          globalThis['\(marker)'] = result;
          window.webkit.messageHandlers['\(handlerName)'].postMessage(result);
        })();
        """
        let store = WKWebsiteDataStore.nonPersistent()
        let content = WKUserContentController()
        let receiver = Receiver(handlerName: handlerName, nonce: nonce, expectedURL: backgroundURL)
        receiver.store = store; receiver.contentController = content
        content.add(receiver, contentWorld: .page, name: handlerName)
        content.addUserScript(WKUserScript(source: injectedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        defer {
            content.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
            content.removeAllUserScripts()
        }
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = store; webConfiguration.userContentController = content
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = store; configuration.webViewConfiguration = webConfiguration
        let controller = WKWebExtensionController(configuration: configuration)
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        try check(webExtension.errors.isEmpty, "Capability fixture manifest failed: \(webExtension.errors.map(\.localizedDescription))")
        let context = WKWebExtensionContext(for: webExtension)
        context.baseURL = base; context.uniqueIdentifier = token; context.hasAccessToPrivateData = true
        receiver.context = context; receiver.controller = controller
        try controller.load(context)
        defer { if context.isLoaded { try? controller.unload(context) } }
        try check(!store.isPersistent && !controller.configuration.isPersistent, "Capability fixture unexpectedly used persistent data")
        context.loadBackgroundContent { error in
            Task { @MainActor in
                if let error { receiver.failure = "Capability background failed to load: \(error.localizedDescription)" }
                receiver.loadFinished = true
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while receiver.failure == nil && !(receiver.loadFinished && receiver.phases.count == 2) && ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if let failure = receiver.failure { throw Failure(description: failure) }
        try check(receiver.loadFinished && receiver.phases.count == 2, "Configured document-start script/background handshake timed out; accepted phases: \(receiver.phases.keys.sorted())")
        guard let injected = receiver.phases["injected"], let background = receiver.phases["background"] else {
            throw Failure(description: "Capability probe did not receive both authenticated phases")
        }
        for key in ["namespacePresent", "sameNamespace", "extensible", "beforeBackground", "propertyInitiallyAbsent", "addRead", "descriptorPreserved", "deleted", "absentAfterDelete", "nativeIdentityPreserved", "addReadDelete"] {
            try check(injected[key] as? Bool == true, "Injected background capability failed: \(key)")
        }
        for key in ["injectedBeforeBackground", "priorMutationSucceeded", "browserAndChromeStillIdentical", "nativeRuntimeStillWorks", "temporaryPropertyAbsent"] {
            try check(background[key] as? Bool == true, "Original background observed failed capability: \(key)")
        }
        try check(context.errors.isEmpty, "Capability context reported errors: \(context.errors.map(\.localizedDescription))")
        try controller.unload(context)
        try check(!context.isLoaded, "Capability context remained loaded after cleanup")
        content.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
        content.removeAllUserScripts()
        try FileManager.default.removeItem(at: directory)
        try check(!FileManager.default.fileExists(atPath: directory.path), "Capability fixture directory remained after cleanup")
        return checks
    }
}
