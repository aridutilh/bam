import AppKit
import WebKit

/// Measurement only (`--extension-test --extension-verified-id-probe`). Public WebKit API directly (no Bam extension
/// manager): does a context whose `uniqueIdentifier` is a Chrome-shaped ID while its `baseURL` host stays a per-install
/// UUID behave consistently? Records runtime.id (browser/chrome) in an extension page, the worker and a content
/// script; getURL/origin; own and web-accessible resource loads; implicit and explicit-self sendMessage with sender
/// fields; a runtime.connect port round trip; storage isolation between two non-persistent controllers ("profiles")
/// using the same ID; and whether storage follows the ID or the base URL when a context is reloaded under a new UUID
/// host, with a UUID-ID control. Original task-owned package, loopback page only, bounded awaits, released and
/// removed state. Prints EXTENSION_VERIFIED_ID_PROBE and MEASUREMENT; never a suite PASS line.
/// Phase 1 scope: non-persistent controllers and website stores in ONE process. It says nothing about durable or
/// relaunch persistence (a later phase with owned persistent stores across processes).
@available(macOS 15.4, *)
@MainActor enum ExtensionVerifiedIDProbe {
    /// Chrome-shaped (32 letters a–p), clearly synthetic; never a real publisher's ID.
    static let probeID = "abcdefghijklmnopabcdefghijklmnop"
    static let budget: TimeInterval = 70
    struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Once { var done = false }
    final class Released {
        var items: [(String, () -> Bool)] = []
        func track(_ name: String, _ object: AnyObject) { weak var weakObject = object; items.append((name, { weakObject == nil })) }
        var pending: [String] { items.filter { !$0.1() }.map(\.0) }
    }

