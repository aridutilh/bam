import AppKit
import CryptoKit
import WebKit

/// Bam's built-in ad and tracker blocker.
///
/// Built on WebKit content blocking (`WKContentRuleList`), so requests are stopped before they're
/// made and pages never see the blocker. Rules come from uBlock Origin's default filter lists,
/// downloaded at runtime (never committed: their licenses differ from Bam's) and refreshed weekly
/// without cookies. Until the first download finishes a small built-in list is used.
///
/// Converting and compiling ~130k rules briefly needs several hundred megabytes, which WebKit and
/// the allocator never hand back, so that work runs in a short-lived child process
/// (`BamBrowser --compile-content-rules <dir>`). The browser only looks up the compiled lists,
/// which WebKit memory-maps from disk. Nothing here delays launch: pages opened before the lists
/// are ready get them as soon as they are.
@MainActor final class ContentBlocking: NSObject {
    static let shared = ContentBlocking()

    struct Source: Equatable, Sendable {
        let name: String, file: String, url: URL
    }
    /// uBlock Origin's defaults (Yab ships the same set).
    nonisolated static let sources: [Source] = [
        .init(name: "EasyList", file: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        .init(name: "EasyPrivacy", file: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        .init(name: "uBlock filters", file: "ublock-filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!),
        .init(name: "Malware and scams", file: "ublock-badware", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.txt")!),
        .init(name: "uBlock privacy", file: "ublock-privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!),
        .init(name: "Site fixes", file: "ublock-unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!),
        .init(name: "Peter Lowe’s list", file: "peter-lowe",
              url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext")!)
    ]
    nonisolated static let refreshInterval: TimeInterval = 7 * 24 * 3_600
    /// Bumped whenever the converter changes what it emits, so cached lists are rebuilt.
    nonisolated static let converterVersion = 1
    nonisolated static let compileFlag = "--compile-content-rules"

    struct Manifest: Codable, Sendable {
        var identifiers: [String]
        var ruleCount: Int
        var listCount: Int
        var builtInOnly: Bool
        var builtAt: Date
        var sourcesUpdated: Date?
    }

    /// Off for test fixtures (unless `BAM_CONTENT_BLOCKING=1`), or with `BAM_CONTENT_BLOCKING=0`.
    let isAvailable: Bool
    let directory: URL
    private var listsDirectory: URL { directory.appendingPathComponent("Lists", isDirectory: true) }
    private var storeDirectory: URL { directory.appendingPathComponent("Store", isDirectory: true) }
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private(set) var lists: [WKContentRuleList] = []
    private var started = false
    private var compiling = false, downloading = false, recompileQueued = false
    private var refreshTimer: Timer?
    /// Every tracked page and whether its controller currently has `lists` attached.
    private let pages = NSMapTable<WKWebView, PageTracker>.weakToStrongObjects()
    private var observers: [NSObjectProtocol] = []

    private override init() {
        let arguments = CommandLine.arguments
        let override = ProcessInfo.processInfo.environment["BAM_CONTENT_BLOCKING"]
        let fixture = arguments.contains { OnboardingGate.testArguments.contains($0) }
        isAvailable = override == "1" || (override != "0" && !fixture)
        directory = Self.workingDirectory(arguments: arguments)
        super.init()
    }

    nonisolated static func workingDirectory(arguments: [String]) -> URL {
        if ContentBlockingPreference.isDisposableLaunch(arguments) {
            // A cache, not profile data: fresh previews share it so each launch doesn't download again.
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BamContentBlocking", isDirectory: true)
        }
        let launch = try? PreviewProfile(arguments: arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(launch?.supportDirectoryName ?? "OrbitPrototype", isDirectory: true)
            .appendingPathComponent("ContentBlocking", isDirectory: true)
    }

    // MARK: Pages

    /// Call once for every web view that shows web pages to the user, right after creating it
    /// (before its first load). Blocking follows the page from site to site.
    func track(_ webView: WKWebView) {
        guard isAvailable, pages.object(forKey: webView) == nil else { return }
        start()
        let tracker = PageTracker(webView: webView, owner: self)
        pages.setObject(tracker, forKey: webView)
        apply(to: webView)
    }

    /// Whether the page's content controller should have the lists, and make it so.
    fileprivate func apply(to webView: WKWebView) {
        guard let tracker = pages.object(forKey: webView) else { return }
        let wanted = ContentBlockingPreference.blocks(webView.url) && !lists.isEmpty
        let controller = webView.configuration.userContentController
        if wanted && tracker.attached !== listsToken {
            if tracker.attached != nil { tracker.attachedLists.forEach(controller.remove) }
            lists.forEach(controller.add)
            tracker.attached = listsToken; tracker.attachedLists = lists
        } else if !wanted && tracker.attached != nil {
            tracker.attachedLists.forEach(controller.remove)
            tracker.attached = nil; tracker.attachedLists = []
        }
    }
    private func applyEverywhere() {
        for webView in pages.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) { apply(to: webView) }
    }
    /// Identity of the current generation of `lists`.
    private var listsToken = NSObject()

    /// Site controls' "Block ads and trackers": remembered for the site, and its open pages reload.
    func setBlocks(_ on: Bool, forSiteOf url: URL?) {
        guard let site = ContentBlockingPreference.site(url) else { return }
        ContentBlockingPreference.setBlocks(on, for: url)
        for webView in pages.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            guard let other = ContentBlockingPreference.site(webView.url),
                  other == site || other.hasSuffix("." + site) || site.hasSuffix("." + other) else { continue }
            pages.object(forKey: webView)?.dismissPrompt()
            apply(to: webView)
            if webView.window != nil { webView.reload() }
        }
    }

    // MARK: Lists

    private func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(forName: .contentBlockingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .contentBlockingUpdateRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.download(force: true) }
        })
        try? FileManager.default.createDirectory(at: listsDirectory, withIntermediateDirectories: true)
        loadCompiled { [weak self] loaded in
            guard let self else { return }
            if !loaded || self.listsChangedSinceBuild() { self.compile() }
        }
        // Check for new lists a little after launch, then every few hours while Bam stays open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.download(force: false) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.download(force: false) }
        }
    }

    private var lastPreferenceEnabled = ContentBlockingPreference.isEnabled
    private func preferenceChanged() {
        applyEverywhere()
        let enabled = ContentBlockingPreference.isEnabled
        if enabled && !lastPreferenceEnabled { download(force: false) }
        lastPreferenceEnabled = enabled
    }

    private func readManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// Look up the lists the last compile left in the store (cheap: WebKit maps them from disk).
    private func loadCompiled(_ done: @escaping (Bool) -> Void) {
        guard let manifest = readManifest(), !manifest.identifiers.isEmpty,
              let store = WKContentRuleListStore(url: storeDirectory) else { done(false); return }
        var found: [Int: WKContentRuleList] = [:], remaining = manifest.identifiers.count, failed = false
        for (index, identifier) in manifest.identifiers.enumerated() {
            store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
                MainActor.assumeIsolated {
                    if let list { found[index] = list } else { failed = true }
                    remaining -= 1
                    guard remaining == 0, let self else { return }
                    guard !failed else { done(false); return }
                    self.install((0..<manifest.identifiers.count).compactMap { found[$0] }, manifest: manifest)
                    done(true)
                }
            }
        }
    }

    private func install(_ newLists: [WKContentRuleList], manifest: Manifest) {
        lists = newLists; listsToken = NSObject()
        ContentBlockingPreference.status.ruleCount = manifest.ruleCount
        ContentBlockingPreference.status.listCount = manifest.listCount
        ContentBlockingPreference.status.builtInOnly = manifest.builtInOnly
        ContentBlockingPreference.status.updated = manifest.sourcesUpdated
        applyEverywhere()
        NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
    }

    private func listsChangedSinceBuild() -> Bool {
        guard let manifest = readManifest() else { return true }
        return (newestListDate() ?? .distantPast) > manifest.builtAt
    }
    private func newestListDate() -> Date? {
        Self.sources.compactMap { source in
            (try? listsDirectory.appendingPathComponent(source.file + ".txt").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    /// Convert and compile in the child process, then pick up what it built.
    private func compile() {
        guard !compiling else { recompileQueued = true; return }
        compiling = true
        let directory = self.directory
        let finish: @Sendable (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shared = ContentBlocking.shared
                    shared.loadCompiled { _ in
                        shared.compiling = false
                        if shared.recompileQueued { shared.recompileQueued = false; shared.compile() }
                    }
                    if !ok { NSLog("Bam content blocking: compiling filter lists failed") }
                }
            }
        }
        guard let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension == "app" else {
            // No app bundle (harnesses): compile here instead.
            Self.compileLists(in: directory) { finish($0) }
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.compileFlag, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.qualityOfService = .utility
        process.terminationHandler = { finish($0.terminationStatus == 0) }
        do { try process.run() } catch { Self.compileLists(in: directory) { finish($0) } }
    }

    /// Fetch every list when they're a week old (or on request), without cookies or a shared cache.
    func download(force: Bool) {
        guard isAvailable, started, !downloading, ContentBlockingPreference.isEnabled else { return }
        let stamp = listsDirectory.appendingPathComponent(".checked")
        let checked = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !force, let checked, Date().timeIntervalSince(checked) < Self.refreshInterval,
           Self.sources.allSatisfy({ FileManager.default.fileExists(atPath: listsDirectory.appendingPathComponent($0.file + ".txt").path) }) { return }
        downloading = true
        ContentBlockingPreference.status.updating = true
        NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Bam/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"]
        let session = URLSession(configuration: configuration)
        let group = DispatchGroup()
        let folder = listsDirectory
        let changed = ChangeCounter()
        for source in Self.sources {
            group.enter()
            session.dataTask(with: source.url) { data, response, _ in
                defer { group.leave() }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count > 200,
                      let text = String(data: data, encoding: .utf8), Self.looksLikeFilterList(text) else { return }
                let file = folder.appendingPathComponent(source.file + ".txt")
                if (try? Data(contentsOf: file)) == data { return }
                if (try? data.write(to: file, options: .atomic)) != nil { changed.increment() }
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                session.finishTasksAndInvalidate()
                guard let self else { return }
                self.downloading = false
                ContentBlockingPreference.status.updating = false
                FileManager.default.createFile(atPath: stamp.path, contents: Data())
                if changed.value > 0 || self.listsChangedSinceBuild() { self.compile() }
                else {
                    ContentBlockingPreference.status.updated = Date()
                    NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
                }
            }
        }
    }

    nonisolated static func looksLikeFilterList(_ text: String) -> Bool {
        let head = text.prefix(2_000)
        return !head.localizedCaseInsensitiveContains("<html") && (head.hasPrefix("[Adblock") || head.hasPrefix("!") || head.contains("||"))
    }

    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: Compiler (child process)

    /// Entry for `BamBrowser --compile-content-rules <dir>`; returns at once for any other launch.
    nonisolated static func runCompilerIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: compileFlag), flag + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        compileLists(in: directory) { ok in exit(ok ? 0 : 1) }
        // WebKit must start on the main thread, so keep it (not dispatchMain, which gives the main queue to a worker).
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    /// Read the downloaded lists (or the built-in seed), convert, compile into the store and write the manifest.
    nonisolated static func compileLists(in directory: URL, completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let listsDirectory = directory.appendingPathComponent("Lists", isDirectory: true)
            let storeDirectory = directory.appendingPathComponent("Store", isDirectory: true)
            try? fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let started = Date()
            var texts: [String] = [], newest: Date?
            for source in sources {
                let file = listsDirectory.appendingPathComponent(source.file + ".txt")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                texts.append(text)
                if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { newest = max(newest ?? date, date) }
            }
            let builtInOnly = texts.isEmpty
            if builtInOnly, let seed = Bundle.main.url(forResource: "ContentBlockingSeed", withExtension: "txt").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
                ?? ProcessInfo.processInfo.environment["BAM_RESOURCES_DIR"].flatMap({ try? String(contentsOfFile: $0 + "/ContentBlockingSeed.txt", encoding: .utf8) }) {
                texts = [seed]
            }
            guard !texts.isEmpty else { completion(false); return }
            var hasher = SHA256()
            hasher.update(data: Data("v\(converterVersion)".utf8))
            for text in texts { hasher.update(data: Data(text.utf8)) }
            let digest = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
            let output = ContentBlockingConverter.convert(texts)
            let encoded = ContentBlockingConverter.encodedLists(output)
            let identifiers = encoded.indices.map { "bam-\(digest)-\($0)" }
            DispatchQueue.main.async {
                guard let store = WKContentRuleListStore(url: storeDirectory) else { completion(false); return }
                // One at a time keeps the peak lower than compiling every list at once.
                func next(_ index: Int) {
                    guard index < encoded.count else {
                        let manifest = Manifest(identifiers: identifiers, ruleCount: output.ruleCount, listCount: texts.count,
                                                builtInOnly: builtInOnly, builtAt: Date(), sourcesUpdated: newest)
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                        guard let data = try? encoder.encode(manifest),
                              (try? data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)) != nil else { completion(false); return }
                        // Drop lists from older builds.
                        store.getAvailableContentRuleListIdentifiers { existing in
                            for old in existing ?? [] where !identifiers.contains(old) { store.removeContentRuleList(forIdentifier: old) { _ in } }
                            print("Compiled \(output.ruleCount) content rules in \(identifiers.count) lists (\(output.skipped) filters skipped) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                            completion(true)
                        }
                        return
                    }
                    store.lookUpContentRuleList(forIdentifier: identifiers[index]) { existing, _ in
                        if existing != nil { next(index + 1); return }
                        store.compileContentRuleList(forIdentifier: identifiers[index], encodedContentRuleList: encoded[index]) { list, error in
                            guard list != nil else {
                                NSLog("Bam content blocking: list \(index) failed: \(error.map { "\($0)" } ?? "unknown")")
                                completion(false); return
                            }
                            next(index + 1)
                        }
                    }
                }
                next(0)
            }
        }
    }
}

// MARK: - Per page

/// Follows one web view: re-applies blocking when it moves between sites, and offers "Allow Ads Here"
/// when the same page is reloaded three times in 20 seconds while blocking was on.
@MainActor private final class PageTracker: NSObject {
    weak var webView: WKWebView?
    weak var owner: ContentBlocking?
    var attached: NSObject?
    var attachedLists: [WKContentRuleList] = []
    private var observations: [NSKeyValueObservation] = []
    private var breakage = ContentBlockingBreakageDetector()
    private var prompt: ContentBlockingPrompt?

