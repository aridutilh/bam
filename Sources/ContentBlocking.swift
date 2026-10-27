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
    nonisolated static let converterVersion = 2
    nonisolated static let compileFlag = "--compile-content-rules"

    struct Manifest: Codable, Sendable {
        var identifiers: [String]
        var ruleCount: Int
        var listCount: Int
        var builtInOnly: Bool
        var builtAt: Date
        var sourcesUpdated: Date?
        /// `converterVersion` at build time; nil for builds before it was recorded.
        var converterVersion: Int? = nil
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
        let wanted = ContentBlockingPreference.blocks(webView.url) && !lists.isEmpty && !Self.isExtensionPage(webView)
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
    /// Extension pages run in their extension's shared configuration; lists added there would also
    /// filter the extension's background page and popups, and nothing would take them off again.
    static func isExtensionPage(_ webView: WKWebView) -> Bool {
        webView.url?.scheme?.lowercased().hasSuffix("-extension") == true // webkit-extension, safari-web-extension…
    }
    /// The ad blocker stopped a page itself (a `$document` filter: malware and scam lists), so retrying won't help.
    static func stoppedPage(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "WebKitErrorDomain" && error.code == 104 // WebKitErrorFrameLoadBlockedByContentBlocker
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
            if !loaded || self.listsChangedSinceBuild() || self.readManifest()?.converterVersion != Self.converterVersion { self.compile() }
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
        do { try process.run() } catch { Self.compileLists(in: directory) { finish($0) }; return }
        // A full build takes seconds; one that hangs would otherwise block every later update this session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak process] in
            guard let process, process.isRunning else { return }
            NSLog("Bam content blocking: list compiler timed out")
            process.terminate()
        }
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
        let changed = ChangeCounter(), fetched = ChangeCounter()
        for source in Self.sources {
            group.enter()
            session.dataTask(with: source.url) { data, response, _ in
                defer { group.leave() }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count > 200,
                      let text = String(data: data, encoding: .utf8), Self.looksLikeFilterList(text) else { return }
                fetched.increment()
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
                // Offline: try again at the next check instead of in a week.
                if fetched.value > 0 { FileManager.default.createFile(atPath: stamp.path, contents: Data()) }
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
                var compiled: [String] = [], dropped = 0
                // One at a time keeps the peak lower than compiling every list at once.
                func next(_ index: Int) {
                    guard index < encoded.count else {
                        guard !compiled.isEmpty else { completion(false); return }
                        let manifest = Manifest(identifiers: compiled, ruleCount: output.ruleCount - dropped, listCount: texts.count,
                                                builtInOnly: builtInOnly, builtAt: Date(), sourcesUpdated: newest, converterVersion: converterVersion)
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                        guard let data = try? encoder.encode(manifest),
                              (try? data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)) != nil else { completion(false); return }
                        // Drop lists from older builds.
                        store.getAvailableContentRuleListIdentifiers { existing in
                            for old in existing ?? [] where !compiled.contains(old) { store.removeContentRuleList(forIdentifier: old) { _ in } }
                            print("Compiled \(output.ruleCount - dropped) content rules in \(compiled.count) lists (\(output.skipped) filters skipped, \(dropped) rejected by WebKit) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                            completion(true)
                        }
                        return
                    }
                    store.lookUpContentRuleList(forIdentifier: identifiers[index]) { existing, _ in
                        if existing != nil { compiled.append(identifiers[index]); next(index + 1); return }
                        store.compileContentRuleList(forIdentifier: identifiers[index], encodedContentRuleList: encoded[index]) { list, error in
                            if list != nil { compiled.append(identifiers[index]); next(index + 1); return }
                            // WebKit rejects a whole list over one rule it can't parse; find those rules and leave them out.
                            NSLog("Bam content blocking: list \(index) failed (\(error.map { "\($0)" } ?? "unknown")); looking for the rules WebKit rejects")
                            compileLeavingOutRejected(encoded[index], as: identifiers[index], in: store) { ok, rejected in
                                if ok { compiled.append(identifiers[index]); dropped += rejected }
                                else { NSLog("Bam content blocking: list \(index) left out") }
                                next(index + 1)
                            }
                        }
                    }
                }
                next(0)
            }
        }
    }

    /// Compiles a list WebKit refused, without the rules it rejects: halves are test-compiled until each
    /// rejected rule is found (about twice the work of one compile per bad rule). Gives up past `limit`.
    nonisolated static func compileLeavingOutRejected(_ encoded: String, as identifier: String, in store: WKContentRuleListStore,
                                                      limit: Int = 64, completion: @escaping (Bool, Int) -> Void) {
        guard let rules = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [Any] else { completion(false, 0); return }
        let probe = identifier + "-probe"
        func json(_ items: [Any]) -> String? {
            (try? JSONSerialization.data(withJSONObject: items, options: [.withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) }
        }
        var rejected: [Int] = []
        var pending: [Range<Int>] = [0..<rules.count]
        func step() {
            guard rejected.count <= limit else { store.removeContentRuleList(forIdentifier: probe) { _ in }; completion(false, 0); return }
            guard let range = pending.popLast() else {
                store.removeContentRuleList(forIdentifier: probe) { _ in }
                let skip = Set(rejected)
                let kept = rules.indices.filter { !skip.contains($0) }.map { rules[$0] }
                guard !kept.isEmpty, let text = json(kept) else { completion(false, 0); return }
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text) { list, _ in
                    completion(list != nil, rejected.count)
                }
                return
            }
            guard let text = json(Array(rules[range])) else { rejected.append(contentsOf: range); step(); return }
            store.compileContentRuleList(forIdentifier: probe, encodedContentRuleList: text) { list, _ in
                if list != nil { step(); return }
                if range.count == 1 { rejected.append(range.lowerBound); step(); return }
                let middle = range.lowerBound + range.count / 2
                pending.append(middle..<range.upperBound); pending.append(range.lowerBound..<middle)
                step()
            }
        }
        step()
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
        card.present(in: web)
        prompt = card
        dismissWhenIdle(card, after: 12)
    }
    /// The toast has no close button: it leaves on its own, waiting while the pointer rests on it.
    private func dismissWhenIdle(_ card: ContentBlockingPrompt, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak card] in
            guard let self, let card, self.prompt === card else { return }
            if card.isHovered { self.dismissWhenIdle(card, after: 2) } else { self.dismissPrompt() }
        }
    }
    func dismissPrompt() { prompt?.dismiss(); prompt = nil }
}