    static func bounded<T>(_ seconds: Double, by deadline: TimeInterval, _ phase: String, _ work: @escaping @MainActor () async -> T?) async throws -> T? {
        let limit = min(seconds, deadline - ProcessInfo.processInfo.systemUptime)
        guard limit > 0 else { throw Failure(description: "\(phase): measurement deadline reached") }
        let result: (Bool, T?) = await withCheckedContinuation { continuation in
            let once = Once()
            Task { @MainActor in let value = await work(); if !once.done { once.done = true; continuation.resume(returning: (true, value)) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                MainActor.assumeIsolated { if !once.done { once.done = true; continuation.resume(returning: (false, nil)) } }
            }
        }
        guard result.0 else { throw Failure(description: "\(phase) did not finish within \(Int(limit)) s") }
        return result.1
    }

    static func run(pageURL: URL) async -> (complete: Bool, summary: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-verified-id-probe-" + UUID().uuidString, isDirectory: true)
        let released = Released()
        var record: [String: Any] = [:], failure: String?, stage = "files"
        await measure(root: root, pageURL: pageURL, released: released, record: &record, failure: &failure, stage: &stage)
        let releaseDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !released.pending.isEmpty && ProcessInfo.processInfo.systemUptime < releaseDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        let pending = released.pending
        if pending.isEmpty { try? fm.removeItem(at: root) }
        let removed = !fm.fileExists(atPath: root.path)
        // Complete needs every record and a valid transport for every storage call. A semantic negative (for example
        // an absent value) is still a valid measurement; a script or transport error is not.
        let storageKeys = ["storageA", "storageBBefore", "storageBWrite", "storageAAfterB", "reloadSameID", "reloadUUIDControl"]
        let required = ["pageA", "contentA", "pageB"] + storageKeys
        let missing = required.filter { record[$0] == nil }
        let invalidTransport = storageKeys.filter { ((record[$0] as? [String: Any])?["ok"] as? Bool) != true }
        let complete = failure == nil && missing.isEmpty && invalidTransport.isEmpty && pending.isEmpty && removed
        var summary = record
        summary["stage"] = stage; summary["failure"] = failure ?? NSNull(); summary["missing"] = missing; summary["invalidStorageTransport"] = invalidTransport
        summary["notReleased"] = pending; summary["folderRemoved"] = removed; summary["preservedFolder"] = removed ? NSNull() : root.path as Any
        summary["probeID"] = probeID
        summary["scope"] = "phase1: non-persistent controllers and website stores, same process only; no durable/relaunch claim"
        let json = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("EXTENSION_VERIFIED_ID_PROBE \(json)")
        print("MEASUREMENT \(complete ? "complete" : "incomplete")\(failure.map { ": stopped at \(stage): \($0)" } ?? "")\(missing.isEmpty ? "" : " missing \(missing)")\(invalidTransport.isEmpty ? "" : " invalid storage transport \(invalidTransport)")\(pending.isEmpty && removed ? "" : " (cleanup not confirmed: \(pending); folder \(removed ? "removed" : "kept at \(root.path)"))")")
        fflush(stdout)
        return (complete, json)
    }

    private static func measure(root: URL, pageURL: URL, released: Released, record: inout [String: Any], failure: inout String?, stage: inout String) async {
        var controllers: [WKWebExtensionController] = [], contexts: [(WKWebExtensionController, WKWebExtensionContext)] = [], views: [WKWebView] = []
        // Each "profile" owns an explicit non-persistent website store; nothing falls back to WKWebsiteDataStore.default().
        var stores: [ObjectIdentifier: WKWebsiteDataStore] = [:]
        defer {
            for view in views { view.stopLoading() }
            views.removeAll()
            for (controller, context) in contexts where context.isLoaded { try? controller.unload(context) }
            contexts.removeAll(); controllers.removeAll(); stores.removeAll()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        do {
            let package = root.appendingPathComponent("package", isDirectory: true)
            try writePackage(package, pageURL: pageURL)
            stage = "controllers"
            func controller(_ name: String) -> WKWebExtensionController {
                let store = WKWebsiteDataStore.nonPersistent()
                let configuration = WKWebExtensionController.Configuration.nonPersistent()
                configuration.defaultWebsiteDataStore = store
                configuration.webViewConfiguration.websiteDataStore = store
                let made = WKWebExtensionController(configuration: configuration)
                controllers.append(made); stores[ObjectIdentifier(made)] = store
                released.track(name, made); released.track("\(name) website store", store)
                return made
            }
            func store(of controller: WKWebExtensionController) throws -> WKWebsiteDataStore {
                guard let store = stores[ObjectIdentifier(controller)] else { throw Failure(description: "no owned website store for a controller") }
                return store
            }
            func load(_ controller: WKWebExtensionController, id: String, host: UUID, name: String) async throws -> WKWebExtensionContext {
                guard let ext = try await bounded(10, by: deadline, "\(name) package", { try? await WKWebExtension(resourceBaseURL: package) }) else {
                    throw Failure(description: "\(name): the package could not be read")
                }
                let context = WKWebExtensionContext(for: ext)
                context.uniqueIdentifier = id
                context.baseURL = URL(string: "webkit-extension://\(host.uuidString.lowercased())/")!
                context.grantedPermissions = [.storage: .distantFuture]
                if let pattern = try? WKWebExtension.MatchPattern(string: "http://127.0.0.1/*") { context.grantedPermissionMatchPatterns = [pattern: .distantFuture] }
                try controller.load(context)
                contexts.append((controller, context)); released.track("\(name) context", context)
                _ = try await bounded(10, by: deadline, "\(name) worker start") { await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in context.loadBackgroundContent { _ in done.resume(returning: true) } } }
                return context
            }
            func page(_ context: WKWebExtensionContext, name: String) async throws -> (WKWebView, [String: Any]) {
                guard let configuration = context.webViewConfiguration, let controller = context.webExtensionController else { throw Failure(description: "\(name): no extension page configuration") }
                configuration.websiteDataStore = try store(of: controller)
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
                views.append(view); released.track("\(name) page", view)
                view.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
                return (view, try await poll(view, key: "bamIdentity", name: name, deadline: deadline))
            }
            /// {ok: true, value} (value "(absent)" when unset, plus wrote when a write happened) or {ok: false, error}.
            /// Script errors and transport errors are kept distinct from a legitimate absent value.
            func storage(_ view: WKWebView, set value: String?, name: String) async throws -> [String: Any] {
                let write = value.map { "await api.storage.local.set({probe: \(ExtensionCompatibilityBridge.json($0))}); wrote = true;" } ?? ""
                let script = """
                    const api = globalThis.browser || globalThis.chrome; let wrote = false;
                    try { \(write) const got = await api.storage.local.get('probe');
                          return {ok: true, wrote, value: got.probe === undefined ? '(absent)' : String(got.probe)}; }
                    catch (error) { return {ok: false, stage: 'script', error: String(error && error.message || error)}; }
                    """
                let answer: [String: Any]? = try await bounded(5, by: deadline, "\(name) storage") { [weak view] in
                    guard let view else { return ["ok": false, "stage": "transport", "error": "page released"] }
                    do { return try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? ["ok": false, "stage": "transport", "error": "non-object reply"] }
                    catch { return ["ok": false, "stage": "transport", "error": String(describing: error)] }
                }
                return answer ?? ["ok": false, "stage": "transport", "error": "no reply"]
            }

            let hostA = UUID(), hostB = UUID(), hostA2 = UUID(), hostC = UUID()
            record["hosts"] = ["A": hostA.uuidString.lowercased(), "B": hostB.uuidString.lowercased(), "A2": hostA2.uuidString.lowercased(), "C": hostC.uuidString.lowercased()]
            stage = "profile A"
            let controllerA = controller("controller A")
            let contextA = try await load(controllerA, id: probeID, host: hostA, name: "A")
            let (pageA, reportA) = try await page(contextA, name: "page A")
            record["pageA"] = reportA
            record["storageA"] = try await storage(pageA, set: "A", name: "A")
            stage = "content A"
            let webConfiguration = WKWebViewConfiguration(); webConfiguration.websiteDataStore = try store(of: controllerA); webConfiguration.webExtensionController = controllerA
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: webConfiguration)
            views.append(web); released.track("web page", web)
            web.load(URLRequest(url: pageURL))
            record["contentA"] = try await poll(web, key: "bamIdentityContent", name: "content A", deadline: deadline)

            stage = "profile B"
            let controllerB = controller("controller B")
            let contextB = try await load(controllerB, id: probeID, host: hostB, name: "B")
            let (pageB, reportB) = try await page(contextB, name: "page B")
            record["pageB"] = reportB
            record["storageBBefore"] = try await storage(pageB, set: nil, name: "B before")
            record["storageBWrite"] = try await storage(pageB, set: "B", name: "B set")
            record["storageAAfterB"] = try await storage(pageA, set: nil, name: "A after B")

            stage = "reload"
            // Same ID under a new base URL host in the same controller: does storage follow the ID?
            pageA.stopLoading()
            try controllerA.unload(contextA)
            let contextA2 = try await load(controllerA, id: probeID, host: hostA2, name: "A2")
            let (pageA2, _) = try await page(contextA2, name: "page A2")
            record["reloadSameID"] = try await storage(pageA2, set: nil, name: "A2")
            try controllerA.unload(contextA2)
            // Control: a UUID ID (Bam's current scheme) in the same controller.
            let contextC = try await load(controllerA, id: hostC.uuidString.lowercased(), host: hostC, name: "C")
            let (pageC, reportC) = try await page(contextC, name: "page C")
            record["pageC"] = reportC
            record["reloadUUIDControl"] = try await storage(pageC, set: nil, name: "C")
            stage = "measured"
        } catch {
            failure = String(describing: error)
        }
    }

