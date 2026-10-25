import Foundation
import WebKit
import JavaScriptCore

/// The tab metadata facade's JavaScript (ExtensionCompatibility worker script) against a fake engine that redacts like
/// WebKit: url/title blank without host access, url/title query filters never match a blanked tab. The native bridge,
/// clock and timers are faked so replies can be held, delayed and released late. This checks only the facade's own
/// behavior; native authority and observation checks are covered by the in-app regressions.
@main @MainActor enum ExtensionTabMetadataFacadeTests {
    struct Failure: Error { let message: String }
    static func main() async throws {
        guard #available(macOS 15.4, *) else { print("SKIP: Compatibility requires macOS 15.4"); return }
        try run()
    }

    /// `distinctRoots` (set before this script) makes `chrome` a separate root with its own event objects.
    static let fakeEngine = """
    var console = {error: function() {}, log: function() {}};
    var clock = 0, timers = [], nextTimer = 0;
    var performance = {now: function() { return clock; }};
    function setTimeout(fn, ms) { var id = ++nextTimer; timers.push({fn: fn, at: clock + (ms || 0), id: id}); return id; }
    function clearTimeout(id) { timers = timers.filter(function(t) { return t.id !== id; }); }
    function advance(ms) { clock += ms; var due = timers.filter(function(t) { return t.at <= clock; }); timers = timers.filter(function(t) { return t.at > clock; }); due.forEach(function(t) { t.fn(); }); }
    var location = {origin: 'webkit-extension://fixture', href: 'webkit-extension://fixture/worker.js'};
    var lastError = null, calls = {}, bridgeLog = [], queries = [], tokenMode = 'ok', metaMode = 'ok', tokens = 0, held = [], afterQuery = null;
    var lastMetadata = null;
    var tabs = [
      {id: 1, windowId: 10, index: 0, url: 'https://a.test/x', title: 'First', host: false},
      {id: 2, windowId: 10, index: 1, url: 'https://a.test/x', title: 'Second, same URL', host: false},
      {id: 3, windowId: 10, index: 2, url: 'https://b.test/', title: 'Shown by WebKit', host: true},
      {id: 4, windowId: 10, index: 3, url: 'https://c.test/', title: 'Native title', host: false, showTitle: true},
      {id: 5, windowId: 10, index: 4, url: 'https://d.test/', title: 'Untitled for WebKit', host: true, hideTitle: true}
    ];
    function count(name) { calls[name] = (calls[name] || 0) + 1; }
    function view(t) {
      var v = {id: t.id, windowId: t.windowId, index: t.index, active: t.index === 0, url: t.host ? t.url : ''};
      if ((t.host && !t.hideTitle) || t.showTitle) v.title = t.title;
      return v;
    }
    function prefix(pattern, url) { return url.indexOf(pattern.replace(/\\*$/, '')) === 0; }
    function settle(cb, value, error) {
      if (cb) { if (error) { lastError = {message: error}; cb(); lastError = null; } else cb(value); return undefined; }
      return error ? Promise.reject(new Error(error)) : Promise.resolve(value);
    }
    function makeEvent() { return { listeners: [],
      addListener: function(fn) { if (this.listeners.indexOf(fn) < 0) this.listeners.push(fn); },
      removeListener: function(fn) { this.listeners = this.listeners.filter(function(x) { return x !== fn; }); },
      hasListener: function(fn) { return this.listeners.indexOf(fn) >= 0; },
      fire: function() { var args = arguments; this.listeners.slice().forEach(function(fn) { fn.apply(null, args); }); } }; }
    function matchesQuery(info, t) {
      if (info.active !== undefined && (t.index === 0) !== info.active) return false;
      if (info.url !== undefined && !(t.host && [].concat(info.url).some(function(p) { return prefix(p, t.url); }))) return false;
      if (info.title !== undefined && !(t.host && t.title === info.title)) return false;
      return true;
    }
    function reply(value) {
      if (metaMode === 'hold') return new Promise(function(resolve) { held.push(function() { resolve(value); }); });
      return Promise.resolve(value);
    }
    function release() { var waiting = held; held = []; waiting.forEach(function(fn) { fn(); }); }
    function makeRoot() { return {
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
            return reply(body.params.entries.map(function(e) {
              var t = tabs.filter(function(x) { return x.windowId === 10; })[e.index];
              if (!t || e.window !== 'normal') return null;
              if (f && !matchesQuery(f, Object.assign({}, t, {host: true}))) return null;
              return {url: t.url, title: 'BRIDGE ' + t.title};
            }));
          }
          return Promise.resolve(null);
        },
        connectNative: function() { return {onMessage: {addListener: function() {}}, onDisconnect: {addListener: function() {}}, postMessage: function() {}, disconnect: function() {}}; }
      },
      tabs: {
        query: function(info, cb) {
          count('query'); queries.push(JSON.stringify(info)); if (info && info.invalid) throw new TypeError('Invalid query');
          var result = tabs.filter(function(t) { return matchesQuery(info || {}, t); }).map(view);
          if (afterQuery) { var hook = afterQuery; afterQuery = null; hook(); }
          return settle(cb, result);
        },
        get: function(id, cb) { count('get'); var t = tabs.filter(function(x) { return x.id === id; })[0]; return settle(cb, t && view(t), t ? null : 'Invalid tab identifier ' + id + '.'); },
        getCurrent: function(cb) { count('getCurrent'); return settle(cb, undefined); },
        create: function(p, cb) { count('create'); var t = {id: 9, windowId: 10, index: tabs.length, url: p.url, title: 'Created', host: false}; tabs.push(t); return settle(cb, view(t)); },
        update: function(id, p, cb) { count('update'); var t = tabs.filter(function(x) { return x.id === id; })[0]; return settle(cb, t && view(t), t ? null : 'Invalid tab identifier ' + id + '.'); },
        onCreated: makeEvent(), onUpdated: makeEvent(), onActivated: makeEvent(), onRemoved: makeEvent(), onMoved: makeEvent()
      },
      windows: {
        getAll: function(info, cb) { count('getAll'); var w = {id: 10, type: 'normal'}; if (info && info.populate) w.tabs = tabs.map(view); return settle(cb, [w]); },
        get: function(id, info, cb) { count('windowsGet'); var w = {id: 10, type: 'normal'}; if (info && info.populate) w.tabs = tabs.map(view); return settle(cb, id === 10 ? w : undefined, id === 10 ? null : 'No window with id: ' + id + '.'); },
        onCreated: makeEvent(), onRemoved: makeEvent(), onFocusChanged: makeEvent()
      }
    }; }
    var browser = makeRoot();
    var chrome = distinctRoots ? makeRoot() : browser;
    var nativeQuery = browser.tabs.query, nativeAdd = browser.tabs.onUpdated.addListener;
    """

