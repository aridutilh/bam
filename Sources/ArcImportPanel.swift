import AppKit
import UniformTypeIdentifiers

/// File > Import from Arc…: choose Arc's layout file, preview exactly what
/// will be added, then commit once. Nothing changes until Import is pressed.
@MainActor extension BrowserController {
    @objc func importFromArc(_ sender: Any?) {
        guard !isShuttingDown, !suspendsChromeInteraction, arcImporter == nil,
              let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress(); findBar.hide(); pageFeedback.hide()
        let importer = ArcImportController()
        arcImporter = importer
        importer.preview = { [weak self] source, options in
            guard let self else { return ArcImport.Report() }
            return ArcImport.apply(source, to: self.session, options: options).report
        }
        importer.onCommit = { [weak self] source, options in self?.commitArcImport(source, options: options) ?? "Bam is closing." }
        importer.onDismiss = { [weak self] in
            guard let self else { return }
            self.arcImporter = nil
            self.view.window?.makeFirstResponder(self.commandWebView)
        }
        importer.present(on: window)
        let defaultSource = ArcImport.defaultSourceURL()
        if FileManager.default.isReadableFile(atPath: defaultSource.path) { importer.load(defaultSource) }
    }

    /// Builds the imported session from the current one and commits it in a
    /// single step, then confirms it reached disk. Returns an error message,
    /// or nil on success. A failed save restores the previous session.
    func commitArcImport(_ source: ArcImport.Source, options: ArcImport.Options) -> String? {
        cancelPaging(); cancelAutomaticDepartures()
        let previous = session
        let (updated, report) = ArcImport.apply(source, to: session, options: options)
        if let refusal = report.refusal { return refusal }
        guard !report.isEmpty else { return "Everything in this layout is already in Bam." }
        session = updated
        if let first = report.firstSpaceID, session.spaceDefinition(first) != nil { session.changeSpace(first) }
        if let writer = sessionWriter, !privateMode {
            save()
            guard writer.flush(timeout: 5), writer.isLatestSnapshotSaved else {
                session = previous; save(); showActive(); refresh(); onSpacesChanged?()
                return "Bam couldn’t save the imported layout, so nothing was imported. Check free disk space and try again."
            }
        }
        showActive(); refreshPaletteResults(); onSpacesChanged?()
        let tabs = report.importedTabs
        pageFeedback.show("Imported \(tabs) tab\(tabs == 1 ? "" : "s") from Arc", symbol: "square.and.arrow.down", in: webHost)
        return nil
    }
}

