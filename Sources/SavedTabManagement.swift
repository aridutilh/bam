import AppKit

@MainActor extension BrowserController {
    @objc func toggleFavorite(_ sender: Any?) { favoriteTab(focusedTabID) }
    @objc func editCurrentSavedTab(_ sender: Any?) { editSavedTab(focusedTabID) }
    @objc func resetCurrentSavedTab(_ sender: Any?) { resetSavedTab(focusedTabID) }

    func favoriteTab(_ id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        cancelPaging()
        guard session.setRetention(id: id, kind: tab.isFavorite ? nil : .favorite) else {
            if session.favoriteTabs.count >= 12 {
                pageFeedback.show("12 Favorites maximum", symbol: "star", in: webHost)
            }
            return
        }
        refresh(); refreshPaletteResults(); save()
    }
    func reorderSavedTab(_ id: UUID, by direction: Int) {
        let moved = session.folder(id) != nil ? session.reorderKeptItem(id: id, by: direction) : session.reorderSavedTab(id: id, by: direction)
        guard moved else { return }
        cancelPaging(); refresh(); save()
    }
    func resetSavedTab(_ id: UUID) {
        guard session.tabs.first(where: { $0.id == id })?.isSaved == true else { return }
        cancelPaging(); cancelAutomaticDepartures()
        peeks[session.split(for: id)?.primaryID ?? id]?.dismiss()
        returnPaneVideo(id)
        let existing = browsers[id]
        guard session.resetSavedTab(id: id) else { return }
        selectSearchResult(id)
        // Newly reopened saved tabs load in showActive. A live saved tab keeps
        // its view, but explicitly navigates back to its original saved address.
        if let existing, let tab = session.tabs.first(where: { $0.id == id }) {
            load(tab.address, in: existing, id: id)
        }
        refresh(); save()
    }
    func editSavedTab(_ id: UUID) {
        guard !isShuttingDown, savedTabEditor == nil,
              let tab = session.tabs.first(where: { $0.id == id }), tab.isSaved,
              let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress(); findBar.hide(); pageFeedback.hide()
        let editor = SavedTabEditorController(tab: tab)
        savedTabEditor = editor
        editor.onSave = { [weak self] title, symbol in
            guard let self, self.session.updateSavedTab(id: id, customTitle: title, customSymbol: symbol) else { return false }
            self.refresh(); self.refreshPaletteResults(); self.save()
            return true
        }
        editor.onDismiss = { [weak self] in
            guard let self else { return }
            self.savedTabEditor = nil
            self.view.window?.makeFirstResponder(self.commandWebView)
        }
        editor.present(on: window)
    }
}

/// Edits only the saved label and symbol, so navigations that finish while the
/// sheet is open retain their latest page metadata and original saved address.
@MainActor final class SavedTabEditorController: NSWindowController, NSTextFieldDelegate {
    var onSave: ((String?, String?) -> Bool)?
    var onDismiss: (() -> Void)?
    let nameField = NSTextField()
    let iconPicker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Changes", target: nil, action: nil)

    init(tab: BrowserTab) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Edit Saved Tab"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let content = FlippedContainer(frame: NSRect(x: 0, y: 0, width: 460, height: 330))
        panel.contentView = content
        func label(_ text: String, _ rect: NSRect) {
            let field = NSTextField(labelWithString: text); field.frame = rect; content.addSubview(field)
        }
        label(tab.isFavorite ? "Favorite · shared within this login profile" : "Kept tab · stays in this Space", NSRect(x: 24, y: 18, width: 410, height: 20))
        label("Name", NSRect(x: 24, y: 52, width: 410, height: 20))
        nameField.frame = NSRect(x: 24, y: 77, width: 412, height: 26)
        nameField.stringValue = tab.saved?.customTitle ?? ""
        nameField.placeholderString = tab.title
        nameField.setAccessibilityLabel("Saved tab name — leave blank to use page title")
        nameField.delegate = self; content.addSubview(nameField)
        label("Icon", NSRect(x: 24, y: 116, width: 100, height: 20))
        iconPicker.frame = NSRect(x: 24, y: 142, width: 260, height: 28)
        iconPicker.addItem(withTitle: "Automatic")
        for symbol in BrowserSpace.symbols {
            iconPicker.addItem(withTitle: symbol.replacingOccurrences(of: ".", with: " ").capitalized)
            iconPicker.lastItem?.representedObject = symbol
            iconPicker.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let symbol = tab.saved?.customSymbol, let index = BrowserSpace.symbols.firstIndex(of: symbol) { iconPicker.selectItem(at: index + 1) }
        iconPicker.setAccessibilityLabel("Saved tab icon"); content.addSubview(iconPicker)
        let address = NSTextField(wrappingLabelWithString: "Saved page: \(tab.saved?.address ?? tab.address)")
        address.frame = NSRect(x: 24, y: 184, width: 412, height: 42)
        address.font = .systemFont(ofSize: 11); address.textColor = .secondaryLabelColor
        address.maximumNumberOfLines = 2; address.toolTip = tab.saved?.address
        content.addSubview(address)
        status.frame = NSRect(x: 24, y: 238, width: 412, height: 30)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; content.addSubview(status)
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.frame = NSRect(x: 228, y: 283, width: 88, height: 30)
        cancelButton.bezelStyle = .rounded; cancelButton.keyEquivalent = "\u{1b}"; content.addSubview(cancelButton)
        saveButton.frame = NSRect(x: 320, y: 283, width: 120, height: 30)
        saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "\r"
        saveButton.target = self; saveButton.action = #selector(saveChanges(_:)); content.addSubview(saveButton)
        updateValidation()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window); window.makeFirstResponder(nameField); nameField.selectText(nil)
    }
    private var validName: Bool {
        let text = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= 80 && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func updateValidation() {
        saveButton.isEnabled = validName
        status.stringValue = validName ? "Leave the name blank to follow the page title." : "Use up to 80 characters without line breaks."
    }
    func controlTextDidChange(_ obj: Notification) { updateValidation() }
    @objc func saveChanges(_ sender: Any?) {
        guard validName else { updateValidation(); return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = iconPicker.selectedItem?.representedObject as? String
        guard onSave?(name.isEmpty ? nil : name, symbol) == true else {
            status.stringValue = "This saved tab is no longer available."; return
        }
        dismiss()
    }
    @objc func cancel(_ sender: Any?) { dismiss() }
    override func cancelOperation(_ sender: Any?) { cancel(sender) }
    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window); window.orderOut(nil)
        let callback = onDismiss; onDismiss = nil; callback?()
    }
}
