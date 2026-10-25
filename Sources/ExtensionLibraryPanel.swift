import AppKit

/// One destination for discovery, source choice and installation. Search remains
/// editable while sources answer; generations prevent old responses winning.
@available(macOS 15.4, *)
@MainActor final class ExtensionLibraryPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private weak var host: BrowserExtensions?
    private let installer: ExtensionInstaller
    private var profileID = UUID()
    private var listings: [ExtensionProductListing] = []
    private var chosenBuild: [Int: Int] = [:]
    private let field = NSSearchField()
    private let table = NSTableView()
    private let profileLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "Popular extensions")
    private let name = NSTextField(wrappingLabelWithString: "Find your next extension")
    private let publisher = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "Search across stores, then add an extension to Bam.")
    private let productIcon = ExtensionCatalogImageView()
    private let sourceLabel = NSTextField(labelWithString: "Install from")
    private let buildPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let installButton = NSButton(title: "Add to Bam", target: nil, action: nil)
    private let detailsButton = NSButton(title: "Permissions & details", target: nil, action: nil)
    private let listingButton = NSButton(title: "View store listing ↗", target: nil, action: nil)
    private let manageButton = NSButton(title: "Installed extensions", target: nil, action: nil)
    private let compatibility = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var installTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var hasSearched = false
    private var installing = false { didSet { updateControls() } }

    init(host: BrowserExtensions, installer: ExtensionInstaller) {
        self.host = host; self.installer = installer
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Extension Library — Bam"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 660)); window.contentView = root
        let heading = NSTextField(labelWithString: "Your extensions. All together.")
        heading.font = .systemFont(ofSize: 24, weight: .semibold); heading.frame = NSRect(x: 28, y: 598, width: 630, height: 36); root.addSubview(heading)
        profileLabel.font = .systemFont(ofSize: 12); profileLabel.textColor = .secondaryLabelColor
        profileLabel.frame = NSRect(x: 28, y: 573, width: 620, height: 22); root.addSubview(profileLabel)
        manageButton.frame = NSRect(x: 690, y: 592, width: 182, height: 34); manageButton.target = self; manageButton.action = #selector(manage); root.addSubview(manageButton)
        field.frame = NSRect(x: 28, y: 524, width: 844, height: 34)
        field.placeholderString = "Search extensions or paste a store link"; field.delegate = self
        field.setAccessibilityLabel("Search extensions across stores"); root.addSubview(field)
        resultLabel.font = .systemFont(ofSize: 12, weight: .medium); resultLabel.textColor = .secondaryLabelColor
        resultLabel.frame = NSRect(x: 28, y: 491, width: 380, height: 22); root.addSubview(resultLabel)
        let scroll = NSScrollView(frame: NSRect(x: 28, y: 89, width: 394, height: 395)); scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("listings")); column.width = 384; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 90; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Extension search results"); scroll.documentView = table; root.addSubview(scroll)
        productIcon.frame = NSRect(x: 450, y: 421, width: 56, height: 56); root.addSubview(productIcon)
        name.font = .systemFont(ofSize: 20, weight: .semibold); name.frame = NSRect(x: 522, y: 421, width: 350, height: 58); root.addSubview(name)
        publisher.font = .systemFont(ofSize: 12); publisher.textColor = .secondaryLabelColor; publisher.lineBreakMode = .byTruncatingTail
        publisher.frame = NSRect(x: 522, y: 391, width: 350, height: 24); root.addSubview(publisher)
        summary.maximumNumberOfLines = 4; summary.lineBreakMode = .byWordWrapping
        name.maximumNumberOfLines = 2; name.lineBreakMode = .byWordWrapping
        summary.font = .systemFont(ofSize: 13); summary.frame = NSRect(x: 450, y: 316, width: 422, height: 66); root.addSubview(summary)
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium); sourceLabel.frame = NSRect(x: 450, y: 288, width: 422, height: 22); root.addSubview(sourceLabel)
        buildPicker.frame = NSRect(x: 447, y: 251, width: 428, height: 32); buildPicker.target = self; buildPicker.action = #selector(pickBuild)
        buildPicker.setAccessibilityLabel("Extension store and build"); root.addSubview(buildPicker)
        compatibility.font = .systemFont(ofSize: 12); compatibility.textColor = .secondaryLabelColor
        compatibility.frame = NSRect(x: 450, y: 169, width: 422, height: 70); root.addSubview(compatibility)
        installButton.frame = NSRect(x: 450, y: 123, width: 205, height: 36); installButton.target = self; installButton.action = #selector(install)
        installButton.keyEquivalent = "\r"; root.addSubview(installButton)
        detailsButton.frame = NSRect(x: 667, y: 123, width: 205, height: 36); detailsButton.target = self; detailsButton.action = #selector(details); root.addSubview(detailsButton)
        listingButton.frame = NSRect(x: 450, y: 84, width: 205, height: 30); listingButton.target = self; listingButton.action = #selector(openListing); root.addSubview(listingButton)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.frame = NSRect(x: 28, y: 19, width: 844, height: 53); root.addSubview(status)
        installer.statusChanged = { [weak self] text in if self?.installing == true { self?.status.stringValue = text } }
        ExtensionManagement.dress?(window, root); updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(profileID: UUID, relativeTo parent: NSWindow?) {
        // An in-progress install is bound to the profile named on the panel.
        if !installing { self.profileID = profileID }
        profileLabel.stringValue = "For your \(host?.profileName?(self.profileID) ?? "current") profile · Chrome, Firefox & Safari sources"
        if let parent { window?.setFrameOrigin(NSPoint(x: parent.frame.midX - 450, y: parent.frame.midY - 330)) } else { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(field)
        refreshInstalledState()
        if !hasSearched { beginSearch(debounce: false) }
    }
    func windowWillClose(_ notification: Notification) {
        searchTask?.cancel(); searchTask = nil; searchGeneration += 1
        installTask?.cancel()
        // Restart a canceled initial lookup when this reusable panel reopens.
        if listings.isEmpty { hasSearched = false }
    }
    func refreshInstalledState() {
        let row = table.selectedRow
        table.reloadData()
        if listings.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateControls()
    }
    private var selected: ExtensionProductListing? { listings.indices.contains(table.selectedRow) ? listings[table.selectedRow] : nil }
    private var selectedCandidate: ExtensionBuildCandidate? {
        guard let listing = selected else { return nil }
        let index = chosenBuild[table.selectedRow] ?? listing.candidates.firstIndex(of: listing.recommended) ?? 0
        return listing.candidates.indices.contains(index) ? listing.candidates[index] : listing.recommended
    }
    private func installed(_ candidate: ExtensionBuildCandidate) -> BrowserExtensionRecord? {
        installer.installedRecord(for: candidate, profileID: profileID)
    }
    private func updateControls() {
        field.isEnabled = !installing; table.isEnabled = !installing; manageButton.isEnabled = !installing
        buildPicker.removeAllItems()
        guard let listing = selected, let candidate = selectedCandidate else {
            name.stringValue = "Find your next extension"; publisher.stringValue = ""; summary.stringValue = "Search across stores, then add an extension to Bam."
            productIcon.load(nil); compatibility.stringValue = ""; sourceLabel.stringValue = "Install from"
            buildPicker.isEnabled = false; installButton.title = "Add to Bam"; installButton.isEnabled = false; detailsButton.isEnabled = false; listingButton.isEnabled = false
            return
        }
        name.stringValue = listing.name; publisher.stringValue = candidate.publisher.isEmpty ? "Publisher shown during review" : candidate.publisher
        summary.stringValue = candidate.summary ?? listing.recommended.summary ?? "Add this extension to your browsing in Bam. You’ll review its permissions before it can access your pages."
        productIcon.load(candidate.iconURL ?? listing.recommended.iconURL)
        for c in listing.candidates {
            let version = c.version.isEmpty ? "" : " · \(c.version)"
            let mark = c == listing.recommended && c.canInstallInBam ? " · Recommended" : ""
            buildPicker.addItem(withTitle: "\(Self.sourceName(c.source))\(version)\(mark)")
            buildPicker.lastItem?.image = ExtensionStoreMark.image(c.source)
        }
        buildPicker.selectItem(at: chosenBuild[table.selectedRow] ?? listing.candidates.firstIndex(of: listing.recommended) ?? 0)
        buildPicker.isEnabled = !installing && listing.candidates.count > 1
        detailsButton.isEnabled = !installing; listingButton.isEnabled = !installing && candidate.listingURL != nil
        sourceLabel.stringValue = candidate.canInstallInBam ? "Install from" : "Available for Safari"
        let record = installed(candidate)
        if record?.enabled != true, let blocker = ExtensionBuildResolver.installationBlocker(candidate) {
            installButton.title = "Choose Firefox above"; installButton.isEnabled = false
            compatibility.stringValue = blocker
        } else if let record {
            installButton.title = record.enabled ? "Added to Bam ✓" : "Enable in Bam"
            installButton.isEnabled = !installing && !record.enabled
            compatibility.stringValue = record.enabled ? "Enabled in \(host?.profileName?(profileID) ?? "this profile"). Click its icon below Bam’s address bar to open it." : "Added to this profile. Enable it to review permissions and start using it."
        } else if !candidate.canInstallInBam {
            installButton.title = "View in App Store ↗"; installButton.isEnabled = !installing && candidate.listingURL != nil
            compatibility.stringValue = candidate.compatibilityNote ?? "This Safari app installs through the App Store. It cannot be added directly to Bam. Choose a Chrome or Firefox source above when available."
        } else {
            installButton.title = installing ? "Adding…" : "Add to Bam"; installButton.isEnabled = !installing
            compatibility.stringValue = candidate.compatibilityNote ?? (candidate == listing.recommended && listing.candidates.count > 1 ? "Bam has selected the most suitable available build. You can choose another source above." : "Permissions are reviewed before the extension is enabled. Availability does not guarantee every feature works in Bam.")
        }
    }
    static func sourceName(_ source: ExtensionCatalogSourceKind) -> String {
        switch source {
        case .amo: return "Firefox Add-ons"
        case .chromeWebStore: return "Chrome Web Store"
        case .safariAppStore: return "Safari App Store"
        case .directPackage: return "Direct package"
        case .local: return "Local folder"
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { listings.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ExtensionManagement.rowView?() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listings.indices.contains(row) else { return nil }
        let listing = listings[row], cell = NSView()
        let icon = ExtensionCatalogImageView(frame: NSRect(x: 12, y: 29, width: 40, height: 40)); icon.load(listing.recommended.iconURL); cell.addSubview(icon)
        let label = NSTextField(labelWithString: listing.name); label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 64, y: 56, width: 306, height: 22); label.lineBreakMode = .byTruncatingTail; cell.addSubview(label)
        let author = NSTextField(labelWithString: listing.publisher.isEmpty ? "" : listing.publisher); author.font = .systemFont(ofSize: 11); author.textColor = .secondaryLabelColor
        author.frame = NSRect(x: 64, y: 36, width: 306, height: 20); author.lineBreakMode = .byTruncatingTail; cell.addSubview(author)
        var seen = Set<ExtensionCatalogSourceKind>(), x: CGFloat = 64
        for candidate in listing.candidates where seen.insert(candidate.source).inserted {
            let mark = NSImageView(frame: NSRect(x: x, y: 12, width: 16, height: 16)); mark.image = ExtensionStoreMark.image(candidate.source)
            mark.toolTip = Self.sourceName(candidate.source); cell.addSubview(mark); x += 22
        }
        let added = listing.candidates.contains { installed($0) != nil }
        let state = NSTextField(labelWithString: added ? "Added" : listing.recommended.canInstallInBam ? "Add to Bam" : "Safari app")
        state.font = .systemFont(ofSize: 10, weight: .medium); state.textColor = .secondaryLabelColor; state.frame = NSRect(x: x + 3, y: 10, width: 155, height: 18); cell.addSubview(state)
        cell.setAccessibilityElement(true); cell.setAccessibilityLabel("\(listing.name), \(listing.publisher), \(seen.map(Self.sourceName).sorted().joined(separator: ", ")), \(state.stringValue)")
        ExtensionManagement.restyleCell?(label)
        return cell
    }
    func controlTextDidChange(_ obj: Notification) { beginSearch(debounce: true) }
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement { beginSearch(debounce: false) }
    }
    private func beginSearch(debounce: Bool) {
        guard !installing else { return }
        searchTask?.cancel(); searchGeneration += 1
        let generation = searchGeneration, text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearched = true; listings = []; chosenBuild = [:]; table.reloadData(); updateControls()
        resultLabel.stringValue = text.isEmpty ? "Popular extensions" : "Searching all stores…"
        status.stringValue = text.isEmpty ? "Finding popular extensions…" : "Searching Chrome, Firefox and Safari sources…"
        searchTask = Task { @MainActor [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await self.installer.resolve(text)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.listings = results; self.table.reloadData()
                self.resultLabel.stringValue = text.isEmpty ? "Popular extensions" : "\(results.count) extension\(results.count == 1 ? "" : "s") found"
                self.status.stringValue = self.installer.searchNotices.joined(separator: " ")
                if results.isEmpty { self.status.stringValue = (["No matching extensions. Try another name or paste a store link."] + self.installer.searchNotices).joined(separator: " ") }
                else { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                self.updateControls()
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.resultLabel.stringValue = "Search unavailable"; self.status.stringValue = error.localizedDescription; self.updateControls()
            }
        }
    }
    @objc private func pickBuild() { chosenBuild[table.selectedRow] = buildPicker.indexOfSelectedItem; updateControls() }
    @objc private func manage() { host?.showManager(profileID: profileID, relativeTo: window) }
    @objc private func openListing() { if let url = selectedCandidate?.listingURL { NSWorkspace.shared.open(url) } }
    @objc private func details() {
        guard let candidate = selectedCandidate, let listing = selected else { return }
        let alert = NSAlert(); alert.messageText = candidate.name
        alert.informativeText = "\(candidate.publisher)\n\(Self.sourceName(candidate.source))\(candidate.version.isEmpty ? "" : " · " + candidate.version)"
        var lines: [String] = []
        if let url = candidate.listingURL { lines.append(url.absoluteString) }
        let permissions = candidate.permissions.filter { !AMOSource.isHostPattern($0) }
        let sites = candidate.hostPermissions + candidate.permissions.filter { AMOSource.isHostPattern($0) }
        let unknownPermissions = candidate.canInstallInBam ? "Shown during installation review." : "Review access in the App Store and Safari. Bam does not install this app."
        lines += ["", "Permissions", permissions.isEmpty ? unknownPermissions : permissions.joined(separator: ", "), "", "Website access"]
        lines += sites.isEmpty ? [unknownPermissions] : sites
        lines += ["", "Compatibility"] + (ExtensionBuildResolver.recommend([candidate])?.1 ?? listing.reasons)
        if let note = candidate.compatibilityNote { lines.append(note) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260)); text.isEditable = false; text.font = .systemFont(ofSize: 12)
        text.string = lines.joined(separator: "\n"); text.textContainer?.widthTracksTextView = true; scroll.documentView = text
        alert.accessoryView = scroll; alert.addButton(withTitle: "Done"); alert.runModal()
    }
    @objc private func install() {
        guard let candidate = selectedCandidate, let host, !installing else { return }
        guard candidate.canInstallInBam else { openListing(); return }
        let profile = profileID
        installing = true
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.installing = false; self.refreshInstalledState() }
            do {
                let id = try await self.installer.install(candidate, profileID: profile)
                let record = host.items(profileID: profile).first { $0.id == id }
                if let error = host.errors[id] { self.status.stringValue = "Added, but needs attention: \(error)" }
                else if record?.enabled == true { self.status.stringValue = "\(record?.name ?? candidate.name) is enabled. Click its icon below Bam’s address bar. Reload existing pages to use it there." }
                else { self.status.stringValue = "\(record?.name ?? candidate.name) was added but is disabled. Choose Enable in Bam when you’re ready to review its permissions." }
            } catch is CancellationError { self.status.stringValue = "Installation canceled." }
            catch { self.status.stringValue = error.localizedDescription }
        }
    }
}

