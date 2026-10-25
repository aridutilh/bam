import AppKit
import WebKit

/// Measurement only (`--extension-test --extension-favicon-probe`): does WebKit route an extension page's own-origin
/// `/_favicon/` request through the extension service worker's fetch event? Original task-owned package, a
/// non-persistent extension controller and website store, no network beyond the loopback fixture, no production
/// favicon behavior. Prints EXTENSION_FAVICON_PROBE and MEASUREMENT lines; it is not a pass/fail suite.
@available(macOS 15.4, *)
@MainActor enum ExtensionFaviconProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Objects the probe owned, held weakly to confirm they were released after teardown.
    final class Released {
        weak var host: BrowserExtensions?
        weak var controller: WKWebExtensionController?
        weak var tab: WKWebView?
        weak var page: WKWebView?
        weak var window: NSWindow?
        var all: Bool { host == nil && controller == nil && tab == nil && page == nil && window == nil }
        var pending: [String] {
            [("host", host == nil), ("controller", controller == nil), ("tab", tab == nil), ("page", page == nil), ("window", window == nil)]
                .filter { !$0.1 }.map(\.0)
        }
    }
    private final class Once { var done = false }

    /// Waits at most `seconds` for `work`; nil on timeout. The work keeps running on its own (JavaScript cannot be
    /// cancelled), but the probe moves on; anything it still holds shows up in the release check.
    static func bounded<T>(_ seconds: Double, _ work: @escaping @MainActor () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task { @MainActor in
                let value = await work()
                if !once.done { once.done = true; continuation.resume(returning: value) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { if !once.done { once.done = true; continuation.resume(returning: nil) } }
            }
        }
    }

    struct Measured { var report: [String: Any]?; var contextFaviconError = false; var stage = "files"; var failure: String? }

    /// Complete only when every required record is terminal, owned objects were released and the folder is gone.
    static func run(pageURL: URL) async -> (complete: Bool, summary: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-favicon-probe-" + UUID().uuidString, isDirectory: true)
        let released = Released()
        let measured = await measure(root: root, pageURL: pageURL, released: released)
        // Teardown happened inside measure(); confirm release before removing the folder the controller used.
        var waited = 0
        while !released.all && waited < 50 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        let releasedAll = released.all, pending = released.pending
        try? fm.removeItem(at: root)
        let removed = !fm.fileExists(atPath: root.path)
        var (outcome, reason) = ExtensionFaviconProbeModel.classify(measured.report, contextRecordedFaviconError: measured.contextFaviconError)
        if let failure = measured.failure { outcome = .incomplete; reason = "Stopped at \(measured.stage): \(failure)" }
        let cleaned = releasedAll && removed
        let summary: [String: Any] = ["outcome": outcome.rawValue, "reason": reason, "stage": measured.stage, "contextFaviconError": measured.contextFaviconError,
                                      "report": measured.report ?? NSNull(), "released": releasedAll, "notReleased": pending, "folderRemoved": removed]
        let json = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let complete = outcome != .incomplete && cleaned
        print("EXTENSION_FAVICON_PROBE \(json)")
        print("MEASUREMENT \(complete ? "complete" : "incomplete"): \(reason)\(cleaned ? "" : " (cleanup not confirmed: \(pending.joined(separator: ", "))\(removed ? "" : ", folder"))")")
        fflush(stdout)
        return (complete, json)
    }

    /// Everything strong lives here and is torn down before returning, on every path.
    private static func measure(root: URL, pageURL: URL, released: Released) async -> Measured {
        var result = Measured()
        var host: BrowserExtensions?, window: NSWindow?, tab: WKWebView?, page: WKWebView?
        defer {
            page?.stopLoading(); page?.removeFromSuperview(); page = nil
            tab?.stopLoading(); tab?.removeFromSuperview(); tab = nil
            host?.surfaces = nil; host?.shutdown(); host = nil
            window?.orderOut(nil); window?.close(); window?.contentView = nil; window = nil
        }
        do {
            let package = root.appendingPathComponent("package", isDirectory: true)
            try writePackage(package)
            result.stage = "host"
            let owned = BrowserExtensions(storageURL: root.appendingPathComponent("registry", isDirectory: true), controllerStorage: .nonPersistent)
            host = owned; released.host = owned
            owned.permissionPrompt = { _ in true }
            let profile = UUID(), configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            owned.configure(configuration, profileID: profile)
            released.controller = configuration.webExtensionController
            guard await bounded(10, { await owned.ready(profileID: profile); return true }) == true else { throw Failure(description: "the extension host did not become ready within 10 s") }
            let frame = NSRect(x: 0, y: 0, width: 420, height: 300)
            let ownedWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            ownedWindow.isReleasedWhenClosed = false; window = ownedWindow; released.window = ownedWindow
            let container = NSView(frame: frame); ownedWindow.contentView = container
            let ownedTab = WKWebView(frame: frame, configuration: configuration), tabID = UUID()
            tab = ownedTab; released.tab = ownedTab
            container.addSubview(ownedTab); ownedWindow.orderFront(nil)
            owned.surfaces = { [weak ownedTab, weak ownedWindow] in
                guard $0 == profile, let ownedTab, let ownedWindow else { return [] }
                return [BrowserExtensionSurface(id: tabID, title: "Probe", url: pageURL, webView: ownedTab, window: ownedWindow, isActive: true, isSelected: true)]
            }
            owned.reconcile()
            result.stage = "install"
            let installed: UUID?? = await bounded(30) { try? await owned.importPackage(at: package, profileID: profile) }
            guard let id = installed ?? nil else { throw Failure(description: "the probe package was not installed within 30 s: \(owned.errors)") }
            guard let context = owned.context(for: id), let popup = context.action(for: nil)?.popupWebView else { throw Failure(description: "the probe extension did not load: \(owned.errors)") }
            popup.frame = frame
            let errorsBefore = context.errors.count
            // Readiness: the worker answers only after evaluating the script that registered its fetch listener.
            result.stage = "ready"
            var ready = false
            for _ in 0..<15 where !ready {
                let answer: [String: Any]?? = await bounded(2) {
                    try? await popup.callAsyncJavaScript("return await (globalThis.browser || globalThis.chrome).runtime.sendMessage({kind: 'ready'});",
                                                         arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                }
                ready = (answer ?? nil)?["ready"] as? Bool == true
                if !ready { try await Task.sleep(nanoseconds: 300_000_000) }
            }
            guard ready else { throw Failure(description: "the worker never acknowledged its fetch listener") }
            result.stage = "page"
            var components = URLComponents(url: context.baseURL.appendingPathComponent("page.html"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageUrl", value: pageURL.absoluteString)]
            guard let pageConfiguration = owned.configuration(forExtensionURL: components.url!, profileID: profile) else { throw Failure(description: "no extension page configuration") }
            let ownedPage = WKWebView(frame: frame, configuration: pageConfiguration)
            page = ownedPage; released.page = ownedPage
            container.addSubview(ownedPage); ownedPage.load(URLRequest(url: components.url!))
            for _ in 0..<40 where result.report == nil {
                let text: String?? = await bounded(2) { try? await ownedPage.evaluateJavaScript("document.documentElement.dataset.bamFaviconProbe || ''") as? String }
                if let text = text ?? nil, !text.isEmpty, let data = text.data(using: .utf8) { result.report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
                if result.report == nil { try await Task.sleep(nanoseconds: 300_000_000) }
            }
            guard result.report != nil else { throw Failure(description: "the probe page did not report within its bound") }
            result.contextFaviconError = context.errors.dropFirst(errorsBefore).contains { ($0 as NSError).localizedDescription.contains("_favicon") }
            result.stage = "measured"
        } catch {
            result.failure = String(describing: error)
        }
        return result
    }

    private static func writePackage(_ package: URL) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
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
    }
}
