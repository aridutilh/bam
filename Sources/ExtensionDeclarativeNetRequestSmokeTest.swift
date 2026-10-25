import AppKit
import WebKit

/// declarativeNetRequest on real WebKit with an original fixture: static block and allow rules,
/// dynamic rules added and removed, an unaffected control, profile separation and unload.
/// Edge cases from the gap plan are measured and printed, not asserted. Loopback pages only.
@available(macOS 15.4, *)
@MainActor enum ExtensionDeclarativeNetRequestSmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(pageURL: URL) async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure(description: message) }; checks += 1 }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw Failure(description: message)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-dnr-fixture-" + UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Bam declarativeNetRequest fixture", "version": "1.0",
            "description": "Original fixture for Bam declarativeNetRequest runtime tests",
            "permissions": ["declarativeNetRequest"], "host_permissions": ["http://127.0.0.1/*"],
            "declarative_net_request": ["rule_resources": [["id": "bam_static", "enabled": true, "path": "rules.json"]]],
            "action": ["default_popup": "popup.html"]]
        let rules: [[String: Any]] = [
            ["id": 1, "priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "/bam-dnr/static-blocked", "resourceTypes": ["xmlhttprequest"]]],
            ["id": 2, "priority": 2, "action": ["type": "allow"], "condition": ["urlFilter": "/bam-dnr/static-blocked?allowed", "resourceTypes": ["xmlhttprequest"]]]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: rules).write(to: package.appendingPathComponent("rules.json"))
        try Data("<!doctype html><meta charset='utf-8'><title>DNR fixture</title>".utf8).write(to: package.appendingPathComponent("popup.html"))

        let host = BrowserExtensions(storageURL: root.appendingPathComponent("registry", isDirectory: true))
        host.permissionPrompt = { _ in true }
        let profileA = UUID(), profileB = UUID()
        let configA = WKWebViewConfiguration(), configB = WKWebViewConfiguration()
        configA.websiteDataStore = .nonPersistent(); configB.websiteDataStore = .nonPersistent()
        host.configure(configA, profileID: profileA); host.configure(configB, profileID: profileB)
        await host.ready(profileID: profileA); await host.ready(profileID: profileB)
        let frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let webA = WKWebView(frame: frame, configuration: configA), webB = WKWebView(frame: frame, configuration: configB)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; let container = NSView(frame: frame); window.contentView = container
        container.addSubview(webA); container.addSubview(webB); webB.isHidden = true; window.orderFront(nil)
        defer { host.shutdown(); webA.stopLoading(); webB.stopLoading(); window.orderOut(nil); window.close() }

        let id = try await host.importPackage(at: package, profileID: profileA)
        guard let context = host.context(for: id), let popup = context.action(for: nil)?.popupWebView else { throw Failure(description: "DNR fixture did not load: \(host.errors)") }
        popup.frame = frame
        try await wait("The DNR fixture's extension page did not load") { (try? await popup.evaluateJavaScript("document.readyState")) as? String == "complete" }
        webA.load(URLRequest(url: pageURL)); webB.load(URLRequest(url: pageURL))
        try await wait("The loopback pages did not load") { webA.url != nil && !webA.isLoading && webB.url != nil && !webB.isLoading }

        /// Same-origin fetch: a blocked request rejects, an unblocked one resolves (a 404 is fine).
        func outcome(_ web: WKWebView, _ path: String, method: String = "GET") async -> String {
            (try? await web.callAsyncJavaScript("""
                try { const response = await fetch(path, {method, cache: 'no-store'}); return 'reached ' + response.status; }
                catch (error) { return 'blocked'; }
                """, arguments: ["path": path, "method": method], contentWorld: .page)) as? String ?? "unknown"
        }
        func dnr(_ script: String) async -> String {
            (try? await popup.callAsyncJavaScript("try { \(script) } catch (error) { return 'error: ' + String(error && error.message || error); }",
                arguments: [:], contentWorld: .page)) as? String ?? "unknown"
        }

        // Static ruleset: block, a higher-priority allow, an unaffected control.
        try await wait("The static block rule did not block its loopback request") { await outcome(webA, "/bam-dnr/static-blocked") == "blocked" }
        let allowed = await outcome(webA, "/bam-dnr/static-blocked?allowed"), control = await outcome(webA, "/bam-dnr/control")
        try check(allowed.hasPrefix("reached") && control.hasPrefix("reached"), "The allow rule or the control was blocked: allowed=\(allowed) control=\(control)")
        // Another profile without the extension is unaffected.
        let otherProfile = await outcome(webB, "/bam-dnr/static-blocked")
        try check(otherProfile.hasPrefix("reached"), "A profile without the extension was filtered: \(otherProfile)")

        // Dynamic rules: added, applied, listed, removed.
        let added = await dnr("await browser.declarativeNetRequest.updateDynamicRules({addRules: [{id: 100, priority: 1, action: {type: 'block'}, condition: {urlFilter: '/bam-dnr/dynamic-blocked', resourceTypes: ['xmlhttprequest']}}]}); return 'ok';")
        try check(added == "ok", "updateDynamicRules rejected a plain block rule: \(added)")
        try await wait("The dynamic block rule did not apply") { await outcome(webA, "/bam-dnr/dynamic-blocked") == "blocked" }
        let listed = await dnr("return JSON.stringify((await browser.declarativeNetRequest.getDynamicRules()).map(rule => rule.id));")
        try check(listed == "[100]", "getDynamicRules did not list the added rule: \(listed)")
        let removed = await dnr("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds: [100]}); return 'ok';")
        try check(removed == "ok", "updateDynamicRules could not remove the rule: \(removed)")
        try await wait("Removing the dynamic rule did not stop blocking") { await outcome(webA, "/bam-dnr/dynamic-blocked").hasPrefix("reached") }

        // Gap-plan edge cases: measured only. Each edge rule is added together with a sentinel block rule on
        // its own path in one atomic update; probes run only once the sentinel blocks (that update is compiled),
        // so a "reached" result means the edge rule really did not match. Removal waits for the sentinel to clear.
        var edges: [String: Any] = [:]
        func measure(_ label: String, id: Int, condition: String, probes: [(String, String, String)]) async {
            let sentinelPath = "/bam-dnr/sentinel-\(id)"
            let rules = "[{id: \(id), priority: 1, action: {type: 'block'}, condition: \(condition)}, {id: \(id + 1000), priority: 1, action: {type: 'block'}, condition: {urlFilter: '\(sentinelPath)', resourceTypes: ['xmlhttprequest']}}]"
            let result = await dnr("await browser.declarativeNetRequest.updateDynamicRules({addRules: \(rules)}); return 'ok';")
            var observed: [String: Any] = ["add": result]
            if result == "ok" {
                let started = ProcessInfo.processInfo.systemUptime
                var active = false
                while !active && ProcessInfo.processInfo.systemUptime - started < 8 {
                    active = await outcome(webA, sentinelPath) == "blocked"
                    if !active { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                observed["sentinelActive"] = active
                observed["activeAfterMs"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                if active { for (name, path, method) in probes { observed[name] = await outcome(webA, path, method: method) } }
                _ = await dnr("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds: [\(id), \(id + 1000)]}); return 'ok';")
                let removing = ProcessInfo.processInfo.systemUptime
                var cleared = false
                while !cleared && ProcessInfo.processInfo.systemUptime - removing < 8 {
                    cleared = await outcome(webA, sentinelPath).hasPrefix("reached")
                    if !cleared { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                observed["removed"] = cleared
            }
            edges[label] = observed
        }
        await measure("regexAlternation", id: 200, condition: "{regexFilter: '/bam-dnr/(alt-one|alt-two)$', resourceTypes: ['xmlhttprequest']}",
                      probes: [("one", "/bam-dnr/alt-one", "GET"), ("two", "/bam-dnr/alt-two", "GET"), ("neither", "/bam-dnr/alt-three", "GET")])
        await measure("postMethod", id: 201, condition: "{urlFilter: '/bam-dnr/post-only', requestMethods: ['post'], resourceTypes: ['xmlhttprequest']}",
                      probes: [("get", "/bam-dnr/post-only", "GET"), ("post", "/bam-dnr/post-only", "POST")])
        await measure("getMethod", id: 202, condition: "{urlFilter: '/bam-dnr/get-only', requestMethods: ['get'], resourceTypes: ['xmlhttprequest']}",
                      probes: [("get", "/bam-dnr/get-only", "GET"), ("post", "/bam-dnr/get-only", "POST")])
        await measure("excludedPostMethod", id: 203, condition: "{urlFilter: '/bam-dnr/not-post', excludedRequestMethods: ['post'], resourceTypes: ['xmlhttprequest']}",
                      probes: [("get", "/bam-dnr/not-post", "GET"), ("post", "/bam-dnr/not-post", "POST")])
        await measure("uppercaseMethod", id: 204, condition: "{urlFilter: '/bam-dnr/upper-method', requestMethods: ['POST'], resourceTypes: ['xmlhttprequest']}",
                      probes: [("post", "/bam-dnr/upper-method", "POST")])
        // excludedResourceTypes is not validated by WebKit; excluding every type it knows leaves an empty list.
        let knownTypes = "['font', 'image', 'main_frame', 'media', 'other', 'ping', 'script', 'stylesheet', 'sub_frame', 'websocket', 'xmlhttprequest']"
        await measure("excludesAllKnownTypes", id: 205, condition: "{urlFilter: '/bam-dnr/excluded-all', excludedResourceTypes: \(knownTypes)}",
                      probes: [("xhr", "/bam-dnr/excluded-all", "GET")])
        await measure("excludesUnknownOnly", id: 206, condition: "{urlFilter: '/bam-dnr/excluded-unknown', excludedResourceTypes: ['webtransport']}",
                      probes: [("xhr", "/bam-dnr/excluded-unknown", "GET")])
        await measure("imagePlusUnknown", id: 207, condition: "{urlFilter: '/bam-dnr/image-only', resourceTypes: ['image', 'webtransport']}",
                      probes: [("xhr", "/bam-dnr/image-only", "GET")])
        await measure("unknownWithXHR", id: 208, condition: "{urlFilter: '/bam-dnr/webtransport-mixed', resourceTypes: ['xmlhttprequest', 'webtransport']}",
                      probes: [("xhr", "/bam-dnr/webtransport-mixed", "GET")])
        let edgeJSON = (try? JSONSerialization.data(withJSONObject: edges, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("EXTENSION_DNR edges=\(edgeJSON) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)"); fflush(stdout)

        // Disabling the extension removes its rules.
        try await host.setEnabled(false, id: id)
        try await wait("Disabling the extension left its static rule blocking") { await outcome(webA, "/bam-dnr/static-blocked").hasPrefix("reached") }
        return checks
    }
}
