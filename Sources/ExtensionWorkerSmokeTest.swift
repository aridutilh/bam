import AppKit
import Network
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
                "background": background, "permissions": ["storage", "idle", "notifications", "offscreen", "fontSettings", "cookies"], "host_permissions": ["http://127.0.0.1/*", "http://localhost/*", "https://127.0.0.1/*"],
                "action": ["default_popup": "popup.html"], "content_scripts": [["matches": ["http://127.0.0.1/*", "http://localhost/*"], "js": ["content.js"], "run_at": "document_end"]]]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
            let dependency = "globalThis.fixtureOrder = [globalThis.__bamCompatibility?.worker === true ? 'adapter' : 'missing-adapter', 'dependency'];\n"
            let importLine = module ? "import './dependency.js';\nglobalThis.fixtureOriginalURL = import.meta.url;\n" : "importScripts('dependency.js');\nglobalThis.fixtureOriginalURL = 'classic';\n"
            let worker = importLine + #"""
            globalThis.fixtureOrder.push('original');
            const api = globalThis.browser || globalThis.chrome;
            // Registered unconditionally at start, as Proton Pass does; a missing event would stop the worker.
            chrome.runtime.onUpdateAvailable.addListener(() => {});
            // cookies.onChanged as Chrome extensions use it: the listener reads changeInfo fields.
            const cookieEvents = [];
            chrome.cookies.onChanged.addListener(info => cookieEvents.push({type: typeof info, removed: info?.removed, name: info?.cookie?.name, cause: info?.cause}));
            // Diagnostics only (never delivered to the fixture's listener): raw firings of WebKit's own event.
            const nativeCookieFires = [];
            globalThis.__bamCompatibility?.cookies?.rawAddListener?.((...args) => nativeCookieFires.push(args.length));
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
              if (message?.kind === 'last-error') {
                return new Promise(resolve => chrome.fontSettings.setFont({genericFamily: 'serif', fontId: 'Fixture'}, () => resolve({lastError: chrome.runtime.lastError ? String(chrome.runtime.lastError.message) : null})));
              }
              if (message?.kind === 'cookie-diagnostics') {
                const describe = async details => { try { const list = await chrome.cookies.getAll(details); return {count: list.length, hasFixture: list.some(c => c.name === 'bam-fixture-cookie')}; } catch (error) { return 'error: ' + String(error?.message || error); } };
                const proto = Object.getPrototypeOf(chrome.cookies), descriptor = proto && Object.getOwnPropertyDescriptor(proto, 'onChanged');
                return {events: cookieEvents.slice(), nativeFires: nativeCookieFires.slice(), adapterInstalled: !!globalThis.__bamCompatibility?.cookies,
                  intercepting: !!globalThis.__bamCompatibility?.cookies?.intercepting, listenerIsBam: chrome.cookies.onChanged.addListener === browser.cookies.onChanged.addListener && chrome.cookies.onChanged.hasListeners?.() === true,
                  sameEvent: chrome.cookies.onChanged === browser.cookies.onChanged, sameNamespace: chrome.cookies === browser.cookies,
                  marker: !!chrome.cookies.__bamChangeInfo, prototypeIsObject: proto === Object.prototype,
                  prototypeDescriptor: descriptor ? {configurable: descriptor.configurable, hasValue: 'value' in descriptor, hasGetter: typeof descriptor.get === 'function'} : null,
                  ownDescriptor: !!Object.getOwnPropertyDescriptor(chrome.cookies, 'onChanged'),
                  getAllEmpty: await describe({}), getAllURL: await describe({url: 'http://127.0.0.1/'}), getAllDomain: await describe({domain: '127.0.0.1'})};
              }
              if (!message || !['probe','denials','revoked','offscreen','offscreen-close','offscreen-stall','offscreen-after-close'].includes(message.kind)) return undefined;
              if (message.kind === 'offscreen-stall') {
                // The page's script runs, then its load stalls on a loopback request that never answers.
                globalThis.pendingOffscreen = api.offscreen.createDocument({url: 'offscreen.html?stall=' + message.port, reasons: ['DOM_PARSER'], justification: 'Bam fixture'})
                  .then(() => 'resolved', error => error.message);
                let echo = null;
                for (let attempt = 0; attempt < 100 && !echo; attempt++) {
                  try { echo = await api.runtime.sendMessage({kind: 'offscreen-echo', value: 'stalled'}); } catch (error) {}
                  if (!echo) await new Promise(resolve => setTimeout(resolve, 50));
                }
                return {echo, has: await api.offscreen.hasDocument()};
              }
              if (message.kind === 'offscreen-after-close') {
                if (message.close) await api.offscreen.closeDocument();
                let echo;
                try { echo = await api.runtime.sendMessage({kind: 'offscreen-echo', value: 'after'}); } catch (error) { echo = 'error: ' + error.message; }
                return {echo: echo === undefined ? 'none' : echo, outcome: await globalThis.pendingOffscreen, has: await api.offscreen.hasDocument()};
              }
              if (message.kind === 'offscreen') {
                const parameters = {url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'Bam fixture'};
                await api.offscreen.createDocument(parameters);
                const report = {has: await api.offscreen.hasDocument(), echo: await api.runtime.sendMessage({kind: 'offscreen-echo', value: 'ping'})};
                try { await api.offscreen.createDocument(parameters); report.second = 'resolved'; } catch (error) { report.second = error.message; }
                report.contexts = (await api.runtime.getContexts({contextTypes: ['OFFSCREEN_DOCUMENT']})).map(context => context.documentUrl);
                report.expected = api.runtime.getURL('offscreen.html');
                return report;
              }
              if (message.kind === 'offscreen-close') {
                await api.offscreen.closeDocument();
                let missing = '';
                try { await api.offscreen.closeDocument(); } catch (error) { missing = error.message; }
                return {has: await api.offscreen.hasDocument(), missing};
              }
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
                adapterVersion: globalThis.__bamCompatibility?.version || 'missing', idleCallback: typeof requestIdleCallback, cookieEvents: cookieEvents.slice(),
                fonts: await api.fontSettings.getFontList().then(list => list.filter(font => typeof font.fontId === 'string' && typeof font.displayName === 'string').length, error => 'error: ' + error.message),
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
            // The offscreen page answers only its own kind, parsing with a DOM API a worker lacks.
            try Data("""
            const stall = new URL(location.href).searchParams.get('stall');
            // HTTPS, not HTTP: an extension page is a secure context, so a plain-HTTP image is
            // blocked as mixed content and would not hold the load. The silent listener accepts
            // the connection and never answers the TLS handshake, so the image stays pending.
            let stallState = 'none', stallSource = '';
            // A policy block reports itself instead of looking like a network error.
            document.addEventListener('securitypolicyviolation', event => { if (stall) stallState = 'csp:' + event.effectiveDirective + ':' + event.blockedURI; });
            if (stall) {
              const image = new Image(); stallState = 'pending';
              image.onload = () => { stallState = 'loaded'; }; image.onerror = () => { if (!stallState.startsWith('csp:')) stallState = 'error'; };
              image.src = 'https://127.0.0.1:' + stall + '/stall.png'; stallSource = image.src; document.documentElement.append(image);
            }
            (globalThis.browser || globalThis.chrome).runtime.onMessage.addListener(message => {
              if (message?.kind === 'offscreen-fetch-diagnostic') {
                // Diagnostic only: how this page's own request to the stall URL ends.
                const started = performance.now(), controller = new AbortController();
                setTimeout(() => controller.abort(), 2000);
                return fetch(message.url, {signal: controller.signal, cache: 'no-store'})
                  .then(response => ({outcome: 'response ' + response.status, ms: Math.round(performance.now() - started)}),
                        error => ({outcome: String(error && error.name) + ': ' + String(error && error.message), ms: Math.round(performance.now() - started)}));
              }
              if (message?.kind !== 'offscreen-echo') return undefined;
              const parsed = new DOMParser().parseFromString('<p>' + message.value + '</p>', 'text/html').body.textContent;
              return Promise.resolve({echo: parsed, path: location.pathname, visible: document.visibilityState, stall: stallState, readyState: document.readyState,
                                      href: location.href, stallPort: stall || '', stallSource});
            });
            """.utf8).write(to: package.appendingPathComponent("offscreen.js"))
            try Data("<!doctype html><meta charset='utf-8'><title>Offscreen fixture</title><script src='offscreen.js'></script>".utf8).write(to: package.appendingPathComponent("offscreen.html"))
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
        try check(firstA?["idleCallback"] as? String == "undefined" && firstB?["idleCallback"] as? String == "undefined",
                  "A prepared worker gained requestIdleCallback, which Chrome workers lack: classic=\(firstA?["idleCallback"] ?? "nil"), module=\(firstB?["idleCallback"] ?? "nil")")
        try check((firstA?["fonts"] as? Int ?? 0) > 0 && (firstB?["fonts"] as? Int ?? 0) > 0,
                  "fontSettings.getFontList returned no installed families: classic=\(firstA?["fonts"] ?? "nil"), module=\(firstB?["fonts"] ?? "nil")")
        print("Worker Wasm response MIME: classic=\(wasmA["mime"] as? String ?? "missing"), module=\(wasmB["mime"] as? String ?? "missing")")
        guard let popupA = contextA.action(for: nil)?.popupWebView, let popupB = contextB.action(for: nil)?.popupWebView else { throw Failure(description: "Workers have no native action popups") }
        popupA.frame = frame; popupB.frame = frame
        try await wait("Classic worker did not answer its real action popup") { await result(popupA)?["starts"] as? Int == 1 }
        try check((try? await popupA.evaluateJavaScript("typeof Symbol.dispose + ',' + typeof Symbol.asyncDispose")) as? String == "symbol,symbol",
                  "Extension page lacked Symbol.dispose/asyncDispose")
        try await wait("Module worker did not answer its real action popup") { await result(popupB)?["starts"] as? Int == 1 }
        // offscreen: a worker creates a hidden page, messages it, and closes it; profiles stay separate.
        let offscreenReport = await request(popupA, kind: "offscreen")
        let echo = offscreenReport?["echo"] as? [String: Any]
        try check(offscreenReport?["has"] as? Bool == true && echo?["echo"] as? String == "ping" && echo?["path"] as? String == "/offscreen.html",
                  "Worker could not create and message its offscreen document: \(offscreenReport ?? [:])")
        try check(offscreenReport?["second"] as? String == "Only a single offscreen document may be created.",
                  "A second offscreen document was not refused with Chrome's message: \(offscreenReport ?? [:])")
        try check((offscreenReport?["contexts"] as? [String]) == [offscreenReport?["expected"] as? String ?? "missing"],
                  "runtime.getContexts did not report the offscreen document: \(offscreenReport ?? [:])")
        try check(runtimeA.compatibility.offscreen.has(contextA.uniqueIdentifier) && !runtimeB.compatibility.offscreen.has(contextB.uniqueIdentifier) &&
                  runtimeA.compatibility.offscreen.document(for: contextA.uniqueIdentifier)?.window == nil,
                  "The offscreen document crossed profiles or was attached to a window")
        weak var offscreenWeb = runtimeA.compatibility.offscreen.document(for: contextA.uniqueIdentifier)
        let closedReport = await request(popupA, kind: "offscreen-close")
        try check(closedReport?["has"] as? Bool == false && closedReport?["missing"] as? String == "No current offscreen document.",
                  "closeDocument did not close the document or report a missing one: \(closedReport ?? [:])")
        try await wait("A closed offscreen document's web view was retained") { offscreenWeb == nil }
        for cycle in 0..<5 {
            let opened = await request(popupA, kind: "offscreen")?["has"] as? Bool, closed = await request(popupA, kind: "offscreen-close")?["has"] as? Bool
            try check(opened == true && closed == false, "Offscreen create/close cycle \(cycle) failed")
        }
        // A load that never finishes: close and revoke must end it at once, not at the timeout.
        let stallParameters = NWParameters.tcp
        stallParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let stallListener = try NWListener(using: stallParameters)
        var stalledConnections: [NWConnection] = []
        var listenerState = "setup"
        stallListener.stateUpdateHandler = { state in listenerState = "\(state)" }
        stallListener.newConnectionHandler = { connection in stalledConnections.append(connection); connection.start(queue: .main) }
        stallListener.start(queue: .main)
        defer { stallListener.cancel(); for connection in stalledConnections { connection.cancel() } }
        // `port` can report the requested `.any` (0) before the listener is bound; wait for a
        // ready listener with its real port, then prove it accepts a plain loopback connection
        // before any WebKit request is judged against it.
        try await wait("Stalling loopback listener did not become ready with a bound port") {
            listenerState == "ready" && (stallListener.port?.rawValue ?? 0) != 0
        }
        let stallPort = Int(stallListener.port!.rawValue)
        let selfCheck = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(stallPort))!, using: .tcp)
        selfCheck.start(queue: .main)
        try await wait("The silent listener on port \(stallPort) did not accept a direct loopback connection (state \(listenerState))") { !stalledConnections.isEmpty }
        selfCheck.cancel()
        for connection in stalledConnections { connection.cancel() }
        stalledConnections.removeAll()
        print("EXTENSION_STALL_LISTENER port=\(stallPort) state=\(listenerState) directConnection=accepted"); fflush(stdout)
        func stalledOffscreen(_ popup: WKWebView) async -> [String: Any]? {
            try? await popup.callAsyncJavaScript("return await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind: 'offscreen-stall', port});",
                arguments: ["port": stallPort], in: nil, contentWorld: .page) as? [String: Any]
        }
        func afterClose(_ popup: WKWebView, close: Bool) async -> [String: Any]? {
            try? await popup.callAsyncJavaScript("return await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind: 'offscreen-after-close', close});",
                arguments: ["close": close], in: nil, contentWorld: .page) as? [String: Any]
        }
        // The fixture's own grant for the stall URL (https loopback; match patterns ignore the port).
        let stallURL = URL(string: "https://127.0.0.1:\(stallPort)/stall.png")!
        let stallAccess = "contextAccess=\(contextA.hasAccess(to: stallURL))"
        let stalledReport = await stalledOffscreen(popupA)
        let stalledEcho = stalledReport?["echo"] as? [String: Any]
        // The stall must be real before the lifecycle is judged: the page ran, its image request
        // reached the silent listener, and the image is still pending.
        try check(stalledEcho?["echo"] as? String == "stalled" && stalledReport?["has"] as? Bool == true,
                  "The stalled offscreen page did not run or answer: \(stalledReport ?? [:])")
        try check(stalledEcho?["stallSource"] as? String == stallURL.absoluteString,
                  "The offscreen page requested \(stalledEcho?["stallSource"] ?? "nothing") instead of the proven listener URL \(stallURL.absoluteString)")
        do {
            try await wait("The stalled offscreen page's request never reached the silent listener") { !stalledConnections.isEmpty }
        } catch {
            // Describe where the request ended before failing: the page's own fetch of the same URL.
            let fetchProbe = try? await popupA.callAsyncJavaScript("return await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind: 'offscreen-fetch-diagnostic', url});",
                arguments: ["url": stallURL.absoluteString], in: nil, contentWorld: .page)
            throw Failure(description: "The stalled offscreen page's request never reached the proven silent listener on port \(stallPort) (\(stallAccess), listener \(listenerState), connectionsAfterFetch=\(stalledConnections.count)): report=\(stalledReport ?? [:]) fetch=\(String(describing: fetchProbe))")
        }
        try check(stalledEcho?["stall"] as? String == "pending" && stalledEcho?["readyState"] as? String != "complete",
                  "The stalling image did not stay pending (fixture did not stall; port \(stallPort), \(stallAccess)): \(stalledReport ?? [:])")
        try check(runtimeA.compatibility.offscreen.entry(for: contextA.uniqueIdentifier)?.isLoaded == false,
                  "A document whose load is still pending was reported loaded: \(stalledReport ?? [:])")
        weak var stalledWeb = runtimeA.compatibility.offscreen.currentDocument(for: contextA.uniqueIdentifier)
        let closedStall = await afterClose(popupA, close: true)
        try check(closedStall?["outcome"] as? String == "The offscreen document was closed before it finished loading." && closedStall?["has"] as? Bool == false &&
                  (closedStall?["echo"] as? [String: Any])?["echo"] == nil, "Closing a loading document left it answering or its create pending: \(closedStall ?? [:])")
        try await wait("A closed loading offscreen web view was retained") { stalledWeb == nil }
        let recreated = await request(popupA, kind: "offscreen")
        try check(recreated?["has"] as? Bool == true && (recreated?["echo"] as? [String: Any])?["echo"] as? String == "ping" &&
                  (recreated?["echo"] as? [String: Any])?["path"] as? String == "/offscreen.html", "Recreating after a cancelled load failed: \(recreated ?? [:])")
        _ = await request(popupA, kind: "offscreen-close")
        // A is still loading when its grants are revoked; B is loaded when B is disabled.
        // Drop the closed document's silent connections so the new request cannot queue behind them.
        for connection in stalledConnections { connection.cancel() }
        stalledConnections.removeAll()
        let revokeStall = await stalledOffscreen(popupA); _ = await request(popupB, kind: "offscreen")
        try await wait("The revoke-case stall never reached the silent listener: \(revokeStall ?? [:])") { !stalledConnections.isEmpty }
        try check(runtimeA.compatibility.offscreen.entry(for: contextA.uniqueIdentifier)?.isLoaded == false && runtimeB.compatibility.offscreen.has(contextB.uniqueIdentifier),
                  "Offscreen documents were not reopened for the lifecycle checks")
        weak var revokedWeb = runtimeA.compatibility.offscreen.currentDocument(for: contextA.uniqueIdentifier)
        // Measurement only: whether a shimmed callback-form failure exposes runtime.lastError natively
        // (WebKit's runtime.lastError is a native attribute Bam may not be able to shadow).
        let pageLastError = (try? await popupA.callAsyncJavaScript("""
            return await new Promise(resolve => chrome.fontSettings.setFont({genericFamily: 'serif', fontId: 'Fixture'}, () => resolve(chrome.runtime.lastError ? String(chrome.runtime.lastError.message) : null)));
            """, arguments: [:], contentWorld: .page)) ?? nil
        let workerLastError = await request(popupA, kind: "last-error")?["lastError"]
        print("EXTENSION_LASTERROR page=\(String(describing: pageLastError)) worker=\(String(describing: workerLastError))"); fflush(stdout)
        // cookies.onChanged on real WebKit: a loopback cookie set and deleted in profile A's own store
        // reaches A's worker as Chrome-shaped changeInfo; profile B's worker sees nothing.
        let fixtureCookie = HTTPCookie(properties: [.name: "bam-fixture-cookie", .value: "1", .domain: "127.0.0.1", .path: "/"])!
        await configA.websiteDataStore.httpCookieStore.setCookie(fixtureCookie)
        func cookieEvents(_ popup: WKWebView) async -> [[String: Any]] { await request(popup)?["cookieEvents"] as? [[String: Any]] ?? [] }
        func cookieDiagnostics() async -> String {
            let value = await request(popupA, kind: "cookie-diagnostics") ?? [:]
            return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
        }
        do {
            try await wait("Setting a cookie did not reach the worker's cookies.onChanged as changeInfo") {
                await cookieEvents(popupA).contains { $0["name"] as? String == "bam-fixture-cookie" && $0["removed"] as? Bool == false && $0["cause"] as? String == "explicit" }
            }
        } catch {
            let storeHas = await configA.websiteDataStore.httpCookieStore.allCookies().contains { $0.name == "bam-fixture-cookie" }
            let diagnostics = await cookieDiagnostics()
            let privateAccess = "contextPrivateAccess=\(contextA.hasAccessToPrivateData) storePersistent=\(configA.websiteDataStore.isPersistent)"
            print("EXTENSION_COOKIE_DIAGNOSTICS storeHasCookie=\(storeHas) \(privateAccess) worker=\(diagnostics)"); fflush(stdout)
            throw Failure(description: "Setting a cookie did not reach the worker's cookies.onChanged as changeInfo (storeHasCookie=\(storeHas), \(privateAccess)): \(diagnostics)")
        }
        await configA.websiteDataStore.httpCookieStore.deleteCookie(fixtureCookie)
        try await wait("Deleting a cookie did not reach the worker's cookies.onChanged as changeInfo") {
            await cookieEvents(popupA).contains { $0["name"] as? String == "bam-fixture-cookie" && $0["removed"] as? Bool == true }
        }
        let eventsA = await cookieEvents(popupA), eventsB = await cookieEvents(popupB)
        try check(eventsA.allSatisfy { $0["type"] as? String == "object" } && !eventsB.contains { $0["name"] as? String == "bam-fixture-cookie" },
                  "cookies.onChanged delivered undefined changeInfo or crossed profiles: A=\(eventsA) B=\(eventsB)")
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
        try check(!runtimeA.compatibility.offscreen.has(contextA.uniqueIdentifier) && runtimeB.compatibility.offscreen.has(contextB.uniqueIdentifier),
                  "Revoking one extension did not close only its offscreen document")
        try await wait("A revoked loading offscreen web view was retained") { revokedWeb == nil }
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
        try check(!runtimeB.compatibility.offscreen.has(contextB.uniqueIdentifier), "Disabling an extension left its offscreen document open")
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

        // Installs prepared by an earlier Bam, classic (A) and module (B): first run the older
        // adapter observably, then relaunch with refresh and require the new adapter to run.
        // Storage (worker starts), grants and vendor bytes must survive; there is no review.
        host.shutdown()
        let registryURL = fixtureRoot.appendingPathComponent("registry", isDirectory: true)
        let older = "0.0.1-older"
        struct Install { let id: UUID; let profile: UUID; let store: WKWebsiteDataStore; let package: URL; let backup: URL; let manifest: [String: Any]; let vendor: Data; let label: String }
        var installs: [Install] = []
        for (id, profile, store, label) in [(idA, profileA, configA.websiteDataStore, "classic"), (idB, profileB, configB.websiteDataStore, "module")] {
            let folder = host.storageURL.appendingPathComponent(id.uuidString, isDirectory: true)
            let package = folder.appendingPathComponent("package", isDirectory: true), backup = folder.appendingPathComponent("original-manifest.json")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
            let source = (manifest[ExtensionServiceWorkerPreparation.markerKey] as? [String: Any])?["source"] as? String ?? "missing"
            try check(try ExtensionServiceWorkerPreparation.refreshAdapter(package: package, originalManifestURL: backup,
                      adapterSource: ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: older)), "Could not age the \(label) worker adapter")
            installs.append(Install(id: id, profile: profile, store: store, package: package, backup: backup, manifest: manifest,
                                    vendor: try Data(contentsOf: package.appendingPathComponent(source)), label: label))
        }
        func relaunch(refreshing: Bool, minimumStarts: Int, expectedVersion: String) async throws -> (BrowserExtensions, [UUID: Int], [UUID: BrowserExtensionRecord]) {
            let relaunched = BrowserExtensions(storageURL: registryURL)
            relaunched.refreshesWorkerAdapters = refreshing
            relaunched.permissionPrompt = { _ in false }
            var starts: [UUID: Int] = [:], records: [UUID: BrowserExtensionRecord] = [:]
            for install in installs {
                let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = install.store
                relaunched.configure(configuration, profileID: install.profile)
                await relaunched.ready(profileID: install.profile)
                guard let context = relaunched.context(for: install.id), let popup = context.action(for: nil)?.popupWebView,
                      let record = relaunched.records.first(where: { $0.id == install.id }) else {
                    throw Failure(description: "The relaunched host did not load the \(install.label) worker: \(relaunched.errors)")
                }
                popup.frame = frame
                var probe: [String: Any]?
                try await wait("The relaunched \(install.label) worker did not answer") { probe = await result(popup); return (probe?["starts"] as? Int ?? 0) >= minimumStarts }
                try check(probe?["adapterVersion"] as? String == expectedVersion,
                          "The \(install.label) worker ran adapter \(probe?["adapterVersion"] ?? "nil"), expected \(expectedVersion) (refresh \(refreshing ? "on" : "off"))")
                starts[install.id] = probe?["starts"] as? Int ?? 0; records[install.id] = record
                context.action(for: nil)?.closePopup()
            }
            return (relaunched, starts, records)
        }
        let (agedHost, agedStarts, agedRecords) = try await relaunch(refreshing: false, minimumStarts: 3, expectedVersion: older)
        agedHost.shutdown()
        let (upgradedHost, upgradedStarts, upgradedRecords) = try await relaunch(refreshing: true, minimumStarts: 4, expectedVersion: BrowserExtensions.browserVersion)
        defer { upgradedHost.shutdown() }
        for install in installs {
            let before = agedRecords[install.id], after = upgradedRecords[install.id]
            try check((upgradedStarts[install.id] ?? 0) > (agedStarts[install.id] ?? 0), "The \(install.label) worker lost its storage across the upgrade")
            try check(after?.permissions == before?.permissions && after?.patterns == before?.patterns && after?.compatibilityGrants == before?.compatibilityGrants &&
                      before?.compatibilityNote?.contains("Updated Bam's service-worker compatibility adapter.") != true &&
                      after?.compatibilityNote?.contains("Updated Bam's service-worker compatibility adapter.") == true,
                      "The \(install.label) upgrade changed grants or was not disclosed")
            let source = (install.manifest[ExtensionServiceWorkerPreparation.markerKey] as? [String: Any])?["source"] as? String ?? "missing"
            try check(try Data(contentsOf: install.package.appendingPathComponent(source)) == install.vendor &&
                      ExtensionServiceWorkerPreparation.prepare(package: install.package, originalManifestURL: install.backup,
                        adapterSource: ExtensionCompatibility.workerScript(manifest: install.manifest, browserVersion: BrowserExtensions.browserVersion)) == nil,
                      "The \(install.label) upgrade changed vendor bytes or left an unverifiable preparation")
        }
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
