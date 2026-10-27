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
    var faviconSmoke: WebsiteFaviconSmokeTest?
    var pipSmoke: PictureInPictureSmokeTest?
    var interactionSmoke: InteractionSmokeTest?
    var autoPiPSmoke: AutomaticPiPSmokeTest?
    var profileInstanceSmoke: ProfileInstanceSmokeTest?
    var arcImportSmoke: ArcImportSmokeTest?
    private let externalURLs = ExternalURLDelivery()
    private let profileInstance = ProfileInstance()
    var spacesMenu: NSMenu?
    var onboarding: OnboardingController?
    var settings: SettingsController?
    var extensionsMenu: NSMenu?
    var appearanceMenu: NSMenu?
    private let quitCoordinator = QuitCoordinator()
    private var mainWindowWasClosed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        BamType.registerFonts()
        if CommandLine.arguments.contains("--favicon-test") { faviconSmoke = WebsiteFaviconSmokeTest(); faviconSmoke?.start(); return }
        if CommandLine.arguments.contains("--vendor-extension-probe") { vendorProbe = VendorExtensionProbe(); vendorProbe?.start(); return }
        if CommandLine.arguments.contains("--extension-test") { extensionSmoke = ExtensionRuntimeSmokeTest(); extensionSmoke?.start(); return }
        if CommandLine.arguments.contains("--profile-test") { profileSmoke = ProfileSmokeTest(); profileSmoke?.start(); return }
        if CommandLine.arguments.contains("--profile-instance-test") { profileInstanceSmoke = ProfileInstanceSmokeTest(); profileInstanceSmoke?.start(); return }
        if CommandLine.arguments.contains("--arc-import-test") { arcImportSmoke = ArcImportSmokeTest(); arcImportSmoke?.start(); return }
        if CommandLine.arguments.contains("--resource-test") { resourceSmoke = TabResourceSmokeTest(); resourceSmoke?.start(); return }
        if CommandLine.arguments.contains("--feature-test") { featureSmoke = FeatureSmokeTest(); featureSmoke?.start(); return }
        if CommandLine.arguments.contains("--auto-pip-test") { autoPiPSmoke = AutomaticPiPSmokeTest(); autoPiPSmoke?.start(); return }
        if CommandLine.arguments.contains("--interaction-test") { interactionSmoke = InteractionSmokeTest(); interactionSmoke?.start(); return }
        if CommandLine.arguments.contains("--pip-test") { pipSmoke = PictureInPictureSmokeTest(); pipSmoke?.start(); return }
        if CommandLine.arguments.contains("--web-test") {
            smoke = WebSmokeTest(); smoke?.start(); return
        }
        let launch: PreviewProfile
        do { launch = try PreviewProfile(arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier) }
        catch { fputs("\(error.localizedDescription)\n", stderr); NSApp.terminate(nil); return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(launch.supportDirectoryName, isDirectory: true)
        let preview = launch.isEphemeral
        PreviewIcon.apply(for: launch)
        profileInstance.onActivation = { [weak self] in self?.activateMainWindow() }
        profileInstance.onOpenURLs = { [weak self] urls in self?.receiveExternalURLs(urls) }
        do {
            // This precedes all session/preferences/controller/store access.
            // Persistent development previews lock their own isolated profile.
            guard try profileInstance.start(in: support, ephemeral: preview) else {
                profileInstance.beginHandoff(completed: { exit(0) }, failed: {
                    let alert = NSAlert()
                    alert.messageText = "Bam couldn’t hand this launch to its running window"
                    alert.informativeText = "The running Bam did not confirm receipt. Try opening the link again after that window is ready."
                    alert.addButton(withTitle: "Quit This Launch")
                    alert.runModal()
                    exit(1)
                })
                externalURLs.connect { [weak self] urls in self?.profileInstance.forwardURLs(urls) }
                return
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Bam couldn’t open this profile safely"
            alert.informativeText = "The profile lock could not be opened. Check access to \(support.path) and try again.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "Quit Bam")
            alert.runModal()
            exit(1)
        }
        let sessionFileExists = FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path)
        if !preview { BrowserController.restoreDefaultSearchEngine() }
        ShortcutStore.shared.configure(persists: !preview)
        // Before any window exists, so every window opens in the chosen appearance.
        BrowserAppearance.restore(persists: !preview)
        if #available(macOS 15.4, *) {
            ExtensionManagement.dress = { BamSheetStyle.dress(window: $0, root: $1) }
            ExtensionManagement.rowView = { BamTableRowView() }
            ExtensionManagement.restyleCell = { $0.font = BamType.sans(12.5); $0.textColor = BamTheme.ink }
            // The Site Access sheet wears the same theme as the extension manager it opens from.
            ExtensionSiteAccessPanel.dress = { BamSheetStyle.dress(window: $0, root: $1) }
            ExtensionSiteAccessPanel.restyle = { BamSheetStyle.restyle($0) }
            ExtensionSiteAccessPanel.restyleCell = { $0.font = BamType.sans(12.5); $0.textColor = BamTheme.ink }
            ExtensionSiteAccessPanel.rowView = { BamTableRowView() }
        }
        BrowserLibrary.dress = { BamSheetStyle.dress(window: $0, root: $1) }
        BrowserLibrary.rowView = { BamTableRowView() }
        controller = BrowserController(sessionURL: support.appendingPathComponent("session.json"), ephemeral: preview)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = launch.windowTitle; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self
        window.isMovableByWindowBackground = false; window.minSize = NSSize(width: 760, height: 540)
        window.backgroundColor = BrowserChrome.windowBackground
        window.contentViewController = controller
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window.setContentSize(NSSize(width: min(1260, available.width - 60), height: min(800, available.height - 60)))
        window.center()
        if !preview { window.setFrameAutosaveName(launch.windowAutosaveName) }
        // The window follows NSApp.appearance (View ▸ Appearance / Settings).
        controller.onSpacesChanged = { [weak self] in
            self?.rebuildSpacesMenu()
            if self?.settings?.window.isVisible == true { self?.settings?.refresh() }
        }
        buildMenus(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyShortcuts() }
        }
        NotificationCenter.default.addObserver(forName: BrowserAppearance.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceDidChange() }
        }
        ShortcutStore.shared.reservedOwner = { [weak self] combo in self?.fixedMenuItem(wearing: combo)?.title }
        externalURLs.connect { [weak self] urls in
            for url in urls { self?.controller?.openLittleOrbit(url: url) }
        }
        // Development extension tests start at the browser without importing
        // favorites or changing the default browser through first-run setup.
        // The welcome remains available explicitly from the menu or flag.
        guard !launch.isPersistentPreview || CommandLine.arguments.contains("--onboarding") else { return }
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
    @objc func showSettings(_ sender: Any?) { presentSettings(section: settings?.window.isVisible == true ? settings!.section : .general) }
    func presentSettings(section: SettingsSection) {
        guard let controller, onboarding == nil else { return }
        if settings == nil {
            settings = SettingsController(snapshot: { [weak self] in self?.controller?.settingsSnapshot() ?? SettingsSnapshot() },
                                          actions: controller.settingsActions(showWelcome: { [weak self] in
                                              self?.settings?.window.orderOut(nil); self?.presentOnboarding()
                                          }))
        }
        settings?.show(section: section, relativeTo: window)
    }
    func presentOnboarding() {
        guard onboarding == nil, let controller, let window, window.attachedSheet == nil else { return }
        controller.setOnboardingActive(true)
        // Only offered when Arc's own layout file is there; the import itself is Bam's previewed sheet.
        var model = OnboardingModel(bookmarks: ChromeBookmarks.load(from: ChromeBookmarks.defaultStoreURL()),
                                    arcAvailable: FileManager.default.isReadableFile(atPath: ArcImport.defaultSourceURL().path))
        if let first = controller.session.spaces.first {
            model.colorIndex = first.colorIndex; model.spaceName = first.name; model.spaceSymbol = first.symbol
        }
        let welcome = OnboardingController(model: model)
        var followUps: [OnboardingFollowUp] = []
        welcome.onApply = { [weak self] result in self?.controller?.applyOnboarding(result); followUps = result.followUps }
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
            // What the person chose during setup, opened now that the window is theirs again.
            self.runOnboardingFollowUps(followUps)
        }
        onboarding = welcome
        welcome.present(over: window)
    }
    /// Runs setup's choices in order. Arc's import sheet holds the window, so whatever follows waits
    /// until that sheet ends (imported or cancelled), or runs at once if the sheet couldn't open.
    private func runOnboardingFollowUps(_ queue: [OnboardingFollowUp]) {
        guard let controller, let next = queue.first else { return }
        let rest = Array(queue.dropFirst())
        switch next {
        case .importFromArc:
            if let importer = controller.presentArcImport(initialSourceURL: ArcImport.defaultSourceURL()) {
                let ended = importer.onDismiss
                importer.onDismiss = { [weak self] in
                    ended?()
                    DispatchQueue.main.async { self?.runOnboardingFollowUps(rest) }
                }
            } else { runOnboardingFollowUps(rest) }
        case .findExtension(let name):
            if #available(macOS 15.4, *) {
                controller.browserExtensions.showLibrary(profileID: controller.commandProfileID, relativeTo: window, query: name)
            }
            runOnboardingFollowUps(rest)
        case .none:
            runOnboardingFollowUps(rest)
        }
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
            // Asked unless the person chose "don't ask again" (Settings › General restores it).
            let preference = QuitConfirmationPreference()
            guard preference.asksBeforeQuitting else { return true }
            sender.activate(ignoringOtherApps: true)
            let choice = QuitConfirmationPanel.run(over: self.window, appName: QuitConfirmationModel.appName(info: Bundle.main.infoDictionary),
                                                   icon: NSApp.applicationIconImage)
            return QuitConfirmationModel.resolve(choice, preference: preference, persist: controller.privateMode != true)
        }, save: {
            await controller.flushSessionForTermination()
        }, saveFailure: {
            let alert = NSAlert()
            alert.messageText = "Your latest browsing changes haven’t been saved"
            alert.informativeText = "Bam couldn’t finish saving your tabs or history. You can stay in the browser, retry, or quit without the latest changes."
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
        receiveExternalURLs(urls)
    }
    private func receiveExternalURLs(_ urls: [URL]) {
        externalURLs.receive(urls.filter { URLInput.directURL($0.absoluteString) != nil })
    }
    private func activateMainWindow() {
        ProfileInstance.activate(window: window)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { activateMainWindow(); return true }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === extensionsMenu { controller?.updateExtensionsMenu(menu) }
    }
    @objc func selectSpace(_ sender: NSMenuItem) { controller.changeSpace(sender.tag) }
    var boundItems: [ShortcutCommand: NSMenuItem] = [:]
    /// A menu item outside the remappable set whose key equivalent is this chord.
    func fixedMenuItem(wearing combo: KeyCombo, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if let hit = fixedMenuItem(wearing: combo, in: item.submenu) { return hit }
            guard !item.keyEquivalent.isEmpty, !boundItems.values.contains(where: { $0 === item }) else { continue }
            if KeyCombo(item.keyEquivalent, item.keyEquivalentModifierMask) == combo { return item }
        }
        return nil
    }
    /// Settings changed a shortcut: the menu items pick up the new chord at once.
    func applyShortcuts() {
        for (command, item) in boundItems {
            let combo = ShortcutStore.shared.combo(for: command)
            item.keyEquivalent = combo.key; item.keyEquivalentModifierMask = combo.modifiers
        }
    }
    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = BrowserAppearance(rawValue: raw) else { return }
        BrowserAppearance.apply(choice)
    }
    /// Keeps the View ▸ Appearance checkmark and an open Settings window in step.
    func appearanceDidChange() {
        for entry in appearanceMenu?.items ?? [] {
            entry.state = (entry.representedObject as? String) == BrowserAppearance.current.rawValue ? .on : .off
        }
        // In place, so a keyboard user on the Appearance chips keeps focus.
        settings?.syncAppearance()
    }
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
    @objc func recordSpaceSwipes(_ sender: Any?) { SpaceSwipeDiagnostics.shared.start() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectSpace(_:)) {
            menuItem.state = controller?.session.space == menuItem.tag ? .on : .off
            return controller?.session.spaceDefinition(menuItem.tag) != nil && window?.attachedSheet == nil
        }
        if menuItem.action == #selector(recordSpaceSwipes(_:)) {
            return !SpaceSwipeDiagnostics.shared.isRecording && !SpaceSwipeDiagnostics.shared.isStarting
        }
        if menuItem.action == #selector(showWelcome(_:)) {
            return onboarding == nil && controller != nil && window?.attachedSheet == nil && window?.isVisible == true
        }
        if menuItem.action == #selector(showSettings(_:)) || menuItem.action == #selector(showAbout(_:)) {
            return onboarding == nil && controller != nil
        }
        return true
    }
    @objc func showAbout(_ sender: Any?) { presentSettings(section: .about) }
    func buildMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); main.addItem(item); let sub = NSMenu(title: title); item.submenu = sub; return sub }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, _ target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        // Remappable commands read their chord from ShortcutStore; applyShortcuts re-reads it on change.
        func bound(_ menu: NSMenu, _ title: String, _ action: Selector, _ command: ShortcutCommand, _ target: AnyObject? = nil) {
            let combo = ShortcutStore.shared.combo(for: command)
            item(menu, title, action, combo.key, combo.modifiers, target)
            boundItems[command] = menu.items.last
        }
        let app = menu("Bam")
        item(app, "About Bam", #selector(showAbout), "", .command, self)
        item(app, "Welcome to Bam…", #selector(showWelcome), "", .command, self)
        app.addItem(.separator()); bound(app, "Settings…", #selector(showSettings), .settings, self)
        app.addItem(.separator()); item(app, "Hide Bam", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); item(app, "Quit Bam", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New Little Bam Window", #selector(BrowserController.newLittleOrbit(_:)), "n", [.command, .option], controller)
        bound(file, "New Tab", #selector(BrowserController.newTab(_:)), .newTab, controller)
        bound(file, "Open Location…", #selector(BrowserController.focusAddress(_:)), .openLocation, controller)
        item(file, "Close Tab", #selector(BrowserController.closeTab(_:)), "w", .command, controller)
        item(file, "Reopen Closed Tab", #selector(BrowserController.reopenTab(_:)), "t", [.command, .shift], controller)
        file.addItem(.separator()); item(file, "Import from Arc…", #selector(BrowserController.importFromArc(_:)), "", .command, controller)
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
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for choice in BrowserAppearance.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = choice.rawValue
            entry.state = choice == BrowserAppearance.current ? .on : .off
            appearanceMenu.addItem(entry)
        }
        appearanceItem.submenu = appearanceMenu; view.addItem(appearanceItem); self.appearanceMenu = appearanceMenu
        item(view, "Focus Sidebar", #selector(BrowserController.focusSidebar(_:)), "s", [.command, .control], controller)
        view.addItem(.separator())
        bound(view, "Toggle Sidebar", #selector(BrowserController.toggleSidebar(_:)), .toggleSidebar, controller)
        item(view, "Reset Sidebar Width", #selector(BrowserController.resetSidebar(_:)), "s", [.command, .shift], controller)
        bound(view, "Keep / Unkeep Tab", #selector(BrowserController.togglePin(_:)), .keepTab, controller)
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
        history.addItem(.separator())
        item(history, "Show History…", #selector(BrowserController.showHistory(_:)), "y", .command, controller)
        item(history, "Recently Closed…", #selector(BrowserController.showArchive(_:)), "", .command, controller)
        item(view, "Downloads…", #selector(BrowserController.showDownloads(_:)), "j", .command, controller)
        let tabs = menu("Tabs")
        item(tabs, "Next Tab", #selector(BrowserController.nextTab(_:)), "\t", .control, controller)
        item(tabs, "Previous Tab", #selector(BrowserController.previousTab(_:)), "\t", [.control, .shift], controller)
        let goToTab = NSMenuItem(title: "Go to Tab", action: nil, keyEquivalent: "")
        let tabNumbers = NSMenu(title: "Go to Tab"); goToTab.submenu = tabNumbers; tabs.addItem(goToTab)
        for number in 1...9 {
            let entry = NSMenuItem(title: number == 9 ? "Last Tab" : "Tab \(number)", action: #selector(BrowserController.selectTabByNumber(_:)), keyEquivalent: String(number))
            entry.keyEquivalentModifierMask = .command; entry.tag = number; entry.target = controller; tabNumbers.addItem(entry)
        }
        bound(tabs, "Next Space", #selector(BrowserController.nextSpace(_:)), .nextSpace, controller)
        bound(tabs, "Previous Space", #selector(BrowserController.previousSpace(_:)), .previousSpace, controller)
        tabs.addItem(.separator())
        item(tabs, "New Folder…", #selector(BrowserController.newFolder(_:)), "", .command, controller)
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
        ProfileInstanceSmokeTest.runChildIfRequested() // Fixture duplicates exit before NSApplication.
        ContentBlocking.runCompilerIfRequested() // The ad blocker's list compiler exits before NSApplication too.
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
