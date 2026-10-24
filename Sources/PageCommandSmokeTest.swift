import AppKit
import WebKit

@MainActor extension FeatureSmokeTest {
    /// Uses its own browser and pasteboard; the user's clipboard is never read or changed.
    func runPageCommands() async throws {
        guard let raw = ProcessInfo.processInfo.environment["ORBIT_TEST_URL"],
              let fixtureURL = URLInput.directURL(raw) else {
            throw Failure.assertion("Page commands need the local HTTP fixture")
        }
        func url(_ role: String) -> URL {
            var components = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "ark_page_command", value: role)]
            return components.url!
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Ark-page-commands-\(UUID().uuidString)"))
        let commands = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/ark-unused-page-commands.json"), ephemeral: true)
        commands.pageCommandPasteboard = pasteboard
        commands.automaticallyShowsVideo = false
        let mainTab = BrowserTab(title: "Page commands", address: url("main").absoluteString, space: 0)
        commands.session = BrowserSession(tabs: [mainTab], activeID: mainTab.id)
        let commandWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        commandWindow.isReleasedWhenClosed = false
        commandWindow.title = "Ark page command fixture"
        commandWindow.contentViewController = commands
        commandWindow.setContentSize(NSSize(width: 1120, height: 720))
        defer {
            commands.prepareToClose()
            commandWindow.close()
            pasteboard.releaseGlobally()
        }
        try await establishKeyWindow(commandWindow, label: "page command browser")
        guard let main = commands.activeWebView else { throw Failure.assertion("Page command main page exists") }
        try await wait("page command main fixture") { !main.isLoading && main.title == "Orbit Feature Fixture" }

