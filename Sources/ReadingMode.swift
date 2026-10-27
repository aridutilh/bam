import AppKit
import WebKit

/// Reading Mode (⌥⌘R): the page's article in one clean column, laid over the
/// page. The page itself is only covered, never rebuilt, so leaving Reading
/// Mode returns to it at the same place with its video still playing and its
/// forms still filled. Extraction uses Mozilla's Readability (Apache 2.0,
/// Resources/Reader/Readability.js) in Bam's own content world.
@MainActor final class ReadingModeCoordinator: NSObject {
    /// The page has no article (a few paragraphs of real text).
    var onNoArticle: ((WKWebView) -> Void)?
    /// A link in the article: leave Reading Mode and open it in the page.
    var onOpenLink: ((WKWebView, URL) -> Void)?
    var persists = false

    private var sessions: [ObjectIdentifier: ReaderSession] = [:]
    private var starting: Set<ObjectIdentifier> = []
    private static let preferencesKey = "ReadingModePreferences"
    private var memoryPreferences: [String: Any]?
    static let world = WKContentWorld.world(name: "BamReader")

    var preferences: [String: Any] {
        get { persists ? (UserDefaults.standard.dictionary(forKey: Self.preferencesKey) ?? [:]) : (memoryPreferences ?? [:]) }
        set { if persists { UserDefaults.standard.set(newValue, forKey: Self.preferencesKey) } else { memoryPreferences = newValue } }
    }

    func isReading(_ web: WKWebView) -> Bool { purge(); return sessions[ObjectIdentifier(web)] != nil }
    /// A closed tab's page is gone; its reader goes with it.
    private func purge() {
        for (key, session) in sessions where session.page == nil { session.close(animated: false); sessions.removeValue(forKey: key) }
    }
    /// The reader laid over this page, for Find.
    func readerView(over web: WKWebView) -> WKWebView? { sessions[ObjectIdentifier(web)]?.reader }

    func toggle(_ web: WKWebView) {
        if isReading(web) { exit(web, animated: true) } else { enter(web) }
    }