    init(webView: WKWebView, owner: ContentBlocking) {
        self.webView = webView; self.owner = owner
        super.init()
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.urlChanged(web) } }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.loadingChanged(web) } }
            }
        ]
    }

    private var lastSite: String?
    private func urlChanged(_ web: WKWebView) {
        owner?.apply(to: web)
        let site = ContentBlockingPreference.site(web.url)
        if site != lastSite { dismissPrompt() }
        lastSite = site
    }
    private func loadingChanged(_ web: WKWebView) {
        guard web.isLoading else { return }
        let blocking = ContentBlockingPreference.blocks(web.url) && !(owner?.lists.isEmpty ?? true)
        let tripped = breakage.pageStarted(web.url, at: ProcessInfo.processInfo.systemUptime)
        if tripped && blocking && ContentBlockingPreference.site(web.url) != nil { showPrompt(on: web) }
    }

    private func showPrompt(on web: WKWebView) {
        guard prompt == nil else { return }
        let card = ContentBlockingPrompt()
        let url = web.url
        card.onAllow = { [weak self] in
            self?.dismissPrompt()
            ContentBlocking.shared.setBlocks(false, forSiteOf: url)
        }
        card.onClose = { [weak self] in self?.dismissPrompt() }
        card.present(in: web)
        prompt = card
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak card] in
            guard let self, let card, self.prompt === card, !card.isHovered else { return }
            self.dismissPrompt()
        }
    }
    func dismissPrompt() { prompt?.dismiss(); prompt = nil }
}

