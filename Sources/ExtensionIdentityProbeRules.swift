import Foundation

/// Pure parts of the extension identity feasibility probe (ExtensionIdentityProbe): the original fixture
/// package, the shared measurement script, the made-up alias and how results are read. Foundation only, so
/// JavaScriptCore component tests can run the script against fakes without WebKit.
///
/// The alias is an original test string. It is deliberately not shaped like any store's extension ID and is
/// not a claimed vendor identity. Collected evidence is not a compatibility claim.
enum ExtensionIdentityProbeRules {
    static let marker = "bamIdentityProbe"
    /// Made-up, fixture-only. Not 32 letters a–p (Chrome's ID alphabet) and not a UUID.
    static let alias = "bam-identity-probe-alias-0001"
    static let fixtureName = "Bam identity probe fixture"
    static let pagePath = "identity.html"
    static let budget: TimeInterval = 45

    /// Chrome Web Store IDs are 32 characters from a–p.
    static func isChromeStyleID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("a"..."p").contains($0) }
    }

    static func manifest() -> [String: Any] {
        ["manifest_version": 3, "name": fixtureName, "version": "1.0",
         "description": "Original fixture: measures runtime.id and whether a page or worker can observe a fixture-only alias",
         "permissions": ["storage"],
         "background": ["service_worker": "worker.js"]]
    }

    /// Runs in the extension page and in the (Bam-prepared) service worker. Returns a Promise of plain JSON.
    /// Every override it makes is restored before it resolves; restoration is itself measured.
    static let measurementScript = #"""
    async function bamIdentityMeasure(alias, scope) {
      const g = globalThis;
      const out = {scope, alias};
      const text = (e) => String((e && e.message) || e).slice(0, 300);
      const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
      const safe = (fn) => { try { return {value: fn()}; } catch (e) { return {error: text(e)}; } };
      const describe = (d) => d ? {kind: ("get" in d || "set" in d) ? "accessor" : "data", configurable: !!d.configurable,
        enumerable: !!d.enumerable, writable: "writable" in d ? !!d.writable : null, hasGetter: typeof d.get === "function",
        hasSetter: typeof d.set === "function"} : null;
      const chain = (object, key) => {
        const found = [];
        let current = object, depth = 0;
        while (current && depth < 8) {
          const d = Object.getOwnPropertyDescriptor(current, key);
          if (d) found.push({depth, tag: Object.prototype.toString.call(current), descriptor: describe(d)});
          current = Object.getPrototypeOf(current); depth += 1;
        }
        return found;
      };
      const nativeChrome = g.chrome, nativeBrowser = g.browser;
      const rt = nativeChrome && nativeChrome.runtime;
      out.types = {chrome: typeof nativeChrome, browser: typeof nativeBrowser, runtime: typeof rt,
                   sameRoot: nativeChrome !== undefined && nativeChrome === nativeBrowser};
      if (!rt) return out;
      const nativeID = rt.id;
      const nativeURL = safe(() => rt.getURL("identity.html"));
      out.native = {id: nativeID, browserID: nativeBrowser && nativeBrowser.runtime ? nativeBrowser.runtime.id : null,
                    getURL: nativeURL, origin: g.location ? g.location.origin : null,
                    idIsUUID: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(nativeID))};
      out.descriptors = {globalChrome: describe(Object.getOwnPropertyDescriptor(g, "chrome")),
                         globalBrowser: describe(Object.getOwnPropertyDescriptor(g, "browser")),
                         runtimeOnRoot: chain(nativeChrome, "runtime"), id: chain(rt, "id"),
                         runtimeExtensible: Object.isExtensible(rt), runtimeFrozen: Object.isFrozen(rt),
                         runtimeTag: Object.prototype.toString.call(rt),
                         freshRuntimeIsSameObject: g.chrome.runtime === rt};
      const reads = () => ({sameObject: safe(() => rt.id).value,
                            freshChrome: safe(() => g.chrome.runtime.id).value,
                            freshBrowser: safe(() => g.browser && g.browser.runtime ? g.browser.runtime.id : null).value,
                            freshHasOwnID: safe(() => Object.prototype.hasOwnProperty.call(g.chrome.runtime, "id")).value});
      async function nativeCalls(api) {
        const r = {};
        r.getURL = safe(() => api.runtime.getURL("identity.html"));
        r.getURLMatchesNative = r.getURL.value === nativeURL.value;
        r.manifestName = safe(() => api.runtime.getManifest().name);
        try {
          await api.storage.local.set({bamIdentityProbe: alias});
          const got = await api.storage.local.get("bamIdentityProbe");
          r.storageRoundTrip = !!got && got.bamIdentityProbe === alias;
          await api.storage.local.remove("bamIdentityProbe");
        } catch (e) { r.storageError = text(e); }
        try {
          const listener = () => undefined;
          api.runtime.onMessage.addListener(listener);
          r.listenerAdded = api.runtime.onMessage.hasListener(listener);
          api.runtime.onMessage.removeListener(listener);
          r.listenerRemoved = !api.runtime.onMessage.hasListener(listener);
        } catch (e) { r.listenerError = text(e); }
        return r;
      }

      // A. An own getter on the native runtime object (native attributes have outranked own properties before).
      const own = {};
      // An existing own `id` is put back exactly; otherwise the added one is deleted.
      const originalOwnID = Object.getOwnPropertyDescriptor(rt, "id");
      own.originalOwnDescriptor = describe(originalOwnID);
      try { Object.defineProperty(rt, "id", {get() { return alias; }, configurable: true, enumerable: true}); own.defined = true; }
      catch (e) { own.defined = false; own.error = text(e); }
      own.descriptorAfter = describe(Object.getOwnPropertyDescriptor(rt, "id"));
      own.immediate = reads();
      await sleep(60);
      own.delayed = reads();
      own.nativeCalls = await nativeCalls(nativeChrome);
      if (own.defined) {
        try {
          if (originalOwnID) { Object.defineProperty(rt, "id", originalOwnID); own.restoredOwnDescriptor = true; }
          else { own.deleted = delete rt.id; }
        } catch (e) { own.restoreError = text(e); }
      }
      own.afterRestore = reads();
      const after = Object.getOwnPropertyDescriptor(rt, "id");
      const sameDescriptor = originalOwnID ? !!after && after.value === originalOwnID.value && after.get === originalOwnID.get
          && !!after.configurable === !!originalOwnID.configurable && !!after.writable === !!originalOwnID.writable : !after;
      own.restored = own.afterRestore.freshChrome === nativeID && sameDescriptor;
      out.ownGetter = own;

      // B. A fixture-only global facade: chrome.runtime.id answers the alias; every other member keeps its native receiver.
      const facadeResult = {};
      const bind = (target, value) => typeof value === "function" ? value.bind(target) : value;
      const runtimeFacade = new Proxy(rt, {get(target, key) { return key === "id" ? alias : bind(target, Reflect.get(target, key)); }});
      const facade = new Proxy(nativeChrome, {get(target, key) { return key === "runtime" ? runtimeFacade : bind(target, Reflect.get(target, key)); }});
      const original = Object.getOwnPropertyDescriptor(g, "chrome");
      facadeResult.globalDescriptorBefore = describe(original);
      try {
        Object.defineProperty(g, "chrome", {value: facade, configurable: true, writable: true, enumerable: original ? !!original.enumerable : false});
        facadeResult.installed = true;
      } catch (e) { facadeResult.installed = false; facadeResult.error = text(e); }
      facadeResult.immediate = {globalChrome: safe(() => g.chrome.runtime.id).value,
                                bareChrome: safe(() => chrome.runtime.id).value,
                                browser: safe(() => g.browser && g.browser.runtime ? g.browser.runtime.id : null).value,
                                facadeDirect: facade.runtime.id};
      await sleep(60);
      facadeResult.delayed = {globalChrome: safe(() => g.chrome.runtime.id).value, bareChrome: safe(() => chrome.runtime.id).value};
      facadeResult.nativeCalls = await nativeCalls(facade);
      try {
        if (original) Object.defineProperty(g, "chrome", original); else delete g.chrome;
      } catch (e) { facadeResult.restoreError = text(e); }
      facadeResult.restored = g.chrome === nativeChrome && safe(() => g.chrome.runtime.id).value === nativeID;
      out.facade = facadeResult;
      out.finalNativeID = safe(() => g.chrome.runtime.id).value;
      return out;
    }
    """#

    /// Worker: answers sender questions and runs the measurement in its own scope. onMessageExternal is
    /// recorded in case an alias-targeted message is delivered as external.
    static let workerScript = measurementScript + #"""

    const bamIdentityExternal = [];
    try {
      if (chrome.runtime.onMessageExternal) chrome.runtime.onMessageExternal.addListener((message, sender) => {
        bamIdentityExternal.push({message: message && message.kind, senderID: sender && sender.id}); return undefined;
      });
    } catch (e) {}
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
      if (!message || typeof message.kind !== "string") return undefined;
      if (message.kind === "sender") {
        sendResponse({senderID: sender && sender.id, senderURL: sender && sender.url, senderOrigin: sender && sender.origin,
                      workerRuntimeID: chrome.runtime.id, label: message.label});
        return undefined;
      }
      if (message.kind === "external-log") { sendResponse(bamIdentityExternal.slice()); return undefined; }
      if (message.kind === "measure") { bamIdentityMeasure(message.alias, "worker").then(sendResponse, (e) => sendResponse({error: String(e)})); return true; }
      return undefined;
    });
    """#

    static let pageHTML = #"""
    <!doctype html><meta charset="utf-8"><title>Bam identity probe</title>
    <p>Bam identity probe fixture (original). Measurement only.</p>
    <script src="identity.js"></script>
    """#

    /// Page: measures itself, then messaging (no target, native UUID, alias) with a bounded wait each, then the worker.
    static func pageScript(alias: String) -> String {
        measurementScript + #"""

        (async () => {
          const alias = \#(jsonString(alias));
          const text = (e) => String((e && e.message) || e).slice(0, 300);
          const bounded = (promise, ms) => Promise.race([
            Promise.resolve(promise).then((value) => ({outcome: "resolved", value: value === undefined ? null : value}),
                                          (error) => ({outcome: "rejected", error: text(error)})),
            new Promise((resolve) => setTimeout(() => resolve({outcome: "timed out"}), ms))]);
          const result = {};
          try { result.page = await bamIdentityMeasure(alias, "page"); } catch (e) { result.pageError = text(e); }
          const send = (target, label) => {
            try {
              return bounded(target === undefined ? chrome.runtime.sendMessage({kind: "sender", label})
                                                  : chrome.runtime.sendMessage(target, {kind: "sender", label}), 3000);
            } catch (e) { return Promise.resolve({outcome: "threw", error: text(e)}); }
          };
          const nativeID = chrome.runtime.id;
          result.messaging = {implicit: await send(undefined, "implicit"), nativeID: await send(nativeID, "native-id"),
                              alias: await send(alias, "alias")};
          result.messaging.externalLog = await bounded(chrome.runtime.sendMessage({kind: "external-log"}), 3000);
          result.worker = await bounded(chrome.runtime.sendMessage({kind: "measure", alias}), 8000);
          result.contentScripts = "pending: not measured in this checkpoint";
          document.documentElement.dataset.\#(marker) = JSON.stringify(result);
        })();
        """#
    }

    static func jsonString(_ value: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// One scope's evidence, read without claiming compatibility.
    struct ScopeReading: Equatable {
        var nativeIDIsUUID: Bool?
        /// The alias was seen on every read of A (same object, fresh chrome, fresh browser, after a delay).
        var ownGetterObserved: Bool?
        var ownGetterDefinedButIgnored: Bool?
        var facadeInstalled: Bool?
        /// The alias was seen through the global and bare `chrome` after installing B, immediately and later.
        var facadeObserved: Bool?
        var facadeNativeCallsWork: Bool?
        var restored: Bool?
    }

    static func read(_ scope: [String: Any]?) -> ScopeReading {
        guard let scope else { return ScopeReading() }
        var reading = ScopeReading()
        let alias = scope["alias"] as? String
        reading.nativeIDIsUUID = (scope["native"] as? [String: Any])?["idIsUUID"] as? Bool
        if let own = scope["ownGetter"] as? [String: Any] {
            let defined = own["defined"] as? Bool ?? false
            let reads = [own["immediate"], own["delayed"]].compactMap { $0 as? [String: Any] }
            let values = reads.flatMap { [$0["sameObject"], $0["freshChrome"], $0["freshBrowser"]] }.compactMap { $0 as? String }
            let observed = defined && !values.isEmpty && values.allSatisfy { $0 == alias }
            reading.ownGetterObserved = observed
            reading.ownGetterDefinedButIgnored = defined && !observed
            reading.restored = own["restored"] as? Bool
        }
        if let facade = scope["facade"] as? [String: Any] {
            let installed = facade["installed"] as? Bool ?? false
            reading.facadeInstalled = installed
            let immediate = facade["immediate"] as? [String: Any], delayed = facade["delayed"] as? [String: Any]
            let seen = [immediate?["globalChrome"], immediate?["bareChrome"], delayed?["globalChrome"], delayed?["bareChrome"]].map { $0 as? String }
            reading.facadeObserved = installed && seen.allSatisfy { $0 == alias }
            if let calls = facade["nativeCalls"] as? [String: Any] {
                reading.facadeNativeCallsWork = calls["getURLMatchesNative"] as? Bool == true && calls["storageRoundTrip"] as? Bool == true
                    && calls["listenerAdded"] as? Bool == true && calls["listenerRemoved"] as? Bool == true
            }
            reading.restored = (reading.restored ?? true) && facade["restored"] as? Bool == true
        }
        return reading
    }

    static func summary(_ reading: ScopeReading) -> [String: Any] {
        func value(_ flag: Bool?) -> Any { flag.map { $0 as Any } ?? "not measured" }
        return ["native_id_is_uuid": value(reading.nativeIDIsUUID), "own_getter_observed": value(reading.ownGetterObserved),
                "own_getter_defined_but_ignored": value(reading.ownGetterDefinedButIgnored), "facade_installed": value(reading.facadeInstalled),
                "facade_observed": value(reading.facadeObserved), "facade_native_calls_work": value(reading.facadeNativeCallsWork),
                "overrides_restored": value(reading.restored)]
    }
}
