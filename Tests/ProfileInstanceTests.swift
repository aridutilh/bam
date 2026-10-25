import AppKit

@MainActor final class InstanceTestDelegate: NSObject, NSApplicationDelegate {
    let instance = ProfileInstance()
    var window: NSWindow!
    var activations = 0
    var checks = 0
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("bam-instance-\(UUID())")

    func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: Profile activation — \(message)\n", stderr); finish(1) }
        checks += 1
    }
    func finish(_ code: Int32) -> Never {
        try? FileManager.default.removeItem(at: base)
        exit(code)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await run() } catch { fputs("FAIL: \(error)\n", stderr); finish(1) } }
    }
    func launch(_ mode: String, directory: URL) async throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [mode, directory.path]
        try child.run()
        let deadline = Date().addingTimeInterval(8)
        while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning { child.terminate(); child.waitUntilExit(); require(false, "Child timed out") }
        return child.terminationStatus
    }
    func waitForActivation(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if activations == count && NSApp.isActive && window.isKeyWindow && !window.isMiniaturized { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        require(false, "Owner did not restore its key window (notifications: \(activations), active: \(NSApp.isActive), key: \(window.isKeyWindow))")
    }
    /// Mirrors LittleBamController.show: a URL opens its own window and
    /// makes it key, synchronously, from the owner's URL delivery.
    func openLittleBam(_ url: URL) -> NSWindow {
        let little = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 360, height: 220),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        little.title = "Little Bam fixture — \(url.host ?? "")"
        little.isReleasedWhenClosed = false
        little.makeKeyAndOrderFront(nil)
        return little
    }
    func littleBamIsFront(_ little: NSWindow?) -> Bool {
        guard let little else { return false }
        return NSApp.isActive && !NSApp.isHidden && NSApp.keyWindow === little && !window.isKeyWindow
            && NSApp.orderedWindows.first === little
    }
    /// The handed-off URL's window must become key and front, and stay so
    /// after any delayed message of that launch could have arrived.
    func requireLittleBamFront(_ little: NSWindow?, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !littleBamIsFront(little) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        require(littleBamIsFront(little), "\(message) (active: \(NSApp.isActive), key: \(NSApp.keyWindow?.title ?? "none"), front: \(NSApp.orderedWindows.first?.title ?? "none"))")
        try await Task.sleep(for: .milliseconds(700))
        require(littleBamIsFront(little), "\(message), and stays in front (key: \(NSApp.keyWindow?.title ?? "none"))")
    }
    func run() async throws {
        instance.onActivation = { [weak self] in
            guard let self else { return }
            self.activations += 1
            ProfileInstance.activate(window: self.window)
        }
        require(try instance.start(in: base, ephemeral: false), "First persistent launch owns profile")
        // A duplicate can arrive before the first launch has made its window.
        require(try await launch("--contend", directory: base) == 73, "Startup duplicate stands down")
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 180),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Bam profile activation fixture"
        let field = NSTextField(string: "Focus returns here")
        field.frame = NSRect(x: 24, y: 60, width: 300, height: 28)
        window.contentView?.addSubview(field)
        ProfileInstance.activate(window: window)
        window.makeFirstResponder(field)
        try await waitForActivation(1)
        require(window.isKeyWindow, "Activation during startup does not lose the first window")
        NSApp.hide(nil)
        try await Task.sleep(for: .milliseconds(200))
        require(try await launch("--contend", directory: base) == 73, "Second launch exits without owning profile")
        try await waitForActivation(2)
        require(!NSApp.isHidden && window.isVisible, "Hidden owner returns to foreground")
        require(window.firstResponder is NSTextView, "Text focus survives activation")
        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(300))
        require(try await launch("--contend", directory: base) == 73, "Minimized owner still owns profile")
        try await waitForActivation(3)
        require(!window.isMiniaturized && window.isKeyWindow, "Second launch restores minimized window")
        let quit = QuitCoordinator()
        var reply: Bool?
        quit.request(confirmation: { false }, save: { true }, saveFailure: { .cancel }, reply: { reply = $0 })
        let quitDeadline = Date().addingTimeInterval(2)
        while reply == nil && Date() < quitDeadline { try await Task.sleep(for: .milliseconds(10)) }
        require(reply == false, "Quit cancellation returns to the owner")
        require(try await launch("--contend", directory: base) == 73, "Canceled quit keeps profile locked")
        try await waitForActivation(4)
        require(try await launch("--ephemeral", directory: base) == 0, "Fresh preview bypasses occupied profile")
        require(try await launch("--ephemeral", directory: base.appendingPathComponent("fresh")) == 0, "Fresh preview opens without a profile")
        require(!FileManager.default.fileExists(atPath: base.appendingPathComponent("fresh").path), "Fresh preview creates no lock or directory")
        require(try await launch("--contend", directory: base.appendingPathComponent("persistent-preview")) == 0, "Persistent preview owns its separate directory")
        require(activations == 4, "Unrelated preview does not focus the persistent owner")
        let ownerURLs = ExternalURLDelivery()
        var opened: [URL] = []
        var littles: [NSWindow] = []
        instance.onOpenURLs = { urls in
            // The owner is briefly busy, forcing the duplicate to resend the
            // same request before it can receive an acknowledgment.
            Thread.sleep(forTimeInterval: 0.3)
            ownerURLs.receive(urls)
        }
        require(try await launch("--url-launch", directory: base) == 0, "Duplicate waits for acknowledged early and late URL delivery")
        require(opened.isEmpty, "Owner may accept URLs before its browser is ready")
        ownerURLs.connect { [weak self] urls in
            opened.append(contentsOf: urls)
            for url in urls { if let little = self?.openLittleBam(url) { littles.append(little) } }
        }
        try await Task.sleep(for: .milliseconds(200))
        require(opened.count == 2, "Retries must not open extra windows")
        require(opened.filter { $0.absoluteString == "https://early.invalid/launch" }.count == 1, "Early launch URL opens exactly once")
        require(opened.filter { $0.absoluteString == "https://late.invalid/launch" }.count == 1, "Late launch URL opens exactly once")
        try await requireLittleBamFront(littles.last, "URLs queued until the browser is ready open Little Bam in front")
        // Owner in the background: activation must precede URL delivery so
        // Little Bam, not the main window, ends up key and in front.
        NSApp.hide(nil)
        try await Task.sleep(for: .milliseconds(200))
        require(try await launch("--url-launch", directory: base) == 0, "A later intentional launch may open the same URLs")
        require(opened.count == 4, "Intentional repeat is not mistaken for a transport retry")
        require(opened.filter { $0.absoluteString == "https://early.invalid/launch" }.count == 2, "Same URL in distinct requests opens once per request")
        try await requireLittleBamFront(littles.last, "Early and late URLs handed to a hidden owner open Little Bam in front of the main window")
        // The same launch's focus-only messages arrive after its URL opened.
        NSApp.hide(nil)
        try await Task.sleep(for: .milliseconds(200))
        require(try await launch("--reordered-focus", directory: base) == 0, "Reordered same-launch messages are acknowledged")
        require(opened.count == 5 && opened.last?.absoluteString == "https://reordered.invalid/launch", "Reordered launch URL opens exactly once")
        try await requireLittleBamFront(littles.last, "Delayed same-launch focus messages cannot front the main window over Little Bam")
        let beforeIndependent = activations
        require(try await launch("--contend", directory: base) == 73, "Independent focus-only launch still stands down")
        try await waitForActivation(beforeIndependent + 1)
        require(window.isKeyWindow && NSApp.orderedWindows.first === window, "Independent later launch fronts the main window over Little Bam")
        instance.onOpenURLs = nil
        require(try await launch("--url-launch", directory: base) == 3, "Unacknowledged URLs fail instead of silently exiting successfully")
        print("PASS: Profile activation — \(checks) startup, focus, canceled quit, preview isolation and acknowledged exactly-once early/late URL and Little Bam front/key-window checks")
        finish(0)
    }
}