    private static func poll(_ view: WKWebView, key: String, name: String, deadline: TimeInterval) async throws -> [String: Any] {
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 15)
        while ProcessInfo.processInfo.systemUptime < until {
            let text: String? = try await bounded(2, by: until, "\(name) report") { [weak view] in
                try? await view?.evaluateJavaScript("document.documentElement.dataset.\(key) || ''") as? String
            }
            if let text, !text.isEmpty, let data = text.data(using: .utf8), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return report }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw Failure(description: "\(name) did not report")
    }

    private static func writePackage(_ package: URL, pageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let host = "\(pageURL.scheme ?? "http")://\(pageURL.host ?? "127.0.0.1")/*"
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Bam verified ID probe", "version": "1.0", "description": "Original measurement fixture",
            "background": ["service_worker": "worker.js"], "permissions": ["storage"], "host_permissions": [host],
            "content_scripts": [["matches": [host], "js": ["content.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["war.txt"], "matches": [host]]]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
        try Data("bam-verified-id-own".utf8).write(to: package.appendingPathComponent("own.txt"))
        try Data("bam-verified-id-war".utf8).write(to: package.appendingPathComponent("war.txt"))
        try Data("""
            const api = globalThis.browser || globalThis.chrome;
            const who = (sender) => ({id: api.runtime.id, browserId: globalThis.browser && globalThis.browser.runtime ? globalThis.browser.runtime.id : null,
              chromeId: globalThis.chrome && globalThis.chrome.runtime ? globalThis.chrome.runtime.id : null, senderId: sender ? sender.id : null, senderUrl: sender && sender.url || null, senderOrigin: sender && sender.origin || null, base: api.runtime.getURL('/')});
            api.runtime.onMessage.addListener((message, sender, reply) => { if (message && message.kind === 'who') { reply(who(sender)); } });
            api.runtime.onConnect.addListener((port) => {
              port.onMessage.addListener((message) => { if (message && message.kind === 'who') port.postMessage(Object.assign(who(port.sender), {name: port.name})); });
            });
            """.utf8).write(to: package.appendingPathComponent("worker.js"))
        try Data("<!doctype html><meta charset='utf-8'><title>id probe</title><script src='page.js'></script>".utf8).write(to: package.appendingPathComponent("page.html"))
        try Data("""
            (async () => {
              const b = globalThis.browser, c = globalThis.chrome, api = b || c, out = {};
              out.browserId = b && b.runtime ? b.runtime.id : null; out.chromeId = c && c.runtime ? c.runtime.id : null;
              out.url = api.runtime.getURL('/own.txt'); out.origin = location.origin;
              try { out.own = await (await fetch(out.url)).text(); } catch (error) { out.own = 'error: ' + error; }
              try { out.message = await api.runtime.sendMessage({kind: 'who'}); } catch (error) { out.message = {error: String(error)}; }
              try { out.selfById = await api.runtime.sendMessage(api.runtime.id, {kind: 'who'}); } catch (error) { out.selfById = {error: String(error)}; }
              out.callbackSelf = await new Promise((resolve) => {
                const timer = setTimeout(() => resolve({timeout: true}), 4000);
                try { (c || b).runtime.sendMessage(api.runtime.id, {kind: 'who'}, (reply) => { clearTimeout(timer); const lastError = (c || b).runtime.lastError; resolve({reply: reply === undefined ? null : reply, lastError: lastError ? String(lastError.message) : null}); }); }
                catch (error) { clearTimeout(timer); resolve({error: String(error)}); }
              });
              const connect = (args, name) => new Promise((resolve) => {
                try {
                  const port = api.runtime.connect(...args), timer = setTimeout(() => resolve({timeout: true}), 4000);
                  port.onMessage.addListener((message) => { clearTimeout(timer); resolve(message); port.disconnect(); });
                  port.postMessage({kind: 'who'});
                } catch (error) { resolve({error: String(error)}); }
              });
              out.portById = await connect([api.runtime.id, {name: 'probe-by-id'}]);
              out.port = await new Promise((resolve) => {
                try {
                  const port = api.runtime.connect({name: 'probe'}), timer = setTimeout(() => resolve({timeout: true}), 4000);
                  port.onMessage.addListener((message) => { clearTimeout(timer); resolve(message); port.disconnect(); });
                  port.postMessage({kind: 'who'});
                } catch (error) { resolve({error: String(error)}); }
              });
              document.documentElement.dataset.bamIdentity = JSON.stringify(out);
            })();
            """.utf8).write(to: package.appendingPathComponent("page.js"))
        try Data("""
            (async () => {
              const api = globalThis.browser || globalThis.chrome, out = {id: api.runtime.id, url: api.runtime.getURL('/war.txt'),
                browserId: globalThis.browser && globalThis.browser.runtime ? globalThis.browser.runtime.id : null,
                chromeId: globalThis.chrome && globalThis.chrome.runtime ? globalThis.chrome.runtime.id : null};
              try { out.message = await api.runtime.sendMessage({kind: 'who'}); } catch (error) { out.message = {error: String(error)}; }
              try { out.war = await (await fetch(out.url)).text(); } catch (error) { out.war = 'error: ' + error; }
              document.documentElement.dataset.bamIdentityContent = JSON.stringify(out);
            })();
            """.utf8).write(to: package.appendingPathComponent("content.js"))
    }
}
