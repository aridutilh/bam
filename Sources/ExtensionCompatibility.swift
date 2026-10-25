import Foundation
import AppKit
import WebKit
import UserNotifications

/// Bam's disclosed compatibility layer for WebExtension APIs that WebKit does not
/// provide. WebExtension namespaces are defined only
/// when `browser.<name>` is absent in the extension's own pages (background,
/// popup, options and other extension-origin documents). Prepared service workers
/// use the same adapter with a restricted native-message transport.
/// A separate own-resource WASM MIME adapter delegates compilation to the native
/// WebAssembly APIs, preserving their validation and CSP enforcement.
///
/// The layer is honest about limits. Shimmed APIs return conservative values
/// (privacy settings "not controllable", no managed storage, no
/// commands) or reject with a clear error. Notifications, idle state and
/// downloads cross into native code through an authenticated message bridge.
@available(macOS 15.4, *)
enum ExtensionCompatibility {
    static let nativeApplicationIdentifier = "com.ari.bam.compatibility"
    struct Plan: Codable, Equatable {
        /// Namespaces or members the layer defines when absent, in manifest order.
        var provided: [String] = []
        /// Requested permissions Bam neither supports natively nor bridges.
        var unavailable: [String] = []
        var isEmpty: Bool { provided.isEmpty }
    }

    /// Permissions WebKit's engine does not implement and this layer can stand in for.
    static let bridgedPermissions: [String] = ["notifications", "idle", "privacy", "management", "downloads", "offscreen"]
    /// Members the layer always offers when the host namespace exists but the member does not.
    static let runtimeExtras: [String] = ["runtime.getBrowserInfo", "runtime.onSuspend", "runtime.requestUpdateCheck", "runtime.getContexts",
                                          "webNavigation.onCreatedNavigationTarget", "storage.managed", "commands", "action.getUserSettings"]

    /// Computes what the layer will define for a parsed extension, from its manifest.
    static func plan(manifest: [String: Any]) -> Plan {
        var requested: [String] = []
        // Optional permissions stay undefined until granted, as in Firefox; WebKit
        // cannot grant a permission it does not know, so they are never provided.
        for case let value as String in manifest["permissions"] as? [Any] ?? [] { requested.append(value) }
        var plan = Plan()
        for permission in bridgedPermissions where requested.contains(permission) { plan.provided.append(permission) }
        plan.provided += runtimeExtras
        return plan
    }

    /// Names shown in the permission review for a bridged permission list.
    static func reviewLabel(_ permissions: [String]) -> String {
        permissions.joined(separator: ", ")
    }

