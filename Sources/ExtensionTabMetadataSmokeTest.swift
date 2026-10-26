import AppKit
import WebKit

/// Native regressions for the Chrome `tabs` metadata facade (work/chrome-tab-metadata-api.md).
///
/// Original fixture extensions in their own profile, all on loopback fixture pages:
/// - "no-host": `tabs` + `scripting`, no host permissions. WebKit redacts its tab URLs/titles; the facade must add
///   them back by WebKit tab id, and nothing else (no host access, no script, no fetch, no grants).
/// - "authorized": `tabs` + the loopback host. WebKit shows real values; its native filter results are the reference.
/// - "no-tabs": `storage` only. No facade, nothing disclosed.
/// The engine's `BrowserExtensions.metadataTestHook` changes topology, permission or context between the token and the
/// answer; every such change must yield WebKit's own (redacted) answer, never a value on the wrong tab.
@available(macOS 15.4, *)
@MainActor enum ExtensionTabMetadataSmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(controller: BrowserController, host: BrowserExtensions, pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: "Tab metadata: " + message) }; checks += 1
        }
        func wait(_ message: String, timeout: TimeInterval = 12, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw Failure(description: "Tab metadata: " + message)
        }
        func page(_ path: String, _ query: String?) -> URL {
            var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
            components.path = path; components.query = query
            return components.url!
        }
        defer { BrowserExtensions.metadataTestHook = nil }

        // A profile of its own, shown in the background, with three loopback tabs: two share one URL.
        guard let profile = controller.session.createProfile(name: "Tab metadata"),
              controller.session.createSpace(name: "Tab metadata", symbol: "briefcase", colorIndex: 1, profileID: profile) != nil,
              let elsewhere = controller.session.createProfile(name: "Tab metadata other"),
              let elsewhereSpace = controller.session.createSpace(name: "Tab metadata other", symbol: "briefcase", colorIndex: 2, profileID: elsewhere) else {
            throw Failure(description: "Tab metadata: could not create the fixture profiles")
        }
        let config = WKWebViewConfiguration(); config.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(config, profileID: profile)
        guard let runtime = config.webExtensionController?.delegate as? BrowserExtensionRuntime else {
            throw Failure(description: "Tab metadata: no extension runtime for the fixture profile")
        }
        let sameURL = page("/next.html", "same"), plainURL = page("/index.html", "metadata"), eventsURL = page("/next.html", "events")
        var opened: [UUID] = []
        defer { for id in opened { _ = host.closeTab?(id) } }
        func open(_ url: URL) async throws -> UUID {
            guard let id = controller.openProfileTab(url, profileID: profile, active: false) else { throw Failure(description: "Tab metadata: could not open \(url)") }
            opened.append(id)
            try await wait("fixture tab did not load: \(url)") { controller.browsers[id]?.url == url && controller.browsers[id]?.isLoading == false }
            return id
        }
        func retitle(_ id: UUID, _ title: String) async throws {
            _ = try await controller.browsers[id]?.evaluateJavaScript("document.title = \(String(reflecting: title)); 0")
            try await wait("fixture tab did not take its title \(title)") { controller.session.tabs.first { $0.id == id }?.title == title }
        }
        let aID = try await open(sameURL), bID = try await open(sameURL)
        _ = try await open(plainURL)
        try await retitle(aID, "Same A"); try await retitle(bID, "Same B")
        // A candidate in another profile: its URL and title must never reach this profile's extensions.
        let candidateURL = page("/index.html", "other-profile-candidate"), candidateTitle = "Other profile candidate"
        guard let candidateID = controller.openProfileTab(candidateURL, profileID: elsewhere, active: false) else {
            throw Failure(description: "Tab metadata: could not open the other-profile candidate")
        }
        opened.append(candidateID)
        try await wait("the other-profile candidate did not load") { controller.browsers[candidateID]?.url == candidateURL && controller.browsers[candidateID]?.isLoading == false }
        try await retitle(candidateID, candidateTitle)
        let leaks: Set<String> = [candidateURL.absoluteString, candidateTitle]

        // Three original extensions in that profile.
        func install(_ name: String, _ manifest: [String: Any], background: String? = nil) async throws -> (id: UUID, context: WKWebExtensionContext, page: WKWebView) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-tab-metadata-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var definition = manifest
            definition["manifest_version"] = 3; definition["name"] = "Bam tab metadata \(name)"; definition["version"] = "1.0"
            definition["description"] = "Original Bam fixture for the tabs metadata facade (\(name))."
            if background != nil { definition["background"] = ["service_worker": "background.js"] }
            try JSONSerialization.data(withJSONObject: definition).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><meta charset='utf-8'><title>metadata page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
            if let background { try Data(background.utf8).write(to: folder.appendingPathComponent("background.js")) }
            let id = try await host.importPackage(at: folder, profileID: profile)
            guard let context = host.context(for: id), let configuration = context.webViewConfiguration else {
                throw Failure(description: "Tab metadata: \(name) extension did not load")
            }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
            web.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            try await wait("\(name) extension page did not load") { web.title == "metadata page" }
            return (id, context, web)
        }
        let worker = """
            browser.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || message.kind !== "query") return;
              const brief = (t) => ({id: t.id, index: t.index, url: t.url || "", title: t.title || ""});
              const native = browser.tabs.query.__bamTabMetadataNative;
              Promise.all([browser.tabs.query({}), native ? native.call(browser.tabs, {}) : Promise.resolve([])])
                .then(([wrapped, unwrapped]) => reply({facade: typeof native, wrapped: wrapped.map(brief), native: unwrapped.map(brief)}));
              return true;
            });
            """
        let noHost = try await install("no-host", ["permissions": ["tabs", "scripting"]], background: worker)
        let authorized = try await install("authorized", ["permissions": ["tabs"], "host_permissions": ["http://127.0.0.1/*"]])
        let noTabs = try await install("no-tabs", ["permissions": ["storage"]])
        let installed = [noHost.id, authorized.id, noTabs.id]
        defer { for page in [noHost.page, authorized.page, noTabs.page] { page.stopLoading() } }
        // The successful path removes these extensions strictly at the end. After a failure they are not removed here:
        // they stay in the caller's ephemeral controller, which the caller shuts down without persisting (its
        // prepareToClose defer). The hook is cleared on every exit (defer above).
        host.reconcile()

        let prelude = """
            const brief = (t) => ({id: t.id, index: t.index, windowId: t.windowId, url: t.url || "", title: t.title || ""});
            const nat = (ns, name, ...args) => { const h = browser[ns], f = h[name].__bamTabMetadataNative || h[name]; return f.apply(h, args); };

            """
        func js(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let text = try await web.callAsyncJavaScript("return JSON.stringify(await (async () => {\n" + prelude + body + "\n})());",
                                                          arguments: arguments, contentWorld: .page) as? String
            guard let data = text?.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(description: "Tab metadata: probe returned \(text ?? "nil")")
            }
            return value
        }
        func tabs(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
        func urls(_ list: [[String: Any]]) -> [String] { list.map { $0["url"] as? String ?? "" } }
        /// WebKit's redaction: neither a URL nor a title (absent and empty both count as redacted).
        func redacted(_ list: [[String: Any]]) -> Bool {
            list.allSatisfy { ($0["url"] as? String ?? "").isEmpty && ($0["title"] as? String ?? "").isEmpty }
        }
        func leaksNothing(_ list: [[String: Any]]) -> Bool {
            list.allSatisfy { !leaks.contains($0["url"] as? String ?? "") && !leaks.contains($0["title"] as? String ?? "") }
        }
        let fixtureURLs: Set<String> = [sameURL.absoluteString, plainURL.absoluteString]
        /// What Bam itself would show for this profile's tabs, in the order extensions see them.
        func expected() -> [(url: String, title: String)] {
            host.reconcile()
            return controller.session.tabs.filter { controller.session.profileID(for: $0) == profile }.map { ($0.address, $0.displayTitle) }
        }
        let wrappedQuery = "return {native: (await nat('tabs', 'query', {})).map(brief), wrapped: (await browser.tabs.query({})).map(brief)};"

        // 1. Facade present only with tabs; WebKit itself redacts the no-host extension; the facade adds exactly Bam's values.
        let presence = try await js(noHost.page, "return {query: typeof browser.tabs.query.__bamTabMetadataNative, chrome: typeof chrome.tabs.get.__bamTabMetadataNative};")
        let absent = try await js(noTabs.page, "return {query: typeof browser.tabs.query.__bamTabMetadataNative, tabs: (await browser.tabs.query({})).map(brief)};")
        try check(presence["query"] as? String == "function" && presence["chrome"] as? String == "function", "the facade is missing on browser or chrome: \(presence)")
        let first = try await js(noHost.page, wrappedQuery)
        let nativeTabs = tabs(first["native"]), wrappedTabs = tabs(first["wrapped"]), reference = expected()
        // Negative controls: no URL *and* no title, only this profile's tabs, and nothing from the other profile.
        try check(absent["query"] as? String == "undefined" && tabs(absent["tabs"]).count == reference.count && redacted(tabs(absent["tabs"])),
                  "an extension without tabs got the facade, a URL or a title, or another profile's tab: \(absent)")
        try check(nativeTabs.count == reference.count && redacted(nativeTabs),
                  "WebKit did not redact the no-host extension's URLs and titles (a host grant leaked?): \(nativeTabs)")
        try check(leaksNothing(wrappedTabs) && wrappedTabs.count == reference.count, "the facade disclosed another profile's tab: \(wrappedTabs)")
        try check(wrappedTabs.map { $0["id"] as? Int } == nativeTabs.map { $0["id"] as? Int }
                  && zip(wrappedTabs, reference).allSatisfy { ($0["url"] as? String) == $1.url && ($0["title"] as? String) == $1.title },
                  "the facade did not add exactly Bam's URL and title per tab: \(wrappedTabs) vs \(reference)")
        var titleByID: [Int: String] = [:]
        for tab in wrappedTabs { if let id = tab["id"] as? Int { titleByID[id] = tab["title"] as? String } }
        guard let aJS = titleByID.first(where: { $0.value == "Same A" })?.key, let bJS = titleByID.first(where: { $0.value == "Same B" })?.key else {
            throw Failure(description: "Tab metadata: same-URL tabs were not told apart: \(wrappedTabs)")
        }
        // Identity is WebKit's own tab id: pinning the tab the facade calls "Same A" keeps Bam's tab A, not B.
        _ = try await js(noHost.page, "await browser.tabs.update(id, {pinned: true}); return {};", ["id": aJS])
        try check(controller.session.tabs.first { $0.id == aID }?.saved?.kind == .kept && controller.session.tabs.first { $0.id == bID }?.saved == nil,
                  "the same-URL tab the facade named \"Same A\" is not Bam's tab A")
        _ = try await js(noHost.page, "await browser.tabs.update(id, {pinned: false}); return {};", ["id": aJS])
        try check(controller.session.tabs.first { $0.id == aID }?.saved == nil, "the identity probe tab stayed kept")

        // 2. get (promise and callback), populated windows, the worker; errors stay WebKit's.
        let reads = try await js(noHost.page, """
            const promise = brief(await browser.tabs.get(b));
            const callback = await new Promise((resolve) => chrome.tabs.get(b, (t) => resolve(brief(t))));
            const all = await browser.windows.getAll({populate: true});
            const normal = all.find((w) => w.type === 'normal');
            const single = await browser.windows.get(normal.id, {populate: true});
            const worker = await browser.runtime.sendMessage({kind: 'query'});
            const bad = 2147480000;
            const nativePromise = await nat('tabs', 'get', bad).then(() => 'resolved', (e) => String(e && e.message));
            const wrappedPromise = await browser.tabs.get(bad).then(() => 'resolved', (e) => String(e && e.message));
            const nativeCallback = await new Promise((resolve) => chrome.tabs.get.__bamTabMetadataNative.call(chrome.tabs, bad, () => resolve(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none')));
            const wrappedCallback = await new Promise((resolve) => chrome.tabs.get(bad, () => resolve(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none')));
            return {promise, callback, all: all.flatMap((w) => (w.tabs || []).map(brief)), single: (single.tabs || []).map(brief), worker,
                    nativePromise, wrappedPromise, nativeCallback, wrappedCallback};
            """, ["b": bJS])
        try check((reads["promise"] as? [String: Any])?["title"] as? String == "Same B" && (reads["callback"] as? [String: Any])?["title"] as? String == "Same B"
                  && (reads["promise"] as? [String: Any])?["url"] as? String == sameURL.absoluteString,
                  "tabs.get (promise or callback) did not show the tab's own URL and title: \(reads)")
        try check(fixtureURLs.isSubset(of: Set(urls(tabs(reads["all"])))) && fixtureURLs.isSubset(of: Set(urls(tabs(reads["single"]))))
                  && leaksNothing(tabs(reads["all"])) && leaksNothing(tabs(reads["single"])),
                  "populated windows did not show the tabs' URLs, or showed another profile's tab: \(reads)")
        let workerReply = reads["worker"] as? [String: Any]
        try check(workerReply?["facade"] as? String == "function" && fixtureURLs.isSubset(of: Set(urls(tabs(workerReply?["wrapped"]))))
                  && leaksNothing(tabs(workerReply?["wrapped"])) && redacted(tabs(workerReply?["native"])) && !tabs(workerReply?["native"]).isEmpty,
                  "the prepared worker did not get the facade, WebKit showed it a URL or title, or another profile leaked: \(String(describing: workerReply))")
        try check(reads["wrappedPromise"] as? String == reads["nativePromise"] as? String && reads["nativePromise"] as? String != "resolved"
                  && reads["wrappedCallback"] as? String == reads["nativeCallback"] as? String && reads["nativeCallback"] as? String != "none",
                  "an invalid tab id did not keep WebKit's own rejection and runtime.lastError: \(reads)")

        // 3. No authority: no host access, script, fetch or grant for the no-host extension.
        let authority = try await js(noHost.page, """
            const script = await browser.scripting.executeScript({target: {tabId: a}, func: () => document.title}).then(() => 'ran', (e) => 'refused');
            const fetched = await fetch(url, {credentials: 'include'}).then((r) => r.type === 'opaque' ? 'opaque' : 'read', () => 'refused');
            const contains = await browser.permissions.contains({origins: ['http://127.0.0.1/*']});
            return {script, fetched, contains};
            """, ["a": aJS, "url": sameURL.absoluteString])
        try check(authority["script"] as? String == "refused" && authority["fetched"] as? String != "read" && authority["contains"] as? Bool == false,
                  "tab metadata widened access (script, fetch or host permission): \(authority)")
        try check(!noHost.context.hasAccess(to: sameURL) && ![.grantedExplicitly, .grantedImplicitly].contains(noHost.context.permissionStatus(for: sameURL)),
                  "a host grant was recorded for the no-host extension")

        // 4. Filters: the facade's url/title filtering equals WebKit's own for an extension that may see the tabs.
        let filters: [String] = [
            "{url: '*://127.0.0.1/next.html*'}", "{title: 'Same*'}", "{title: 'same*'}", "{title: '*B'}",
            "{url: ['*://127.0.0.1/index.html*', '*://127.0.0.1/next.html?same'], title: '*A'}", "{url: '*://other.invalid/*'}",
        ]
        for filter in filters {
            let shape = ".map((t) => [t.index, t.url || '', t.title || ''])"
            // The reference is WebKit's own query (captured native method) for the extension with host access.
            let reference = try await js(authorized.page, "return {tabs: (await nat('tabs', 'query', \(filter)))\(shape)};")["tabs"] as? [[Any]]
            let facade = try await js(noHost.page, "return {tabs: (await browser.tabs.query(\(filter)))\(shape)};")["tabs"] as? [[Any]]
            try check(reference != nil && String(describing: reference!) == String(describing: facade ?? []),
                      "filter \(filter) differs from WebKit's own: \(String(describing: facade)) vs \(String(describing: reference))")
        }
        // WebKit may refuse synchronously (a throw from the call) or asynchronously (a rejected promise); record which,
        // separately for the facade and the captured native method, and require the same form and message.
        let invalid = try await js(noHost.page, """
            const outcome = async (call) => {
              let result;
              try { result = call(); } catch (error) { return {form: 'throw', message: String(error && error.message || error)}; }
              try { const value = await result; return {form: 'resolve', message: Array.isArray(value) ? 'tabs:' + value.length : typeof value}; }
              catch (error) { return {form: 'reject', message: String(error && error.message || error)}; }
            };
            const wrapped = await outcome(() => browser.tabs.query({url: 'not a pattern'}));
            const native = await outcome(() => nat('tabs', 'query', {url: 'not a pattern'}));
            return {wrapped, native};
            """)
        let wrappedOutcome = invalid["wrapped"] as? [String: Any], nativeOutcome = invalid["native"] as? [String: Any]
        try check(nativeOutcome?["form"] as? String != nil && nativeOutcome?["form"] as? String != "resolve" && !((nativeOutcome?["message"] as? String) ?? "").isEmpty,
                  "WebKit did not refuse an invalid url filter, so the facade comparison has no reference: \(invalid)")
        try check(wrappedOutcome?["form"] as? String == nativeOutcome?["form"] as? String && wrappedOutcome?["message"] as? String == nativeOutcome?["message"] as? String,
                  "an invalid url filter did not keep WebKit's own failure form and message: \(invalid)")

        // 5. Topology changes between the token and the answer (engine hook) never put a value on the wrong tab.
        var phases: [String: Int] = [:]
        func swapSameURLTabs() {
            var list = controller.session.tabs
            guard let i = list.firstIndex(where: { $0.id == aID }), let j = list.firstIndex(where: { $0.id == bID }) else { return }
            list.swapAt(i, j); controller.session.tabs = list; host.reconcile()
        }
        func hooked(_ name: String, _ hook: @escaping @MainActor (String, Int) -> Void) async throws -> [[String: Any]] {
            phases = [:]
            BrowserExtensions.metadataTestHook = { phase in phases[phase, default: 0] += 1; hook(phase, phases[phase]!) }
            defer { BrowserExtensions.metadataTestHook = nil }
            return tabs(try await js(noHost.page, wrappedQuery)["wrapped"])
        }
        func byID(_ list: [[String: Any]]) -> [Int: (url: String, title: String)] {
            Dictionary(list.compactMap { tab in (tab["id"] as? Int).map { ($0, (tab["url"] as? String ?? "", tab["title"] as? String ?? "")) } }, uniquingKeysWith: { a, _ in a })
        }
        // A reorder after the token: the first answer is refused, the retry fills each tab by its own id.
        let reordered = try await hooked("reorder") { phase, count in if phase == "issued" && count == 1 { swapSameURLTabs() } }
        try check(phases["issued"] == 2 && phases["answering"] == 2 && byID(reordered)[aJS]?.title == "Same A" && byID(reordered)[bJS]?.title == "Same B",
                  "a reorder between token and answer was not refused and retried by id: \(phases) \(reordered)")
        // ABA: reordered after the token and restored before the answer; the order matches again, but WebKit read
        // the swapped one in between, so that answer is refused too.
        let aba = try await hooked("aba") { phase, count in if count == 1 { swapSameURLTabs() } }
        try check(phases["issued"] == 2 && phases["answering"] == 2 && byID(aba)[aJS]?.title == "Same A" && byID(aba)[bJS]?.title == "Same B",
                  "an ABA reorder was answered from the restored order: \(phases) \(aba)")
        // ABA on every attempt: never answered; WebKit's redacted result stands.
        let persistent = try await hooked("aba-always") { _, _ in swapSameURLTabs() }
        try check(phases["issued"] == 3 && redacted(persistent), "a persistently changing topology was answered (URL or title): \(phases) \(persistent)")
        if controller.session.tabs.firstIndex(where: { $0.id == aID })! > controller.session.tabs.firstIndex(where: { $0.id == bID })! { swapSameURLTabs() }
        // An adapter replaced before the answer: the stale WebKit id never gets a value.
        let replaced = try await hooked("adapter") { phase, count in
            guard phase == "answering", count == 1, let old = runtime.tabs[aID] else { return }
            runtime.controller.didCloseTab(old); runtime.tabs.removeValue(forKey: aID); runtime.reconcile()
        }
        try check(phases["issued"] == 2 && byID(replaced)[aJS].map { $0.url.isEmpty && $0.title.isEmpty } == true && byID(replaced)[bJS]?.title == "Same B",
                  "a replaced adapter's stale id received a value: \(phases) \(replaced)")
        let afterReplacement = byID(tabs(try await js(noHost.page, wrappedQuery)["wrapped"]))
        try check(afterReplacement[aJS] == nil && afterReplacement.values.contains { $0.title == "Same A" }, "the replacement adapter was not answered under its new id")
        // tabs revoked before the answer: no value, and no further token.
        let revoked = try await hooked("revoke") { phase, count in
            if phase == "answering" && count == 1 { noHost.context.setPermissionStatus(.deniedExplicitly, for: .tabs) }
        }
        noHost.context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        try check(phases["issued"] == 1 && phases["answering"] == 1 && redacted(revoked),
                  "metadata was answered after tabs was revoked: \(phases) \(revoked)")
        try check(fixtureURLs.isSubset(of: Set(urls(tabs(try await js(noHost.page, wrappedQuery)["wrapped"])))), "metadata did not return after tabs was granted again")
        // A tab moved to another profile before the answer: no value for it from either profile.
        let currentA = afterReplacement.first { $0.value.title == "Same A" }?.key
        let moved = try await hooked("profile") { phase, count in
            if phase == "answering" && count == 1 { _ = controller.session.moveTab(id: aID, toSpace: elsewhereSpace); host.reconcile() }
        }
        try check(phases["issued"] == 2 && currentA.flatMap { byID(moved)[$0] }.map { $0.url.isEmpty && $0.title.isEmpty } == true && !moved.contains { $0["title"] as? String == "Same A" },
                  "a tab moved to another profile was answered: \(phases) \(moved)")
        try check(controller.session.profileID(for: controller.session.tabs.first { $0.id == aID }!) == elsewhere, "the fixture tab did not move profiles")

        // 6. Events: supplemented in order, only keys WebKit sent, nothing after removal.
        _ = try await js(noHost.page, """
            globalThis.__events = {wrapped: [], native: [], created: []};
            globalThis.__wrappedUpdated = (id, info, tab) => __events.wrapped.push({id, keys: Object.keys(info).sort(), url: info.url, title: info.title, tab: brief(tab)});
            browser.tabs.onUpdated.addListener(__wrappedUpdated);
            browser.tabs.onUpdated.addListener.__bamTabMetadataNative.call(browser.tabs.onUpdated,
              (id, info) => __events.native.push({id, keys: Object.keys(info).sort(), url: info.url, title: info.title}));
            browser.tabs.onCreated.addListener((tab) => __events.created.push(brief(tab)));
            return {};
            """)
        let eventsID = try await open(eventsURL)
        try await retitle(eventsID, "Events title")
        let eventsJS = tabs(try await js(noHost.page, wrappedQuery)["wrapped"]).first { $0["url"] as? String == eventsURL.absoluteString }?["id"] as? Int
        guard let eventsJS else { throw Failure(description: "Tab metadata: the events tab was not visible") }
        let eventsProbe = "return {wrapped: __events.wrapped.filter((e) => e.id === id), native: __events.native.filter((e) => e.id === id), created: __events.created.filter((t) => t.id === id)};"
        // A navigation, so WebKit sends a (redacted) url key; then wait for the facade to deliver everything.
        let navigatedURL = page("/next.html", "events-navigated")
        controller.navigatePane(eventsID, address: navigatedURL.absoluteString)
        try await wait("the events tab did not navigate") { controller.browsers[eventsID]?.url == navigatedURL && controller.browsers[eventsID]?.isLoading == false }
        try await wait("supplemented onUpdated events did not catch up") {
            guard let value = try? await js(noHost.page, eventsProbe, ["id": eventsJS]) else { return false }
            let wrapped = tabs(value["wrapped"]), native = tabs(value["native"])
            return native.contains { ($0["keys"] as? [String])?.contains("url") == true } && wrapped.count == native.count
                && wrapped.last.map { ($0["tab"] as? [String: Any])?["url"] as? String == navigatedURL.absoluteString } == true
        }
        // A same-document navigation changes the URL without a load, so nothing changes while the facade answers:
        // WebKit's redacted url key must arrive filled, paired with WebKit's own event for it.
        var fragmentComponents = URLComponents(url: navigatedURL, resolvingAgainstBaseURL: false)!
        fragmentComponents.fragment = "supplemented"
        let fragmentURL = fragmentComponents.url!
        // A title-only change of a tab outside the shown Space (no load, no commit) must still reach tabs.onUpdated,
        // delivered with the tab's new title (BrowserController.updateMetadata publishes every tab's change).
        let eventsBeforeTitle = tabs((try await js(noHost.page, eventsProbe, ["id": eventsJS]))["native"]).count
        try await retitle(eventsID, "Events retitled")
        try await wait("a background tab's title-only change was not published to tabs.onUpdated, or not delivered with its title") {
            guard let value = try? await js(noHost.page, eventsProbe, ["id": eventsJS]) else { return false }
            let wrapped = tabs(value["wrapped"]), native = tabs(value["native"])
            return native.count > eventsBeforeTitle && wrapped.count == native.count
                && (wrapped.last?["tab"] as? [String: Any])?["title"] as? String == "Events retitled"
        }
        let eventsBeforeFragment = tabs((try await js(noHost.page, eventsProbe, ["id": eventsJS]))["native"]).count
        _ = try await controller.browsers[eventsID]?.evaluateJavaScript("location.hash = 'supplemented'; 0")
        // On timeout the failure carries the evidence that separates the causes: whether Bam's tab address followed the
        // fragment (session vs web view), whether WebKit published any url event after it (native events since the
        // change), and what the facade delivered (wrapped events).
        do {
            var lastEvents: [String: Any] = [:]
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            var delivered = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let value = try? await js(noHost.page, eventsProbe, ["id": eventsJS]) {
                    lastEvents = value
                    let wrapped = tabs(value["wrapped"]), native = tabs(value["native"])
                    delivered = wrapped.count == native.count && zip(wrapped, native).contains { wrapped, native in
                        (native["keys"] as? [String])?.contains("url") == true && ((native["url"] as? String) ?? "").isEmpty
                            && wrapped["url"] as? String == fragmentURL.absoluteString
                            && (wrapped["tab"] as? [String: Any])?["url"] as? String == fragmentURL.absoluteString
                    }
                    if delivered { break }
                }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            let native = tabs(lastEvents["native"]), wrapped = tabs(lastEvents["wrapped"])
            try check(delivered, "the redacted url key of a quiet URL change was not delivered filled: " +
                      "session address=\(controller.session.tabs.first { $0.id == eventsID }?.address ?? "missing") " +
                      "web view url=\(controller.browsers[eventsID]?.url?.absoluteString ?? "none") expected=\(fragmentURL.absoluteString); " +
                      "native events since the change=\(Array(native.dropFirst(eventsBeforeFragment))) (of \(native.count)); " +
                      "wrapped tail=\(Array(wrapped.suffix(max(1, native.count - eventsBeforeFragment)))) (of \(wrapped.count))")
        }
        let events = try await js(noHost.page, eventsProbe, ["id": eventsJS])
        let wrappedEvents = tabs(events["wrapped"]), nativeEvents = tabs(events["native"])
        try check(zip(wrappedEvents, nativeEvents).allSatisfy { String(describing: $0["keys"] ?? "") == String(describing: $1["keys"] ?? "") },
                  "onUpdated changeInfo keys differ from WebKit's (an invented or dropped key): \(wrappedEvents) vs \(nativeEvents)")
        // WebKit sends a redacted key as an absent value or an empty string: both count as blank. Whenever the facade
        // supplemented an event (its tab carries a URL), every key WebKit sent blank carries that tab's value; a key WebKit
        // didn't send is never added (checked above), so no title change is invented on first observation. An event
        // the facade couldn't supplement in time (topology churn while loading) stays exactly WebKit's.
        func blank(_ event: [String: Any], _ key: String) -> Bool {
            (event["keys"] as? [String])?.contains(key) == true && ((event[key] as? String) ?? "").isEmpty
        }
        let deliveredTab = { (event: [String: Any]) in (event["tab"] as? [String: Any]) ?? [:] }
        try check(wrappedEvents.count == nativeEvents.count && zip(wrappedEvents, nativeEvents).contains { wrapped, native in
                      blank(native, "url") && wrapped["url"] as? String == fragmentURL.absoluteString && deliveredTab(wrapped)["url"] as? String == fragmentURL.absoluteString },
                  "no WebKit event with a redacted url key was delivered with that key filled: \(wrappedEvents) vs \(nativeEvents)")
        try check(zip(wrappedEvents, nativeEvents).allSatisfy { wrapped, native in
                      let tab = deliveredTab(wrapped), supplemented = !((tab["url"] as? String) ?? "").isEmpty
                      let urlOK = !blank(native, "url") || (supplemented ? wrapped["url"] as? String == tab["url"] as? String : ((wrapped["url"] as? String) ?? "").isEmpty)
                      let titleOK = !blank(native, "title") || (supplemented && !((tab["title"] as? String) ?? "").isEmpty
                          ? wrapped["title"] as? String == tab["title"] as? String : ((wrapped["title"] as? String) ?? "").isEmpty)
                      return urlOK && titleOK },
                  "a blank changeInfo url or title did not carry the supplemented tab's own value: \(wrappedEvents) vs \(nativeEvents)")
        try check(wrappedEvents.allSatisfy { [eventsURL.absoluteString, navigatedURL.absoluteString, fragmentURL.absoluteString, ""].contains(deliveredTab($0)["url"] as? String ?? "-")
                      && leaksNothing([deliveredTab($0)]) },
                  "an event carried another tab's or another profile's URL: \(wrappedEvents)")
        // onCreated of a tab that loads at once: Bam's topology changes while it loads, so a blank (WebKit's own) tab
        // is allowed by the facade's contract; a wrong URL never is.
        let created = tabs(events["created"])
        try check(created.count == 1 && [eventsURL.absoluteString, ""].contains(created[0]["url"] as? String ?? "-"), "onCreated was missing, repeated or showed another URL: \(created)")
        // onCreated of a tab whose URL and title Bam already knows and that doesn't load (as a restored, not yet
        // loaded tab): nothing changes while the facade answers, so the delivered tab must carry both.
        let readyURL = page("/next.html", "ready"), readyTitle = "Ready metadata"
        let createdBefore = tabs(try await js(noHost.page, "return {created: __events.created};")["created"]).count
        let ready = BrowserTab(title: readyTitle, address: readyURL.absoluteString, space: controller.session.spaceID(forProfile: profile)!)
        controller.session.tabs.append(ready)
        defer { controller.session.tabs.removeAll { $0.id == ready.id }; host.reconcile() }
        host.reconcile()
        try await wait("onCreated was not delivered for a ready tab") {
            ((try? await js(noHost.page, "return {created: __events.created};"))?["created"] as? [Any])?.count ?? 0 > createdBefore
        }
        let readyCreated = Array(tabs(try await js(noHost.page, "return {created: __events.created};")["created"]).dropFirst(createdBefore))
        try check(readyCreated.count == 1 && readyCreated[0]["url"] as? String == readyURL.absoluteString && readyCreated[0]["title"] as? String == readyTitle,
                  "onCreated for a tab with known metadata was not supplemented with its URL and title: \(readyCreated)")
        // Removal: the cut is taken in the same evaluation that removes the listener, and the control is a later
        // navigation event (a url key), not any event that was already on its way.
        let cut = try await js(noHost.page, """
            browser.tabs.onUpdated.removeListener(__wrappedUpdated);
            return {wrapped: __events.wrapped.filter((e) => e.id === id).length,
                    nativeURL: __events.native.filter((e) => e.id === id && e.keys.includes('url')).length};
            """, ["id": eventsJS])
        guard let removedAt = cut["wrapped"] as? Int, let urlEventsAt = cut["nativeURL"] as? Int else { throw Failure(description: "Tab metadata: no removal cut: \(cut)") }
        controller.navigatePane(eventsID, address: page("/next.html", "events-after").absoluteString)
        try await wait("WebKit reported no navigation event after the listener was removed") {
            let native = tabs((try? await js(noHost.page, eventsProbe, ["id": eventsJS]))?["native"])
            return native.filter { ($0["keys"] as? [String])?.contains("url") == true }.count > urlEventsAt
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try check(tabs(try await js(noHost.page, eventsProbe, ["id": eventsJS])["wrapped"]).count == removedAt, "a removed listener was called again")

        // 7. Context unloaded between token and answer (engine API directly): no binding, no answer.
        guard let binding = runtime.tabMetadataBinding(for: noHost.context),
              let request = ExtensionTabMetadata.Request.parse(["token": "unused", "normalCount": 1, "popupCount": 0, "entries": [["window": "normal", "index": 0]]]) else {
            throw Failure(description: "Tab metadata: no binding for the loaded no-host context")
        }
        try check(runtime.answerTabMetadata(for: noHost.context, issued: binding, request: request) != nil, "a valid native answer was refused")
        try await host.setEnabled(false, id: noHost.id)
        try check(runtime.answerTabMetadata(for: noHost.context, issued: binding, request: request) == nil && runtime.tabMetadataBinding(for: noHost.context) == nil,
                  "an unloaded context was answered or issued a token")

        // Cleanup on success. The moved tab returns home and the extensions are removed here (strictly: a failed removal
        // fails the run); the opened tabs close and the hook is cleared on return (defers above). The two fixture
        // profiles and their Spaces stay in the caller's ephemeral controller, which it closes without persisting.
        _ = controller.session.moveTab(id: aID, toSpace: controller.session.spaceID(forProfile: profile)!)
        for id in installed { try await host.remove(id: id) }
        return checks
    }
}
