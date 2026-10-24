import Foundation
import AppKit
import UniformTypeIdentifiers

@available(macOS 15.4, *)
@MainActor final class ExtensionManagement: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var host: BrowserExtensions?
    private var profileID = UUID()
    private var items: [BrowserExtensionRecord] = []
    private let table = NSTableView()
    private let heading = NSTextField(labelWithString: "Extensions")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: "Enable", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let revoke = NSButton(title: "Revoke Permissions", target: nil, action: nil)
    private let importButton = NSButton(title: "Import Folder…", target: nil, action: nil)
    private var busy = false

    init(host: BrowserExtensions) {
        self.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Extensions — Bam"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 470))
        window.contentView = root
        heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.frame = NSRect(x: 22, y: 423, width: 576, height: 28); root.addSubview(heading)
        let detail = NSTextField(wrappingLabelWithString: "Install local WebExtensions in this login profile. Chrome Web Store installation, native messaging and full Chrome compatibility are not supported.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.frame = NSRect(x: 22, y: 364, width: 576, height: 50); root.addSubview(detail)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 142, width: 576, height: 210)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extensions")); column.width = 570; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Extensions in this profile")
        scroll.documentView = table; root.addSubview(scroll)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.frame = NSRect(x: 22, y: 76, width: 576, height: 55); root.addSubview(status)
        importButton.frame = NSRect(x: 18, y: 21, width: 174, height: 32); importButton.target = self; importButton.action = #selector(importPackage)
        toggle.frame = NSRect(x: 197, y: 21, width: 85, height: 32); toggle.target = self; toggle.action = #selector(toggleExtension)
        revoke.frame = NSRect(x: 286, y: 21, width: 190, height: 32); revoke.target = self; revoke.action = #selector(revokePermissions)
        removeButton.frame = NSRect(x: 482, y: 21, width: 116, height: 32); removeButton.target = self; removeButton.action = #selector(removeExtension)
        [importButton, toggle, revoke, removeButton].forEach { root.addSubview($0) }
        BamSheetStyle.dress(window: window, root: root, colorIndex: BrowserSpace.flatColorCount - 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(profileID: UUID, relativeTo parent: NSWindow?) {
        self.profileID = profileID; refresh()
        if let parent { window?.setFrameOrigin(NSPoint(x: parent.frame.midX - 310, y: parent.frame.midY - 235)) } else { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        guard let host else { return }
        let selected = selection?.id
        items = host.items(profileID: profileID)
        heading.stringValue = "Extensions · \(host.profileName?(profileID) ?? "Current profile")"
        table.reloadData()
        if let selected, let row = items.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateControls()
    }
    private var selection: BrowserExtensionRecord? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }
    private func updateControls() {
        let selected = selection
        toggle.title = selected?.enabled == true ? "Disable" : "Enable"
        toggle.isEnabled = !busy && selected != nil; removeButton.isEnabled = !busy && selected != nil; revoke.isEnabled = !busy && selected != nil; importButton.isEnabled = !busy
        let guidance = "Reload already open pages after enabling, disabling, or revoking access. Code injected into a page cannot be removed until that page reloads. Extension storage stays local to this profile."
        status.stringValue = selected.flatMap { host?.errors[$0.id] } ?? host?.lastError
            ?? selected?.compatibilityNote.map { $0 + " Reload open pages after changing access." } ?? guidance
        status.toolTip = guidance
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let record = items[row]
        let label = NSTextField(wrappingLabelWithString: "\(record.name)  \(record.version)\n\(record.enabled ? "Enabled" : "Disabled")\(host?.errors[record.id] != nil ? " · Needs attention" : "")")
        label.font = .systemFont(ofSize: 12); label.setAccessibilityLabel(label.stringValue); return label
    }
    @objc private func importPackage() {
        guard let host, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]; panel.prompt = "Review Extension"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; updateControls()
        let access = url.startAccessingSecurityScopedResource(), profile = profileID
        Task { @MainActor [weak self] in
            defer { if access { url.stopAccessingSecurityScopedResource() }; self?.busy = false; self?.refresh() }
            do { _ = try await host.importPackage(at: url, profileID: profile) } catch { host.setError(error) }
        }
    }
    @objc private func toggleExtension() {
        guard let host, let selected = selection, !busy else { return }
        busy = true; updateControls()
        Task { @MainActor [weak self] in
            defer { self?.busy = false; self?.refresh() }
            do { try await host.setEnabled(!selected.enabled, id: selected.id) } catch { host.setError(error, for: selected.id) }
        }
    }
    @objc private func revokePermissions() {
        guard let host, let selected = selection, !busy else { return }
        do { try host.revokePermissions(id: selected.id) } catch { host.setError(error, for: selected.id) }
    }
    @objc private func removeExtension() {
        guard let host, let selected = selection, !busy else { return }
        let alert = NSAlert(); alert.messageText = "Remove \(selected.name)?"; alert.informativeText = "This removes its package and permissions from this login profile."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; updateControls()
        Task { @MainActor [weak self] in
            defer { self?.busy = false; self?.refresh() }
            do { try await host.remove(id: selected.id) } catch { host.setError(error, for: selected.id) }
        }
    }
    static func reviewPermissions(_ review: BrowserExtensionPermissionReview) -> Bool {
        let alert = NSAlert()
        alert.messageText = review.isOptional ? "Allow more access for \(review.name)?" : "Enable \(review.name)?"
        alert.informativeText = "Profile: \(review.profileName)\nOnly continue if you trust this extension. Website access lets it read and change content, including information you enter."
        var lines: [String] = []
        if let note = review.compatibilityNote { lines += ["Compatibility preparation:", note, ""] }
        if !review.permissions.isEmpty { lines += ["Browser capabilities:", review.permissions.joined(separator: ", "), ""] }
        if !review.websites.isEmpty { lines += ["Websites:"] + review.websites + [""] }
        if !review.unsupported.isEmpty { lines += ["Unavailable in Bam (not granted):", review.unsupported.joined(separator: ", "), ""] }
        lines += ["Unpacked local folders only. Native messaging and full Chrome compatibility are unavailable. Reload existing pages after changing access."]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 180)); text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 12); text.string = lines.joined(separator: "\n"); text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: review.isOptional ? "Allow" : "Enable")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
