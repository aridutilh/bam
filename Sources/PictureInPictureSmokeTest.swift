import AppKit
import WebKit

/// Uses only bundled pages, a bundled video, and a nonpersistent WebKit store.
@MainActor final class PictureInPictureSmokeTest: NSObject, WKNavigationDelegate {
    private enum Stage { case loadingVideo, cancelling, opening, playing, returning, restored, rapidRefloat, automaticPaused, automaticCancelled, automaticOpening, automaticPlaying, automaticReturning, automaticRestored, loadingEmpty, automaticEmpty, empty, finished }
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
    private weak var returningPanel: NSWindow?
    private var oldMarker = false
    private var newMarker = true
    private var renderedCoverChecks = 0
    private var explicitReturns: [UUID] = []
    private var automaticCompletions: [String: [Bool]] = [:]
    private let focusField = NSTextField(string: "Typing continues in the selected tab")
    private weak var expectedKeyWindow: NSWindow?
    private weak var expectedFirstResponder: NSResponder?

    init(resourcesURL: URL? = nil) { self.resourcesURL = resourcesURL; super.init() }

    func start() {
        do { print("PASS: PiP positioning — \(try PiPPositioningSmokeTest.run()) checks") }
        catch { finish(false, "\(error)"); return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Bam — local PiP smoke test"
        window.contentView = host
        host.addSubview(web); web.frame = host.bounds
        window.makeKeyAndOrderFront(nil)
        coordinator.onChange = { [weak self] in self?.pictureInPictureChanged() }
        coordinator.onReturnToTab = { [weak self] id in self?.explicitReturns.append(id) }
        coordinator.onRestorationReady = { [weak self] web in self?.checkRenderedCover(web) }
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
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
                const marker = document.createElement('div');
                marker.id = 'orbit-render-marker';
                marker.style.cssText = 'position:fixed;left:0;top:0;width:28px;height:28px;z-index:2147483646;';
                for (let index = 0; index < 4; index++) {
                    const cell = document.createElement('span');
                    cell.style.cssText = `position:absolute;left:${index % 2 * 14}px;top:${Math.floor(index / 2) * 14}px;width:14px;height:14px;background:${index === 0 || index === 3 ? '#fff' : '#000'};`;
                    marker.append(cell);
                }
                document.body.append(marker);
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
                    self.finish(passed, "Fresh page-cover pixel checks and cancellation, final-size presentation, manual and automatic PiP: live video identity/time, rounded aspect-fit panel, native pause/play/seek bounds/volume/mute/resize/Return, restored DOM before reveal, close/Escape; playing-only automatic detection, focus retention, stale-guard/pending cancellation, no replacement, and no-video handling")
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
                  !floating.styleMask.contains(.titled), floating.styleMask.contains(.resizable),
                  floating.isOpaque == false, floating.contentView?.layer?.cornerRadius == 14,
                  floating.contentMinSize.width == 320 else {
                finish(false, "Floating panel/ownership state is incorrect"); return
            }
            stage = .playing
            after(0.75) {
                guard self.coordinator.presentationReady, floating.alphaValue > 0.99,
                      self.control("presentationCover", in: floating.contentView) == nil else {
                    self.finish(false, "PiP was not revealed from a rendered final-size frame"); return
                }
                self.web.evaluateJavaScript("({same: document.querySelector('video') === window.__orbitSmokeVideo, time: window.__orbitSmokeVideo.currentTime, controls: window.__orbitSmokeVideo.controls, width: window.__orbitSmokeVideo.getBoundingClientRect().width, height: window.__orbitSmokeVideo.getBoundingClientRect().height, ratio: window.__orbitSmokeVideo.videoWidth / window.__orbitSmokeVideo.videoHeight, viewport: window.innerWidth, viewportHeight: window.innerHeight})") { [weak self] value, error in
                    guard let self else { return }
                    guard error == nil, let info = value as? [String: Any], info["same"] as? Bool == true,
                          info["controls"] as? Bool == false, let time = info["time"] as? Double, time > self.baselineTime + 0.1,
                          let width = info["width"] as? Double, let viewport = info["viewport"] as? Double, abs(width - viewport) < 2,
                          let height = info["height"] as? Double, let viewportHeight = info["viewportHeight"] as? Double, abs(height - viewportHeight) < 2,
                          let ratio = info["ratio"] as? Double, abs(Double(floating.frame.width / floating.frame.height) - ratio) < 0.02 else {
                        self.finish(false, "Video identity, playback, controls, or isolation failed: \(value ?? "nil")"); return
                    }
                    if self.cycle == 0 {
                        self.exerciseNativeControls(in: floating) { self.finishManualCycle(in: floating) }
                    } else { self.finishManualCycle(in: floating) }
                }
            }
        } else if stage == .returning {
            let cover = control("restorationCover", in: web) as? NSImageView
            let still = control("panelSnapshot", in: returningPanel?.contentView) as? NSImageView
            let checks: [(String, Bool)] = [
                ("activeTabCleared", coordinator.activeTabID == nil),
                ("ownershipReleased", !coordinator.owns(web)),
                ("originalHostRestored", web.superview === host),
                ("restoreCallbackCount", restoreCount == cycle + 1),
                ("restorationActive", coordinator.isRestoring(web)),
                ("oldPanelVisible", returningPanel?.isVisible == true),
                ("pageCoverExists", cover != nil),
                ("pageCoverOpaque", cover?.alphaValue == 1),
                ("originalPagePixels", image(cover?.image, containsMarker: oldMarker)),
                ("panelStillExists", still != nil),
                ("panelStillHasImage", still?.image != nil)
            ]
            let failed = checks.filter { !$0.1 }.map { $0.0 }
            guard failed.isEmpty else {
                finish(false, "Return handoff failed [\(failed.joined(separator: ", "))]; cycle=\(cycle), callbacks=\(restoreCount), webBounds=\(web.bounds), coverFrame=\(String(describing: cover?.frame)), coverAlpha=\(String(describing: cover?.alphaValue)), panelVisible=\(String(describing: returningPanel?.isVisible)), panelAlpha=\(String(describing: returningPanel?.alphaValue)), marker=\(markerDiagnostics(cover?.image, expected: oldMarker))")
                return
            }
            stage = .restored
            afterRestoration {
                self.web.evaluateJavaScript("({same: document.querySelector('video') === window.__orbitSmokeVideo, time: window.__orbitSmokeVideo.currentTime, controls: window.__orbitSmokeVideo.controls, actualStyles: [window.__orbitSmokeVideo.getAttribute('style'),document.body.getAttribute('style'),document.documentElement.getAttribute('style')], expectedStyles: window.__orbitSmokeStyles, styles: JSON.stringify([window.__orbitSmokeVideo.getAttribute('style'),document.body.getAttribute('style'),document.documentElement.getAttribute('style')].map(value => value || '')) === JSON.stringify(window.__orbitSmokeStyles.map(value => value || ''))})") { [weak self] value, error in
                    guard let self else { return }
                    guard error == nil, let info = value as? [String: Any], info["same"] as? Bool == true,
                          info["styles"] as? Bool == true, info["controls"] as? Bool == false, self.web.alphaValue == 1,
                          self.renderedCoverChecks == self.cycle + 1, self.returningPanel?.isVisible != true,
                          self.control("restorationCover", in: self.web) == nil,
                          let time = info["time"] as? Double, time > self.panelTime + 0.1 else {
                        self.finish(false, "DOM/style/control restoration or continued playback failed: \(value ?? "nil")"); return
                    }
                    if self.cycle < 2 {
                        self.cycle += 1; self.baselineTime = time; self.openPanel()
                    } else {
                        guard self.explicitReturns == [self.tabID] else { self.finish(false, "Only the explicit Return control should request source selection"); return }
                        self.testRapidRefloat()
                    }
                }
            }
        }
    }

