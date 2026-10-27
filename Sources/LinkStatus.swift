import AppKit
import WebKit

/// Arc's hovered-link status: while the pointer is over a link, its address
/// shows in a small capsule at the bottom-left corner of that page.
///
/// WebKit has no public hover callback, so a tiny script in its own content
/// world (invisible to the page's scripts) reports the link under the pointer.
/// The address is only displayed: never stored, logged or sent anywhere.
@MainActor final class LinkStatusController: NSObject {
    static let world = WKContentWorld.world(name: "BamLinkStatus")
    static let messageName = "bamLinkStatus"
    static let source = #"""
    (() => {
      if (window.__bamLinkStatus) return; window.__bamLinkStatus = true;
      let shown = null;
      const post = (href) => {
        if (href === shown) return; shown = href;
        try { window.webkit.messageHandlers.bamLinkStatus.postMessage(href === null ? "" : href); } catch (e) {}
      };
      const linkAt = (start) => {
        for (let node = start; node; node = node.parentNode || node.host) {
          if (node.nodeType !== 1) continue;
          const name = node.localName;
          if (name === 'a' || name === 'area') {
            const raw = typeof node.href === 'string' ? node.href : (node.href && node.href.baseVal);
            if (!raw) continue;
            try { return new URL(raw, document.baseURI).href; } catch (e) { return null; }
          }
        }
        return null;
      };
      addEventListener('mouseover', (event) => {
        const path = event.composedPath ? event.composedPath() : [];
        post(linkAt(path.length ? path[0] : event.target));
      }, true);
      addEventListener('mouseout', (event) => { if (!event.relatedTarget) post(null); }, true);
      addEventListener('pagehide', () => post(null), true);
      addEventListener('blur', () => post(null));
    })();
    """#

    weak var owner: BrowserController?
    private let installed = NSHashTable<WKUserContentController>.weakObjects()
    private var pill: LinkStatusPill?
    private weak var hoveredWeb: WKWebView?
    private var hideWork: DispatchWorkItem?

    /// Adds the hover script to a page's content controller once, and points its messages here (a
    /// page moved from another window keeps its script and now reports to this window).
    func install(in web: WKWebView, owner: BrowserController) {
        self.owner = owner
        let controller = web.configuration.userContentController
        if !installed.contains(controller) {
            installed.add(controller)
            if !controller.userScripts.contains(where: { $0.source == Self.source }) {
                controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
            }
        }
        controller.removeScriptMessageHandler(forName: Self.messageName, contentWorld: Self.world)
        controller.add(WeakMessageHandler(self), contentWorld: Self.world, name: Self.messageName)
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard let web = message.webView, let owner, web.window === owner.view.window,
              !web.isHiddenOrHasHiddenAncestor, let href = message.body as? String else { return }
        if href.isEmpty || URL(string: href) == nil {
            if hoveredWeb == nil || hoveredWeb === web { hide(immediately: false) }
            return
        }
        show(Self.displayText(href), host: Self.displayHost(href), over: web)
    }

    /// What the capsule says: the address without its http(s) scheme or any
    /// user name and password (`https://google.com@evil.example` would read as
    /// Google), readable where that's safe. Percent escapes are decoded only
    /// when none of them hides an invisible, spacing or direction-changing
    /// character, which a page could use to make the address read differently.
    static func displayText(_ href: String) -> String {
        var text = href
        if var parts = URLComponents(string: href), parts.percentEncodedUser != nil || parts.percentEncodedPassword != nil {
            parts.percentEncodedUser = nil; parts.percentEncodedPassword = nil
            text = parts.string ?? href
        }
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)); break }
        if text.hasSuffix("/"), text.dropLast().contains("/") == false { text.removeLast() }
        guard let decoded = text.removingPercentEncoding else { return text }
        let unsafe: Set<Unicode.GeneralCategory> = [.control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator,
                                                     .privateUse, .surrogate, .unassigned, .nonspacingMark, .enclosingMark]
        return decoded.unicodeScalars.contains { unsafe.contains($0.properties.generalCategory) } ? text : decoded
    }
    /// The link's host as the capsule shows it, so it can be kept whole when the address is shortened.
    static func displayHost(_ href: String) -> String? {
        guard let url = URL(string: href), let host = url.host, !host.isEmpty else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private func show(_ text: String, host: String?, over web: WKWebView) {
        guard let root = owner?.view else { return }
        hideWork?.cancel(); hideWork = nil
        let pill = self.pill ?? LinkStatusPill()
        if pill.superview !== root { root.addSubview(pill, positioned: .above, relativeTo: nil) }
        else if root.subviews.last !== pill { root.addSubview(pill, positioned: .above, relativeTo: nil) }
        self.pill = pill; hoveredWeb = web
        let area = web.convert(web.bounds, to: root)
        let limit = min(LinkStatusPill.maximumWidth, max(80, area.width - LinkStatusPill.inset * 2))
        // Shortening never hides the host: cut the end of the address, and if the host
        // alone is too long, show only its end, which names the site that owns it.
        pill.text = text; pill.truncation = .byTruncatingTail
        if pill.fittingWidth > limit, let host, text.hasPrefix(host) {
            pill.text = host + "…"
            if pill.fittingWidth > limit { pill.text = host; pill.truncation = .byTruncatingHead }
            else { pill.text = text }
        }
        let width = min(pill.fittingWidth, limit)
        let y = root.isFlipped ? area.maxY - LinkStatusPill.inset - LinkStatusPill.height : area.minY + LinkStatusPill.inset
        pill.frame = NSRect(x: area.minX + LinkStatusPill.inset, y: y, width: width, height: LinkStatusPill.height).integral
        if pill.isHidden || pill.alphaValue < 1 {
            pill.isHidden = false
            fade(pill, to: 1, duration: 0.08)
        }
    }

    /// Hides after a short linger (Arc keeps it ~0.2s, so moving between
    /// adjacent links doesn't flicker); `immediately` for tab switches.
    func hide(immediately: Bool) {
        hideWork?.cancel(); hideWork = nil
        guard let pill, !pill.isHidden else { hoveredWeb = nil; return }
        if immediately { pill.isHidden = true; pill.alphaValue = 0; hoveredWeb = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pill = self.pill else { return }
            self.hoveredWeb = nil
            self.fade(pill, to: 0, duration: 0.1) { if pill.alphaValue == 0 { pill.isHidden = true } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func fade(_ view: NSView, to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.alphaValue = alpha; completion?(); return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        }, completionHandler: { completion?() })
    }
}

/// Breaks the content controller → handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: LinkStatusController?
    init(_ target: LinkStatusController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message) }
    }
}

/// The capsule: a thin outline, dark in dark mode and light in light mode,
/// with the address in one line, shortened so the host always shows.
@MainActor final class LinkStatusPill: NSView {
    static let height: CGFloat = 24
    static let inset: CGFloat = 10
    static let maximumWidth: CGFloat = 400
    private static let padding: CGFloat = 10
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityValue(newValue); needsLayout = true }
    }
    var truncation: NSLineBreakMode {
        get { label.lineBreakMode }
        set { label.lineBreakMode = newValue }
    }
    var fittingWidth: CGFloat {
        let font = label.font ?? .systemFont(ofSize: 12.5, weight: .medium)
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + Self.padding * 2 + 6
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        alphaValue = 0; isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Link address")
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Display only: the pointer passes straight through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let lineHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Self.padding, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width - Self.padding * 2, height: lineHeight)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 0.96)
                                       : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 0.96)).cgColor
        layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).cgColor
        label.textColor = dark ? NSColor(white: 1, alpha: 0.78) : NSColor(white: 0, alpha: 0.72)
    }
}
