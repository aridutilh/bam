import AppKit

/// Sidebar folder commands: create, rename, collapse, move and ungroup.
@MainActor extension BrowserController {
    func connectFolderCommands() {
        sidebar.onToggleFolder = { [weak self] id in self?.toggleFolder(id) }
        sidebar.onRenameFolder = { [weak self] id in self?.renameFolder(id) }
        sidebar.onNewFolder = { [weak self] id in self?.newFolder(around: id) }
        sidebar.onUngroupFolder = { [weak self] id in self?.ungroupFolder(id) }
        sidebar.onMoveToFolder = { [weak self] id, folder in self?.moveToFolder(id, folder: folder) }
        sidebar.folderTargets = { [weak self] id in self?.folderTargets(for: id) ?? [] }
    }
    @objc func newFolder(_ sender: Any?) { newFolder(around: nil) }

    func toggleFolder(_ id: UUID) {
        guard let folder = session.folder(id) else { return }
        cancelPaging()
        session.setFolderCollapsed(id: id, collapsed: !folder.isCollapsed)
        refresh(); save()
    }
    /// From a tab: wrap it in a new folder in place. From a folder: nest a new
    /// folder inside. From nowhere: add a folder at the end of the kept section.
    func newFolder(around id: UUID?) {
        guard !isShuttingDown, let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress()
        var parent: UUID?, items: [UUID] = [], space = session.space
        if let id, let folder = session.folder(id) { parent = folder.id; space = folder.space }
        else if let id, let tab = session.tabs.first(where: { $0.id == id }), !tab.isFavorite {
            items = [id]; space = tab.space; parent = tab.saved?.kind == .kept ? tab.folderID : nil
        }
        promptForFolderName(title: "New Folder", message: items.isEmpty ? "Folders keep related tabs together in this Space." : "The tab moves into the new folder and stays kept.",
                            initial: "New Folder", confirm: "Create Folder", window: window) { [weak self] name in
            guard let self, self.session.createFolder(name: name, space: space, parent: parent, containing: items) != nil else { return false }
            if let parent { self.session.setFolderCollapsed(id: parent, collapsed: false) }
            self.refresh(); self.refreshPaletteResults(); self.save()
            return true
        }
    }
    func renameFolder(_ id: UUID) {
        guard let folder = session.folder(id), let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging()
        promptForFolderName(title: "Rename Folder", message: nil, initial: folder.name, confirm: "Rename", window: window) { [weak self] name in
            guard let self, self.session.renameFolder(id: id, name: name) else { return false }
            self.refresh(); self.save(); return true
        }
    }
    func ungroupFolder(_ id: UUID) {
        cancelPaging()
        guard session.ungroupFolder(id: id) else { return }
        refresh(); save()
    }
    func moveToFolder(_ id: UUID, folder: UUID?) {
        cancelPaging()
        guard session.moveKeptItem(id, into: folder) else { return }
        if let folder { session.setFolderCollapsed(id: folder, collapsed: false) }
        refresh(); refreshPaletteResults(); save()
    }
    /// The current Space's root plus every folder, with invalid targets disabled.
    func folderTargets(for id: UUID) -> [SidebarFolderTarget] {
        let movingFolder = session.folder(id)
        guard let space = movingFolder?.space ?? session.tabs.first(where: { $0.id == id })?.space else { return [] }
        let current = session.container(ofKeptItem: id)
        let rootName = session.spaceDefinition(space)?.name ?? "Space"
        var targets = [SidebarFolderTarget(id: nil, name: "\(rootName) (no folder)", depth: 0,
                                           isEnabled: current != .root(space) && session.canMoveKeptItem(id, into: nil))]
        for entry in session.keptLayout(in: space) where entry.isFolder {
            guard let folder = session.folder(entry.id) else { continue }
            // Disable anything the model would refuse: self/descendant, depth limit, unkeepable pages.
            targets.append(SidebarFolderTarget(id: folder.id, name: folder.name, depth: entry.depth + 1,
                                               isEnabled: current != .folder(folder.id) && session.canMoveKeptItem(id, into: folder.id)))
        }
        _ = movingFolder
        return targets
    }

    /// Asks for a folder name. If the name is refused, the sheet comes back
    /// with the typed text and an explanation rather than losing the input.
    private func promptForFolderName(title: String, message: String?, initial: String, confirm: String,
                                     window: NSWindow, error: String? = nil, commit: @escaping (String) -> Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error ?? message ?? ""
        if error != nil { alert.alertStyle = .warning }
        alert.addButton(withTitle: confirm); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial; field.placeholderString = "Folder name"
        field.setAccessibilityLabel("Folder name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { self.view.window?.makeFirstResponder(self.commandWebView); return }
            let typed = field.stringValue
            if BrowserFolder.validName(typed) != nil, commit(typed) {
                self.view.window?.makeFirstResponder(self.commandWebView); return
            }
            let reason = BrowserFolder.validName(typed) == nil
                ? "Enter a name of up to 120 characters."
                : "Bam couldn’t do that here. Folders can nest \(BrowserSession.maximumFolderDepth) levels deep and hold kept web pages only."
            DispatchQueue.main.async {
                guard let window = self.view.window, window.attachedSheet == nil else { return }
                self.promptForFolderName(title: title, message: message, initial: typed, confirm: confirm, window: window, error: reason, commit: commit)
            }
        }
        DispatchQueue.main.async { field.selectText(nil) }
    }
}
