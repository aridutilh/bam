import AppKit
import WebKit

/// The per-extension "Site access" editor for Manage Extensions. UI only: it renders an engine-supplied `Snapshot`,
/// sends the user's proposed `Action`s to `perform`, and re-renders whatever snapshot (or failure) the engine
/// returns. It never grants, revokes or stores anything itself; the engine (`ExtensionSiteAccess` + context) is the
/// authority.
@available(macOS 15.4, *)
@MainActor final class ExtensionSiteAccessPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// What the engine says is true now, for one extension in one profile.
    struct Snapshot: Equatable {
        /// Which extension in which profile this describes, and the engine's revision of its site access (advanced
        /// on every change). Requests carry these so a stale proposal can be refused.
        var extensionID: UUID
        var profileID: UUID
        var revision: Int
        var extensionName: String
        var profileName: String
        var state: ExtensionSiteAccess.State
        var declarations: ExtensionSiteAccess.Declarations
        /// `providesOneTimeAccess(grantedPermissions:)` on the context's *effective* granted permissions.
        var oneTimeAccess: Bool
        /// An engine message to show (for example a failed save); nil when there's nothing to report.
        var message: String? = nil
    }
    /// A change the user asked for. The engine decides, applies and answers with a new snapshot.
    enum Action: Equatable {
        /// `.withheld` or `.allRequested` (the user's explicit choice; All requested approves the current requests).
        /// Specific sites are never chosen empty: they start with `.addSite`.
        case choose(ExtensionSiteAccess.Mode)
        /// Add a typed site to the site list. From Withheld or All requested this starts a list with just this site.
        case addSite(input: String, includeSubdomains: Bool)
        case removeSite(String)
        /// Exactly the pending requests the user just reviewed and allowed.
        case acceptPending([String])
    }
    /// An action bound to the snapshot it was proposed from. The engine should refuse it (`.failed`) when the
    /// extension, profile or revision no longer matches.
    struct Request: Equatable {
        let extensionID: UUID
        let profileID: UUID
        let revision: Int
        /// The declarations the panel displayed when the user acted. `.choose(.allRequested)` approves exactly
        /// `displayed.requested` (`.allRequested(approving: displayed)`), so hosts a newer manifest adds stay
        /// pending; the engine also refuses the request if the current declarations or revision differ.
        let displayed: ExtensionSiteAccess.Declarations
        let action: Action
    }
    enum Failure: Error, Equatable {
        /// The model's refusal for a typed site; shown inline, the typed text is kept.
        case refused(ExtensionSiteAccess.Refusal)
        /// Anything else the engine reports (unchanged snapshot is assumed).
        case failed(String)
    }

    /// Injected by the engine owner. Call `completion` exactly once, on the main actor, with the authoritative
    /// snapshot after applying, or the failure. Controls stay disabled until then.
    var perform: ((Request, @escaping @MainActor (Result<Snapshot, Failure>) -> Void) -> Void)?
    /// The explicit review for pending requests; true allows exactly `sites`. Defaults to a native alert sheet-free
    /// modal; tests substitute a decision.
    var confirmPending: (([String], Snapshot) -> Bool)?
    var onClose: (() -> Void)?
    /// The app's Manage Extensions styling (wash and pill buttons), like `ExtensionManagement.dress`; nil keeps AppKit's.
    static var dress: ((NSWindow?, NSView) -> Void)?

    private(set) var snapshot: Snapshot
    /// "On specific sites" picked but no site added yet: the editor shows, nothing has changed.
    private(set) var draftingSites = false
    private(set) var busy = false
    private var listedSites: [String] = []
    /// Advanced by every send, reset, show and close. An answer only lands for the request still current.
    private var generation = 0

    let modeMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let modeHelp = NSTextField(wrappingLabelWithString: "")
    let requestedLabel = NSTextField(wrappingLabelWithString: "")
    let sitesTable = NSTableView()
    private let sitesScroll = NSScrollView()
    let siteField = NSTextField()
    let subdomainsBox = NSButton(checkboxWithTitle: "Include subdomains", target: nil, action: nil)
    let addButton = NSButton(title: "Add Site", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let editor = NSStackView()
    let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    let pendingLabel = NSTextField(wrappingLabelWithString: "")
    let pendingButton = NSButton(title: "Review New Sites…", target: nil, action: nil)
    private let pendingRow = NSStackView()
    let optionalLabel = NSTextField(wrappingLabelWithString: "")
    let reloadNotice = NSTextField(wrappingLabelWithString: "Reload open pages for this change to take effect.")
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "Site Access")
    /// The bounded, scrolling details region (everything except Done).
    let detailScroll = NSScrollView()
    private let subheading = NSTextField(labelWithString: "")

    /// Popup tags.
    private enum Choice: Int { case withheld = 0, specific = 1, allRequested = 2 }

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Site Access — Bam"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(in: window)
        render(previous: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Presentation

    /// Shows the editor for a fresh engine snapshot: as a sheet on `parent`, or as its own window. Reopening resets
    /// any typed text, draft, feedback and notice.
    func show(_ snapshot: Snapshot, relativeTo parent: NSWindow?) {
        reset(to: snapshot)
        guard let window else { return }
        if let parent, parent.attachedSheet == nil { parent.beginSheet(window) } else { window.center(); showWindow(nil) }
        window.makeFirstResponder(modeMenu)
    }
    /// Replaces the snapshot without presenting (engine-side changes while open, and tests).
    func reset(to snapshot: Snapshot) {
        generation &+= 1   // any answer still on its way belongs to what was shown before
        self.snapshot = snapshot; draftingSites = false; busy = false
        siteField.stringValue = ""; subdomainsBox.state = .off; feedbackLabel.stringValue = ""; reloadNotice.isHidden = true
        render(previous: nil)
    }
    @objc func done() {
        generation &+= 1; busy = false
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
        onClose?()
    }
    func windowWillClose(_ notification: Notification) { generation &+= 1; busy = false; onClose?() }

    // MARK: Layout (Manage Extensions' language: semibold heading, 12 pt secondary detail, native controls)

    private func build(in window: NSWindow) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 470))
        window.contentView = root
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        subheading.font = .systemFont(ofSize: 12); subheading.textColor = .secondaryLabelColor
        let prompt = NSTextField(labelWithString: "Access to the sites it requests:")
        prompt.font = .systemFont(ofSize: 13)
        modeMenu.target = self; modeMenu.action = #selector(modeChanged)
        let modeRow = NSStackView(views: [prompt, modeMenu]); modeRow.spacing = 8
        for label in [modeHelp, requestedLabel, optionalLabel, pendingLabel, reloadNotice] {
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor; label.preferredMaxLayoutWidth = 436
        }
        reloadNotice.textColor = .labelColor; reloadNotice.isHidden = true
        feedbackLabel.font = .systemFont(ofSize: 12); feedbackLabel.textColor = .systemRed; feedbackLabel.preferredMaxLayoutWidth = 436
        feedbackLabel.setAccessibilityLabel("Site access message")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site")); column.width = 420
        sitesTable.addTableColumn(column); sitesTable.headerView = nil; sitesTable.rowHeight = 22
        sitesTable.dataSource = self; sitesTable.delegate = self
        sitesTable.setAccessibilityLabel("Allowed sites")
        sitesScroll.documentView = sitesTable; sitesScroll.hasVerticalScroller = true; sitesScroll.borderType = .bezelBorder
        sitesScroll.translatesAutoresizingMaskIntoConstraints = false
        sitesScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        sitesScroll.widthAnchor.constraint(equalToConstant: 436).isActive = true
        siteField.placeholderString = "example.com"
        siteField.setAccessibilityLabel("Site to allow")
        siteField.target = self; siteField.action = #selector(addSite)   // Return in the field adds
        siteField.translatesAutoresizingMaskIntoConstraints = false
        siteField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        subdomainsBox.setAccessibilityLabel("Include subdomains of the site")
        addButton.target = self; addButton.action = #selector(addSite)
        removeButton.target = self; removeButton.action = #selector(removeSelectedSite)
        removeButton.setAccessibilityLabel("Remove selected site")
        let addRow = NSStackView(views: [siteField, subdomainsBox, addButton]); addRow.spacing = 8
        let listRow = NSStackView(views: [sitesScroll])
        let removeRow = NSStackView(views: [removeButton])
        editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 6
        [listRow, removeRow, addRow].forEach(editor.addArrangedSubview)

        pendingButton.target = self; pendingButton.action = #selector(reviewPending)
        pendingRow.orientation = .vertical; pendingRow.alignment = .leading; pendingRow.spacing = 6
        [pendingLabel, pendingButton].forEach(pendingRow.addArrangedSubview)

        doneButton.target = self; doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\u{1b}"   // Escape closes; changes already applied by the engine
        // Long manifests (many requested, pending or optional sites) never push controls out of the window: the
        // details scroll inside a bounded region, and Done stays in a fixed footer.
        let stack = NSStackView(views: [heading, subheading, modeRow, modeHelp, requestedLabel, editor, feedbackLabel,
                                        pendingRow, optionalLabel, reloadNotice])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 12, right: 22)
        stack.setCustomSpacing(2, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = PanelDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        detailScroll.drawsBackground = false; detailScroll.hasVerticalScroller = true; detailScroll.autohidesScrollers = true
        detailScroll.borderType = .noBorder; detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = document
        detailScroll.setAccessibilityLabel("Site access details")
        let footer = NSStackView(views: [NSView(), doneButton]); footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false
        [detailScroll, separator, footer].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            detailScroll.topAnchor.constraint(equalTo: root.topAnchor), detailScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), detailScroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor), separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            document.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        window.initialFirstResponder = modeMenu
        Self.dress?(window, root)
    }

    // MARK: Rendering (pure function of the snapshot plus the local draft)

    /// The mode's wording. "On click" only when one-time access exists; never promised otherwise.
    static func title(for choice: Int, oneTimeAccess: Bool, requestsAllSites: Bool) -> String {
        switch choice {
        case Choice.withheld.rawValue: return oneTimeAccess ? "On click" : "No requested sites"
        case Choice.specific.rawValue: return "On specific sites"
        default: return requestsAllSites ? "On all sites" : "On all requested sites"
        }
    }
    /// Describes only what THIS setting grants of the requested sites (a separately approved optional grant may
    /// overlap them, so nothing here denies access), and says separately approved access remains. Patterns aren't
    /// counted as sites (one optional `*://*/*` is every site).
    static let separatelyApproved = "Separately approved access remains (listed below)."
    static func help(for mode: ExtensionSiteAccess.Mode, drafting: Bool, oneTimeAccess: Bool, hasOptionalGrants: Bool = false) -> String {
        let requested: String
        if drafting { requested = "Add a site below to allow only specific requested sites. Until then, this setting stays as it is." }
        else {
            switch mode {
            case .withheld:
                requested = oneTimeAccess
                    ? "This setting allows none of the sites it requests in advance. Click the extension’s button on a page to let it run on that tab."
                    : "This setting allows none of the sites it requests. This extension doesn’t support one-time access on click; choose “On specific sites” to allow some."
            case .specific(let sites):
                requested = "This setting allows it only on \(sites.count == 1 ? "the site" : "the \(sites.count) site entries") you chose from those it requests."
            case .allRequested: requested = "This setting allows every site it requests that you approved."
            }
        }
        return hasOptionalGrants ? requested + " " + separatelyApproved : requested
    }
    static func describe(_ refusal: ExtensionSiteAccess.Refusal) -> String {
        switch refusal {
        case .empty: return "Type a site, like example.com."
        case .invalid: return "That isn’t a website address."
        case .unsupportedScheme(let scheme): return "Only http and https sites can be allowed, not \(scheme):."
        case .allSites: return "To allow every site, choose “On all requested sites”."
        case .notRequested: return "This extension doesn’t request that site, so it can’t be allowed."
        }
    }
    private var choice: Choice {
        if draftingSites { return .specific }
        switch snapshot.state.mode { case .withheld: return .withheld; case .specific: return .specific; case .allRequested: return .allRequested }
    }

    private func render(previous: Snapshot?) {
        let decl = snapshot.declarations, state = snapshot.state
        let requestsAll = Self.requestsAllSites(decl)
        subheading.stringValue = "\(snapshot.extensionName) · \(snapshot.profileName)"
        modeMenu.removeAllItems()
        for tag in [Choice.withheld, .specific, .allRequested] {
            modeMenu.addItem(withTitle: Self.title(for: tag.rawValue, oneTimeAccess: snapshot.oneTimeAccess, requestsAllSites: requestsAll))
            modeMenu.lastItem?.tag = tag.rawValue
        }
        modeMenu.selectItem(withTag: choice.rawValue)
        modeMenu.setAccessibilityLabel("Site access for \(snapshot.extensionName)")
        let requestsNothing = decl.requested.isEmpty
        let hasOptional = state.optionalGrants.contains { ExtensionSiteAccess.isCovered($0, by: decl.optional + decl.requested) }
        modeHelp.stringValue = requestsNothing
            ? "This extension doesn’t require access to any website." + (hasOptional ? " " + Self.separatelyApproved : "")
            : Self.help(for: state.mode, drafting: draftingSites, oneTimeAccess: snapshot.oneTimeAccess, hasOptionalGrants: hasOptional)
        requestedLabel.stringValue = requestsNothing ? "" : "Requested: " + decl.requested.sorted().joined(separator: ", ")
        requestedLabel.isHidden = requestsNothing
        let sites: [String] = { if case .specific(let sites) = state.mode, !draftingSites { return sites }; return [] }()
        // Reload only when the list changed, so a selection (and Remove) survives unrelated re-renders.
        if sites != listedSites { listedSites = sites; sitesTable.reloadData() }
        editor.isHidden = requestsNothing || choice != .specific
        let pending = ExtensionSiteAccess.pendingRequests(state, declarations: decl)
        pendingRow.isHidden = pending.isEmpty
        pendingLabel.stringValue = pending.isEmpty ? "" : "Not allowed yet (newly requested): " + pending.joined(separator: ", ")
        // Optional grants: allowed when the extension asked, and untouched by this setting. Never shown as revoked.
        let optional = state.optionalGrants.filter { ExtensionSiteAccess.isCovered($0, by: decl.optional + decl.requested) }
        optionalLabel.isHidden = optional.isEmpty
        optionalLabel.stringValue = optional.isEmpty ? ""
            : "Allowed separately because the extension asked and you agreed (this setting doesn’t change them): " + optional.joined(separator: ", ")
        if let message = snapshot.message { feedbackLabel.stringValue = message }
        feedbackLabel.isHidden = feedbackLabel.stringValue.isEmpty
        // Reload notice only when the engine's answer changed what is actually granted.
        if let previous {
            let before = ExtensionSiteAccess.grantedPatterns(previous.state, declarations: previous.declarations)
            let after = ExtensionSiteAccess.grantedPatterns(snapshot.state, declarations: snapshot.declarations)
            if before != after { reloadNotice.isHidden = false }
        }
        let enabled = !busy && !requestsNothing
        modeMenu.isEnabled = enabled
        [siteField, subdomainsBox, addButton].forEach { $0.isEnabled = enabled }
        updateRemoveButton()
        pendingButton.isEnabled = !busy
    }
    private func updateRemoveButton() {
        removeButton.isEnabled = !busy && !snapshot.declarations.requested.isEmpty && listedSites.indices.contains(sitesTable.selectedRow)
    }

    // MARK: Actions → engine

    private func send(_ action: Action) {
        guard let perform, !busy else { return }
        generation &+= 1
        let token = generation, before = snapshot
        busy = true; feedbackLabel.stringValue = ""; render(previous: nil)
        let request = Request(extensionID: before.extensionID, profileID: before.profileID, revision: before.revision,
                              displayed: before.declarations, action: action)
        perform(request) { [weak self] result in
            // Only the answer to the request still current applies: not one for a snapshot replaced by reset/show,
            // closed, or superseded; and never a snapshot for another extension or profile.
            guard let self, token == self.generation else { return }
            if case .success(let next) = result, next.extensionID != before.extensionID || next.profileID != before.profileID { return }
            self.busy = false
            switch result {
            case .success(let next):
                self.snapshot = next
                if case .specific = next.state.mode { self.draftingSites = false }
                if case .addSite = action { self.siteField.stringValue = ""; self.subdomainsBox.state = .off }
                self.render(previous: before)
            case .failure(let failure):
                switch failure {
                case .refused(let refusal): self.feedbackLabel.stringValue = Self.describe(refusal)
                case .failed(let message): self.feedbackLabel.stringValue = message
                }
                self.render(previous: nil)
                NSAccessibility.post(element: self.feedbackLabel, notification: .announcementRequested,
                                     userInfo: [.announcement: self.feedbackLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }
    @objc private func modeChanged() {
        guard let picked = Choice(rawValue: modeMenu.selectedTag()) else { return }
        switch picked {
        case .specific:
            // Never an empty site list: open the editor; the first added site makes the change.
            if case .specific = snapshot.state.mode { return }
            draftingSites = true; feedbackLabel.stringValue = ""; render(previous: nil)
            window?.makeFirstResponder(siteField)
        case .withheld:
            draftingSites = false
            if case .withheld = snapshot.state.mode { render(previous: nil); return }
            send(.choose(.withheld))
        case .allRequested:
            draftingSites = false
            if case .allRequested = snapshot.state.mode { render(previous: nil); return }
            send(.choose(.allRequested))
        }
    }
    @objc private func addSite() {
        let text = siteField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedbackLabel.stringValue = Self.describe(.empty); render(previous: nil); return
        }
        send(.addSite(input: text, includeSubdomains: subdomainsBox.state == .on))
    }
    @objc private func removeSelectedSite() {
        let row = sitesTable.selectedRow
        guard listedSites.indices.contains(row) else { return }
        send(.removeSite(listedSites[row]))
    }
    @objc private func reviewPending() {
        guard !busy else { return }
        let reviewed = snapshot, token = generation
        let pending = ExtensionSiteAccess.pendingRequests(reviewed.state, declarations: reviewed.declarations)
        guard !pending.isEmpty else { return }
        let allowed = (confirmPending ?? Self.confirmWithAlert)(pending, reviewed)
        // The review is modal: the panel may have been reset, reopened for another extension, closed, or the
        // engine may have changed this one meanwhile. Approve only what was reviewed, for exactly that snapshot.
        let unchanged = token == generation && !busy && snapshot.extensionID == reviewed.extensionID && snapshot.profileID == reviewed.profileID
            && snapshot.revision == reviewed.revision && ExtensionSiteAccess.pendingRequests(snapshot.state, declarations: snapshot.declarations) == pending
        guard allowed else { return }
        guard unchanged else {
            if snapshot.extensionID == reviewed.extensionID && snapshot.profileID == reviewed.profileID {
                feedbackLabel.stringValue = "Site access changed while you were reviewing. Review the new sites again."
                render(previous: nil)
            }
            return
        }
        send(.acceptPending(pending))
    }
    static func confirmWithAlert(_ sites: [String], _ snapshot: Snapshot) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow \(snapshot.extensionName) on new sites?"
        alert.informativeText = "Profile: \(snapshot.profileName)\nIt will be able to read and change data on:\n" + sites.joined(separator: "\n")
        alert.addButton(withTitle: "Don’t Allow"); alert.addButton(withTitle: "Allow")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: Site list

    func numberOfRows(in tableView: NSTableView) -> Int { listedSites.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: listedSites.indices.contains(row) ? listedSites[row] : "")
        label.font = .systemFont(ofSize: 12); label.setAccessibilityLabel(label.stringValue)
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateRemoveButton() }
    /// Delete or Forward Delete in the site list removes the selected site (the Remove button's equivalent).
    override func deleteBackward(_ sender: Any?) { if window?.firstResponder === sitesTable { removeSelectedSite() } else { super.deleteBackward(sender) } }
    override func deleteForward(_ sender: Any?) { deleteBackward(sender) }

    /// Whether a request covers every host (worded "On all sites").
    private static func requestsAllSites(_ declarations: ExtensionSiteAccess.Declarations) -> Bool {
        declarations.requested.contains { pattern in
            guard let parsed = try? WKWebExtension.MatchPattern(string: pattern) else { return false }
            return parsed.matchesAllURLs || parsed.matchesAllHosts
        }
    }
}

/// Flipped so the details start at the top of their scroll region.
private final class PanelDocumentView: NSView { override var isFlipped: Bool { true } }