/// "Page not working?" as an Arc-style toast: a small frosted pill at the page's top-right with one
/// bordered action, that grows into place and leaves on its own.
@MainActor final class ContentBlockingPrompt: NSView {
    var onAllow: () -> Void = {}
    private(set) var isHovered = false
    private let glass = NSVisualEffectView()
    private let title = NSTextField(labelWithString: "Page not working?")
    private let allow = ContentBlockingToastButton(title: "Allow Ads Here")
    static let height: CGFloat = 44, inset: CGFloat = 8

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16; layer?.shadowRadius = 12; layer?.shadowOffset = CGSize(width: 0, height: -3)
        glass.material = .popover; glass.blendingMode = .withinWindow; glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12; glass.layer?.cornerCurve = .continuous; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        addSubview(glass)
        title.font = .systemFont(ofSize: 13.5, weight: .medium); title.textColor = .labelColor
        title.setAccessibilityElement(false)
        allow.target = self; allow.action = #selector(allowPressed)
        glass.addSubview(title); glass.addSubview(allow)
        paint()
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Page not working? Ads and trackers are blocked on this site.")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glass.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }

    var preferredSize: NSSize {
        let text = ceil(title.attributedStringValue.size().width)
        return NSSize(width: 16 + text + 12 + allow.preferredWidth + 8, height: Self.height)
    }
    override func layout() {
        super.layout()
        glass.frame = bounds
        let h = bounds.height
        allow.frame = NSRect(x: bounds.width - allow.preferredWidth - 8, y: (h - 28) / 2, width: allow.preferredWidth, height: 28)
        title.frame = NSRect(x: 16, y: (h - 18) / 2, width: allow.frame.minX - 28, height: 18)
    }

    func present(in host: NSView) {
        let size = preferredSize
        let y = host.isFlipped ? Self.inset : host.bounds.height - size.height - Self.inset
        frame = NSRect(x: host.bounds.width - size.width - Self.inset, y: y, width: size.width, height: size.height)
        autoresizingMask = host.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        host.addSubview(self, positioned: .above, relativeTo: nil)
        layoutSubtreeIfNeeded()
        // Grows into place from 96% about its own center, fading in (Arc's toast entrance).
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let layer else { return }
        let duration = reduce ? 0.12 : 0.22
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup(); group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        if reduce { group.animations = [fade] } else {
            let grow = CABasicAnimation(keyPath: "transform")
            let b = layer.bounds
            var t = CATransform3DMakeTranslation(b.width * 0.02, b.height * 0.02, 0)
            t = CATransform3DScale(t, 0.96, 0.96, 1)
            grow.fromValue = NSValue(caTransform3D: t); grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            group.animations = [fade, grow]
        }
        layer.add(group, forKey: "enter")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Page not working? Allow Ads Here is available.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    @objc private func allowPressed() { onAllow() }
}

/// The toast's bordered action, like the square button in Arc's toasts but carrying words.
@MainActor private final class ContentBlockingToastButton: NSButton {
    private var hovering = false
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true
        self.title = title
        font = .systemFont(ofSize: 12.5, weight: .semibold)
        layer?.cornerRadius = 7; layer?.cornerCurve = .continuous; layer?.borderWidth = 0.5
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var preferredWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font as Any]).width) + 22 }
    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = dark ? NSColor(white: 1, alpha: hovering ? 0.16 : 0.10) : NSColor(white: 1, alpha: hovering ? 0.95 : 0.7)
            layer?.backgroundColor = (isHighlighted ? NSColor(white: dark ? 1 : 0, alpha: 0.12) : base).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font as Any, .foregroundColor: NSColor.labelColor])
    }
    override var isHighlighted: Bool { didSet { paint() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }
}
