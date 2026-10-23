import AppKit
import WebKit

/// Exercises the actual controller's departure/arrival paths with a real player.
@MainActor final class AutomaticPiPSmokeTest {
    var controller: BrowserController!
    var window: NSWindow!
    var checks = 0
    enum Failure: Error { case assertion(String) }
    func start() {
        Task { @MainActor in
            do { try await run(); finish(true, "\(checks) checks: automatic departure/return, playback continuity, focus, paused/no-video, rapid switching, spaces, closure, preference, split fallback/return, and split-group cleanup") }
            catch { finish(false, String(describing: error)) }
        }
    }
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }; checks += 1
    }
    func pause(_ seconds: Double = 0.08) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { checks += 1; return }; await pause() }
        throw Failure.assertion("Timed out: \(message)")
    }
    func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    func run() async throws {
        controller = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/orbit-unused-auto-pip.json"), ephemeral: true)
        let video = BrowserTab(title: "Local video", address: "orbit://video", space: 0)
        let home = BrowserTab(title: "Local home", address: "orbit://newtab", space: 0)
        let otherSpace = BrowserTab(title: "Other space", address: "orbit://newtab", space: 1)
        controller.session = BrowserSession(tabs: [video, home, otherSpace], activeID: video.id)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.mediaTypesRequiringUserActionForPlayback = []
        let player = WKWebView(frame: .zero, configuration: config)
        controller.register(player, id: video.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller; window.setContentSize(NSSize(width: 1000, height: 700)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        controller.load("orbit://video", in: player, id: video.id)
        try await wait("local demo") { !player.isLoading && player.url?.lastPathComponent == "PiPDemo.html" }
        for _ in 0..<80 {
            let ready = try? await js(player, "document.querySelector('video')?.readyState >= 2") as? Bool
            if ready == true { break }; await pause()
        }
        _ = try await js(player, "window.__orbitTestVideo = document.querySelector('video'); __orbitTestVideo.muted = true; __orbitTestVideo.loop = true; __orbitTestVideo.play(); true")
        await pause(0.25)
        try require((try await js(player, "!__orbitTestVideo.paused")) as? Bool == true, "Fixture is playing before departure")
        controller.select(home.id)
        try await wait("automatic PiP") { self.controller.pictureInPicture.activeTabID == video.id }
        try require(controller.session.activeID == home.id && controller.activeWebView?.superview === controller.webHost, "Destination tab stays visible")
        try require(player.window?.isKeyWindow == false && (NSApp.keyWindow == nil || NSApp.keyWindow === window), "Automatic PiP must not take keyboard focus")
        try require(controller.pictureInPicture.owns(player), "PiP owns original WKWebView")
        let t0 = (try await js(player, "__orbitTestVideo.currentTime")) as? Double ?? -1
        await pause(0.4)
        let t1 = (try await js(player, "__orbitTestVideo.currentTime")) as? Double ?? -1
        let samePlayingVideo = (try await js(player, "!__orbitTestVideo.paused && __orbitTestVideo === document.querySelector('video')")) as? Bool == true
        try require(t1 != t0 && samePlayingVideo, "Original player continues playing")
        controller.select(video.id)
        try require(!controller.pictureInPicture.references(player) && player.superview === controller.webHost, "Selecting source returns its original video immediately")
        try await wait("outgoing Home probe clears after source return") { self.controller.pictureInPicture.referencedTabID == nil }
        await pause(0.15)
        try require((try await js(player, "document.querySelector('h1').getBoundingClientRect().height > 0 && getComputedStyle(document.querySelector('h1')).visibility === 'visible'")) as? Bool == true, "Page styling restores")
        _ = try await js(player, "__orbitTestVideo.pause(); true")
        controller.select(home.id); await pause(0.35)
        try require(controller.pictureInPicture.referencedTabID == nil, "Paused video does not float")
        controller.select(otherSpace.id); await pause(0.2)
        try require(controller.pictureInPicture.referencedTabID == nil, "No-video departure is silent")
        controller.select(video.id); _ = try await js(player, "__orbitTestVideo.play(); true"); await pause(0.15)
        controller.select(home.id); controller.select(video.id)
        await pause(0.35)
        try require(controller.pictureInPicture.referencedTabID == nil && player.superview === controller.webHost, "Rapid switch-back cancels pending request")
        controller.changeSpace(1)
        try await wait("space departure PiP") { self.controller.session.space == 1 && self.controller.pictureInPicture.activeTabID == video.id }
        controller.changeSpace(0)
        try await wait("space return") { self.controller.session.activeID == video.id && self.controller.pictureInPicture.referencedTabID == nil }
        controller.automaticallyShowsVideo = false
        controller.select(home.id); await pause(0.3)
        try require(controller.pictureInPicture.referencedTabID == nil, "Disabled auto preference is respected")
        controller.select(video.id); controller.automaticallyShowsVideo = true
        controller.select(home.id); controller.close(video.id); await pause(0.35)
        try require(controller.pictureInPicture.referencedTabID == nil && controller.browsers[video.id] == nil, "Closing source cancels pending or active panel")
        try require(controller.session.activeID == home.id, "Background video closure preserves destination selection")
        try await runSplitLifecycle(destinationID: home.id)
    }

    func runSplitLifecycle(destinationID: UUID) async throws {
        let left = BrowserTab(title: "Split without video", address: "orbit://newtab", space: 0)
        let right = BrowserTab(title: "Split playing video", address: "orbit://video", space: 0)
        controller.session.tabs.append(contentsOf: [left, right])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        let player = WKWebView(frame: .zero, configuration: config)
        controller.register(player, id: right.id)
        try require(controller.session.makeSplit(primary: left.id, secondary: right.id), "Local split group was created")
        controller.showActive()
        controller.load("orbit://video", in: player, id: right.id)
        try await wait("split local pages") {
            !player.isLoading && player.url?.lastPathComponent == "PiPDemo.html"
                && self.controller.browsers[left.id]?.isLoading == false
                && self.controller.browsers[left.id]?.url?.lastPathComponent == "Home.html"
        }
        for _ in 0..<80 {
            let ready = try? await js(player, "document.querySelector('video')?.readyState >= 2") as? Bool
            if ready == true { break }; await pause()
        }
        guard let split = controller.splitCoordinators[left.id], let leftWeb = controller.browsers[left.id],
              let leftHost = leftWeb.superview, let rightHost = player.superview,
              let destinationWeb = controller.browsers[destinationID] else { throw Failure.assertion("Split fixture did not retain both pane views and destination") }
        try require(leftHost !== rightHost && split.view.superview === controller.webHost, "Both split panes are hosted independently")
        try require((try await js(leftWeb, "document.querySelector('video') === null")) as? Bool == true, "First split candidate has no HTML5 video")
        split.setFocusedSide(.left)
        try require(controller.focusedTabID == left.id, "No-video left pane is focused before departure")
        _ = try await js(player, "window.__orbitSplitVideo = document.querySelector('video'); __orbitSplitVideo.muted = true; __orbitSplitVideo.loop = true; __orbitSplitVideo.currentTime = 1; __orbitSplitVideo.play(); true")
        await pause(0.25)
        try require((try await js(player, "!__orbitSplitVideo.paused && !__orbitSplitVideo.ended")) as? Bool == true, "Right split video was playing before departure")
        let initialTime = (try await js(player, "__orbitSplitVideo.currentTime")) as? Double ?? -1
        controller.select(destinationID)
        try await wait("split fallback from no-video left to playing right") { self.controller.pictureInPicture.activeTabID == right.id }
        try require(controller.pictureInPicture.owns(player) && controller.browsers[right.id] === player, "Split fallback floats the original right WKWebView")
        try require(controller.session.activeID == destinationID && controller.activeWebView === destinationWeb && destinationWeb.superview === controller.webHost, "Split fallback preserves destination selection and view")
        try require(controller.splitCoordinators[left.id] === split && leftWeb.superview === leftHost, "Hidden split retains its original left pane")
        await pause(0.3)
        let floatingTime = (try await js(player, "__orbitSplitVideo.currentTime")) as? Double ?? -1
        let samePlayingVideo = (try await js(player, "!__orbitSplitVideo.paused && __orbitSplitVideo === document.querySelector('video')")) as? Bool == true
        try require(floatingTime != initialTime && samePlayingVideo, "Split video continues without replacing its DOM player")

        controller.select(left.id)
        try require(!controller.pictureInPicture.references(player), "Returning to split group immediately clears original player PiP ownership")
        try require(controller.browsers[right.id] === player && player.superview === rightHost && leftWeb.superview === leftHost && split.view.superview === controller.webHost, "Returning restores both original split WKWebViews to their original panes")
        try require(controller.visibleMemberIDs == [left.id, right.id] && controller.session.activeID == left.id, "Returning keeps the split group selected")
        try await wait("outgoing Home probe clears after split return") { self.controller.pictureInPicture.referencedTabID == nil }
        await pause(0.2)
        try require((try await js(player, "__orbitSplitVideo === document.querySelector('video') && !__orbitSplitVideo.paused && getComputedStyle(document.querySelector('h1')).visibility === 'visible'")) as? Bool == true, "Returned split video retains playback and restored page styling")

        controller.select(destinationID)
        try await wait("split video floats before group close") { self.controller.pictureInPicture.activeTabID == right.id }
        controller.close(left.id)
        await pause(0.35)
        try require(controller.pictureInPicture.referencedTabID == nil && !controller.pictureInPicture.references(player), "Closing split group clears active PiP")
        try require(controller.browsers[left.id] == nil && controller.browsers[right.id] == nil && controller.observations[left.id] == nil && controller.observations[right.id] == nil, "Closing split group clears both browser and observation caches")
        try require(controller.splitCoordinators[left.id] == nil && controller.session.split(for: left.id) == nil && controller.session.split(for: right.id) == nil, "Closing split group clears coordinator and model membership")
        try require(!controller.session.tabs.contains(where: { $0.id == left.id || $0.id == right.id }) && leftWeb.superview == nil && player.superview == nil, "Closed split members leave session and all view hosts")
        try require(controller.session.activeID == destinationID && controller.browsers[destinationID] === destinationWeb && controller.activeWebView === destinationWeb && destinationWeb.superview === controller.webHost, "Background split-group close preserves the destination and original WKWebView")
    }
    func finish(_ success: Bool, _ detail: String) {
        controller?.prepareToClose()
        print("\(success ? "PASS" : "FAIL"): Automatic PiP — \(detail)"); fflush(stdout); exit(success ? 0 : 1)
    }
}
