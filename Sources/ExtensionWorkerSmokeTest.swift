import AppKit
import WebKit

/// Runs original classic and module fixtures as real WebKit service workers.
/// Disposable profiles, loopback pages and fake native capability responses only.
@available(macOS 15.4, *)
@MainActor enum ExtensionWorkerSmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run(pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure(description: message) }; checks += 1 }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw Failure(description: message)
        }
        func result(_ web: WKWebView) async -> [String: Any]? {
            guard let text = try? await web.evaluateJavaScript("document.documentElement.dataset.bamWorkerResult || ''") as? String,
                  let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func request(_ popup: WKWebView, kind: String = "probe") async -> [String: Any]? {
            try? await popup.callAsyncJavaScript("return await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind});",
                arguments: ["kind": kind], in: nil, contentWorld: .page) as? [String: Any]
        }
        let fm = FileManager.default
        let fixtureRoot = fm.temporaryDirectory.appendingPathComponent("bam-worker-fixtures-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixtureRoot) }
        func fixture(_ module: Bool) throws -> URL {
            let package = fixtureRoot.appendingPathComponent(module ? "module" : "classic", isDirectory: true)
            try fm.createDirectory(at: package.appendingPathComponent("worker"), withIntermediateDirectories: true)
            var background: [String: Any] = ["service_worker": "worker/original.js"]
            if module { background["type"] = "module" }
            let manifest: [String: Any] = ["manifest_version": 3, "name": module ? "Bam module worker fixture" : "Bam classic worker fixture", "version": "1.0", "description": "Original fixture for Bam service-worker runtime tests",
                "content_security_policy": ["extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"],
                "background": background, "permissions": ["storage", "idle", "notifications"], "host_permissions": ["http://127.0.0.1/*", "http://localhost/*"],
                "action": ["default_popup": "popup.html"], "content_scripts": [["matches": ["http://127.0.0.1/*", "http://localhost/*"], "js": ["content.js"], "run_at": "document_end"]]]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
            let dependency = "globalThis.fixtureOrder = [globalThis.__bamCompatibility?.worker === true ? 'adapter' : 'missing-adapter', 'dependency'];\n"
            let importLine = module ? "import './dependency.js';\nglobalThis.fixtureOriginalURL = import.meta.url;\n" : "importScripts('dependency.js');\nglobalThis.fixtureOriginalURL = 'classic';\n"
            let worker = importLine + #"""
            globalThis.fixtureOrder.push('original');
            const api = globalThis.browser || globalThis.chrome;
            // A class whose dispose key is computed at load, as wasm-bindgen and TypeScript `using` emit.
            class FixtureResource { [Symbol.dispose]() { return 'released'; } }
            const disposal = typeof Symbol.dispose === 'symbol' && typeof Symbol.asyncDispose === 'symbol' &&
              new FixtureResource()[Symbol.dispose]() === 'released' ? 'available' : 'missing:' + typeof Symbol.dispose;
            const events = [];
            const wasmResult = (async () => {
              const url = api.runtime.getURL('answer.wasm');
              const response = await fetch(url);
              const mime = response.headers.get('Content-Type') || '';
              const module = await WebAssembly.compileStreaming(response);
              const compiled = await WebAssembly.instantiate(module);
              const streamed = await WebAssembly.instantiateStreaming(fetch(url));
              return {compiled:compiled.exports.answer(), instantiated:streamed.instance.exports.answer(), mime};
            })().catch(error => ({error:String(error)}));
            const started = api.storage.local.get('workerStarts').then(async saved => {
              const count = Number(saved.workerStarts || 0) + 1;
              await api.storage.local.set({workerStarts: count}); return count;
            });
            api.notifications.onClicked.addListener(id => events.push({kind:'notification', value:id}));
            api.idle.onStateChanged.addListener(state => events.push({kind:'idle', value:state}));
            api.idle.setDetectionInterval(15);
            const refusal = async (application, method) => {
              try { await api.runtime.sendNativeMessage(application, {kind:'request', method, params:{id:1,url:'https://fixture.invalid/file'}}); return false; }
              catch (error) { return String(error); }
            };
            api.runtime.onMessage.addListener(async message => {
              if (!message || !['probe','denials','revoked'].includes(message.kind)) return undefined;
              if (message.kind === 'denials') return {
                external: await refusal('com.example.not-bam', 'idle.queryState'),
                undeclared: await refusal('com.ari.bam.compatibility', 'downloads.download'),
                unknown: await refusal('com.ari.bam.compatibility', 'arbitrary.execute')
              };
              if (message.kind === 'revoked') return {
                requestDenied: await refusal('com.ari.bam.compatibility', 'idle.queryState'), events: events.slice()
              };
              return {order:globalThis.fixtureOrder, hasDocument:typeof document !== 'undefined', originalURL:globalThis.fixtureOriginalURL,
                workerURL:location.href, starts:await started, events:events.slice(), wasm:await wasmResult, disposal,
                idle:await api.idle.queryState(15), permission:await api.notifications.getPermissionLevel()};
            });
            """#
            let content = #"""
            (async () => {
              try { document.documentElement.dataset.bamWorkerResult = JSON.stringify(await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind:'probe'})); }
              catch (error) { document.documentElement.dataset.bamWorkerError = String(error); }
            })();
            """#
            // Original minimal Wasm module: one exported () -> i32 function returning 42.
            let wasm: [UInt8] = [0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,7,10,1,6,97,110,115,119,101,114,0,0,10,6,1,4,0,65,42,11]
            try Data(wasm).write(to: package.appendingPathComponent("answer.wasm"))
            try Data(dependency.utf8).write(to: package.appendingPathComponent("worker/dependency.js"))
            try Data(worker.utf8).write(to: package.appendingPathComponent("worker/original.js"))
            try Data(content.utf8).write(to: package.appendingPathComponent("content.js"))
            try Data("<!doctype html><meta charset='utf-8'><title>Worker fixture</title><script src='content.js'></script>".utf8).write(to: package.appendingPathComponent("popup.html"))
            return package
        }
        // A private/nonpersistent extension controller may discard storage when
        // its context unloads. Exercise the persistence promise with fresh UUID
        // controllers and a disposable registry; website sessions remain private.
        let host = BrowserExtensions(storageURL: fixtureRoot.appendingPathComponent("registry", isDirectory: true))
        let profileA = UUID(), profileB = UUID(), tabA = UUID(), tabB = UUID()
        let configA = WKWebViewConfiguration(), configB = WKWebViewConfiguration()
        configA.websiteDataStore = .nonPersistent(); configB.websiteDataStore = .nonPersistent()
        host.configure(configA, profileID: profileA); host.configure(configB, profileID: profileB)
        await host.ready(profileID: profileA); await host.ready(profileID: profileB)
        guard let runtimeA = configA.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let runtimeB = configB.webExtensionController?.delegate as? BrowserExtensionRuntime else { throw Failure(description: "Worker fixture runtimes are missing") }
        var idleA: TimeInterval = 120
        runtimeA.compatibility.idleSeconds = { idleA }; runtimeB.compatibility.idleSeconds = { 0 }
        runtimeA.compatibility.isNotificationDeliveryAvailable = { true }; runtimeB.compatibility.isNotificationDeliveryAvailable = { false }
        let frame = NSRect(x: 0, y: 0, width: 500, height: 340)
        let webA = WKWebView(frame: frame, configuration: configA), webB = WKWebView(frame: frame, configuration: configB)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; let container = NSView(frame: frame); window.contentView = container
        container.addSubview(webA); container.addSubview(webB); webB.isHidden = true; window.orderFront(nil)
        defer { host.shutdown(); webA.stopLoading(); webB.stopLoading(); window.orderOut(nil); window.close() }
        host.surfaces = { profile in
            if profile == profileA { return [BrowserExtensionSurface(id: tabA, title: "Classic worker", url: pageURL, webView: webA, window: window, isActive: true, isSelected: true)] }
            if profile == profileB { return [BrowserExtensionSurface(id: tabB, title: "Module worker", url: pageURL, webView: webB, window: window, isSelected: true)] }
            return []
        }
        func clearPersistentFixtureData() async {
            host.shutdown()
            for runtime in [runtimeA, runtimeB] {
                let types = WKWebExtensionController.allExtensionDataTypes
                let records = await runtime.controller.dataRecords(ofTypes: types)
                await runtime.controller.removeData(ofTypes: types, from: records)
            }
        }
        func exercise() async throws -> Int {
        host.permissionPrompt = { _ in true }; host.reconcile()
        let idA = try await host.importPackage(at: fixture(false), profileID: profileA)
        let idB = try await host.importPackage(at: fixture(true), profileID: profileB)
        guard let contextA = host.context(for: idA), let contextB = host.context(for: idB) else { throw Failure(description: "Worker fixtures failed to load: \(host.errors)") }
        try check(contextA.hasPermission(.nativeMessaging) && contextB.hasPermission(.nativeMessaging) &&
                  contextA.webExtension.manifest["manifest_version"] as? Int == 3 && contextB.webExtension.manifest["manifest_version"] as? Int == 3,
                  "Prepared workers did not receive their explicit internal transport grant")
        webA.load(URLRequest(url: pageURL)); webB.load(URLRequest(url: pageURL))
        try await wait("Classic original worker did not answer its content script") { await result(webA)?["order"] as? [String] == ["adapter", "dependency", "original"] }
        try await wait("Module original worker/dependency did not run after its shim") { await result(webB)?["order"] as? [String] == ["adapter", "dependency", "original"] }
        let firstA = await result(webA), firstB = await result(webB)
        try check(firstA?["hasDocument"] as? Bool == false && firstB?["hasDocument"] as? Bool == false &&
                  (firstA?["workerURL"] as? String)?.hasSuffix("/worker/original.js") == true &&
                  (firstB?["originalURL"] as? String)?.hasSuffix("/worker/original.js") == true,
                  "Worker environment, classic registration URL or original module URL changed")
        try check(firstA?["idle"] as? String == "idle" && firstA?["permission"] as? String == "granted" &&
                  firstB?["idle"] as? String == "active" && firstB?["permission"] as? String == "denied",
                  "Worker native requests did not return their own profile's capability values: A=\(firstA ?? [:]), B=\(firstB ?? [:])")
        let wasmA = firstA?["wasm"] as? [String: Any] ?? [:], wasmB = firstB?["wasm"] as? [String: Any] ?? [:]
        try check(wasmA["compiled"] as? Int == 42 && wasmA["instantiated"] as? Int == 42, "Classic worker packaged Wasm streaming failed: \(wasmA)")
        try check(wasmB["compiled"] as? Int == 42 && wasmB["instantiated"] as? Int == 42, "Module worker packaged Wasm streaming failed: \(wasmB)")
        try check(firstA?["disposal"] as? String == "available" && firstB?["disposal"] as? String == "available",
                  "Worker lacked usable Symbol.dispose/asyncDispose: classic=\(firstA?["disposal"] ?? "nil"), module=\(firstB?["disposal"] ?? "nil")")
        print("Worker Wasm response MIME: classic=\(wasmA["mime"] as? String ?? "missing"), module=\(wasmB["mime"] as? String ?? "missing")")
        guard let popupA = contextA.action(for: nil)?.popupWebView, let popupB = contextB.action(for: nil)?.popupWebView else { throw Failure(description: "Workers have no native action popups") }
        popupA.frame = frame; popupB.frame = frame
        try await wait("Classic worker did not answer its real action popup") { await result(popupA)?["starts"] as? Int == 1 }
        try check((try? await popupA.evaluateJavaScript("typeof Symbol.dispose + ',' + typeof Symbol.asyncDispose")) as? String == "symbol,symbol",
                  "Extension page lacked Symbol.dispose/asyncDispose")
        try await wait("Module worker did not answer its real action popup") { await result(popupB)?["starts"] as? Int == 1 }
        let denied = await request(popupA, kind: "denials")
        try check(denied?["external"] is String && denied?["undeclared"] is String && denied?["unknown"] is String,
                  "Worker native messaging allowed an external app, undeclared capability or unknown method: \(denied ?? [:])")
        let foreign: (Any?, Error?) = await withCheckedContinuation { continuation in
            runtimeB.webExtensionController(runtimeB.controller, sendMessage: ["kind": "request", "method": "idle.queryState"],
                toApplicationWithIdentifier: ExtensionCompatibility.nativeApplicationIdentifier, for: contextA) { continuation.resume(returning: ($0, $1)) }
        }
        try check(foreign.1 != nil, "A native request accepted another profile's context")
        let eventID = "classic-only-" + UUID().uuidString
        try await wait("Native notification event did not cross the worker's event port") {
            runtimeA.compatibility.dispatch("notifications.onClicked", [eventID], to: contextA.uniqueIdentifier)
            return (await request(popupA)?["events"] as? [[String: String]])?.contains { $0["value"] == eventID } == true
        }
        try check((await request(popupB)?["events"] as? [[String: String]])?.contains { $0["value"] == eventID } == false,
                  "Native event delivery crossed login profiles")
        idleA = 0; runtimeA.compatibility.pollIdle()
        try await wait("Inactivity transition did not cross the worker event port") {
            (await request(popupA)?["events"] as? [[String: String]])?.contains { $0["kind"] == "idle" && $0["value"] == "active" } == true
        }
        try host.revokePermissions(id: idA)
        let revokedID = "revoked-" + UUID().uuidString
        runtimeA.compatibility.dispatch("notifications.onClicked", [revokedID], to: contextA.uniqueIdentifier)
        let revokedNative = await runtimeA.compatibility.receiveNativeMessage(["kind": "request", "method": "idle.queryState"], context: contextA)
        let revoked = await request(popupA, kind: "revoked")
        try check(revokedNative.1 != nil && revoked?["requestDenied"] is String &&
                  (revoked?["events"] as? [[String: String]])?.contains { $0["value"] == revokedID } == false,
                  "Revoked worker grants still allowed native requests or event delivery")
        // Unload and recreate both actual worker contexts. WebKit storage belongs
        // to the stable extension identity, while startup executes again.
        try await host.setEnabled(false, id: idA); try await host.setEnabled(false, id: idB)
        try await host.setEnabled(true, id: idA); try await host.setEnabled(true, id: idB)
        guard let reloadedA = host.context(for: idA), let reloadedB = host.context(for: idB),
              let newPopupA = reloadedA.action(for: nil)?.popupWebView, let newPopupB = reloadedB.action(for: nil)?.popupWebView else { throw Failure(description: "Worker reload lost its action context") }
        newPopupA.frame = frame; newPopupB.frame = frame
        var restartedA: [String: Any]?, restartedB: [String: Any]?
        do {
            try await wait("Classic worker failed to restart with stable extension storage") {
                restartedA = await result(newPopupA); return (restartedA?["starts"] as? Int ?? 0) >= 2
            }
            try await wait("Module worker failed to restart with stable extension storage") {
                restartedB = await result(newPopupB); return (restartedB?["starts"] as? Int ?? 0) >= 2
            }
        } catch {
            let pageError = (try? await newPopupA.evaluateJavaScript("document.documentElement.dataset.bamWorkerError || ''")) as? String ?? ""
            throw Failure(description: "\(error); classic=\(restartedA ?? [:]), module=\(restartedB ?? [:]), pageError=\(pageError), hostErrors=\(host.errors)")
        }
        let stale = await runtimeA.compatibility.receiveNativeMessage(["kind": "request", "method": "idle.queryState"], context: contextA)
        try check(stale.1 != nil, "A replaced worker context retained native bridge authority")
        reloadedA.action(for: nil)?.closePopup(); reloadedB.action(for: nil)?.closePopup()
        return checks
        }
        do {
            let count = try await exercise()
            await clearPersistentFixtureData()
            return count
        } catch {
            await clearPersistentFixtureData()
            throw error
        }
    }
}