/// Store marks drawn from simple geometry; no artwork extracted from other apps.
@available(macOS 15.4, *)
@MainActor private enum ExtensionStoreMark {
    private static var images: [ExtensionCatalogSourceKind: NSImage] = [:]
    static func image(_ source: ExtensionCatalogSourceKind) -> NSImage {
        if let image = images[source] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: 9, y: 9)
            switch source {
            case .chromeWebStore:
                for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill(); let sector = NSBezierPath(); sector.move(to: center)
                    sector.appendArc(withCenter: center, radius: 8.5, startAngle: CGFloat(index * 120 + 30), endAngle: CGFloat(index * 120 + 150)); sector.close(); sector.fill()
                }
                NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 4.5, dy: 4.5)).fill()
                NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5)).fill()
            case .amo:
                NSColor.systemPurple.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.systemOrange.setStroke(); let flame = NSBezierPath(); flame.lineWidth = 5
                flame.appendArc(withCenter: center, radius: 6, startAngle: 35, endAngle: 325); flame.stroke()
                NSColor.systemOrange.setFill(); let ear = NSBezierPath(); ear.move(to: NSPoint(x: 11, y: 12)); ear.line(to: NSPoint(x: 16.5, y: 17.5)); ear.line(to: NSPoint(x: 15, y: 9)); ear.close(); ear.fill()
            case .safariAppStore:
                NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)); ring.lineWidth = 0.7; ring.stroke()
                for (points, color) in [([NSPoint(x: 14, y: 14), NSPoint(x: 7, y: 9), NSPoint(x: 9, y: 7)], NSColor.systemRed), ([NSPoint(x: 4, y: 4), NSPoint(x: 7, y: 9), NSPoint(x: 9, y: 7)], NSColor.white)] {
                    color.setFill(); let needle = NSBezierPath(); needle.move(to: points[0]); needle.line(to: points[1]); needle.line(to: points[2]); needle.close(); needle.fill()
                }
            case .directPackage, .local:
                NSImage(systemSymbolName: source == .local ? "folder" : "shippingbox", accessibilityDescription: nil)?.draw(in: rect)
            }
            return true
        }
        image.accessibilityDescription = ExtensionLibraryPanel.sourceName(source); images[source] = image; return image
    }
}

@MainActor private final class ExtensionCatalogImageView: NSImageView {
    private static let cache = NSCache<NSURL, NSImage>()
    private var currentURL: URL?
    private var task: Task<Void, Never>?
    func load(_ url: URL?) {
        guard currentURL != url || image == nil else { return }
        currentURL = url; task?.cancel()
        image = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: "Extension")
        imageScaling = .scaleProportionallyUpOrDown
        guard let url, url.scheme == "https" else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
        task = Task { @MainActor [weak self] in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("bam-catalog-icon-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            guard let response = try? await URLSessionExtensionHTTPClient().download(for: URLRequest(url: url), to: file, byteLimit: 1_048_576),
                  (200..<300).contains(response.statusCode), !Task.isCancelled, let icon = NSImage(contentsOf: file) else { return }
            Self.cache.setObject(icon, forKey: url as NSURL)
            if self?.currentURL == url { self?.image = icon }
        }
    }
}
