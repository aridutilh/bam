import AppKit

/// A sheet edits only Space definitions. Apply to the latest session so page
/// titles, navigations and other asynchronous browser metadata cannot be lost.
struct SpaceEditPlan {
    let originalIDs: Set<Int>
    var spaces: [BrowserSpace]
    var removalDestinations: [Int: Int] = [:]

    func applying(to current: BrowserSession) -> BrowserSession? {
        guard Set(current.spaceIDs) == originalIDs, !spaces.isEmpty,
              spaces.count <= BrowserSession.maximumSpaces,
              Set(spaces.map(\.id)).count == spaces.count else { return nil }
        var result = current
        var identifiers: [Int: Int] = [:]
        for definition in spaces {
            if originalIDs.contains(definition.id) {
                guard result.updateSpace(id: definition.id, name: definition.name, symbol: definition.symbol, colorIndex: definition.colorIndex) else { return nil }
                identifiers[definition.id] = definition.id
            } else {
                // Negative IDs belong only to this unsaved sheet, never to disk.
                guard definition.id < 0 else { return nil }
            }
        }
        // Resolve deletion chains before mutating the copy (A → B → C).
        func survivingDestination(for id: Int) -> Int? {
            var next = id, visited = Set<Int>()
            while identifiers[next] == nil && !spaces.contains(where: { $0.id == next }) {
                guard visited.insert(next).inserted, let destination = removalDestinations[next] else { return nil }
                next = destination
            }
            return next
        }
        let removedIDs = current.spaceIDs.filter { id in !spaces.contains { $0.id == id } }
        var destinations: [Int: Int] = [:]
        for id in removedIDs {
            guard let destination = survivingDestination(for: id) else { return nil }
            destinations[id] = destination
        }
        // Deleting first permits replacing a Space even at the 32-Space limit.
        // New destinations require a temporary slot; use an existing survivor as
        // a holding Space, then move the exact affected tab IDs after allocation.
        let survivor = spaces.first(where: { originalIDs.contains($0.id) })?.id ?? current.spaceIDs.first!
        var pendingMoves: [(UUID, Int)] = []
        for id in removedIDs where id != survivor {
            guard let destination = destinations[id] else { return nil }
            let destinationExists = result.spaceDefinition(destination) != nil && spaces.contains { $0.id == destination }
            let target = destinationExists ? destination : survivor
            if !destinationExists { pendingMoves += result.tabs.filter { $0.space == id && !$0.isFavorite }.map { ($0.id, destination) } }
            guard result.deleteSpace(id: id, movingTabsTo: target) else { return nil }
        }
        if removedIDs.contains(survivor) {
            guard let draftTarget = destinations[survivor],
                  let definition = spaces.first(where: { $0.id == draftTarget }),
                  let target = result.createSpace(name: definition.name, symbol: definition.symbol, colorIndex: definition.colorIndex),
                  result.deleteSpace(id: survivor, movingTabsTo: target) else { return nil }
            identifiers[draftTarget] = target
        }
        for definition in spaces where identifiers[definition.id] == nil {
            guard let id = result.createSpace(name: definition.name, symbol: definition.symbol, colorIndex: definition.colorIndex) else { return nil }
            identifiers[definition.id] = id
        }
        for (tab, draftTarget) in pendingMoves {
            guard let target = identifiers[draftTarget], result.moveTab(id: tab, toSpace: target) else { return nil }
        }
        for (index, definition) in spaces.enumerated() {
            guard let id = identifiers[definition.id], result.reorderSpace(id: id, to: index) else { return nil }
        }
        result.sanitize()
        return result
    }
}

