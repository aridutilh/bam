import AppKit
import WebKit

/// `--window-test`: two normal windows over one session, with a real session file in a temporary
/// folder and nonpersistent website data. Checks the shared tabs, per-window selection, moving a
/// live page between windows, closing tabs and windows, and that saving and reloading keeps every
/// tab exactly once with the second window's selection.
@MainActor final class WindowSmokeTest {
    var checks = 0
    var primary: BrowserController?
    var primaryWindow: NSWindow?
    var secondary: SecondaryWindowController?
    var directory: URL?
    enum Failure: Error { case assertion(String) }
    func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure.assertion(message) }; checks += 1 }
    func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { checks += 1; return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw Failure.assertion("Timeout: \(message)")
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    func start() {
        Task { @MainActor in
            do { try await run(); finish(true, "\(checks) checks: shared tabs with per-window Space and selection, live page moved between windows with a stand-in left behind, closes in either window, window close, saved and reloaded session with every tab once, restored window state, Little Bam target") }
            catch { finish(false, String(describing: error)) }
        }
    }

    func makePrimary(_ url: URL) throws -> (BrowserController, NSWindow) {
        let stores = try WebsiteProfileStore(isolated: [:])
        let controller = BrowserController(sessionURL: url, ephemeral: false, profileStores: stores)
        controller.automaticallyShowsVideo = false
        let window = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        return (controller, window)
    }

    func run() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"], let base = URL(string: raw)?.deletingLastPathComponent() else { throw Failure.assertion("Missing local fixture URL") }
        let page = { (name: String) in base.appendingPathComponent("sleep-static.html").absoluteString + "?window=\(name)" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-window-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        let sessionURL = folder.appendingPathComponent("session.json")
        let a = BrowserTab(title: "A", address: page("a"), space: 0), b = BrowserTab(title: "B", address: page("b"), space: 0)
        let c = BrowserTab(title: "C", address: page("c"), space: 0), d = BrowserTab(title: "D", address: page("d"), space: 1)
        try SessionFile.save(BrowserSession(tabs: [a, b, c, d], activeID: a.id, lastSelectedTabIDsBySpace: [0: a.id, 1: d.id]), to: sessionURL)

        let (p, pWindow) = try makePrimary(sessionURL)
        primary = p; primaryWindow = pWindow
        let group = BrowserWindowGroup(); group.add(p)
        NSApp.activate(ignoringOtherApps: true)
        pWindow.makeKeyAndOrderFront(nil)
        try await wait("first page") { p.browsers[a.id]?.isLoading == false }

        // A second window opens on the same Space with its own new tab; the main window's selection is untouched.
        let s = SecondaryWindowController(primary: p, group: group, state: nil, like: p, frame: pWindow.frame)
        secondary = s
        let sc = s.controller
        s.show(openingPalette: false)
        try await settle()
        try check(p.session.tabs.count == 5 && sc.session.tabs.count == 5, "New window's tab is not in the shared session once")
        try check(sc.session.space == 0 && sc.session.active?.isHome == true, "New window doesn't open a new tab on the same Space")
        try check(p.session.activeID == a.id, "Opening a window changed the main window's selection")
        try check(Set(p.session.tabs.map(\.id)) == Set(sc.session.tabs.map(\.id)), "Windows disagree on the tabs")

        // Per-window Space: switching Space in the second window leaves the main window where it is.
        sc.changeSpace(1)
        try await settle()
        try check(sc.session.space == 1 && sc.session.activeID == d.id, "Second window didn't switch Space")
        try check(p.session.space == 0 && p.session.activeID == a.id, "Main window followed the other window's Space")
        sc.changeSpace(0)

        // The main window shows B; then the second window (in front) chooses B: the live page moves.
        pWindow.makeKeyAndOrderFront(nil)
        try await wait("main window key") { pWindow.isKeyWindow }
        p.select(b.id)
        try await wait("B loaded in main window") { p.browsers[b.id]?.isLoading == false }
        let pageB = p.browsers[b.id]
        _ = try await pageB?.evaluateJavaScript("window.windowMarker = 'kept'; true")
        NSApp.activate(ignoringOtherApps: true); s.window.makeKeyAndOrderFront(nil)
        try await wait("second window key") { s.window.isKeyWindow }
        sc.select(b.id)
        try check(sc.browsers[b.id] != nil && sc.browsers[b.id] === pageB, "Choosing B in the second window didn't move its live page")
        try check(p.browsers[b.id] == nil, "B's page is still registered in the main window")
        let marker = try await sc.browsers[b.id]?.evaluateJavaScript("window.windowMarker") as? String
        try check(marker == "kept", "Moved page lost its document state")
        try await wait("stand-in in main window") { p.webHost.subviews.contains { $0 is PageElsewhereView } }
        try check(p.session.activeID == b.id, "Main window's selection changed when its page moved")

        // Closing a tab in one window removes it everywhere.
        p.select(c.id)   // main window is not key: C is new there, so it loads there
        try await wait("C loaded in main window") { p.browsers[c.id] != nil }
        sc.close(c.id)
        try await settle()
        try check(!p.session.tabs.contains { $0.id == c.id } && !sc.session.tabs.contains { $0.id == c.id }, "Tab closed in one window survives in another")
        try check(p.browsers[c.id] == nil, "Main window kept a page for a tab closed elsewhere")
        try check(p.session.tabs.contains { $0.id == p.session.activeID }, "Main window's selection points at a closed tab")

        // A tab added in the main window appears in the second window without changing its selection.
        let selectedThere = sc.session.activeID
        let e = p.session.add(address: page("e"))
        try await settle()
        try check(sc.session.tabs.contains { $0.id == e }, "New tab didn't reach the second window")
        try check(sc.session.activeID == selectedThere, "Second window's selection followed the main window")

        // Little Bam's Open in Space goes to the frontmost normal window.
        BrowserController.frontmostNormalBrowser = { sc }
        try check(p.promotionTarget === sc, "Little Bam would open in the main window instead of the frontmost one")
        BrowserController.frontmostNormalBrowser = nil

        // Save, reload: every tab exactly once, and the second window comes back with its selection.
        let state = s.state
        let stateURL = folder.appendingPathComponent("windows.json")
        BrowserWindowState.save([state], to: stateURL)
        try check(BrowserWindowState.load(stateURL) == [state], "Window state didn't round-trip")
        let flushed = await p.flushSessionForTermination()
        try check(flushed, "Session didn't flush")
        let reloaded = SessionFile.load(sessionURL)
        let reloadedIDs = reloaded.tabs.map(\.id)
        try check(Set(reloadedIDs).count == reloadedIDs.count, "A tab was saved twice")
        for id in [a.id, b.id, d.id, e] { try check(reloadedIDs.contains(id), "A tab was lost on save") }
        try check(!reloadedIDs.contains(c.id), "A closed tab came back")
        try check(reloaded.activeID == p.session.activeID, "Main window's selection wasn't saved")

        // Closing the second window keeps its tabs and gives B's page back to the main window.
        let tabsBefore = Set(p.session.tabs.map(\.id))
        s.window.close()
        try await settle()
        try check(sc.isShuttingDown && !group.browsers.contains { $0 === sc }, "Closed window is still in the group")
        try check(Set(p.session.tabs.map(\.id)) == tabsBefore, "Closing a window changed the tabs")
        pWindow.makeKeyAndOrderFront(nil)
        try await wait("main window key again") { pWindow.isKeyWindow }
        p.select(b.id)
        try await wait("B shown in main window again") { p.browsers[b.id] != nil && !p.webHost.subviews.contains { $0 is PageElsewhereView } }

        // A relaunch: a new main browser from the file, and the second window from its saved state.
        p.prepareToClose(); pWindow.orderOut(nil)
        let (p2, p2Window) = try makePrimary(sessionURL)
        primary = p2; primaryWindow = p2Window
        let group2 = BrowserWindowGroup(); group2.add(p2)
        p2Window.makeKeyAndOrderFront(nil)
        let restored = SecondaryWindowController(primary: p2, group: group2, state: BrowserWindowState.load(stateURL).first, like: nil, frame: nil)
        secondary = restored
        restored.show(openingPalette: false)
        try await settle()
        let ids = p2.session.tabs.map(\.id)
        try check(Set(ids).count == ids.count && Set(ids) == Set(reloadedIDs), "Relaunch with a second window changed the tabs")
        try check(restored.controller.session.activeID == state.activeID || !reloadedIDs.contains(state.activeID), "Second window didn't restore its selection")
        try check(restored.controller.session.space == state.space, "Second window didn't restore its Space")
        restored.window.close()
    }

    func finish(_ success: Bool, _ message: String) {
        print("\(success ? "PASS: Windows — " : "FAIL: Windows — ")\(message)")
        secondary?.window.close()
        primary?.prepareToClose(); primaryWindow?.orderOut(nil)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        fflush(stdout); exit(success ? 0 : 1)
    }
}
