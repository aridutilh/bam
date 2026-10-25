import AppKit

/// Profile ownership, duplicate-launch focus and URL handoff, run inside the
/// app bundle under test (`--profile-instance-test`). Duplicate launches are
/// the same executable in a child mode that never creates NSApplication, so
/// every process shares the tested bundle identity. The profile is a
/// disposable temporary directory; no installed profile is opened or locked.
/// The owner mirrors AppDelegate's wiring with a fresh browser controller, so
/// URL handoffs open real Little Bam windows whose key/front state is checked.
@MainActor final class ProfileInstanceSmokeTest {
    static let childFlag = "--profile-instance-child"
    private let instance = ProfileInstance()
    private let externalURLs = ExternalURLDelivery()
    private var controller: BrowserController?
    private var window: NSWindow?
    private var littles: [NSWindow] = []
    private var opened: [URL] = []
    private var activations = 0
    private var checks = 0
    private var watchdog: Timer?
    private var finished = false
    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("bam-profile-instance-\(UUID().uuidString)", isDirectory: true)
    enum Failure: Error { case assertion(String) }

    func start() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        Task { @MainActor in
            do {
                try await run()
                finish(true, "\(checks) startup, focus, canceled quit, preview isolation, acknowledged exactly-once early/late URL and Little Bam key/front-window checks")
            } catch { finish(false, String(describing: error)) }
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
        checks += 1
    }
    private func launch(_ mode: String, directory: URL, urls: [URL] = []) async throws -> Int32 {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = [Self.childFlag, mode, directory.path] + urls.map(\.absoluteString)
        try child.run()
        let deadline = Date().addingTimeInterval(8)
        while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning { child.terminate(); child.waitUntilExit(); throw Failure.assertion("\(mode) child timed out") }
        return child.terminationStatus
    }
    private func waitForActivation(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if activations == count && NSApp.isActive && window?.isKeyWindow == true && window?.isMiniaturized == false { checks += 1; return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.assertion("Owner did not restore its key window (notifications: \(activations), active: \(NSApp.isActive), key: \(window?.isKeyWindow == true))")
    }
    private func littleBamIsFront(_ little: NSWindow?) -> Bool {
        guard let little, let window else { return false }
        return NSApp.isActive && !NSApp.isHidden && NSApp.keyWindow === little && !window.isKeyWindow
            && NSApp.orderedWindows.first === little
    }
    /// The handed-off URL's Little Bam must become key and front, and stay so
    /// after any delayed message from that launch could have arrived.
    private func requireLittleBamFront(_ little: NSWindow?, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !littleBamIsFront(little) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let state = "active: \(NSApp.isActive), key: \(NSApp.keyWindow?.title ?? "none"), front: \(NSApp.orderedWindows.first?.title ?? "none")"
        try require(littleBamIsFront(little), "\(message) (\(state))")
        try await Task.sleep(for: .milliseconds(700))
        try require(littleBamIsFront(little), "\(message), and stays in front (key: \(NSApp.keyWindow?.title ?? "none"))")
    }
    private func hideOwner() async throws {
        NSApp.hide(nil)
        try await Task.sleep(for: .milliseconds(200))
        try require(NSApp.isHidden, "Owner hides before a background handoff")
    }

    private func run() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"], let fixture = URLInput.directURL(raw) else {
            throw Failure.assertion("Set BAM_TEST_URL to a local fixture")
        }
        func handoff(_ label: String) -> URL {
            var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "handoff", value: label)]
            return components.url!
        }
        let early = handoff("early"), late = handoff("late"), reordered = handoff("reordered")

        // Same wiring as AppDelegate: front the main window; URLs go through
        // the delivery queue until the browser is ready.
        instance.onActivation = { [weak self] in
            guard let self else { return }
            self.activations += 1
            ProfileInstance.activate(window: self.window)
        }
        try require(try instance.start(in: base, ephemeral: false), "First persistent launch owns profile")
        // A duplicate can arrive before the first launch has made its window.
        try require(try await launch("--contend", directory: base) == 73, "Startup duplicate stands down")
        let controller = BrowserController(sessionURL: base.appendingPathComponent("unused-session.json"), ephemeral: true)
        let tab = BrowserTab(title: "Fixture", address: fixture.absoluteString, space: 0)
        controller.session = BrowserSession(tabs: [tab], activeID: tab.id) // Loopback only.
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bam profile activation fixture"
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 680))
        self.window = window
        ProfileInstance.activate(window: window)
        try await waitForActivation(1)
        try require(window.isKeyWindow, "Activation during startup does not lose the first window")
        let pageDeadline = Date().addingTimeInterval(10)
        while controller.activeWebView.map({ $0.isLoading || $0.url == nil }) ?? true, Date() < pageDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(controller.activeWebView?.isLoading == false, "Owner browser finishes loading its loopback page")
        let field = NSTextField(string: "Focus returns here")
        field.frame = NSRect(x: 24, y: 24, width: 300, height: 28)
        window.contentView?.addSubview(field)
        try require(window.makeFirstResponder(field), "Fixture text field takes focus")
        let editor = window.firstResponder
        try require(editor is NSTextView, "Fixture text field is being edited")

        try await hideOwner()
        try require(try await launch("--contend", directory: base) == 73, "Second launch exits without owning profile")
        try await waitForActivation(2)
        try require(!NSApp.isHidden && window.isVisible, "Hidden owner returns to foreground")
        try require(window.firstResponder === editor, "Text focus survives activation")
        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(300))
        try require(try await launch("--contend", directory: base) == 73, "Minimized owner still owns profile")
        try await waitForActivation(3)
        try require(!window.isMiniaturized && window.isKeyWindow, "Second launch restores minimized window")
        let quit = QuitCoordinator()
        var reply: Bool?
        quit.request(confirmation: { false }, save: { true }, saveFailure: { .cancel }, reply: { reply = $0 })
        let quitDeadline = Date().addingTimeInterval(2)
        while reply == nil && Date() < quitDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(reply == false, "Quit cancellation returns to the owner")
        try require(try await launch("--contend", directory: base) == 73, "Canceled quit keeps profile locked")
        try await waitForActivation(4)
        field.removeFromSuperview()
        try require(try await launch("--ephemeral", directory: base) == 0, "Fresh preview bypasses occupied profile")
        let fresh = base.appendingPathComponent("fresh")
        try require(try await launch("--ephemeral", directory: fresh) == 0, "Fresh preview opens without a profile")
        try require(!FileManager.default.fileExists(atPath: fresh.path), "Fresh preview creates no lock or directory")
        try require(try await launch("--contend", directory: base.appendingPathComponent("persistent-preview")) == 0,
                    "Persistent preview owns its separate directory")
        try require(activations == 4, "Unrelated preview does not focus the persistent owner")

        instance.onOpenURLs = { [weak self] urls in
            // The owner is briefly busy, forcing the duplicate to resend the
            // same request before it can receive an acknowledgment.
            Thread.sleep(forTimeInterval: 0.3)
            self?.externalURLs.receive(urls.filter { URLInput.directURL($0.absoluteString) != nil })
        }
        try require(try await launch("--url-launch", directory: base, urls: [early, late]) == 0,
                    "Duplicate waits for acknowledged early and late URL delivery")
        try require(opened.isEmpty, "Owner may accept URLs before its browser is ready")
        externalURLs.connect { [weak self] urls in
            guard let self, let controller = self.controller else { return }
            self.opened.append(contentsOf: urls)
            for url in urls {
                let before = Set(controller.littleWindows.keys)
                controller.openLittleOrbit(url: url)
                if let added = controller.littleWindows.first(where: { !before.contains($0.key) })?.value.window {
                    self.littles.append(added)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        try require(opened.count == 2 && littles.count == 2, "Retries must not open extra Little Bam windows")
        try require(opened.filter { $0 == early }.count == 1, "Early launch URL opens exactly once")
        try require(opened.filter { $0 == late }.count == 1, "Late launch URL opens exactly once")
        try await requireLittleBamFront(littles.last, "URLs queued until the browser is ready open Little Bam in front")

        // Owner in the background: activation must precede URL delivery so
        // Little Bam, not the main window, ends up key and in front.
        try await hideOwner()
        try require(try await launch("--url-launch", directory: base, urls: [early, late]) == 0,
                    "A later intentional launch may open the same URLs")
        try require(opened.count == 4 && littles.count == 4, "Intentional repeat is not mistaken for a transport retry")
        try require(opened.filter { $0 == early }.count == 2, "Same URL in distinct requests opens once per request")
        try await requireLittleBamFront(littles.last, "Early and late URLs handed to a hidden owner open Little Bam in front of the main window")

        // The same launch's focus-only messages arrive after its URL opened.
        try await hideOwner()
        try require(try await launch("--reordered-focus", directory: base, urls: [reordered]) == 0,
                    "Reordered same-launch messages are acknowledged")
        try require(opened.count == 5 && opened.last == reordered && littles.count == 5, "Reordered launch URL opens exactly once")
        try await requireLittleBamFront(littles.last, "Delayed same-launch focus messages cannot front the main window over Little Bam")
        let beforeIndependent = activations
        try require(try await launch("--contend", directory: base) == 73, "Independent focus-only launch still stands down")
        try await waitForActivation(beforeIndependent + 1)
        try require(NSApp.orderedWindows.first === window, "Independent later launch fronts the main window over Little Bam")

        instance.onOpenURLs = nil
        try require(try await launch("--url-launch", directory: base, urls: [early, late]) == 3,
                    "Unacknowledged URLs fail instead of silently exiting successfully")
    }

    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        watchdog?.invalidate(); watchdog = nil
        for little in littles { little.close() }
        controller?.prepareToClose(); window?.orderOut(nil)
        try? FileManager.default.removeItem(at: base)
        print("\(success ? "PASS" : "FAIL"): Profile activation — \(message)"); fflush(stdout)
        exit(success ? 0 : 1)
    }

    // MARK: Duplicate launches

    /// Call first in `main`, before NSApplication exists. Returns only when
    /// this process is not a duplicate-launch child of the fixture.
    static func runChildIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count > 3, arguments[1] == childFlag else { return }
        let mode = arguments[2], directory = URL(fileURLWithPath: arguments[3])
        let urls = arguments.dropFirst(4).compactMap(URL.init(string:))
        if mode == "--reordered-focus" { reorderedFocusLaunch(directory: directory, urls: urls) }
        let instance = ProfileInstance()
        let delivery = ExternalURLDelivery()
        // Like Apple events delivered before startup decides the owner.
        if mode == "--url-launch", let first = urls.first { delivery.receive([first]) }
        let acquired: Bool
        do { acquired = try instance.start(in: directory, ephemeral: mode == "--ephemeral") }
        catch { fputs("FAIL: Profile activation child — \(error)\n", stderr); exit(5) }
        guard mode == "--url-launch" else { exit(acquired ? 0 : 73) }
        guard !acquired else { exit(2) }
        instance.beginHandoff(completed: { exit(0) }, failed: { exit(3) })
        delivery.connect { instance.forwardURLs($0) }
        // Like a URL-open event after startup.
        let late = Timer(timeInterval: 0.25, repeats: false) { _ in
            MainActor.assumeIsolated { delivery.receive(Array(urls.dropFirst())) }
        }
        RunLoop.main.add(late, forMode: .common)
        RunLoop.main.run()
        exit(4)
    }

    /// A duplicate whose URL request reaches the owner before its focus-only
    /// messages, which then arrive (and are retried) under the same launch ID.
    private static func reorderedFocusLaunch(directory: URL, urls: [URL]) -> Never {
        typealias Wire = ProfileInstance.Wire
        final class Acknowledged: @unchecked Sendable { var ids: Set<String> = [] } // Main run loop only.
        let identity = ProfileLock.identity(for: directory).path
        let launch = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        let acknowledged = Acknowledged()
        let observer = center.addObserver(forName: Wire.acknowledgment, object: identity, queue: nil) { notification in
            if let id = notification.userInfo?[Wire.request] as? String { acknowledged.ids.insert(id) }
        }
        func post(_ info: [String: Any]) {
            center.postNotificationName(Wire.activation, object: identity, userInfo: info, deliverImmediately: true)
        }
        func deliver(_ info: [String: Any], before: () -> Void = {}) {
            let id = info[Wire.request] as! String
            let deadline = Date().addingTimeInterval(5)
            before()
            while !acknowledged.ids.contains(id) {
                guard Date() < deadline else { exit(3) }
                post(info)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        deliver([Wire.launch: launch, Wire.request: UUID().uuidString, Wire.urls: urls.map(\.absoluteString)])
        deliver([Wire.launch: launch, Wire.request: UUID().uuidString, Wire.urls: [String]()],
                before: { post([Wire.launch: launch]) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        center.removeObserver(observer)
        exit(0)
    }
}
