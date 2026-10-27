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
            // WebKit's namespace attributes are native static values: reads always return the native event
            // and a defined property does not replace them (unlike a plain JavaScript object).
            function webkitNamespace(target, event) {
              return new Proxy(target, {
                get(t, key, receiver) { return key === 'onChanged' ? event : Reflect.get(t, key, receiver); },
                defineProperty(t, key, descriptor) { return key === 'onChanged' ? true : Reflect.defineProperty(t, key, descriptor); }
              });
            }
            var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}, cookies: webkitNamespace(new Cookies(), nativeChanged)};
            var chrome = {runtime: browser.runtime, cookies: webkitNamespace(new Cookies(), nativeChanged)};
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
        try check(cookieJS.evaluateScript("__bamCompatibility.cookies.intercepting && chrome.cookies.onChanged === browser.cookies.onChanged && chrome.cookies.onChanged.hasListener(grammarlyWatch) && nativeListeners.length === 1 && seen.length === 0")!.toBool(),
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
                // WebKit's namespace attributes are native static values: reads always return the native event
                // and a defined property does not replace them (unlike a plain JavaScript object).
                function webkitNamespace(target, event) {
                  return new Proxy(target, {
                    get(t, key, receiver) { return key === 'onChanged' ? event : Reflect.get(t, key, receiver); },
                    defineProperty(t, key, descriptor) { return key === 'onChanged' ? true : Reflect.defineProperty(t, key, descriptor); }
                  });
                }
                var browser = {runtime: {getURL: function(path) { return 'webkit-extension://fixture' + path; }, getManifest: function() { return {}; }}, cookies: webkitNamespace(new Cookies(), nativeChanged)};
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

        // Reentrancy: a callback that detaches and re-adds during a two-cookie diff ends that diff, so
        // the re-added listener gets none of the old period's events; a listener removed mid-dispatch
        // is not called.
        let (reentrant, reentrantErrors) = heldCookieContext()
        reentrant.evaluateScript("""
            var bSeen = [], cSeen = [];
            var listenerB = function (n) { bSeen.push(n.cookie.name); };
            var listenerC = function (n) { cSeen.push(n.cookie.name); };
            var listenerA = function (n) {
              seen.push(n.cookie.name);
              browser.cookies.onChanged.removeListener(listenerA); browser.cookies.onChanged.removeListener(listenerC);
              browser.cookies.onChanged.addListener(listenerB);
            };
            browser.cookies.onChanged.addListener(listenerA); browser.cookies.onChanged.addListener(listenerC);
            """)
        reentrant.evaluateScript("release();")
        reentrant.evaluateScript("jar.push(cookie('one', '1')); jar.push(cookie('two', '2')); fire();")
        reentrant.evaluateScript("release();")
        try check(reentrantErrors().isEmpty && reentrant.evaluateScript("seen.length === 1 && bSeen.length === 0 && cSeen.length === 0")!.toBool(),
                  "A reentrant detach/re-add leaked the old diff to the new listener or called a removed one: \(reentrant.evaluateScript("JSON.stringify([seen, bSeen, cSeen])")!)")

        let noCookies = JSContext()!
        noCookies.evaluateScript("var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }}; var browser = {runtime: {getURL: function(p) { return 'webkit-extension://fixture' + p; }, getManifest: function() { return {}; }}};")
        noCookies.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        try check(noCookies.evaluateScript("browser.cookies === undefined && __bamCompatibility.cookies === undefined")!.toBool(), "A cookies adapter appeared without a cookies namespace")

        // runtime.onUpdateAvailable: Proton Pass registers a listener unconditionally at worker start.
        let lifecycle = JSContext()!
        var lifecycleErrors: [String] = []
        lifecycle.exceptionHandler = { _, error in lifecycleErrors.append(error?.toString() ?? "JavaScript error") }
        lifecycle.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/background.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            function Runtime() {} Runtime.prototype.getURL = function (path) { return 'webkit-extension://fixture' + path; }; Runtime.prototype.getManifest = function () { return {version: '1.42.0'}; };
            var browser = {runtime: new Runtime()}, chrome = {runtime: new Runtime()};
            """)
        lifecycle.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        lifecycle.evaluateScript("var onUpdate = function () {}; chrome.runtime.onUpdateAvailable.addListener(onUpdate);")
        try check(lifecycleErrors.isEmpty && lifecycle.evaluateScript("""
            chrome.runtime.onUpdateAvailable === browser.runtime.onUpdateAvailable && chrome.runtime.onUpdateAvailable.hasListener(onUpdate)
            && typeof chrome.runtime.onUpdateAvailable.removeListener === 'function'
            """)!.toBool(), "runtime.onUpdateAvailable was missing or not a shared event: \(lifecycleErrors)")
        let nativeLifecycle = JSContext()!
        nativeLifecycle.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            var engineEvent = {addListener: function () {}};
            var browser = {runtime: {getURL: function (p) { return 'webkit-extension://fixture' + p; }, getManifest: function () { return {}; }, onUpdateAvailable: engineEvent}};
            """)
        nativeLifecycle.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        try check(nativeLifecycle.evaluateScript("browser.runtime.onUpdateAvailable === engineEvent")!.toBool(), "An engine-provided onUpdateAvailable was replaced")

        // windows.onBoundsChanged: native signals only; payloads are WebKit's own getAll windows, diffed in order.
        let bounds = JSContext()!
        var boundsErrors: [String] = []
        bounds.exceptionHandler = { _, error in boundsErrors.append(error?.toString() ?? "JavaScript error") }
        bounds.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, logged = [], console = {error: function (m) { logged.push(String(m)); }}, performance = {now: function() { return 0; }};
            // A read either waits for the test (reads) or takes the next planned answer, in getAll order.
            var reads = [], planned = [], getAllCalls = [], portLog = [];
            function Runtime() {}
            Runtime.prototype.getURL = function (p) { return 'webkit-extension://fixture' + p; }; Runtime.prototype.getManifest = function () { return {}; };
            Runtime.prototype.sendNativeMessage = function () { return Promise.resolve(true); };
            Runtime.prototype.connectNative = function () { return {postMessage: function (m) { portLog.push(m.kind + ':' + m.event); }, onMessage: {addListener: function () {}},
              onDisconnect: {addListener: function () {}}, disconnect: function () { portLog.push('disconnect'); }}; };
            function Windows() {}
            Windows.prototype.getAll = function (query) {
              getAllCalls.push(JSON.stringify(query));
              if (planned.length) { var answer = planned.shift(); return answer.error ? Promise.reject(answer.error) : Promise.resolve(answer.list); }
              return new Promise(function (resolve, reject) { reads.push({resolve: resolve, reject: reject}); });
            };
            var browser = {runtime: new Runtime(), windows: new Windows()}, chrome = {runtime: browser.runtime, windows: browser.windows};
            function win(id, left, width) { return {id: id, left: left, top: 20, width: width, height: 600, focused: false, state: 'normal', type: 'normal'}; }
            function signal() { __bamCompatibility.dispatch('windows.onBoundsChanged', []); }
            function settle(list) { if (reads.length) reads.shift().resolve(list); else planned.push({list: list}); }
            function fail(error) { if (reads.length) reads.shift().reject(error); else planned.push({error: error}); }
            var got = [];
            function first(w) { got.push('first:' + w.id + ':' + w.left + ':' + w.width); w.left = -1; }
            """)
        bounds.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        // Registration at startup (Session Buddy) takes the baseline; a signal during the baseline read waits for it.
        bounds.evaluateScript("""
            var shared = chrome.windows.onBoundsChanged === browser.windows.onBoundsChanged && Windows.prototype.onBoundsChanged === chrome.windows.onBoundsChanged;
            chrome.windows.onBoundsChanged.addListener(first);
            signal();
            """)
        // Microtasks have drained: only the baseline read has started; the signal's read waits behind it.
        bounds.evaluateScript("var baselineCalls = getAllCalls.length, waitedForBaseline = reads.length === 1;")
        bounds.evaluateScript("settle([win(1, 0, 800), win(2, 900, 500)]);")
        bounds.evaluateScript("var afterBaseline = getAllCalls.length; settle([win(1, 40, 800), win(2, 900, 500), win(3, 0, 300)]);")
        try check(boundsErrors.isEmpty && bounds.evaluateScript("""
            shared && baselineCalls === 1 && getAllCalls[0] === '{"populate":false}' && waitedForBaseline && afterBaseline === 2
            && JSON.stringify(got) === '["first:1:40:800"]' && portLog[0] === 'subscribe:windows.onBoundsChanged'
            """)!.toBool(), "Baseline/signal ordering or the first change were wrong: \(bounds.evaluateScript("JSON.stringify([got, getAllCalls, portLog, waitedForBaseline])")!) \(boundsErrors)")
        // Unchanged windows are silent; signals queued back to back report a change once, with the final bounds.
        bounds.evaluateScript("got = []; signal(); settle([win(1, 40, 800), win(2, 900, 500)]);")
        bounds.evaluateScript("signal(); signal(); settle([win(1, 40, 1000), win(2, 900, 500)]);")
        bounds.evaluateScript("settle([win(1, 40, 1000), win(2, 900, 500)]);")
        try check(bounds.evaluateScript("JSON.stringify(got) === '[\"first:1:40:1000\"]' && reads.length === 0 && planned.length === 0")!.toBool(),
                  "Unchanged reads were reported or coalesced signals reported twice: \(bounds.evaluateScript("JSON.stringify(got)")!)")
        // Each listener gets its own copy; a throwing listener does not stop the others.
        bounds.evaluateScript("""
            got = []; var seen = [];
            function thrower(w) { seen.push(w); throw new Error('vendor listener failure'); }
            function second(w) { seen.push(w); got.push('second:' + w.left); }
            chrome.windows.onBoundsChanged.addListener(thrower); chrome.windows.onBoundsChanged.addListener(second);
            signal(); settle([win(1, 70, 1000), win(2, 900, 500)]);
            """)
        try check(bounds.evaluateScript("JSON.stringify(got) === '[\"first:1:70:1000\",\"second:70\"]' && seen[0] !== seen[1] && logged.some(function (m) { return m.indexOf('listener failed') >= 0; })")!.toBool(),
                  "Listener isolation or per-listener copies failed: \(bounds.evaluateScript("JSON.stringify([got, logged])")!)")
        // Removing every listener ends the period: a pending read is discarded and the worker unsubscribes.
        bounds.evaluateScript("got = []; signal();")
        bounds.evaluateScript("""
            var pendingAtDetach = reads.length === 1;
            [first, thrower, second].forEach(function (fn) { chrome.windows.onBoundsChanged.removeListener(fn); });
            settle([win(1, 300, 1000), win(2, 900, 500)]);
            """)
        try check(bounds.evaluateScript("pendingAtDetach && got.length === 0 && planned.length === 0 && !chrome.windows.onBoundsChanged.hasListeners() && portLog.indexOf('unsubscribe:windows.onBoundsChanged') >= 0 && portLog[portLog.length - 1] === 'disconnect'")!.toBool(),
                  "A read pending at detach delivered, or the worker stayed subscribed: \(bounds.evaluateScript("JSON.stringify([got, portLog])")!)")
        // Re-adding takes a fresh baseline (differences from the old period are not reported). A listener that
        // removes itself mid-delivery ends the period: the second changed window is not delivered.
        bounds.evaluateScript("""
            function once(w) { got.push('once:' + w.id); chrome.windows.onBoundsChanged.removeListener(once); }
            chrome.windows.onBoundsChanged.addListener(once);
            settle([win(1, 500, 1000), win(2, 900, 500)]);
            signal(); settle([win(1, 510, 1000), win(2, 910, 500)]);
            """)
        try check(bounds.evaluateScript("JSON.stringify(got) === '[\"once:1\"]' && reads.length === 0 && planned.length === 0")!.toBool(),
                  "Re-baselining or reentrant removal was wrong: \(bounds.evaluateScript("JSON.stringify(got)")!)")
        // A failed baseline read invents nothing: the next read becomes the baseline, later changes report.
        bounds.evaluateScript("""
            got = []; chrome.windows.onBoundsChanged.addListener(first);
            fail(new Error('getAll failed'));
            signal(); settle([win(1, 600, 1000)]);
            signal(); settle([win(1, 620, 1000)]);
            """)
        try check(bounds.evaluateScript("JSON.stringify(got) === '[\"first:1:620:1000\"]' && planned.length === 0 && logged.some(function (m) { return m.indexOf('read failed') >= 0; })")!.toBool() && boundsErrors.isEmpty,
                  "A failed baseline invented or missed a change: \(bounds.evaluateScript("JSON.stringify(got)")!) \(boundsErrors)")
        // Topology refresh (a window opened elsewhere while window 1 is mid-resize): never reports, keeps window 1's
        // committed geometry, adds window 4, drops window 2. The next committed read reports window 1's final bounds
        // and window 4's first real move.
        bounds.evaluateScript("""
            got = [];
            __bamCompatibility.dispatch('windows.onBoundsChanged', ['topology']); settle([win(1, 999, 1234), win(4, 10, 300)]);
            """)
        bounds.evaluateScript("var afterTopology = got.length; var topologyBaseline = JSON.stringify(__bamCompatibility.windowsBounds.baseline);")
        bounds.evaluateScript("signal(); settle([win(1, 640, 1000), win(4, 15, 300)]);")
        try check(bounds.evaluateScript("afterTopology === 0 && topologyBaseline === '[1,4]' && JSON.stringify(got) === '[\"first:1:640:1000\",\"first:4:15:300\"]'")!.toBool(),
                  "A topology refresh reported, overwrote committed geometry, or lost the new window: \(bounds.evaluateScript("JSON.stringify([afterTopology, topologyBaseline, got])")!)")

        // An engine-provided event is kept; without a windows namespace nothing is defined.
        let engineBounds = JSContext()!
        engineBounds.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            var engineEvent = {addListener: function () {}};
            var browser = {runtime: {getURL: function (p) { return 'webkit-extension://fixture' + p; }, getManifest: function () { return {}; }}, windows: {getAll: function () {}, onBoundsChanged: engineEvent}};
            """)
        engineBounds.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        try check(engineBounds.evaluateScript("browser.windows.onBoundsChanged === engineEvent")!.toBool(), "An engine-provided windows.onBoundsChanged was replaced")

        // bookmarks: read-only getTree only, when declared and absent; access is decided natively per call.
        let marks = JSContext()!
        var marksErrors: [String] = []
        marks.exceptionHandler = { _, error in marksErrors.append(error?.toString() ?? "JavaScript error") }
        marks.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, logged = [], console = {error: function (a, b) { logged.push(String(a) + ' ' + String(b && b.message || b)); }}, performance = {now: function() { return 0; }};
            var granted = true, requests = [], tree = [{id: '0', title: '', children: [{id: 'favorites', parentId: '0', index: 0, title: 'Favorites', children: []}]}];
            function Runtime() {}
            Runtime.prototype.getURL = function (p) { return 'webkit-extension://fixture' + p; }; Runtime.prototype.getManifest = function () { return {permissions: ['bookmarks']}; };
            Runtime.prototype.sendNativeMessage = function (app, body) { requests.push(body); return granted ? Promise.resolve(tree) : Promise.reject(new Error('Bam has not been granted bookmarks access for this extension.')); };
            var browser = {runtime: new Runtime()}, chrome = browser;
            """)
        marks.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["bookmarks"]], browserVersion: "test"))
        marks.evaluateScript("""
            var out = {keys: Object.keys(chrome.bookmarks).join(',')};
            chrome.bookmarks.getTree().then(function (value) { out.promise = value === tree; out.request = JSON.stringify(requests.filter(function (r) { return r.kind === 'request'; })[0]); });
            """)
        marks.evaluateScript("""
            granted = false;
            chrome.bookmarks.getTree().then(function () { out.denied = 'resolved'; }, function (error) { out.denied = error.message; });
            try { out.syncReturn = chrome.bookmarks.getTree(function () { out.callbackArgs = arguments.length; }); out.threw = false; } catch (error) { out.threw = true; }
            """)
        try check(marksErrors.isEmpty && marks.evaluateScript("""
            out.keys === 'getTree' && out.promise === true && out.request === '{"kind":"request","method":"bookmarks.getTree","params":null}'
            && out.denied === 'Bam has not been granted bookmarks access for this extension.' && out.threw === false && out.syncReturn === undefined
            && out.callbackArgs === 0 && logged.some(function (line) { return line.indexOf('not been granted') >= 0; })
            """)!.toBool(), "bookmarks.getTree shape, pass-through or denial contract was wrong: \(marks.evaluateScript("JSON.stringify([out, logged])")!) \(marksErrors)")
        let undeclared = JSContext()!
        undeclared.evaluateScript("var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }}; var browser = {runtime: {getURL: function (p) { return p; }, getManifest: function () { return {}; }}};")
        undeclared.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        let engineMarks = JSContext()!
        engineMarks.evaluateScript("var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }}; var engine = {getTree: function () {}}; var browser = {runtime: {getURL: function (p) { return p; }, getManifest: function () { return {}; }}, bookmarks: engine};")
        engineMarks.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["bookmarks"]], browserVersion: "test"))
        try check(undeclared.evaluateScript("browser.bookmarks === undefined")!.toBool() && engineMarks.evaluateScript("browser.bookmarks === engine")!.toBool(),
                  "bookmarks appeared without the declared permission, or replaced an engine namespace")

        // history: search + two genuine events only, when declared and absent; the query is validated before bridging.
        let hist = JSContext()!
        var histErrors: [String] = []
        hist.exceptionHandler = { _, error in histErrors.append(error?.toString() ?? "JavaScript error") }
        hist.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, logged = [], console = {error: function (a, b) { logged.push(String(a) + ' ' + String(b && b.message || b)); }}, performance = {now: function() { return 0; }};
            var granted = true, requests = [], portLog = [], items = [{id: 'x', url: 'https://a.example/', title: 'A', lastVisitTime: 5}];
            function Runtime() {}
            Runtime.prototype.getURL = function (p) { return 'webkit-extension://fixture' + p; }; Runtime.prototype.getManifest = function () { return {permissions: ['history']}; };
            Runtime.prototype.sendNativeMessage = function (app, body) { if (body.kind === 'request') requests.push(body); return body.kind !== 'request' || granted ? Promise.resolve(items) : Promise.reject(new Error('Bam has not been granted history access for this extension.')); };
            Runtime.prototype.connectNative = function () { return {postMessage: function (m) { portLog.push(m.kind + ':' + m.event); }, onMessage: {addListener: function () {}}, onDisconnect: {addListener: function () {}}, disconnect: function () { portLog.push('disconnect'); }}; };
            var browser = {runtime: new Runtime()}, chrome = browser;
            """)
        hist.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["history"]], browserVersion: "test"))
        hist.evaluateScript("""
            var out = {keys: Object.keys(chrome.history).sort().join(','), heard: [], removed: []};
            chrome.history.search({text: 'a', startTime: 0, maxResults: 20000}).then(function (value) { out.passed = value === items; });
            var invalid = [{}, {text: 1}, {text: '', startTime: '0'}, {text: '', endTime: Infinity}, {text: '', maxResults: 1.5}, {text: '', maxResults: -1}, {text: '', maxResults: true}, null, Object.assign([], {text: ''}), {text: '', maxResults: 2147483648}, {text: '', startTime: null}];
            out.rejections = 0;
            invalid.forEach(function (query) { chrome.history.search(query).then(function () {}, function (error) { if (error instanceof TypeError) out.rejections += 1; }); });
            chrome.history.search({}, function () { out.invalidCallbackArgs = arguments.length; });
            var onVisit = function (item) { out.heard.push(item.url); }, onRemove = function (info) { out.removed.push(info); };
            chrome.history.onVisited.addListener(onVisit); chrome.history.onVisitRemoved.addListener(onRemove);
            __bamCompatibility.dispatch('history.onVisited', [items[0]]);
            __bamCompatibility.dispatch('history.onVisitRemoved', [{allHistory: true, urls: []}]);
            """)
        hist.evaluateScript("""
            out.validRequests = requests.length; out.request = JSON.stringify(requests[0]);
            granted = false;
            chrome.history.search({text: ''}).then(function () { out.denied = 'resolved'; }, function (error) { out.denied = error.message; });
            chrome.history.search({text: ''}, function () { out.deniedCallbackArgs = arguments.length; });
            chrome.history.onVisited.removeListener(onVisit); chrome.history.onVisitRemoved.removeListener(onRemove);
            """)
        try check(histErrors.isEmpty && hist.evaluateScript("""
            out.keys === 'onVisitRemoved,onVisited,search' && out.passed && out.rejections === 11 && out.invalidCallbackArgs === 0 && out.validRequests === 1
            && out.request === '{"kind":"request","method":"history.search","params":{"text":"a","startTime":0,"maxResults":20000}}'
            && JSON.stringify(out.heard) === '["https://a.example/"]' && out.removed.length === 1 && out.removed[0].allHistory === true
            && out.denied === 'Bam has not been granted history access for this extension.' && out.deniedCallbackArgs === 0
            && portLog.indexOf('subscribe:history.onVisited') >= 0 && portLog.indexOf('subscribe:history.onVisitRemoved') >= 0 && portLog[portLog.length - 1] === 'disconnect'
            """)!.toBool(), "history shape, validation, pass-through, events or denial contract was wrong: \(hist.evaluateScript("JSON.stringify([out, portLog, logged])")!) \(histErrors)")
        let engineHistory = JSContext()!
        engineHistory.evaluateScript("var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }}; var engine = {search: function () {}}; var browser = {runtime: {getURL: function (p) { return p; }, getManifest: function () { return {}; }}, history: engine};")
        engineHistory.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["history"]], browserVersion: "test"))
        let noHistory = JSContext()!
        noHistory.evaluateScript("var location = {origin: 'webkit-extension://fixture', href: 'x'}, console = {error: function() {}}, performance = {now: function() { return 0; }}; var browser = {runtime: {getURL: function (p) { return p; }, getManifest: function () { return {}; }}};")
        noHistory.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["bookmarks"]], browserVersion: "test"))
        try check(engineHistory.evaluateScript("browser.history === engine")!.toBool() && noHistory.evaluateScript("browser.history === undefined")!.toBool(),
                  "history replaced an engine namespace or appeared without its own declared permission")

        // declarativeNetRequest guard: unsafe added rules are refused before WebKit; valid calls pass through untouched.
        let guardJS = JSContext()!
        var guardErrors: [String] = []
        guardJS.exceptionHandler = { _, error in guardErrors.append(error?.toString() ?? "JavaScript error") }
        guardJS.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, console = {error: function() {}}, performance = {now: function() { return 0; }};
            var nativeCalls = [], nativeResult = Promise.resolve('native');
            function DNR() {}
            ['updateDynamicRules', 'updateSessionRules'].forEach(function (name) {
              DNR.prototype[name] = function () { nativeCalls.push({name: name, receiver: this, args: Array.prototype.slice.call(arguments)});
                var callback = arguments[1]; if (typeof callback === 'function') callback(); return nativeResult; };
            });
            var browser = {runtime: {getURL: function(p) { return 'webkit-extension://fixture' + p; }, getManifest: function() { return {}; }}, declarativeNetRequest: new DNR()};
            var chrome = {runtime: browser.runtime, declarativeNetRequest: new DNR()};
            var allTypes = ['font', 'image', 'main_frame', 'media', 'other', 'ping', 'script', 'stylesheet', 'sub_frame', 'websocket', 'xmlhttprequest'];
            var unsafe = {id: 7, priority: 1, action: {type: 'block'}, condition: {urlFilter: '/x', excludedResourceTypes: allTypes}};
            var safe = {id: 8, priority: 1, action: {type: 'block'}, condition: {urlFilter: '/y', excludedResourceTypes: ['image', 'webtransport']}};
            """)
        guardJS.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["declarativeNetRequest"]], browserVersion: "test"))
        guardJS.evaluateScript("""
            var out = {};
            var validOptions = {addRules: [safe], removeRuleIds: [3]}, validCallback = function () { out.callbackRan = true; };
            out.promiseReturn = browser.declarativeNetRequest.updateDynamicRules(validOptions) === nativeResult;
            chrome.declarativeNetRequest.updateSessionRules(validOptions, validCallback);
            out.validCalls = nativeCalls.length === 2 && nativeCalls[0].receiver === browser.declarativeNetRequest && nativeCalls[0].args.length === 1 && nativeCalls[0].args[0] === validOptions
              && nativeCalls[1].receiver === chrome.declarativeNetRequest && nativeCalls[1].args[1] === validCallback && out.callbackRan === true;
            nativeCalls = [];
            browser.declarativeNetRequest.updateDynamicRules({addRules: [safe, unsafe]}).then(function () { out.promise = 'resolved'; }, function (error) { out.promise = error.message; });
            try { chrome.declarativeNetRequest.updateSessionRules({addRules: [unsafe]}, function () { out.unsafeCallbackRan = true; }); out.callbackForm = 'returned'; }
            catch (error) { out.callbackForm = error.message; }
            out.removeOnly = browser.declarativeNetRequest.updateDynamicRules({removeRuleIds: [7]}) === nativeResult;
            // G2: any non-empty request-method condition is refused, whatever the action; empty lists reach WebKit.
            var methodRule = {id: 9, priority: 1, action: {type: 'allow'}, condition: {urlFilter: '/m', requestMethods: ['get']}};
            var excludedMethodRule = {id: 10, priority: 1, action: {type: 'block'}, condition: {urlFilter: '/n', excludedRequestMethods: ['post']}};
            var callsBeforeMethods = nativeCalls.length;
            browser.declarativeNetRequest.updateSessionRules({addRules: [safe, methodRule]}).then(function () { out.methodPromise = 'resolved'; }, function (error) { out.methodPromise = error.message; });
            try { chrome.declarativeNetRequest.updateDynamicRules({addRules: [excludedMethodRule]}, function () { out.methodCallbackRan = true; }); out.methodCallback = 'returned'; }
            catch (error) { out.methodCallback = error.message; }
            out.methodNativeCalls = nativeCalls.length - callsBeforeMethods;
            out.emptyMethods = browser.declarativeNetRequest.updateDynamicRules({addRules: [{id: 11, priority: 1, action: {type: 'block'}, condition: {urlFilter: '/e', requestMethods: []}}]}) === nativeResult;
            """)
        try check(guardErrors.isEmpty && guardJS.evaluateScript("out.promiseReturn && out.validCalls")!.toBool(),
                  "A valid DNR update did not reach the native method with its receiver, arguments, callback and return value: \(guardJS.evaluateScript("JSON.stringify(out)")!)")
        let refusal = "Rule with id 7 excludes every resource type this browser supports, so it would match all requests here."
        try check(guardJS.evaluateScript("out.promise === '\(refusal)' && out.callbackForm === '\(refusal)' && out.unsafeCallbackRan === undefined && out.removeOnly && nativeCalls.length === 2 && nativeCalls[0].args[0].removeRuleIds[0] === 7")!.toBool(),
                  "An unsafe DNR update reached WebKit or was not refused in promise (reject) and callback (synchronous throw) forms: \(guardJS.evaluateScript("JSON.stringify([out, nativeCalls.length])")!)")
        let methodRefusal = " has a request-method condition (requestMethods or excludedRequestMethods), which this browser does not enforce as written."
        try check(guardJS.evaluateScript("out.methodPromise === 'Rule with id 9\(methodRefusal)' && out.methodCallback === 'Rule with id 10\(methodRefusal)' && out.methodCallbackRan === undefined && out.methodNativeCalls === 0 && out.emptyMethods")!.toBool(),
                  "A method-conditioned DNR update reached WebKit or was not refused in both forms: \(guardJS.evaluateScript("JSON.stringify(out)")!)")
        guardJS.evaluateScript(ExtensionCompatibility.workerScript(manifest: ["permissions": ["declarativeNetRequest"]], browserVersion: "test"))
        try check(guardJS.evaluateScript("browser.declarativeNetRequest.updateDynamicRules.__bamDNRGuard === true && browser.declarativeNetRequest.updateDynamicRules({removeRuleIds: []}) === nativeResult")!.toBool(),
                  "Re-running the adapter wrapped the DNR guard twice")
        // modifyHeaders names WebKit refuses (Todoist's `Doist-Platform`) are left out; everything else passes through.
        guardJS.evaluateScript("""
            nativeCalls = []; var warned = [];
            console.warn = function (text) { warned.push(text); };
            var todoist = {id: 1, priority: 1, condition: {urlFilter: '|https://api.todoist.com/'}, action: {type: 'modifyHeaders',
              requestHeaders: [{header: 'Doist-Platform', operation: 'set', value: 'chrome'}, {header: 'User-Agent', operation: 'set', value: 'x'}]}};
            var onlyCustom = {id: 2, priority: 1, condition: {urlFilter: '/c'}, action: {type: 'modifyHeaders', responseHeaders: [{header: 'X-Custom', operation: 'remove'}]}};
            var mixed = {id: 3, priority: 1, condition: {urlFilter: '/m'}, action: {type: 'modifyHeaders', requestHeaders: [{header: 'X-Only', operation: 'remove'}],
              responseHeaders: [{header: 'Set-Cookie', operation: 'remove'}]}};
            var headerOptions = {addRules: [todoist, onlyCustom, mixed, safe], removeRuleIds: [1]};
            var headerResult = browser.declarativeNetRequest.updateSessionRules(headerOptions);
            var sent = nativeCalls[0] && nativeCalls[0].args[0];
            var headerOK = headerResult === nativeResult && nativeCalls.length === 1 && sent !== headerOptions && sent.removeRuleIds[0] === 1
              && sent.addRules.length === 3 && sent.addRules[0].id === 1 && sent.addRules[0].action.requestHeaders.length === 1
              && sent.addRules[0].action.requestHeaders[0].header === 'User-Agent' && sent.addRules[1].id === 3
              && sent.addRules[1].action.requestHeaders === undefined && sent.addRules[1].action.responseHeaders.length === 1
              && sent.addRules[2] === safe && todoist.action.requestHeaders.length === 2 && warned.length === 1
              && warned[0].indexOf('Doist-Platform') >= 0 && warned[0].indexOf('X-Custom') >= 0;
            var accepted = {id: 4, priority: 1, condition: {urlFilter: '/a'}, action: {type: 'modifyHeaders', requestHeaders: [{header: 'referer', operation: 'remove'}]}};
            var acceptedOptions = {addRules: [accepted]};
            nativeCalls = [];
            browser.declarativeNetRequest.updateDynamicRules(acceptedOptions);
            headerOK = headerOK && nativeCalls[0].args[0] === acceptedOptions && warned.length === 1;
            """)
        try check(guardErrors.isEmpty && guardJS.evaluateScript("headerOK")!.toBool(),
                  "modifyHeaders entries WebKit refuses were not left out exactly: \(guardJS.evaluateScript("JSON.stringify([sent, warned])")!)")

        // Chrome enum constants: supplied only where the namespace exists and the engine has none; never replacing one.
        let enums = JSContext()!
        var enumErrors: [String] = []
        enums.exceptionHandler = { _, error in enumErrors.append(error?.toString() ?? "JavaScript error") }
        enums.evaluateScript("""
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'}, console = {error: function() {}, warn: function() {}}, performance = {now: function() { return 0; }};
            function WR() {} function Tabs() {} function DNR() {}
            var engineStatus = {LOADING: 'loading'};
            var browser = {runtime: {getURL: function(p) { return 'webkit-extension://fixture' + p; }, getManifest: function() { return {}; }}, webRequest: new WR(), tabs: new Tabs(), declarativeNetRequest: new DNR()};
            browser.tabs.TabStatus = engineStatus;
            """)
        enums.evaluateScript(ExtensionCompatibility.workerScript(manifest: [:], browserVersion: "test"))
        try check(enumErrors.isEmpty && enums.evaluateScript("""
            Object.values(browser.webRequest.ResourceType).indexOf('webbundle') < 0 && browser.webRequest.ResourceType.MAIN_FRAME === 'main_frame'
            && Object.isFrozen(browser.webRequest.ResourceType) && browser.tabs.TabStatus === engineStatus && browser.tabs.TAB_ID_NONE === -1
            && browser.runtime.OnInstalledReason.INSTALL === 'install' && browser.runtime.PlatformOs.MAC === 'mac'
            && browser.declarativeNetRequest.RuleActionType.MODIFY_HEADERS === 'modifyHeaders' && browser.declarativeNetRequest.MAX_NUMBER_OF_REGEX_RULES === 1000
            && typeof browser.declarativeNetRequest.getAvailableStaticRuleCount === 'function'
            && browser.windows === undefined && browser.contextMenus === undefined
            """)!.toBool(), "Chrome enum constants were missing, replaced an engine enum, or created a namespace: \(enums.evaluateScript("JSON.stringify([Object.keys(browser), Object.getOwnPropertyNames(browser.webRequest)])")!) \(enumErrors)")
        enums.evaluateScript("browser.declarativeNetRequest.getAvailableStaticRuleCount().then(function (n) { availableCount = n; });")

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
        try revokedWorkerTransport(check)
        try tabsQueryWindowTypes(check)
        print("PASS: Extension compatibility (\(checks) checks)")
    }

    /// tabs.query with Chrome window types Bam never has ('app', 'devtools') answers [] without calling WebKit, which
    /// rejects them (Dark Reader's getActiveTab falls back to 'app'); every other query reaches WebKit's method unchanged.
    @available(macOS 15.4, *)
    static func tabsQueryWindowTypes(_ check: (Bool, String) throws -> Void) throws {
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Original Window Type Fixture", "version": "1.0", "permissions": ["storage"]]
        let js = JSContext()!
        var errors: [String] = []
        js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
        js.evaluateScript("""
        var console = {error: function() {}, warn: function() {}}, performance = {now: function() { return 0; }};
        var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'};
        var nativeCalls = [];
        var browser = {runtime: {
          getURL: function(path) { return 'webkit-extension://fixture' + path; },
          getManifest: function() { return \(String(data: try! JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!); },
          sendNativeMessage: function() { return Promise.resolve(true); }
        }, tabs: {
          query: function(info) {
            nativeCalls.push(JSON.stringify(info));
            if (info && (info.windowType === 'app' || info.windowType === 'devtools')) throw new Error("Invalid call to tabs.query(). The 'windowType' value is invalid");
            return Promise.resolve([{id: 7, windowType: info && info.windowType}]);
          }
        }, storage: {}, action: {}};
        var results = {}; var nativeQuery = browser.tabs.query;
        """)
        js.evaluateScript(ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: "test"))
        js.evaluateScript("""
        browser.tabs.query({active: true, windowType: 'app'}).then(function(tabs) { results.appPromise = JSON.stringify(tabs); }, function(e) { results.appPromise = 'rejected: ' + e.message; });
        results.appCallbackReturn = String(browser.tabs.query({windowType: 'devtools'}, function(tabs) { results.devtoolsCallback = JSON.stringify(tabs); }));
        browser.tabs.query({active: true, windowType: 'normal'}).then(function(tabs) { results.normal = tabs.length + ':' + tabs[0].windowType; });
        results.marked = browser.tabs.query.__bamTabsQueryGuard === true && browser.tabs.query.__bamTabsQueryNative === nativeQuery;
        """)
        try check(errors.isEmpty && js.evaluateScript("results.marked")!.toBool(), "The tabs.query window-type guard was not installed: \(errors)")
        try check(js.evaluateScript("results.appPromise")?.toString() == "[]" && js.evaluateScript("results.devtoolsCallback")?.toString() == "[]"
                  && js.evaluateScript("results.appCallbackReturn")?.toString() == "undefined",
                  "An 'app' or 'devtools' query did not answer an empty list in promise and callback forms")
        try check(js.evaluateScript("results.normal")?.toString() == "1:normal"
                  && js.evaluateScript("JSON.stringify(nativeCalls)")?.toString() == "[\"{\\\"active\\\":true,\\\"windowType\\\":\\\"normal\\\"}\"]",
                  "Other queries did not reach WebKit's method exactly once, unchanged: \(js.evaluateScript("JSON.stringify(nativeCalls)")?.toString() ?? "")")

        // A page document re-applies the adapter on a timer for 60 s (5 ms at first). With and without the tabs metadata
        // facade, tabs.query must be wrapped exactly once and stay the same function across hundreds of ticks; an
        // absent window type answers [] with no native call and exactly one callback; nothing repopulates that [].
        for permissions in [["tabs", "storage"], ["storage"]] {
            let pageManifest: [String: Any] = ["manifest_version": 3, "name": "Original Window Type Page", "version": "1.0", "permissions": permissions]
            let page = JSContext()!
            var pageErrors: [String] = []
            page.exceptionHandler = { _, error in pageErrors.append(error?.toString() ?? "JavaScript error") }
            page.evaluateScript("""
            var console = {error: function() {}, warn: function() {}, log: function() {}};
            var clock = 0, timers = [], nextTimer = 0;
            var performance = {now: function() { return clock; }};
            function setTimeout(fn, ms) { var id = ++nextTimer; timers.push({fn: fn, at: clock + (ms || 0), id: id}); return id; }
            function clearTimeout(id) { timers = timers.filter(function(t) { return t.id !== id; }); }
            function advance(ms) { clock += ms; var due = timers.filter(function(t) { return t.at <= clock; }); timers = timers.filter(function(t) { return t.at > clock; }); due.forEach(function(t) { t.fn(); }); }
            var queueMicrotask = function(fn) { Promise.resolve().then(fn); };
            var document = {readyState: 'loading', addEventListener: function() {}};
            var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/ui/page.html'};
            var nativeCalls = 0, callbacks = 0;
            var browser = {runtime: {
              getURL: function(path) { return 'webkit-extension://fixture' + path; },
              getManifest: function() { return \(String(data: try! JSONSerialization.data(withJSONObject: pageManifest), encoding: .utf8)!); }
            }, tabs: {
              query: function(info, cb) {
                nativeCalls += 1;
                if (info && (info.windowType === 'app' || info.windowType === 'devtools')) throw new Error("Invalid call to tabs.query(). The 'windowType' value is invalid");
                var tabs = [{id: 1, windowId: 10, index: 0, url: '', title: ''}];
                if (cb) { cb(tabs); return undefined; } return Promise.resolve(tabs);
              },
              get: function() { return Promise.resolve(null); }, getCurrent: function() { return Promise.resolve(null); },
              create: function() { return Promise.resolve(null); }, update: function() { return Promise.resolve(null); },
              onCreated: {addListener: function() {}, removeListener: function() {}, hasListener: function() { return false; }},
              onUpdated: {addListener: function() {}, removeListener: function() {}, hasListener: function() { return false; }}
            }, windows: {get: function() { return Promise.resolve(null); }, getAll: function() { return Promise.resolve([]); },
              getCurrent: function() { return Promise.resolve(null); }, getLastFocused: function() { return Promise.resolve(null); }, create: function() { return Promise.resolve(null); }},
            storage: {}, action: {}};
            var chrome = browser;
            var nativeQuery = browser.tabs.query;
            var webkit = {messageHandlers: {}};
            """)
            page.evaluateScript(ExtensionCompatibility.script(baseURL: URL(string: "webkit-extension://fixture/")!, bridge: "bridge",
                                                              plan: ExtensionCompatibility.plan(manifest: pageManifest), browserVersion: "test"))
            page.evaluateScript("advance(1); var afterFirst = browser.tabs.query; for (var i = 0; i < 400; i++) advance(5); advance(70000);")
            let metadata = permissions.contains("tabs")
            let layering = metadata
                ? "browser.tabs.query.__bamTabMetadataNative === nativeQuery && !browser.tabs.query.__bamTabsQueryGuard"
                : "browser.tabs.query.__bamTabsQueryGuard === true && browser.tabs.query.__bamTabsQueryNative === nativeQuery"
            try check(pageErrors.isEmpty && page.evaluateScript("browser.tabs.query === afterFirst && " + layering)!.toBool(),
                      "tabs.query was rewrapped over repeated adapter ticks (tabs=\(metadata)): \(pageErrors)")
            page.evaluateScript("""
            nativeCalls = 0; callbacks = 0; var appResult = null, normalCount = null;
            browser.tabs.query({active: true, windowType: 'app'}).then(function(v) { appResult = JSON.stringify(v); });
            browser.tabs.query({windowType: 'devtools'}, function(v) { callbacks += 1; appResult = appResult + '|' + JSON.stringify(v); });
            """)
            page.evaluateScript("advance(3000);")
            try check(page.evaluateScript("nativeCalls === 0 && callbacks === 1 && appResult === '[]|[]'")!.toBool(),
                      "An absent window type reached WebKit, was supplemented, or called back more than once (tabs=\(metadata)): \(page.evaluateScript("nativeCalls + ' ' + callbacks + ' ' + appResult")?.toString() ?? "")")
            page.evaluateScript("browser.tabs.query({active: true}, function(v) { callbacks += 1; normalCount = v.length; });")
            page.evaluateScript("advance(3000);")
            try check(page.evaluateScript("nativeCalls === 1 && callbacks === 2 && normalCount === 1")!.toBool(),
                      "A normal query did not reach WebKit exactly once with one callback (tabs=\(metadata)): \(page.evaluateScript("nativeCalls + ' ' + callbacks + ' ' + normalCount")?.toString() ?? "")")
        }
    }

    /// After Revoke Permissions the fresh worker context has no nativeMessaging, so WebKit exposes neither
    /// sendNativeMessage nor connectNative. Top-level listener registration must not throw (a throw stops the worker
    /// from loading, and WebKit then never answers its queued messages); nothing is delivered, no port is opened, and
    /// every bridged call rejects with exactly the adapter's transport text.
    @available(macOS 15.4, *)
    static func revokedWorkerTransport(_ check: (Bool, String) throws -> Void) throws {
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Original Revoked Worker Fixture", "version": "1.0",
                                      "permissions": ["notifications", "idle", "history", "bookmarks"]]
        let js = JSContext()!
        var errors: [String] = []
        js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
        js.evaluateScript("""
        var console = {error: function() {}, warn: function() {}}, performance = {now: function() { return 0; }};
        var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'};
        var browser = {runtime: {
          getURL: function(path) { return 'webkit-extension://fixture' + path; },
          getManifest: function() { return \(String(data: try! JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!); }
        }, storage: {}, action: {}};
        var results = {}, heard = [];
        """)
        js.evaluateScript(ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: "test"))
        js.evaluateScript("""
        var top = function(x) { heard.push(x); };
        browser.idle.onStateChanged.addListener(top); browser.notifications.onClicked.addListener(top);
        browser.history.onVisited.addListener(top); browser.windows && browser.windows.onBoundsChanged && browser.windows.onBoundsChanged.addListener(top);
        results.registered = browser.idle.onStateChanged.hasListener(top) && browser.notifications.onClicked.hasListener(top) && browser.history.onVisited.hasListener(top);
        """)
        try check(errors.isEmpty && js.evaluateScript("results.registered === true")!.toBool(),
                  "A revoked worker's top-level listener registration threw or was lost: \(errors)")
        js.evaluateScript("""
        browser.history.search({text: ''}).then(function() { results.history = 'resolved'; }, function(e) { results.history = e.message; });
        browser.bookmarks.getTree().then(function() { results.bookmarks = 'resolved'; }, function(e) { results.bookmarks = e.message; });
        browser.idle.queryState(15).then(function() { results.idle = 'resolved'; }, function(e) { results.idle = e.message; });
        """)
        let text = ExtensionCompatibility.workerTransportUnavailable
        for name in ["history", "bookmarks", "idle"] {
            try check(js.evaluateScript("results.\(name)")?.toString() == text, "A revoked worker's \(name) call did not refuse with the exact transport text: \(js.evaluateScript("results.\(name)")?.toString() ?? "")")
        }
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
            var logged = [], console = {error: function() { logged.push(Array.prototype.slice.call(arguments).map(function (x) { return String(x && x.message || x); }).join(' ')); }}, performance = {now: function() { return 0; }};
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
            results.callbackError = [browser.runtime.lastError, chrome.runtime.lastError, Object.getOwnPropertyNames(browser.runtime).indexOf('lastError')];
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
            results.callbackArgs === 0 && results.callbackError[0] === undefined && results.callbackError[1] === undefined && results.callbackError[2] === -1
            && logged.some(function (line) { return line.indexOf('Only a single offscreen document may be created.') !== -1; })
            """)!.toBool(), "A callback-form failure faked runtime.lastError or was not logged: \(js.evaluateScript("JSON.stringify([results, logged])")!)")
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
            && results.setError === undefined && logged.some(function (line) { return line.indexOf('fontSettings.setFont is not available in Bam.') !== -1; }) && browser.fontSettings.GenericFamily.SERIF === 'serif'
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
