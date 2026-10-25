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
                                      "permissions": ["notifications", "idle", "downloads", "fontSettings"]]
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
        // Bitwarden's SDK: a TypeScript `using` site and a class whose dispose key is computed at load.
        try check(js.evaluateScript("""
            (function () {
              if (typeof Symbol.dispose !== 'symbol' || typeof Symbol.asyncDispose !== 'symbol' || Symbol.dispose === Symbol.asyncDispose) return false;
              var released = [];
              class Client { [Symbol.dispose]() { released.push('client'); } }
              function usingHelper(value) { if (!Symbol.dispose) throw new TypeError('Symbol.dispose is not defined.'); var dispose = value[Symbol.dispose]; if (typeof dispose !== 'function') throw new TypeError('Object not disposable.'); dispose.call(value); }
              usingHelper(new Client());
              var descriptor = Object.getOwnPropertyDescriptor(Symbol, 'dispose');
              return released.join() === 'client' && !descriptor.writable && !descriptor.enumerable && !Object.prototype.hasOwnProperty.call(Client.prototype, 'undefined');
            })()
            """)!.toBool(), "Worker adapter did not supply usable explicit-resource-management symbols")
        let nativeSymbols = JSContext()!
        nativeSymbols.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            var nativeDispose = Symbol('engine dispose');
            Object.defineProperty(Symbol, 'dispose', {value: nativeDispose, configurable: true});
            var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}};
            """)
        nativeSymbols.evaluateScript(worker)
        try check(nativeSymbols.evaluateScript("Symbol.dispose === nativeDispose && typeof Symbol.asyncDispose === 'symbol'")!.toBool(), "Worker adapter replaced an engine-provided Symbol.dispose")
        // Two realms of one agent (a parent extension page and its same-origin frame): a resource
        // made in one is disposed in the other, synchronously and asynchronously.
        let agent = JSVirtualMachine()!
        let realms = (0..<2).map { _ in JSContext(virtualMachine: agent)! }
        var realmErrors: [String] = []
        for realm in realms {
            realm.exceptionHandler = { _, error in realmErrors.append(error?.toString() ?? "JavaScript error") }
            realm.evaluateScript("""
                var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/frame.html'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
                var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}};
                """)
            realm.evaluateScript(worker)
        }
        realms[1].evaluateScript("""
            var released = [];
            var makeResource = function () { return {[Symbol.dispose]: function () { released.push('sync'); }, [Symbol.asyncDispose]: function () { released.push('async'); return Promise.resolve(); }}; };
            """)
        realms[0].setObject(realms[1].objectForKeyedSubscript("makeResource"), forKeyedSubscript: "foreignMake" as NSString)
        realms[0].setObject(realms[1].objectForKeyedSubscript("released"), forKeyedSubscript: "foreignReleased" as NSString)
        realms[0].evaluateScript("""
            var crossRealm = 'pending';
            (async function () {
              var resource = foreignMake();
              var dispose = resource[Symbol.dispose], disposeAsync = resource[Symbol.asyncDispose];
              if (typeof dispose !== 'function' || typeof disposeAsync !== 'function') throw new TypeError('Object not disposable.');
              dispose.call(resource); await disposeAsync.call(resource);
              crossRealm = foreignReleased.join();
            })().catch(function (error) { crossRealm = String(error); });
            """)
        try check(realmErrors.isEmpty && realms[0].evaluateScript("crossRealm")!.toString() == "sync,async" &&
                  realms[0].evaluateScript("Symbol.dispose")!.isEqual(to: realms[1].evaluateScript("Symbol.dispose")),
                  "Disposal symbols differed between same-agent realms: \(realms[0].evaluateScript("crossRealm")!) \(realmErrors)")

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

        // storage.managed with Grammarly's exact call shape: callback form inside a 3 s Promise.race whose
        // timer logs unconditionally. Bam's answer must win the race in both forms, through a separate
        // chrome.storage wrapper sharing WebKit's prototype, with no runtime.lastError.
        let managed = JSContext()!
        var managedErrors: [String] = []
        managed.exceptionHandler = { _, error in managedErrors.append(error?.toString() ?? "JavaScript error") }
        managed.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/sw.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            var timers = [], logged = [];
            function setTimeout(fn) { timers.push(fn); return timers.length; }
            function StorageArea() {} StorageArea.prototype.get = function () {};
            function Storage() { this.local = new StorageArea(); }
            var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}, storage: new Storage()};
            var chrome = {runtime: {lastError: undefined}, storage: new Storage()};
            """)
        managed.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["storage"]], browserVersion: "test"))
        managed.evaluateScript("""
            var outcomes = {};
            function grammarlyGet(key) {
              return Promise.race([
                new Promise(function (t) { chrome.storage.managed.get(key, function (n) {
                  if (chrome.runtime.lastError) { t(['error', chrome.runtime.lastError.message]); return; }
                  t(['answered', n[key], Object.keys(n).length]); }); }),
                new Promise(function (t) { setTimeout(function () { logged.push('Manage storage timeout to get "' + key + '"'); t(['timeout']); }, 3000); })
              ]);
            }
            Promise.all(['GrammarlyExtensionMode', 'GrammarlyEnrollmentToken'].map(function (key) { return grammarlyGet(key).then(function (r) { outcomes[key] = r; }); }))
              .then(function () { return chrome.storage.managed.get('GrammarlyExtensionMode'); }).then(function (value) { outcomes.promise = Object.keys(value).length; });
            """)
        try check(managedErrors.isEmpty && managed.evaluateScript("""
            JSON.stringify(outcomes.GrammarlyExtensionMode) === '["answered",null,0]' && JSON.stringify(outcomes.GrammarlyEnrollmentToken) === '["answered",null,0]'
            && outcomes.promise === 0 && timers.length === 2 && logged.length === 0
            """)!.toBool(), "storage.managed did not settle Grammarly's race before its timer: \(managed.evaluateScript("JSON.stringify([outcomes, timers.length])")!) \(managedErrors)")
        // Firing the timers afterwards reproduces Grammarly's log lines although the race was already won.
        managed.evaluateScript("timers.forEach(function (fn) { fn(); });")
        try check(managed.evaluateScript("logged.length === 2 && JSON.stringify(outcomes.GrammarlyExtensionMode) === '[\"answered\",null,0]'")!.toBool(),
                  "Grammarly's unconditional timeout log was not reproduced after a settled race")

        // cookies.onChanged: WebKit fires listeners with no changeInfo; Bam diffs getAll({}) snapshots.
        let cookieJS = JSContext()!
        var cookieErrors: [String] = []
        cookieJS.exceptionHandler = { _, error in cookieErrors.append(error?.toString() ?? "JavaScript error") }
        cookieJS.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            var jar = [], nativeListeners = [], getAllCalls = 0;
            function NativeEvent() {}
            NativeEvent.prototype.addListener = function (fn) { nativeListeners.push(fn); };
            NativeEvent.prototype.removeListener = function (fn) { nativeListeners = nativeListeners.filter(function (x) { return x !== fn; }); };
            var nativeChanged = new NativeEvent();
            function Cookies() {}
            Object.defineProperty(Cookies.prototype, 'onChanged', {get: function () { return nativeChanged; }, configurable: true});
            Cookies.prototype.getAll = function () { getAllCalls++; return Promise.resolve(jar.map(function (c) { return Object.assign({}, c); })); };
            function fire(info) { nativeListeners.slice().forEach(function (fn) { info === undefined ? fn() : fn(info); }); }
            var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}, cookies: new Cookies()};
            var chrome = {runtime: browser.runtime, cookies: new Cookies()};
            var seen = [];
            function cookie(name, value, extra) { return Object.assign({name: name, value: value, domain: '127.0.0.1', path: '/', storeId: '0', secure: false, httpOnly: false, session: true, hostOnly: true, sameSite: 'lax'}, extra || {}); }
            """)
        cookieJS.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["cookies"]], browserVersion: "test"))
        func settle(_ script: String) { cookieJS.evaluateScript("(async function () { \(script); await __bamCompatibility.cookies.settled(); })();") }
        // Grammarly's handler shape destructures the argument.
        cookieJS.evaluateScript("""
            jar = [cookie('kept', '1')];
            var grammarlyWatch = function (n) { var r = n.cookie, i = n.cause; seen.push([n.removed, r.name, r.value, i]); };
            chrome.cookies.onChanged.addListener(grammarlyWatch);
            """)
        settle("")
        try check(cookieJS.evaluateScript("chrome.cookies.onChanged === browser.cookies.onChanged && chrome.cookies.onChanged.hasListener(grammarlyWatch) && nativeListeners.length === 1 && seen.length === 0")!.toBool(),
                  "cookies.onChanged was not one shared event with a single native trigger and a silent baseline")
        settle("jar.push(cookie('session', 'a')); fire()")
        settle("jar[1] = cookie('session', 'b'); fire()")
        settle("jar = jar.filter(function (c) { return c.name !== 'session'; }); fire()")
        settle("jar.push(cookie('old', 'x', {session: false, expirationDate: 1})); fire()")
        settle("jar = jar.filter(function (c) { return c.name !== 'old'; }); fire()")
        try check(cookieErrors.isEmpty && cookieJS.evaluateScript("""
            JSON.stringify(seen) === JSON.stringify([[false,'session','a','explicit'], [true,'session','a','overwrite'], [false,'session','b','explicit'],
              [true,'session','b','explicit'], [false,'old','x','explicit'], [true,'old','x','expired']])
            """)!.toBool(), "Diffed changeInfo did not follow Chrome's add/overwrite/remove/expire shape: \(cookieJS.evaluateScript("JSON.stringify(seen)")!) \(cookieErrors)")
        // Two native fires before a diff runs report the change once. (Engine-provided changeInfo has its own race test below.)
        settle("seen = []; jar.push(cookie('burst', '1')); fire(); fire()")
        try check(cookieJS.evaluateScript("JSON.stringify(seen) === JSON.stringify([[false,'burst','1','explicit']])")!.toBool(),
                  "Coalesced changes were duplicated or lost: \(cookieJS.evaluateScript("JSON.stringify(seen)")!)")
        // A throwing listener does not stop others; removing the last listener detaches the native trigger.
        settle("seen = []; globalThis.thrower = function () { throw new Error('vendor'); }; chrome.cookies.onChanged.addListener(thrower); jar.push(cookie('after', '1')); fire()")
        cookieJS.evaluateScript("chrome.cookies.onChanged.removeListener(thrower); chrome.cookies.onChanged.removeListener(grammarlyWatch);")
        try check(cookieErrors.isEmpty && cookieJS.evaluateScript("seen.length === 1 && seen[0][1] === 'after' && nativeListeners.length === 0 && !chrome.cookies.onChanged.hasListeners()")!.toBool(),
                  "Listener isolation or native detach failed: \(cookieJS.evaluateScript("JSON.stringify([seen, nativeListeners.length])")!)")
        // Races with reads held open: a read captures the jar when issued and resolves only when released.
        func heldCookieContext() -> (JSContext, () -> [String]) {
            let js = JSContext()!
            var errors: [String] = []
            js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
            js.evaluateScript("""
                var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
                var jar = [], nativeListeners = [], held = [], seen = [];
                function NativeEvent() {}
                NativeEvent.prototype.addListener = function (fn) { nativeListeners.push(fn); };
                NativeEvent.prototype.removeListener = function (fn) { nativeListeners = nativeListeners.filter(function (x) { return x !== fn; }); };
                var nativeChanged = new NativeEvent();
                function Cookies() {}
                Object.defineProperty(Cookies.prototype, 'onChanged', {get: function () { return nativeChanged; }, configurable: true});
                Cookies.prototype.getAll = function () { var copy = jar.map(function (c) { return Object.assign({}, c); }); return new Promise(function (resolve) { held.push(function () { resolve(copy); }); }); };
                function fire(info) { nativeListeners.slice().forEach(function (fn) { info === undefined ? fn() : fn(info); }); }
                function release() { var next = held.shift(); if (next) next(); }
                function cookie(name, value) { return {name: name, value: value, domain: '127.0.0.1', path: '/', storeId: '0'}; }
                var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}, cookies: new Cookies()};
                var watch = function (n) { seen.push([n.removed, n.cookie.name, n.cause]); };
                """)
            js.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["cookies"]], browserVersion: "test"))
            return (js, { errors })
        }
        // Engine changeInfo arriving while the baseline read is pending is delivered once; the stale
        // baseline never produces a second, synthesized copy, and later argument-less fires add nothing.
        let (payloadRace, payloadErrors) = heldCookieContext()
        payloadRace.evaluateScript("browser.cookies.onChanged.addListener(watch); browser.cookies.onChanged.addListener(function (n) { forwarded = n; });")
        payloadRace.evaluateScript("var forwarded, payload = {removed: false, cookie: cookie('x', '1'), cause: 'explicit'}; jar.push(cookie('x', '1')); fire(payload); release();")
        payloadRace.evaluateScript("(async function () { await __bamCompatibility.cookies.settled(); fire(); while (held.length) release(); await __bamCompatibility.cookies.settled(); })();")
        try check(payloadErrors().isEmpty && payloadRace.evaluateScript("JSON.stringify(seen) === JSON.stringify([[false,'x','explicit']]) && held.length === 0 && forwarded === payload")!.toBool(),
                  "An engine-provided change during the baseline read was duplicated or lost: \(payloadRace.evaluateScript("JSON.stringify(seen)")!) \(payloadErrors())")
        // Detach and re-attach while the old baseline read is pending: the old read never seeds the new
        // generation, so a cookie added in between is not reported as a change.
        let (generationRace, generationErrors) = heldCookieContext()
        generationRace.evaluateScript("browser.cookies.onChanged.addListener(watch);")   // baseline read issued and held
        generationRace.evaluateScript("browser.cookies.onChanged.removeListener(watch); jar.push(cookie('between', '1')); browser.cookies.onChanged.addListener(watch);")
        // Each evaluateScript drains microtasks, so each step's read issue/resolution is explicit.
        // The old read is still held and the new period issued its own baseline at once (separate chains).
        try check(generationRace.evaluateScript("held.length === 2")!.toBool(), "The new listener period's baseline waited behind the detached period's read")
        generationRace.evaluateScript("release();")   // stale read from the detached period: discarded
        try check(generationRace.evaluateScript("held.length === 1 && seen.length === 0")!.toBool(), "The detached period's read was used or issued more work")
        generationRace.evaluateScript("release();")   // new baseline includes 'between'
        generationRace.evaluateScript("jar.push(cookie('after', '1')); fire();")
        generationRace.evaluateScript("release();")
        try check(generationErrors().isEmpty && generationRace.evaluateScript("JSON.stringify(seen) === JSON.stringify([[false,'after','explicit']])")!.toBool(),
                  "A read from a detached listener period seeded the new baseline: \(generationRace.evaluateScript("JSON.stringify(seen)")!) \(generationErrors())")

        // An old read finishing after the final detach stores nothing and starts no further reads; a
        // listener mutating a delivered cookie does not change the next comparison.
        let (afterDetach, afterDetachErrors) = heldCookieContext()
        afterDetach.evaluateScript("browser.cookies.onChanged.addListener(watch);")
        afterDetach.evaluateScript("browser.cookies.onChanged.removeListener(watch); jar.push(cookie('late', '1')); release(); fire();")
        try check(afterDetachErrors().isEmpty && afterDetach.evaluateScript("held.length === 0 && seen.length === 0 && nativeListeners.length === 0")!.toBool(),
                  "A read completing after detach continued work or delivered events: \(afterDetach.evaluateScript("JSON.stringify([held.length, seen, nativeListeners.length])")!)")
        let (mutation, mutationErrors) = heldCookieContext()
        mutation.evaluateScript("browser.cookies.onChanged.addListener(function (n) { seen.push([n.removed, n.cookie.name, n.cause]); n.cookie.value = 'mutated'; });")
        mutation.evaluateScript("release();")
        mutation.evaluateScript("jar.push(cookie('m', '1')); fire();")
        mutation.evaluateScript("release();")
        mutation.evaluateScript("fire();")
        mutation.evaluateScript("release();")
        try check(mutationErrors().isEmpty && mutation.evaluateScript("JSON.stringify(seen) === JSON.stringify([[false,'m','explicit']])")!.toBool(),
                  "A listener's mutation of a delivered cookie produced a spurious change: \(mutation.evaluateScript("JSON.stringify(seen)")!)")

        let noCookies = JSContext()!
        noCookies.evaluateScript("var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }}; var browser = {runtime: {getURL: function(p) { return 'webkit-extension://fixture' + p; }, getManifest: function() { return {}; }}};")
        noCookies.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        try check(noCookies.evaluateScript("browser.cookies === undefined && __bamCompatibility.cookies === undefined")!.toBool(), "A cookies adapter appeared without a cookies namespace")

        // scripting.ExecutionWorld: the enum WebKit lacks, on the native namespace and its shared
        // prototype (so a distinct chrome.scripting wrapper sees it); never replacing a native enum.
        func executionWorld(_ setup: String) -> JSContext {
            let js = JSContext()!
            js.evaluateScript("""
                var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
                function Scripting() {} Scripting.prototype.executeScript = function () {};
                var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}};
                \(setup)
                """)
            js.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
            return js
        }
        let world = executionWorld("browser.scripting = new Scripting(); var chrome = {scripting: new Scripting(), runtime: browser.runtime};")
        try check(world.evaluateScript("""
            browser.scripting.ExecutionWorld.ISOLATED === 'ISOLATED' && browser.scripting.ExecutionWorld.MAIN === 'MAIN' && Object.isFrozen(browser.scripting.ExecutionWorld)
            && chrome.scripting.ExecutionWorld === browser.scripting.ExecutionWorld && Object.keys(browser.scripting.ExecutionWorld).join() === 'ISOLATED,MAIN'
            """)!.toBool(), "scripting.ExecutionWorld was missing, mutable, or absent from a distinct chrome.scripting wrapper")
        let nativeWorld = executionWorld("var engineWorld = {ISOLATED: 'ISOLATED', MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT'}; browser.scripting = new Scripting(); browser.scripting.ExecutionWorld = engineWorld;")
        try check(nativeWorld.evaluateScript("browser.scripting.ExecutionWorld === engineWorld")!.toBool(), "An engine-provided ExecutionWorld was replaced")
        let noScripting = executionWorld("")
        try check(noScripting.evaluateScript("browser.scripting === undefined")!.toBool(), "A scripting namespace appeared for an extension without one")

        // Idle callbacks: never in the worker adapter; in the page adapter only for its own origin.
        try check(!worker.contains("requestIdleCallback"), "The worker adapter defines idle callbacks, which Chrome workers lack")
        func idlePage(origin: String) -> Bool {
            let page = JSContext()!
            page.evaluateScript("""
                var location = {origin: '\(origin)', href: '\(origin)/page.html'}, console = {error: function() {}};
                var performance = {now: function() { return 0; }}, setTimeout = function() { return 1; }, clearTimeout = function() {};
                var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}};
                """)
            page.evaluateScript(ExtensionCompatibility.script(baseURL: URL(string: "webkit-extension://fixture/")!, bridge: "bridge", plan: ExtensionCompatibility.plan(manifest: [:]), browserVersion: "test"))
            return page.evaluateScript("typeof requestIdleCallback === 'function' && typeof cancelIdleCallback === 'function'")!.toBool()
        }
        try check(idlePage(origin: "webkit-extension://fixture") && !idlePage(origin: "https://example.invalid"),
                  "The page adapter did not define idle callbacks for its extension origin only")

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
        let fonts = ["kind": "request", "method": "fontSettings.getFontList"]
        result = await bridge.receiveNativeMessage(fonts, context: context)
        try check(result.1 != nil, "An ungranted fontSettings list was returned")
        bridge.permissionGranted = { candidate, permission in candidate === context && permission == "fontSettings" }
        result = await bridge.receiveNativeMessage(fonts, context: context)
        let families = result.0 as? [[String: String]] ?? []
        let names = families.compactMap { $0["displayName"] }
        try check(result.1 == nil && families.contains { $0["fontId"] == "Helvetica" } && !families.contains { $0["fontId"]?.hasPrefix(".") == true } &&
                  names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "fontSettings.getFontList did not list installed families sorted by name")
        bridge.permissionGranted = { candidate, permission in candidate === context && permission == "idle" }
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
        try offscreenAdapter(check)
        print("PASS: Extension compatibility (\(checks) checks)")
    }

    /// The worker adapter's offscreen, getContexts and runtime.lastError behavior, against
    /// a fake native side that answers like Bam's bridge (one document, enveloped outcomes).
    @available(macOS 15.4, *)
    static func offscreenAdapter(_ check: (Bool, String) throws -> Void) throws {
        func context(permissions: [String], nativeFails: Bool = false) -> (JSContext, () -> [String]) {
            let manifest: [String: Any] = ["manifest_version": 3, "name": "Original Offscreen Fixture", "version": "1.0", "permissions": permissions]
            let js = JSContext()!
            var errors: [String] = []
            js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
            js.evaluateScript("""
            var console = {error: function() {}}, performance = {now: function() { return 0; }};
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'};
            var requests = [], document = null, nativeFails = \(nativeFails);
            function Runtime() {}
            Object.defineProperty(Runtime.prototype, 'lastError', {get: function() { return undefined; }, configurable: true});
            var browser = {runtime: new Runtime(), storage: {}, action: {}};
            browser.runtime.getURL = function(path) { return 'webkit-extension://fixture' + (path[0] === '/' ? path : '/' + path); };
            browser.runtime.getManifest = function() { return \(String(data: try! JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!); };
            browser.runtime.sendNativeMessage = function(app, body) {
              if (body.kind !== 'request') return Promise.resolve(true);
              requests.push(body.method);
              if (nativeFails) return Promise.reject(new Error('This compatibility capability is not available to the extension.'));
              var params = body.params || {};
              switch (body.method) {
                case 'offscreen.createDocument':
                  if (document) return Promise.resolve({error: 'Only a single offscreen document may be created.'});
                  document = 'webkit-extension://fixture/' + params.url; return Promise.resolve({value: null});
                case 'offscreen.closeDocument':
                  if (!document) return Promise.resolve({error: 'No current offscreen document.'});
                  document = null; return Promise.resolve({value: null});
                case 'offscreen.hasDocument': return Promise.resolve({value: !!document});
                case 'fontSettings.getFontList': return Promise.resolve([{fontId: 'Fixture Sans', displayName: 'Fixture Sans', extra: 1}]);
                case 'offscreen.contexts': return Promise.resolve({value: document ? [{contextType: 'OFFSCREEN_DOCUMENT', contextId: 'c1', documentId: 'c1', documentUrl: document,
                  documentOrigin: 'webkit-extension://fixture', tabId: -1, windowId: -1, frameId: 0, incognito: false}] : []});
              }
              return Promise.reject(new Error('unexpected ' + body.method));
            };
            // Chrome's alias is a distinct object here with its own runtime, as some engines expose it.
            var chrome = {runtime: new Runtime()};
            var results = {};
            """)
            js.evaluateScript(ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: "test"))
            return (js, { errors })
        }
        let (js, errors) = context(permissions: ["offscreen"])
        try check(js.evaluateScript("typeof browser.offscreen.createDocument === 'function' && browser.offscreen.Reason.CLIPBOARD === 'CLIPBOARD' && Object.isFrozen(browser.offscreen.Reason)")!.toBool(),
                  "Offscreen namespace or Reason enum was not defined for a declared permission")
        js.evaluateScript("""
        (async function () {
          await browser.offscreen.createDocument({url: 'offscreen.html', reasons: ['CLIPBOARD'], justification: 'copy'});
          results.has = await browser.offscreen.hasDocument();
          try { await browser.offscreen.createDocument({url: 'offscreen.html', reasons: ['CLIPBOARD'], justification: 'copy'}); results.second = 'resolved'; }
          catch (error) { results.second = error.message; }
          results.matching = (await browser.runtime.getContexts({contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [browser.runtime.getURL('offscreen.html')]})).length;
          results.popups = (await browser.runtime.getContexts({contextTypes: [browser.runtime.ContextType.POPUP]})).length;
          results.all = (await browser.runtime.getContexts({})).map(function (c) { return c.contextType; }).join();
          browser.offscreen.createDocument({url: 'offscreen.html', reasons: ['CLIPBOARD'], justification: 'copy'}, function (value) {
            results.callbackArgs = arguments.length;
            results.callbackError = [browser.runtime.lastError && browser.runtime.lastError.message, chrome.runtime.lastError && chrome.runtime.lastError.message];
            setTimeoutLike();
          });
        })().catch(function (error) { results.failure = String(error); });
        function setTimeoutLike() { Promise.resolve().then(function () { results.afterCallback = [browser.runtime.lastError, chrome.runtime.lastError, Object.getOwnPropertyNames(browser.runtime).indexOf('lastError')]; }); }
        """)
        try check(errors().isEmpty && js.evaluateScript("results.failure === undefined && results.has === true && results.matching === 1 && results.popups === 0 && results.all === 'OFFSCREEN_DOCUMENT'")!.toBool(),
                  "Offscreen create, hasDocument or getContexts filtering failed: \(js.evaluateScript("JSON.stringify(results)")!) \(errors())")
        try check(js.evaluateScript("results.second === 'Only a single offscreen document may be created.'")!.toBool(),
                  "A second createDocument did not reject with Chrome's exact message (Bitwarden compares it)")
        try check(js.evaluateScript("""
            results.callbackArgs === 0 && results.callbackError[0] === 'Only a single offscreen document may be created.' && results.callbackError[1] === results.callbackError[0]
            && results.afterCallback[0] === undefined && results.afterCallback[1] === undefined && results.afterCallback[2] === -1
            """)!.toBool(), "Callback-form failure did not expose and then restore runtime.lastError on both namespaces: \(js.evaluateScript("JSON.stringify(results)")!)")
        js.evaluateScript("""
        (async function () {
          await browser.offscreen.closeDocument();
          results.afterClose = [await browser.offscreen.hasDocument(), (await browser.runtime.getContexts({})).length];
          try { await browser.offscreen.closeDocument(); } catch (error) { results.closeMissing = error.message; }
          try { await browser.offscreen.createDocument({url: 5, reasons: ['CLIPBOARD'], justification: 'x'}); } catch (error) { results.badURL = error instanceof TypeError; }
          try { await browser.offscreen.createDocument({url: 'x.html', reasons: 'CLIPBOARD', justification: 'x'}); } catch (error) { results.badReasons = error instanceof TypeError; }
        })();
        """)
        try check(js.evaluateScript("results.afterClose[0] === false && results.afterClose[1] === 0 && results.closeMissing === 'No current offscreen document.' && results.badURL && results.badReasons")!.toBool(),
                  "closeDocument, its missing-document error or argument validation failed: \(js.evaluateScript("JSON.stringify(results)")!)")
        try check(js.evaluateScript("requests.filter(function (m) { return m === 'offscreen.createDocument'; }).length === 3")!.toBool(),
                  "Invalid createDocument arguments reached the native side")

        // fontSettings: the native list arrives normalized in both call forms; settings calls reject with lastError.
        let (fontsJS, fontErrors) = context(permissions: ["fontSettings"])
        fontsJS.evaluateScript("""
        (async function () {
          results.promised = await browser.fontSettings.getFontList();
          chrome.fontSettings = browser.fontSettings;
          await new Promise(function (resolve) { chrome.fontSettings.getFontList(function (list) { results.callback = list; resolve(); }); });
          await new Promise(function (resolve) { chrome.fontSettings.setFont({genericFamily: 'serif', fontId: 'x'}, function () { results.setError = chrome.runtime.lastError && chrome.runtime.lastError.message; resolve(); }); });
        })();
        """)
        try check(fontErrors().isEmpty && fontsJS.evaluateScript("""
            JSON.stringify(results.promised) === '[{"fontId":"Fixture Sans","displayName":"Fixture Sans"}]' && JSON.stringify(results.callback) === JSON.stringify(results.promised)
            && results.setError === 'fontSettings.setFont is not available in Bam.' && browser.fontSettings.GenericFamily.SERIF === 'serif'
            """)!.toBool(), "fontSettings adapter did not normalize the list or reject settings changes: \(fontsJS.evaluateScript("JSON.stringify(results)")!)")

        // Undeclared: no namespace, and getContexts keeps its earlier empty, request-free answer.
        let (plain, plainErrors) = context(permissions: ["storage"])
        plain.evaluateScript("(async function () { results.contexts = (await browser.runtime.getContexts({})).length; })();")
        try check(plainErrors().isEmpty && plain.evaluateScript("browser.offscreen === undefined && results.contexts === 0 && requests.length === 0")!.toBool(),
                  "An extension without the offscreen permission received the API or a native request")
        // Declared but not granted (an install reviewed before Bam bridged offscreen): getContexts stays empty, create fails.
        let (ungranted, _) = context(permissions: ["offscreen"], nativeFails: true)
        ungranted.evaluateScript("""
        (async function () {
          results.contexts = (await browser.runtime.getContexts({})).length;
          try { await browser.offscreen.createDocument({url: 'x.html', reasons: ['CLIPBOARD'], justification: 'x'}); results.create = 'resolved'; } catch (error) { results.create = 'rejected'; }
        })();
        """)
        try check(ungranted.evaluateScript("results.contexts === 0 && results.create === 'rejected'")!.toBool(), "An ungranted offscreen permission broke getContexts or created a document")
    }
}
