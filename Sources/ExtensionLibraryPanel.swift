import AppKit

/// Bam's extension library: one search box that takes a store link, a package
/// link or a product name, shows each product once with the build Bam would
/// install and why, and installs through the verified fetch pipeline into the
/// current login profile. Publisher, source, version and permissions stay visible.
@available(macOS 15.4, *)
@MainActor final class ExtensionLibraryPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private weak var host: BrowserExtensions?
    private let installer: ExtensionInstaller
    private var profileID = UUID()
    private var listings: [ExtensionProductListing] = []
    private var chosenBuild: [Int: Int] = [:]
    private let field = NSTextField()
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let buildPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let installButton = NSButton(title: "Install into Profile", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var busy = false { didSet { updateControls() } }

    init(host: BrowserExtensions, installer: ExtensionInstaller) {
        self.host = host; self.installer = installer
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Extension Library — Bam"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 540)); window.contentView = root
        let heading = NSTextField(labelWithString: "Find an extension")
        heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.frame = NSRect(x: 22, y: 493, width: 636, height: 28); root.addSubview(heading)
        let blurb = NSTextField(wrappingLabelWithString: "Paste a Chrome Web Store or Firefox Add-ons link, a direct .xpi/.crx/.zip link, or search Firefox Add-ons by name. Bam verifies the package (published hash or CRX3 signature), unpacks it privately and reviews permissions before enabling.")
        blurb.font = .systemFont(ofSize: 12); blurb.textColor = .secondaryLabelColor; blurb.frame = NSRect(x: 22, y: 440, width: 636, height: 48); root.addSubview(blurb)
        field.frame = NSRect(x: 22, y: 404, width: 540, height: 28); field.placeholderString = "Link or name, e.g. https://addons.mozilla.org/firefox/addon/vidiq-vision-youtube/"
        field.font = .systemFont(ofSize: 13); field.delegate = self; root.addSubview(field)
        searchButton.frame = NSRect(x: 570, y: 402, width: 88, height: 32); searchButton.target = self; searchButton.action = #selector(search); searchButton.keyEquivalent = "\r"; root.addSubview(searchButton)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 212, width: 636, height: 180)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("listings")); column.width = 630; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 52; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Extension search results")
        scroll.documentView = table; root.addSubview(scroll)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.frame = NSRect(x: 22, y: 118, width: 636, height: 86); root.addSubview(detail)
        let buildLabel = NSTextField(labelWithString: "Build:"); buildLabel.font = .systemFont(ofSize: 12); buildLabel.frame = NSRect(x: 22, y: 82, width: 44, height: 20); root.addSubview(buildLabel)
        buildPicker.frame = NSRect(x: 66, y: 76, width: 400, height: 30); buildPicker.target = self; buildPicker.action = #selector(pickBuild); root.addSubview(buildPicker)
        installButton.frame = NSRect(x: 474, y: 75, width: 184, height: 32); installButton.target = self; installButton.action = #selector(install); root.addSubview(installButton)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.frame = NSRect(x: 22, y: 18, width: 636, height: 50); root.addSubview(status)
        installer.statusChanged = { [weak self] text in self?.status.stringValue = text }
        ExtensionManagement.dress?(window, root)
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(profileID: UUID, relativeTo parent: NSWindow?) {
        self.profileID = profileID
        if let parent { window?.setFrameOrigin(NSPoint(x: parent.frame.midX - 340, y: parent.frame.midY - 270)) } else { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(field)
        status.stringValue = "Installing into the \(host?.profileName?(profileID) ?? "current") profile."
    }

    private var selected: ExtensionProductListing? { listings.indices.contains(table.selectedRow) ? listings[table.selectedRow] : nil }
    private var selectedCandidate: ExtensionBuildCandidate? {
        guard let listing = selected else { return nil }
        let index = chosenBuild[table.selectedRow] ?? listing.candidates.firstIndex(of: listing.recommended) ?? 0
        return listing.candidates.indices.contains(index) ? listing.candidates[index] : listing.recommended
    }
    private func updateControls() {
        searchButton.isEnabled = !busy; field.isEnabled = !busy
        installButton.isEnabled = !busy && selectedCandidate != nil
        buildPicker.removeAllItems()
        if let listing = selected {
            for candidate in listing.candidates {
                let mark = candidate == listing.recommended ? " · recommended" : ""
                buildPicker.addItem(withTitle: "\(Self.sourceName(candidate.source)) \(candidate.version)\(mark)")
            }
            buildPicker.selectItem(at: chosenBuild[table.selectedRow] ?? listing.candidates.firstIndex(of: listing.recommended) ?? 0)
            buildPicker.isEnabled = !busy && listing.candidates.count > 1
            if let candidate = selectedCandidate {
                var lines = ["\(candidate.name) · \(candidate.publisher.isEmpty ? "publisher unknown until unpacked" : candidate.publisher) · \(Self.sourceName(candidate.source))"]
                if let listingURL = candidate.listingURL { lines.append(listingURL.absoluteString) }
                let permissions = candidate.permissions.filter { !AMOSource.isHostPattern($0) }
                if !permissions.isEmpty { lines.append("Permissions: " + permissions.joined(separator: ", ")) }
                let sites = candidate.hostPermissions + candidate.permissions.filter { AMOSource.isHostPattern($0) }
                if !sites.isEmpty { lines.append("Websites: " + sites.prefix(6).joined(separator: ", ") + (sites.count > 6 ? " …" : "")) }
                lines += listing.reasons
                detail.stringValue = lines.joined(separator: "\n")
            }
        } else {
            buildPicker.isEnabled = false
            detail.stringValue = listings.isEmpty ? "" : "Select a product to see its builds, publisher and permissions."
        }
    }
    static func sourceName(_ source: ExtensionCatalogSourceKind) -> String {
        switch source {
        case .amo: return "Firefox Add-ons"
        case .chromeWebStore: return "Chrome Web Store"
        case .directPackage: return "Direct package"
        case .local: return "Local folder"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listings.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ExtensionManagement.rowView?() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listings.indices.contains(row) else { return nil }
        let listing = listings[row]
        let builds = listing.candidates.map { "\(Self.sourceName($0.source)) \($0.version)" }.joined(separator: " · ")
        let label = NSTextField(wrappingLabelWithString: "\(listing.name)  —  \(listing.publisher.isEmpty ? "publisher unknown" : listing.publisher)\n\(builds)")
        label.font = .systemFont(ofSize: 12); label.setAccessibilityLabel(label.stringValue)
        let cell = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                                     label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        ExtensionManagement.restyleCell?(label)
        return cell
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement { search() }
    }

    @objc private func search() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true; status.stringValue = "Looking up \(text)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                self.listings = try await self.installer.resolve(text); self.chosenBuild = [:]
                self.table.reloadData()
                if self.listings.isEmpty { self.status.stringValue = "No extensions matched. Paste a store link to reach a specific listing." }
                else { self.status.stringValue = "\(self.listings.count) product\(self.listings.count == 1 ? "" : "s") found."; self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            } catch { self.status.stringValue = error.localizedDescription }
            self.updateControls()
        }
    }
    @objc private func pickBuild() { chosenBuild[table.selectedRow] = buildPicker.indexOfSelectedItem; updateControls() }
    @objc private func install() {
        guard let candidate = selectedCandidate, let host, !busy else { return }
        busy = true
        let profile = profileID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.updateControls() }
            do {
                let id = try await self.installer.install(candidate, profileID: profile)
                let record = host.items(profileID: profile).first { $0.id == id }
                if let error = host.errors[id] { self.status.stringValue = "Installed but not enabled: \(error)" }
                else if record?.enabled == true { self.status.stringValue = "\(record?.name ?? candidate.name) is enabled in \(host.profileName?(profile) ?? "this profile"). Reload open pages to use it." }
                else { self.status.stringValue = "\(record?.name ?? candidate.name) was added but stays disabled until its permissions are approved." }
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}