    func enter(_ web: WKWebView) {
        let key = ObjectIdentifier(web)
        guard sessions[key] == nil, !starting.contains(key), let source = Self.extractionSource else {
            if Self.extractionSource == nil { onNoArticle?(web) }
            return
        }
        starting.insert(key)
        Task { @MainActor [weak self, weak web] in
            guard let self, let web else { return }
            let value = try? await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: Self.world)
            self.starting.remove(key)
            guard web.window != nil, self.sessions[key] == nil else { return }
            guard let article = value as? [String: Any], article["content"] is String else { self.onNoArticle?(web); return }
            self.present(article: article, over: web)
        }
    }

    func exit(_ web: WKWebView, animated: Bool) {
        guard let session = sessions.removeValue(forKey: ObjectIdentifier(web)) else { return }
        session.close(animated: animated && !BamTheme.reduceMotion)
    }

    func exitAll() {
        for session in sessions.values { session.close(animated: false) }
        sessions.removeAll()
    }

    private func present(article: [String: Any], over web: WKWebView) {
        guard let page = Self.resource("Reader", "html"), let folder = Self.resourcesFolder else { onNoArticle?(web); return }
        let session = ReaderSession(page: web, article: article, preferences: preferences, coordinator: self)
        sessions[ObjectIdentifier(web)] = session
        session.load(page: page, folder: folder)
    }

    fileprivate func received(_ body: [String: Any], from session: ReaderSession) {
        guard let page = session.page, sessions[ObjectIdentifier(page)] === session else { return }
        switch body["type"] as? String {
        case "loaded": session.render()
        case "close": exit(page, animated: true)
        case "prefs": if let prefs = body["prefs"] as? [String: Any] { preferences = prefs }
        default: break
        }
    }

    fileprivate func open(_ url: URL, from session: ReaderSession) {
        guard let page = session.page else { return }
        exit(page, animated: false)
        onOpenLink?(page, url)
    }

    fileprivate func pageNavigated(_ session: ReaderSession) {
        guard let page = session.page else { return }
        exit(page, animated: false)
    }

    // MARK: Resources

    static var resourcesFolder: URL? {
        if let override = ProcessInfo.processInfo.environment["BAM_RESOURCES_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL
    }
    static func resource(_ name: String, _ ext: String) -> URL? {
        guard let url = resourcesFolder?.appendingPathComponent("Reader/\(name).\(ext)"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Readability, its readerable check, and the extraction itself, as one async function body.
    static let extractionSource: String? = {
        guard let readability = resource("Readability", "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
              let readerable = resource("Readability-readerable", "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return nil }
        return readerable + "\n" + readability + "\n" + extraction
    }()

    private static let extraction = #"""
    const normalize = (t) => (t || "").replace(/\s+/g, " ").trim();
    // The paragraph being read, so the article opens at the same place.
    let anchor = null;
    if (window.scrollY > 160) {
      for (const block of document.querySelectorAll("p, li, h2, h3, h4, blockquote, pre")) {
        const r = block.getBoundingClientRect();
        if (r.bottom > 72 && r.top < innerHeight && normalize(block.textContent).length > 40) { anchor = normalize(block.textContent).slice(0, 160); break; }
      }
    }
    const readerable = isProbablyReaderable(document, { minContentLength: 140, minScore: 20 });
    const copy = document.cloneNode(true);
    // Page furniture Readability can keep: wiki edit links, print-hidden bits, skip links.
    copy.querySelectorAll(".mw-editsection, .noprint, .mw-jump-link, [aria-hidden='true'], .sr-only, .visually-hidden").forEach((n) => n.remove());
    const article = new Readability(copy, { charThreshold: 500 }).parse();
    if (!article || !article.content) return null;
    const words = normalize(article.textContent).split(" ").filter(Boolean).length;
    if (words < 120 || (!readerable && words < 300)) return null;
    // A <title> that adds the site's name ("Site — Headline") gives way to the page's own headline.
    const headline = (title) => {
      for (const h of document.querySelectorAll("h1")) {
        const text = normalize(h.textContent);
        if (text.length > 8 && text.length < title.length && normalize(title).includes(text)) return text;
      }
      return title;
    };
    let published = "";
    if (article.publishedTime) {
      const d = new Date(article.publishedTime);
      if (!isNaN(d)) published = d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
    }
    return {
      title: headline(article.title || document.title || ""), byline: article.byline || "", siteName: article.siteName || "",
      content: article.content, words, lang: article.lang || document.documentElement.lang || "", dir: article.dir || "",
      url: location.href, host: location.hostname.replace(/^www\./, ""), published, anchor
    };
    """#
}

/// One page's reader: a web view of Reader.html covering that page.
@MainActor private final class ReaderSession: NSObject, WKNavigationDelegate {
    weak var page: WKWebView?
    let reader: ReaderWebView
    private let article: [String: Any]
    private let preferences: [String: Any]
    private weak var coordinator: ReadingModeCoordinator?
    private var observation: NSKeyValueObservation?
    private var rendered = false
    private var closed = false
    private let pageURL: URL?

    init(page: WKWebView, article: [String: Any], preferences: [String: Any], coordinator: ReadingModeCoordinator) {
        self.page = page; self.article = article; self.preferences = preferences; self.coordinator = coordinator
        pageURL = page.url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = page.configuration.websiteDataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.minimumFontSize = CGFloat(WebsitePreferences.minimumFontSize) // Settings › Websites
        reader = ReaderWebView(frame: page.bounds, configuration: configuration)
        super.init()
        configuration.userContentController.add(ReaderMessageProxy(owner: self), contentWorld: .page, name: "bamReader")
        reader.navigationDelegate = self
        reader.autoresizingMask = [.width, .height]
        reader.alphaValue = 0
        reader.setValue(false, forKey: "drawsBackground")
        reader.setAccessibilityLabel("Reading Mode")
        reader.allowsMagnification = false
        reader.onStep = { [weak self] delta in self?.step(delta) }
        PageInspector.enable(reader)
        observation = page.observe(\.url, options: [.new]) { [weak self] web, _ in
            DispatchQueue.main.async {
                guard let self, !self.closed, web.url != self.pageURL else { return }
                self.coordinator?.pageNavigated(self)
            }
        }
    }

    func load(page file: URL, folder: URL) {
        guard let page else { return }
        reader.frame = page.bounds
        page.addSubview(reader, positioned: .above, relativeTo: nil)
        reader.loadFileURL(file, allowingReadAccessTo: folder)
    }

    func render() {
        guard !rendered, !closed else { return }
        rendered = true
        let anchor = article["anchor"] as? String ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            var payload = self.article; payload.removeValue(forKey: "anchor")
            _ = try? await self.reader.callAsyncJavaScript("return BamReader.render(article, prefs, anchor);",
                arguments: ["article": payload, "prefs": self.preferences, "anchor": anchor], in: nil, contentWorld: .page)
            guard !self.closed else { return }
            // Keyboard focus moves into the article when it was on the page (or nowhere).
            let responder = self.reader.window?.firstResponder
            let focusWasOnPage = responder === self.reader.window || (self.page.map { page in (responder as? NSView)?.isDescendant(of: page) == true } ?? false)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = BamTheme.reduceMotion ? 0 : 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
                self.reader.animator().alphaValue = 1
            }, completionHandler: nil)
            if focusWasOnPage { self.reader.window?.makeFirstResponder(self.reader) }
            NSAccessibility.post(element: self.reader, notification: .layoutChanged)
        }
    }

    private func step(_ delta: Int) {
        Task { @MainActor [weak self] in
            _ = try? await self?.reader.callAsyncJavaScript("return BamReader.step(delta);", arguments: ["delta": delta], in: nil, contentWorld: .page)
        }
    }

    func close(animated: Bool) {
        guard !closed else { return }
        closed = true
        observation = nil
        let reader = self.reader, page = self.page
        let hadFocus = (reader.window?.firstResponder as? NSView).map { $0 === reader || $0.isDescendant(of: reader) } ?? false
        let finish = {
            reader.configuration.userContentController.removeAllScriptMessageHandlers()
            reader.stopLoading()
            reader.removeFromSuperview()
        }
        if hadFocus, let page { page.window?.makeFirstResponder(page) }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            reader.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }

    func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        coordinator?.received(body, from: self)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // Embedded players load in their own frames; the reader page itself is a local file.
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if url.isFileURL, action.navigationType != .linkActivated { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated, URLInput.directURL(url.absoluteString) != nil {
            coordinator?.open(url, from: self)
        }
    }
}

/// The message handler holds its session weakly (WebKit retains handlers).
@MainActor private final class ReaderMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderSession?
    init(owner: ReaderSession) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { owner?.receive(message) }
    }
}

/// ⌘+ / ⌘- / ⌘0 size the article's text rather than zooming the page under it.
@MainActor final class ReaderWebView: WKWebView {
    var onStep: ((Int) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor, alphaValue > 0 else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function, .shift])
        guard mods == .command, let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "=", "+": onStep?(1); return true
        case "-", "_": onStep?(-1); return true
        case "0": onStep?(0); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