@MainActor final class ArcImportController: NSWindowController {
    var preview: ((ArcImport.Source, ArcImport.Options) -> ArcImport.Report)?
    var onCommit: ((ArcImport.Source, ArcImport.Options) -> String?)?
    var onDismiss: (() -> Void)?
    private(set) var source: ArcImport.Source?
    private(set) var options = ArcImport.Options()
    private(set) var report: ArcImport.Report?
    private let sourceLabel = NSTextField(labelWithString: "No layout chosen")
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let summary = NSStackView()
    private let notices = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let todayBox = NSButton(checkboxWithTitle: "Include Today tabs", target: nil, action: nil)
    private let favoritesBox = NSButton(checkboxWithTitle: "Include Favorites", target: nil, action: nil)
    private let recoverBox = NSButton(checkboxWithTitle: "Also bring in Favorites from other Arc profiles, each in its own Space and login profile",
                                      target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Import from Arc"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        build(in: panel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(in panel: NSPanel) {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content
        let title = NSTextField(labelWithString: "Import from Arc")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString: "Bam reads Arc’s sidebar layout file and adds your Spaces, folders, kept tabs, Today tabs and Favorites. Arc isn’t changed. Imported pages stay asleep until you open them.")
        intro.textColor = .secondaryLabelColor; intro.font = .systemFont(ofSize: 12.5)
        sourceLabel.lineBreakMode = .byTruncatingMiddle; sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 12); sourceLabel.setAccessibilityLabel("Layout file")
        chooseButton.target = self; chooseButton.action = #selector(choose); chooseButton.bezelStyle = .rounded
        let sourceRow = NSStackView(views: [sourceLabel, chooseButton]); sourceRow.orientation = .horizontal; sourceRow.spacing = 10
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.orientation = .vertical; summary.alignment = .leading; summary.spacing = 6
        summary.setAccessibilityElement(true); summary.setAccessibilityRole(.group); summary.setAccessibilityLabel("Import preview")
        let summaryScroll = NSScrollView(); summaryScroll.hasVerticalScroller = true; summaryScroll.autohidesScrollers = true
        summaryScroll.borderType = .noBorder; summaryScroll.drawsBackground = false
        let document = FlippedContainer(); document.translatesAutoresizingMaskIntoConstraints = false
        summary.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(summary); summaryScroll.documentView = document
        notices.font = .systemFont(ofSize: 11.5); notices.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .systemRed; status.isHidden = true
        for box in [todayBox, favoritesBox, recoverBox] { box.target = self; box.action = #selector(optionsChanged) }
        todayBox.state = .on; favoritesBox.state = .on; recoverBox.state = .off
        cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self; importButton.action = #selector(commit); importButton.keyEquivalent = "\r"; importButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancelButton, importButton]); buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [title, intro, sourceRow, summaryScroll, todayBox, favoritesBox, recoverBox, notices, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.setCustomSpacing(4, after: title); stack.setCustomSpacing(14, after: intro); stack.setCustomSpacing(14, after: summaryScroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [intro, sourceRow, summaryScroll, notices, status, buttons, recoverBox] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            summaryScroll.heightAnchor.constraint(equalToConstant: 170),
            document.widthAnchor.constraint(equalTo: summaryScroll.contentView.widthAnchor),
            summary.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            summary.topAnchor.constraint(equalTo: document.topAnchor),
            summary.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        render()
    }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onDismiss?() }
        window.makeFirstResponder(source == nil ? chooseButton : importButton)
    }

    /// Reads the file read-only and previews it. Errors leave nothing changed.
    func load(_ url: URL) {
        do {
            source = try ArcImport.load(from: url)
            sourceLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            status.isHidden = true
        } catch {
            source = nil; report = nil
            sourceLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            showError((error as? LocalizedError)?.errorDescription ?? "Bam couldn’t read that file.")
        }
        refreshPreview()
    }
    private func refreshPreview() {
        options.includeToday = todayBox.state == .on
        options.includeFavorites = favoritesBox.state == .on
        options.includeUnattachedProfiles = recoverBox.state == .on && favoritesBox.state == .on
        report = source.flatMap { source in preview?(source, options) }
        render()
    }
    private func showError(_ message: String) {
        status.stringValue = message; status.isHidden = false
        NSAccessibility.post(element: status, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }
    private func render() {
        summary.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let report else {
            summary.addArrangedSubview(label(source == nil ? "Choose Arc’s StorableSidebar.json (in ~/Library/Application Support/Arc) to see what will be imported." : "",
                                             color: .secondaryLabelColor))
            importButton.isEnabled = false; notices.stringValue = ""
            recoverBox.isHidden = true
            return
        }
        if let refusal = report.refusal { showError(refusal) }
        let newSpaces = report.spaces.filter(\.isNew).count
        let headline = report.isEmpty ? "Everything in this layout is already in Bam."
            : "\(report.importedTabs) tabs and \(report.importedFolders) folders" + (newSpaces > 0 ? " into \(newSpaces) new Space\(newSpaces == 1 ? "" : "s")" : "")
        summary.addArrangedSubview(label(headline, size: 14, weight: .semibold))
        for space in report.spaces {
            var parts: [String] = []
            if space.keptTabs > 0 { parts.append("\(space.keptTabs) kept") }
            if space.folders > 0 { parts.append("\(space.folders) folder\(space.folders == 1 ? "" : "s")") }
            if space.todayTabs > 0 { parts.append("\(space.todayTabs) Today") }
            if space.favorites > 0 { parts.append("\(space.favorites) Favorite\(space.favorites == 1 ? "" : "s")") }
            if space.splits > 0 { parts.append("\(space.splits) Split\(space.splits == 1 ? "" : "s")") }
            let name = [space.emoji, space.title].compactMap { $0 }.joined(separator: " ")
            let row = label("\(name) — \(parts.isEmpty ? "nothing new" : parts.joined(separator: " · "))\(space.isNew ? "" : "  (adds to existing Space)")")
            row.setAccessibilityLabel("\(space.title): \(parts.isEmpty ? "nothing new" : parts.joined(separator: ", "))")
            summary.addArrangedSubview(row)
        }
        for profile in report.newProfiles {
            summary.addArrangedSubview(label("New login profile: \(profile)", size: 12, color: .secondaryLabelColor))
        }
        let unattached = report.unattachedProfiles
        recoverBox.isHidden = unattached == 0 && recoverBox.state == .off
        notices.stringValue = report.notices.map { "• " + $0 }.joined(separator: "\n")
        importButton.isEnabled = !report.isEmpty && report.refusal == nil
    }

    @objc private func optionsChanged() { refreshPreview() }
    @objc private func choose() {
        guard let window else { return }
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
    @objc private func cancel() { finish() }
    @objc private func commit() {
        guard let source, let onCommit else { return }
        importButton.isEnabled = false
        if let failure = onCommit(source, options) {
            showError(failure); refreshPreview(); return
        }
        finish()
    }
    private func finish() {
        guard let window, let parent = window.sheetParent else { onDismiss?(); return }
        parent.endSheet(window)
    }
}