    /// Builds the document-start script for one extension context.
    static func script(baseURL: URL, bridge: String, plan: Plan, browserVersion: String) -> String {
        let origin = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let provided = (try? JSONSerialization.data(withJSONObject: plan.provided)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return source
            .replacingOccurrences(of: "__ORIGIN__", with: javaScriptString(origin))
            .replacingOccurrences(of: "__WORKER__", with: "false")
            .replacingOccurrences(of: "__WASM_ADAPTER__", with: ExtensionWasmCompatibility.source)
            .replacingOccurrences(of: "__BRIDGE__", with: javaScriptString(bridge))
            .replacingOccurrences(of: "__PROVIDED__", with: provided)
            .replacingOccurrences(of: "__VERSION__", with: javaScriptString(browserVersion))
            + "\n" + documentActionIconBinding(baseURL: baseURL)
    }

    /// WebKit's document-native API functions require their namespace receiver.
    /// Chrome callers can extract setIcon, so bind only this method while keeping
    /// native validation, callback/Promise handling, and permission checks intact.
    /// Service workers use a different JS facade and retain their prepared bytes.
    static func documentActionIconBinding(baseURL: URL) -> String {
        let origin = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        return documentActionIconSource.replacingOccurrences(of: "__ORIGIN__", with: javaScriptString(origin))
    }

    private static let documentActionIconSource = #"""
    (() => {
      if (location.origin !== __ORIGIN__) return;
      const marker = "__bamNativeActionIconBindings";
      if (Object.prototype.hasOwnProperty.call(globalThis, marker)) return;
      const held = [], seen = new WeakSet();
      const bind = Function.prototype.bind;
      for (const api of [globalThis.browser, globalThis.chrome]) {
        if (!api || typeof api !== "object") continue;
        for (const name of ["action", "browserAction"]) {
          const holder = api[name];
          if (!holder || typeof holder.setIcon !== "function" || seen.has(holder)) continue;
          seen.add(holder);
          const descriptor = Object.getOwnPropertyDescriptor(holder, "setIcon");
          const bound = Reflect.apply(bind, holder.setIcon, [holder]);
          try {
            Object.defineProperty(holder, "setIcon", {value: bound, writable: true, configurable: true,
              enumerable: descriptor ? descriptor.enumerable : true});
            held.push(holder);
          } catch (_) { /* A non-writable native API remains unchanged. */ }
        }
      }
      // Native namespace wrappers are weakly cached; retain both browser/chrome
      // variants so future lookups return the same correctly bound method.
      Object.defineProperty(globalThis, marker, {value: held, configurable: false});
    })();
    """#

    /// The package preparer loads this adapter before the unchanged worker entry.
    /// It performs no asynchronous initialization or lifecycle keepalive polling.
    static func workerScript(manifest: [String: Any], browserVersion: String) -> String {
        let provided = (try? JSONSerialization.data(withJSONObject: plan(manifest: manifest).provided))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return source
            .replacingOccurrences(of: "__ORIGIN__", with: "api.runtime.getURL('/').replace(/\\/$/, '')")
            .replacingOccurrences(of: "__WORKER__", with: "true")
            .replacingOccurrences(of: "__WASM_ADAPTER__", with: ExtensionWasmCompatibility.source)
            .replacingOccurrences(of: "__BRIDGE__", with: javaScriptString(nativeApplicationIdentifier))
            .replacingOccurrences(of: "__PROVIDED__", with: provided)
            .replacingOccurrences(of: "__VERSION__", with: javaScriptString(browserVersion))
    }

    private static func javaScriptString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let text = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }

    // The original adapter leaves native WebExtension APIs intact. The explicitly
    // scoped WASM adapter delegates byte compilation to the native engine.
    private static let source = #"""
    (() => {
      const api = globalThis.browser || globalThis.chrome;
      if (!api || typeof api !== "object" || api.__bamCompatibility) return;
      if (location.origin !== __ORIGIN__) return;
      __WASM_ADAPTER__
      // Explicit resource management: TypeScript `using` helpers throw, and wasm-bindgen
      // classes omit their dispose methods, when the engine lacks these well-known symbols
      // (Bitwarden's SDK client relies on both). Native symbols are never replaced. Like a
      // well-known symbol, the fallback is shared by every realm of the agent (registry key),
      // so a resource made in a same-origin extension frame can be disposed by its parent.
      for (const name of ["dispose", "asyncDispose"]) {
        try { if (typeof Symbol[name] !== "symbol") Object.defineProperty(Symbol, name, { value: Symbol.for("Symbol." + name) }); } catch (error) {}
      }
      const isWorker = __WORKER__;
      const nativeSend = isWorker && api.runtime && typeof api.runtime.sendNativeMessage === "function" ? api.runtime.sendNativeMessage.bind(api.runtime) : null;
      const nativeConnect = isWorker && api.runtime && typeof api.runtime.connectNative === "function" ? api.runtime.connectNative.bind(api.runtime) : null;
      const sendNative = (body) => nativeSend ? Promise.resolve(nativeSend(__BRIDGE__, body)) : Promise.reject(new Error("Bam's worker compatibility transport is unavailable."));
      try { install(); } catch (error) {
        console.error("[Bam compatibility] layer failed to install", error);
        const body = { kind: "scriptError", url: location.href, message: String(error && error.message || error), stack: String(error && error.stack || "").slice(0, 1200) };
        try { if (isWorker) sendNative(body).catch(() => {}); else globalThis.webkit.messageHandlers[__BRIDGE__].postMessage(body); } catch (inner) {}
      }
      function install() {
      const provided = new Set(__PROVIDED__);
      const bridgeName = __BRIDGE__;
      const version = __VERSION__;
      const pending = new Map();
      let nextRequest = 1;
      let eventPort = null;
      const nativeEvents = new Set(["notifications.onClosed", "notifications.onClicked", "notifications.onButtonClicked", "notifications.onShown", "idle.onStateChanged"]);
      const subscribe = (name) => {
        if (!isWorker || !nativeEvents.has(name)) return;
        if (!nativeConnect) throw unsupported("Worker event delivery");
        if (!eventPort) {
          eventPort = nativeConnect(bridgeName);
          const port = eventPort;
          port.onMessage.addListener((message) => {
            if (port === eventPort && message && typeof message.event === "string") compat.dispatch(message.event, message.args);
          });
          port.onDisconnect.addListener(() => { if (eventPort === port) eventPort = null; });
        }
        eventPort.postMessage({ kind: "subscribe", event: name });
      };
      const define = (target, name, value) => Object.defineProperty(target, name, { value, writable: true, configurable: true, enumerable: true });
      const event = (name) => {
        const listeners = new Set();
        const e = {
          addListener(fn) { if (typeof fn === "function") { listeners.add(fn); subscribe(name); } },
          removeListener(fn) {
            listeners.delete(fn);
            if (isWorker && eventPort && nativeEvents.has(name) && !listeners.size) {
              eventPort.postMessage({ kind: "unsubscribe", event: name });
              if (![...nativeEvents].some((key) => compat.events[key] && compat.events[key].hasListeners())) { const port = eventPort; eventPort = null; port.disconnect(); }
            }
          },
          hasListener(fn) { return listeners.has(fn); },
          hasListeners() { return listeners.size > 0; }
        };
        Object.defineProperty(e, "__bamDispatch", { value: (...args) => { for (const fn of Array.from(listeners)) { try { fn(...args); } catch (error) { console.error("[Bam compatibility] " + name + " listener failed", error); } } }, enumerable: false, writable: true, configurable: true });
        return e;
      };
      const unsupported = (what) => new Error(what + " is not available in Bam.");
      // Chrome reports a callback-form failure through runtime.lastError, readable only
      // during that callback. Shadow it on each distinct runtime object, then restore.
      const withLastError = (error, run) => {
        const message = String((error && error.message) || error || "Unknown error");
        const restore = [];
        for (const ns of new Set([globalThis.chrome, globalThis.browser])) {
          const runtime = ns && ns.runtime;
          if (!runtime || restore.some((entry) => entry.runtime === runtime)) continue;
          const own = Object.getOwnPropertyDescriptor(runtime, "lastError");
          try { Object.defineProperty(runtime, "lastError", { value: { message }, configurable: true, enumerable: false, writable: false }); restore.push({ runtime, own }); } catch (inner) {}
        }
        try { run(); } finally {
          for (const { runtime, own } of restore) { try { if (own) Object.defineProperty(runtime, "lastError", own); else delete runtime.lastError; } catch (inner) {} }
        }
      };
      // Callback or promise, matching WebKit's dual-style APIs.
      const call = (fn) => function (...args) {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = Promise.resolve().then(() => fn.apply(this, args));
        if (!callback) return promise;
        promise.then((value) => { try { Array.isArray(value) && value.__bamSpread ? callback(...value) : callback(value); } catch (error) { console.error(error); } },
                     (error) => withLastError(error, () => { try { callback(); } catch (inner) { console.error(inner); } }));
        return undefined;
      };
      const bridge = (method, params) => isWorker ? sendNative({ kind: "request", method, params: params === undefined ? null : params }) : new Promise((resolve, reject) => {
        const handler = globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers[bridgeName];
        if (!handler) { reject(unsupported(method)); return; }
        const id = nextRequest++;
        pending.set(id, { resolve, reject });
        try { handler.postMessage({ kind: "request", id, method, params: params === undefined ? null : params }); }
        catch (error) { pending.delete(id); reject(error); }
      });
      const notify = (kind, detail) => {
        if (isWorker) { try { sendNative({ kind, ...detail }).catch(() => {}); } catch (error) {} return; }
        const handler = globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers[bridgeName];
        if (handler) { try { handler.postMessage({ kind, ...detail }); } catch (error) {} }
      };
      const compat = {
        version,
        worker: isWorker,
        unavailable: isWorker ? ["notifications.onPermissionLevelChanged", "notifications.onShowSettings", "downloads events"] : [],
        events: {},
        resolve(id, value, error) {
          const entry = pending.get(id); if (!entry) return; pending.delete(id);
          if (error) entry.reject(new Error(String(error))); else entry.resolve(value);
        },
        dispatch(name, args) {
          const e = compat.events[name]; if (e && e.__bamDispatch) e.__bamDispatch(...(args || []));
        }
      };
      const registerEvent = (holder, name, fullName) => { const e = event(fullName); define(holder, name, e); compat.events[fullName] = e; return e; };
      const manifest = () => { try { return api.runtime.getManifest() || {}; } catch (error) { return {}; } };

      // notifications: delivered natively when Bam can post them, otherwise kept in memory.
      if (provided.has("notifications") && !api.notifications) {
        const ns = {};
        const ids = new Map();
        const create = async (idOrOptions, maybeOptions) => {
          let id = typeof idOrOptions === "string" ? idOrOptions : "";
          const options = typeof idOrOptions === "string" ? maybeOptions : idOrOptions;
          if (!options || typeof options !== "object") throw new Error("Notification options are required.");
          if (!id) id = "bam-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
          const payload = { id, type: String(options.type || "basic"), title: String(options.title || ""), message: String(options.message || ""),
                            contextMessage: options.contextMessage ? String(options.contextMessage) : "",
                            buttons: Array.isArray(options.buttons) ? options.buttons.slice(0, 2).map((b) => String((b && b.title) || "")) : [] };
          ids.set(id, { ...options });
          try { await bridge("notifications.create", payload); } catch (error) { if (isWorker) { ids.delete(id); throw error; } /* documents retain the existing in-memory fallback */ }
          return id;
        };
        define(ns, "create", call(create));
        define(ns, "update", call(async (id, options) => { if (!ids.has(id)) return false; await create(id, { ...ids.get(id), ...options }); return true; }));
        define(ns, "clear", call(async (id) => { const existed = ids.delete(id); if (existed) { try { await bridge("notifications.clear", { id }); } catch (error) {} } return existed; }));
        define(ns, "getAll", call(async () => { const all = {}; for (const id of ids.keys()) all[id] = true; return all; }));
        define(ns, "getPermissionLevel", call(async () => (await bridge("notifications.permissionLevel", null).catch(() => "denied"))));
        {
          for (const name of ["onClosed", "onClicked", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings", "onShown"]) registerEvent(ns, name, "notifications." + name);
          const original = compat.events["notifications.onClosed"].__bamDispatch;
          Object.defineProperty(compat.events["notifications.onClosed"], "__bamDispatch", { value: (id, byUser) => { ids.delete(id); original(id, byUser); }, enumerable: false, writable: true, configurable: true });
        }
        define(ns, "TemplateType", { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" });
        define(ns, "PermissionLevel", { GRANTED: "granted", DENIED: "denied" });
        define(api, "notifications", ns);
      }

      // idle: real inactivity and transitions come from the native side.
      if (provided.has("idle") && !api.idle) {
        const ns = {};
        let interval = 60;
        define(ns, "queryState", call(async (seconds) => {
          const threshold = Math.max(15, Number(seconds) || interval);
          return await bridge("idle.queryState", { threshold });
        }));
        define(ns, "setDetectionInterval", (seconds) => { interval = Math.max(15, Number(seconds) || 60); notify("idle.interval", { interval }); });
        define(ns, "getAutoLockDelay", call(async () => 0));
        registerEvent(ns, "onStateChanged", "idle.onStateChanged");
        define(ns, "IdleState", { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" });
        define(api, "idle", ns);
      }

      // privacy: every setting reads as not controllable by the extension.
      if (provided.has("privacy") && !api.privacy) {
        const setting = (name, value) => {
          const s = {};
          define(s, "get", call(async () => ({ value, levelOfControl: "not_controllable" })));
          define(s, "set", call(async () => { throw unsupported("privacy." + name + ".set"); }));
          define(s, "clear", call(async () => { throw unsupported("privacy." + name + ".clear"); }));
          registerEvent(s, "onChange", "privacy." + name + ".onChange");
          return s;
        };
        const group = (prefix, entries) => { const g = {}; for (const [name, value] of Object.entries(entries)) define(g, name, setting(prefix + "." + name, value)); return g; };
        const ns = {};
        define(ns, "services", group("services", { alternateErrorPagesEnabled: false, autofillEnabled: false, autofillAddressEnabled: false, autofillCreditCardEnabled: false,
          hotwordSearchEnabled: false, passwordSavingEnabled: false, safeBrowsingEnabled: false, safeBrowsingExtendedReportingEnabled: false, searchSuggestEnabled: false,
          spellingServiceEnabled: false, translationServiceEnabled: false }));
        define(ns, "network", group("network", { networkPredictionEnabled: false, webRTCIPHandlingPolicy: "default", peerConnectionEnabled: true, httpsOnlyMode: "never", globalPrivacyControl: false }));
        define(ns, "websites", group("websites", { thirdPartyCookiesAllowed: true, hyperlinkAuditingEnabled: false, referrersEnabled: true, doNotTrackEnabled: false,
          protectedContentEnabled: true, trackingProtectionMode: "private_browsing", cookieConfig: { behavior: "allow_all", nonPersistentCookies: false },
          firstPartyIsolate: false, resistFingerprinting: false, topicsEnabled: false, fledgeEnabled: false, adMeasurementEnabled: false, relatedWebsiteSetsEnabled: false }));
        define(api, "privacy", ns);
      }

      // management: only this extension is visible; nothing can be changed.
      if (provided.has("management") && !api.management) {
        const self = () => {
          const m = manifest();
          const id = (api.runtime && api.runtime.id) || "";
          return { id, name: String(m.name || ""), shortName: String(m.short_name || m.name || ""), description: String(m.description || ""),
                   version: String(m.version || ""), versionName: m.version_name ? String(m.version_name) : undefined, mayDisable: false, mayEnable: false,
                   enabled: true, type: "extension", installType: "development", isApp: false, icons: [], permissions: (m.permissions || []).filter((p) => typeof p === "string" && !p.includes("://") && !p.startsWith("<")),
                   hostPermissions: (m.host_permissions || []).concat((m.permissions || []).filter((p) => typeof p === "string" && (p.includes("://") || p.startsWith("<")))),
                   homepageUrl: m.homepage_url ? String(m.homepage_url) : undefined, optionsUrl: m.options_ui && m.options_ui.page ? api.runtime.getURL(m.options_ui.page) : (m.options_page ? api.runtime.getURL(m.options_page) : "") };
        };
        const ns = {};
        define(ns, "getSelf", call(async () => self()));
        define(ns, "getAll", call(async () => [self()]));
        define(ns, "get", call(async (id) => { const me = self(); if (id === me.id) return me; throw new Error("No extension with id " + id); }));
        define(ns, "getPermissionWarningsById", call(async () => []));
        define(ns, "getPermissionWarningsByManifest", call(async () => []));
        define(ns, "setEnabled", call(async () => { throw unsupported("management.setEnabled"); }));
        define(ns, "uninstall", call(async () => { throw unsupported("management.uninstall"); }));
        define(ns, "uninstallSelf", call(async () => { throw unsupported("management.uninstallSelf"); }));
        define(ns, "launchApp", call(async () => { throw unsupported("management.launchApp"); }));
        for (const name of ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]) registerEvent(ns, name, "management." + name);
        define(api, "management", ns);
      }

      // downloads: a download request is handed to Bam's own download handling.
      if (provided.has("downloads") && !api.downloads) {
        const ns = {};
        let nextDownload = 1;
        define(ns, "download", call(async (options) => {
          if (!options || typeof options.url !== "string") throw new Error("downloads.download needs a url.");
          const id = nextDownload++;
          await bridge("downloads.download", { id, url: options.url, filename: typeof options.filename === "string" ? options.filename : "", saveAs: !!options.saveAs });
          return id;
        }));
        define(ns, "search", call(async () => []));
        define(ns, "cancel", call(async () => { throw unsupported("downloads.cancel"); }));
        define(ns, "erase", call(async () => []));
        define(ns, "removeFile", call(async () => { throw unsupported("downloads.removeFile"); }));
        define(ns, "show", call(async () => false));
        define(ns, "showDefaultFolder", () => {});
        define(ns, "open", call(async () => { throw unsupported("downloads.open"); }));
        define(ns, "pause", call(async () => { throw unsupported("downloads.pause"); }));
        define(ns, "resume", call(async () => { throw unsupported("downloads.resume"); }));
        define(ns, "setShelfEnabled", () => {});
        if (!isWorker) for (const name of ["onCreated", "onErased", "onChanged", "onDeterminingFilename"]) registerEvent(ns, name, "downloads." + name);
        define(ns, "State", { IN_PROGRESS: "in_progress", INTERRUPTED: "interrupted", COMPLETE: "complete" });
        define(ns, "InterruptReason", {});
        define(api, "downloads", ns);
      }

      // offscreen: one hidden page of this extension, hosted by Bam in the same profile.
      // Outcomes arrive as {value} or {error} so Chrome's exact messages are preserved.
      const offscreenRequest = async (method, params) => {
        const result = await bridge("offscreen." + method, params);
        if (result && typeof result === "object" && typeof result.error === "string") throw new Error(result.error);
        return result && typeof result === "object" ? result.value : undefined;
      };
      if (provided.has("offscreen") && !api.offscreen) {
        const ns = {};
        const reasons = ["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA", "DISPLAY_MEDIA",
                         "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"];
        define(ns, "createDocument", call(async (parameters) => {
          if (!parameters || typeof parameters !== "object") throw new TypeError("offscreen.createDocument requires parameters.");
          const { url, reasons: requested, justification } = parameters;
          if (typeof url !== "string") throw new TypeError("offscreen.createDocument requires a url.");
          if (!Array.isArray(requested) || requested.some((reason) => typeof reason !== "string")) throw new TypeError("offscreen.createDocument requires a reasons array.");
          if (typeof justification !== "string") throw new TypeError("offscreen.createDocument requires a justification.");
          await offscreenRequest("createDocument", { url, reasons: requested.slice(), justification });
        }));
        define(ns, "closeDocument", call(async () => { await offscreenRequest("closeDocument", null); }));
        define(ns, "hasDocument", call(async () => (await offscreenRequest("hasDocument", null)) === true));
        define(ns, "Reason", Object.freeze(Object.fromEntries(reasons.map((reason) => [reason, reason]))));
        define(api, "offscreen", ns);
      }

      // commands: manifest commands are listed; keyboard dispatch is not provided.
      if (provided.has("commands") && !api.commands) {
        const ns = {};
        define(ns, "getAll", call(async () => Object.entries(manifest().commands || {}).map(([name, c]) => ({ name, description: String((c && c.description) || ""), shortcut: "" }))));
        define(ns, "update", call(async () => {}));
        define(ns, "reset", call(async () => {}));
        define(ns, "openShortcutSettings", call(async () => {}));
        registerEvent(ns, "onCommand", "commands.onCommand");
        define(api, "commands", ns);
      }

      // storage.managed: no enterprise policy store exists; reads are empty.
      let managedStorage = null;
      if (provided.has("storage.managed") && api.storage && !api.storage.managed) {
        const ns = {};
        define(ns, "get", call(async (keys) => {
          if (keys && typeof keys === "object" && !Array.isArray(keys)) return { ...keys };
          return {};
        }));
        define(ns, "getBytesInUse", call(async () => 0));
        define(ns, "getKeys", call(async () => []));
        for (const op of ["set", "remove", "clear"]) define(ns, op, call(async () => { throw new Error("storage.managed is read-only."); }));
        registerEvent(ns, "onChanged", "storage.managed.onChanged");
        managedStorage = ns;
      }

      // Members added to WebKit's own namespaces. WebKit can hand the page a
      // fresh namespace object after document start (observed with 1Password's
      // HTML background page, where webNavigation lost members added at start),
      // so each member is defined on the instance and its prototype and
      // re-applied for a while after load. Events are cached so listeners persist.
      const extensions = [], extensionValues = {};
      const extend = (ns, name, make) => extensions.push({ ns, name, make });
      const extensionEvent = (ns, name) => () => { const fullName = ns + "." + name; const e = event(fullName); compat.events[fullName] = e; return e; };
      // WebKit's namespace wrappers appear to be weakly cached: once nothing in
      // the page references them they are collected and rebuilt without the
      // members added here. Holding them keeps the same objects alive.
      const held = {};
      const applyExtensions = () => {
        let missing = false;
        for (const x of extensions) {
          const holder = api[x.ns];
          if (!holder) { missing = true; continue; }
          if (held[x.ns] !== holder) { held[x.ns] = holder; held[x.ns + ".prototype"] = Object.getPrototypeOf(holder); }
          if (holder[x.name] !== undefined) continue;
          const key = x.ns + "." + x.name;
          const value = extensionValues[key] || (extensionValues[key] = x.make());
          try { define(holder, x.name, value); } catch (error) {}
          const proto = Object.getPrototypeOf(holder);
          if (proto && proto !== Object.prototype && proto[x.name] === undefined) { try { define(proto, x.name, value); } catch (error) {} }
          compat.reapplied.push(key + "@" + Math.round(performance.now()));
        }
        return !missing;
      };
      compat.reapplied = []; compat.held = held;
      // Keep WebKit's weakly cached storage wrapper alive just like runtime and
      // webNavigation, and share the same managed object/event across wrappers.
      if (managedStorage) extend("storage", "managed", () => managedStorage);
      if (provided.has("runtime.getBrowserInfo")) extend("runtime", "getBrowserInfo", () => call(async () => ({ name: "Bam", vendor: "Bam", version, buildID: "" })));
      if (provided.has("runtime.onSuspend")) for (const name of ["onSuspend", "onSuspendCanceled", "onRestartRequired"]) extend("runtime", name, extensionEvent("runtime", name));
      if (provided.has("runtime.requestUpdateCheck")) extend("runtime", "requestUpdateCheck", () => call(async () => { const value = ["no_update", { version: String(manifest().version || "") }]; value.__bamSpread = true; return value; }));
      // Only the offscreen document Bam hosts is reported; other contexts are not enumerated.
      if (provided.has("runtime.getContexts")) extend("runtime", "getContexts", () => call(async (filter) => {
        if (filter !== undefined && (filter === null || typeof filter !== "object")) throw new TypeError("runtime.getContexts requires a filter object.");
        if (!provided.has("offscreen")) return [];
        // Without a reviewed offscreen grant this stays the earlier empty answer.
        const contexts = await offscreenRequest("contexts", null).catch(() => []);
        const matches = (key, value) => !filter || !Array.isArray(filter[key]) || filter[key].includes(value);
        return (Array.isArray(contexts) ? contexts : []).filter((c) => matches("contextTypes", c.contextType) && matches("contextIds", c.contextId) &&
          matches("documentIds", c.documentId) && matches("documentUrls", c.documentUrl) && matches("documentOrigins", c.documentOrigin) &&
          matches("tabIds", c.tabId) && matches("windowIds", c.windowId) && matches("frameIds", c.frameId) &&
          (!filter || typeof filter.incognito !== "boolean" || filter.incognito === c.incognito));
      }));
      if (provided.has("runtime.getContexts")) extend("runtime", "ContextType", () => Object.freeze({ TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" }));
      extend("runtime", "restart", () => () => {});
      extend("runtime", "restartAfterDelay", () => call(async () => {}));
      if (provided.has("webNavigation.onCreatedNavigationTarget")) {
        for (const name of ["onCreatedNavigationTarget", "onHistoryStateUpdated", "onReferenceFragmentUpdated", "onTabReplaced"]) extend("webNavigation", name, extensionEvent("webNavigation", name));
      }
      if (provided.has("action.getUserSettings")) {
        for (const ns of ["action", "browserAction"]) extend(ns, "getUserSettings", () => call(async () => ({ isOnToolbar: false })));
      }
      applyExtensions();
      if (!isWorker) {
        const started = performance.now();
        const tick = () => {
          applyExtensions();
          const elapsed = performance.now() - started;
          if (elapsed > 60000) return;
          setTimeout(tick, elapsed < 1500 ? 5 : elapsed < 15000 ? 50 : 500);
        };
        queueMicrotask(applyExtensions);
        setTimeout(tick, 0);
        document.addEventListener("DOMContentLoaded", applyExtensions, { once: true });
        globalThis.addEventListener("load", applyExtensions, { once: true });
      }
      Object.defineProperty(api, "__bamCompatibility", { value: compat, enumerable: false, configurable: false });
      Object.defineProperty(globalThis, "__bamCompatibility", { value: compat, enumerable: false, configurable: false });
      notify("hello", { url: location.href, provided: Array.from(provided), namespaces: Object.getOwnPropertyNames(api).filter(k => k !== "__bamCompatibility").join(","), webNavigation: typeof api.webNavigation, ready: isWorker ? "worker" : document.readyState });
      }
    })();
    """#
}

/// The native side of the layer, owned by one profile runtime. It injects the
/// script for each loaded context, authenticates every message against the
/// context that owns the sending document, and delivers events back.
@available(macOS 15.4, *)
@MainActor final class ExtensionCompatibilityBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    struct Download { let id: Int; let url: URL; let filename: String; let saveAs: Bool }
    let handlerName: String
    private weak var controller: WKWebExtensionController?
    private weak var dataStore: WKWebsiteDataStore?
    private weak var contentController: WKUserContentController?
    private var scripts: [String: WKUserScript] = [:]
    private struct Registration { weak var context: WKWebExtensionContext?; let plan: ExtensionCompatibility.Plan }
    private struct EventConnection { let port: WKWebExtension.MessagePort; var events: Set<String> = [] }
    private var registrations: [String: Registration] = [:]
    private var eventConnections: [String: [ObjectIdentifier: EventConnection]] = [:]
    private var idleIntervals: [String: Double] = [:]
    private var idleStates: [String: String] = [:]
    private var idleTimer: Timer?
    /// Injectable clock for deterministic inactivity tests; production reads real input inactivity.
    var idleSeconds: () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    /// The extension document that registered last for each loaded context, by
    /// unique identifier: popups come and go, the background page persists.
    /// A frame that ran the layer. Replies and events are evaluated in that
    /// frame, never in the main frame on its behalf, and dead views are dropped.
    private struct Document { weak var web: WKWebView?; let frame: WKFrameInfo; var isLive: Bool { web?.url != nil } }
    private var documents: [String: [Document]] = [:]
    private var notificationOwners: [String: String] = [:]
    /// Diagnostics per context: documents that reported in, and any failure of the layer itself.
    private var helloURLs: [String: [String]] = [:]
    private var scriptErrors: [String: [String]] = [:]
    private static func appendDiagnostic(_ value: String, for key: String, to entries: inout [String: [String]], limit: Int) {
        guard (entries[key]?.count ?? 0) < limit else { return }
        // Scalar counting also bounds pathological combining-character strings.
        entries[key, default: []].append(String(String.UnicodeScalarView(value.unicodeScalars.prefix(1_200))))
    }
    /// Diagnostic only: evaluates a script in every extension document that reported in.
    func evaluate(_ script: String, for context: WKWebExtensionContext) async -> [String] {
        var results: [String] = []
        for document in documents[context.uniqueIdentifier] ?? [] {
            guard let web = document.web, document.isLive else { continue }
            do { results.append(Self.json(try await web.evaluateJavaScript(script, in: document.frame, contentWorld: .page) ?? NSNull())) }
            catch { results.append("error: \(error.localizedDescription)") }
        }
        return results
    }
    func diagnostics(for context: WKWebExtensionContext) -> [String: Any] {
        ["installed": scripts[context.uniqueIdentifier] != nil, "documents": helloURLs[context.uniqueIdentifier] ?? [], "script_errors": scriptErrors[context.uniqueIdentifier] ?? []]
    }
    /// Hidden extension documents for `chrome.offscreen`, one per loaded context.
    private(set) var offscreen: ExtensionOffscreenDocuments<WKWebView>!
    private var offscreenLoaders: [ObjectIdentifier: OffscreenLoader] = [:]
    /// Supplied by the host: start a download from an extension document.
    var startDownload: ((WKWebView, Download) -> Bool)?
    /// The host may resolve a live page belonging to this exact worker context.
    var workerDownload: ((WKWebExtensionContext, Download) -> Bool)?
    /// Live, persisted review grants supplied by the owner. Unknown WebKit
    /// permission names are never inferred to be approved from API availability.
    var permissionGranted: ((WKWebExtensionContext, String) -> Bool)?
    /// Supplied by the host: the identifier for notifications posted on behalf of an extension.
    var notificationIdentifier: ((String) -> String?)?
    /// Returns a delivery error, or nil when the notification was posted natively.
    var postNotification: ((String, String, String, [String], @MainActor () -> Bool) async -> String?)?
    var isNotificationDeliveryAvailable: (() -> Bool)?
    let browserVersion: String

    init(controller: WKWebExtensionController, dataStore: WKWebsiteDataStore, contentController: WKUserContentController, browserVersion: String) {
        self.controller = controller; self.dataStore = dataStore; self.contentController = contentController; self.browserVersion = browserVersion
        handlerName = "bamCompatibility" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        super.init()
        contentController.add(self, contentWorld: .page, name: handlerName)
        offscreen = ExtensionOffscreenDocuments(load: { [weak self] owner, url in
            guard let self else { throw ExtensionOffscreenDocuments<WKWebView>.Failure(description: "Extensions are shutting down.") }
            return try await self.loadOffscreen(owner: owner, url: url)
        }, discard: { [weak self] web in
            self?.offscreenLoaders.removeValue(forKey: ObjectIdentifier(web))
            web.navigationDelegate = nil; web.stopLoading()
        })
    }

    /// Loads an extension page in a hidden web view built from the context's own
    /// configuration, so it is an ordinary extension page to WebKit (messaging,
    /// storage and this layer) in the same profile store. It is never shown.
    private func loadOffscreen(owner: String, url: URL) async throws -> WKWebView {
        guard let context = registrations[owner]?.context, ownsRegisteredContext(context),
              BrowserExtensions.isExtensionURL(url, ownedBy: context), let configuration = context.webViewConfiguration else {
            throw ExtensionOffscreenDocuments<WKWebView>.Failure(description: "Offscreen documents must be pages of this extension.")
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loader = OffscreenLoader(baseURL: context.baseURL)
        loader.terminated = { [weak self, weak web] in
            guard let self, let web else { return }
            self.offscreen.documentEnded(web, owner: owner)
        }
        offscreenLoaders[ObjectIdentifier(web)] = loader
        web.navigationDelegate = loader
        do { try await loader.load(url, in: web); return web }
        catch { offscreenLoaders.removeValue(forKey: ObjectIdentifier(web)); web.navigationDelegate = nil; web.stopLoading(); throw error }
    }
    /// Revoked grants close the extension's hidden document immediately.
    func revoke(_ context: WKWebExtensionContext) { offscreen.discard(owner: context.uniqueIdentifier) }

    func install(_ plan: ExtensionCompatibility.Plan, for context: WKWebExtensionContext) {
        guard !plan.isEmpty, let contentController else { return }
        registrations[context.uniqueIdentifier] = Registration(context: context, plan: plan)
        let script = WKUserScript(source: ExtensionCompatibility.script(baseURL: context.baseURL, bridge: handlerName, plan: plan, browserVersion: browserVersion),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        scripts[context.uniqueIdentifier] = script
        contentController.addUserScript(script)
    }
    func remove(_ context: WKWebExtensionContext) {
        offscreen.discard(owner: context.uniqueIdentifier)
        documents.removeValue(forKey: context.uniqueIdentifier)
        registrations.removeValue(forKey: context.uniqueIdentifier)
        helloURLs.removeValue(forKey: context.uniqueIdentifier)
        scriptErrors.removeValue(forKey: context.uniqueIdentifier)
        let ports = eventConnections.removeValue(forKey: context.uniqueIdentifier)?.values.map(\.port) ?? []
        for port in ports { port.disconnect() }
        idleIntervals.removeValue(forKey: context.uniqueIdentifier); idleStates.removeValue(forKey: context.uniqueIdentifier)
        updateIdleTimer()
        guard scripts.removeValue(forKey: context.uniqueIdentifier) != nil, let contentController else { return }
        contentController.removeAllUserScripts()
        for script in scripts.values { contentController.addUserScript(script) }
    }
    func shutdown() {
        offscreen.discardAll()
        idleTimer?.invalidate(); idleTimer = nil
        let ports = eventConnections.values.flatMap { $0.values.map(\.port) }
        eventConnections.removeAll(); registrations.removeAll(); idleIntervals.removeAll(); idleStates.removeAll()
        for port in ports { port.disconnect() }
        contentController?.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
        contentController?.removeAllUserScripts()
        scripts.removeAll(); documents.removeAll()
        helloURLs.removeAll(); scriptErrors.removeAll()
    }

    private func ownsRegisteredContext(_ context: WKWebExtensionContext) -> Bool {
        guard let controller else { return false }
        return context.isLoaded && context.webExtensionController === controller &&
            registrations[context.uniqueIdentifier]?.context === context && controller.extensionContext(for: context.baseURL) === context
    }
    private func permits(_ namespace: String, for context: WKWebExtensionContext) -> Bool {
        guard ownsRegisteredContext(context), registrations[context.uniqueIdentifier]?.plan.provided.contains(namespace) == true,
              permissionGranted?(context, namespace) == true else { return false }
        // Optional shim capabilities are not silently granted. They need a future
        // explicit permission store/review flow before becoming available.
        return (context.webExtension.manifest["permissions"] as? [String] ?? []).contains(namespace)
    }
    private static let eventPermissions = ["notifications.onClosed": "notifications", "notifications.onClicked": "notifications",
        "notifications.onButtonClicked": "notifications", "notifications.onShown": "notifications", "idle.onStateChanged": "idle"]
    private static func bridgeError(_ message: String) -> NSError {
        NSError(domain: "Bam.ExtensionCompatibility", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Called only for the Bam application identifier by the runtime delegate.
    /// Context identity is supplied by WebKit, never by an untrusted message field.
    func receiveNativeMessage(_ message: Any, context: WKWebExtensionContext) async -> (Any?, Error?) {
        guard ownsRegisteredContext(context), let body = message as? [String: Any],
              JSONSerialization.isValidJSONObject(body), let bytes = try? JSONSerialization.data(withJSONObject: body), bytes.count <= 65_536,
              let kind = body["kind"] as? String else { return (nil, Self.bridgeError("Invalid or inactive compatibility request.")) }
        switch kind {
        case "hello":
            if let url = body["url"] as? String, let parsed = URL(string: url), BrowserExtensions.isExtensionURL(parsed, ownedBy: context) {
                Self.appendDiagnostic("\(url) ready=worker", for: context.uniqueIdentifier, to: &helloURLs, limit: 20)
            }
            return (true, nil)
        case "scriptError":
            Self.appendDiagnostic(body["message"] as? String ?? "Worker compatibility error", for: context.uniqueIdentifier, to: &scriptErrors, limit: 10)
            return (true, nil)
        case "idle.interval":
            guard permits("idle", for: context) else { return (nil, Self.bridgeError("The extension has not declared idle access.")) }
            setIdleInterval((body["interval"] as? Double) ?? 60, for: context)
            return (true, nil)
        case "request":
            guard let method = body["method"] as? String else { return (nil, Self.bridgeError("A compatibility method is required.")) }
            let (value, error) = await handle(method: method, params: body["params"] as? [String: Any] ?? [:], context: context, web: nil)
            return (value, error.map(Self.bridgeError))
        default: return (nil, Self.bridgeError("Unknown compatibility request."))
        }
    }

    /// A native port exists only while extension code subscribes to real events.
    func connectNativePort(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext) -> Error? {
        guard ownsRegisteredContext(context), port.applicationIdentifier == ExtensionCompatibility.nativeApplicationIdentifier else {
            return Self.bridgeError("This compatibility connection is not authorized.")
        }
        let key = context.uniqueIdentifier, identifier = ObjectIdentifier(port)
        eventConnections[key, default: [:]][identifier] = EventConnection(port: port)
        port.messageHandler = { [weak self, weak context, weak port] message, error in
            guard let self, let context, let port, error == nil, self.ownsRegisteredContext(context),
                  let body = message as? [String: Any], let kind = body["kind"] as? String,
                  let event = body["event"] as? String, let permission = Self.eventPermissions[event], self.permits(permission, for: context) else {
                port?.disconnect(throwing: Self.bridgeError("This event subscription is not authorized.")); return
            }
            guard var connection = self.eventConnections[key]?[identifier] else { return }
            if kind == "subscribe" {
                connection.events.insert(event)
                if event == "idle.onStateChanged" { self.setIdleInterval(self.idleIntervals[key] ?? 60, for: context) }
            } else if kind == "unsubscribe" { connection.events.remove(event) }
            else { port.disconnect(throwing: Self.bridgeError("Unknown event subscription.")); return }
            self.eventConnections[key]?[identifier] = connection
        }
        port.disconnectHandler = { [weak self] _ in
            self?.eventConnections[key]?.removeValue(forKey: identifier)
        }
        return nil
    }
    private func setIdleInterval(_ interval: Double, for context: WKWebExtensionContext) {
        let seconds = interval.isFinite ? min(86_400, max(15, interval)) : 60
        idleIntervals[context.uniqueIdentifier] = seconds
        if idleStates[context.uniqueIdentifier] == nil { idleStates[context.uniqueIdentifier] = idleSeconds() >= seconds ? "idle" : "active" }
        updateIdleTimer()
    }
    private func updateIdleTimer() {
        if idleIntervals.isEmpty { idleTimer?.invalidate(); idleTimer = nil; return }
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollIdle() }
        }
    }
    func pollIdle() {
        let elapsed = idleSeconds()
        for (key, threshold) in idleIntervals {
            guard let context = registrations[key]?.context, permits("idle", for: context) else { continue }
            let state = elapsed >= threshold ? "idle" : "active"
            if idleStates[key] != state { idleStates[key] = state; dispatch("idle.onStateChanged", [state], to: key) }
        }
    }

    /// The owning context for a message, or nil when any part of its provenance fails.
    private func authenticate(_ message: WKScriptMessage) -> WKWebExtensionContext? {
        guard let controller, let dataStore, let contentController,
              message.name == handlerName, message.world === WKContentWorld.page,
              let web = message.webView, message.frameInfo.webView === web,
              web.configuration.webExtensionController === controller,
              web.configuration.websiteDataStore === dataStore,
              web.configuration.userContentController === contentController,
              let url = message.frameInfo.request.url,
              let context = controller.extensionContext(for: url), context.isLoaded,
              BrowserExtensions.isExtensionURL(url, ownedBy: context),
              message.frameInfo.securityOrigin.protocol == context.baseURL.scheme,
              message.frameInfo.securityOrigin.host == context.baseURL.host,
              ownsRegisteredContext(context) else { return nil }
        return context
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let context = authenticate(message), let web = message.webView, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        let key = context.uniqueIdentifier
        switch kind {
        case "hello":
            let frame = message.frameInfo
            var list = (documents[key] ?? []).filter(\.isLive)
            list.removeAll { $0.web === web && $0.frame.isMainFrame == frame.isMainFrame && $0.frame.request.url == frame.request.url }
            list.append(Document(web: web, frame: frame))
            documents[key] = list
            if permits("idle", for: context) { setIdleInterval(idleIntervals[key] ?? 60, for: context) }
            if let url = body["url"] as? String {
                Self.appendDiagnostic("\(url) ready=\(body["ready"] as? String ?? "?") webNavigation=\(body["webNavigation"] as? String ?? "?") namespaces=\(body["namespaces"] as? String ?? "?")", for: key, to: &helloURLs, limit: 20)
            }
        case "scriptError":
            let text = "\(body["message"] as? String ?? "?") @ \(body["url"] as? String ?? "?") \((body["stack"] as? String ?? "").prefix(600))"
            Self.appendDiagnostic(text, for: key, to: &scriptErrors, limit: 10)
        case "request":
            guard let id = body["id"] as? Int, let method = body["method"] as? String else { return }
            let params = body["params"] as? [String: Any] ?? [:]
            let frame = message.frameInfo
            Task { @MainActor [weak self, weak web] in
                guard let self else { return }
                let (value, error) = await self.handle(method: method, params: params, context: context, web: web)
                guard let web else { return }
                self.reply(web, frame: frame, id: id, value: value, error: error)
            }
        case "idle.interval":
            if permits("idle", for: context) { setIdleInterval((body["interval"] as? Double) ?? 60, for: context) }
        default: break
        }
    }

    private func handle(method: String, params: [String: Any], context: WKWebExtensionContext, web: WKWebView?) async -> (Any?, String?) {
        let methods = ["idle.queryState": "idle", "notifications.permissionLevel": "notifications", "notifications.create": "notifications",
                       "notifications.clear": "notifications", "downloads.download": "downloads",
                       "offscreen.createDocument": "offscreen", "offscreen.closeDocument": "offscreen", "offscreen.hasDocument": "offscreen", "offscreen.contexts": "offscreen"]
        guard let permission = methods[method], permits(permission, for: context) else { return (nil, "This compatibility capability is not available to the extension.") }
        switch method {
        case "idle.queryState":
            let threshold = max(15, (params["threshold"] as? Double) ?? 60)
            let idle = idleSeconds()
            return (idle >= threshold ? "idle" : "active", nil)
        case "notifications.permissionLevel":
            return (isNotificationDeliveryAvailable?() == true ? "granted" : "denied", nil)
        case "notifications.create":
            guard let id = params["id"] as? String, let post = postNotification else { return (nil, "Notifications are not delivered natively in this build.") }
            let title = params["title"] as? String ?? "", message = params["message"] as? String ?? ""
            let buttons = params["buttons"] as? [String] ?? []
            let identifier = Self.notificationIdentifier(context: context, id: id)
            notificationOwners[identifier] = context.uniqueIdentifier
            if let failure = await post(identifier, title.isEmpty ? (context.webExtension.displayName ?? "Extension") : title, message, buttons, { [weak self, weak context] in
                guard let self, let context else { return false }
                return self.permits("notifications", for: context)
            }) {
                notificationOwners.removeValue(forKey: identifier)
                return (nil, failure)
            }
            dispatch("notifications.onShown", [id], to: context.uniqueIdentifier)
            return (true, nil)
        case "notifications.clear":
            guard let id = params["id"] as? String else { return (false, nil) }
            let identifier = Self.notificationIdentifier(context: context, id: id)
            notificationOwners.removeValue(forKey: identifier)
            ExtensionNotificationCenter.shared.forget(identifier)
            if Self.canUseNotificationCenter {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            }
            return (true, nil)
        case "downloads.download":
            guard let id = params["id"] as? Int, let raw = params["url"] as? String, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return (nil, "Only HTTP(S) URLs can be downloaded through Bam.") }
            let download = Download(id: id, url: url, filename: params["filename"] as? String ?? "", saveAs: params["saveAs"] as? Bool ?? false)
            let started = web.map { startDownload?($0, download) == true } ?? (workerDownload?(context, download) == true)
            guard started else { return (nil, "Open a page in this extension's profile to start the download.") }
            return (true, nil)
        case "offscreen.createDocument", "offscreen.closeDocument", "offscreen.hasDocument", "offscreen.contexts":
            // Outcomes travel as values so Chrome's exact messages survive WebKit's
            // native-message error wrapping; the adapter rethrows them unchanged.
            let owner = context.uniqueIdentifier
            do {
                switch method {
                case "offscreen.createDocument":
                    let url = try ExtensionOffscreenDocuments<WKWebView>.validate(url: params["url"] as? String ?? "", reasons: params["reasons"] as? [String] ?? [],
                                                                                 justification: params["justification"] as? String ?? "", baseURL: context.baseURL)
                    try await offscreen.create(owner: owner, url: url)
                    return (["value": NSNull()], nil)
                case "offscreen.closeDocument": try offscreen.close(owner: owner); return (["value": NSNull()], nil)
                case "offscreen.hasDocument": return (["value": offscreen.has(owner)], nil)
                default:
                    guard let entry = offscreen.entry(for: owner) else { return (["value": [Any]()], nil) }
                    let origin = context.baseURL.absoluteString.hasSuffix("/") ? String(context.baseURL.absoluteString.dropLast()) : context.baseURL.absoluteString
                    return (["value": [["contextType": "OFFSCREEN_DOCUMENT", "contextId": entry.id.uuidString, "documentId": entry.id.uuidString,
                                        "documentUrl": entry.url.absoluteString, "documentOrigin": origin, "tabId": -1, "windowId": -1, "frameId": 0,
                                        "incognito": dataStore?.isPersistent == false]]], nil)
                }
            } catch let failure as ExtensionOffscreenDocuments<WKWebView>.Failure {
                return (["error": failure.description], nil)
            } catch { return (["error": error.localizedDescription], nil) }
        default:
            return (nil, "Unknown compatibility request.")
        }
    }

    private func reply(_ web: WKWebView, frame: WKFrameInfo, id: Int, value: Any?, error: String?) {
        let encodedValue = Self.json(value ?? NSNull()), encodedError = Self.json(error ?? NSNull())
        web.evaluateJavaScript("globalThis.__bamCompatibility && globalThis.__bamCompatibility.resolve(\(id), \(encodedValue), \(encodedError));", in: frame, in: .page) { _ in }
    }

    /// Delivers an event to every live document of one extension.
    func dispatch(_ event: String, _ arguments: [Any], to uniqueIdentifier: String) {
        guard let context = registrations[uniqueIdentifier]?.context,
              let permission = Self.eventPermissions[event], permits(permission, for: context) else { return }
        let script = "globalThis.__bamCompatibility && globalThis.__bamCompatibility.dispatch(\(Self.json(event)), \(Self.json(arguments)));"
        documents[uniqueIdentifier]?.removeAll { !$0.isLive }
        for document in documents[uniqueIdentifier] ?? [] { document.web?.evaluateJavaScript(script, in: document.frame, in: .page) { _ in } }
        for connection in eventConnections[uniqueIdentifier]?.values ?? Dictionary<ObjectIdentifier, EventConnection>().values where connection.events.contains(event) {
            connection.port.sendMessage(["event": event, "args": arguments]) { _ in }
        }
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }
    static func notificationIdentifier(context: WKWebExtensionContext, id: String) -> String { "bam-extension:\(context.uniqueIdentifier):\(id)" }
    static func parseNotificationIdentifier(_ identifier: String) -> (context: String, id: String)? {
        let parts = identifier.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "bam-extension" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
    /// UNUserNotificationCenter aborts outside a proper app bundle, which is where
    /// test binaries and worktree executables run; deliver nothing there.
    static var canUseNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.url(forResource: "Info", withExtension: "plist") != nil
    }

    // MARK: Notification responses
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier, action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let parsed = Self.parseNotificationIdentifier(identifier), self.notificationOwners[identifier] == parsed.context else { return }
            switch action {
            case UNNotificationDefaultActionIdentifier: self.dispatch("notifications.onClicked", [parsed.id], to: parsed.context)
            case UNNotificationDismissActionIdentifier: self.dispatch("notifications.onClosed", [parsed.id, true], to: parsed.context)
            default:
                if action.hasPrefix("bam-button-"), let index = Int(action.dropFirst("bam-button-".count)) {
                    self.dispatch("notifications.onButtonClicked", [parsed.id, index], to: parsed.context)
                }
            }
            self.notificationOwners.removeValue(forKey: identifier)
            ExtensionNotificationCenter.shared.forget(identifier)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// App-wide notification delivery shared by every profile runtime. One center
/// delegate routes responses to the bridge that posted the notification.
@available(macOS 15.4, *)
@MainActor final class ExtensionNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ExtensionNotificationCenter()
    private var bridges: [ObjectIdentifier: ExtensionCompatibilityBridge] = [:]
    private var authorization: Bool?
    func register(_ bridge: ExtensionCompatibilityBridge) {
        bridges[ObjectIdentifier(bridge)] = bridge
        guard ExtensionCompatibilityBridge.canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().delegate = self
        let category = UNNotificationCategory(identifier: "bam-extension", actions: [UNNotificationAction(identifier: "bam-button-0", title: "Open", options: [.foreground])], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    func unregister(_ bridge: ExtensionCompatibilityBridge) { bridges.removeValue(forKey: ObjectIdentifier(bridge)) }
    /// Drops the per-notification button category once the notification is gone.
    func forget(_ identifier: String) {
        guard ExtensionCompatibilityBridge.canUseNotificationCenter else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let existing = await center.notificationCategories()
            let pruned = existing.filter { $0.identifier != "bam-extension-\(identifier)" }
            if pruned.count != existing.count { center.setNotificationCategories(pruned) }
        }
    }
    var isAvailable: Bool { ExtensionCompatibilityBridge.canUseNotificationCenter && authorization != false }
    func post(identifier: String, title: String, body: String, buttons: [String], isAuthorized: @MainActor () -> Bool) async -> String? {
        let revoked = "The extension no longer has permission to post notifications."
        guard isAuthorized() else { return revoked }
        guard ExtensionCompatibilityBridge.canUseNotificationCenter else { return "Notifications need the installed Bam app." }
        let center = UNUserNotificationCenter.current()
        if authorization == nil {
            authorization = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard isAuthorized() else { return revoked }
        guard authorization == true else { return "Notifications are not allowed for Bam in System Settings." }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if !buttons.isEmpty {
            let actions = buttons.enumerated().map { UNNotificationAction(identifier: "bam-button-\($0.offset)", title: $0.element.isEmpty ? "Open" : $0.element, options: [.foreground]) }
            let category = UNNotificationCategory(identifier: "bam-extension-\(identifier)", actions: actions, intentIdentifiers: [])
            let existing = await center.notificationCategories()
            guard isAuthorized() else { return revoked }
            center.setNotificationCategories(existing.union([category]))
            content.categoryIdentifier = category.identifier
        }
        guard isAuthorized() else { return revoked }
        do { try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) } catch { return error.localizedDescription }
        guard isAuthorized() else {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            forget(identifier)
            return revoked
        }
        return nil
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let group = DispatchGroup()
            for bridge in self.bridges.values { group.enter(); bridge.userNotificationCenter(center, didReceive: response) { group.leave() } }
            group.notify(queue: .main) { completionHandler() }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Awaits one hidden offscreen document's first load and keeps its main frame on
/// the extension's own origin. Subframes (IFRAME_SCRIPTING) may load other sites.
@available(macOS 15.4, *)
@MainActor final class OffscreenLoader: NSObject, WKNavigationDelegate {
    static let timeout: UInt64 = 30_000_000_000
    let baseURL: URL
    var terminated: (() -> Void)?
    private var pending: CheckedContinuation<Void, Error>?
    init(baseURL: URL) { self.baseURL = baseURL }
    private static func failure(_ message: String) -> Error { ExtensionOffscreenDocuments<WKWebView>.Failure(description: message) }

    func load(_ url: URL, in web: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = continuation
            web.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeout)
                self?.finish(Self.failure("The offscreen document did not finish loading."))
            }
        }
    }
    private func finish(_ error: Error?) {
        guard let continuation = pending else { return }
        pending = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == baseURL.scheme && url?.host == baseURL.host ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if pending != nil { finish(Self.failure("The offscreen document stopped while loading.")) } else { terminated?() }
    }
}
