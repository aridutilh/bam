import Foundation
import WebKit

/// Passive, isolated-world observation: no networking/media API replacement,
/// no message handlers, and no page-provided claim of safety. Adopted pages that
/// missed document-start installation have no tracker and remain protected.
@MainActor final class TabActivityProbe {
    struct Snapshot {
        var evidence: TabActivityEvidence
        var scrollX: Double
        var scrollY: Double
        var url: String { evidence.address }
        var documentToken: String { evidence.documentToken }
    }

    private static let world = WKContentWorld.world(name: "com.ari.bam.tab-activity.v1")
    private var requests: [ObjectIdentifier: UUID] = [:]
    private let clock: () -> TimeInterval
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        if controller.userScripts.contains(where: { $0.source == trackerSource }) { return }
        controller.addUserScript(WKUserScript(source: trackerSource, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: world))
    }

    /// Invalidates any in-flight result; it does not erase sticky document
    /// interaction state or retroactively install a tracker in a loaded page.
    func invalidate(_ web: WKWebView) { requests.removeValue(forKey: ObjectIdentifier(web)) }

    func inspect(web: WKWebView, expectedURL: String) async -> Snapshot? {
        let identity = ObjectIdentifier(web), token = UUID(), started = clock()
        requests[identity] = token
        defer { if requests[identity] == token { requests.removeValue(forKey: identity) } }
        guard started.isFinite, nativeURLMatches(web, expectedURL),
              let first = await readDocument(web), requests[identity] == token,
              let playback = await mediaState(web), requests[identity] == token,
              let last = await readDocument(web), requests[identity] == token,
              first.documentToken == last.documentToken,
              first.url == expectedURL, last.url == expectedURL,
              nativeURLMatches(web, expectedURL), clock() >= started, clock() - started <= 1 else { return nil }
        var result = last
        // Even paused/suspended media may have state the user expects to retain.
        if playback != .none { result.evidence.reasons.append("native-media") }
        if web.cameraCaptureState != .none { result.evidence.reasons.append("camera-capture") }
        if web.microphoneCaptureState != .none { result.evidence.reasons.append("microphone-capture") }
        if web.canGoBack || web.canGoForward { result.evidence.reasons.append("navigation-history") }
        result.evidence.observedAt = started
        return result
    }

    private func nativeURLMatches(_ web: WKWebView, _ expected: String) -> Bool {
        guard !web.isLoading, web.url?.absoluteString == expected,
              let url = URL(string: expected), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }

    private func readDocument(_ web: WKWebView) async -> Snapshot? {
        await withCheckedContinuation { continuation in
            let reply = ProbeReply<Snapshot>(continuation)
            web.evaluateJavaScript(Self.querySource, in: nil, in: Self.world) { result in
                switch result {
                case .success(let value): reply.finish(Self.decode(value))
                case .failure: reply.finish(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reply.finish(nil) }
        }
    }
    private func mediaState(_ web: WKWebView) async -> WKMediaPlaybackState? {
        await withCheckedContinuation { continuation in
            let reply = ProbeReply<WKMediaPlaybackState>(continuation)
            web.requestMediaPlaybackState { reply.finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reply.finish(nil) }
        }
    }

    /// Malformed/unsupported responses never become a safe default snapshot.
    static func decode(_ value: Any?) -> Snapshot? {
        guard let dictionary = value as? [String: Any], dictionary["version"] as? Int == 1,
              let address = dictionary["url"] as? String, !address.isEmpty,
              let documentToken = dictionary["documentToken"] as? String, !documentToken.isEmpty,
              let reasons = dictionary["reasons"] as? [String],
              let x = dictionary["scrollX"] as? Double, let y = dictionary["scrollY"] as? Double,
              x.isFinite, y.isFinite else { return nil }
        return Snapshot(evidence: TabActivityEvidence(address: address, documentToken: documentToken,
                                                      observedAt: .nan, reasons: reasons), scrollX: x, scrollY: y)
    }

    static let querySource = "typeof globalThis.__bamTabActivityV1 === 'function' ? globalThis.__bamTabActivityV1() : null"
    static let trackerSource = #"""
    (() => {
      if (typeof globalThis.__bamTabActivityV1 === 'function') return;
      const token = (globalThis.crypto && typeof crypto.randomUUID === 'function')
        ? crypto.randomUUID() : `${Date.now()}-${Math.random()}-${performance.timeOrigin}`;
      let interacted = false, scripts = false, frames = false, forms = false, opaque = false, failed = false, observer = null;
      const protectedDocument = () => interacted || scripts || frames || forms || opaque || failed;
      const stopIfProtected = () => { if (protectedDocument() && observer) { observer.disconnect(); observer = null; } };
      const inspectElement = element => {
        if (!element || element.nodeType !== 1) return;
        const tag = String(element.tagName).toLowerCase();
        // Template contents and component shadow trees are outside ordinary
        // light-DOM traversal. Treat that uncertainty as protection.
        if (tag === 'template' || tag.includes('-') || element.getAttribute('is') !== null || element.shadowRoot) opaque = true;
        if (protectedDocument()) return;
        if (tag === 'script') {
          const type = (element.getAttribute('type') || '').trim().toLowerCase();
          // Unknown script types stay protected; only known inert data is excluded.
          if (!['application/json', 'application/ld+json'].includes(type)) scripts = true;
        }
        if (['iframe','frame','object','embed'].includes(tag)) frames = true;
        if (['form','input','textarea','select'].includes(tag)
            || (element.getAttribute('contenteditable') !== null && element.getAttribute('contenteditable') !== 'false')
            || element.getAttribute('role') === 'textbox') forms = true;
        if (protectedDocument()) return;
        for (const attribute of element.attributes || []) {
          if (/^on/i.test(attribute.name)
              || (['href','src','action'].includes(attribute.name) && /^\s*javascript:/i.test(attribute.value))) {
            scripts = true; return;
          }
        }
      };
      const inspectNode = (node, seen = new WeakSet()) => {
        if (!node || node.nodeType !== 1 || protectedDocument()) return;
        const pending = [node];
        while (pending.length && !protectedDocument()) {
          const element = pending.pop();
          if (seen.has(element)) continue;
          seen.add(element); inspectElement(element);
          if (!protectedDocument()) for (const child of element.children || []) pending.push(child);
        }
        stopIfProtected();
      };
      const protectInteraction = event => {
        if (event.isTrusted) { interacted = true; stopIfProtected(); }
      };
      for (const name of ['input','change','keydown','pointerdown','paste','drop','submit']) {
        document.addEventListener(name, protectInteraction, {capture:true, passive:true});
      }
      try {
        inspectNode(document.documentElement);
        if (!protectedDocument()) {
          observer = new MutationObserver(records => {
            if (protectedDocument()) { stopIfProtected(); return; }
            try {
              const seen = new WeakSet();
              for (const record of records) {
                if (protectedDocument()) break;
                if (record.type === 'attributes') {
                  // Attribute changes inspect only their target, never its subtree.
                  if (/^on/i.test(record.attributeName || '')) scripts = true;
                  if (['is','shadowrootmode'].includes(record.attributeName)) opaque = true;
                  if (['href','src','action'].includes(record.attributeName)
                      && /^\s*javascript:/i.test(record.oldValue || '')) scripts = true;
                  if (String(record.target.tagName).toLowerCase() === 'script') scripts = true;
                  if (!protectedDocument()) inspectElement(record.target);
                } else {
                  for (const node of record.addedNodes) inspectNode(node, seen);
                  for (const node of record.removedNodes) inspectNode(node, seen);
                }
              }
            } catch (_) { failed = true; }
            stopIfProtected();
          });
          observer.observe(document, {subtree:true, childList:true, attributes:true, attributeOldValue:true});
        }
      } catch (_) { failed = true; stopIfProtected(); }
      Object.defineProperty(globalThis, '__bamTabActivityV1', {configurable:false, writable:false, value:() => {
        const reasons = [];
        try {
          // Full inspection is confined to an explicit pressure-time query on
          // a still-unprotected static document, not every DOM mutation.
          if (!protectedDocument()) {
            inspectNode(document.documentElement);
            if (!protectedDocument() && (document.querySelector('form,input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="textbox"]')
                || String(document.designMode).toLowerCase() === 'on')) forms = true;
          }
          if (window.frames.length) frames = true;
          stopIfProtected();
          if (failed) reasons.push('tracker-unknown');
          if (document.readyState !== 'complete') reasons.push('document-loading');
          if (interacted) reasons.push('user-interaction');
          if (scripts) reasons.push('executable-script-or-inline-handler');
          if (frames) reasons.push('frames');
          if (forms) reasons.push('form-or-editable');
          if (opaque) reasons.push('shadow-or-template-content');
          if (navigator.serviceWorker && navigator.serviceWorker.controller) reasons.push('service-worker');
          if (!protectedDocument() && Array.from(document.querySelectorAll('audio,video')).some(m => !m.paused && !m.ended)) reasons.push('playing-media');
          const x = Number(window.scrollX), y = Number(window.scrollY);
          if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
          return {version:1, url:document.URL, documentToken:token, reasons, scrollX:x, scrollY:y};
        } catch (_) { return null; }
      }});
    })();
    """#
}

@MainActor private final class ProbeReply<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
    func finish(_ result: Value?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