    private func finishManualCycle(in floating: NSPanel) {
        oldMarker = !cycle.isMultiple(of: 2)
        newMarker = cycle.isMultiple(of: 2)
        returningPanel = floating
        web.evaluateJavaScript("Array.from(document.getElementById('orbit-render-marker').children).forEach((cell, index) => { cell.style.background = ((index === 0 || index === 3) !== \(newMarker ? "true" : "false")) ? '#fff' : '#000'; }); window.__orbitSmokeVideo.currentTime") { [weak self] value, _ in
            guard let self, let time = value as? Double else { return }
            self.panelTime = time
            self.stage = .returning
            if self.cycle == 0 { floating.performClose(nil) }
            else if self.cycle == 1 {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: floating.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { self.finish(false, "Could not construct Escape event"); return }
                floating.sendEvent(event)
            } else if let button = self.control("return", in: floating.contentView) as? NSButton { button.performClick(nil) }
            else { self.finish(false, "Return control missing") }
        }
    }

    private func checkRenderedCover(_ returned: WKWebView) {
        guard stage == .restored || stage == .automaticRestored else { return }
        guard returned === web, coordinator.restorationHasRendered(web),
              let cover = control("restorationCover", in: web) as? NSImageView,
              cover.alphaValue == 1, image(cover.image, containsMarker: newMarker) else {
            let cover = control("restorationCover", in: returned) as? NSImageView
            finish(false, "Fresh destination cover failed: cycle=\(cycle), sameWeb=\(returned === web), rendered=\(coordinator.restorationHasRendered(web)), coverAlpha=\(String(describing: cover?.alphaValue)), marker=\(markerDiagnostics(cover?.image, expected: newMarker))"); return
        }
        renderedCoverChecks += 1
    }

