import AppKit
import UniformTypeIdentifiers

/// The Import from Arc sheet. Header (title, source) and footer (Cancel,
/// Import) stay pinned; the preview, options and notices scroll between them,
/// so long reports never push the buttons out of reach. The sheet resizes.
@MainActor final class ArcImportController: NSWindowController {
    typealias Commit = (ArcImport.Source, ArcImport.Options, @escaping (String?) -> Void) -> Void
    var preview: ((ArcImport.Source, ArcImport.Options) -> ArcImport.Report)?
    var onCommit: Commit?
    var onDismiss: (() -> Void)?
    private(set) var source: ArcImport.Source?
    private(set) var options = ArcImport.Options()
    private(set) var report: ArcImport.Report?
    private(set) var isCommitting = false
    let sourceLabel = NSTextField(labelWithString: "No layout chosen")
    let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    let body = NSStackView()
    let bodyScroll = NSScrollView()
    private let summary = NSStackView()
    let notices = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    let todayBox = NSButton(checkboxWithTitle: "Include Today tabs", target: nil, action: nil)
    let favoritesBox = NSButton(checkboxWithTitle: "Include Favorites", target: nil, action: nil)
    let recoverBox = NSButton(checkboxWithTitle: "Also bring in Favorites from other Arc profiles, each in its own Space and login profile",
                              target: nil, action: nil)
    let importButton = NSButton(title: "Import", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// One checkbox row per Arc Space, built once per loaded file so keyboard
    /// focus survives the live recount; below them, rows for Spaces made from
    /// other Arc profiles' Favorites (governed by `recoverBox`, not a checkbox).
    let spacesList = NSStackView()
    private let extraRows = NSStackView()
    private(set) var spaceBoxes: [String: NSButton] = [:]
    private var spaceDetails: [String: NSTextField] = [:]
    /// Arc Space IDs the user left out. Stored as exclusions so a new or
    /// reloaded file starts with every Space selected, and IDs that aren't in
    /// the current file never suppress anything.
    private(set) var excludedSpaceIDs: Set<String> = []
    static let minimumSize = NSSize(width: 480, height: 400)

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = "Import from Arc"; panel.isReleasedWhenClosed = false
        panel.contentMinSize = Self.minimumSize
        // Space checkboxes are added per file; Tab must reach them.
        panel.autorecalculatesKeyViewLoop = true
        super.init(window: panel)
        build(in: panel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    /// Wrapping text reports its whole one-line width as intrinsic; at the
    /// default compression resistance that outranks the window's own sizing
    /// and keeps the sheet from reaching its minimum width. Let it wrap instead.
    private static func wraps(_ view: NSView) {
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func build(in panel: NSPanel) {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content
        // Header
        let title = NSTextField(labelWithString: "Import from Arc")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString: "Bam reads Arc’s sidebar layout file and adds your Spaces, folders, kept tabs, Today tabs and Favorites. Arc isn’t changed. Imported pages stay asleep until you open them.")
        intro.textColor = .secondaryLabelColor; intro.font = .systemFont(ofSize: 12.5)
        for view in [intro, notices, status, recoverBox] as [NSView] { Self.wraps(view) }
        sourceLabel.lineBreakMode = .byTruncatingMiddle; sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 12); sourceLabel.setAccessibilityLabel("Layout file")
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.target = self; chooseButton.action = #selector(choose); chooseButton.bezelStyle = .rounded
        // The path takes only the width left after Choose File… and truncates in
        // the middle; the button always keeps its full width at the trailing edge.
        // (A stack view here would clip the button instead of shrinking the label.)
        let sourceRow = NSView()
        for view in [sourceLabel, chooseButton] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; sourceRow.addSubview(view) }
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            sourceLabel.leadingAnchor.constraint(equalTo: sourceRow.leadingAnchor),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: chooseButton.leadingAnchor, constant: -10),
            chooseButton.trailingAnchor.constraint(equalTo: sourceRow.trailingAnchor),
            sourceLabel.centerYAnchor.constraint(equalTo: sourceRow.centerYAnchor),
            chooseButton.centerYAnchor.constraint(equalTo: sourceRow.centerYAnchor),
            chooseButton.topAnchor.constraint(greaterThanOrEqualTo: sourceRow.topAnchor),
            chooseButton.bottomAnchor.constraint(lessThanOrEqualTo: sourceRow.bottomAnchor),
            sourceRow.heightAnchor.constraint(equalTo: chooseButton.heightAnchor)
        ])
        let header = NSStackView(views: [title, intro, sourceRow])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 8; header.setCustomSpacing(4, after: title)
        // Body (scrolls)
        summary.orientation = .vertical; summary.alignment = .leading; summary.spacing = 6
        summary.setAccessibilityElement(true); summary.setAccessibilityRole(.group); summary.setAccessibilityLabel("Import preview")
        notices.font = .systemFont(ofSize: 11.5); notices.textColor = .secondaryLabelColor
        notices.setAccessibilityLabel("What won’t be imported exactly")
        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .systemRed; status.isHidden = true
        for box in [todayBox, favoritesBox, recoverBox] { box.target = self; box.action = #selector(optionsChanged) }
        todayBox.state = .on; favoritesBox.state = .on; recoverBox.state = .off
        recoverBox.lineBreakMode = .byWordWrapping; recoverBox.usesSingleLineMode = false
        spacesList.orientation = .vertical; spacesList.alignment = .leading; spacesList.spacing = 8
        spacesList.setClippingResistancePriority(.defaultLow, for: .horizontal)
        spacesList.setAccessibilityElement(true); spacesList.setAccessibilityRole(.group); spacesList.setAccessibilityLabel("Spaces to import")
        extraRows.orientation = .vertical; extraRows.alignment = .leading; extraRows.spacing = 6
        body.setViews([summary, spacesList, todayBox, favoritesBox, recoverBox, notices, status], in: .top)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.setCustomSpacing(12, after: summary); body.setCustomSpacing(16, after: spacesList); body.setCustomSpacing(14, after: recoverBox)
        bodyScroll.hasVerticalScroller = true; bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .noBorder; bodyScroll.drawsBackground = false
        let document = Flipped()
        document.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body); bodyScroll.documentView = document
        // Footer (pinned)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self; importButton.action = #selector(commit); importButton.keyEquivalent = "\r"; importButton.isEnabled = false
        let footer = NSStackView(views: [spinner, NSView(), cancelButton, importButton]); footer.orientation = .horizontal; footer.spacing = 10
        let separator = NSBox(); separator.boxType = .separator
        for view in [header, bodyScroll, separator, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        for view in [summary, spacesList, notices, status, recoverBox] as [NSView] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        for view in [intro, sourceRow] as [NSView] { view.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bodyScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            bodyScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bodyScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            bodyScroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        // Header and footer keep their natural heights; the body absorbs resizing.
        for view in [header, footer] as [NSView] { view.setContentHuggingPriority(.required, for: .vertical); view.setContentCompressionResistancePriority(.required, for: .vertical) }
        render()
    }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onDismiss?() }
        window.makeFirstResponder(source == nil ? chooseButton : importButton)
    }

    /// Reads the file read-only and previews it. Errors leave nothing changed.
    func load(_ url: URL) {
        sourceLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        do {
            source = try ArcImport.load(from: url)
            status.isHidden = true
        } catch {
            source = nil; report = nil
            showError((error as? LocalizedError)?.errorDescription ?? "Bam couldn’t read that file.")
        }
        // Keep only exclusions that still name a Space in this file; every
        // other Space (including ones new to this file) starts selected.
        if let source { excludedSpaceIDs.formIntersection(source.spaces.map(\.id)) }
        rebuildSpaceRows()
        refreshPreview()
    }
    func refreshPreview() {
        options.includeToday = todayBox.state == .on
        options.includeFavorites = favoritesBox.state == .on
        options.includeUnattachedProfiles = recoverBox.state == .on && favoritesBox.state == .on
        // nil means every Space, exactly as before selection existed.
        let allIDs = source.map { Set($0.spaces.map(\.id)) } ?? []
        options.spaceIDs = excludedSpaceIDs.isEmpty ? nil : allIDs.subtracting(excludedSpaceIDs)
        report = source.flatMap { source in preview?(source, options) }
        render()
    }
    /// Includes or leaves out one Arc Space, as its checkbox does.
    func setSpace(_ id: String, included: Bool) {
        guard let source, source.spaces.contains(where: { $0.id == id }), !isCommitting else { return }
        if included { excludedSpaceIDs.remove(id) } else { excludedSpaceIDs.insert(id) }
        spaceBoxes[id]?.state = included ? .on : .off
        refreshPreview()
        if selectedSpaceCount == 0, let message = emptySelectionHint {
            NSAccessibility.post(element: spacesList, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    var selectedSpaceCount: Int { (source?.spaces ?? []).filter { !excludedSpaceIDs.contains($0.id) }.count }
    private static func spaceName(_ space: ArcImport.Space, index: Int) -> String {
        let title = space.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [space.emoji, title.isEmpty ? "Arc Space \(index + 1)" : title].compactMap { $0 }.joined(separator: " ")
    }
    /// Shown when no Space is selected and nothing else would be added.
    private var emptySelectionHint: String? {
        guard let report, report.isEmpty, report.refusal == nil, selectedSpaceCount == 0, source?.spaces.isEmpty == false else { return nil }
        return report.unattachedProfiles > 0 && recoverBox.state == .off
            ? "No Spaces selected. Select a Space to import, or bring in Favorites from other Arc profiles."
            : "No Spaces selected. Select at least one Space to import."
    }
    /// Why nothing would be added. With some Spaces left out, it speaks about
    /// the selected Spaces, not the whole layout.
    private func emptyHeadline(_ report: ArcImport.Report) -> String {
        guard !excludedSpaceIDs.isEmpty, report.skippedSpaces == 0 else { return report.emptyReason }
        if report.removedSpaces > 0 && report.alreadyImported == 0 {
            return "Nothing new: the selected Spaces were removed after an earlier import."
        }
        if report.alreadyImported > 0 { return "Everything Bam supports in the selected Spaces is already in Bam." }
        return "The selected Spaces have nothing Bam can import."
    }
    private func rebuildSpaceRows() {
        spacesList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        spaceBoxes = [:]; spaceDetails = [:]
        for (index, space) in (source?.spaces ?? []).enumerated() {
            let box = NSButton(checkboxWithTitle: Self.spaceName(space, index: index), target: self, action: #selector(spaceToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier("arc-space-\(space.id)")
            box.state = excludedSpaceIDs.contains(space.id) ? .off : .on
            box.font = .systemFont(ofSize: 13, weight: .medium)
            box.lineBreakMode = .byTruncatingTail
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = label("", size: 12, color: .secondaryLabelColor)
            detail.setAccessibilityElement(false)   // read as part of the checkbox
            let row = NSStackView(views: [box, detail]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 2
            // A long Space name truncates; it must never hold the sheet open wider.
            row.setClippingResistancePriority(.defaultLow, for: .horizontal)
            spacesList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: spacesList.widthAnchor).isActive = true
            box.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor).isActive = true
            // The counts line sits under the name, aligned with the checkbox title.
            detail.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20).isActive = true
            // Pinned to the row's width so long counts wrap instead of widening the sheet.
            detail.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            spaceBoxes[space.id] = box; spaceDetails[space.id] = detail
        }
        spacesList.addArrangedSubview(extraRows)
        extraRows.widthAnchor.constraint(equalTo: spacesList.widthAnchor).isActive = true
    }
    @objc private func spaceToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("arc-space-") else { return }
        setSpace(String(raw.dropFirst("arc-space-".count)), included: sender.state == .on)
    }
    /// "112 kept · 19 folders · …" for one Space's report row.
    private static func parts(_ space: ArcImport.SpaceReport) -> [String] {
        var parts: [String] = []
        if space.keptTabs > 0 { parts.append("\(space.keptTabs) kept") }
        if space.folders > 0 { parts.append("\(space.folders) folder\(space.folders == 1 ? "" : "s")") }
        if space.todayTabs > 0 { parts.append("\(space.todayTabs) Today") }
        if space.favorites > 0 { parts.append("\(space.favorites) Favorite\(space.favorites == 1 ? "" : "s")") }
        if space.splits > 0 { parts.append("\(space.splits) Split\(space.splits == 1 ? "" : "s")") }
        if space.easels > 0 { parts.append("\(space.easels) Easel reference\(space.easels == 1 ? "" : "s")") }
        if space.theme { parts.append("Arc theme") }
        return parts
    }
    func showError(_ message: String) {
        status.stringValue = message; status.textColor = .systemRed; status.isHidden = false
        NSAccessibility.post(element: status, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        status.scrollToVisible(status.bounds)
    }
    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        Self.wraps(field)
        return field
    }
    private func render() {
        summary.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func add(_ field: NSTextField) {
            summary.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        }
        guard let report else {
            add(label(source == nil ? "Choose Arc’s StorableSidebar.json (in ~/Library/Application Support/Arc) to see what will be imported." : "",
                      color: .secondaryLabelColor))
            importButton.isEnabled = false; notices.stringValue = ""
            recoverBox.isHidden = true; spacesList.isHidden = true
            return
        }
        spacesList.isHidden = spaceBoxes.isEmpty && report.spaces.isEmpty
        if let refusal = report.refusal { showError(refusal) }
        let newSpaces = report.spaces.filter(\.isNew).count
        let hint = emptySelectionHint
        let headline = hint != nil ? "No Spaces selected"
            : report.isEmpty ? emptyHeadline(report)
            : "\(report.importedTabs) tab\(report.importedTabs == 1 ? "" : "s") and \(report.importedFolders) folder\(report.importedFolders == 1 ? "" : "s")"
                + (newSpaces > 0 ? " into \(newSpaces) new Space\(newSpaces == 1 ? "" : "s")" : "")
        add(label(headline, size: 14, weight: .semibold))
        if let hint { add(label(String(hint.dropFirst("No Spaces selected. ".count)), size: 12, color: .secondaryLabelColor)) }
        // Each Arc Space's checkbox row: its name, then what it would add.
        for (id, box) in spaceBoxes {
            let included = !excludedSpaceIDs.contains(id)
            box.state = included ? .on : .off
            box.isEnabled = !isCommitting
            let row = report.spaces.first { $0.sourceSpaceID == id }
            let parts = row.map(Self.parts) ?? []
            let detail = !included ? "Not imported"
                : row == nil || parts.isEmpty ? "Nothing new to add"
                : parts.joined(separator: " · ") + (row?.isNew == false ? " — adds to an existing Space" : "")
            spaceDetails[id]?.stringValue = detail
            box.setAccessibilityLabel("\(box.title): \(detail)")
        }
        // Spaces made from other Arc profiles' Favorites, and new login profiles.
        extraRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func extra(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) {
            let field = label(text, size: size, color: color)
            extraRows.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: extraRows.widthAnchor).isActive = true
        }
        for space in report.spaces where space.sourceSpaceID == nil {
            let parts = Self.parts(space)
            extra("\(space.title) — \(parts.isEmpty ? "nothing new" : parts.joined(separator: " · "))")
        }
        for profile in report.newProfiles { extra("New login profile: \(profile)", size: 12, color: .secondaryLabelColor) }
        extraRows.isHidden = extraRows.arrangedSubviews.isEmpty
        recoverBox.isHidden = report.unattachedProfiles == 0 && recoverBox.state == .off
        notices.stringValue = report.notices.map { "• " + $0 }.joined(separator: "\n")
        importButton.isEnabled = !isCommitting && !report.isEmpty && report.refusal == nil
    }

    @objc private func optionsChanged() { refreshPreview() }
    @objc private func choose() {
        guard let window, !isCommitting else { return }
        let open = NSOpenPanel()
        open.title = "Choose Arc’s Sidebar Layout"
        open.message = "Arc keeps it at ~/Library/Application Support/Arc/StorableSidebar.json. Bam only reads it."
        open.prompt = "Preview"
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false; open.canChooseDirectories = false
        open.showsHiddenFiles = true
        open.directoryURL = ArcImport.defaultSourceURL().deletingLastPathComponent()
        open.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            self?.load(url)
        }
    }
    @objc private func cancel() { guard !isCommitting else { return }; finish() }
    /// Waits for the save outcome before closing; the sheet stays up with an
    /// explanation if the import could not be kept.
    @objc private func commit() {
        guard let source, let onCommit, !isCommitting else { return }
        isCommitting = true
        for control in [importButton, cancelButton, chooseButton, todayBox, favoritesBox, recoverBox] + Array(spaceBoxes.values) { control.isEnabled = false }
        status.stringValue = "Importing and saving…"; status.textColor = .secondaryLabelColor; status.isHidden = false
        spinner.startAnimation(nil)
        onCommit(source, options) { [weak self] failure in
            guard let self else { return }
            self.isCommitting = false; self.spinner.stopAnimation(nil)
            for control in [self.cancelButton, self.chooseButton, self.todayBox, self.favoritesBox, self.recoverBox] + Array(self.spaceBoxes.values) { control.isEnabled = true }
            if let failure { self.showError(failure); self.refreshPreview(); return }
            self.finish()
        }
    }
    private func finish() {
        guard let window, let parent = window.sheetParent else { onDismiss?(); return }
        parent.endSheet(window)
    }
}
