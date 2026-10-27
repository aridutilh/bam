import AppKit
import WebKit

/// Arc's per-tab actions: Copy Link, Rename…, Mute, Duplicate and Close Tabs
/// Below (Arc's "Archive Tabs Below"). Each acts on the tab a menu item names
/// (its `representedObject` UUID, for a sidebar row's menu) or else on the
/// focused tab (the Tabs menu, the command palette).
@MainActor extension BrowserController {
    private func actionTabID(_ sender: Any?) -> UUID? {
        if let id = (sender as? NSMenuItem)?.representedObject as? UUID, session.tabs.contains(where: { $0.id == id }) { return id }
        guard NSApp.keyWindow === view.window || NSApp.keyWindow == nil || addressOverlay != nil else { return nil }
        return session.tabs.contains(where: { $0.id == focusedTabID }) ? focusedTabID : nil
    }

    // MARK: Duplicate

    @objc func duplicateTab(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        duplicate(tabID: id)
    }
    /// The copy opens just below and is selected, carrying the page's back/forward
    /// history and scroll position when the original page is live.
    @discardableResult func duplicate(tabID id: UUID) -> UUID? {
        cancelPaging(); dismissAddress()
        let source = browsers[id]
        guard let copy = session.duplicate(id: id), let tab = session.tabs.first(where: { $0.id == copy }) else { NSSound.beep(); return nil }
        let web = webView(for: tab)
        if let state = source?.interactionState { web.interactionState = state }
        showActive(); save()
        return copy
    }

    // MARK: Rename