/// A duplicate whose URL request reaches the owner before its focus-only
/// messages, which then arrive (and are retried) under the same launch ID.
@MainActor func reorderedFocusLaunch(directory: URL) -> Never {
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
    deliver([Wire.launch: launch, Wire.request: UUID().uuidString, Wire.urls: ["https://reordered.invalid/launch"]])
    deliver([Wire.launch: launch, Wire.request: UUID().uuidString, Wire.urls: [String]()],
            before: { post([Wire.launch: launch]) })
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    center.removeObserver(observer)
    exit(0)
}

@main enum ProfileInstanceTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count > 2 {
            let instance = ProfileInstance()
            let urls = ExternalURLDelivery()
            if CommandLine.arguments[1] == "--reordered-focus" {
                reorderedFocusLaunch(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            if CommandLine.arguments[1] == "--url-launch" {
                urls.receive([URL(string: "https://early.invalid/launch")!])
            }
            let acquired = try instance.start(in: URL(fileURLWithPath: CommandLine.arguments[2]),
                                              ephemeral: CommandLine.arguments[1] == "--ephemeral")
            if CommandLine.arguments[1] == "--url-launch" {
                guard !acquired else { exit(2) }
                instance.beginHandoff(completed: { exit(0) }, failed: { exit(3) })
                urls.connect { instance.forwardURLs($0) }
                let late = Timer(timeInterval: 0.25, repeats: false) { _ in
                    MainActor.assumeIsolated { urls.receive([URL(string: "https://late.invalid/launch")!]) }
                }
                RunLoop.main.add(late, forMode: .common)
                RunLoop.main.run()
                exit(4)
            }
            exit(acquired ? 0 : 73)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = InstanceTestDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
