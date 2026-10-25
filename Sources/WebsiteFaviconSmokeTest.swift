import AppKit
import WebKit

/// Real loopback documents, WebKit link discovery, asynchronous image loading and
/// rendered native controls. This fixture never opens a real browser profile.
@MainActor final class WebsiteFaviconSmokeTest {
    private var controller: BrowserController!
    private var window: NSWindow!
    private var watchdog: Timer?
    private var runner: Task<Void, Never>?
    private var finished = false
    private var checks = 0
    private var iconChanges: [UUID: Int] = [:]
    private var watchedBlueProfile: UUID?
    private var staleRedAppeared = false
    enum Failure: Error { case assertion(String) }

    func start() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        runner = Task { @MainActor in
            do {
                try await run()
                finish(true, "\(checks) checks: real PNG and inline/network SVG discovery, native sidebar/Favorite/palette images, profile separation, custom-icon fallback, cached-miss replacement and stale-navigation rejection")
            } catch { finish(false, String(describing: error)) }
        }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
        checks += 1
    }
    private func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { checks += 1; return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.assertion("Timed out: \(message)")
    }
    private func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
    private func ready(_ web: WKWebView, at url: URL, title: String) async throws {
        try await wait(title) { !web.isLoading && web.url == url && web.title == title }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func row(_ id: UUID) -> NSView? {
        descendants(controller.sidebar).first { $0.identifier?.rawValue == "tab-row-\(id.uuidString)" }
    }
    private func icon(in view: NSView?) -> NSImageView? {
        guard let view else { return nil }
        return descendants(view).compactMap { $0 as? NSImageView }.first { $0.identifier?.rawValue == "website-favicon" }
    }
    private func favorite(_ id: UUID) -> NSButton? {
        descendants(controller.sidebar).first { $0.identifier?.rawValue == "favorite-\(id.uuidString)" } as? NSButton
    }
    private func isColor(_ image: NSImage?, red: Bool) -> Bool {
        guard let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.9 && (red
            ? color.redComponent > 0.75 && color.blueComponent < 0.25
            : color.blueComponent > 0.75 && color.redComponent < 0.25)
    }
    /// Emoji artwork need not cover the center pixel. Sample the complete small
    /// decoded image instead of relying on a particular installed glyph design.
    private func hasVisibleArtwork(_ image: NSImage?) -> Bool {
        guard let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
        var visible = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.25 else { continue }
                visible += 1
            }
        }
        return visible > bitmap.pixelsWide * bitmap.pixelsHigh / 100
    }
    private func cached(_ page: URL, profile: UUID) -> NSImage? {
        controller.favicons.image(for: page, profileID: profile, allowFetch: false)
    }

    /// Optional evidence from this isolated fixture only. No screen capture,
    /// user-window access, or delay is needed to save the native rendered view.
    private func capture(_ view: NSView, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["BAM_FAVICON_CAPTURE_DIR"], !path.isEmpty else { return }
        guard path.hasPrefix("/") else { throw Failure.assertion("BAM_FAVICON_CAPTURE_DIR must be an absolute path") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller.view.layoutSubtreeIfNeeded(); view.layoutSubtreeIfNeeded()
        window.displayIfNeeded(); view.displayIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure.assertion("Could not allocate native \(name) capture")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.assertion("Could not encode \(name) capture") }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BAM_TEST_URL"] ?? env["ARK_TEST_URL"] ?? env["ORBIT_TEST_URL"],
              let base = URLInput.directURL(raw), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(base.host ?? "") else {
            throw Failure.assertion("Set BAM_TEST_URL to the isolated loopback fixture server")
        }
        let folder = base.deletingLastPathComponent().appendingPathComponent("favicon", isDirectory: true)
        let redURL = folder.appendingPathComponent("red.html"), blueURL = folder.appendingPathComponent("blue.html")
        let missingURL = folder.appendingPathComponent("missing.html")
        let red = BrowserTab(title: "Red", address: redURL.absoluteString, space: 0)
        var session = BrowserSession(tabs: [red], activeID: red.id,
                                     spaces: [BrowserSpace(id: 0, name: "Red profile", symbol: "house", colorIndex: 0)])
        guard let blueProfile = session.createProfile(name: "Blue profile"),
              let blueSpace = session.createSpace(name: "Blue", symbol: "globe", colorIndex: 1, profileID: blueProfile),
              let missingProfile = session.createProfile(name: "Missing icon profile"),
              let missingSpace = session.createSpace(name: "Missing", symbol: "book", colorIndex: 2, profileID: missingProfile) else {
            throw Failure.assertion("Could not create isolated fixture profiles")
        }
        let blue = BrowserTab(title: "Blue", address: blueURL.absoluteString, space: blueSpace)
        let missing = BrowserTab(title: "Missing", address: missingURL.absoluteString, space: missingSpace)
        session.tabs += [blue, missing]
        controller = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/bam-favicon-unused-\(UUID()).json"), ephemeral: true)
        controller.automaticallyShowsVideo = false; controller.automaticTabSleeping = false
        controller.session = session
        try check(controller.privateMode, "Favicon fixture must use a private controller")
        let redStore = controller.profileStores.store(for: BrowserProfile.defaultID)
        let blueStore = controller.profileStores.store(for: blueProfile)
        try check(!redStore.isPersistent && !blueStore.isPersistent && redStore !== blueStore, "Fixture stores must be disposable and profile-separated")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Bam — isolated favicon fixture"; window.contentViewController = controller
        // Installing an NSViewController adopts its initial 1×1 root size.
        // Size after attachment, as the real app and interaction fixtures do.
        window.setContentSize(NSSize(width: 1060, height: 720))
        window.makeKeyAndOrderFront(nil)
        controller.layoutBrowser(); controller.view.layoutSubtreeIfNeeded()
        try check(controller.view.bounds.width >= 1000 && controller.view.bounds.height >= 700,
                  "Fixture content did not retain its intended visible size")
        try check(!controller.sidebar.isHidden && controller.sidebar.bounds.width >= 200 && controller.sidebar.bounds.height >= 700,
                  "Fixture sidebar is hidden or too small to realize its rows")
        guard let redWeb = controller.browsers[red.id] else { throw Failure.assertion("Initial page was not created") }
        let refreshIcons = controller.favicons.onChange
        controller.favicons.onChange = { [weak self] profile, origin in
            guard let self else { return }
            self.iconChanges[profile, default: 0] += 1
            if self.watchedBlueProfile == profile, self.isColor(self.cached(blueURL, profile: profile), red: true) { self.staleRedAppeared = true }
            refreshIcons?(profile, origin)
        }
        try await ready(redWeb, at: redURL, title: "Bam Favicon Red")
        try await wait("real declared red PNG") { isColor(cached(redURL, profile: BrowserProfile.defaultID), red: true) }
        let redImage = cached(redURL, profile: BrowserProfile.defaultID)!
        try check(!redImage.isTemplate, "Site artwork must retain its original colors")
        try check(cached(redURL, profile: blueProfile) == nil, "A different profile inherited Red's cache entry")
        guard let discovery = try await js(redWeb, BrowserController.faviconDiscoveryScript) as? [String: Any],
              let candidates = discovery["icons"] as? [String] else { throw Failure.assertion("Real DOM discovery did not return candidates") }
        try check(discovery["page"] as? String == redURL.absoluteString, "Discovery lost the source document URL")
        try check(candidates.first == folder.appendingPathComponent("red.png").absoluteString, "Discovery failed to prefer the declared 32px regular icon")
        try check(!candidates.contains { $0.hasPrefix("javascript:") || $0.contains("hidden.png") }, "Discovery accepted an unsafe or nonmatching-media declaration")
        try check(Set(candidates).count == candidates.count, "Discovery did not deduplicate declared URLs")
        try await wait("native sidebar image") { isColor(icon(in: row(red.id))?.image, red: true) }
        try check(icon(in: row(red.id))?.contentTintColor == nil, "Sidebar tinted the site's raster icon")
        try capture(controller.sidebar, named: "sidebar")
        let rowIdentity = row(red.id)
        controller.sidebar.refreshFavicons()
        try check(row(red.id) === rowIdentity, "Favicon arrival replaced an existing sidebar row")
        try check(try await js(redWeb, "window.faviconFixtureSentinel") as? String == "red-document", "Icon loading reloaded or modified the page")

        // Open the real palette with an empty query: no remote suggestions.
        controller.openAddress(newTab: false, empty: true)
        guard let results = controller.tabSearchResults else { throw Failure.assertion("Command palette did not create results") }
        controller.view.layoutSubtreeIfNeeded()
        let redResult = descendants(results).first { $0.accessibilityLabel()?.hasPrefix("Bam Favicon Red,") == true }
        try check(isColor(icon(in: redResult)?.image, red: true), "Existing-tab palette result did not receive the real cached icon")
        results.moveSelection(delta: 1)
        let selected = results.selectedIndex, children = results.subviews.map(ObjectIdentifier.init)
        results.refreshFavicons()
        try check(results.selectedIndex == selected && results.subviews.map(ObjectIdentifier.init) == children, "Icon refresh disturbed palette selection or rebuilt rows")
        controller.addressField?.stringValue = redURL.absoluteString
        controller.refreshPaletteResults()
        try check(descendants(results).compactMap { $0 as? NSImageView }.filter { $0.identifier?.rawValue == "website-favicon" && isColor($0.image, red: true) }.count >= 2,
                  "Cached typed URL and matching tab should both show their favicon")
        if let palette = controller.addressCard { try capture(palette, named: "palette") }
        controller.dismissAddress()

        // Retention and explicit artwork continue to take precedence over sites.
        try check(controller.session.setRetention(id: red.id, kind: .favorite), "Could not favorite the fixture page")
        controller.refresh(); controller.view.layoutSubtreeIfNeeded()
        try check(isColor(favorite(red.id)?.image, red: true), "Favorite tile did not use its site's icon")
        try capture(controller.sidebar, named: "favorites")
        try check(controller.session.updateSavedTab(id: red.id, customTitle: nil, customSymbol: BrowserSpace.symbols[0]), "Could not assign a custom symbol")
        controller.refresh()
        try check(controller.favicon(forTabID: red.id) == nil && favorite(red.id)?.image == nil, "Site icon overrode an explicit saved symbol")
        try check(controller.session.updateSavedTab(id: red.id, customTitle: nil, customSymbol: nil), "Could not restore automatic site artwork")
        controller.refresh()
        try check(isColor(favorite(red.id)?.image, red: true), "Removing a custom symbol did not restore cached artwork")

        controller.select(blue.id)
        guard let blueWeb = controller.browsers[blue.id] else { throw Failure.assertion("Blue page was not created") }
        try await ready(blueWeb, at: blueURL, title: "Bam Favicon Blue")
        try await wait("same-origin Blue profile icon") { isColor(cached(blueURL, profile: blueProfile), red: false) }
        try check(isColor(cached(redURL, profile: BrowserProfile.defaultID), red: true), "Blue profile changed Red's same-origin favicon")
        try await wait("Blue native sidebar icon") { isColor(icon(in: row(blue.id))?.image, red: false) }
        try check(favorite(red.id) == nil, "Another profile's favorite leaked into the active sidebar")

        // The JS callback is necessarily asynchronous. A new navigation in this
        // same turn must invalidate its token before that callback can apply.
        _ = try await js(blueWeb, "document.querySelector('#current-icon').href='red.png'; true")
        watchedBlueProfile = blueProfile
        controller.discoverFavicon(in: blueWeb)
        try check(controller.faviconDocumentGenerations[blue.id] != nil, "Stale-discovery test never started discovery")
        let nextBlueURL = URL(string: blueURL.absoluteString + "?navigation=next")!
        controller.load(nextBlueURL.absoluteString, in: blueWeb, id: blue.id)
        try check(controller.faviconDocumentGenerations[blue.id] == nil, "Navigation did not invalidate discovery synchronously")
        try await ready(blueWeb, at: nextBlueURL, title: "Bam Favicon Blue")
        // A second WebKit round trip also completes after old-document work.
        // Together with the synchronous token check, this checks actual cache
        // behavior without depending on a timed server response race.
        _ = try await js(blueWeb, "document.readyState")
        try check(!staleRedAppeared && isColor(cached(nextBlueURL, profile: blueProfile), red: false), "Stale Red discovery replaced Blue's origin cache")
        try check(controller.session.tabs.first { $0.id == blue.id }?.address == nextBlueURL.absoluteString, "Favicon work changed navigation metadata")
        watchedBlueProfile = nil

        let missingChangesBefore = iconChanges[missingProfile, default: 0]
        controller.select(missing.id)
        guard let missingWeb = controller.browsers[missing.id] else { throw Failure.assertion("Missing-icon page was not created") }
        try await ready(missingWeb, at: missingURL, title: "Bam Favicon Missing")
        controller.discoverFavicon(in: missingWeb)
        try await wait("missing candidate and origin fallback completed") { iconChanges[missingProfile, default: 0] > missingChangesBefore }
        controller.refresh(); controller.view.layoutSubtreeIfNeeded()
        try check(cached(missingURL, profile: missingProfile) == nil, "Missing icon borrowed another profile's cached image")
        try check(icon(in: row(missing.id)) == nil, "Missing icon failed to preserve the native fallback")
        try check(row(missing.id).map { descendants($0).compactMap { $0 as? NSImageView }.contains { $0.image != nil } } == true,
                  "Missing-icon row rendered no fallback symbol")
        try check(try await js(missingWeb, "window.faviconFixtureSentinel") as? String == "missing-document", "Failed icon loading interfered with page readiness")

        // This profile/origin has a confirmed negative cache entry. A real SVG
        // declaration must replace that miss without waiting for its TTL. The
        // fixture has no raster icon and /favicon.ico remains absent.
        var previousSVG: NSImage?
        for format in ["percent", "percent-literals", "base64", "network"] {
            let svgURL = folder.appendingPathComponent("svg.html").appending(queryItems: [URLQueryItem(name: "format", value: format)])
            controller.load(svgURL.absoluteString, in: missingWeb, id: missing.id)
            try await ready(missingWeb, at: svgURL, title: "Bam Favicon SVG")
            guard let discovery = try await js(missingWeb, BrowserController.faviconDiscoveryScript) as? [String: Any],
                  let candidates = discovery["icons"] as? [String], candidates.count == 1 else {
                throw Failure.assertion("SVG-only document did not expose exactly one declared icon")
            }
            let expectedPrefix = format == "network" ? folder.appendingPathComponent("emoji.svg").absoluteString
                : (format == "base64" ? "data:image/svg+xml;base64," : "data:image/svg+xml,")
            try check(candidates[0].hasPrefix(expectedPrefix), "Discovery lost the \(format) SVG declaration")
            if format.hasPrefix("percent") {
                let expectedSVG = format == "percent-literals"
                    ? #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="16">100% / %25</text></svg>"#
                    : #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">🪩</text></svg>"#
                try check(candidates[0].contains("%22") && !candidates[0].contains("%2522"),
                          "DOM discovery double-encoded existing SVG quote escapes")
                try check(URL(string: candidates[0])?.absoluteString == candidates[0],
                          "Discovered SVG URL was not stable across Swift URL parsing")
                try check(String(candidates[0].dropFirst(expectedPrefix.count)).removingPercentEncoding == expectedSVG,
                          "One SVG data-URL decode did not preserve its markup and literal percent text")
            }
            try await wait("decoded \(format) SVG replacing the previous cache entry") {
                guard let current = cached(svgURL, profile: missingProfile), current !== previousSVG else { return false }
                return hasVisibleArtwork(current)
            }
            previousSVG = cached(svgURL, profile: missingProfile)
            try check(previousSVG?.isTemplate == false, "SVG artwork became a template image")
            try await wait("rendered \(format) SVG sidebar icon") {
                icon(in: row(missing.id))?.image === previousSVG && hasVisibleArtwork(icon(in: row(missing.id))?.image)
            }
            try check(icon(in: row(missing.id))?.contentTintColor == nil, "Sidebar tinted the SVG artwork")
            try check(try await js(missingWeb, "window.faviconFixtureSentinel") as? String == "svg-document-\(format)",
                      "SVG icon decoding changed the source document")
            try check(try await js(missingWeb, "performance.getEntriesByType('resource').every(entry => { const url = new URL(entry.name); return url.protocol === 'data:' || (url.origin === location.origin && [new URL('emoji.svg', location.href).pathname, '/favicon.ico'].includes(url.pathname)); })") as? Bool == true,
                      "SVG fixture loaded an unrelated network resource")
        }
        try capture(controller.sidebar, named: "svg-sidebar")
        controller.openAddress(newTab: false, empty: true)
        guard let svgResults = controller.tabSearchResults else { throw Failure.assertion("SVG palette did not create results") }
        controller.view.layoutSubtreeIfNeeded()
        let svgResult = descendants(svgResults).first { $0.accessibilityLabel()?.hasPrefix("Bam Favicon SVG,") == true }
        try check(icon(in: svgResult)?.image === previousSVG && hasVisibleArtwork(icon(in: svgResult)?.image),
                  "Palette lost the decoded SVG artwork")
        let svgSelection = svgResults.selectedIndex, svgRows = svgResults.subviews.map(ObjectIdentifier.init)
        svgResults.refreshFavicons()
        try check(svgResults.selectedIndex == svgSelection && svgResults.subviews.map(ObjectIdentifier.init) == svgRows &&
                  icon(in: svgResult)?.image === previousSVG, "Refreshing SVG artwork disturbed the palette or its image")
        if let palette = controller.addressCard { try capture(palette, named: "svg-palette") }
        controller.dismissAddress()

        // Site-scoped presentation is a separate boundary: return a genuinely
        // loaded image through a recording provider rather than starting HTTPS
        // against the HTTP-only fixture server or contacting a public site.
        let scoped = TabSearchResultsView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        var siteRequests: [(URL, Bool)] = []
        scoped.siteFaviconProvider = { url, allowFetch in siteRequests.append((url, allowFetch)); return redImage }
        let engine = SiteSearchEngine(name: "Fixture", host: base.host! + (base.port.map { ":\($0)" } ?? ""), aliases: [],
                                      color: .systemRed, symbol: "magnifyingglass", searchTemplate: redURL.absoluteString + "?q=%@", suggestTemplate: nil)
        scoped.update(tabs: [], query: "local", activeID: red.id, canCreate: true, engine: engine)
        try check(siteRequests.count == 1 && siteRequests[0].1 && siteRequests[0].0.host == base.host, "Scoped search did not request its configured site icon")
        try check(isColor(icon(in: scoped)?.image, red: true), "Site-scoped result did not render supplied full-color artwork")
        let scopedRowIDs = scoped.subviews.map(ObjectIdentifier.init)
        scoped.refreshFavicons()
        try check(scoped.subviews.map(ObjectIdentifier.init) == scopedRowIDs, "Scoped icon refresh rebuilt results")
        controller.select(red.id)
        try check(controller.browsers[red.id] === redWeb && isColor(favorite(red.id)?.image, red: true), "Returning to a profile lost its page or favicon identity")
    }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        watchdog?.invalidate(); watchdog = nil; runner?.cancel(); runner = nil
        if !success, let controller {
            print("Favicon diagnostics: active=\(controller.session.active?.address ?? "nil") profiles=\(controller.session.profiles.count) browsers=\(controller.browsers.count)")
            print("Favicon geometry: root=\(controller.view.frame) sidebar=\(controller.sidebar.frame) hidden=\(controller.sidebar.isHidden) displayedWidth=\(controller.displayedWidth)")
            for table in descendants(controller.sidebar).compactMap({ $0 as? NSTableView }) {
                print("Favicon table: frame=\(table.frame) visible=\(table.visibleRect) rows=\(table.numberOfRows) realized=\(table.subviews.count)")
            }
            let identifiers = descendants(controller.sidebar).compactMap { $0.identifier?.rawValue }
            print("Favicon sidebar identifiers: \(Array(identifiers.prefix(40)))")
            do { try capture(controller.sidebar, named: "failure-sidebar") }
            catch { print("Favicon failure capture: \(error)") }
        }
        controller?.prepareToClose(persistSession: false); window?.orderOut(nil)
        print("\(success ? "PASS: Favicons — " : "FAIL: Favicons — ")\(message)")
        fflush(stdout); exit(success ? 0 : 1)
    }
}
