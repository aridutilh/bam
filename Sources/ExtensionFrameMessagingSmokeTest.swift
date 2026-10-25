import AppKit
import WebKit

/// Original same-origin iframe messaging fixtures, shared by the isolated host
/// and real BrowserController paths. Never loads vendor code or account data.
@available(macOS 15.4, *)
@MainActor enum ExtensionFrameMessagingSmokeTest {
    static func prepare(package: URL, manifest: inout [String: Any]) throws {
        var permissions = manifest["permissions"] as? [String] ?? []
        if !permissions.contains("webRequest") { permissions.append("webRequest") }
        manifest["permissions"] = permissions
        var background = manifest["background"] as? [String: Any] ?? [:]
        var scripts = background["scripts"] as? [String] ?? []
        scripts.append("iframe-background.js"); background["scripts"] = scripts
        manifest["background"] = background
        var entries = manifest["content_scripts"] as? [[String: Any]] ?? []
        entries.append(["matches": ["http://127.0.0.1/*"], "js": ["iframe-content.js"],
                        "run_at": "document_end", "all_frames": true])
        manifest["content_scripts"] = entries
        try Data(backgroundSource.utf8).write(to: package.appendingPathComponent("iframe-background.js"))
        try Data(contentSource.utf8).write(to: package.appendingPathComponent("iframe-content.js"))
    }

    private static let backgroundSource = """
    const bamIframeRequests = new Map();
    browser.webRequest.onBeforeRequest.addListener((request) => {
      const {tabId, frameId, parentFrameId, url, type} = request;
      bamIframeRequests.set(url, {tabId, frameId, parentFrameId, url, type});
      if (bamIframeRequests.size > 16) bamIframeRequests.delete(bamIframeRequests.keys().next().value);
    }, {urls: ["http://127.0.0.1/*"], types: ["sub_frame"]});
    browser.runtime.onMessage.addListener((message, sender, respond) => {
      // Exact iframe-parent gate: two-argument content callback, a background
      // listener returning literal true, and a callback relay to frame zero.
      if (message?.kind === "bam-frame-parent-flags") {
        const metadata = {tabID: sender.tab?.id, frameID: sender.frameId, url: sender.url};
        chrome.tabs.sendMessage(sender.tab.id, {kind: "bam-frame-top-query"}, {frameId: 0}, (flags) => {
          const error = chrome.runtime.lastError;
          respond({sender: metadata, flags, ...(error ? {error: String(error.message)} : {})});
        });
        return true;
      }
      if (!message || !["bam-frame-sender", "bam-frame-document-complete"].includes(message.kind)) return;
      const metadata = {tabID: sender.tab?.id, frameID: sender.frameId, url: sender.url,
        request: bamIframeRequests.get(sender.url) || null};
      if (message.kind === "bam-frame-sender") return Promise.resolve(metadata);
      if (!Number.isInteger(metadata.tabID) || !Number.isInteger(metadata.frameID) || typeof metadata.url !== "string") {
        return Promise.resolve({sender: metadata, error: "Missing sender tab/frame/url metadata"});
      }
      const request = {kind: "bam-frame-target", token: message.token, transport: message.transport};
      if (message.transport === "callback") {
        return new Promise((resolve) => {
          chrome.tabs.sendMessage(metadata.tabID, request, {frameId: metadata.frameID}, (reply) => {
            const error = chrome.runtime.lastError;
            resolve({sender: metadata, reply, ...(error ? {error: String(error.message)} : {})});
          });
        });
      }
      return (async () => {
        try {
          const reply = await browser.tabs.sendMessage(metadata.tabID, request, {frameId: metadata.frameID});
          return {sender: metadata, reply};
        } catch (error) { return {sender: metadata, error: String(error)}; }
      })();
    });
    """

