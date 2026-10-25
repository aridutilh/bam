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
    static let minimumSize = NSSize(width: 480, height: 400)

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = "Import from Arc"; panel.isReleasedWhenClosed = false
        panel.contentMinSize = Self.minimumSize
        super.init(window: panel)
        build(in: panel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    private func build(in panel: NSPanel) {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content
        // Header
        let title = NSTextField(labelWithString: "Import from Arc")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString: "Bam reads Arc’s sidebar layout file and adds your Spaces, folders, kept tabs, Today tabs and Favorites. Arc isn’t changed. Imported pages stay asleep until you open them.")
        intro.textColor = .secondaryLabelColor; intro.font = .systemFont(ofSize: 12.5)
        sourceLabel.lineBreakMode = .byTruncatingMiddle; sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 12); sourceLabel.setAccessibilityLabel("Layout file")
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.target = self; chooseButton.action = #selector(choose); chooseButton.bezelStyle = .rounded
        let sourceRow = NSStackView(views: [sourceLabel, chooseButton]); sourceRow.orientation = .horizontal; sourceRow.spacing = 10
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
        body.setViews([summary, todayBox, favoritesBox, recoverBox, notices, status], in: .top)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.setCustomSpacing(16, after: summary); body.setCustomSpacing(14, after: recoverBox)
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
        for view in [summary, notices, status, recoverBox] as [NSView] {
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
        refreshPreview()
    }
    func refreshPreview() {
        options.includeToday = todayBox.state == .on
        options.includeFavorites = favoritesBox.state == .on
        options.includeUnattachedProfiles = recoverBox.state == .on && favoritesBox.state == .on
        report = source.flatMap { source in preview?(source, options) }
        render()
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
            recoverBox.isHidden = true
            return
        }
        if let refusal = report.refusal { showError(refusal) }
        let newSpaces = report.spaces.filter(\.isNew).count
        let headline = report.isEmpty ? report.emptyReason
            : "\(report.importedTabs) tabs and \(report.importedFolders) folders" + (newSpaces > 0 ? " into \(newSpaces) new Space\(newSpaces == 1 ? "" : "s")" : "")
        add(label(headline, size: 14, weight: .semibold))
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
            add(row)
        }
        for profile in report.newProfiles { add(label("New login profile: \(profile)", size: 12, color: .secondaryLabelColor)) }
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
        for control in [importButton, cancelButton, chooseButton, todayBox, favoritesBox, recoverBox] { control.isEnabled = false }
        status.stringValue = "Importing and saving…"; status.textColor = .secondaryLabelColor; status.isHidden = false
        spinner.startAnimation(nil)
        onCommit(source, options) { [weak self] failure in
            guard let self else { return }
            self.isCommitting = false; self.spinner.stopAnimation(nil)
            for control in [self.cancelButton, self.chooseButton, self.todayBox, self.favoritesBox, self.recoverBox] { control.isEnabled = true }
            if let failure { self.showError(failure); self.refreshPreview(); return }
            self.finish()
        }
    }
    private func finish() {
        guard let window, let parent = window.sheetParent else { onDismiss?(); return }
        parent.endSheet(window)
    }
}
