import AppKit
import WebKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    var window: NSWindow!
    var controller: BrowserController!
    var profileSmoke: ProfileSmokeTest?
    var extensionSmoke: ExtensionRuntimeSmokeTest?
    var vendorProbe: VendorExtensionProbe?
    var resourceSmoke: TabResourceSmokeTest?
    var featureSmoke: FeatureSmokeTest?
    var smoke: WebSmokeTest?
    var pipSmoke: PictureInPictureSmokeTest?
    var interactionSmoke: InteractionSmokeTest?
    var autoPiPSmoke: AutomaticPiPSmokeTest?
    var pendingExternalURLs: [URL] = []
    var spacesMenu: NSMenu?
    var onboarding: OnboardingController?
    var extensionsMenu: NSMenu?
    private let quitCoordinator = QuitCoordinator()
    private var mainWindowWasClosed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--vendor-extension-probe") { vendorProbe = VendorExtensionProbe(); vendorProbe?.start(); return }
        if CommandLine.arguments.contains("--extension-test") { extensionSmoke = ExtensionRuntimeSmokeTest(); extensionSmoke?.start(); return }
        if CommandLine.arguments.contains("--profile-test") { profileSmoke = ProfileSmokeTest(); profileSmoke?.start(); return }
        if CommandLine.arguments.contains("--resource-test") { resourceSmoke = TabResourceSmokeTest(); resourceSmoke?.start(); return }
        if CommandLine.arguments.contains("--feature-test") { featureSmoke = FeatureSmokeTest(); featureSmoke?.start(); return }
        if CommandLine.arguments.contains("--auto-pip-test") { autoPiPSmoke = AutomaticPiPSmokeTest(); autoPiPSmoke?.start(); return }
        if CommandLine.arguments.contains("--interaction-test") { interactionSmoke = InteractionSmokeTest(); interactionSmoke?.start(); return }
        if CommandLine.arguments.contains("--pip-test") { pipSmoke = PictureInPictureSmokeTest(); pipSmoke?.start(); return }
        if CommandLine.arguments.contains("--web-test") {
            smoke = WebSmokeTest(); smoke?.start(); return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OrbitPrototype", isDirectory: true)
        let preview = CommandLine.arguments.contains("--fresh-preview")
        let sessionFileExists = FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path)
        controller = BrowserController(sessionURL: support.appendingPathComponent("session.json"), ephemeral: preview)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bam"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self
        window.isMovableByWindowBackground = false; window.minSize = NSSize(width: 760, height: 540)
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.contentViewController = controller
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window.setContentSize(NSSize(width: min(1260, available.width - 60), height: min(800, available.height - 60)))
        window.center()
        if !preview { window.setFrameAutosaveName("OrbitPrototypeWindow") }
        window.appearance = NSAppearance(named: .darkAqua)
        controller.onSpacesChanged = { [weak self] in self?.rebuildSpacesMenu() }
        buildMenus(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for url in pendingExternalURLs { controller.openLittleOrbit(url: url) }; pendingExternalURLs.removeAll()
        let completed = UserDefaults.standard.bool(forKey: OnboardingGate.completedKey)
        let started = UserDefaults.standard.bool(forKey: OnboardingGate.startedKey)
        if OnboardingGate.shouldGrandfather(arguments: CommandLine.arguments, sessionFileExists: sessionFileExists,
                                            completed: completed, started: started) {
            // Profiles that predate onboarding are never welcomed as new.
            UserDefaults.standard.set(true, forKey: OnboardingGate.completedKey)
        } else if OnboardingGate.shouldPresent(arguments: CommandLine.arguments, sessionFileExists: sessionFileExists,
                                               completed: completed, started: started) {
            presentOnboarding()
        }
    }
    @objc func showWelcome(_ sender: Any?) { presentOnboarding() }
    func presentOnboarding() {
        guard onboarding == nil, let controller, let window, window.attachedSheet == nil else { return }
        controller.setOnboardingActive(true)
        var model = OnboardingModel(bookmarks: ChromeBookmarks.load(from: ChromeBookmarks.defaultStoreURL()))
        if let first = controller.session.spaces.first {
            model.colorIndex = first.colorIndex; model.spaceName = first.name; model.spaceSymbol = first.symbol
        }
        let welcome = OnboardingController(model: model)
        welcome.onApply = { [weak self] result in self?.controller?.applyOnboarding(result) }
        // A quit mid-welcome writes a session; the started mark keeps the next
        // launch from mistaking that profile for a pre-onboarding one.
        if controller.privateMode != true { UserDefaults.standard.set(true, forKey: OnboardingGate.startedKey) }
        welcome.onDismiss = { [weak self] _ in
            guard let self else { return }
            self.onboarding = nil
            self.controller?.setOnboardingActive(false)
            // Seen once is seen: skipping must not re-welcome on the next launch.
            if self.controller?.privateMode != true {
                UserDefaults.standard.set(true, forKey: OnboardingGate.completedKey)
                UserDefaults.standard.removeObject(forKey: OnboardingGate.startedKey)
            }
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeFirstResponder(self.controller?.commandWebView)
        }
        onboarding = welcome
        welcome.present(over: window)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Fixtures deliberately minimize, replace, and close their windows.
        // Only their explicit terminal result may finish a smoke-test process.
        return !CommandLine.arguments.contains { OnboardingGate.testArguments.contains($0) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Runtime fixtures own their controllers and exit explicitly. Both
        // normal browsing and the fresh private preview use this confirmation.
        guard let controller else { return .terminateNow }
        quitCoordinator.request(confirmation: {
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to quit Bam?"
            alert.informativeText = "All Bam windows will close. Playing audio and video will stop."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Bam").keyEquivalent = ""
            sender.activate(ignoringOtherApps: true)
            return self.runQuitAlert(alert) == .alertSecondButtonReturn
        }, save: {
            await controller.flushSessionForTermination()
        }, saveFailure: {
            let alert = NSAlert()
            alert.messageText = "Your latest tabs haven’t been saved"
            alert.informativeText = "Bam couldn’t finish saving this session. You can stay in the browser, retry, or quit without the latest changes."
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Quit Without Saving")
            switch self.runQuitAlert(alert) {
            case .alertSecondButtonReturn: return .retry
            case .alertThirdButtonReturn: return .quitWithoutSaving
            default: return .cancel
            }
        }, reply: { [weak self] shouldQuit in
            if !shouldQuit { self?.restoreClosedMainWindow() }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        })
        return .terminateLater
    }
    private func runQuitAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let cancel = alert.buttons[0]
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        // AppKit replaces a default button's Escape equivalent with Return.
        // Handle Escape only while this alert owns the modal event loop.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === alert.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }
    private func restoreClosedMainWindow() {
        // Closing the last window triggers termination after AppKit hides it.
        // Cancel must bring back that retained session, not leave a windowless app.
        guard mainWindowWasClosed,
              controller?.littleWindows.values.contains(where: { $0.window?.isVisible == true }) != true else { return }
        mainWindowWasClosed = false
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window { mainWindowWasClosed = true }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if let selected = notification.object as? NSWindow, selected === window { mainWindowWasClosed = false }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.prepareToClose(persistSession: false) }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where URLInput.directURL(url.absoluteString) != nil {
            if let controller { controller.openLittleOrbit(url: url) } else { pendingExternalURLs.append(url) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.makeKeyAndOrderFront(nil); return true }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === extensionsMenu { controller?.updateExtensionsMenu(menu) }
    }
    @objc func selectSpace(_ sender: NSMenuItem) { controller.changeSpace(sender.tag) }
    func rebuildSpacesMenu() {
        guard let spacesMenu, let controller else { return }
        spacesMenu.removeAllItems()
        for (index, space) in controller.session.spaces.enumerated() {
            let item = NSMenuItem(title: space.name, action: #selector(selectSpace(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = [.command, .option]; item.target = self; item.tag = space.id
            item.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
            spacesMenu.addItem(item)
        }
    }
    @objc func goHome(_ sender: Any?) { controller.showHome(sender) }
    @objc func recordSpaceSwipes(_ sender: Any?) { SpaceSwipeDiagnostics.shared.start() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectSpace(_:)) {
            menuItem.state = controller?.session.space == menuItem.tag ? .on : .off
            return controller?.session.spaceDefinition(menuItem.tag) != nil && window?.attachedSheet == nil
        }
        if menuItem.action == #selector(goHome(_:)) { return window?.attachedSheet == nil && controller?.littleWindows.values.contains(where: { $0.window?.isKeyWindow == true }) != true }
        if menuItem.action == #selector(recordSpaceSwipes(_:)) {
            return !SpaceSwipeDiagnostics.shared.isRecording && !SpaceSwipeDiagnostics.shared.isStarting
        }
        if menuItem.action == #selector(showWelcome(_:)) {
            return onboarding == nil && controller != nil && window?.attachedSheet == nil && window?.isVisible == true
        }
        return true
    }
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Bam", .applicationVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") + " — Native browser prototype", .credits: NSAttributedString(string: "An independent AppKit + WebKit prototype informed by recovered sidebar behavior.\nNot affiliated with The Browser Company.")])
    }
    func buildMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); main.addItem(item); let sub = NSMenu(title: title); item.submenu = sub; return sub }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, _ target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let app = menu("Bam")
        item(app, "About Bam", #selector(showAbout), "", .command, self)
        item(app, "Welcome to Bam…", #selector(showWelcome), "", .command, self)
        app.addItem(.separator()); item(app, "Hide Bam", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); item(app, "Quit Bam", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New Little Bam Window", #selector(BrowserController.newLittleOrbit(_:)), "n", [.command, .option], controller)
        item(file, "New Tab", #selector(BrowserController.newTab(_:)), "t", .command, controller)
        item(file, "Open Location…", #selector(BrowserController.focusAddress(_:)), "l", .command, controller)
        item(file, "Close Tab", #selector(BrowserController.closeTab(_:)), "w", .command, controller)
        item(file, "Reopen Closed Tab", #selector(BrowserController.reopenTab(_:)), "t", [.command, .shift], controller)
        file.addItem(.separator()); item(file, "Print…", #selector(BrowserController.printPage(_:)), "p", .command, controller)
        let edit = menu("Edit")
        item(edit, "Undo", Selector(("undo:")), "z"); item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift]); edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x"); item(edit, "Copy", #selector(NSText.copy(_:)), "c"); item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find in Page…", #selector(BrowserController.findInPage(_:)), "f", .command, controller)
        item(edit, "Find Next", #selector(BrowserController.findNext(_:)), "g", .command, controller)
        item(edit, "Find Previous", #selector(BrowserController.findPrevious(_:)), "g", [.command, .shift], controller)
        item(edit, "Copy Current URL", #selector(BrowserController.copyCurrentURL(_:)), "c", [.command, .shift], controller)
        let view = menu("View")
        item(view, "Toggle Sidebar", #selector(BrowserController.toggleSidebar(_:)), "s", .command, controller)
        item(view, "Reset Sidebar Width", #selector(BrowserController.resetSidebar(_:)), "s", [.command, .shift], controller)
        item(view, "Keep / Unkeep Tab", #selector(BrowserController.togglePin(_:)), "d", .command, controller)
        item(view, "Add / Remove Favorite", #selector(BrowserController.toggleFavorite(_:)), "d", [.command, .shift], controller)
        item(view, "Edit Saved Tab…", #selector(BrowserController.editCurrentSavedTab(_:)), "", .command, controller)
        item(view, "Reset to Saved Page", #selector(BrowserController.resetCurrentSavedTab(_:)), "", .command, controller)
        view.addItem(.separator()); item(view, "Reload / Stop", #selector(BrowserController.reload(_:)), "r", .command, controller)
        item(view, "Hard Refresh", #selector(BrowserController.hardReload(_:)), "r", [.command, .shift], controller)
        item(view, "Zoom In", #selector(BrowserController.zoomIn(_:)), "+", .command, controller)
        item(view, "Zoom Out", #selector(BrowserController.zoomOut(_:)), "-", .command, controller)
        item(view, "Actual Size", #selector(BrowserController.actualSize(_:)), "0", .command, controller)
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        view.addItem(.separator())
        item(view, "Automatically Show Playing Videos", #selector(BrowserController.toggleAutomaticVideo(_:)), "", .command, controller)
        view.items.last?.state = controller.automaticallyShowsVideo ? .on : .off
        item(view, "Picture in Picture", #selector(BrowserController.togglePictureInPicture(_:)), "p", [.command, .option], controller)
        item(view, "Sleep Idle Pages Under Memory Pressure", #selector(BrowserController.toggleAutomaticTabSleeping(_:)), "", .command, controller)
        item(view, "Keep This Site Awake", #selector(BrowserController.toggleSiteKeepAwake(_:)), "", .command, controller)
        item(view, "Open Video Demo", #selector(BrowserController.openVideoDemo(_:)), "", .command, controller)
        view.addItem(.separator())
        item(view, "Split View with New Page", #selector(BrowserController.splitWithNewPage(_:)), "=", [.command, .option], controller)
        item(view, "Separate Split into Tabs", #selector(BrowserController.unsplitCurrent(_:)), "", .command, controller)
        view.addItem(.separator())
        item(view, "Record Space Swipes (60 Seconds)", #selector(recordSpaceSwipes(_:)), "", .command, self)
        let history = menu("History")
        item(history, "Back", #selector(BrowserController.goBack(_:)), "[", .command, controller)
        item(history, "Forward", #selector(BrowserController.goForward(_:)), "]", .command, controller)
        item(history, "Home", #selector(goHome(_:)), "h", [.command, .shift], self)
        history.addItem(.separator())
        item(history, "Show History…", #selector(BrowserController.showHistory(_:)), "y", .command, controller)
        item(history, "Recently Closed…", #selector(BrowserController.showArchive(_:)), "", .command, controller)
        item(view, "Downloads…", #selector(BrowserController.showDownloads(_:)), "j", .command, controller)
        let tabs = menu("Tabs")
        item(tabs, "Next Tab", #selector(BrowserController.nextTab(_:)), "\t", .control, controller)
        item(tabs, "Previous Tab", #selector(BrowserController.previousTab(_:)), "\t", [.control, .shift], controller)
        item(tabs, "Next Space", #selector(BrowserController.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option], controller)
        item(tabs, "Previous Space", #selector(BrowserController.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option], controller)
        tabs.addItem(.separator())
        item(tabs, "Manage Spaces…", #selector(BrowserController.manageSpaces(_:)), "", .command, controller)
        let chooseSpace = NSMenuItem(title: "Go to Space", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Go to Space"); chooseSpace.submenu = submenu; tabs.addItem(chooseSpace)
        spacesMenu = submenu; rebuildSpacesMenu()
        let extensions = menu("Extensions"); extensions.delegate = self; extensionsMenu = extensions
        controller.updateExtensionsMenu(extensions)
        let windowMenu = menu("Window"); NSApp.windowsMenu = windowMenu
        item(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
    }
}

/// Runs a real WebKit engine against bundled test pages without touching a user's browser data.
@MainActor final class WebSmokeTest: NSObject, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var stage = 0
    var completed = false
    var timeout: Timer?
    func start() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: config); web.navigationDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web
        window.orderFront(nil)
        timeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in DispatchQueue.main.async { self?.finish(false, "WebKit test timed out") } }
        guard let file = Bundle.main.url(forResource: "SmokeA", withExtension: "html") else { finish(false, "Missing fixture"); return }
        web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if stage == 0 {
            web.evaluateJavaScript("document.title + ':' + document.getElementById('sentinel').textContent") { [weak self] value, error in
                guard let self else { return }
                guard error == nil, value as? String == "Orbit Smoke A:ready" else { self.finish(false, "DOM did not render"); return }
                self.stage = 1; self.web.evaluateJavaScript("document.getElementById('next').click()", completionHandler: nil)
            }
        } else if stage == 1 {
            web.evaluateJavaScript("document.title") { [weak self] value, error in
                guard let self else { return }
                guard error == nil, value as? String == "Orbit Smoke B", self.web.canGoBack else { self.finish(false, "Navigation/history unavailable: title=\(value ?? "nil"), back=\(self.web.canGoBack)"); return }
                self.stage = 2; self.web.goBack()
            }
        } else if stage == 2 {
            web.evaluateJavaScript("document.title") { [weak self] value, error in
                guard let self else { return }
                self.finish(error == nil && value as? String == "Orbit Smoke A" && self.web.canGoForward, "DOM render, local-link navigation, back and forward history")
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false, error.localizedDescription) }
    func finish(_ success: Bool, _ message: String) {
        guard !completed else { return }; completed = true; timeout?.invalidate()
        print("\(success ? "PASS" : "FAIL"): WebKit — \(message)"); fflush(stdout); exit(success ? 0 : 1)
    }
}

@main enum OrbitMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
