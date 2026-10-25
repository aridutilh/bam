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
        let deadline = Date().addingTimeInterval(5)
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
        print("PASS: Profile activation — \(checks) startup, hidden/minimized focus, canceled quit, duplicate exit and preview-isolation checks")
        finish(0)
    }
}

@main enum ProfileInstanceTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count > 2 {
            let instance = ProfileInstance()
            let acquired = try instance.start(in: URL(fileURLWithPath: CommandLine.arguments[2]),
                                              ephemeral: CommandLine.arguments[1] == "--ephemeral")
            exit(acquired ? 0 : 73)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = InstanceTestDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
