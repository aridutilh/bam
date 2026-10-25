import Foundation
import AppKit
import UniformTypeIdentifiers

@available(macOS 15.4, *)
@MainActor final class ExtensionManagement: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var host: BrowserExtensions?
    private var profileID = UUID()
    private var items: [BrowserExtensionRecord] = []
    let table = NSTableView()
    private let heading = NSTextField(labelWithString: "Extensions")
    /// Status and the selected extension's full disclosure: read-only, selectable, scrollable and focusable, so no
    /// note is clipped however long it is (it replaced a fixed-height label).
    let status = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 44))
    let statusScroll = NSScrollView(frame: NSRect(x: 22, y: 129, width: 576, height: 44))
    private let toggle = NSButton(title: "Enable", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let revoke = NSButton(title: "Revoke Permissions", target: nil, action: nil)
    private let importButton = NSButton(title: "Import Folder…", target: nil, action: nil)
    private let libraryButton = NSButton(title: "Find Extensions…", target: nil, action: nil)
    private let updateButton = NSButton(title: "Check for Update", target: nil, action: nil)
    private let desktopButton = NSButton(title: "Connect Desktop…", target: nil, action: nil)
    /// Opens the selected extension's Site Access editor (enabled only while that extension is loaded).
    let siteAccessButton = NSButton(title: "Site Access…", target: nil, action: nil)
    /// The engine side of site access. The app uses the host (which owns this manager, hence weak); component tests
    /// substitute an engine.
    weak var siteAccessSource: ExtensionSiteAccessSource?
    /// Presents the editor; the app shows it as a sheet on this window. Tests substitute a presenter that shows nothing.
    var presentSiteAccess: (ExtensionSiteAccessPanel, ExtensionSiteAccessPanel.Snapshot, NSWindow?) -> Void = { panel, snapshot, parent in
        panel.show(snapshot, relativeTo: parent)
    }
    private var windowCloseObserver: NSObjectProtocol?
    /// The open Site Access editor, bound to one record (never to the table selection).
    private(set) var siteAccess: SiteAccessBinding?
    private var busy = false
    /// A one-shot message shown by the next refresh instead of the generic guidance.
    private var pendingStatus: String?
    /// The selection whose details the status area shows; its scroll position is kept while text and selection stay.
    private var statusSelectionID: UUID?

    init(host: BrowserExtensions) {
        self.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 535), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Extensions — Bam"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 535))
        window.contentView = root
        heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.frame = NSRect(x: 22, y: 488, width: 576, height: 28); root.addSubview(heading)
        let detail = NSTextField(wrappingLabelWithString: "Manage extensions in this login profile. Find new extensions in the Bam library, or import an unpacked folder. Enabled extensions appear below the browser’s address bar; click an icon to open its popup.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.frame = NSRect(x: 22, y: 419, width: 576, height: 62); root.addSubview(detail)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 183, width: 576, height: 228)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extensions")); column.width = 570; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 62; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Extensions in this profile")
        scroll.documentView = table; root.addSubview(scroll)
        status.isEditable = false; status.isSelectable = true; status.drawsBackground = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.textContainerInset = NSSize(width: 0, height: 2); status.textContainer?.widthTracksTextView = true
        status.isVerticallyResizable = true; status.autoresizingMask = [.width]
        status.setAccessibilityLabel("Selected extension status and compatibility details")
        statusScroll.documentView = status; statusScroll.hasVerticalScroller = true; statusScroll.autohidesScrollers = true
        statusScroll.drawsBackground = false; statusScroll.borderType = .noBorder
        root.addSubview(statusScroll)
        libraryButton.frame = NSRect(x: 18, y: 91, width: 214, height: 32); libraryButton.target = self; libraryButton.action = #selector(openLibrary)
        importButton.frame = NSRect(x: 236, y: 91, width: 160, height: 32); importButton.target = self; importButton.action = #selector(importPackage)
        updateButton.frame = NSRect(x: 400, y: 91, width: 198, height: 32); updateButton.target = self; updateButton.action = #selector(checkForUpdate)
        toggle.frame = NSRect(x: 18, y: 56, width: 100, height: 32); toggle.target = self; toggle.action = #selector(toggleExtension)
        siteAccessButton.frame = NSRect(x: 122, y: 56, width: 160, height: 32); siteAccessButton.target = self; siteAccessButton.action = #selector(openSiteAccess)
        revoke.frame = NSRect(x: 286, y: 56, width: 190, height: 32); revoke.target = self; revoke.action = #selector(revokePermissions)
        desktopButton.frame = NSRect(x: 18, y: 21, width: 214, height: 32); desktopButton.target = self; desktopButton.action = #selector(connectDesktop)
        removeButton.frame = NSRect(x: 482, y: 21, width: 116, height: 32); removeButton.target = self; removeButton.action = #selector(removeExtension)
        [libraryButton, importButton, updateButton, toggle, siteAccessButton, revoke, desktopButton, removeButton].forEach { root.addSubview($0) }
        siteAccessSource = host
        // Every close route (red button, performClose, close) ends the Site Access editor with the window.
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeSiteAccess(because: nil) }
        }
        Self.dress?(window, root)
    }
    deinit { if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) } }
    /// The app installs Bam's wash and pill styling here; this file also builds
    /// alone in its component suite, where the styling kit is absent.
    @MainActor static var dress: ((NSWindow?, NSView) -> Void)?
    /// Supplies the app's selection-tinted row; nil keeps AppKit's.
    @MainActor static var rowView: (() -> NSTableRowView)?
    /// Restyles a freshly made row label the way `dress` styles static ones.
    @MainActor static var restyleCell: ((NSTextField) -> Void)?
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// Lists a profile's extensions without presenting the window.
    func load(profileID: UUID) {
        if let binding = siteAccess, binding.profileID != profileID { closeSiteAccess(because: "Site Access closed because the profile changed.", updating: false) }
        self.profileID = profileID; refresh()
    }
    func show(profileID: UUID, relativeTo parent: NSWindow?) {
        load(profileID: profileID)
        if let parent { window?.setFrameOrigin(NSPoint(x: parent.frame.midX - 310, y: parent.frame.midY - 268)) } else { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        guard let host else { return }
        let selected = selection?.id
        items = host.items(profileID: profileID)
        heading.stringValue = "Extensions · \(host.profileName?(profileID) ?? "Current profile")"
        table.reloadData()
        if let selected, let row = items.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        resyncSiteAccess()
        updateControls()
    }
    override func close() { closeSiteAccess(because: nil); super.close() }
    /// Row of an extension in the current list (tests and selection restore).
    func items(for id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private var selection: BrowserExtensionRecord? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }
    private func updateControls() {
        let selected = selection
        let toggleTitle = selected?.enabled == true ? "Disable" : "Enable"
        // Keep whatever styling the app dressed the button in.
        let attributes = toggle.attributedTitle.length > 0 ? toggle.attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        toggle.attributedTitle = NSAttributedString(string: toggleTitle, attributes: attributes)
        toggle.isEnabled = !busy && selected != nil; removeButton.isEnabled = !busy && selected != nil; revoke.isEnabled = !busy && selected != nil; importButton.isEnabled = !busy
        let editable = selected.flatMap { siteAccessSource?.siteAccess(id: $0.id) }?.editable == true
        siteAccessButton.isEnabled = !busy && editable && siteAccess == nil
        siteAccessButton.setAccessibilityLabel(selected.map { "Site access for \($0.name)" } ?? "Site access")
        siteAccessButton.toolTip = selected == nil ? "Select an extension to review its site access."
            : editable ? "Choose which of the sites it requests \(selected!.name) may use."
            : "Enable the extension to change its site access."
        libraryButton.isEnabled = !busy
        let desktopCandidate = selected?.catalog?.source == .chromeWebStore && selected?.catalog?.upstreamID == ExtensionNativeMessaging.chromeExtensionIdentifier
        desktopButton.isHidden = !desktopCandidate
        desktopButton.isEnabled = !busy && (selected?.nativeHost != nil || (selected?.enabled == true && selected.flatMap { host?.context(for: $0.id) } != nil))
        let verified = selected.map(BrowserExtensions.supportsNativeCompanion) ?? false
        let desktopTitle = selected?.nativeHost != nil ? "Disconnect Desktop" : verified ? "Connect Desktop…" : "Verify Desktop Support…"
        let desktopAttributes = desktopButton.attributedTitle.length > 0 ? desktopButton.attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        desktopButton.attributedTitle = NSAttributedString(string: desktopTitle, attributes: desktopAttributes)
        desktopButton.toolTip = "Connect the official 1Password Chrome extension to its signed desktop app. Requires an Apple-signed Bam build and approval in 1Password’s browser settings."
        let safari = selected?.safariBundle != nil
        let updatable = safari || (selected?.catalog.map { $0.source == .amo || $0.source == .chromeWebStore } ?? false)
        let updateAttributes = updateButton.attributedTitle.length > 0 ? updateButton.attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        updateButton.attributedTitle = NSAttributedString(string: safari ? "Refresh from Installed App" : "Check for Update", attributes: updateAttributes)
        updateButton.isEnabled = !busy && updatable
        updateButton.toolTip = safari ? "Review the current signed extension in its installed app, without contacting the store. Keeps its Bam identity and settings. Update the containing app in the App Store first when needed."
            : updatable ? "Ask \(selected?.catalog?.sourceLabel ?? "the store") for a newer version of this build. Updates keep the extension’s identity and storage and never switch stores." : "Only store-installed extensions can check for updates."
        let guidance = "Reload already open pages after enabling, disabling, or revoking access. Code injected into a page cannot be removed until that page reloads. Extension storage stays local to this profile."
        // A message or error leads; the selected extension's full disclosure always follows it, so a persistent
        // error never hides the static-rule warning the row points to.
        let headline = pendingStatus ?? selected.flatMap { host?.errors[$0.id] } ?? (selected == nil ? host?.lastError : nil)
        // Refreshes (badges, loads, other extensions' changes) run this often: keep the reader's place unless the
        // selection or the text itself changed, and start at the top only then.
        let text = Self.statusText(headline: headline, details: selected.flatMap(Self.details), guidance: guidance)
        if text != status.string || selected?.id != statusSelectionID {
            if text != status.string { status.string = text }
            status.scrollToBeginningOfDocument(nil)
            statusSelectionID = selected?.id
        }
        pendingStatus = nil
        statusScroll.toolTip = guidance
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Self.rowView?() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let record = items[row]
        let bridged = (record.compatibility ?? []).isEmpty ? "" : " · Compatibility layer: \(record.compatibility!.joined(separator: ", "))"
        var origin = record.catalog.map { "\n\($0.sourceLabel)\($0.publisher.isEmpty ? "" : " · \($0.publisher)") · \($0.provenance)" } ?? "\nLocal folder · trusted by you"
        if let available = record.catalog?.availableVersion { origin += " · Update available: \(available)" }
        let state = record.safariBundle != nil && record.enabled && host?.context(for: record.id) == nil ? "Not running" : record.enabled ? "Enabled" : "Disabled"
        let desktop = record.nativeHost == nil ? "" : " · Desktop access approved"
        // Visible without selecting the row: installs from an earlier Bam get the static-rule audit without a new review.
        let rules = record.staticRuleAudit?.note == nil ? "" : " · Network rules: see details"
        let label = NSTextField(wrappingLabelWithString: "\(record.name)  \(record.version)\n\(state)\(host?.errors[record.id] != nil ? " · Needs attention" : "")\(desktop)\(rules)\(bridged)\(origin)")
        label.font = .systemFont(ofSize: 12); label.setAccessibilityLabel(label.stringValue)
        let cell = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                                     label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        Self.restyleCell?(label)
        return cell
    }
    @objc private func openLibrary() {
        guard let host, !busy else { return }
        host.showLibrary(profileID: profileID, relativeTo: window)
    }
    @objc private func checkForUpdate() {
        guard let host, let selected = selection, !busy else { return }
        busy = true; updateControls()
        status.string = selected.safariBundle != nil ? "Verifying the installed app for \(selected.name)…" : "Checking \(selected.catalog?.sourceLabel ?? "the store") for a newer \(selected.name)…"
        Task { @MainActor [weak self] in
            defer { self?.busy = false; self?.refresh() }
            do {
                if selected.safariBundle != nil {
                    let refreshed = try await host.installer.refreshSafariFromInstalledApp(selected)
                    let record = host.records.first { $0.id == selected.id }
                    self?.pendingStatus = refreshed ? "\(record?.name ?? selected.name) was refreshed from its installed app.\(record?.enabled == true ? " Its settings are kept." : " Enable it when you’re ready to review permissions.")"
                        : "\(selected.name) already matches its installed app.\(record?.enabled == true ? "" : " It remains disabled.")"
                    return
                }
                guard let candidate = try await host.installer.checkForUpdate(selected) else {
                    self?.pendingStatus = "\(selected.name) \(selected.version) is the newest version on \(selected.catalog?.sourceLabel ?? "its source")."; return
                }
                let alert = NSAlert(); alert.messageText = "Update \(selected.name) to \(candidate.version)?"
                alert.informativeText = "Installed: \(selected.version) from \(selected.catalog?.sourceLabel ?? "its source"). The update is downloaded from the same source, verified, and reviewed again before it is enabled. Its settings and sign-ins are kept."
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Update")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                try await host.installer.update(selected, to: candidate)
            } catch let error as BrowserExtensionUpdateCancelled { self?.pendingStatus = error.localizedDescription }
            catch { host.setError(error, for: selected.id) }
        }
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
    @objc private func connectDesktop() {
        guard let host, let selected = selection, !busy else { return }
        if selected.nativeHost != nil {
            do { try host.disconnectDesktopApp(id: selected.id) } catch { host.setError(error, for: selected.id) }
            return
        }
        let needsVerification = !BrowserExtensions.supportsNativeCompanion(selected)
        if needsVerification {
            let alert = NSAlert(); alert.messageText = "Verify 1Password for desktop support?"
            alert.informativeText = "Bam will download the current build from the same Chrome Web Store listing, verify its publisher signature and review its permissions. Your extension’s settings and sign-ins are kept. Desktop access will still need a separate approval."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Verify")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        busy = true; updateControls()
        Task { @MainActor [weak self] in
            defer { self?.busy = false; self?.refresh() }
            do {
                if needsVerification {
                    try await host.installer.reverifyNativeCompanion(selected)
                    self?.pendingStatus = "1Password’s publisher is verified. Choose Connect Desktop to review access to its desktop app."
                } else {
                    try await host.connectDesktopApp(id: selected.id)
                    if host.records.first(where: { $0.id == selected.id })?.nativeHost != nil {
                        self?.pendingStatus = "Desktop access approved. Trust Bam in 1Password’s Settings → Browsers, then reopen the extension."
                    }
                }
            } catch { host.setError(error, for: selected.id) }
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
    // MARK: Site Access

    @objc func openSiteAccess() {
        guard !busy, siteAccess == nil, let selected = selection, let source = siteAccessSource,
              let engine = source.siteAccess(id: selected.id), engine.profileID == profileID else { return }
        let profileName = host?.profileName?(selected.profileID) ?? "Current profile"
        guard let snapshot = SiteAccessBinding.panelSnapshot(engine, name: selected.name, profileName: profileName, revision: 1) else {
            pendingStatus = "Enable \(selected.name) to change its site access."; updateControls(); return
        }
        let panel = ExtensionSiteAccessPanel(snapshot: snapshot)
        let binding = SiteAccessBinding(extensionID: selected.id, profileID: selected.profileID, name: selected.name,
                                        profileName: profileName, engine: engine, panel: panel)
        siteAccess = binding
        panel.perform = { [weak self, weak binding] request, completion in
            guard let self, let binding, self.siteAccess === binding else { completion(.failure(.failed(Self.siteAccessGone))); return }
            self.performSiteAccess(request, binding: binding, completion: completion)
        }
        panel.onClose = { [weak self, weak binding] in
            guard let self, let binding, self.siteAccess === binding else { return }
            self.siteAccess = nil; self.updateControls()
        }
        updateControls()
        presentSiteAccess(panel, snapshot, window)
    }
    static let siteAccessGone = "This Site Access editor is no longer current. Open it again."

    /// One panel request through the engine. The request must match the binding's record, the displayed revision
    /// and the displayed declarations; then the engine checks its own full revision and the live declarations.
    private func performSiteAccess(_ request: ExtensionSiteAccessPanel.Request, binding: SiteAccessBinding,
                                   completion: @escaping @MainActor (Result<ExtensionSiteAccessPanel.Snapshot, ExtensionSiteAccessPanel.Failure>) -> Void) {
        guard let source = siteAccessSource, request.extensionID == binding.extensionID, request.profileID == binding.profileID,
              request.revision == binding.displayRevision, request.displayed == binding.engine.declarations else {
            completion(.failure(.failed(BrowserExtensionSiteAccessFailure.stale.localizedDescription)))
            resyncSiteAccess(force: true, message: BrowserExtensionSiteAccessFailure.stale.localizedDescription); updateControls(); return
        }
        binding.inFlight = true
        // The engine may notify (refresh) and offer a page reload while it applies; refreshes wait until it answers.
        defer {
            binding.inFlight = false
            if binding.refreshWhileInFlight { binding.refreshWhileInFlight = false; resyncSiteAccess(); updateControls() }
        }
        do {
            let next = try source.performSiteAccess(id: binding.extensionID, profileID: binding.profileID, revision: binding.engine.revision,
                                                    displayed: request.displayed, change: Self.change(for: request.action))
            binding.engine = next; binding.displayRevision += 1
            // A restart that applied a website access change is said once, in the editor and the status line.
            let notice = host?.takeSiteAccessNotice(id: binding.extensionID)
            if let notice { pendingStatus = notice }
            if var snapshot = binding.snapshot { snapshot.message = notice; completion(.success(snapshot)) }
            else {
                completion(.failure(.failed(Self.siteAccessGone)))
                binding.refreshWhileInFlight = true   // not editable any more: the deferred refresh closes the editor
            }
        } catch let failure as BrowserExtensionSiteAccessFailure {
            switch failure {
            case .refused(let refusal): completion(.failure(.refused(refusal)))
            case .stale:
                completion(.failure(.failed(failure.localizedDescription)))
                binding.forceReset = failure.localizedDescription; binding.refreshWhileInFlight = true
            case .failed: completion(.failure(.failed(failure.localizedDescription)))
            }
        } catch { completion(.failure(.failed(error.localizedDescription))) }
    }
    static func change(for action: ExtensionSiteAccessPanel.Action) -> BrowserExtensionSiteAccessChange {
        switch action {
        case .choose(let mode): return .choose(mode)
        case .addSite(let input, let includeSubdomains): return .addSite(input: input, includeSubdomains: includeSubdomains)
        case .removeSite(let site): return .removeSite(site)
        case .acceptPending(let sites): return .acceptPending(sites)
        }
    }
    /// Keeps the open editor true to the engine: closes it when its extension is gone, in another profile, disabled
    /// or unloaded; re-renders (new display revision) when the engine's snapshot changed; waits while a request is
    /// with the engine.
    private func resyncSiteAccess(force: Bool = false, message: String? = nil) {
        guard let binding = siteAccess else { return }
        if binding.inFlight { binding.refreshWhileInFlight = true; if let message { binding.forceReset = message }; return }
        let note = message ?? binding.forceReset
        binding.forceReset = nil
        guard binding.profileID == profileID, let fresh = siteAccessSource?.siteAccess(id: binding.extensionID),
              fresh.id == binding.extensionID, fresh.profileID == binding.profileID, fresh.editable else {
            closeSiteAccess(because: "Site Access closed because \(binding.name) was disabled, removed or reloaded.", updating: false); return
        }
        guard force || note != nil || fresh != binding.engine else { return }
        binding.engine = fresh; binding.displayRevision += 1
        guard var snapshot = binding.snapshot else { return }
        snapshot.message = note
        binding.panel.reset(to: snapshot)
    }
    /// `updating: false` when the caller updates the controls next (refresh), so the reason survives to be shown.
    private func closeSiteAccess(because reason: String?, updating: Bool = true) {
        guard let binding = siteAccess else { return }
        siteAccess = nil
        binding.panel.onClose = nil
        binding.panel.done()
        if let reason { pendingStatus = reason }
        if updating { updateControls() }
    }

    @objc private func revokePermissions() {
        guard let host, let selected = selection, !busy else { return }
        do {
            try host.revokePermissions(id: selected.id)
            if let notice = host.takeSiteAccessNotice(id: selected.id) { pendingStatus = notice; updateControls() }
        } catch { host.setError(error, for: selected.id) }
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
    /// The selected extension's disclosure: the static-rule warning first (it can affect what the extension does),
    /// then preparation notes, then reload guidance. Nil when there is nothing extension-specific to say.
    static func details(_ record: BrowserExtensionRecord) -> String? {
        // Capabilities Bam now provides for what the extension declares but that were never reviewed (installs from
        // an earlier Bam) or were revoked: listed, never granted silently.
        let now = Date()
        let ungranted = (record.compatibility ?? []).filter { (record.compatibilityGrants?[$0] ?? .distantPast) <= now }
        let access = ungranted.isEmpty ? nil : "Not granted: \(ExtensionCompatibility.reviewLabel(ungranted)). Disable and enable the extension to review this access."
        let identity = record.runtimeIdentifier.map { "Chrome Web Store ID \($0), from a verified publisher signature. The extension sees it as its runtime ID; its pages keep a private per-install address." }
        let tabs = (record.permissions["tabs"] ?? .distantPast) > now ? tabsDisclosure : nil
        let parts = [access, identity, record.staticRuleAudit?.note, record.compatibilityNote, tabs].compactMap { $0 }
        return parts.isEmpty ? nil : (parts + ["Reload open pages after changing access."]).joined(separator: "\n\n")
    }
    static func statusText(headline: String?, details: String?, guidance: String) -> String {
        let parts = [headline, details].compactMap { $0 }
        return parts.isEmpty ? guidance : parts.joined(separator: "\n\n")
    }
    /// What the `tabs` permission means, in plain words. The permission itself and how it's granted are unchanged.
    static let tabsDisclosure = "Tabs: it can see the addresses and titles of your tabs. This permission alone doesn’t let it read or change what’s on a page."
    /// The review's details text (the dialog's scrolling accessory), in this order.
    static func reviewDetails(_ review: BrowserExtensionPermissionReview) -> String {
        var lines: [String] = []
        if let note = review.compatibilityNote { lines += ["Compatibility preparation:", note, ""] }
        if !review.permissions.isEmpty {
            lines += ["Browser capabilities:", review.permissions.joined(separator: ", ")]
            if review.permissions.contains("tabs") { lines.append(tabsDisclosure) }
            lines.append("")
        }
        if !review.websites.isEmpty { lines += ["Websites:"] + review.websites + [""] }
        if !review.bridged.isEmpty { lines += ["Provided by Bam’s compatibility layer (limited):", ExtensionCompatibility.reviewLabel(review.bridged), ""] }
        if review.nativeCompanionAvailable { lines += ["Desktop app (separate approval required):", "The verified 1Password extension can request a connection from Manage Extensions. Enabling website access does not approve it.", ""] }
        if !review.unsupported.isEmpty { lines += ["Unavailable in Bam (not granted):", review.unsupported.joined(separator: ", "), ""] }
        lines += ["Desktop-app access is reviewed separately in Manage Extensions and currently supports only the verified Chrome build of 1Password. Other native hosts and full Chrome compatibility remain unavailable. Reload existing pages after changing access."]
        return lines.joined(separator: "\n")
    }
    static func reviewPermissions(_ review: BrowserExtensionPermissionReview) -> Bool {
        let alert = NSAlert()
        alert.messageText = review.isOptional ? "Allow more access for \(review.name)?" : "Enable \(review.name)?"
        alert.informativeText = "Profile: \(review.profileName)\nOnly continue if you trust this extension. Website access lets it read and change content, including information you enter."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 180)); text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 12); text.string = reviewDetails(review); text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: review.isOptional ? "Allow" : "Enable")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// The engine operations the Site Access editor needs (BrowserExtensions provides them).
@available(macOS 15.4, *)
@MainActor protocol ExtensionSiteAccessSource: AnyObject {
    func siteAccess(id: UUID) -> BrowserExtensionSiteAccessSnapshot?
    func performSiteAccess(id: UUID, profileID: UUID, revision: BrowserExtensionSiteAccessSnapshot.Revision,
                           displayed: ExtensionSiteAccess.Declarations, change: BrowserExtensionSiteAccessChange) throws -> BrowserExtensionSiteAccessSnapshot
}
@available(macOS 15.4, *)
extension BrowserExtensions: ExtensionSiteAccessSource {}

/// One open Site Access editor: the exact engine snapshot (whose full `Revision` is the only token sent back to the
/// engine) and the panel's display revision, for one record in one profile.
@available(macOS 15.4, *)
@MainActor final class SiteAccessBinding {
    let extensionID: UUID
    let profileID: UUID
    let name: String
    let profileName: String
    var engine: BrowserExtensionSiteAccessSnapshot
    /// The panel's `Snapshot.revision`: advanced whenever a different engine snapshot is shown.
    var displayRevision = 1
    var inFlight = false
    var refreshWhileInFlight = false
    /// A message to show with the next reset (a stale refusal).
    var forceReset: String?
    let panel: ExtensionSiteAccessPanel
    init(extensionID: UUID, profileID: UUID, name: String, profileName: String, engine: BrowserExtensionSiteAccessSnapshot, panel: ExtensionSiteAccessPanel) {
        self.extensionID = extensionID; self.profileID = profileID; self.name = name; self.profileName = profileName
        self.engine = engine; self.panel = panel
    }
    var snapshot: ExtensionSiteAccessPanel.Snapshot? { Self.panelSnapshot(engine, name: name, profileName: profileName, revision: displayRevision) }
    /// The panel snapshot for an engine snapshot; nil while the extension isn't loaded (no declarations).
    static func panelSnapshot(_ engine: BrowserExtensionSiteAccessSnapshot, name: String, profileName: String, revision: Int) -> ExtensionSiteAccessPanel.Snapshot? {
        guard let declarations = engine.declarations else { return nil }
        let timed = engine.timed.requested.map { ExtensionSiteAccessPanel.TimedGrant(pattern: $0.key, expires: $0.value, separatelyApproved: false) }
            + engine.timed.optional.map { ExtensionSiteAccessPanel.TimedGrant(pattern: $0.key, expires: $0.value, separatelyApproved: true) }
        return ExtensionSiteAccessPanel.Snapshot(extensionID: engine.id, profileID: engine.profileID, revision: revision, extensionName: name,
                                                 profileName: profileName, state: engine.state, declarations: declarations,
                                                 oneTimeAccess: engine.oneTimeAccess, timedGrants: timed.sorted { $0.pattern < $1.pattern })
    }
}