    @objc func renameTab(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        presentRename(for: id)
    }
    /// Arc renames in place; until the sidebar row can edit inline this asks in
    /// a sheet. Leaving the name empty goes back to the page's own title.
    func presentRename(for id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }), let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress()
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave it empty to use the page’s own title."
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = tab.displayTitle; field.placeholderString = tab.title
        field.setAccessibilityLabel("Tab name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.view.window?.makeFirstResponder(self.commandWebView) }
            guard response == .alertFirstButtonReturn else { return }
            if self.session.renameTab(id: id, title: String(field.stringValue.prefix(80))) {
                self.refresh(); self.refreshPaletteResults(); self.save()
            } else { NSSound.beep() }
        }
        DispatchQueue.main.async { field.selectText(nil) }
    }

    // MARK: Mute

    @objc func toggleMuteTab(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        setTab(id, muted: !isTabMuted(id))
    }
    func isTabMuted(_ id: UUID) -> Bool { tabNavigation.mutedTabs.contains(session.split(for: id)?.primaryID ?? id) }
    /// True while the tab's page (either Split pane) is making sound.
    func isTabPlayingAudio(_ id: UUID) -> Bool {
        let members = session.split(for: id).map { [$0.primaryID, $0.secondaryID] } ?? [id]
        return members.contains { browsers[$0].map(Self.isPlayingAudio) ?? false }
    }
    func setTab(_ id: UUID, muted: Bool) {
        let primary = session.split(for: id)?.primaryID ?? id
        let members = session.split(for: id).map { [$0.primaryID, $0.secondaryID] } ?? [id]
        var applied = false
        for member in members { if let web = browsers[member], Self.setPageMuted(muted, in: web) { applied = true } }
        guard applied || !muted else { NSSound.beep(); return }
        if muted { tabNavigation.mutedTabs.insert(primary) } else { tabNavigation.mutedTabs.remove(primary) }
        refresh()
    }
    /// A page that is created again (woken from sleep, re-rendered) keeps its tab's mute.
    func reapplyMute(_ web: WKWebView, id: UUID) {
        if isTabMuted(id) { _ = Self.setPageMuted(true, in: web) }
    }
    /// WebKit has no public page mute; `_setPageMuted:` (WKMediaMutedState,
    /// audio = 1) has shipped since macOS 10.13. Guarded, so a WebKit without
    /// it simply leaves Mute unavailable.
    static func setPageMuted(_ muted: Bool, in web: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard web.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(web.method(for: selector), to: Setter.self)(web, selector, muted ? 1 : 0)
        return true
    }
    static func isPlayingAudio(_ web: WKWebView) -> Bool {
        guard web.responds(to: NSSelectorFromString("_isPlayingAudio")) else { return false }
        return (web.value(forKey: "_isPlayingAudio") as? Bool) ?? false
    }

    // MARK: Close Tabs Below

    @objc func closeTabsBelow(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        closeTabs(below: id)
    }
    /// Closes the Today tabs under this one, bottom first, so ⌘Z / ⇧⌘T bring
    /// back the nearest first. The selection moves to this tab if it was below.
    func closeTabs(below id: UUID) {
        let doomed = session.todayTabs(below: id)
        guard !doomed.isEmpty else { NSSound.beep(); return }
        let anchor = session.split(for: id)?.primaryID ?? id
        if doomed.contains(session.activeID) { select(anchor) }
        for victim in doomed.reversed() where session.tabs.contains(where: { $0.id == victim }) { close(victim) }
    }

    // MARK: Copy Link

    @objc func copyTabLink(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        if id == focusedTabID, (sender as? NSMenuItem)?.representedObject == nil { copyCurrentURL(sender); return }
        copyLink(ofTab: id)
    }
    /// The tab's page address, cleaned of tracking parameters as Copy Link does.
    func copyLink(ofTab id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        let url = browsers[id].flatMap(cleanLink(for:)) ?? URLInput.directURL(tab.address).map(CleanLinks.clean)
        guard let url else { NSSound.beep(); return }
        pageCommandPasteboard.clearContents()
        guard pageCommandPasteboard.setString(url.absoluteString, forType: .string) else { return }
        pageFeedback.show("Link copied", symbol: "link", in: webHost)
    }

    // MARK: Change Icon / edit

    @objc func changeTabIcon(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        editTab(id)
    }
    /// Arc's Change Icon…: name and icon for any tab, in the sheet kept tabs already use.
    func editTab(_ id: UUID) {
        guard !isShuttingDown, savedTabEditor == nil, let tab = session.tabs.first(where: { $0.id == id }),
              let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress(); findBar.hide(); pageFeedback.hide()
        let editor = SavedTabEditorController(tab: tab)
        savedTabEditor = editor
        editor.onSave = { [weak self] title, symbol in
            guard let self, self.session.updateTab(id: id, customTitle: title, customSymbol: symbol) else { return false }
            self.refresh(); self.refreshPaletteResults(); self.save()
            return true
        }
        editor.onDismiss = { [weak self] in
            guard let self else { return }
            self.savedTabEditor = nil
            self.view.window?.makeFirstResponder(self.commandWebView)
        }
        editor.present(on: window)
        window.attachedSheet?.makeFirstResponder(editor.iconPicker)
    }

    // MARK: Move to

    @objc func moveTabToSpace(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let id = item.representedObject as? UUID else { return }
        cancelPaging()
        if moveTab(id, toSpace: item.tag) { refresh(); refreshPaletteResults(); save() } else { NSSound.beep() }
    }
    /// Arc's "New Space…": make a Space, and the tab moves into it once it exists.
    @objc func moveTabToNewSpace(_ sender: Any?) {
        guard let id = actionTabID(sender) else { NSSound.beep(); return }
        openSpaceCreation()
        if spaceCreationPanel != nil { tabNavigation.pendingMoveToNewSpace = id }
    }
    /// Called by Space creation with the new Space, before it is shown.
    func finishPendingMove(toNewSpace space: Int) {
        guard let id = tabNavigation.pendingMoveToNewSpace else { return }
        tabNavigation.pendingMoveToNewSpace = nil
        if session.tabs.contains(where: { $0.id == id }) { _ = moveTab(id, toSpace: space) }
    }

    // MARK: Menus

    /// Ready-made items for a sidebar tab row's menu, in Arc's order (Copy Link,
    /// Share ▸; Change Icon…, Rename…, Mute; Duplicate). Move to ▸ and the
    /// archive pair come separately. Each targets this controller with the row's ID.
    func tabActionMenuItems(for id: UUID) -> [NSMenuItem] {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return [] }
        func entry(_ title: String, _ action: Selector, _ symbol: String, key: String = "", enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = [.command, .shift] }
            item.target = self; item.representedObject = id; item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        let muted = isTabMuted(id)
        return [
            entry("Copy Link", #selector(copyTabLink(_:)), "link", key: "c", enabled: URLInput.directURL(tab.address) != nil),
            shareMenuItem(for: id),
            .separator(),
            entry("Change Icon…", #selector(changeTabIcon(_:)), "face.smiling"),
            entry("Rename…", #selector(renameTab(_:)), "pencil"),
            entry(muted ? "Unmute" : "Mute", #selector(toggleMuteTab(_:)), muted ? "speaker.wave.2" : "speaker.slash",
                  enabled: muted || isTabPlayingAudio(id)),
            .separator(),
            entry("Duplicate", #selector(duplicateTab(_:)), "plus.square.on.square", enabled: !tab.isArcEasel && URLInput.extensionURL(tab.address) == nil)
        ]
    }
    /// Share ▸ (the system share menu: AirDrop, Mail, Messages, Notes…) for the tab's page.
    func shareMenuItem(for id: UUID) -> NSMenuItem {
        guard let tab = session.tabs.first(where: { $0.id == id }),
              let url = browsers[id].flatMap(cleanLink(for:)) ?? URLInput.directURL(tab.address).map(CleanLinks.clean) else {
            let item = NSMenuItem(title: "Share", action: nil, keyEquivalent: ""); item.isEnabled = false; return item
        }
        let item = NSSharingServicePicker(items: [url]).standardShareMenuItem
        item.title = "Share"
        return item
    }
    /// Arc's "Move to ▸": every Space (this one ticked), then "New Space…".
    func moveToMenuItem(for id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Move to"); menu.autoenablesItems = false
        guard let tab = session.tabs.first(where: { $0.id == id }) else { item.isEnabled = false; return item }
        let current = tab.isFavorite ? session.space : tab.space
        for space in session.spaces {
            let entry = NSMenuItem(title: space.name, action: #selector(moveTabToSpace(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = id; entry.tag = space.id
            entry.state = space.id == current ? .on : .off
            entry.isEnabled = space.id != current && !tab.isFavorite
            entry.image = ArkSpaceIcon.image(for: space, pointSize: 14)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New Space…", action: #selector(moveTabToNewSpace(_:)), keyEquivalent: "")
        new.target = self; new.representedObject = id
        new.isEnabled = !tab.isFavorite && session.spaces.count < BrowserSession.maximumSpaces && !isPrivateWindow
        menu.addItem(new)
        item.submenu = menu
        return item
    }
    /// "Close Tabs Below" for a Today row's menu, next to Close Tab.
    func closeTabsBelowMenuItem(for id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: "Close Tabs Below", action: #selector(closeTabsBelow(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = id
        item.isEnabled = !session.todayTabs(below: id).isEmpty
        return item
    }

    /// Enables and titles the Tabs-menu entries for the focused tab.
    func validateTabActionItem(_ item: NSMenuItem) -> Bool? {
        let id = (item.representedObject as? UUID) ?? focusedTabID
        switch item.action {
        case #selector(toggleMuteTab(_:)):
            let muted = isTabMuted(id)
            item.title = item.representedObject == nil ? (muted ? "Unmute Tab" : "Mute Tab") : (muted ? "Unmute" : "Mute")
            return muted || isTabPlayingAudio(id)
        case #selector(duplicateTab(_:)):
            guard let tab = session.tabs.first(where: { $0.id == id }) else { return false }
            return !tab.isArcEasel && URLInput.extensionURL(tab.address) == nil
        case #selector(renameTab(_:)):
            return session.tabs.contains { $0.id == id } && view.window?.attachedSheet == nil
        case #selector(closeTabsBelow(_:)):
            return !session.todayTabs(below: id).isEmpty
        case #selector(changeTabIcon(_:)):
            return session.tabs.contains { $0.id == id } && view.window?.attachedSheet == nil && savedTabEditor == nil
        case #selector(copyTabLink(_:)):
            return session.tabs.first { $0.id == id }.flatMap { URLInput.directURL($0.address) } != nil
        default: return nil
        }
    }
}
