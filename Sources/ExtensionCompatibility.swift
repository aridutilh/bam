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
    static let bridgedPermissions: [String] = ["notifications", "idle", "privacy", "management", "downloads", "offscreen", "fontSettings", "bookmarks", "history"]
    /// Members the layer always offers when the host namespace exists but the member does not.
    static let runtimeExtras: [String] = ["runtime.getBrowserInfo", "runtime.onSuspend", "runtime.requestUpdateCheck", "runtime.getContexts",
                                          "webNavigation.onCreatedNavigationTarget", "storage.managed", "commands", "action.getUserSettings",
                                          "scripting.ExecutionWorld", "runtime.onUpdateAvailable", "windows.onBoundsChanged"]

    /// Computes what the layer will define for a parsed extension, from its manifest.
    static func plan(manifest: [String: Any]) -> Plan {
        var requested: [String] = []
        // Optional permissions stay undefined until granted, as in Firefox; WebKit
        // cannot grant a permission it does not know, so they are never provided.
        for case let value as String in manifest["permissions"] as? [Any] ?? [] { requested.append(value) }
        var plan = Plan()
        for permission in bridgedPermissions where requested.contains(permission) { plan.provided.append(permission) }
        // The tab metadata facade is installed for extensions that declare `tabs` (required or optional); the native
        // side still answers only while `tabs` is granted to that exact live context.
        let optional = (manifest["optional_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        if requested.contains("tabs") || optional.contains("tabs") { plan.provided.append("tabs.metadata") }
        plan.provided += runtimeExtras
        return plan
    }

    /// Names shown in the permission review for a bridged permission list.
    static func reviewLabel(_ permissions: [String]) -> String {
        permissions.map {
            switch $0 {
            case "bookmarks": return "bookmarks (read-only: getTree of this profile's Favorites and kept tabs; no changes or events)"
            case "history": return "history (read-only: search this profile's history and hear new visits and clearing; no adding or deleting)"
            case "tabs.metadata": return "tab addresses and titles (requires the tabs permission; no page-content access)"
            default: return $0
            }
        }
            .joined(separator: ", ")
    }

    /// Builds the document-start script for one extension context.
    static func script(baseURL: URL, bridge: String, plan: Plan, browserVersion: String) -> String {
        let origin = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let provided = (try? JSONSerialization.data(withJSONObject: plan.provided)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return source
            .replacingOccurrences(of: "__ORIGIN__", with: javaScriptString(origin))
            .replacingOccurrences(of: "__WORKER__", with: "false")
            .replacingOccurrences(of: "__PAGE_ENVIRONMENT__", with: ExtensionIdleCallbackCompatibility.source)
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
            .replacingOccurrences(of: "__PAGE_ENVIRONMENT__", with: "")
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
      __PAGE_ENVIRONMENT__
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
      const nativeEvents = new Set(["notifications.onClosed", "notifications.onClicked", "notifications.onButtonClicked", "notifications.onShown", "idle.onStateChanged", "windows.onBoundsChanged", "history.onVisited", "history.onVisitRemoved"]);
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
      // Chrome reports a callback-form failure through runtime.lastError. WebKit's runtime.lastError is
      // a native attribute that Bam cannot set (measured: it stays null in pages and workers), so a
      // failed shimmed call logs the error and calls back without arguments; the promise form rejects.
      // Callback or promise, matching WebKit's dual-style APIs.
      const call = (fn) => function (...args) {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = Promise.resolve().then(() => fn.apply(this, args));
        if (!callback) return promise;
        promise.then((value) => { try { Array.isArray(value) && value.__bamSpread ? callback(...value) : callback(value); } catch (error) { console.error(error); } },
                     (error) => { console.error("[Bam compatibility]", error); try { callback(); } catch (inner) { console.error(inner); } });
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

      // bookmarks: read-only getTree only, from Bam's saved items in this login profile, when the manifest declares
      // the permission and no engine namespace exists. No mutation methods and no events are defined. Access is
      // checked natively on every call against an explicit grant; a denial arrives asynchronously, so the promise
      // form rejects and the callback form logs the error and calls back with no tree (no empty tree is invented).
      if (provided.has("bookmarks") && !api.bookmarks) {
        const ns = {};
        define(ns, "getTree", call(async () => await bridge("bookmarks.getTree", null)));
        define(api, "bookmarks", ns);
      }

      // history: read-only search plus the two genuine events (Bam's library reports new visits, trims and clears),
      // when declared and absent. No add/delete/getVisits. The query is checked against the official schema here and
      // natively; like every bridged call, errors reject the promise or are logged with an argument-less callback.
      if (provided.has("history") && !api.history) {
        const ns = {};
        const invalid = (detail) => new TypeError("Invalid history.search query: " + detail + ".");
        define(ns, "search", call(async (query) => {
          if (query === null || typeof query !== "object" || Array.isArray(query)) throw invalid("a query object is required");
          if (typeof query.text !== "string") throw invalid("'text' must be a string");
          for (const key of ["startTime", "endTime"]) {
            if (query[key] !== undefined && (typeof query[key] !== "number" || !Number.isFinite(query[key]))) throw invalid("'" + key + "' must be a finite number");
          }
          if (query.maxResults !== undefined && (typeof query.maxResults !== "number" || !Number.isInteger(query.maxResults) || query.maxResults < 0 || query.maxResults > 2147483647)) {
            throw invalid("'maxResults' must be an integer from 0 to 2147483647");
          }
          const params = { text: query.text };
          for (const key of ["startTime", "endTime", "maxResults"]) if (query[key] !== undefined) params[key] = query[key];
          return await bridge("history.search", params);
        }));
        registerEvent(ns, "onVisited", "history.onVisited");
        registerEvent(ns, "onVisitRemoved", "history.onVisitRemoved");
        define(api, "history", ns);
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

      // cookies.onChanged: WebKit invokes listeners with no changeInfo (its FIXME, webkit.org/b/267514),
      // so Chrome-style handlers receive undefined (Grammarly's sign-in cookie watch throws). Keep
      // WebKit's event as the trigger, diff cookies.getAll({}) against the last snapshot, and deliver
      // {removed, cookie, cause}. Only cookies this extension can already read are compared. A future
      // engine that passes changeInfo is forwarded unchanged.
      const nativeCookies = api.cookies;
      if (nativeCookies && nativeCookies.onChanged && typeof nativeCookies.getAll === "function" && !nativeCookies.__bamChangeInfo) {
        const nativeEvent = nativeCookies.onChanged;
        const listeners = new Set();
        // generation: bumped on attach/detach so a read from an earlier listener period never
        // seeds or diffs a later one. enginePassesInfo: once WebKit supplies real changeInfo, it
        // is forwarded from then on and no diff (including one already in flight) is delivered.
        let snapshot = null, work = Promise.resolve(), attached = false, generation = 0, enginePassesInfo = false;
        const key = (c) => [c.storeId || "", c.domain || "", c.path || "", c.name || "", c.partitionKey ? JSON.stringify(c.partitionKey) : ""].join("\u0000");
        const read = async () => { const map = new Map(); for (const c of (await nativeCookies.getAll({})) || []) map.set(key(c), c); return map; };
        const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        // A listener removed during a dispatch is not called afterwards, and a dispatch from an
        // earlier listener period stops as soon as a callback detaches or re-attaches.
        const deliver = (info, period) => {
          for (const fn of Array.from(listeners)) {
            if (period !== generation) return false;
            if (!listeners.has(fn)) continue;
            try { fn(info); } catch (error) { console.error("[Bam compatibility] cookies.onChanged listener failed", error); }
          }
          return period === generation;
        };
        // Delivered cookies are copies, so a listener mutating one cannot change the next comparison.
        const copy = (c) => JSON.parse(JSON.stringify(c));
        const refresh = () => {
          const requested = generation;
          work = work.then(async () => {
            if (requested !== generation || enginePassesInfo) return;
            let next;
            try { next = await read(); } catch (error) { return; }
            if (requested !== generation || enginePassesInfo) return;
            const previous = snapshot; snapshot = next;
            if (!previous) return;
            const now = Date.now() / 1000;
            for (const [k, old] of previous) {
              const current = next.get(k);
              if (!current) { if (!deliver({ removed: true, cookie: copy(old), cause: typeof old.expirationDate === "number" && old.expirationDate <= now ? "expired" : "explicit" }, requested)) return; }
              else if (!same(old, current)) { if (!deliver({ removed: true, cookie: copy(old), cause: "overwrite" }, requested)) return; }
            }
            for (const [k, current] of next) {
              const old = previous.get(k);
              if ((!old || !same(old, current)) && !deliver({ removed: false, cookie: copy(current), cause: "explicit" }, requested)) return;
            }
          });
          return work;
        };
        const onNative = (info) => {
          if (info && typeof info === "object") { enginePassesInfo = true; snapshot = null; deliver(info, generation); return; }
          if (!enginePassesInfo) refresh();
        };
        // WebKit's namespace attributes (cookies.onChanged) are native static values that a defined
        // property cannot replace, but the native event's methods can be overridden on the instance (as
        // the action.setIcon binding does). Keep the originals for Bam's single native trigger.
        const nativeAdd = nativeEvent.addListener.bind(nativeEvent), nativeRemove = nativeEvent.removeListener.bind(nativeEvent);
        const methods = {
          addListener(fn) {
            if (typeof fn !== "function") return;
            listeners.add(fn);
            // A fresh chain per listener period: an old read that never settles cannot stall this one.
            if (!attached) { attached = true; generation++; snapshot = null; work = Promise.resolve(); nativeAdd(onNative); refresh(); }
          },
          removeListener(fn) {
            listeners.delete(fn);
            if (attached && !listeners.size) { attached = false; generation++; nativeRemove(onNative); snapshot = null; }
          },
          hasListener(fn) { return listeners.has(fn); },
          hasListeners() { return listeners.size > 0; }
        };
        for (const [name, value] of Object.entries(methods)) {
          try { Object.defineProperty(nativeEvent, name, { value, writable: true, configurable: true, enumerable: true }); } catch (error) {}
        }
        try { Object.defineProperty(nativeCookies, "__bamChangeInfo", { value: true, configurable: true }); } catch (error) {}
        // rawAddListener is a diagnostics seam: fixtures count WebKit's own firings without joining Bam's listeners.
        compat.cookies = { namespace: nativeCookies, nativeEvent, settled: () => work, intercepting: nativeEvent.addListener === methods.addListener, rawAddListener: nativeAdd };
      }

      // fontSettings: the installed font families (Dark Reader's font picker). Bam has no
      // per-script or default font settings, so reading or changing those rejects.
      if (provided.has("fontSettings") && !api.fontSettings) {
        const ns = {};
        define(ns, "getFontList", call(async () => {
          const list = await bridge("fontSettings.getFontList", null);
          return Array.isArray(list) ? list.map((font) => ({ fontId: String(font.fontId), displayName: String(font.displayName) })) : [];
        }));
        for (const name of ["getFont", "setFont", "clearFont", "getDefaultFontSize", "setDefaultFontSize", "clearDefaultFontSize", "getDefaultFixedFontSize",
                            "setDefaultFixedFontSize", "clearDefaultFixedFontSize", "getMinimumFontSize", "setMinimumFontSize", "clearMinimumFontSize"]) {
          define(ns, name, call(async () => { throw unsupported("fontSettings." + name); }));
        }
        for (const name of ["onFontChanged", "onDefaultFontSizeChanged", "onDefaultFixedFontSizeChanged", "onMinimumFontSizeChanged"]) registerEvent(ns, name, "fontSettings." + name);
        define(ns, "GenericFamily", { STANDARD: "standard", SANSSERIF: "sansserif", SERIF: "serif", FIXED: "fixed", CURSIVE: "cursive", FANTASY: "fantasy", MATH: "math" });
        define(ns, "LevelOfControl", { NOT_CONTROLLABLE: "not_controllable", CONTROLLED_BY_OTHER_EXTENSIONS: "controlled_by_other_extensions",
                                      CONTROLLABLE_BY_THIS_EXTENSION: "controllable_by_this_extension", CONTROLLED_BY_THIS_EXTENSION: "controlled_by_this_extension" });
        define(api, "fontSettings", ns);
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

      // declarativeNetRequest: refuse added rules that WebKit does not enforce as written. Measured on canonical
      // runs: a rule whose excludedResourceTypes covers every type WebKit supports matched an XHR (WebKit does not
      // validate exclusions and writes an empty resource-type list); with compiled sentinels and server counts,
      // requestMethods ['get'] and excludedRequestMethods ['post'] rules blocked POST, and requestMethods ['post']
      // never blocked POST, so request-method conditions are refused whatever their action. Valid updates reach WebKit's own method with
      // the original receiver, arguments, callback and return value. A refused update never reaches WebKit:
      // the promise form rejects; the callback form throws synchronously, because Bam cannot set
      // runtime.lastError and a callback without an error would look like success.
      const webkitResourceTypes = ["font", "image", "main_frame", "media", "other", "ping", "script", "stylesheet", "sub_frame", "websocket", "xmlhttprequest"];
      const broadeningReason = (rule) => {
        const excluded = rule && rule.condition && rule.condition.excludedResourceTypes;
        if (Array.isArray(excluded) && webkitResourceTypes.every((type) => excluded.includes(type))) {
          return "Rule with id " + (rule && rule.id) + " excludes every resource type this browser supports, so it would match all requests here.";
        }
        // Empty or non-array values are left to WebKit's own validation.
        const condition = rule && rule.condition;
        const listed = (value) => Array.isArray(value) && value.length > 0;
        if (condition && (listed(condition.requestMethods) || listed(condition.excludedRequestMethods))) {
          return "Rule with id " + (rule && rule.id) + " has a request-method condition (requestMethods or excludedRequestMethods), which this browser does not enforce as written.";
        }
        return null;
      };
      const dnrGuardHeld = [];
      const applyDNRGuard = () => {
        for (const root of new Set([globalThis.browser, globalThis.chrome])) {
          const holder = root && root.declarativeNetRequest;
          if (!holder) continue;
          for (const name of ["updateDynamicRules", "updateSessionRules"]) {
            const native = holder[name];
            if (typeof native !== "function" || native.__bamDNRGuard) continue;
            const guarded = function (options, ...rest) {
              const added = options && Array.isArray(options.addRules) ? options.addRules : [];
              for (const rule of added) {
                const reason = broadeningReason(rule);
                if (!reason) continue;
                const error = new Error(reason);
                if (typeof rest[rest.length - 1] === "function") throw error;
                return Promise.reject(error);
              }
              return native.apply(this && typeof this === "object" ? this : holder, [options, ...rest]);
            };
            Object.defineProperty(guarded, "__bamDNRGuard", { value: true });
            try { Object.defineProperty(holder, name, { value: guarded, writable: true, configurable: true, enumerable: true }); dnrGuardHeld.push(holder); } catch (error) {}
          }
        }
      };

      // Tab metadata (Chrome's `tabs` contract: a tab's url and title without host access). WebKit blanks both unless
      // the extension has host access to the tab's site; this adds only those two values back, for an extension whose
      // live context holds `tabs` (checked natively on every request). It grants no site, and scripting, cookies,
      // fetch and webRequest keep WebKit's own host checks.
      // - The extension's own WebKit call runs first, once, synchronously and unchanged: its throws, callback
      //   runtime.lastError, promise rejections and mutations stay WebKit's. Supplementing never repeats it.
      // - Then a fresh WebKit read runs between a native identity token and a native answer bound to one observed tab
      //   topology; a change in between answers null, and up to 3 attempts are made before WebKit's answer is kept.
      // - Supplementing is computed without touching WebKit's objects and applied only before delivery, within a
      //   deadline (reads 2 s, events 1 s). Past it the original result is delivered once, and a late answer is
      //   discarded: nothing is mutated or called back afterwards.
      // - Only blank url and title fields are filled, each independently, by WebKit's own tab id; a value WebKit showed
      //   is never replaced. A url/title-filtered query keeps WebKit's own matching objects and adds blanked tabs the
      //   native answer matched.
      // - Tabs in several Little Bam windows, non-web pages and over-long values stay blank. favIconUrl stays WebKit's.
      // - Events: listeners of the tabs.* and windows.* events listed in `tabEvents`/`windowEvents` (not
      //   windows.onBoundsChanged) are delivered through one FIFO per document or worker, so their order is kept.
      //   tabs.onCreated/onUpdated get supplemented copies (shared by that dispatch's listeners; WebKit's own objects
      //   are never changed) if values arrive within 1 s; supplementing is skipped for an event that waited 3 s. The
      //   queue holds at most 256 events: one more abandons the supplementing in progress and delivers everything
      //   queued at once, in order, with WebKit's own values. No event is dropped or invented. Values are those at
      //   delivery. changeInfo.url/title are filled only when WebKit sent the key. A removed listener is not called.
      const metadataEnabled = provided.has("tabs.metadata");
      const metadataNative = "__bamTabMetadataNative";
      const readDeadline = 2000, eventDeadline = 1000, queueWait = 3000, queueCap = 256;
      // Resolves with the promise's value, or null at the deadline (a later value is then ignored by every caller).
      const deadline = (promise, ms) => new Promise((resolve) => {
        const timer = setTimeout(() => resolve(null), ms);
        Promise.resolve(promise).then((value) => { clearTimeout(timer); resolve(value); }, () => { clearTimeout(timer); resolve(null); });
      });
      const unwrap = (fn) => (fn && fn[metadataNative]) || fn;
      const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
      const nativeCall = (root, ns, name, args) => {
        const holder = root && root[ns], fn = holder && unwrap(holder[name]);
        if (typeof fn !== "function") return Promise.reject(unsupported(ns + "." + name));
        try { return Promise.resolve(fn.apply(holder, args)); } catch (error) { return Promise.reject(error); }
      };
      // A bounded bridge request: null on error or at the deadline. A document request still pending then is retired
      // from `pending`, so an unanswered native request leaves nothing behind (a worker's sendNativeMessage can't be
      // withdrawn; its late reply is ignored).
      const bridgeValue = (method, params) => {
        if (isWorker) return deadline(sendNative({ kind: "request", method, params: params === undefined ? null : params }), readDeadline);
        return new Promise((resolve) => {
          const handler = globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers[bridgeName];
          if (!handler) { resolve(null); return; }
          const id = nextRequest++;
          const timer = setTimeout(() => { if (pending.delete(id)) resolve(null); }, readDeadline);
          pending.set(id, { resolve: (value) => { clearTimeout(timer); resolve(value); }, reject: () => { clearTimeout(timer); resolve(null); } });
          try { handler.postMessage({ kind: "request", id, method, params: params === undefined ? null : params }); }
          catch (error) { pending.delete(id); clearTimeout(timer); resolve(null); }
        });
      };
      const blank = (value) => value === undefined || value === null || value === "";
      // WebKit blanked the url (it also never matches such a tab against a url/title filter).
      const isRedacted = (tab) => !!tab && typeof tab === "object" && typeof tab.id === "number" && blank(tab.url);
      // Some field is blank and may be supplemented; each field is considered on its own.
      const needsFill = (tab) => !!tab && typeof tab === "object" && typeof tab.id === "number" && (blank(tab.url) || blank(tab.title));
      // One bound read: token, fresh WebKit read, window kinds, answer. Returns {tabs, values} or null. Touches only
      // the fresh objects it read (and only to look at them).
      const boundRead = async (root, read, collect, filter) => {
        for (let attempt = 0; attempt < 3; attempt++) {
          const token = await bridgeValue("tabs.identityToken", null);
          if (typeof token !== "string") return null;
          let fresh, windows;
          try { fresh = await read(); windows = await nativeCall(root, "windows", "getAll", [{ windowTypes: ["normal", "popup"] }]); }
          catch (error) { return null; }
          const kinds = new Map();
          let normalCount = 0, popupCount = 0;
          for (const w of Array.isArray(windows) ? windows : []) {
            if (w && w.type === "normal") { normalCount++; kinds.set(w.id, "normal"); }
            else if (w && w.type === "popup") { popupCount++; kinds.set(w.id, "popup"); }
          }
          const tabs = collect(fresh).filter((tab) => tab && typeof tab.id === "number");
          const located = tabs.filter((tab) => kinds.has(tab.windowId) && Number.isInteger(tab.index) && tab.index >= 0).slice(0, 512);
          if (filter && located.length !== tabs.length) return null;
          const params = { token, normalCount, popupCount, entries: located.map((tab) => ({ window: kinds.get(tab.windowId), index: tab.index })) };
          if (filter) params.filter = filter;
          const answer = await bridgeValue("tabs.metadata", params);
          if (!Array.isArray(answer) || answer.length !== located.length) continue;
          const values = new Map();
          located.forEach((tab, i) => { const v = answer[i]; if (v && typeof v.url === "string") values.set(tab, v); });
          return { tabs, values };
        }
        return null;
      };
      // Values by WebKit tab id from a bound fresh read; nothing is applied here.
      const valuesByID = (root, read, collect) => boundRead(root, read, collect, null).then((result) => {
        if (!result) return null;
        const byID = new Map();
        for (const tab of result.tabs) if (result.values.has(tab)) byID.set(tab.id, result.values.get(tab));
        return byID;
      });
      // Fills each blank field independently; a field WebKit gave a value is kept as WebKit gave it.
      const fill = (target, value) => {
        if (!needsFill(target) || !value) return;
        if (blank(target.url)) target.url = value.url;
        if (blank(target.title) && typeof value.title === "string") target.title = value.title;
      };
      const tabsOf = (value) => Array.isArray(value) ? value : value && typeof value === "object" ? [value] : [];
      const windowTabs = (value) => tabsOf(value).flatMap((w) => Array.isArray(w && w.tabs) ? w.tabs : []);
      // A reader answers a promise of an `apply` function (or null). `apply` runs only if it arrives within the read
      // deadline, right before delivery, and returns what to deliver.
      const filling = (root, value, baseline, read, collect) => {
        if (!baseline.some(needsFill)) return Promise.resolve(null);
        return valuesByID(root, read, collect).then((byID) => byID && (() => {
          for (const tab of baseline) if (needsFill(tab)) fill(tab, byID.get(tab.id));
          return value;
        }));
      };
      const readers = {
        "tabs.query": (root, args, value) => {
          const info = args[0] && typeof args[0] === "object" ? args[0] : {};
          if (info.url === undefined && info.title === undefined) {
            return filling(root, value, tabsOf(value), () => nativeCall(root, "tabs", "query", [info]), tabsOf);
          }
          // WebKit never matches a url/title filter on a blanked tab: re-run the query without them and let the native
          // answer evaluate the filter on the real values. WebKit's own matches are kept as WebKit returned them, even
          // if a tab changed between the reads; only blanked tabs the answer matched are added, in tab order.
          const stripped = { ...info }; delete stripped.url; delete stripped.title;
          const filter = {};
          if (info.url !== undefined) filter.url = info.url;
          if (info.title !== undefined) filter.title = info.title;
          return boundRead(root, () => nativeCall(root, "tabs", "query", [stripped]), tabsOf, filter).then((result) => result && (() => {
            const native = tabsOf(value), nativeByID = new Map(native.map((tab) => [tab && tab.id, tab]));
            const out = [], seen = new Set();
            for (const tab of result.tabs) {
              if (nativeByID.has(tab.id)) { if (!seen.has(tab.id)) { out.push(nativeByID.get(tab.id)); seen.add(tab.id); } }
              else if (isRedacted(tab) && result.values.has(tab)) { fill(tab, result.values.get(tab)); out.push(tab); }
            }
            for (const tab of native) if (!seen.has(tab && tab.id)) out.push(tab);
            return out;
          }));
        },
        "tabs.get": (root, args, value) => filling(root, value, tabsOf(value), () => nativeCall(root, "tabs", "get", [args[0]]), tabsOf),
        "tabs.getCurrent": (root, args, value) => filling(root, value, tabsOf(value), () => nativeCall(root, "tabs", "getCurrent", []), tabsOf),
        "tabs.create": (root, args, value) => filling(root, value, tabsOf(value), () => nativeCall(root, "tabs", "get", [value.id]), tabsOf),
        "tabs.update": (root, args, value) => filling(root, value, tabsOf(value), () => nativeCall(root, "tabs", "get", [value.id]), tabsOf),
        "windows.create": (root, args, value) => filling(root, value, windowTabs(value), () => nativeCall(root, "windows", "get", [value.id, { populate: true }]), windowTabs)
      };
      for (const name of ["get", "getAll", "getCurrent", "getLastFocused"]) {
        readers["windows." + name] = (root, args, value) => {
          const infoIndex = name === "get" ? 1 : 0;
          const info = args[infoIndex] && typeof args[infoIndex] === "object" ? args[infoIndex] : null;
          if (!info || !info.populate) return Promise.resolve(null);
          return filling(root, value, windowTabs(value), () => nativeCall(root, "windows", name, args.slice(0, infoIndex + 1)), windowTabs);
        };
      }
      const wrapRead = (root, holder, ns, name, native) => {
        const key = ns + "." + name;
        const wrapped = function (...args) {
          const receiver = this && typeof this === "object" ? this : holder;
          const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
          const supplement = (value) => {
            let pending;
            try { pending = readers[key](root, args, value); } catch (error) { return Promise.resolve(value); }
            return deadline(pending, readDeadline).then((apply) => {
              if (typeof apply !== "function") return value;
              try { return apply(); } catch (error) { return value; }
            });
          };
          if (!callback) {
            const result = native.apply(receiver, args);
            return result && typeof result.then === "function" ? result.then((value) => value == null ? value : supplement(value)) : result;
          }
          return native.apply(receiver, [...args, (...results) => {
            let failed = false;
            try { failed = !!(root.runtime && root.runtime.lastError); } catch (error) {}
            // A WebKit error is reported inside WebKit's own callback, where runtime.lastError is set.
            if (failed || results[0] == null) { callback(...results); return; }
            supplement(results[0]).then((value) => callback(value));
          }]);
        };
        Object.defineProperty(wrapped, metadataNative, { value: native });
        return wrapped;
      };
      // Events: one FIFO per document or worker; listener tables per actual event object (browser and chrome event
      // objects are separate registrations, as in WebKit; aliases of one object share its table).
      const eventQueue = [];
      let draining = false;
      const eventTables = new WeakMap();
      const pendingValues = new WeakMap(), copies = new WeakMap();
      let preparing = null;   // the job whose supplementing is awaited (not in eventQueue)
      let stopWaiting = null; // ends that wait at once (overload flush)
      // Delivers a job once; a listener removed meanwhile is not called.
      const deliver = (job, args) => {
        if (job.delivered) return;
        job.delivered = true;
        if (job.table.get(job.listener) !== job.wrapper) return;
        try { job.listener(...args); } catch (error) { console.error(error); }
      };
      const drain = async () => {
        if (draining) return;
        draining = true;
        while (eventQueue.length) {
          const job = eventQueue.shift();
          let args = job.args;
          const pending = job.prepare && performance.now() - job.at < queueWait ? job.prepare() : null;
          if (pending) {
            preparing = job;
            const make = await Promise.race([deadline(pending, eventDeadline), new Promise((resolve) => { stopWaiting = () => resolve(null); })]);
            preparing = null; stopWaiting = null;
            // An overload flush may already have delivered it with WebKit's values; a late answer is then ignored.
            if (job.delivered) continue;
            if (typeof make === "function") { try { args = make(); } catch (error) {} }
          }
          deliver(job, args);
        }
        draining = false;
      };
      // Queue full: abandon supplementing and deliver the awaited job and everything queued now, in order, with
      // WebKit's own values (events dispatched by those listeners join the same flush, in order).
      const flush = () => {
        if (preparing) { const job = preparing; preparing = null; deliver(job, job.args); }
        if (stopWaiting) { const stop = stopWaiting; stopWaiting = null; stop(); }
        while (eventQueue.length) { const job = eventQueue.shift(); deliver(job, job.args); }
      };
      const enqueue = (job) => {
        eventQueue.push(job);
        if (eventQueue.length + (preparing ? 1 : 0) > queueCap) flush(); else drain();
      };
      const tabValues = (root, tab) => {
        if (!needsFill(tab)) return null;
        if (!pendingValues.has(tab)) pendingValues.set(tab, valuesByID(root, () => nativeCall(root, "tabs", "get", [tab.id]), tabsOf));
        return pendingValues.get(tab);
      };
      // A supplemented copy of a WebKit object, made once per dispatch and shared by its listeners.
      const copyOf = (original, make) => { if (!copies.has(original)) copies.set(original, make()); return copies.get(original); };
      const tabCopy = (tab, value) => copyOf(tab, () => { const copy = { ...tab }; fill(copy, value); return copy; });
      const preparers = {
        "tabs.onCreated": (root, args) => {
          const tab = args[0], pending = tabValues(root, tab);
          return pending && pending.then((byID) => {
            const value = byID && byID.get(tab.id);
            return value ? () => [tabCopy(tab, value), ...args.slice(1)] : null;
          });
        },
        "tabs.onUpdated": (root, args) => {
          const [tabId, changeInfo, tab] = args, pending = tabValues(root, tab);
          return pending && pending.then((byID) => {
            const value = byID && byID.get(tab.id);
            if (!value) return null;
            return () => {
              const copy = tabCopy(tab, value);
              const info = changeInfo && typeof changeInfo === "object" ? copyOf(changeInfo, () => {
                const next = { ...changeInfo };
                if (hasOwn(changeInfo, "url") && blank(changeInfo.url) && !blank(copy.url)) next.url = copy.url;
                if (hasOwn(changeInfo, "title") && blank(changeInfo.title) && typeof copy.title === "string") next.title = copy.title;
                return next;
              }) : changeInfo;
              return [tabId, info, copy, ...args.slice(3)];
            };
          });
        }
      };
      const wrapEvent = (root, ns, name, target) => {
        const key = ns + "." + name;
        const add = unwrap(target.addListener), remove = unwrap(target.removeListener), has = unwrap(target.hasListener);
        if (typeof add !== "function" || typeof remove !== "function") return;
        const table = eventTables.get(target) || new Map();
        eventTables.set(target, table);
        const install = (member, fn, native) => {
          Object.defineProperty(fn, metadataNative, { value: native });
          try { Object.defineProperty(target, member, { value: fn, writable: true, configurable: true, enumerable: true }); } catch (error) {}
        };
        install("addListener", function (listener, ...rest) {
          if (typeof listener !== "function") return add.call(target, listener, ...rest);
          let wrapper = table.get(listener);
          if (!wrapper) {
            wrapper = (...args) => {
              const prepare = preparers[key] ? () => preparers[key](root, args) : null;
              enqueue({ table, listener, wrapper, args, prepare, at: performance.now(), delivered: false });
            };
            table.set(listener, wrapper);
          }
          return add.call(target, wrapper, ...rest);
        }, add);
        install("removeListener", function (listener, ...rest) {
          const wrapper = table.get(listener);
          table.delete(listener);
          return remove.call(target, wrapper || listener, ...rest);
        }, remove);
        if (typeof has === "function") install("hasListener", function (listener) { return has.call(target, table.get(listener) || listener); }, has);
      };
      const tabEvents = ["onActivated", "onAttached", "onCreated", "onDetached", "onHighlighted", "onMoved", "onRemoved", "onReplaced", "onUpdated", "onZoomChange"];
      const windowEvents = ["onCreated", "onRemoved", "onFocusChanged"];
      const metadataHeld = [];
      const applyTabMetadata = () => {
        if (!metadataEnabled) return;
        for (const root of new Set([globalThis.browser, globalThis.chrome])) {
          if (!root || typeof root !== "object") continue;
          for (const [ns, names, events] of [["tabs", ["query", "get", "getCurrent", "create", "update"], tabEvents], ["windows", ["get", "getAll", "getCurrent", "getLastFocused", "create"], windowEvents]]) {
            const holder = root[ns];
            if (!holder || typeof holder !== "object") continue;
            for (const name of names) {
              const current = holder[name];
              if (typeof current !== "function" || current[metadataNative]) continue;
              try {
                Object.defineProperty(holder, name, { value: wrapRead(root, holder, ns, name, current), writable: true, configurable: true, enumerable: true });
                metadataHeld.push(holder);
              } catch (error) {}
            }
            for (const name of events) {
              const target = holder[name];
              if (!target || typeof target !== "object" || (target.addListener && target.addListener[metadataNative])) continue;
              wrapEvent(root, ns, name, target);
              metadataHeld.push(target);
            }
          }
        }
      };

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
        applyDNRGuard();
        applyTabMetadata();
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
      // runtime.onUpdateAvailable never fires in Bam: there is no pending-update state. Updates are
      // user-initiated in Bam's extension manager, reviewed, and replace the extension directly.
      // Proton Pass registers a listener unconditionally at worker start.
      if (provided.has("runtime.onUpdateAvailable")) extend("runtime", "onUpdateAvailable", extensionEvent("runtime", "onUpdateAvailable"));
      // windows.onBoundsChanged (Chrome: fired when a window's new bounds are committed). WebKit has no
      // such event; Session Buddy registers one unconditionally while starting. Bam's native side only
      // signals "a window this profile exposes committed a move or resize" (debounced). Each signal reads
      // WebKit's own windows.getAll and reports, as WebKit's Window object, each window whose left, top,
      // width or height differs from the previous read, so IDs and coordinates are WebKit's, never Bam's.
      // Baseline and signals are serialized on one chain per listening period: the baseline is read when
      // the first listener is added; a change committed before that read completes becomes part of the
      // baseline (not reported); several changes between two reads are reported once, with the final
      // bounds. New and removed windows are not reported here (onCreated/onRemoved cover them). When the
      // last listener is removed the period ends and pending reads are discarded.
      const boundsChangedEvent = () => {
        const name = "windows.onBoundsChanged";
        const e = event(name), own = new Set();
        compat.events[name] = e;
        const nativeAdd = e.addListener, nativeRemove = e.removeListener;
        let period = 0, snapshot = null, chain = Promise.resolve();
        const geometry = (w) => [w.left, w.top, w.width, w.height].join(",");
        const read = () => Promise.resolve().then(() => api.windows.getAll({ populate: false }));
        const enqueue = (work) => {
          const current = period;
          chain = chain.then(() => current === period ? work(current) : undefined)
            .catch((error) => { if (current === period) console.error("[Bam compatibility] windows.onBoundsChanged read failed", error); });
        };
        const remember = (list) => { snapshot = new Map((Array.isArray(list) ? list : []).map((w) => [w.id, geometry(w)])); };
        const start = () => {
          period += 1; snapshot = null; chain = Promise.resolve();
          enqueue(async (current) => { const list = await read(); if (current === period) remember(list); });
        };
        define(e, "addListener", function (fn) {
          if (typeof fn !== "function") return;
          const first = own.size === 0;
          own.add(fn); nativeAdd.call(e, fn);
          if (first) start();
        });
        define(e, "removeListener", function (fn) {
          if (!own.delete(fn)) return;
          nativeRemove.call(e, fn);
          if (own.size === 0) { period += 1; snapshot = null; }
        });
        // Topology refresh: add windows the baseline lacks and drop removed ones; never report and never
        // overwrite a known window's geometry (it may be mid-resize; only committed signals compare it).
        const refreshTopology = (list) => {
          if (!snapshot) { remember(list); return; }
          const present = new Set();
          for (const w of Array.isArray(list) ? list : []) { present.add(w.id); if (!snapshot.has(w.id)) snapshot.set(w.id, geometry(w)); }
          for (const id of Array.from(snapshot.keys())) if (!present.has(id)) snapshot.delete(id);
        };
        Object.defineProperty(e, "__bamDispatch", { value: (kind) => {
          if (own.size === 0) return;
          if (kind === "topology") { enqueue(async (current) => { const list = await read(); if (current === period) refreshTopology(list); }); return; }
          enqueue(async (current) => {
            const list = await read();
            if (current !== period) return;
            const previous = snapshot;
            remember(list);
            // A failed baseline read makes this read the baseline; nothing is invented.
            if (!previous || !Array.isArray(list)) return;
            for (const w of list) {
              const before = previous.get(w.id);
              if (before === undefined || before === geometry(w)) continue;
              for (const fn of Array.from(own)) {
                if (current !== period) return;
                if (!own.has(fn)) continue;
                try { fn(Object.assign({}, w)); } catch (error) { console.error("[Bam compatibility] windows.onBoundsChanged listener failed", error); }
              }
            }
          });
        }, enumerable: false, writable: true, configurable: true });
        compat.windowsBounds = { get period() { return period; }, get baseline() { return snapshot ? Array.from(snapshot.keys()) : null; } };
        return e;
      };
      if (provided.has("windows.onBoundsChanged")) extend("windows", "onBoundsChanged", boundsChangedEvent);
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
      // WebKit's scripting accepts world: "ISOLATED"/"MAIN" strings but has no enum; Bitwarden
      // reads chrome.scripting.ExecutionWorld.ISOLATED before every injection. Only the
      // constants are supplied; what each world does stays WebKit's own executeScript.
      if (provided.has("scripting.ExecutionWorld")) extend("scripting", "ExecutionWorld", () => Object.freeze({ ISOLATED: "ISOLATED", MAIN: "MAIN" }));
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
    /// Who posted each notification: the registration key (runtime.id) and the posting installation (base URL host).
    /// A replacement install of the same store extension reuses runtime.id but never the installation host.
    private struct NotificationOwner { let key: String; let install: String }
    private var notificationOwners: [String: NotificationOwner] = [:]
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
    /// Tab metadata (work/chrome-tab-metadata-api.md): the runtime issues bindings and answers redeemed requests from one
    /// observed topology. Tokens live here so unload, revoke and shutdown purge them with the registration.
    var tabMetadataBinding: ((WKWebExtensionContext) -> ExtensionTabMetadata.Binding?)?
    var answerTabMetadata: ((WKWebExtensionContext, ExtensionTabMetadata.Binding, ExtensionTabMetadata.Request) -> [ExtensionTabMetadata.Value?]?)?
    private var metadataTokens = ExtensionTabMetadata.TokenStore()
    /// Supplied by the host: the identifier for notifications posted on behalf of an extension.
    var notificationIdentifier: ((String) -> String?)?
    /// Returns a delivery error, or nil when the notification was posted natively.
    var postNotification: ((String, String, String, [String], @MainActor () -> Bool) async -> String?)?
    var isNotificationDeliveryAvailable: (() -> Bool)?
    /// This profile's saved items for bookmarks.getTree; nil when unavailable. Never called for private hosts.
    var bookmarkInput: (() -> ExtensionBookmarkTree.Input?)?
    /// This profile's in-memory history visits, newest first; nil when unavailable. Never called for private hosts.
    var historyVisits: (() -> [ExtensionHistory.Visit]?)?
    static let historyNotGranted = "Bam has not been granted history access for this extension. Disable and enable it in Manage Extensions to review access."
    var isPrivateHost = false
    static let bookmarksNotGranted = "Bam has not been granted bookmarks access for this extension. Disable and enable it in Manage Extensions to review access."
    let browserVersion: String

    init(controller: WKWebExtensionController, dataStore: WKWebsiteDataStore, contentController: WKUserContentController, browserVersion: String) {
        self.controller = controller; self.dataStore = dataStore; self.contentController = contentController; self.browserVersion = browserVersion
        handlerName = "bamCompatibility" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        super.init()
        contentController.add(self, contentWorld: .page, name: handlerName)
        offscreen = ExtensionOffscreenDocuments(start: { [weak self] owner, url in
            guard let self else { throw ExtensionOffscreenDocuments<WKWebView>.Failure(description: "Extensions are shutting down.") }
            return try self.startOffscreen(owner: owner, url: url)
        }, discard: { [weak self] web in
            // End the pending wait now and stop the page; releasing the slot's last
            // reference closes it, so it receives nothing once close has returned.
            self?.offscreenLoaders.removeValue(forKey: ObjectIdentifier(web))?.cancel()
            web.navigationDelegate = nil; web.stopLoading()
        })
    }

    /// Starts an extension page in a hidden web view built from the context's own
    /// configuration, so it is an ordinary extension page to WebKit (messaging,
    /// storage and this layer) in the same profile store. It is never shown. The
    /// returned wait holds only the loader, never the web view.
    private func startOffscreen(owner: String, url: URL) throws -> (WKWebView, @MainActor () async throws -> Void) {
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
        web.load(URLRequest(url: url))
        return (web, { try await loader.wait() })
    }
    /// Revoked grants close the extension's hidden document immediately.
    func revoke(_ context: WKWebExtensionContext) { offscreen.discard(owner: context.uniqueIdentifier); metadataTokens.purge(context: context.uniqueIdentifier) }

    func install(_ plan: ExtensionCompatibility.Plan, for context: WKWebExtensionContext) {
        guard !plan.isEmpty, let contentController else { return }
        registrations[context.uniqueIdentifier] = Registration(context: context, plan: plan)
        let script = WKUserScript(source: ExtensionCompatibility.script(baseURL: context.baseURL, bridge: handlerName, plan: plan, browserVersion: browserVersion),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        scripts[context.uniqueIdentifier] = script
        contentController.addUserScript(script)
    }
    /// The registration a notification response may reach: only while the identifier is still owned and the live
    /// registration under that key is the very installation that posted it.
    func routedOwner(for identifier: String) -> String? {
        guard let owner = notificationOwners[identifier], let context = registrations[owner.key]?.context,
              ownsRegisteredContext(context), context.baseURL.host == owner.install else { return nil }
        return owner.key
    }
    func remove(_ context: WKWebExtensionContext) {
        // Withdraw this installation's notifications: their responses must never reach a later install.
        let install = context.baseURL.host ?? ""
        let owned = notificationOwners.filter { $0.value.install == install }.map(\.key)
        for identifier in owned { notificationOwners.removeValue(forKey: identifier); ExtensionNotificationCenter.shared.forget(identifier) }
        if !owned.isEmpty, Self.canUseNotificationCenter {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: owned)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: owned)
        }
        offscreen.discard(owner: context.uniqueIdentifier)
        metadataTokens.purge(context: context.uniqueIdentifier)
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
        metadataTokens.purgeAll()
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
        "notifications.onButtonClicked": "notifications", "notifications.onShown": "notifications", "idle.onStateChanged": "idle",
        "history.onVisited": "history", "history.onVisitRemoved": "history"]
    /// Events Chrome delivers without any permission. They still require a registered, loaded context of
    /// this profile whose compatibility plan provides the event.
    private static let unpermissionedEvents: Set<String> = ["windows.onBoundsChanged"]
    private func allowsEvent(_ event: String, for context: WKWebExtensionContext) -> Bool {
        if Self.unpermissionedEvents.contains(event) {
            return ownsRegisteredContext(context) && context.isLoaded && registrations[context.uniqueIdentifier]?.plan.provided.contains(event) == true
        }
        guard let permission = Self.eventPermissions[event] else { return false }
        if permission == "history" && isPrivateHost { return false }
        return permits(permission, for: context)
    }
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

    /// Tab metadata bridge. Every refusal answers null, which the facade reads as "use WebKit's own answer"; no
    /// error is invented. Only a registered context whose plan includes the facade may ask, and the runtime checks the
    /// exact live context, `tabs`, the private boundary and the observation again when answering.
    private func tabMetadata(_ method: String, params: [String: Any], context: WKWebExtensionContext) -> Any? {
        guard ownsRegisteredContext(context), registrations[context.uniqueIdentifier]?.plan.provided.contains("tabs.metadata") == true else { return nil }
        switch method {
        case "tabs.identityToken":
            guard let binding = tabMetadataBinding?(context), let token = metadataTokens.issue(binding, now: Date()) else { return nil }
            BrowserExtensions.metadataTestHook?("issued")
            return token
        default:
            guard let request = ExtensionTabMetadata.Request.parse(params),
                  let issued = metadataTokens.consume(request.token, now: Date()), issued.context == context.uniqueIdentifier else { return nil }
            BrowserExtensions.metadataTestHook?("answering")
            guard ownsRegisteredContext(context), let values = answerTabMetadata?(context, issued, request) else { return nil }
            return ExtensionTabMetadata.response(values)
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
                  let event = body["event"] as? String, self.allowsEvent(event, for: context) else {
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
        if method == "tabs.identityToken" || method == "tabs.metadata" { return (tabMetadata(method, params: params, context: context), nil) }
        let methods = ["idle.queryState": "idle", "notifications.permissionLevel": "notifications", "notifications.create": "notifications",
                       "notifications.clear": "notifications", "downloads.download": "downloads",
                       "fontSettings.getFontList": "fontSettings", "bookmarks.getTree": "bookmarks", "history.search": "history",
                       "offscreen.createDocument": "offscreen", "offscreen.closeDocument": "offscreen", "offscreen.hasDocument": "offscreen", "offscreen.contexts": "offscreen"]
        guard let permission = methods[method], permits(permission, for: context) else {
            if method.hasPrefix("bookmarks.") { return (nil, Self.bookmarksNotGranted) }
            if method.hasPrefix("history.") { return (nil, Self.historyNotGranted) }
            return (nil, "This compatibility capability is not available to the extension.")
        }
        switch method {
        case "history.search":
            // This bridge's own profile; nothing the caller sends selects one. The library is already in memory.
            if isPrivateHost { return (nil, "History is not available to extensions in private windows.") }
            let query: ExtensionHistory.Query
            switch ExtensionHistory.query(params, now: Date()) {
            case .success(let parsed): query = parsed
            case .failure(let failure): return (nil, failure.description)
            }
            guard let visits = historyVisits?() else { return (nil, "Bam's history is not available right now.") }
            switch ExtensionHistory.search(visits, query) {
            case .success(let items): return (items, nil)
            case .failure(let failure): return (nil, failure.description)
            }
        case "bookmarks.getTree":
            // The profile is this bridge's own (the context was matched to its registration above); nothing the
            // caller sends selects a profile.
            if isPrivateHost { return (nil, "Bookmarks are not available to extensions in private windows.") }
            guard let input = bookmarkInput?() else { return (nil, "Bam's bookmarks are not available right now.") }
            switch ExtensionBookmarkTree.tree(input) {
            case .success(let root): return ([root], nil)
            case .failure(let failure): return (nil, failure.description)
            }
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
            notificationOwners[identifier] = NotificationOwner(key: context.uniqueIdentifier, install: context.baseURL.host ?? "")
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
        case "fontSettings.getFontList":
            return (Self.fontList(), nil)
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
        guard let context = registrations[uniqueIdentifier]?.context, allowsEvent(event, for: context) else { return }
        let script = "globalThis.__bamCompatibility && globalThis.__bamCompatibility.dispatch(\(Self.json(event)), \(Self.json(arguments)));"
        documents[uniqueIdentifier]?.removeAll { !$0.isLive }
        for document in documents[uniqueIdentifier] ?? [] { document.web?.evaluateJavaScript(script, in: document.frame, in: .page) { _ in } }
        for connection in eventConnections[uniqueIdentifier]?.values ?? Dictionary<ObjectIdentifier, EventConnection>().values where connection.events.contains(event) {
            connection.port.sendMessage(["event": event, "args": arguments]) { _ in }
        }
    }

    /// A window this profile exposes committed new bounds (`topologyOnly` false), or the set of exposed windows
    /// changed (`topologyOnly` true): every registered context of this bridge's profile that provides the event is
    /// signalled (pages directly, workers only while subscribed). Payloads are read by the adapter from WebKit's own
    /// windows.getAll. A topology signal only adds/removes window IDs in the adapter's baseline; it never reports
    /// and never overwrites a known window's geometry, so it cannot leak bounds that are not committed.
    func signalWindowBoundsChanged(topologyOnly: Bool = false) {
        for key in registrations.keys.sorted() { dispatch("windows.onBoundsChanged", topologyOnly ? ["topology"] : [], to: key) }
    }
    /// A genuine change in this profile's library: delivered to each registered context whose grant and loaded state
    /// are re-checked at dispatch (`dispatch` → `allowsEvent`), so nothing reaches a revoked or unloaded extension.
    func dispatchHistory(_ change: ExtensionHistory.Change) {
        guard !isPrivateHost else { return }
        let events = ExtensionHistory.events(for: change)
        // Changes too large to deliver are not invented or truncated; they are recorded (bounded, no URLs) and logged.
        for message in events.undeliverable {
            historyDiagnostics.append(message); if historyDiagnostics.count > 20 { historyDiagnostics.removeFirst(historyDiagnostics.count - 20) }
            NSLog("Bam: %@", message)
        }
        for (event, payload) in events.deliveries {
            for key in registrations.keys.sorted() { dispatch(event, [payload], to: key) }
        }
    }
    /// The last undeliverable history changes of this profile (diagnostics and fixtures).
    private(set) var historyDiagnostics: [String] = []
    /// Contexts a bounds signal would reach (diagnostics and fixtures).
    func boundsSignalRecipients() -> [String] {
        registrations.keys.sorted().filter { key in registrations[key]?.context.map { allowsEvent("windows.onBoundsChanged", for: $0) } == true }
    }

    /// Installed font families as Chrome lists them: an ID and a localized display name,
    /// sorted by display name. System-private families (leading ".") are omitted.
    static func fontList() -> [[String: String]] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
            .map { ["fontId": $0, "displayName": NSFontManager.shared.localizedName(forFamily: $0, face: nil)] }
            .sorted { ($0["displayName"] ?? "").localizedStandardCompare($1["displayName"] ?? "") == .orderedAscending }
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }
    /// Per installation (base URL host), not per `runtime.id`: two profiles can install the same store extension, and
    /// the shared notification center must not let one profile's notification reach the other.
    static func notificationIdentifier(context: WKWebExtensionContext, id: String) -> String { "bam-extension:\(context.baseURL.host ?? context.uniqueIdentifier):\(id)" }
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
            // Only the bridge that posted it owns it; events go to the registration that posted it.
            guard let self, let parsed = Self.parseNotificationIdentifier(identifier), let owner = self.routedOwner(for: identifier) else { return }
            switch action {
            case UNNotificationDefaultActionIdentifier: self.dispatch("notifications.onClicked", [parsed.id], to: owner)
            case UNNotificationDismissActionIdentifier: self.dispatch("notifications.onClosed", [parsed.id, true], to: owner)
            default:
                if action.hasPrefix("bam-button-"), let index = Int(action.dropFirst("bam-button-".count)) {
                    self.dispatch("notifications.onButtonClicked", [parsed.id, index], to: owner)
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
    private var outcome: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    init(baseURL: URL) { self.baseURL = baseURL }
    private static func failure(_ message: String) -> Error { ExtensionOffscreenDocuments<WKWebView>.Failure(description: message) }

    /// Resolves at the first load's end, on failure, on timeout, or as soon as it is cancelled.
    func wait() async throws {
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeout)
                self?.finish(.failure(Self.failure("The offscreen document did not finish loading.")))
            }
        }
    }
    func cancel() { finish(.failure(Self.failure(ExtensionOffscreenDocuments<WKWebView>.closedWhileLoading))) }
    private func finish(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        let continuation = waiter; waiter = nil
        continuation?.resume(with: result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == baseURL.scheme && url?.host == baseURL.host ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if outcome == nil { finish(.failure(Self.failure("The offscreen document stopped while loading."))) } else { terminated?() }
    }
}
