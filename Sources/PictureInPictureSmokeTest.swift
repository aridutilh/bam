import AppKit
import WebKit

/// Uses only bundled pages, a bundled video, and a nonpersistent WebKit store.
@MainActor final class PictureInPictureSmokeTest: NSObject, WKNavigationDelegate {
    private enum Stage { case loadingVideo, cancelling, opening, playing, returning, restored, automaticPaused, automaticCancelled, automaticOpening, automaticPlaying, automaticReturning, automaticRestored, loadingEmpty, automaticEmpty, empty, finished }
    private var stage = Stage.loadingVideo
    private let coordinator = PictureInPictureCoordinator()
    private let tabID = UUID()
    private let resourcesURL: URL?
    private var web: WKWebView!
    private var window: NSWindow!
    private let host = NSView()
    private var timeout: Timer?
    private var baselineTime = 0.0
    private var panelTime = 0.0
    private var restoreCount = 0
    private var cycle = 0
    private var automaticCompletions: [String: [Bool]] = [:]
    private let focusField = NSTextField(string: "Typing continues in the selected tab")
    private weak var expectedKeyWindow: NSWindow?
    private weak var expectedFirstResponder: NSResponder?

    init(resourcesURL: URL? = nil) { self.resourcesURL = resourcesURL; super.init() }

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Ark — local PiP smoke test"
        window.contentView = host
        host.addSubview(web); web.frame = host.bounds
        window.makeKeyAndOrderFront(nil)
        coordinator.onChange = { [weak self] in self?.pictureInPictureChanged() }
        timeout = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.finish(false, "Timed out") }
        }
        loadFixture("PiPDemo")
    }

    private func loadFixture(_ name: String) {
        let file = resourcesURL?.appendingPathComponent(name + ".html") ?? Bundle.main.url(forResource: name, withExtension: "html")
        guard let file, FileManager.default.fileExists(atPath: file.path) else { finish(false, "Missing \(name) fixture"); return }
        web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch stage {
        case .loadingVideo:
            web.callAsyncJavaScript("""
                const video = document.querySelector('video');
                if (!video) throw new Error('Missing video');
                video.muted = true; video.loop = true; video.controls = false;
                video.setAttribute('style', 'border-radius: 11px;');
                document.body.style.padding = '7px';
                window.__orbitSmokeVideo = video;
                window.__orbitSmokeStyles = [video.getAttribute('style'), document.body.getAttribute('style'), document.documentElement.getAttribute('style')];
                await video.play();
                return true;
                """, arguments: [:], in: nil, in: .page) { [weak self] result in
                    guard let self else { return }
                    if case .failure(let error) = result { self.finish(false, "Playback could not start: \(error.localizedDescription)"); return }
                    self.after(0.6) { self.readTime { time in self.baselineTime = time; self.checkPendingCancellation() } }
                }
        case .loadingEmpty:
            stage = .automaticEmpty
            coordinator.automaticallyPresentIfPlaying(web: web, tabID: tabID, shouldPresent: { true }, restore: { [weak self] _ in self?.finish(false, "Automatic no-video request rehosted a page") }, completion: { [weak self] result in self?.recordCompletion("empty", result) })
            after(0.35) {
                guard self.coordinator.referencedTabID == nil, !self.coordinator.references(self.web), self.web.superview === self.host else { self.finish(false, "Automatic no-video request did not quietly clear"); return }
                self.stage = .empty
                self.coordinator.toggle(web: self.web, tabID: self.tabID, restore: { _ in }, report: { [weak self] message in
                    guard let self else { return }
                    let passed = message.hasPrefix("No HTML5 video found.") && self.coordinator.activeTabID == nil && !self.coordinator.owns(self.web) && self.web.superview === self.host
                    let expected = ["empty": [false], "paused": [false], "initialGuard": [false], "staleGuard": [false], "cancelled": [false], "presented": [true], "busy": [false]]
                    guard self.automaticCompletions == expected else { self.finish(false, "Automatic completion was not delivered exactly once per terminal result: \(self.automaticCompletions)"); return }
                    self.finish(passed, "Manual and automatic PiP: live video identity/time, panel, styles/controls, close/Escape; playing-only automatic detection, focus retention, stale-guard/pending cancellation, no replacement, and no-video handling")
                })
            }
        default: break
        }
    }

    private func checkPendingCancellation() {
        stage = .cancelling
        coordinator.toggle(web: web, tabID: tabID, restore: { [weak self] _ in self?.finish(false, "Pending detection unexpectedly rehosted the view") }, report: { [weak self] _ in self?.finish(false, "Cancelled request delivered a stale report") })
        guard coordinator.references(web), !coordinator.owns(web), coordinator.activeTabID == nil else {
            finish(false, "Pending request ownership is incorrect"); return
        }
        coordinator.restore()
        after(0.35) {
            guard !self.coordinator.references(self.web), !self.coordinator.owns(self.web), self.coordinator.activeTabID == nil, self.web.superview === self.host else {
                self.finish(false, "Cancelled detection opened a panel or retained the tab"); return
            }
            self.readTime { time in self.baselineTime = time; self.openPanel() }
        }
    }

    private func openPanel() {
        stage = .opening
        coordinator.toggle(web: web, tabID: tabID, restore: { [weak self] returned in
            guard let self else { return }
            guard returned === self.web else { self.finish(false, "Restored a different WKWebView"); return }
            self.restoreCount += 1
            self.host.addSubview(returned)
            returned.frame = self.host.bounds
        }, report: { [weak self] message in self?.finish(false, "Unexpected PiP report: \(message)") })
    }

    private func pictureInPictureChanged() {
        if stage == .automaticOpening { automaticOpened(); return }
        if stage == .automaticReturning { automaticReturned(); return }
        if stage == .opening {
            guard coordinator.owns(web), coordinator.activeTabID == tabID,
                  let floating = web.window as? NSPanel, floating !== window,
                  floating.isVisible, floating.level == .floating,
                  floating.contentMinSize.width == 320, floating.contentMinSize.height == 180 else {
                finish(false, "Floating panel/ownership state is incorrect"); return
            }
            stage = .playing
            after(0.75) {
                self.web.evaluateJavaScript("({same: document.querySelector('video') === window.__orbitSmokeVideo, time: window.__orbitSmokeVideo.currentTime, controls: window.__orbitSmokeVideo.controls, width: window.__orbitSmokeVideo.getBoundingClientRect().width, viewport: window.innerWidth})") { [weak self] value, error in
                    guard let self else { return }
                    guard error == nil, let info = value as? [String: Any], info["same"] as? Bool == true,
                          info["controls"] as? Bool == true, let time = info["time"] as? Double, time > self.baselineTime + 0.1,
                          let width = info["width"] as? Double, let viewport = info["viewport"] as? Double, abs(width - viewport) < 2 else {
                        self.finish(false, "Video identity, playback, controls, or isolation failed: \(value ?? "nil")"); return
                    }
                    self.panelTime = time
                    self.stage = .returning
                    if self.cycle == 0 {
                        self.web.window?.performClose(nil)
                    } else if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: floating.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        floating.sendEvent(event)
                    } else { self.finish(false, "Could not construct Escape test event") }
                }
            }
        } else if stage == .returning {
            guard coordinator.activeTabID == nil, !coordinator.owns(web), web.superview === host, restoreCount == cycle + 1 else {
                finish(false, "Return-to-tab callback or ownership failed"); return
            }
            stage = .restored
            after(0.5) {
                self.web.evaluateJavaScript("({same: document.querySelector('video') === window.__orbitSmokeVideo, time: window.__orbitSmokeVideo.currentTime, controls: window.__orbitSmokeVideo.controls, actualStyles: [window.__orbitSmokeVideo.getAttribute('style'),document.body.getAttribute('style'),document.documentElement.getAttribute('style')], expectedStyles: window.__orbitSmokeStyles, styles: JSON.stringify([window.__orbitSmokeVideo.getAttribute('style'),document.body.getAttribute('style'),document.documentElement.getAttribute('style')].map(value => value || '')) === JSON.stringify(window.__orbitSmokeStyles.map(value => value || ''))})") { [weak self] value, error in
                    guard let self else { return }
                    guard error == nil, let info = value as? [String: Any], info["same"] as? Bool == true,
                          info["styles"] as? Bool == true, info["controls"] as? Bool == false,
                          let time = info["time"] as? Double, time > self.panelTime + 0.1 else {
                        self.finish(false, "DOM/style/control restoration or continued playback failed: \(value ?? "nil")"); return
                    }
                    if self.cycle == 0 {
                        self.cycle = 1; self.baselineTime = time; self.openPanel()
                    } else {
                        self.testAutomaticPaused()
                    }
                }
            }
        }
    }

    private func testAutomaticPaused() {
        stage = .automaticPaused
        web.evaluateJavaScript("window.__orbitSmokeVideo.pause(); undefined") { [weak self] _, error in
            guard let self, error == nil else { self?.finish(false, "Could not pause the local fixture"); return }
            self.coordinator.automaticallyPresentIfPlaying(web: self.web, tabID: self.tabID, shouldPresent: { true }, restore: { [weak self] _ in self?.finish(false, "Paused automatic video was rehosted") }, completion: { [weak self] result in self?.recordCompletion("paused", result) })
            guard self.coordinator.referencedTabID == self.tabID, !self.coordinator.owns(self.web) else { self.finish(false, "Automatic pending tab identity is missing"); return }
            self.after(0.35) {
                guard self.coordinator.referencedTabID == nil, !self.coordinator.references(self.web), self.web.superview === self.host else { self.finish(false, "Paused video automatically entered PiP"); return }
                self.web.evaluateJavaScript("window.__orbitSmokeVideo.paused && !window.__orbitSmokeVideo.controls") { [weak self] value, error in
                    guard let self else { return }
                    guard error == nil, value as? Bool == true else { self.finish(false, "Automatic paused rejection altered playback or controls"); return }
                    self.testAutomaticCancellation()
                }
            }
        }
    }

    private func testAutomaticCancellation() {
        stage = .automaticCancelled
        coordinator.automaticallyPresentIfPlaying(web: web, tabID: tabID, shouldPresent: { false }, restore: { [weak self] _ in self?.finish(false, "False departure guard rehosted a page") }, completion: { [weak self] result in self?.recordCompletion("initialGuard", result) })
        guard coordinator.referencedTabID == nil else { finish(false, "False initial guard created a pending request"); return }
        web.callAsyncJavaScript("window.__orbitSmokeVideo.currentTime = 1; await window.__orbitSmokeVideo.play(); return true", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            if case .failure = result { self.finish(false, "Could not resume the fixture"); return }
            var allowDeparture = true
            self.coordinator.automaticallyPresentIfPlaying(web: self.web, tabID: self.tabID, shouldPresent: { allowDeparture }, restore: { [weak self] _ in self?.finish(false, "Stale departure guard rehosted a page") }, completion: { [weak self] result in self?.recordCompletion("staleGuard", result) })
            allowDeparture = false
            self.after(0.35) {
                guard self.coordinator.referencedTabID == nil, !self.coordinator.references(self.web), self.web.superview === self.host else { self.finish(false, "Guard was not rechecked after asynchronous video discovery"); return }
                self.coordinator.automaticallyPresentIfPlaying(web: self.web, tabID: self.tabID, shouldPresent: { true }, restore: { [weak self] _ in self?.finish(false, "Cancelled automatic request rehosted a page") }, completion: { [weak self] result in self?.recordCompletion("cancelled", result) })
                guard self.coordinator.referencedTabID == self.tabID else { self.finish(false, "Pending automatic tab identity disappeared"); return }
                self.coordinator.restore()
                self.after(0.35) {
                    guard self.coordinator.referencedTabID == nil, !self.coordinator.references(self.web), self.web.superview === self.host else { self.finish(false, "Returning to the tab failed to cancel automatic detection"); return }
                    self.openAutomatically()
                }
            }
        }
    }

    private func openAutomatically() {
        // The standalone executable is an accessory app; explicitly activate
        // the test window before measuring whether automatic PiP steals focus.
        NSApp.activate(ignoringOtherApps: true)
        after(0.15) { self.openAutomaticallyWithFocus() }
    }

    private func openAutomaticallyWithFocus() {
        focusField.frame = NSRect(x: 12, y: 12, width: 340, height: 26)
        host.addSubview(focusField, positioned: .above, relativeTo: web)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focusField)
        expectedKeyWindow = NSApp.keyWindow
        expectedFirstResponder = window.firstResponder
        guard expectedKeyWindow === window, expectedFirstResponder != nil else { finish(false, "Could not establish focus before automatic PiP: appActive=\(NSApp.isActive), key=\(String(describing: NSApp.keyWindow)), windowKey=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder))"); return }
        readTime { time in
            self.baselineTime = time
            self.stage = .automaticOpening
            self.coordinator.automaticallyPresentIfPlaying(web: self.web, tabID: self.tabID, shouldPresent: { true }, restore: { [weak self] returned in
                guard let self else { return }
                guard returned === self.web else { self.finish(false, "Automatic return replaced the web view"); return }
                self.host.addSubview(returned, positioned: .below, relativeTo: self.focusField)
                returned.frame = self.host.bounds
            }, completion: { [weak self] result in self?.recordCompletion("presented", result) })
        }
    }

    private func automaticOpened() {
        guard coordinator.activeTabID == tabID, coordinator.referencedTabID == tabID, coordinator.owns(web),
              let floating = web.window as? NSPanel, floating.isVisible, !floating.isKeyWindow,
              NSApp.keyWindow === expectedKeyWindow, window.firstResponder === expectedFirstResponder else { finish(false, "Automatic PiP did not preserve the current window and keyboard focus"); return }
        stage = .automaticPlaying
        // A second departure must not evict a video already in PiP.
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let other = WKWebView(frame: .zero, configuration: config)
        coordinator.automaticallyPresentIfPlaying(web: other, tabID: UUID(), shouldPresent: { true }, restore: { [weak self] _ in self?.finish(false, "Second automatic request replaced current PiP") }, completion: { [weak self] result in self?.recordCompletion("busy", result) })
        guard coordinator.owns(web), !coordinator.references(other), coordinator.referencedTabID == tabID else { finish(false, "Automatic PiP ownership was replaced by another departure"); return }
        after(0.7) {
            self.web.evaluateJavaScript("({same: document.querySelector('video') === window.__orbitSmokeVideo, time: window.__orbitSmokeVideo.currentTime, paused: window.__orbitSmokeVideo.paused})") { [weak self] value, error in
                guard let self else { return }
                guard error == nil, let info = value as? [String: Any], info["same"] as? Bool == true, info["paused"] as? Bool == false, let time = info["time"] as? Double, time > self.baselineTime + 0.1,
                      NSApp.keyWindow === self.expectedKeyWindow, self.window.firstResponder === self.expectedFirstResponder else { self.finish(false, "Automatic playback continuity or focus retention failed: \(value ?? "nil")"); return }
                self.panelTime = time
                self.stage = .automaticReturning
                self.coordinator.restore()
            }
        }
    }

    private func automaticReturned() {
        stage = .automaticRestored
        guard coordinator.referencedTabID == nil, !coordinator.references(web), web.superview === host else { finish(false, "Automatic return retained stale ownership"); return }
        after(0.4) {
            self.web.evaluateJavaScript("({same: document.querySelector('video') === window.__orbitSmokeVideo, time: window.__orbitSmokeVideo.currentTime, controls: window.__orbitSmokeVideo.controls, styles: JSON.stringify([window.__orbitSmokeVideo.getAttribute('style'),document.body.getAttribute('style'),document.documentElement.getAttribute('style')].map(value => value || '')) === JSON.stringify(window.__orbitSmokeStyles.map(value => value || ''))})") { [weak self] value, error in
                guard let self else { return }
                guard error == nil, let info = value as? [String: Any], info["same"] as? Bool == true, info["controls"] as? Bool == false, info["styles"] as? Bool == true, let time = info["time"] as? Double, time > self.panelTime + 0.1,
                      NSApp.keyWindow === self.expectedKeyWindow, self.window.firstResponder === self.expectedFirstResponder else { self.finish(false, "Automatic return did not restore content/playback without stealing focus: \(value ?? "nil")"); return }
                self.focusField.removeFromSuperview()
                self.stage = .loadingEmpty; self.loadFixture("SmokeA")
            }
        }
    }

    private func recordCompletion(_ label: String, _ result: Bool) {
        automaticCompletions[label, default: []].append(result)
    }

    private func readTime(_ callback: @escaping (Double) -> Void) {
        web.evaluateJavaScript("(() => { window.__orbitSmokeStyles = [window.__orbitSmokeVideo.getAttribute('style'), document.body.getAttribute('style'), document.documentElement.getAttribute('style')]; return document.querySelector('video').currentTime; })()") { [weak self] value, error in
            guard let self else { return }
            guard error == nil, let time = value as? Double, time > 0 else { self.finish(false, "Video time did not advance"); return }
            callback(time)
        }
    }

    private func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.stage != .finished else { return }; action()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false, error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false, error.localizedDescription) }

    private func finish(_ success: Bool, _ message: String) {
        guard stage != .finished else { return }
        stage = .finished; timeout?.invalidate(); coordinator.restore()
        print("\(success ? "PASS" : "FAIL"): PiP — \(message)"); fflush(stdout)
        exit(success ? 0 : 1)
    }
}
