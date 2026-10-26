import AppKit

/// The browser's side of Settings: a fresh snapshot on demand and actions
/// that reuse the same code paths as the menu toggles, so the two never disagree.
@MainActor extension BrowserController {
    func settingsSnapshot() -> SettingsSnapshot {
        var snapshot = SettingsSnapshot()
        snapshot.showsPlayingVideo = automaticallyShowsVideo
        snapshot.sleepsIdlePages = automaticTabSleeping
        snapshot.keepAwakeHost = currentSleepProtectionHost
        snapshot.keepsCurrentSiteAwake = currentSleepProtectionHost.map { keepAwakeHosts.contains($0) } ?? false
        snapshot.asksBeforeQuitting = QuitConfirmationPreference().asksBeforeQuitting
        snapshot.canChangeQuitPreference = !privateMode
        snapshot.searchEngine = URLInput.searchEngine
        snapshot.appearance = BrowserAppearance.current
        snapshot.spaces = session.spaces
        snapshot.currentSpaceID = session.space
        snapshot.profileName = session.profileName(commandProfileID)
        if #available(macOS 15.4, *) {
            snapshot.extensions = browserExtensions.items(profileID: commandProfileID)
                .map { SettingsExtensionItem(name: $0.name, version: $0.version, enabled: $0.enabled) }
        }
        snapshot.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        snapshot.build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return snapshot
    }

    func settingsActions(showWelcome: @escaping () -> Void) -> SettingsActions {
        var actions = SettingsActions()
        actions.setShowsPlayingVideo = { [weak self] on in
            guard let self, self.automaticallyShowsVideo != on else { return }
            self.toggleAutomaticVideo(nil)
        }
        actions.setSleepsIdlePages = { [weak self] on in
            guard let self, self.automaticTabSleeping != on else { return }
            self.toggleAutomaticTabSleeping(nil)
        }
        actions.setKeepsSiteAwake = { [weak self] host, on in self?.setKeepAwake(host: host, on) }
        // Like the quit dialog's "don't ask again": a private window never changes the normal preference.
        actions.setAsksBeforeQuitting = { [weak self] on in
            guard let self, !self.privateMode else { return }
            QuitConfirmationPreference().asksBeforeQuitting = on
        }
        actions.setSearchEngine = { [weak self] engine in self?.setDefaultSearchEngine(engine) }
        actions.editSpace = { [weak self] space in self?.editSpace(space) ?? false }
        actions.switchSpace = { [weak self] id in self?.changeSpace(id) }
        actions.manageSpaces = { [weak self] in self?.manageSpaces(nil) }
        actions.manageExtensions = { [weak self] in self?.manageExtensions(nil) }
        actions.showWelcome = showWelcome
        actions.setAppearance = { BrowserAppearance.apply($0) }
        actions.importFromArc = { [weak self] in
            self?.view.window?.makeKeyAndOrderFront(nil)
            self?.importFromArc(nil)
        }
        actions.openURL = { [weak self] url in
            guard let self, URLInput.directURL(url.absoluteString) != nil else { return }
            self.cancelPaging(); self.dismissAddress()
            self.session.add(address: url.absoluteString); self.showActive(); self.save()
            self.view.window?.makeKeyAndOrderFront(nil)
        }
        return actions
    }

    /// The Settings row names a host; protect exactly that one, whatever tab is active now.
    func setKeepAwake(host: String, _ on: Bool) {
        guard keepAwakeHosts.contains(host) != on else { return }
        if on { keepAwakeHosts.insert(host) } else { keepAwakeHosts.remove(host) }
        if !privateMode { UserDefaults.standard.set(keepAwakeHosts.sorted(), forKey: "KeepAwakeHosts") }
    }
    func setDefaultSearchEngine(_ engine: DefaultSearchEngine) {
        URLInput.searchEngine = engine
        if !privateMode { UserDefaults.standard.set(engine.rawValue, forKey: DefaultSearchEngine.defaultsKey) }
    }
    static func restoreDefaultSearchEngine() {
        if let raw = UserDefaults.standard.string(forKey: DefaultSearchEngine.defaultsKey), let engine = DefaultSearchEngine(rawValue: raw) {
            URLInput.searchEngine = engine
        }
    }

    /// Applies one Space's name, icon and color through the same staged plan
    /// Manage Spaces uses, so validation and profile handling stay identical.
    @discardableResult func editSpace(_ space: BrowserSpace) -> Bool {
        guard let name = BrowserSpace.validName(space.name), BrowserSpace.symbols.contains(space.symbol),
              BrowserSpace.colorNames.indices.contains(space.colorIndex),
              let index = session.spaces.firstIndex(where: { $0.id == space.id }) else { return false }
        var spaces = session.spaces
        spaces[index].name = name; spaces[index].symbol = space.symbol; spaces[index].colorIndex = space.colorIndex
        return applySpaceEdits(SpaceEditPlan(originalIDs: Set(session.spaceIDs), spaces: spaces))
    }
}
