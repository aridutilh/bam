import AppKit
import WebKit

/// A store is chosen before constructing a web view. Sharing a profile means
/// sharing this same store, including in nonpersistent previews.
@MainActor final class WebsiteProfileStore {
    let ephemeral: Bool
    private var stores: [UUID: WKWebsiteDataStore] = [:]
    init(ephemeral: Bool) { self.ephemeral = ephemeral }
    func store(for profileID: UUID) -> WKWebsiteDataStore {
        if let existing = stores[profileID] { return existing }
        let store: WKWebsiteDataStore
        if ephemeral { store = .nonPersistent() }
        else if profileID == BrowserProfile.defaultID { store = .default() }
        else { store = WKWebsiteDataStore(forIdentifier: profileID) }
        stores[profileID] = store
        return store
    }
    func profileID(for store: WKWebsiteDataStore) -> UUID? {
        if let match = stores.first(where: { $0.value === store })?.key { return match }
        if !ephemeral, let identifier = store.identifier, stores[identifier] != nil { return identifier }
        return nil
    }
}

@MainActor extension BrowserController {
    var commandProfileID: UUID {
        if let web = littleWindows.values.first(where: { $0.window?.isKeyWindow == true })?.webView,
           let profile = profileID(of: web) { return profile }
        return session.currentProfileID
    }
    func profileID(of web: WKWebView) -> UUID? {
        if let profile = profileStores.profileID(for: web.configuration.websiteDataStore) { return profile }
        if let id = browsers.first(where: { $0.value === web })?.key,
           let tab = session.tabs.first(where: { $0.id == id }) { return session.profileID(for: tab) }
        return nil
    }
    @discardableResult func openProfileTab(_ url: URL, profileID: UUID, active: Bool) -> UUID? {
        guard URLInput.directURL(url.absoluteString) != nil || allowsExtensionPage(url, profileID: profileID) else { return nil }
        let previousSpace = session.space, previousTab = session.activeID
        guard selectSpace(forProfile: profileID) else { return nil }
        let id = session.add(address: url.absoluteString)
        if active { select(id); view.window?.makeKeyAndOrderFront(nil) }
        else {
            session.changeSpace(previousSpace); session.select(previousTab)
            if let tab = session.tabs.first(where: { $0.id == id }) { _ = webView(for: tab) }
            refresh(); save()
        }
        return id
    }
    func library(for profileID: UUID) -> BrowserLibrary {
        if let existing = profileLibraries[profileID] {
            existing.profileName = session.profileName(profileID)
            return existing
        }
        let directory = sessionURL.deletingLastPathComponent()
        let url = profileID == BrowserProfile.defaultID ? directory.appendingPathComponent("library.json")
            : directory.appendingPathComponent("Profiles/\(profileID.uuidString)/library.json")
        let value = BrowserLibrary(storageURL: privateMode ? nil : url)
        value.profileName = session.profileName(profileID)
        value.onOpenURL = { [weak self] address in
            guard let self, self.selectSpace(forProfile: profileID) else { return }
            self.cancelPaging(); self.dismissAddress()
            self.session.add(address: address); self.showActive(); self.save()
        }
        value.onRestoreClosed = { [weak self] record in
            guard let self, self.selectSpace(forProfile: profileID) else { return }
            self.restoreClosed(record, profileID: profileID)
        }
        profileLibraries[profileID] = value
        return value
    }
    /// Floating windows retain their originating sign-in even after the main
    /// browser switches Spaces. Promotion must return to that profile too.
    @discardableResult func selectSpace(forProfile profileID: UUID) -> Bool {
        if session.currentProfileID == profileID { return true }
        guard session.profiles.contains(where: { $0.id == profileID }) else { return false }
        guard let space = session.spaceID(forProfile: profileID) ?? session.createSpace(name: session.profileName(profileID), symbol: "briefcase", colorIndex: 0, profileID: profileID) else { return false }
        session.changeSpace(space)
        onSpacesChanged?()
        return true
    }
    @discardableResult func applyProfileAwareSession(_ proposed: BrowserSession, rebase: ((BrowserSession) -> BrowserSession?)? = nil) -> Bool {
        var updated = proposed
        let oldTabs = Dictionary(session.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = updated.tabs.filter { tab in
            guard let old = oldTabs[tab.id] else { return false }
            return session.profileID(for: old) != updated.profileID(for: tab)
        }.map(\.id)
        let live = changed.filter { browsers[$0] != nil || peeks[$0]?.isPresented == true }
        if !live.isEmpty {
            let message = "Changing the login profile reloads \(live.count == 1 ? "this page" : "these \(live.count) pages") with the destination profile’s cookies and logins. Unsaved page edits and playback won’t carry over. Your previous profile’s saved logins are kept."
            let accepted: Bool
            if let confirmProfileChange { accepted = confirmProfileChange(message) }
            else {
                let alert = NSAlert(); alert.messageText = "Reload pages in a different profile?"
                alert.informativeText = message
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reload Pages")
                accepted = runProfileAlert(alert) == .alertSecondButtonReturn
            }
            guard accepted else { return false }
        }
        // The native confirmation pumps a nested run loop. Preserve metadata
        // and tabs that arrived while it was open instead of restoring a stale copy.
        if let rebase {
            guard let latest = rebase(session) else { return false }; updated = latest
        } else {
            let currentTabs = Dictionary(session.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in updated.tabs.indices {
                let id = updated.tabs[index].id
                guard let old = oldTabs[id], let current = currentTabs[id] else { continue }
                if updated.tabs[index].address == old.address { updated.tabs[index].address = current.address }
                if updated.tabs[index].title == old.title { updated.tabs[index].title = current.title }
            }
            let known = Set(updated.tabs.map(\.id))
            updated.tabs += session.tabs.filter { oldTabs[$0.id] == nil && !known.contains($0.id) }
        }
        let latestChanged = updated.tabs.filter { tab in
            guard let current = session.tabs.first(where: { $0.id == tab.id }) else { return false }
            return session.profileID(for: current) != updated.profileID(for: tab)
        }.map(\.id)
        // If another loaded page arrived, the earlier decision didn't cover it.
        // Keep the staged editor open rather than discarding new work silently.
        guard !latestChanged.contains(where: { !live.contains($0) && (browsers[$0] != nil || peeks[$0]?.isPresented == true) }) else { return false }
        cancelPaging(); cancelAutomaticDepartures(); findBar.hide(); pageFeedback.hide()
        // Remove old identities before PiP restoration can re-enter showActive.
        // The updated model is installed only after the previous page is retired.
        isApplyingProfileChange = true
        for id in latestChanged { retireProfilePage(id) }
        session = updated
        for id in latestChanged {
            if let index = session.tabs.firstIndex(where: { $0.id == id }) { session.tabs[index].sleepState = nil }
        }
        isApplyingProfileChange = false
        showActive(); refreshPaletteResults(); save(); onSpacesChanged?()
        return true
    }
    func runProfileAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let cancel = alert.buttons[0]
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === alert.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            cancel.performClick(nil); return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }
    func retireProfilePage(_ id: UUID) {
        peeks[id]?.dismiss()
        if let group = session.split(for: id), let split = splitCoordinators.removeValue(forKey: group.primaryID) {
            split.detach(); split.view.removeFromSuperview()
            retiringViews.removeValue(forKey: ObjectIdentifier(split.view))
        }
        navigationTokens.removeValue(forKey: id); browserExtensionOrigins.removeValue(forKey: id)
        observations.removeValue(forKey: id)
        let web = browsers.removeValue(forKey: id)
        if let web {
            tabActivityProbe.invalidate(web)
            web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading()
            if pictureInPicture.references(web) { pictureInPicture.restore() }
            web.pauseAllMediaPlayback(completionHandler: nil)
            retiringViews.removeValue(forKey: ObjectIdentifier(web)); web.removeFromSuperview()
        }
        pendingHome.remove(id); pendingLoads.remove(id); requestedAddresses.removeValue(forKey: id)
        tabErrors.removeValue(forKey: id); tabLastUsed.removeValue(forKey: id)
        sleepRestores.removeValue(forKey: id); nonGetDocuments.remove(id); pendingNonGetDocuments.removeValue(forKey: id)
        displayedMemberIDs.removeAll { $0 == id }
        if displayedTabID == id { displayedTabID = nil }
    }
}