    private static let contentSource = """
    (() => {
      const root = document.documentElement;
      const token = new URL(location.href).searchParams.get("bam-frame-token") || "top";
      root.dataset.bamIframeProbeStarted = token;
      root.dataset.bamIframeProbeHits = "0";
      root.dataset.bamIframeRelayTopQueries = "0";
      browser.runtime.onMessage.addListener((message, sender, respond) => {
        if (message?.kind === "bam-frame-top-query") {
          root.dataset.bamIframeRelayTopQueries = String(Number(root.dataset.bamIframeRelayTopQueries) + 1);
          if (window !== window.top) return;
          respond({skipAnalysis: false, aboveThresholds: false});
          return true;
        }
        if (message?.kind !== "bam-frame-target") return;
        root.dataset.bamIframeProbeHits = String(Number(root.dataset.bamIframeProbeHits) + 1);
        if (message.token !== token) return;
        const reply = {token, url: location.href, isTop: window === window.top, transport: message.transport};
        if (message.transport === "callback") { respond(reply); return false; }
        return Promise.resolve(reply);
      });
      const callbackSend = (message) => new Promise((resolve, reject) => {
        chrome.runtime.sendMessage(chrome.runtime.id, message, (response) => {
          const error = chrome.runtime.lastError;
          if (error) reject(new Error(error.message)); else resolve(response);
        });
      });
      (async () => {
        try {
          root.dataset.bamIframeProbeSender = JSON.stringify(await browser.runtime.sendMessage({kind: "bam-frame-sender"}));
          root.dataset.bamIframeProbeResult = JSON.stringify(await browser.runtime.sendMessage({kind: "bam-frame-document-complete", token, transport: "promise"}));
          root.dataset.bamIframeCallbackSender = JSON.stringify(await callbackSend({kind: "bam-frame-sender"}));
          root.dataset.bamIframeCallbackResult = JSON.stringify(await callbackSend({kind: "bam-frame-document-complete", token, transport: "callback"}));
          if (window !== window.top) {
            const parentFlags = await new Promise((resolve, reject) => {
              chrome.runtime.sendMessage({kind: "bam-frame-parent-flags"}, (response) => {
                const error = chrome.runtime.lastError;
                if (error) reject(new Error(error.message)); else resolve(response);
              });
            });
            root.dataset.bamIframeParentFlags = JSON.stringify(parentFlags);
          }
        } catch (error) { root.dataset.bamIframeProbeError = String(error); }
      })();
    })();
    """