@MainActor extension BrowserController {
    @objc func manageSpaces(_ sender: Any?) {
        guard !isShuttingDown, spaceManager == nil, let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress(); findBar.hide(); pageFeedback.hide()
        let manager = SpaceManagementController(spaces: session.spaces, selectedID: session.space)
        spaceManager = manager
        manager.onSave = { [weak self] plan in self?.applySpaceEdits(plan) ?? false }
        manager.onDismiss = { [weak self] in
            guard let self else { return }
            self.spaceManager = nil
            self.view.window?.makeFirstResponder(self.commandWebView)
        }
        manager.present(on: window)
    }
    @discardableResult func applySpaceEdits(_ plan: SpaceEditPlan) -> Bool {
        guard let updated = plan.applying(to: session) else { return false }
        cancelPaging(); session = updated
        showActive(); refreshPaletteResults(); save(); onSpacesChanged?()
        return true
    }
    @discardableResult func moveTab(_ id: UUID, toSpace destination: Int) -> Bool {
        guard session.spaceDefinition(destination) != nil else { return false }
        cancelPaging(); dismissAddress()
        guard session.moveTab(id: id, toSpace: destination) else { return false }
        showActive(); save()
        return true
    }
}

@MainActor final class SpaceManagementController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onSave: ((SpaceEditPlan) -> Bool)?
    var onDismiss: (() -> Void)?
    private(set) var plan: SpaceEditPlan
    let table = NSTableView()
    let nameField = NSTextField()
    let iconPicker = NSPopUpButton()
    let colorPicker = NSPopUpButton()
    let destinationPicker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Changes", target: nil, action: nil)
    private let addButton = NSButton(title: "New Space", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Space", target: nil, action: nil)
    private let upButton = NSButton(title: "↑", target: nil, action: nil)
    private let downButton = NSButton(title: "↓", target: nil, action: nil)
    private var selectedID: Int
    private var draftID = -1
    private var updating = false
    private static let pasteboardType = NSPasteboard.PasteboardType("com.ari.bam.space-order")

    init(spaces: [BrowserSpace], selectedID: Int) {
        plan = SpaceEditPlan(originalIDs: Set(spaces.map(\.id)), spaces: spaces)
        self.selectedID = selectedID
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Manage Spaces"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildContent()
        reload(selectedID: selectedID)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildContent() {
        guard let window else { return }
        let root = FlippedContainer(frame: NSRect(x: 0, y: 0, width: 650, height: 440)); window.contentView = root
        func label(_ text: String, _ frame: NSRect, size: CGFloat = 12, weight: NSFont.Weight = .regular) {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: size, weight: weight); label.frame = frame; root.addSubview(label)
        }
        label("Your Spaces", NSRect(x: 24, y: 20, width: 580, height: 27), size: 21, weight: .semibold)
        label("Create a place for each part of your day.", NSRect(x: 24, y: 51, width: 580, height: 19))
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 85, width: 226, height: 260))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space")); column.width = 220
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 36
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Spaces — drag to reorder")
        table.registerForDraggedTypes([Self.pasteboardType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table; root.addSubview(scroll)
        label("Name", NSRect(x: 278, y: 85, width: 336, height: 19), weight: .medium)
        nameField.frame = NSRect(x: 278, y: 109, width: 344, height: 26); nameField.delegate = self
        nameField.setAccessibilityLabel("Space name"); root.addSubview(nameField)
        label("Icon", NSRect(x: 278, y: 148, width: 160, height: 19), weight: .medium)
        iconPicker.frame = NSRect(x: 274, y: 173, width: 172, height: 28)
        let iconNames = ["Sparkles", "Sun", "Globe", "Work", "Home", "Heart", "Book", "Creative", "Code", "Bolt", "Leaf", "Music"]
        for (index, symbol) in BrowserSpace.symbols.enumerated() {
            iconPicker.addItem(withTitle: index < iconNames.count ? iconNames[index] : symbol)
            iconPicker.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        iconPicker.target = self; iconPicker.action = #selector(editAppearance); iconPicker.setAccessibilityLabel("Space icon"); root.addSubview(iconPicker)
        label("Color", NSRect(x: 460, y: 148, width: 150, height: 19), weight: .medium)
        colorPicker.frame = NSRect(x: 456, y: 173, width: 170, height: 28)
        colorPicker.addItems(withTitles: BrowserSpace.colorNames); colorPicker.target = self; colorPicker.action = #selector(editAppearance)
        colorPicker.setAccessibilityLabel("Space color"); root.addSubview(colorPicker)
        label("Move this Space’s tabs to", NSRect(x: 278, y: 231, width: 344, height: 19), weight: .medium)
        destinationPicker.frame = NSRect(x: 274, y: 256, width: 216, height: 28); destinationPicker.setAccessibilityLabel("Destination when removing Space"); root.addSubview(destinationPicker)
        removeButton.frame = NSRect(x: 492, y: 254, width: 134, height: 30); removeButton.target = self; removeButton.action = #selector(removeSpace); root.addSubview(removeButton)
        label("Removing a Space keeps all its tabs.", NSRect(x: 278, y: 291, width: 344, height: 19), size: 11)
        addButton.frame = NSRect(x: 18, y: 351, width: 118, height: 30); addButton.target = self; addButton.action = #selector(addSpace); root.addSubview(addButton)
        upButton.frame = NSRect(x: 164, y: 351, width: 40, height: 30); upButton.target = self; upButton.action = #selector(moveSpaceEarlier); upButton.setAccessibilityLabel("Move Space earlier"); root.addSubview(upButton)
        downButton.frame = NSRect(x: 206, y: 351, width: 40, height: 30); downButton.target = self; downButton.action = #selector(moveSpaceLater); downButton.setAccessibilityLabel("Move Space later"); root.addSubview(downButton)
        status.frame = NSRect(x: 278, y: 325, width: 344, height: 52); status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; root.addSubview(status)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 398, y: 395, width: 100, height: 30); cancel.keyEquivalent = "\u{1b}"; root.addSubview(cancel)
        saveButton.frame = NSRect(x: 501, y: 395, width: 126, height: 30); saveButton.target = self; saveButton.action = #selector(saveChanges); saveButton.keyEquivalent = "\r"; root.addSubview(saveButton)
        for button in [saveButton, addButton, removeButton, upButton, downButton, cancel] { button.bezelStyle = .rounded }
    }
    func present(on parent: NSWindow) {
        guard let window else { return }
        window.appearance = parent.appearance
        parent.beginSheet(window)
        window.makeFirstResponder(nameField); nameField.selectText(nil)
    }
    @objc func cancel(_ sender: Any?) { dismiss() }
    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window); window.orderOut(nil)
        onDismiss?()
    }
    @objc func saveChanges(_ sender: Any?) {
        storeFields()
        guard validNames else { updateStatus(); return }
        guard onSave?(plan) == true else {
            status.stringValue = "Couldn’t save these changes. Reopen Spaces and try again."; return
        }
        dismiss()
    }
    private var validNames: Bool {
        plan.spaces.allSatisfy { let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines); return !name.isEmpty && name.count <= 60 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { plan.spaces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard plan.spaces.indices.contains(row) else { return nil }
        let space = plan.spaces[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let image = NSImageView(frame: NSRect(x: 10, y: 8, width: 20, height: 20))
        image.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil); image.contentTintColor = ArkPalette.spaceColor(space.colorIndex)
        let text = NSTextField(labelWithString: space.name.isEmpty ? "Untitled Space" : space.name)
        text.frame = NSRect(x: 40, y: 9, width: 169, height: 19); text.lineBreakMode = .byTruncatingTail
        cell.addSubview(image); cell.addSubview(text); cell.textField = text; cell.imageView = image
        cell.setAccessibilityLabel(space.name); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, plan.spaces.indices.contains(table.selectedRow) else { return }
        selectedID = plan.spaces[table.selectedRow].id; loadFields()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard !updating else { return }; storeFields()
        if let row = plan.spaces.firstIndex(where: { $0.id == selectedID }) { table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
    }
    @objc private func editAppearance(_ sender: Any?) { storeFields(); reload(selectedID: selectedID) }
    private func storeFields() {
        guard !updating, let index = plan.spaces.firstIndex(where: { $0.id == selectedID }) else { return }
        plan.spaces[index].name = nameField.stringValue
        if BrowserSpace.symbols.indices.contains(iconPicker.indexOfSelectedItem) { plan.spaces[index].symbol = BrowserSpace.symbols[iconPicker.indexOfSelectedItem] }
        plan.spaces[index].colorIndex = max(0, colorPicker.indexOfSelectedItem)
        updateStatus()
    }
    private func loadFields() {
        guard let space = plan.spaces.first(where: { $0.id == selectedID }) else { return }
        updating = true
        nameField.stringValue = space.name
        iconPicker.selectItem(at: BrowserSpace.symbols.firstIndex(of: space.symbol) ?? 0); colorPicker.selectItem(at: space.colorIndex)
        destinationPicker.removeAllItems()
        for target in plan.spaces where target.id != selectedID {
            destinationPicker.addItem(withTitle: target.name.isEmpty ? "Untitled Space" : target.name); destinationPicker.lastItem?.tag = target.id
        }
        updating = false; updateStatus()
    }
    private func updateStatus() {
        let index = plan.spaces.firstIndex { $0.id == selectedID } ?? 0
        upButton.isEnabled = index > 0; downButton.isEnabled = index + 1 < plan.spaces.count
        addButton.isEnabled = plan.spaces.count < BrowserSession.maximumSpaces
        removeButton.isEnabled = plan.spaces.count > 1; destinationPicker.isEnabled = removeButton.isEnabled
        saveButton.isEnabled = validNames
        status.stringValue = validNames ? "Changes apply when you save. Drag Spaces in the list or use the arrows to reorder." : "Give every Space a name of 1–60 characters."
    }
    private func reload(selectedID: Int) {
        self.selectedID = selectedID; updating = true; table.reloadData()
        if let index = plan.spaces.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index) }
        updating = false; loadFields()
    }
    @objc func addSpace(_ sender: Any?) {
        guard plan.spaces.count < BrowserSession.maximumSpaces else { return }
        var suffix = 1, name = "New Space"
        while plan.spaces.contains(where: { $0.name == name }) { suffix += 1; name = "New Space \(suffix)" }
        let id = draftID; draftID -= 1
        // New Spaces cycle the flat colors only; the Prism and Clear
        // appearances apply by explicit choice, never as a default.
        plan.spaces.append(BrowserSpace(id: id, name: name, symbol: "sparkles", colorIndex: plan.spaces.count % BrowserSpace.flatColorCount))
        reload(selectedID: id); window?.makeFirstResponder(nameField); nameField.selectText(nil)
    }
    @objc func removeSpace(_ sender: Any?) {
        guard plan.spaces.count > 1, let destination = destinationPicker.selectedItem?.tag,
              destination != selectedID, plan.spaces.contains(where: { $0.id == destination }) else { return }
        plan.removalDestinations[selectedID] = destination
        plan.spaces.removeAll { $0.id == selectedID }; reload(selectedID: destination)
    }
    func reorderSelected(to index: Int) {
        guard let origin = plan.spaces.firstIndex(where: { $0.id == selectedID }), plan.spaces.indices.contains(index) else { return }
        let space = plan.spaces.remove(at: origin); plan.spaces.insert(space, at: index); reload(selectedID: space.id)
    }
    @objc func moveSpaceEarlier(_ sender: Any?) { if let i = plan.spaces.firstIndex(where: { $0.id == selectedID }) { reorderSelected(to: i - 1) } }
    @objc func moveSpaceLater(_ sender: Any?) { if let i = plan.spaces.firstIndex(where: { $0.id == selectedID }) { reorderSelected(to: i + 1) } }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard plan.spaces.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(String(plan.spaces[row].id), forType: Self.pasteboardType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        table.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table,
              let text = info.draggingPasteboard.string(forType: Self.pasteboardType), let id = Int(text),
              let origin = plan.spaces.firstIndex(where: { $0.id == id }) else { return false }
        selectedID = id; reorderSelected(to: min(plan.spaces.count - 1, max(0, row > origin ? row - 1 : row))); return true
    }
}