/// The small corner card: "Page not working?" with "Allow Ads Here". Drawn in Bam's own palette
/// (card surface, ink, red action) so it reads as the browser speaking, not the page.
@MainActor final class ContentBlockingPrompt: NSView {
    var onAllow: () -> Void = {}
    var onClose: () -> Void = {}
    private(set) var isHovered = false
    private let title = NSTextField(labelWithString: "Page not working?")
    private let detail = NSTextField(labelWithString: "Ads are blocked on this site.")
    private let allow = BamPillButton(title: "Allow Ads Here", prominent: true)
    private let close = NSButton()
    static let size = NSSize(width: 372, height: 62)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1; layer?.shadowRadius = 14; layer?.shadowOffset = CGSize(width: 0, height: -4)
        title.font = BamType.sans(13.5, weight: .bold)
        detail.font = BamType.sans(12)
        [title, detail].forEach { $0.lineBreakMode = .byTruncatingTail; $0.setAccessibilityElement(false) }
        allow.translatesAutoresizingMaskIntoConstraints = true
        allow.target = self; allow.action = #selector(allowPressed)
        allow.setAccessibilityLabel("Allow Ads Here")
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        close.target = self; close.action = #selector(closePressed)
        close.setAccessibilityLabel("Dismiss")
        [close, title, detail, allow].forEach(addSubview)
        paint()
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Page not working? Ads and trackers are blocked here.")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BamTheme.card.cgColor
            layer?.borderColor = BamTheme.line.cgColor
            layer?.shadowColor = BamTheme.shadow.cgColor
        }
        title.textColor = BamTheme.ink; detail.textColor = BamTheme.muted; close.contentTintColor = BamTheme.muted
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }

    override func layout() {
        super.layout()
        let h = bounds.height
        close.frame = NSRect(x: 12, y: (h - 20) / 2, width: 20, height: 20)
        let button = allow.fittingSize
        let width = max(button.width, 112)
        allow.frame = NSRect(x: bounds.width - width - 12, y: (h - button.height) / 2, width: width, height: button.height)
        let textX: CGFloat = 40, textWidth = allow.frame.minX - textX - 10
        title.frame = NSRect(x: textX, y: h / 2, width: textWidth, height: 18)
        detail.frame = NSRect(x: textX, y: h / 2 - 17, width: textWidth, height: 16)
    }

    func present(in host: NSView) {
        let inset: CGFloat = 12
        let y = host.isFlipped ? host.bounds.height - Self.size.height - inset : inset
        frame = NSRect(x: host.bounds.width - Self.size.width - inset, y: y, width: Self.size.width, height: Self.size.height)
        autoresizingMask = host.isFlipped ? [.minXMargin, .minYMargin] : [.minXMargin, .maxYMargin]
        alphaValue = 0
        host.addSubview(self, positioned: .above, relativeTo: nil)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rest = frame
        if !reduce { frame = rest.offsetBy(dx: 0, dy: host.isFlipped ? 8 : -8) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.12 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
            animator().alphaValue = 1
            animator().frame = rest
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Page not working? Allow Ads Here is available.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    @objc private func allowPressed() { onAllow() }
    @objc private func closePressed() { onClose() }
}
