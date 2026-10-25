import Foundation
import JavaScriptCore

/// Component checks for the identity probe's original fixture and measurement script. The script runs in
/// JavaScriptCore against fake runtimes; no WebKit extension, app or vendor package is involved. The fakes
/// model outcomes, they don't prove WebKit's behavior: the native run in canonical Bam Preview does that.
@main enum ExtensionIdentityProbeTests {
    typealias Rules = ExtensionIdentityProbeRules
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }

        // The fixture and alias.
        require(!Rules.isChromeStyleID(Rules.alias) && UUID(uuidString: Rules.alias) == nil, "The alias is a made-up string, not a store ID or UUID")
        require(Rules.isChromeStyleID("abcdefghijklmnopabcdefghijklmnop") && !Rules.isChromeStyleID("abcdefghijklmnopabcdefghijklmnoq"),
                "Chrome-style IDs are recognized (32 letters a–p)")
        let manifest = Rules.manifest()
        require(manifest["permissions"] as? [String] == ["storage"] && manifest["content_scripts"] == nil && manifest["host_permissions"] == nil
                && (manifest["background"] as? [String: Any])?["service_worker"] as? String == "worker.js" && manifest["key"] == nil,
                "The package asks for storage only, has no content scripts, host access or key, and uses a service worker")
        require(Rules.jsonString("a\"b\\c") == "\"a\\\"b\\\\c\"", "Embedded strings are JSON-escaped")

        // Fake runtimes. Native functions reject a wrong receiver, like WebKit bindings.
        let nativeID = "6F2B7C1E-0D3A-4B5C-9E8F-1A2B3C4D5E6F"
        let setup = #"""
        globalThis.makeRuntime = (id, mode) => {
          const listeners = new Set();
          const onMessage = {addListener(l) { if (this !== onMessage) throw new Error("receiver"); listeners.add(l); },
                             removeListener(l) { if (this !== onMessage) throw new Error("receiver"); listeners.delete(l); },
                             hasListener(l) { if (this !== onMessage) throw new Error("receiver"); return listeners.has(l); }};
          const base = {getURL(path) { if (this !== runtime && this !== target) throw new Error("receiver"); return "webkit-extension://" + id.toLowerCase() + "/" + path; },
                        getManifest() { return {name: "Bam identity probe fixture"}; }, onMessage};
          let target, runtime;
          if (mode === "native-precedence") {
            // Like a native attribute: own properties can be defined and described, but reads of `id` ignore them.
            target = Object.assign(Object.create(null), base);
            runtime = new Proxy(target, {get(t, key) { return key === "id" ? id : Reflect.get(t, key); }});
          } else if (mode === "locked") {
            // A locked native `id`: non-configurable, read-only data. defineProperty throws, and a Proxy that
            // answers a different `id` violates the invariant, so reading the facade throws a TypeError.
            target = runtime = Object.assign({}, base);
            Object.defineProperty(runtime, "id", {value: id, configurable: false, enumerable: true, writable: false});
          } else {
            target = runtime = Object.assign({}, base);
            Object.defineProperty(runtime, "id", {value: id, configurable: true, enumerable: true, writable: false});
          }
          const data = {};
          const local = {set(values) { if (this !== local) throw new Error("receiver"); Object.assign(data, values); return Promise.resolve(); },
                         get(key) { if (this !== local) throw new Error("receiver"); return Promise.resolve({[key]: data[key]}); },
                         remove(key) { if (this !== local) throw new Error("receiver"); delete data[key]; return Promise.resolve(); }};
          return {runtime, storage: {local}};
        };
        globalThis.install = (mode, configurableGlobal) => {
          const api = makeRuntime(\#(Rules.jsonString(nativeID)), mode);
          Object.defineProperty(globalThis, "chrome", {value: api, configurable: configurableGlobal, writable: configurableGlobal, enumerable: true});
          globalThis.nativeChrome = api;
        };
        """#

        func run(mode: String, configurableGlobal: Bool) -> [String: Any] {
            let context = JSContext()!
            var failure: String?
            context.exceptionHandler = { _, exception in failure = exception?.toString() }
            let timers: @convention(block) (JSValue, Double) -> Void = { callback, delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay) / 1000) { callback.call(withArguments: []) }
            }
            context.setObject(timers, forKeyedSubscript: "setTimeout" as NSString)
            context.evaluateScript(setup)
            context.evaluateScript(Rules.measurementScript)
            context.evaluateScript("install(\(Rules.jsonString(mode)), \(configurableGlobal)); globalThis.probeDone = undefined;" +
                                   "bamIdentityMeasure(\(Rules.jsonString(Rules.alias)), 'page').then((r) => { globalThis.probeDone = JSON.stringify(r); }, (e) => { globalThis.probeDone = 'ERROR ' + e; });")
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, context.objectForKeyedSubscript("probeDone")?.isUndefined != false {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            require(failure == nil, "Script raised in \(mode): \(failure ?? "")")
            let text = context.objectForKeyedSubscript("probeDone")?.toString() ?? ""
            require(!text.hasPrefix("ERROR") && !text.isEmpty, "Measurement resolved in \(mode): \(text)")
            let restored = context.evaluateScript("globalThis.chrome === globalThis.nativeChrome && chrome.runtime.id === \(Rules.jsonString(nativeID))")
            require(restored?.toBool() == true, "Global chrome and runtime.id are restored after \(mode)")
            // Plain: the original own data property is back exactly. Native-precedence: no own `id` is left behind.
            let descriptor = context.evaluateScript(mode == "plain"
                ? "(() => { const d = Object.getOwnPropertyDescriptor(chrome.runtime, 'id'); return !!d && 'value' in d && d.writable === false && d.configurable === true; })()"
                : mode == "locked"
                ? "(() => { const d = Object.getOwnPropertyDescriptor(chrome.runtime, 'id'); return !!d && d.configurable === false && d.writable === false; })()"
                : "!Object.prototype.hasOwnProperty.call(chrome.runtime, 'id')")
            require(descriptor?.toBool() == true, "The runtime's own `id` is restored exactly in \(mode)")
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }

        // Plain object: an own getter is observed; restore deletes it.
        let plain = run(mode: "plain", configurableGlobal: true)
        let plainReading = Rules.read(plain)
        require((plain["native"] as? [String: Any])?["id"] as? String == nativeID && plainReading.nativeIDIsUUID == true, "Native ID read and recognized as a UUID")
        require(plainReading.ownGetterObserved == true && plainReading.ownGetterDefinedButIgnored == false, "Plain model: the own getter is observed everywhere")
        require(plainReading.facadeInstalled == true && plainReading.facadeObserved == true && plainReading.facadeNativeCallsWork == true,
                "Plain model: the facade is observed and native calls keep their receivers")
        require(plainReading.restored == true, "Plain model: both overrides restored")

        // Native-precedence model: defineProperty "works" and the descriptor appears, but reads stay native.
        let native = run(mode: "native-precedence", configurableGlobal: true)
        let nativeReading = Rules.read(native)
        let own = native["ownGetter"] as? [String: Any]
        require(own?["defined"] as? Bool == true && (own?["descriptorAfter"] as? [String: Any])?["kind"] as? String == "accessor",
                "Native-precedence model: the getter is defined and described")
        require(nativeReading.ownGetterObserved == false && nativeReading.ownGetterDefinedButIgnored == true,
                "Native-precedence model: a defined-but-ignored own getter is reported as not observed")
        require(nativeReading.facadeObserved == true && nativeReading.facadeNativeCallsWork == true && nativeReading.restored == true,
                "Native-precedence model: the facade still works through native receivers and is restored")

        // Non-configurable global chrome: the facade can't be installed, and that's reported, not hidden.
        let locked = run(mode: "native-precedence", configurableGlobal: false)
        let lockedReading = Rules.read(locked)
        require(lockedReading.facadeInstalled == false && lockedReading.facadeObserved == false && (locked["facade"] as? [String: Any])?["error"] != nil,
                "A non-configurable global chrome blocks the facade and records why")
        let summary = Rules.summary(lockedReading)
        require(summary["facade_observed"] as? Bool == false && summary["own_getter_observed"] as? Bool == false, "Summary reports unobserved outcomes as false")
        require(Rules.summary(Rules.read(nil))["facade_observed"] as? String == "not measured", "Missing evidence is 'not measured', never a pass")

        // Review: a locked native `id` makes the facade's reads throw after the global was replaced. The
        // throw is captured as a result and the global is still restored (run() checks both).
        let lockedID = run(mode: "locked", configurableGlobal: true)
        let lockedOwn = lockedID["ownGetter"] as? [String: Any], lockedFacade = lockedID["facade"] as? [String: Any]
        let lockedReads = lockedFacade?["immediate"] as? [String: Any]
        require(lockedOwn?["defined"] as? Bool == false && lockedOwn?["error"] != nil, "A locked id refuses the own getter, recorded")
        require(lockedFacade?["installed"] as? Bool == true && (lockedReads?["facadeDirect"] as? [String: Any])?["error"] != nil
                && (lockedReads?["globalChrome"] as? [String: Any])?["error"] != nil,
                "Facade reads that throw are captured as errors, not thrown past the restore")
        let lockedIDReading = Rules.read(lockedID)
        require(lockedIDReading.facadeObserved == false && lockedIDReading.restored == true, "Locked id: facade not observed, global restored")
        require(Rules.isMeasured(lockedID), "A definite negative outcome with confirmed restore is still a measurement")

        // Review: completion needs measured page and worker scopes, confirmed restores and definite message outcomes.
        let messages: [String: Any] = ["implicit": ["outcome": "resolved"], "nativeID": ["outcome": "resolved"], "alias": ["outcome": "rejected", "error": "x"]]
        let complete: [String: Any] = ["page": plain, "worker": ["outcome": "resolved", "value": native], "messaging": messages]
        require(Rules.missing(complete).isEmpty, "Measured page + worker + all messages is complete: \(Rules.missing(complete))")
        var workerErrorResult = complete; workerErrorResult["worker"] = ["outcome": "resolved", "value": ["error": "TypeError: boom"]]
        require(Rules.missing(workerErrorResult) == ["worker"], "A worker {error} reply is not a measurement")
        var workerTimeout = complete; workerTimeout["worker"] = ["outcome": "timed out"]
        require(Rules.missing(workerTimeout) == ["worker"], "A timed-out worker is not a measurement")
        var unrestored = plain; var unrestoredFacade = plain["facade"] as! [String: Any]; unrestoredFacade["restored"] = false; unrestored["facade"] = unrestoredFacade
        var pageUnrestored = complete; pageUnrestored["page"] = unrestored
        require(Rules.missing(pageUnrestored) == ["page"], "An unconfirmed restore makes the page scope incomplete")
        var noAlias = complete; noAlias["messaging"] = ["implicit": ["outcome": "resolved"], "nativeID": ["outcome": "resolved"]]
        require(Rules.missing(noAlias) == ["messaging.alias"], "A missing message outcome is reported")
        require(!Rules.isMeasured(nil) && !Rules.isMeasured(["error": "x"]), "Nothing or an error object is never measured")

        // The worker and page scripts parse; the worker answers sender and measure messages.
        let worker = JSContext()!
        var workerError: String?
        worker.exceptionHandler = { _, exception in workerError = exception?.toString() }
        let workerTimers: @convention(block) (JSValue, Double) -> Void = { callback, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay) / 1000) { callback.call(withArguments: []) }
        }
        worker.setObject(workerTimers, forKeyedSubscript: "setTimeout" as NSString)
        worker.evaluateScript(setup)
        worker.evaluateScript("install('plain', true); globalThis.location = {origin: 'webkit-extension://fixture'};")
        worker.evaluateScript("const realAdd = chrome.runtime.onMessage.addListener.bind(chrome.runtime.onMessage); globalThis.workerListener = null;" +
                              "chrome.runtime.onMessage.addListener = function(l) { globalThis.workerListener = l; return realAdd(l); };")
        worker.evaluateScript(Rules.workerScript)
        require(workerError == nil, "The worker script runs: \(workerError ?? "")")
        worker.evaluateScript("globalThis.senderReply = null; workerListener({kind: 'sender', label: 'x'}, {id: 'native', url: 'u', origin: 'o'}, (r) => { globalThis.senderReply = JSON.stringify(r); });")
        let senderReply = worker.objectForKeyedSubscript("senderReply")?.toString() ?? ""
        require(senderReply.contains("\"senderID\":\"native\"") && senderReply.contains("\"workerRuntimeID\":\"\(nativeID)\""), "The worker reports sender and its own runtime ID: \(senderReply)")
        worker.evaluateScript("globalThis.measureReply = undefined; const keep = workerListener({kind: 'measure', alias: \(Rules.jsonString(Rules.alias))}, {}, (r) => { globalThis.measureReply = JSON.stringify(r); }); globalThis.keptOpen = keep === true;")
        let workerDeadline = Date().addingTimeInterval(5)
        while Date() < workerDeadline, worker.objectForKeyedSubscript("measureReply")?.isUndefined != false { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let measureReply = worker.objectForKeyedSubscript("measureReply")?.toString() ?? ""
        require(worker.objectForKeyedSubscript("keptOpen")?.toBool() == true && measureReply.contains("\"scope\":\"worker\""),
                "The worker keeps the channel open and returns its own measurement")
        let page = JSContext()!
        var pageError: String?
        page.exceptionHandler = { _, exception in pageError = exception?.toString() }
        page.evaluateScript("new Function(\(Rules.jsonString(Rules.pageScript(alias: Rules.alias))));")
        require(pageError == nil, "The page script parses: \(pageError ?? "")")
        require(Rules.pageScript(alias: Rules.alias).contains("contentScripts = \"pending"), "Content scripts are reported as pending, not measured")
        print("PASS: \(checks) extension identity probe checks")
    }
}