        func seed(_ web: WKWebView, _ marker: String) async throws {
            _ = try await js(web, "window.__arkPageCommandSentinel='\(marker)'; true")
        }
        func retained(_ web: WKWebView, _ marker: String) async throws -> Bool {
            (try await js(web, "window.__arkPageCommandSentinel==='\(marker)'")) as? Bool == true
        }
        func freshDocument(_ web: WKWebView, _ label: String) async throws {
            for _ in 0..<100 {
                if !web.isLoading, web.title == "Orbit Feature Fixture",
                   (try? await js(web, "typeof window.__arkPageCommandSentinel==='undefined'")) as? Bool == true {
                    checks += 1
                    return
                }
                await pause()
            }
            throw Failure.assertion("Hard refresh did not replace \(label)'s document")
        }
        func feedbackFits(_ message: String) throws {
            let overlay = commands.pageFeedback.view
            overlay.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            guard let label = descendants(overlay).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.stringValue == message }),
                  let font = label.font, let pill = label.superview else {
                throw Failure.assertion("Feedback has no rendered label for \(message)")
            }
            let glyphWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width)
            // Leave room for the text cell's drawing insets rather than merely
            // fitting the glyph advance. This is independent of the pill's layout constants.
            try check(label.frame.width >= glyphWidth + 8,
                      "Feedback clips \(message): label width \(label.frame.width), measured glyph width \(glyphWidth)")
            try check(pill.bounds.contains(label.frame) && !label.isHiddenOrHasHiddenAncestor,
                      "Feedback label for \(message) is hidden or extends outside its pill")
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: overlay.superview)
            try check(overlay.hitTest(point) == nil, "Feedback intercepts page clicks over \(message)")
        }
        func copy(_ web: WKWebView, label: String, window: NSWindow) throws {
            let responder = window.firstResponder
            pasteboard.clearContents()
            pasteboard.setString("unmodified", forType: .string)
            commands.pageFeedback.hide()
            commands.copyCurrentURL(nil)
            try check(pasteboard.string(forType: .string) == web.url?.absoluteString,
                      "Copy URL did not use \(label)'s live address")
            try check(commands.pageFeedback.isVisible && commands.pageFeedback.message == "Page copied"
                        && commands.pageFeedback.view.window === window,
                      "Copy URL feedback was missing or belonged to another window for \(label)")
            try check(window.firstResponder === responder, "Copy URL feedback stole \(label)'s responder")
            try feedbackFits("Page copied")
        }
        func hardRefresh(_ web: WKWebView, label: String, window: NSWindow) async throws {
            try await seed(web, "refresh")
            commands.pageFeedback.hide()
            commands.hardReload(nil)
            try check(commands.pageFeedback.isVisible && commands.pageFeedback.message == "Hard refreshing…"
                        && commands.pageFeedback.view.window === window,
                      "Accepted hard refresh did not show feedback in \(label)'s window")
            try feedbackFits("Hard refreshing…")
            try await freshDocument(web, label)
        }

        // A same-document URL change must be copied instead of stale saved-tab metadata.
        let pushed = try await js(main, "history.pushState(null,'','?ark_page_command=main-live'); location.href") as! String
        try await wait("main live URL") { main.url?.absoluteString == pushed }
        try copy(main, label: "main", window: commandWindow)
        try await hardRefresh(main, label: "main", window: commandWindow)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = main.configuration.websiteDataStore
        let right = PageCommandRecordingWebView(frame: .zero, configuration: configuration)
        right.load(URLRequest(url: url("right")))
        commands.openSplit(adopting: right, beside: mainTab.id)
        try await wait("right split command fixture") { !right.isLoading && right.title == "Orbit Feature Fixture" }
        guard let split = commands.splitCoordinators[mainTab.id] else { throw Failure.assertion("Page command split created") }
        commandWindow.makeFirstResponder(main); split.setFocusedSide(.left)
        try await seed(right, "untouched-right")
        try copy(main, label: "left split", window: commandWindow)
        try await hardRefresh(main, label: "left split", window: commandWindow)
        try check(try await retained(right, "untouched-right"), "Refreshing left split replaced the right page")
        commandWindow.makeFirstResponder(right); split.setFocusedSide(.right)
        try await seed(main, "untouched-left")
        try copy(right, label: "right split", window: commandWindow)
        try await hardRefresh(right, label: "right split", window: commandWindow)
        try check(right.originReloads == 1 && right.normalReloads == 0,
                  "Hard refresh did not invoke reloadFromOrigin exactly once on the focused split")
        try check(try await retained(main, "untouched-left"), "Refreshing right split replaced the left page")

        // The hard-refresh command must not inherit ordinary Reload/Stop's loading branch.
        try await seed(right, "refresh")
        let beforeLoadingRefresh = right.originReloads
        let beforeStops = right.stops
        right.reportsLoading = true
        commands.hardReload(nil)
        right.reportsLoading = false
        try check(right.originReloads == beforeLoadingRefresh + 1 && right.stops == beforeStops,
                  "Hard refresh stopped an in-flight page instead of requesting origin revalidation")
        try await freshDocument(right, "loading split")
        commands.pageFeedback.hide()
        right.acceptsOriginReload = false
        let beforeRejectedRefresh = right.originReloads
        commands.hardReload(nil)
        right.acceptsOriginReload = true
        try check(right.originReloads == beforeRejectedRefresh + 1 && !commands.pageFeedback.isVisible,
                  "Rejected hard-refresh navigation reported a false success")

        commands.openPeek(url("peek"))
        guard let peek = commands.peeks[mainTab.id], let preview = peek.webView else {
            throw Failure.assertion("Page command Peek created")
        }
        try await wait("Peek command fixture") { !preview.isLoading && preview.title == "Orbit Feature Fixture" }
        try await seed(main, "behind-peek-left"); try await seed(right, "behind-peek-right")
        let beforePeekRefresh = right.originReloads
        try copy(preview, label: "Peek", window: commandWindow)
        try await hardRefresh(preview, label: "Peek", window: commandWindow)
        try check(try await retained(main, "behind-peek-left"), "Refreshing Peek reloaded its left source pane")
        try check(try await retained(right, "behind-peek-right"), "Refreshing Peek reloaded its right source pane")
        try check(right.originReloads == beforePeekRefresh, "Peek hard refresh reached the focused source split")
        peek.dismiss()

        commands.openLittleOrbit(url: url("little"))
        guard let little = commands.littleWindows.values.first, let littleWindow = little.window,
              let littleWeb = little.webView else { throw Failure.assertion("Page command Little Ark created") }
        try await establishKeyWindow(littleWindow, label: "Little Ark page commands")
        try await wait("Little Ark command fixture") { !littleWeb.isLoading && littleWeb.title == "Orbit Feature Fixture" }
        try copy(littleWeb, label: "Little Ark", window: littleWindow)
        try await hardRefresh(littleWeb, label: "Little Ark", window: littleWindow)
        try check(try await retained(main, "behind-peek-left"), "Little Ark refresh changed the main left pane")
        try check(try await retained(right, "behind-peek-right"), "Little Ark refresh changed the main right pane")

        let utility = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 360, height: 180),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        utility.title = "Ark page command utility fixture"
        utility.isReleasedWhenClosed = false
        defer { utility.close() }
        try await establishKeyWindow(utility, label: "utility before page commands")
        try await seed(littleWeb, "behind-utility")
        let beforeUtilityRefresh = right.originReloads
        pasteboard.clearContents(); pasteboard.setString("utility-must-not-copy", forType: .string)
        commands.pageFeedback.hide()
        commands.copyCurrentURL(nil); commands.hardReload(nil)
        await pause()
        try check(pasteboard.string(forType: .string) == "utility-must-not-copy" && !commands.pageFeedback.isVisible,
                  "A key utility window copied a background URL or displayed page feedback")
        try check(try await retained(littleWeb, "behind-utility"), "A key utility window refreshed background Little Ark")
        try check(try await retained(main, "behind-peek-left"), "A key utility window refreshed the background main page")
        try check(try await retained(right, "behind-peek-right"), "A key utility window refreshed the background split page")
        try check(right.originReloads == beforeUtilityRefresh, "A key utility window dispatched an origin reload")
        utility.close()
        little.close()

        try await establishKeyWindow(commandWindow, label: "empty-page command browser")
        let empty = WKWebView(frame: .zero, configuration: configuration)
        _ = commands.adoptWebView(empty)
        try await wait("empty command page") { !empty.isLoading }
        pasteboard.clearContents(); pasteboard.setString("empty-must-not-copy", forType: .string)
        commands.pageFeedback.hide()
        commands.copyCurrentURL(nil)
        try check(pasteboard.string(forType: .string) == "empty-must-not-copy" && !commands.pageFeedback.isVisible,
                  "An internal empty page copied a nonexistent HTTP address or reported success")
    }
}

/// Records dispatch while retaining real WebKit navigation for document checks.
@MainActor private final class PageCommandRecordingWebView: WKWebView {
    var originReloads = 0
    var normalReloads = 0
    var stops = 0
    var reportsLoading = false
    var acceptsOriginReload = true
    override var isLoading: Bool { reportsLoading || super.isLoading }
    override func reloadFromOrigin() -> WKNavigation? {
        originReloads += 1
        return acceptsOriginReload ? super.reloadFromOrigin() : nil
    }
    override func reload() -> WKNavigation? { normalReloads += 1; return super.reload() }
    override func stopLoading() { stops += 1; super.stopLoading() }
}