    static func verify(web: WKWebView, pageURL: URL, label: String) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ExtensionSmokeTest.Failure(description: "\(label): \(message)") }; checks += 1
        }
        func wait(_ message: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await condition() { checks += 1; return }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw ExtensionSmokeTest.Failure(description: "\(label): \(message)")
        }
        func state() async -> [String: Any] {
            (try? await web.evaluateJavaScript("""
            (() => {
              const read = (doc) => {
                if (!doc) return null;
                const d = doc.documentElement?.dataset || {};
                const parse = (value) => { try { return value ? JSON.parse(value) : null; } catch (_) { return {invalidJSON:true}; } };
                return {url:doc.URL, ready:doc.readyState, started:d.bamIframeProbeStarted || "",
                  sender:parse(d.bamIframeProbeSender), result:parse(d.bamIframeProbeResult),
                  callbackSender:parse(d.bamIframeCallbackSender), callbackResult:parse(d.bamIframeCallbackResult),
                  parentFlags:parse(d.bamIframeParentFlags), topQueries:Number(d.bamIframeRelayTopQueries || 0),
                  error:d.bamIframeProbeError || "", hits:Number(d.bamIframeProbeHits || 0)};
              };
              return {top:read(document), frame:read(document.getElementById("bam-frame-probe")?.contentDocument)};
            })()
            """)) as? [String: Any] ?? [:]
        }
        func validSender(_ sender: [String: Any], tabID: NSNumber, frameID: Int, url: URL) -> Bool {
            (sender["tabID"] as? NSNumber) == tabID && (sender["frameID"] as? NSNumber)?.intValue == frameID && sender["url"] as? String == url.absoluteString
        }
        func validReply(_ response: [String: Any], token: String, url: URL, isTop: Bool, transport: String) -> Bool {
            guard let reply = response["reply"] as? [String: Any] else { return false }
            return reply["token"] as? String == token && reply["url"] as? String == url.absoluteString && reply["isTop"] as? Bool == isTop &&
                reply["transport"] as? String == transport && response["error"] == nil
        }
        let token = "frame-" + UUID().uuidString.lowercased()
        let frameURL = pageURL.appending(queryItems: [URLQueryItem(name: "bam-frame-token", value: token)])
        defer { web.evaluateJavaScript("document.getElementById('bam-frame-probe')?.remove()", completionHandler: nil) }
        do {
            try await wait("Top-level promise frame-targeted baseline did not complete") {
                ((await state()["top"] as? [String: Any])?["result"] as? [String: Any])?["reply"] != nil
            }
            try await wait("Top-level three-argument content callback / background frame-targeted callback did not complete") {
                ((await state()["top"] as? [String: Any])?["callbackResult"] as? [String: Any])?["reply"] != nil
            }
            let top = await state()["top"] as? [String: Any] ?? [:]
            let topSender = top["sender"] as? [String: Any] ?? [:]
            guard let tabID = topSender["tabID"] as? NSNumber else { throw ExtensionSmokeTest.Failure(description: "\(label): Missing top sender tab ID") }
            try check(validSender(topSender, tabID: tabID, frameID: 0, url: pageURL) && validSender(top["callbackSender"] as? [String: Any] ?? [:], tabID: tabID, frameID: 0, url: pageURL), "Top sender metadata was incorrect")
            try check(validReply(top["result"] as? [String: Any] ?? [:], token: "top", url: pageURL, isTop: true, transport: "promise") &&
                      validReply(top["callbackResult"] as? [String: Any] ?? [:], token: "top", url: pageURL, isTop: true, transport: "callback"), "Top handshake answered from the wrong document")
            _ = try await web.callAsyncJavaScript("const frame = document.createElement('iframe'); frame.id = 'bam-frame-probe'; frame.src = url; document.body.append(frame); return true;",
                arguments: ["url": frameURL.absoluteString], in: nil, contentWorld: .page)
            try await wait("Dynamic same-origin iframe did not execute its all_frames script") {
                (await state()["frame"] as? [String: Any])?["started"] as? String == token
            }
            try await wait("Iframe sender metadata did not reach background") {
                (await state()["frame"] as? [String: Any])?["sender"] is [String: Any]
            }
            try await wait("Promise tabs.sendMessage(frameId:) did not return the iframe reply") {
                ((await state()["frame"] as? [String: Any])?["result"] as? [String: Any])?["reply"] != nil
            }
            try await wait("Three-argument content callback / background frame-targeted callback did not return the iframe reply") {
                ((await state()["frame"] as? [String: Any])?["callbackResult"] as? [String: Any])?["reply"] != nil
            }
            try await wait("Two-argument callback / literal-true background relay to frame zero did not return parent flags") {
                ((await state()["frame"] as? [String: Any])?["parentFlags"] as? [String: Any])?["flags"] != nil
            }
            let final = await state(), frame = final["frame"] as? [String: Any] ?? [:]
            let sender = frame["sender"] as? [String: Any] ?? [:]
            let frameID = (sender["frameID"] as? NSNumber)?.intValue ?? 0
            if sender["request"] == nil || sender["request"] is NSNull {
                if ProcessInfo.processInfo.environment["BAM_REQUIRE_SUBFRAME_REQUESTS"] == "1" {
                    throw ExtensionSmokeTest.Failure(description: "\(label): webRequest.onBeforeRequest omitted the same-origin sub_frame request")
                }
                // Preserve the strict engine reproducer without counting an
                // absent event as a passed assertion or hiding unrelated checks.
                print("KNOWN_LIMITATION \(label): webRequest.onBeforeRequest omitted sub_frame; not counted as passed. Set BAM_REQUIRE_SUBFRAME_REQUESTS=1 for the strict reproducer."); fflush(stdout)
            } else {
                let request = sender["request"] as? [String: Any] ?? [:]
                try check((request["frameId"] as? NSNumber)?.intValue == frameID &&
                          (request["parentFrameId"] as? NSNumber)?.intValue == 0 && (request["tabId"] as? NSNumber) == tabID &&
                          request["url"] as? String == frameURL.absoluteString && request["type"] as? String == "sub_frame",
                          "webRequest.onBeforeRequest did not map the iframe's runtime frame ID to parent frame zero")
            }
            try check(frameID > 0 && validSender(sender, tabID: tabID, frameID: frameID, url: frameURL) &&
                      validSender(frame["callbackSender"] as? [String: Any] ?? [:], tabID: tabID, frameID: frameID, url: frameURL), "Iframe sender metadata lost its tab, distinct frame ID or URL")
            try check(validReply(frame["result"] as? [String: Any] ?? [:], token: token, url: frameURL, isTop: false, transport: "promise") &&
                      validReply(frame["callbackResult"] as? [String: Any] ?? [:], token: token, url: frameURL, isTop: false, transport: "callback"), "Frame-targeted handshake returned the wrong document")
            try check((frame["hits"] as? NSNumber)?.intValue == 2 && ((final["top"] as? [String: Any])?["hits"] as? NSNumber)?.intValue == 2, "A frame-targeted message was broadcast to another frame")
            let parentRelay = frame["parentFlags"] as? [String: Any] ?? [:]
            let flags = parentRelay["flags"] as? [String: Any] ?? [:]
            try check(validSender(parentRelay["sender"] as? [String: Any] ?? [:], tabID: tabID, frameID: frameID, url: frameURL) &&
                      flags["skipAnalysis"] as? Bool == false && flags["aboveThresholds"] as? Bool == false && parentRelay["error"] == nil,
                      "Literal-true parent relay lost sender metadata or returned incorrect flags")
            try check((frame["topQueries"] as? NSNumber)?.intValue == 0 && ((final["top"] as? [String: Any])?["topQueries"] as? NSNumber)?.intValue == 1,
                      "Parent flag query did not target only frame zero")
            print("EXTENSION_IFRAME_MESSAGING_PASS \(label): promise + callback + parent relay; distinct frame \(frameID); skipAnalysis=false aboveThresholds=false"); fflush(stdout)
            return checks
        } catch {
            let diagnostic: [String: Any] = ["fixture": label, "state": await state()]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                print("EXTENSION_IFRAME_DIAGNOSTIC " + String(decoding: data, as: UTF8.self)); fflush(stdout)
            }
            throw error
        }
    }

    static func runIntegrated(fixtureURL: URL, pageURL: URL) async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-frame-browser-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureURL, to: package)
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["manifest_version"] = 2
        let hosts = manifest.removeValue(forKey: "host_permissions") as? [String] ?? []
        manifest["permissions"] = (manifest["permissions"] as? [String] ?? []).filter { $0 != "scripting" } + hosts
        manifest["optional_permissions"] = manifest.removeValue(forKey: "optional_host_permissions")
        manifest["browser_action"] = manifest.removeValue(forKey: "action")
        manifest["background"] = ["scripts": ["background.js"], "persistent": false]
        try prepare(package: package, manifest: &manifest)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        let controller = BrowserController(sessionURL: root.appendingPathComponent("unused-session.json"), ephemeral: true)
        controller.session.tabs.removeAll(); controller.automaticallyShowsVideo = false
        let profile = controller.session.currentProfileID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 650)); controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 650)
        window.makeKeyAndOrderFront(nil); controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        defer { controller.prepareToClose(persistSession: false); window.orderOut(nil); window.close() }
        let host = controller.browserExtensions
        host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = controller.profileStores.store(for: profile)
        host.configure(configuration, profileID: profile)
        let extensionID = try await host.importPackage(at: package, profileID: profile)
        guard host.context(for: extensionID)?.hasPermission(.init(rawValue: "webRequest")) == true else {
            throw ExtensionSmokeTest.Failure(description: "Integrated iframe fixture was not granted webRequest")
        }
        let url = pageURL.appending(queryItems: [URLQueryItem(name: "profile", value: "integrated-frame")])
        guard let id = controller.openProfileTab(url, profileID: profile, active: true), let web = controller.browsers[id] else {
            throw ExtensionSmokeTest.Failure(description: "Integrated iframe fixture did not create its browser tab")
        }
        return try await verify(web: web, pageURL: url, label: "BrowserController MV2")
    }
}