    @available(macOS 15.4, *)
    static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }

        func context(permissions: [String], distinctRoots: Bool = false) -> (JSContext, () -> [String]) {
            let manifest: [String: Any] = ["manifest_version": 3, "name": "Original tabs fixture", "version": "1.0", "permissions": permissions]
            let json = String(data: try! JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!
            let js = JSContext()!
            var errors: [String] = []
            js.exceptionHandler = { _, error in errors.append(error?.toString() ?? "JavaScript error") }
            js.evaluateScript("var manifest = \(json); var distinctRoots = \(distinctRoots);\n" + fakeEngine)
            js.evaluateScript(ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: "test"))
            return (js, { errors })
        }
        @discardableResult func eval(_ js: JSContext, _ source: String) -> JSValue { js.evaluateScript(source)! }

        // MARK: The fake clock's timer IDs are unique, so clearing one never cancels another.
        let (clockCheck, _) = context(permissions: ["storage"])
        eval(clockCheck, """
        var fired = []; var t1 = setTimeout(function() { fired.push(1); }, 10), t2 = setTimeout(function() { fired.push(2); }, 10);
        clearTimeout(t1); var t3 = setTimeout(function() { fired.push(3); }, 10); clearTimeout(t2); advance(10);
        """)
        try check(eval(clockCheck, "t1 === 1 && t2 === 2 && t3 === 3 && fired.join() === '3'").toBool(),
                  "Fake timers must use unique IDs: \(eval(clockCheck, "[t1, t2, t3, fired.join()].join('|')"))")

        // MARK: The review names the capability in words, never the internal plan key.
        let label = ExtensionCompatibility.reviewLabel(["notifications", "tabs.metadata"])
        try check(label == "notifications, tab addresses and titles (requires the tabs permission; no page-content access)" && !label.contains("tabs.metadata"),
                  "The tab metadata review label must be human-readable: \(label)")

        // MARK: Without `tabs` nothing is wrapped.
        let (plain, plainErrors) = context(permissions: ["storage"])
        try check(eval(plain, "browser.tabs.query === nativeQuery && browser.tabs.onUpdated.addListener === nativeAdd").toBool() && plainErrors().isEmpty,
                  "An extension without tabs must keep WebKit's own tabs API")

        let (js, errors) = context(permissions: ["tabs"])
        try check(errors().isEmpty, "Facade failed to install: \(errors())")
        try check(eval(js, "browser.tabs.query !== nativeQuery && browser.tabs.query.__bamTabMetadataNative === nativeQuery").toBool(),
                  "tabs.query must be wrapped once, keeping WebKit's own function")

        // MARK: Reads: blank fields filled by WebKit tab id, each field on its own; WebKit's values kept.
        eval(js, "var r1; browser.tabs.query({}).then(function(v) { r1 = v; });")
        try check(eval(js, "r1.length === 5 && r1[0].url === 'https://a.test/x' && r1[0].title === 'BRIDGE First' && r1[1].url === 'https://a.test/x' && r1[1].title === 'BRIDGE Second, same URL'").toBool(),
                  "Same-URL tabs must each get their own title: \(eval(js, "JSON.stringify(r1)"))")
        try check(eval(js, "r1[2].title === 'Shown by WebKit' && r1[2].url === 'https://b.test/'").toBool(), "Values WebKit showed must never be replaced")
        try check(eval(js, "r1[3].url === 'https://c.test/' && r1[3].title === 'Native title'").toBool(),
                  "A blank url must not replace a title WebKit showed: \(eval(js, "JSON.stringify(r1[3])"))")
        try check(eval(js, "r1[4].url === 'https://d.test/' && r1[4].title === 'BRIDGE Untitled for WebKit'").toBool(),
                  "A blank title must be filled even when WebKit showed the url: \(eval(js, "JSON.stringify(r1[4])"))")
        try check(eval(js, "bridgeLog.join() === 'tabs.identityToken,tabs.metadata' && lastMetadata.normalCount === 1 && lastMetadata.popupCount === 0 && lastMetadata.entries.length === 5").toBool(),
                  "A read must be token, fresh read, then one bound answer: \(eval(js, "JSON.stringify([bridgeLog, lastMetadata])"))")

        // MARK: Errors stay WebKit's: synchronous throw, callback lastError, promise rejection; no bridge traffic.
        eval(js, "bridgeLog = []; var threw = null; try { browser.tabs.query({invalid: true}); } catch (e) { threw = e; }")
        try check(eval(js, "threw instanceof TypeError && threw.message === 'Invalid query' && bridgeLog.length === 0").toBool(), "A synchronous WebKit throw must reach the caller unchanged")
        eval(js, "var seenError = null, callbackArgs = null; browser.tabs.get(999, function() { callbackArgs = arguments.length; seenError = browser.runtime.lastError && browser.runtime.lastError.message; });")
        try check(eval(js, "seenError === 'Invalid tab identifier 999.' && callbackArgs === 0 && bridgeLog.length === 0").toBool(),
                  "Callback form must see WebKit's own runtime.lastError inside the callback")
        eval(js, "var rejected = null; browser.tabs.get(999).catch(function(e) { rejected = e.message; });")
        try check(eval(js, "rejected === 'Invalid tab identifier 999.'").toBool(), "Promise form must reject with WebKit's error")
        eval(js, "var cbTab = null, cbError = 'unset'; browser.tabs.get(2, function(t) { cbTab = t; cbError = browser.runtime.lastError; });")
        try check(eval(js, "cbTab && cbTab.title === 'BRIDGE Second, same URL' && cbError === null").toBool(), "A callback success must be supplemented without an error")

        // MARK: Mutations run exactly once; the result is supplemented by a read.
        eval(js, "calls = {}; var created = null; browser.tabs.create({url: 'https://e.test/'}).then(function(t) { created = t; });")
        try check(eval(js, "calls.create === 1 && calls.get === 1 && created.url === 'https://e.test/' && created.title === 'BRIDGE Created'").toBool(),
                  "tabs.create must run once and be supplemented: \(eval(js, "JSON.stringify([calls, created])"))")
        eval(js, "tabs.pop();")

        // MARK: Filtered queries keep WebKit's own matches, even if the tab navigated before the reread.
        eval(js, """
        queries = []; var nav;
        afterQuery = function() { tabs[2].url = 'https://z.test/'; tabs[2].title = 'Navigated away'; };
        browser.tabs.query({url: 'https://b.test/*'}).then(function(v) { nav = v; });
        """)
        try check(eval(js, "nav.length === 1 && nav[0].id === 3 && nav[0].url === 'https://b.test/' && nav[0].title === 'Shown by WebKit'").toBool(),
                  "A native match must keep WebKit's own values after navigating between reads: \(eval(js, "JSON.stringify(nav)"))")
        try check(eval(js, "queries[0] === JSON.stringify({url: 'https://b.test/*'}) && queries[1] === '{}'").toBool(),
                  "The original filtered query must run first, then the stripped reread: \(eval(js, "JSON.stringify(queries)"))")
        eval(js, "tabs[2].url = 'https://b.test/'; tabs[2].title = 'Shown by WebKit';")
        eval(js, "var filtered; browser.tabs.query({url: 'https://a.test/*', active: true}).then(function(v) { filtered = v; });")
        try check(eval(js, "filtered.length === 1 && filtered[0].id === 1 && filtered[0].title === 'BRIDGE First' && lastMetadata.filter.url === 'https://a.test/*'").toBool(),
                  "A url filter must match blanked tabs through the native answer, other filters kept: \(eval(js, "JSON.stringify(filtered)"))")
        eval(js, "var vanished; afterQuery = function() { tabs.splice(2, 1); tabs.forEach(function(t, i) { t.index = i; }); }; browser.tabs.query({url: 'https://b.test/*'}).then(function(v) { vanished = v; });")
        try check(eval(js, "vanished.length === 1 && vanished[0].id === 3 && vanished[0].url === 'https://b.test/'").toBool(),
                  "A native match missing from the reread must still be returned as WebKit gave it: \(eval(js, "JSON.stringify(vanished)"))")
        eval(js, "tabs.splice(2, 0, {id: 3, windowId: 10, index: 2, url: 'https://b.test/', title: 'Shown by WebKit', host: true}); tabs.forEach(function(t, i) { t.index = i; });")

        // MARK: Fallback: 3 completed refusals keep WebKit's result; no token means no answer request.
        eval(js, "metaMode = 'null'; bridgeLog = []; var fallback; browser.tabs.query({}).then(function(v) { fallback = v; });")
        try check(eval(js, "fallback.length === 5 && fallback[0].url === '' && bridgeLog.filter(function(m) { return m === 'tabs.metadata'; }).length === 3").toBool(),
                  "Refused answers must retry at most 3 times, then keep WebKit's redacted result")
        eval(js, "metaMode = 'ok'; tokenMode = 'null'; bridgeLog = []; var refused; browser.tabs.query({}).then(function(v) { refused = v; });")
        try check(eval(js, "refused[0].url === '' && bridgeLog.join() === 'tabs.identityToken'").toBool(), "Without a token nothing may be requested or filled")
        eval(js, "tokenMode = 'ok';")

        // MARK: Read deadline: a held answer delivers WebKit's result once at 2 s; a late answer changes nothing.
        eval(js, """
        metaMode = 'hold'; var slow = null, slowCalls = 0, slowValue = null;
        browser.tabs.query({}).then(function(v) { slow = v; });
        browser.tabs.get(1, function(t) { slowCalls++; slowValue = t; });
        """)
        try check(eval(js, "slow === null && slowCalls === 0 && held.length === 2").toBool(), "A held answer must hold delivery until the deadline")
        eval(js, "advance(1999);")
        try check(eval(js, "slow === null && slowCalls === 0").toBool(), "Nothing may be delivered before the 2 s deadline")
        eval(js, "advance(1);")
        try check(eval(js, "slow && slow[0].url === '' && slowCalls === 1 && slowValue.url === ''").toBool(),
                  "At the deadline WebKit's own result must be delivered once: \(eval(js, "JSON.stringify([slow && slow[0], slowCalls])"))")
        eval(js, "metaMode = 'ok'; release();")
        try check(eval(js, "slow[0].url === '' && slow[0].title === undefined && slowCalls === 1 && slowValue.url === ''").toBool(),
                  "A late answer must not change delivered objects or call back again")

        // MARK: Populated windows.
        eval(js, "var wins; browser.windows.getAll({populate: true}).then(function(v) { wins = v; });")
        try check(eval(js, "wins[0].tabs[1].title === 'BRIDGE Second, same URL' && wins[0].tabs[0].url === 'https://a.test/x'").toBool(), "Populated windows must be supplemented")

        // MARK: Events: FIFO across listeners; copies, never WebKit's objects; changeInfo keys only when WebKit sent them.
        eval(js, """
        var order = [], updates = [];
        var onUpdated = function(id, info, tab) { order.push('updated'); updates.push({info: info, tab: tab}); };
        var onActivated = function() { order.push('activated'); };
        browser.tabs.onUpdated.addListener(onUpdated);
        browser.tabs.onActivated.addListener(onActivated);
        var sentInfo = {url: ''}, sentTab = view(tabs[0]);
        browser.tabs.onUpdated.fire(1, sentInfo, sentTab);
        browser.tabs.onActivated.fire({tabId: 1, windowId: 10});
        browser.tabs.onUpdated.fire(2, {status: 'complete'}, view(tabs[1]));
        """)
        try check(eval(js, "order.join() === 'updated,activated,updated'").toBool(), "Event order across listeners must be kept: \(eval(js, "order.join()"))")
        try check(eval(js, "updates[0].info.url === 'https://a.test/x' && updates[0].tab.title === 'BRIDGE First' && !('title' in updates[0].info)").toBool(),
                  "changeInfo.url must be filled only because WebKit sent it; no title key invented: \(eval(js, "JSON.stringify(updates[0])"))")
        try check(eval(js, "sentInfo.url === '' && sentTab.url === '' && updates[0].tab !== sentTab").toBool(), "WebKit's own event objects must never be changed")
        try check(eval(js, "!('url' in updates[1].info) && !('title' in updates[1].info) && updates[1].tab.title === 'BRIDGE Second, same URL'").toBool(),
                  "A changeInfo without url/title keys must stay without them")

        // MARK: Event deadline: held at 1 s, WebKit's values are delivered; a late answer changes nothing.
        eval(js, "metaMode = 'hold'; var heldTab = view(tabs[0]), heldInfo = {url: ''}; browser.tabs.onUpdated.fire(1, heldInfo, heldTab);")
        try check(eval(js, "updates.length === 2").toBool(), "A held event must wait for its answer")
        eval(js, "advance(1000);")
        try check(eval(js, "updates.length === 3 && updates[2].tab === heldTab && heldTab.url === ''").toBool(), "At the event deadline WebKit's own values must be delivered")
        eval(js, "metaMode = 'ok'; release();")
        try check(eval(js, "heldTab.url === '' && heldInfo.url === '' && updates.length === 3").toBool(), "A late event answer must not mutate delivered objects or deliver again")

        // MARK: Removal while held: the listener is not called again.
        eval(js, "metaMode = 'hold'; browser.tabs.onUpdated.fire(1, {url: ''}, view(tabs[0])); browser.tabs.onUpdated.removeListener(onUpdated); advance(1000); metaMode = 'ok'; release();")
        try check(eval(js, "updates.length === 3 && !browser.tabs.onUpdated.hasListener(onUpdated) && browser.tabs.onUpdated.listeners.length === 0").toBool(),
                  "A removed listener must not be called again")

        // MARK: Bounded FIFO: a held event plus a burst beyond 256 delivers everything at once, in order, unchanged.
        eval(js, """
        var burst = [];
        var onUpdatedBurst = function(id, info, tab) { burst.push('u' + id + ':' + tab.url); };
        var onActivatedBurst = function(info) { burst.push('a' + info.tabId); };
        browser.tabs.onUpdated.addListener(onUpdatedBurst);
        browser.tabs.onActivated.removeListener(onActivated);
        browser.tabs.onActivated.addListener(onActivatedBurst);
        metaMode = 'hold';
        var burstTab = view(tabs[0]);
        browser.tabs.onUpdated.fire(1, {url: ''}, burstTab);
        // One held plus 255 queued is the cap (256): nothing delivered yet.
        for (var i = 0; i < 255; i++) browser.tabs.onActivated.fire({tabId: i, windowId: 10});
        var beforeOverflow = burst.length;
        browser.tabs.onActivated.fire({tabId: 255, windowId: 10});
        var atOverflow = burst.length;
        """)
        try check(eval(js, "beforeOverflow === 0 && atOverflow === 257 && burst[0] === 'u1:' && burst[1] === 'a0' && burst[256] === 'a255'").toBool(),
                  "Overload must deliver the held event and the queue at once, synchronously and in order: \(eval(js, "[beforeOverflow, atOverflow, burst[0], burst[1], burst[256]].join()"))")
        eval(js, "browser.tabs.onActivated.fire({tabId: 900, windowId: 10});")
        try check(eval(js, "burst.length === 258 && burst[257] === 'a900'").toBool(),
                  "Delivery must continue at once after an overload, not behind the abandoned wait: \(eval(js, "burst.length"))")
        eval(js, "metaMode = 'ok'; release(); advance(1000);")
        try check(eval(js, "burst.length === 258 && burstTab.url === ''").toBool(), "After an overload flush a late answer must not deliver or mutate")
        try check(errors().isEmpty, "Facade raised JavaScript errors: \(errors())")

        // MARK: Listener tables per actual event object: distinct roots are separate registrations; aliases share one.
        let (two, twoErrors) = context(permissions: ["tabs"], distinctRoots: true)
        eval(two, """
        var hits = [];
        var shared = function(id) { hits.push(id); };
        browser.tabs.onActivated.addListener(shared);
        chrome.tabs.onActivated.addListener(shared);
        chrome.tabs.onActivated.removeListener(shared);
        browser.tabs.onActivated.fire({tabId: 1});
        chrome.tabs.onActivated.fire({tabId: 2});
        """)
        try check(eval(two, "browser !== chrome && hits.length === 1 && hits[0].tabId === 1 && browser.tabs.onActivated.hasListener(shared) && !chrome.tabs.onActivated.hasListener(shared)").toBool(),
                  "Removing through one root must not affect the other root's registration: \(eval(two, "JSON.stringify(hits)"))")
        eval(two, "chrome.tabs.onActivated.addListener(shared); chrome.tabs.onActivated.fire({tabId: 3}); browser.tabs.onActivated.fire({tabId: 4});")
        try check(eval(two, "hits.length === 3 && hits[1].tabId === 3 && hits[2].tabId === 4").toBool(), "Re-adding through one root must deliver on that root only")
        try check(twoErrors().isEmpty, "Distinct-root facade raised errors: \(twoErrors())")
        let (alias, aliasErrors) = context(permissions: ["tabs"])
        eval(alias, "var aliasHits = 0; var f = function() { aliasHits++; }; browser.tabs.onActivated.addListener(f); chrome.tabs.onActivated.addListener(f); browser.tabs.onActivated.fire({tabId: 1});")
        try check(eval(alias, "browser === chrome && aliasHits === 1 && browser.tabs.onActivated.listeners.length === 1").toBool(), "Aliased roots must keep WebKit's de-duplication")
        eval(alias, "chrome.tabs.onActivated.removeListener(f); browser.tabs.onActivated.fire({tabId: 2});")
        try check(eval(alias, "aliasHits === 1 && !browser.tabs.onActivated.hasListener(f)").toBool(), "Removing through an alias must remove the one registration")
        try check(aliasErrors().isEmpty, "Alias facade raised errors: \(aliasErrors())")

        print("ExtensionTabMetadataFacadeTests: \(checks) checks passed")
    }
}
