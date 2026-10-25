import Foundation
import WebKit
import JavaScriptCore

/// The tab metadata facade's JavaScript (ExtensionCompatibility worker script) against a fake engine that redacts like
/// WebKit: url/title blank without host access, url/title query filters never match a blanked tab. The native bridge is
/// faked, so this checks only the facade's own behavior; the native authority and observation checks are covered by the
/// in-app regressions.
@main @MainActor enum ExtensionTabMetadataFacadeTests {
    struct Failure: Error { let message: String }
    static func main() async throws {
        guard #available(macOS 15.4, *) else { print("SKIP: Compatibility requires macOS 15.4"); return }
        try run()
    }

    static let fakeEngine = """
    var console = {error: function() {}, log: function() {}};
    var performance = {now: function() { return 0; }};
    var timers = []; function setTimeout(fn) { timers.push(fn); return timers.length; } function clearTimeout() {}
    var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'};
    var lastError = null, calls = {}, bridgeLog = [], queries = [], tokenMode = 'ok', metaMode = 'ok', tokens = 0;
    var tabs = [
      {id: 1, windowId: 10, index: 0, url: 'https://a.test/x', title: 'First', host: false},
      {id: 2, windowId: 10, index: 1, url: 'https://a.test/x', title: 'Second, same URL', host: false},
      {id: 3, windowId: 10, index: 2, url: 'https://b.test/', title: 'Shown by WebKit', host: true}
    ];
    function count(name) { calls[name] = (calls[name] || 0) + 1; }
    function view(t) { var v = {id: t.id, windowId: t.windowId, index: t.index, active: t.index === 0, url: t.host ? t.url : ''}; if (t.host) v.title = t.title; return v; }
    function prefix(pattern, url) { return url.indexOf(pattern.replace(/\\*$/, '')) === 0; }
    function settle(cb, value, error) {
      if (cb) { if (error) { lastError = {message: error}; cb(); lastError = null; } else cb(value); return undefined; }
      return error ? Promise.reject(new Error(error)) : Promise.resolve(value);
    }
    function makeEvent() { return { listeners: [],
      addListener: function(fn) { this.listeners.push(fn); }, removeListener: function(fn) { this.listeners = this.listeners.filter(function(x) { return x !== fn; }); },
      hasListener: function(fn) { return this.listeners.indexOf(fn) >= 0; }, fire: function() { var args = arguments; this.listeners.slice().forEach(function(fn) { fn.apply(null, args); }); } }; }
    function matchesQuery(info, t) {
      if (info.active !== undefined && (t.index === 0) !== info.active) return false;
      if (info.url !== undefined && !(t.host && [].concat(info.url).some(function(p) { return prefix(p, t.url); }))) return false;
      if (info.title !== undefined && !(t.host && t.title === info.title)) return false;
      return true;
    }
    var browser = {
      runtime: {
        getURL: function(path) { return 'webkit-extension://fixture' + path; },
        getManifest: function() { return manifest; },
        get lastError() { return lastError; },
        sendNativeMessage: function(app, body) {
          if (body.kind !== 'request') return Promise.resolve(true);
          bridgeLog.push(body.method);
          if (body.method === 'tabs.identityToken') return Promise.resolve(tokenMode === 'ok' ? 'token-' + (++tokens) : null);
          if (body.method === 'tabs.metadata') {
            lastMetadata = body.params;
            if (metaMode === 'null') return Promise.resolve(null);
            var f = body.params.filter;
            return Promise.resolve(body.params.entries.map(function(e) {
              var t = tabs.filter(function(x) { return x.windowId === 10; })[e.index];
              if (!t || e.window !== 'normal') return null;
              if (f && !matchesQuery(Object.assign({}, f, {}), Object.assign({}, t, {host: true}))) return null;
              return {url: t.url, title: t.host ? 'NOT WEBKIT' : t.title};
            }));
          }
          return Promise.resolve(null);
        },
        connectNative: function() { return {onMessage: {addListener: function() {}}, onDisconnect: {addListener: function() {}}, postMessage: function() {}, disconnect: function() {}}; }
      },
      tabs: {
        query: function(info, cb) { count('query'); queries.push(JSON.stringify(info)); if (info && info.invalid) throw new TypeError('Invalid query'); return settle(cb, tabs.filter(function(t) { return matchesQuery(info || {}, t); }).map(view)); },
        get: function(id, cb) { count('get'); var t = tabs.filter(function(x) { return x.id === id; })[0]; return settle(cb, t && view(t), t ? null : 'Invalid tab identifier ' + id + '.'); },
        getCurrent: function(cb) { count('getCurrent'); return settle(cb, undefined); },
        create: function(p, cb) { count('create'); var t = {id: tabs.length + 1, windowId: 10, index: tabs.length, url: p.url, title: 'Created', host: false}; tabs.push(t); return settle(cb, view(t)); },
        update: function(id, p, cb) { count('update'); var t = tabs.filter(function(x) { return x.id === id; })[0]; return settle(cb, t && view(t), t ? null : 'Invalid tab identifier ' + id + '.'); },
        onCreated: makeEvent(), onUpdated: makeEvent(), onActivated: makeEvent(), onRemoved: makeEvent(), onMoved: makeEvent()
      },
      windows: {
        getAll: function(info, cb) { count('getAll'); var w = {id: 10, type: 'normal'}; if (info && info.populate) w.tabs = tabs.map(view); return settle(cb, [w]); },
        get: function(id, info, cb) { count('windowsGet'); var w = {id: 10, type: 'normal'}; if (info && info.populate) w.tabs = tabs.map(view); return settle(cb, id === 10 ? w : undefined, id === 10 ? null : 'No window with id: ' + id + '.'); },
        onCreated: makeEvent(), onRemoved: makeEvent(), onFocusChanged: makeEvent()
      }
    };
    var lastMetadata = null;
    var nativeQuery = browser.tabs.query, nativeAdd = browser.tabs.onUpdated.addListener;
    """

