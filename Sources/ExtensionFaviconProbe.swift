import AppKit
import WebKit

/// Measurement only (`--extension-test --extension-favicon-probe`): does WebKit route an extension page's own-origin
/// `/_favicon/` request through the extension service worker's fetch event? Original task-owned package, ephemeral
/// state, no network beyond the loopback fixture, no production favicon behavior. Prints EXTENSION_FAVICON_PROBE.
@available(macOS 15.4, *)
@MainActor enum ExtensionFaviconProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// `complete` is true only when every required record arrived and cleanup was confirmed (either outcome).
    static func run(pageURL: URL) async throws -> (complete: Bool, summary: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-favicon-probe-" + UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Bam favicon routing probe", "version": "1.0",
                                       "description": "Original measurement fixture", "background": ["service_worker": "worker.js"],
                                       "action": ["default_popup": "popup.html"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
        let marker = ExtensionFaviconProbeModel.marker
        // The listener is registered during the worker's first evaluation, before it acknowledges readiness.
        try Data("""
            const seen = [];
            self.addEventListener('fetch', (event) => {
              const url = new URL(event.request.url);
              seen.push({path: url.pathname, search: url.search, destination: event.request.destination});
              if (url.origin === self.location.origin && url.pathname === '/_favicon/') {
                const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><desc>\(marker)</desc><rect width="16" height="16" fill="#0a7"/></svg>';
                event.respondWith(new Response(svg, {status: 200, headers: {'Content-Type': 'image/svg+xml', 'X-Bam-Probe': 'worker'}}));
              }
            });
            const api = globalThis.browser || globalThis.chrome;
            api.runtime.onMessage.addListener((message, sender, reply) => {
              if (message?.kind === 'ready') { reply({ready: true, listener: true}); return; }
              if (message?.kind === 'seen') { reply({seen: seen.slice()}); return; }
            });
            """.utf8).write(to: package.appendingPathComponent("worker.js"))
        try Data(ExtensionFaviconProbeModel.controlBody.utf8).write(to: package.appendingPathComponent("control.txt"))
        try Data("<!doctype html><meta charset='utf-8'><title>probe popup</title>".utf8).write(to: package.appendingPathComponent("popup.html"))
        try Data("<!doctype html><meta charset='utf-8'><title>probe page</title><body><script src='page.js'></script></body>".utf8).write(to: package.appendingPathComponent("page.html"))
        try Data("""
            (async () => {
              const api = globalThis.browser || globalThis.chrome, out = {};
              const target = new URLSearchParams(location.search).get('pageUrl');
              out.ready = await api.runtime.sendMessage({kind: 'ready'}).catch((error) => ({error: String(error)}));
              out.controlled = !!(navigator.serviceWorker && navigator.serviceWorker.controller);
              const favicon = api.runtime.getURL('/_favicon/') + '?pageUrl=' + encodeURIComponent(target) + '&size=16';
              try { const r = await fetch(favicon); out.fetch = {status: r.status, type: r.headers.get('Content-Type'), probe: r.headers.get('X-Bam-Probe'), body: (await r.text()).slice(0, 300)}; }
              catch (error) { out.fetch = {error: String(error)}; }
              try { const r = await fetch(api.runtime.getURL('/control.txt')); out.control = {status: r.status, body: await r.text()}; }
              catch (error) { out.control = {error: String(error)}; }
              out.img = await new Promise((resolve) => {
                const img = new Image(), timer = setTimeout(() => resolve({timeout: true}), 5000);
                img.onload = () => { clearTimeout(timer); resolve({loaded: true, width: img.naturalWidth, height: img.naturalHeight}); };
                img.onerror = () => { clearTimeout(timer); resolve({error: true}); };
                img.src = favicon + '&img=1'; document.body.appendChild(img);
              });
              out.seen = await api.runtime.sendMessage({kind: 'seen'}).catch((error) => ({error: String(error)}));
              document.documentElement.dataset.bamFaviconProbe = JSON.stringify(out);
            })();
            """.utf8).write(to: package.appendingPathComponent("page.js"))

        let host = BrowserExtensions(storageURL: root.appendingPathComponent("registry", isDirectory: true))
        host.permissionPrompt = { _ in true }
        let profile = UUID(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.configure(configuration, profileID: profile)
        await host.ready(profileID: profile)
        let frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; let container = NSView(frame: frame); window.contentView = container
        let tab = WKWebView(frame: frame, configuration: configuration), tabID = UUID()
        container.addSubview(tab); window.orderFront(nil)
        host.surfaces = { $0 == profile ? [BrowserExtensionSurface(id: tabID, title: "Probe", url: pageURL, webView: tab, window: window, isActive: true, isSelected: true)] : [] }
        var probePage: WKWebView?
        func cleanup() -> Bool {
            probePage?.stopLoading(); probePage?.removeFromSuperview(); probePage = nil
            tab.stopLoading(); host.shutdown(); window.orderOut(nil); window.close()
            try? fm.removeItem(at: root)
            return !fm.fileExists(atPath: root.path)
        }
        var report: [String: Any]?, recordedError = false, stage = "install"
        do {
            host.reconcile()
            let id = try await host.importPackage(at: package, profileID: profile)
            guard let context = host.context(for: id), let popup = context.action(for: nil)?.popupWebView else { throw Failure(description: "The probe extension did not load: \(host.errors)") }
            popup.frame = frame
            let errorsBefore = context.errors.count
            // Readiness: the worker answers only after evaluating the script that registered its fetch listener.
            stage = "ready"
            var ready = false
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while !ready && ProcessInfo.processInfo.systemUptime < deadline {
                let answer = try? await popup.callAsyncJavaScript("return await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind: 'ready'});",
                                                                  arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                ready = answer?["ready"] as? Bool == true
                if !ready { try await Task.sleep(nanoseconds: 200_000_000) }
            }
            if ready {
                stage = "page"
                var components = URLComponents(url: context.baseURL.appendingPathComponent("page.html"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "pageUrl", value: pageURL.absoluteString)]
                guard let pageConfiguration = host.configuration(forExtensionURL: components.url!, profileID: profile) else { throw Failure(description: "No extension page configuration") }
                let page = WKWebView(frame: frame, configuration: pageConfiguration); probePage = page
                container.addSubview(page); page.load(URLRequest(url: components.url!))
                let pageDeadline = ProcessInfo.processInfo.systemUptime + 20
                while report == nil && ProcessInfo.processInfo.systemUptime < pageDeadline {
                    if let text = try? await page.evaluateJavaScript("document.documentElement.dataset.bamFaviconProbe || ''") as? String, !text.isEmpty,
                       let data = text.data(using: .utf8) { report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
                    if report == nil { try await Task.sleep(nanoseconds: 200_000_000) }
                }
                recordedError = context.errors.dropFirst(errorsBefore).contains { ($0 as NSError).localizedDescription.contains("_favicon") }
            }
        } catch {
            let cleaned = cleanup()
            let line = "EXTENSION_FAVICON_PROBE {\"outcome\":\"incomplete\",\"stage\":\"\(stage)\",\"error\":\(ExtensionCompatibilityBridge.json(String(describing: error))),\"cleanup\":\(cleaned)}"
            print(line); print("MEASUREMENT incomplete: \(error)"); fflush(stdout)
            return (false, line)
        }
        let (outcome, reason) = ExtensionFaviconProbeModel.classify(report, contextRecordedFaviconError: recordedError)
        let cleaned = cleanup()
        let summary: [String: Any] = ["outcome": outcome.rawValue, "reason": reason, "stage": stage, "contextFaviconError": recordedError,
                                      "report": report ?? NSNull(), "cleanup": cleaned]
        let json = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("EXTENSION_FAVICON_PROBE \(json)")
        print("MEASUREMENT \(outcome == .incomplete || !cleaned ? "incomplete" : "complete"): \(reason)\(cleaned ? "" : " (cleanup failed)")"); fflush(stdout)
        return (outcome != .incomplete && cleaned, json)
    }
}
