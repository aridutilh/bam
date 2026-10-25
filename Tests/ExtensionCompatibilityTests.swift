import Foundation
import WebKit
import JavaScriptCore

/// Exercises adapter execution and native authorization without windows, pages,
/// extension background processes, network access, or user profiles.
@main @MainActor enum ExtensionCompatibilityTests {
    struct Failure: Error { let message: String }
    static func main() async throws {
        guard #available(macOS 15.4, *) else { print("SKIP: Compatibility requires macOS 15.4"); return }
        try await run()
    }
    @available(macOS 15.4, *)
    static func run() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; checks += 1
        }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Original Compatibility Fixture", "version": "1.0",
                                      "permissions": ["notifications", "idle", "downloads"]]
        let json = String(data: try JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!
        let js = JSContext()!
        var jsErrors: [String] = []
        js.exceptionHandler = { _, error in jsErrors.append(error?.toString() ?? "JavaScript error") }
        js.evaluateScript("""
        var requests = [], subscriptions = [], connections = 0, disconnected = 0, eventReceiver, disconnectReceiver, delivered = [];
        var console = {error: function() {}};
        var performance = {now: function() { return 0; }};
        var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'};
        var browser = { runtime: {
          getURL: function(path) { return 'webkit-extension://fixture' + path; },
          getManifest: function() { return \(json); },
          sendNativeMessage: function(app, body) { requests.push({app: app, body: body}); return Promise.resolve(body.method === 'idle.queryState' ? 'idle' : true); },
          connectNative: function(app) { connections++; return {
            onMessage: {addListener: function(fn) { eventReceiver = fn; }},
            onDisconnect: {addListener: function(fn) { disconnectReceiver = fn; }},
            postMessage: function(message) { subscriptions.push(message); },
            disconnect: function() { disconnected++; }
          }; }
        }, storage: {}, action: {} };
        function StorageWrapper() {}
        var storageReads = 0;
        Object.defineProperty(browser, 'storage', { get: function() { storageReads++; return new StorageWrapper(); } });
        """)
        let worker = ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: "test")
        js.evaluateScript(worker)
        try check(jsErrors.isEmpty, "Worker adapter accessed DOM or another unavailable global: \(jsErrors)")
        try check(js.evaluateScript("browser.__bamCompatibility.worker === true && connections === 0")!.toBool(), "Worker opened an event connection without a listener")
        try check(js.evaluateScript("requests.length === 1 && requests[0].body.kind === 'hello' && requests[0].app === 'com.ari.bam.compatibility'")!.toBool(), "Worker did not use the scoped native transport")
        try check(js.evaluateScript("browser.__bamCompatibility.held.storage instanceof StorageWrapper && browser.storage.managed === browser.__bamCompatibility.held.storage.managed")!.toBool(), "Managed storage was lost when WebKit recreated its namespace wrapper")
        js.evaluateScript("var managedBefore = browser.storage.managed; var policyListener = function() {}; managedBefore.onChanged.addListener(policyListener);")
        try check(js.evaluateScript("browser.storage.managed === managedBefore && browser.storage.managed.onChanged.hasListener(policyListener) && StorageWrapper.prototype.managed === managedBefore && storageReads > 3")!.toBool(), "Managed storage events were recreated across fresh wrappers")
        js.evaluateScript("var click = function(id) { delivered.push(id); }; browser.notifications.onClicked.addListener(click); browser.idle.onStateChanged.addListener(function(state) { delivered.push(state); });")
        try check(js.evaluateScript("connections === 1 && subscriptions.length === 2")!.toBool(), "Supported event listeners did not share a native subscription")
        js.evaluateScript("eventReceiver({event:'notifications.onClicked', args:['notice']}); eventReceiver({event:'idle.onStateChanged', args:['idle']});")
        try check(js.evaluateScript("JSON.stringify(delivered) === '[\"notice\",\"idle\"]'")!.toBool(), "Native events did not reach registered extension listeners")
        js.evaluateScript("browser.notifications.onClicked.removeListener(click);")
        try check(js.evaluateScript("subscriptions[2].kind === 'unsubscribe' && disconnected === 0")!.toBool(), "Removing one listener disconnected other subscriptions")
        js.evaluateScript(worker)
        try check(jsErrors.isEmpty && js.evaluateScript("requests.length === 1")!.toBool(), "Worker adapter was not idempotent")

        // Model WebKit's native receiver check without replacing any API semantics.
        let binding = JSContext()!
        var bindingErrors: [String] = []
        binding.exceptionHandler = { _, error in bindingErrors.append(error?.toString() ?? "Binding error") }
        binding.evaluateScript("""
        var location = {origin: 'webkit-extension://fixture'}, calls = [], callbackValues = [];
        var details = {path: {16:'original.png'}, tabId:undefined}, nativeError = new Error('native validation');
        var nativePromise = Promise.resolve('native result');
        function namespace(name) {
          const holder = {name, getTitle: function(){return name;}};
          holder.setIcon = function(value, callback) {
            if (this !== holder) return undefined;
            if (value === null) throw nativeError;
            calls.push({holder:this,value,callback});
            if (callback) {callback('native callback'); return 'native return';}
            return nativePromise;
          };
          return holder;
        }
        var browser = {action:namespace('browser.action'), browserAction:namespace('browser.browserAction')};
        var chrome = {action:namespace('chrome.action'), browserAction:namespace('chrome.browserAction')};
        var originalTitle = browser.action.getTitle, originalAction = browser.action, originalChrome = chrome.action;
        """)
        let iconBinding = ExtensionCompatibility.documentActionIconBinding(baseURL: URL(string: "webkit-extension://fixture/")!)
        binding.evaluateScript(iconBinding)
        try check(bindingErrors.isEmpty, "Native action binding failed to install: \(bindingErrors)")
        try check(binding.evaluateScript("var fn=chrome.action.setIcon; fn(details, value => callbackValues.push(value)) === 'native return' && callbackValues[0] === 'native callback' && calls[0].value === details && calls[0].holder === originalChrome")!.toBool(), "Detached Chrome action changed native arguments, callback, receiver or return value")
        try check(binding.evaluateScript("var promiseFn=browser.action.setIcon; promiseFn(details) === nativePromise && browser.action === originalAction && browser.action.getTitle === originalTitle")!.toBool(), "Document binding changed native Promise identity, namespace or unrelated methods")
        try check(binding.evaluateScript("var caught; try {promiseFn(null);} catch(error) {caught=error;} caught === nativeError")!.toBool(), "Document binding replaced native validation errors")
        try check(binding.evaluateScript("var aliasFn=chrome.browserAction.setIcon; aliasFn(details) === nativePromise && calls[calls.length-1].holder === chrome.browserAction")!.toBool(), "Legacy browserAction detached call retained the wrong receiver")
        binding.evaluateScript("var installed=chrome.action.setIcon;")
        binding.evaluateScript(iconBinding)
        try check(bindingErrors.isEmpty && binding.evaluateScript("installed === chrome.action.setIcon && __bamNativeActionIconBindings.length === 4")!.toBool(), "Native action binding stacked wrappers or lost retained namespaces")
        try check(!worker.contains("__bamNativeActionIconBindings"), "Document-only action binding changed the prepared worker adapter")
        let foreignWorld = JSContext()!
        foreignWorld.evaluateScript("var location={origin:'https://example.invalid'}, original=function(){}, browser={action:{setIcon:original}};")
        foreignWorld.evaluateScript(iconBinding)
        try check(foreignWorld.evaluateScript("browser.action.setIcon === original && typeof __bamNativeActionIconBindings === 'undefined'")!.toBool(), "Action binding ran outside its exact extension origin")

        // Required namespaces are distinct from optional declarations.
        let optional = ExtensionCompatibility.plan(manifest: ["optional_permissions": ["notifications", "idle"]])
        try check(!optional.provided.contains("notifications") && !optional.provided.contains("idle"), "Optional capabilities were silently exposed")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-compatibility-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        context.baseURL = URL(string: "webkit-extension://native-fixture/")!
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let dataStore = WKWebsiteDataStore.nonPersistent(), contentController = WKUserContentController()
        configuration.defaultWebsiteDataStore = dataStore
        let controller = WKWebExtensionController(configuration: configuration)
        let bridge = ExtensionCompatibilityBridge(controller: controller, dataStore: dataStore, contentController: contentController, browserVersion: "test")
        defer { bridge.shutdown(); try? controller.unload(context) }
        bridge.install(ExtensionCompatibility.plan(manifest: manifest), for: context)
        try controller.load(context)
        bridge.idleSeconds = { 120 }
        let query: [String: Any] = ["kind": "request", "method": "idle.queryState", "params": ["threshold": 60]]
        var result = await bridge.receiveNativeMessage(query, context: context)
        try check(result.1 != nil, "Missing persisted review grant authorized a native capability")
        bridge.permissionGranted = { candidate, permission in candidate === context && permission == "idle" }
        result = await bridge.receiveNativeMessage(query, context: context)
        try check(result.1 == nil && result.0 as? String == "idle", "Authorized native idle query did not use actual inactivity")
        result = await bridge.receiveNativeMessage(["kind": "request", "method": "notifications.create"], context: context)
        try check(result.1 != nil, "A different declared but ungranted namespace bypassed review")
        result = await bridge.receiveNativeMessage(["kind": "request", "method": "arbitrary.execute"], context: context)
        try check(result.1 != nil, "Unknown native method was accepted")
        let foreign = WKWebExtensionContext(for: ext)
        result = await bridge.receiveNativeMessage(query, context: foreign)
        try check(result.1 != nil, "Unregistered context borrowed another extension's transport")
        var notificationsAllowed = true, checkedAfterAwait = false
        bridge.permissionGranted = { _, permission in permission == "notifications" && notificationsAllowed }
        bridge.postNotification = { _, _, _, _, isAuthorized in
            await Task.yield()
            notificationsAllowed = false; checkedAfterAwait = true
            return isAuthorized() ? nil : "Review permission was revoked."
        }
        result = await bridge.receiveNativeMessage(["kind": "request", "method": "notifications.create", "params": ["id": "original-test-notification"]], context: context)
        try check(checkedAfterAwait && result.1 != nil, "Notification authorization did not recheck live grants after suspension")
        bridge.permissionGranted = { _, _ in false }
        result = await bridge.receiveNativeMessage(query, context: context)
        try check(result.1 != nil, "Permission revocation did not immediately close capability access")
        bridge.permissionGranted = { _, _ in true }
        bridge.remove(context)
        result = await bridge.receiveNativeMessage(query, context: context)
        try check(result.1 != nil, "Removed context retained native capability access")
        print("PASS: Extension compatibility (\(checks) checks)")
    }
}