    private func image(_ image: NSImage?, containsMarker inverted: Bool) -> Bool {
        guard let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              image.size.width > 0, image.size.height > 0 else { return false }
        // TIFF/colorAt may interpret RGB bytes as Generic RGB before sRGB
        // conversion. Black/white endpoints avoid profile-dependent chromatic
        // shifts; all four cells must match the old or newly inverted pattern.
        return [false, true].contains { verticallyFlipped in
            (0..<4).allSatisfy { index in
                let pointX = CGFloat(index % 2 * 14 + 7)
                let pointY = CGFloat(index / 2 * 14 + 7)
                let x = min(bitmap.pixelsWide - 1, Int(pointX * CGFloat(bitmap.pixelsWide) / image.size.width))
                let imageY = min(bitmap.pixelsHigh - 1, Int(pointY * CGFloat(bitmap.pixelsHigh) / image.size.height))
                let y = verticallyFlipped ? bitmap.pixelsHigh - imageY - 1 : imageY
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.99 else { return false }
                let white = (index == 0 || index == 3) != inverted
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                return white ? channels.allSatisfy { $0 > 0.98 } : channels.allSatisfy { $0 < 0.02 }
            }
        }
    }

    private func markerDiagnostics(_ image: NSImage?, expected inverted: Bool) -> String {
        guard let image else { return "image=nil" }
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              image.size.width > 0, image.size.height > 0 else { return "unreadable image size=\(image.size)" }
        func components(_ color: NSColor?) -> String {
            guard let color = color?.usingColorSpace(.sRGB) else { return "unavailable" }
            return String(format: "(%.3f,%.3f,%.3f,%.3f)", Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent))
        }
        let samples = [false, true].map { flipped in
            let cells = (0..<4).map { index -> String in
                let x = min(bitmap.pixelsWide - 1, Int(CGFloat(index % 2 * 14 + 7) * CGFloat(bitmap.pixelsWide) / image.size.width))
                let imageY = min(bitmap.pixelsHigh - 1, Int(CGFloat(index / 2 * 14 + 7) * CGFloat(bitmap.pixelsHigh) / image.size.height))
                let y = flipped ? bitmap.pixelsHigh - imageY - 1 : imageY
                return "(\(x),\(y))=" + components(bitmap.colorAt(x: x, y: y))
            }.joined(separator: ";")
            return "flipped=\(flipped):" + cells
        }.joined(separator: " / ")
        return "size=\(image.size), bitmap=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), colorSpace=\(bitmap.colorSpace), expected=\(inverted ? "BWWB" : "WBBW"), samples=\(samples)"
    }

    private func afterRestoration(_ action: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.waitForRestoration()
                try await Task.sleep(nanoseconds: 150_000_000)
                guard self.stage != .finished else { return }
                action()
            } catch { self.finish(false, "Visual restoration did not finish: \(error)") }
        }
    }

    private func waitForRestoration() async throws {
        for _ in 0..<120 {
            if !coordinator.isRestoring(web) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ControlFailure(message: "Timed out waiting for the restored page cover")
    }

    private func control(_ name: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.identifier?.rawValue == "pip.\(name)" { return root }
        for child in root.subviews { if let result = control(name, in: child) { return result } }
        return nil
    }

    private struct ControlFailure: Error { let message: String }
    private func waitForJavaScript(_ expression: String) async throws {
        for _ in 0..<60 {
            if try await web.evaluateJavaScript(expression) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ControlFailure(message: expression)
    }

    private func exerciseNativeControls(in floating: NSPanel, completion: @escaping () -> Void) {
        guard let pause = control("playPause", in: floating.contentView) as? NSButton,
              let back = control("backward", in: floating.contentView) as? NSButton,
              let forward = control("forward", in: floating.contentView) as? NSButton,
              let mute = control("mute", in: floating.contentView) as? NSButton,
              let volume = control("volume", in: floating.contentView) as? NSSlider,
              let grip = control("resize", in: floating.contentView),
              control("return", in: floating.contentView) is NSButton,
              control("close", in: floating.contentView) is NSButton else {
            finish(false, "Native overlay controls missing"); return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                pause.performClick(nil)
                try await self.waitForJavaScript("window.__orbitSmokeVideo.paused")
                _ = try await self.web.evaluateJavaScript("window.__orbitSmokeVideo.currentTime = 5; undefined")
                forward.performClick(nil)
                try await self.waitForJavaScript("Math.abs(window.__orbitSmokeVideo.currentTime - 15) < 0.3")
                back.performClick(nil)
                try await self.waitForJavaScript("Math.abs(window.__orbitSmokeVideo.currentTime - 5) < 0.3")
                _ = try await self.web.evaluateJavaScript("window.__orbitSmokeVideo.currentTime = 1; undefined")
                back.performClick(nil)
                try await self.waitForJavaScript("window.__orbitSmokeVideo.currentTime < 0.1")
                _ = try await self.web.evaluateJavaScript("window.__orbitSmokeVideo.currentTime = window.__orbitSmokeVideo.duration - 1; undefined")
                forward.performClick(nil)
                try await self.waitForJavaScript("window.__orbitSmokeVideo.currentTime <= window.__orbitSmokeVideo.duration && window.__orbitSmokeVideo.currentTime > window.__orbitSmokeVideo.duration - 0.3")
                volume.doubleValue = 0.35; _ = volume.sendAction(volume.action, to: volume.target)
                try await self.waitForJavaScript("Math.abs(window.__orbitSmokeVideo.volume - 0.35) < 0.001 && !window.__orbitSmokeVideo.muted")
                mute.performClick(nil)
                try await self.waitForJavaScript("window.__orbitSmokeVideo.muted")
                let oldWidth = floating.frame.width
                guard grip.accessibilityPerformIncrement(), floating.frame.width > oldWidth,
                      abs(floating.frame.width / floating.frame.height - floating.contentAspectRatio.width) < 0.02,
                      grip.accessibilityPerformDecrement() else { throw ControlFailure(message: "Accessible resize must preserve video aspect ratio") }
                _ = try await self.web.evaluateJavaScript("window.__orbitSmokeVideo.currentTime = 5; undefined")
                pause.performClick(nil)
                try await self.waitForJavaScript("!window.__orbitSmokeVideo.paused && document.querySelector('video') === window.__orbitSmokeVideo && window.__orbitSmokeVideo.currentTime > 5.05")
                completion()
            } catch { self.finish(false, "Native media control check failed: \(error)") }
        }
    }

    private func testRapidRefloat() {
        stage = .rapidRefloat
        let restore: (WKWebView) -> Void = { [weak self] returned in
            guard let self else { return }; self.host.addSubview(returned); returned.frame = self.host.bounds
        }
        let report: (String) -> Void = { [weak self] message in self?.finish(false, "Immediate re-float: \(message)") }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.coordinator.toggle(web: self.web, tabID: self.tabID, restore: restore, report: report)
                try await self.waitForOwnership(true)
                let firstPanel = self.web.window
                self.coordinator.restore()
                guard self.coordinator.isRestoring(self.web), self.control("restorationCover", in: self.web) != nil else {
                    throw ControlFailure(message: "Rapid return had no protected destination surface")
                }
                self.coordinator.toggle(web: self.web, tabID: self.tabID, restore: restore, report: report)
                guard !self.coordinator.isRestoring(self.web), firstPanel?.isVisible != true,
                      self.control("restorationCover", in: self.web) == nil else {
                    throw ControlFailure(message: "Re-float did not synchronously cancel its old cover/window")
                }
                try await self.waitForOwnership(true)
                try await Task.sleep(nanoseconds: 250_000_000)
                guard self.web.alphaValue == 1, self.web.window !== self.window else {
                    throw ControlFailure(message: "Stale restore completion hid or reparented the re-floated video")
                }
                try await self.waitForJavaScript("document.querySelector('video') === window.__orbitSmokeVideo && !window.__orbitSmokeVideo.controls && getComputedStyle(window.__orbitSmokeVideo).position === 'fixed'")
                self.coordinator.restore()
                try await self.waitForJavaScript("JSON.stringify([window.__orbitSmokeVideo.getAttribute('style'), document.body.getAttribute('style'), document.documentElement.getAttribute('style')].map(value => value || '')) === JSON.stringify(window.__orbitSmokeStyles.map(value => value || ''))")
                try await self.waitForRestoration()
                guard self.web.superview === self.host, self.web.alphaValue == 1,
                      self.control("restorationCover", in: self.web) == nil else {
                    throw ControlFailure(message: "Re-float cycle did not restore its original host/visibility")
                }
                self.testAutomaticPaused()
            } catch { self.finish(false, "Immediate re-float check failed: \(error)") }
        }
    }

    private func waitForOwnership(_ owned: Bool) async throws {
        for _ in 0..<60 {
            if coordinator.owns(web) == owned, coordinator.activeTabID == (owned ? tabID : nil) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ControlFailure(message: "Timed out waiting for PiP ownership")
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
        afterRestoration {
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