    @available(macOS 15.4, *)
    static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }

        func context(permissions: [String]) -> (JSContext, () -> [String]) {
            let manifest: [String: Any] = ["manifest_version": 3, "name": "Original tabs fixture", "version": "1.0", "permissions": permissions]
            let json = String(data: try! JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!
            let js = JSContext()!
            var errors: [String] = []
            js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
            js.evaluateScript("var manifest = \(json);\n" + fakeEngine)
            js.evaluateScript(ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: "test"))
            return (js, { errors })
        }
        @discardableResult func eval(_ js: JSContext, _ source: String) -> JSValue { js.evaluateScript(source)! }

        // MARK: Without `tabs` nothing is wrapped.
        let (plain, plainErrors) = context(permissions: ["storage"])
        try check(eval(plain, "browser.tabs.query === nativeQuery && browser.tabs.onUpdated.addListener === nativeAdd").toBool() && plainErrors().isEmpty,
                  "An extension without tabs must keep WebKit's own tabs API")

        let (js, errors) = context(permissions: ["tabs"])
        try check(errors().isEmpty, "Facade failed to install: \(errors())")
        try check(eval(js, "browser.tabs.query !== nativeQuery && browser.tabs.query.__bamTabMetadataNative === nativeQuery").toBool(),
                  "tabs.query must be wrapped once, keeping WebKit's own function")

        // MARK: Reads: blanked tabs get url/title by WebKit tab id; same URL stays distinct; WebKit's values are kept.
        eval(js, "var r1; browser.tabs.query({}).then(function(v) { r1 = v; });")
        try check(eval(js, "r1.length === 3 && r1[0].url === 'https://a.test/x' && r1[0].title === 'First' && r1[1].url === 'https://a.test/x' && r1[1].title === 'Second, same URL'").toBool(),
                  "Same-URL tabs must each get their own title: \(eval(js, "JSON.stringify(r1)"))")
        try check(eval(js, "r1[2].title === 'Shown by WebKit' && r1[2].url === 'https://b.test/'").toBool(), "A value WebKit showed must never be replaced")
        try check(eval(js, "bridgeLog.join() === 'tabs.identityToken,tabs.metadata' && lastMetadata.normalCount === 1 && lastMetadata.popupCount === 0 && lastMetadata.entries.length === 3 && lastMetadata.entries[1].index === 1").toBool(),
                  "A read must be token, fresh read, then one bound answer: \(eval(js, "JSON.stringify([bridgeLog, lastMetadata])"))")

        // MARK: Errors stay WebKit's: synchronous throw, callback lastError, promise rejection; no bridge traffic.
        eval(js, "bridgeLog = []; var threw = null; try { browser.tabs.query({invalid: true}); } catch (e) { threw = e; }")
        try check(eval(js, "threw instanceof TypeError && threw.message === 'Invalid query' && bridgeLog.length === 0").toBool(), "A synchronous WebKit throw must reach the caller unchanged")
        eval(js, "var seenError = null, callbackArgs = null; browser.tabs.get(999, function() { callbackArgs = arguments.length; seenError = browser.runtime.lastError && browser.runtime.lastError.message; });")
        try check(eval(js, "seenError === 'Invalid tab identifier 999.' && callbackArgs === 0 && bridgeLog.length === 0").toBool(),
                  "Callback form must see WebKit's own runtime.lastError inside the callback")
        eval(js, "var rejected = null; browser.tabs.get(999).catch(function(e) { rejected = e.message; });")
        try check(eval(js, "rejected === 'Invalid tab identifier 999.'").toBool(), "Promise form must reject with WebKit's error")

        // MARK: Callback success is supplemented, with no lastError.
        eval(js, "var cbTab = null, cbError = 'unset'; browser.tabs.get(2, function(t) { cbTab = t; cbError = browser.runtime.lastError; });")
        try check(eval(js, "cbTab && cbTab.title === 'Second, same URL' && cbError === null").toBool(), "A callback success must be supplemented without an error")

        // MARK: Mutations run exactly once; the result is supplemented by a read.
        eval(js, "calls = {}; var created = null; browser.tabs.create({url: 'https://c.test/'}).then(function(t) { created = t; });")
        try check(eval(js, "calls.create === 1 && calls.get === 1 && created.url === 'https://c.test/' && created.title === 'Created'").toBool(),
                  "tabs.create must run once and be supplemented: \(eval(js, "JSON.stringify([calls, created])"))")
        eval(js, "tabs.pop();")

        // MARK: url/title filters: re-run without them and keep tabs the native answer matched.
        eval(js, "bridgeLog = []; queries = []; var filtered; browser.tabs.query({url: 'https://a.test/*', active: true}).then(function(v) { filtered = v; });")
        try check(eval(js, "filtered.length === 1 && filtered[0].id === 1 && filtered[0].title === 'First'").toBool(),
                  "A url filter must match blanked tabs through the native answer, other filters kept: \(eval(js, "JSON.stringify(filtered)"))")
        try check(eval(js, "queries[0] === JSON.stringify({url: 'https://a.test/*', active: true}) && queries[1] === JSON.stringify({active: true}) && lastMetadata.filter.url === 'https://a.test/*'").toBool(),
                  "The original filtered query must run first, then the stripped query: \(eval(js, "JSON.stringify(queries)"))")
        eval(js, "var byTitle; browser.tabs.query({title: 'Shown by WebKit'}).then(function(v) { byTitle = v; });")
        try check(eval(js, "byTitle.length === 1 && byTitle[0].id === 3").toBool(), "A tab WebKit could see must keep WebKit's own filter result")

        // MARK: Fallback: no answer after 3 attempts keeps WebKit's own result; no token means no answer request.
        eval(js, "metaMode = 'null'; bridgeLog = []; var fallback; browser.tabs.query({}).then(function(v) { fallback = v; });")
        try check(eval(js, "fallback.length === 3 && fallback[0].url === '' && bridgeLog.filter(function(m) { return m === 'tabs.metadata'; }).length === 3").toBool(),
                  "Refused answers must retry at most 3 times, then keep WebKit's redacted result")
        eval(js, "metaMode = 'ok'; tokenMode = 'null'; bridgeLog = []; var refused; browser.tabs.query({}).then(function(v) { refused = v; });")
        try check(eval(js, "refused[0].url === '' && bridgeLog.join() === 'tabs.identityToken'").toBool(), "Without a token nothing may be requested or filled")
        eval(js, "tokenMode = 'ok';")

        // MARK: Populated windows.
        eval(js, "var wins; browser.windows.getAll({populate: true}).then(function(v) { wins = v; });")
        try check(eval(js, "wins[0].tabs[1].title === 'Second, same URL' && wins[0].tabs[0].url === 'https://a.test/x'").toBool(), "Populated windows must be supplemented")

        // MARK: Events: FIFO across tabs/windows listeners; changeInfo keys only when WebKit sent them; removal holds.
        eval(js, """
        var order = [], updates = [];
        var onUpdated = function(id, info, tab) { order.push('updated'); updates.push({info: info, tab: tab}); };
        var onActivated = function() { order.push('activated'); };
        browser.tabs.onUpdated.addListener(onUpdated);
        browser.tabs.onActivated.addListener(onActivated);
        browser.tabs.onUpdated.fire(1, {url: ''}, view(tabs[0]));
        browser.tabs.onActivated.fire({tabId: 1, windowId: 10});
        browser.tabs.onUpdated.fire(2, {status: 'complete'}, view(tabs[1]));
        """)
        try check(eval(js, "order.join() === 'updated,activated,updated'").toBool(), "Event order across listeners must be kept: \(eval(js, "order.join()"))")
        try check(eval(js, "updates[0].info.url === 'https://a.test/x' && updates[0].tab.title === 'First' && !('title' in updates[0].info)").toBool(),
                  "changeInfo.url must be filled only because WebKit sent it; no title key invented: \(eval(js, "JSON.stringify(updates[0])"))")
        try check(eval(js, "!('url' in updates[1].info) && !('title' in updates[1].info) && updates[1].tab.title === 'Second, same URL'").toBool(),
                  "A changeInfo without url/title keys must stay without them")
        try check(eval(js, "browser.tabs.onUpdated.hasListener(onUpdated) && browser.tabs.onUpdated.listeners.length === 1").toBool(), "hasListener must see the caller's listener")
        eval(js, "metaMode = 'null'; browser.tabs.onUpdated.fire(1, {url: ''}, view(tabs[0])); browser.tabs.onUpdated.removeListener(onUpdated);")
        // The pending event waits on timers that never fire here: once removed, the listener must not be called.
        eval(js, "metaMode = 'ok'; timers.forEach(function(fn) { fn(); });")
        try check(eval(js, "updates.length === 2 && !browser.tabs.onUpdated.hasListener(onUpdated) && browser.tabs.onUpdated.listeners.length === 0").toBool(),
                  "A removed listener must not be called again: \(eval(js, "updates.length"))")
        try check(errors().isEmpty, "Facade raised JavaScript errors: \(errors())")

        print("ExtensionTabMetadataFacadeTests: \(checks) checks passed")
    }
}
