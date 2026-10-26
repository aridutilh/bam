import AppKit

/// Bam's own quit confirmation: a centered card over a dimmed browser window with
/// the app icon, "Quit Bam?", and Quit, and don't ask again / Cancel (esc) / Quit (return).
/// It runs a modal session so the synchronous quit flow keeps its contract.
@MainActor final class QuitConfirmationPanel: NSPanel {
    private var choice: QuitConfirmationChoice = .cancel

    static func run(over parent: NSWindow?, appName: String, icon: NSImage?) -> QuitConfirmationChoice {
        let panel = QuitConfirmationPanel(appName: appName, icon: icon)
        let previousKey = NSApp.keyWindow
        var dim: NSWindow?
        if let parent, parent.isVisible, !parent.isMiniaturized {
            let shade = NSWindow(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
            shade.isOpaque = false
            shade.backgroundColor = NSColor.black.withAlphaComponent(0.32)
            shade.hasShadow = false
            shade.isReleasedWhenClosed = false
            shade.setAccessibilityElement(false)
            parent.addChildWindow(shade, ordered: .above)
            dim = shade
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                         y: parent.frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if let dim { dim.parent?.removeChildWindow(dim); dim.orderOut(nil) }
        // Cancel returns focus to where it was; quitting needs no restoration.
        if panel.choice == .cancel, let previousKey, previousKey.isVisible { previousKey.makeKeyAndOrderFront(nil) }
        return panel.choice
    }

    private init(appName: String, icon: NSImage?) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        let title = QuitConfirmationModel.title(appName: appName)
        self.title = title
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(title)

        let card = QuitConfirmationCard(frame: NSRect(origin: .zero, size: frame.size))
        contentView = card

        let image = NSImageView(image: icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityElement(false)
        let heading = NSTextField(labelWithString: title)
        // Bam's sans at semibold: Bricolage's Q carries a long flat tail that reads as an underline in a short heading.
        heading.font = BamType.sans(19, weight: .semibold)
        heading.textColor = BamTheme.ink
        heading.setAccessibilityRole(.staticText)

        let neverAsk = button("Quit, and don’t ask again", prominent: false, key: nil, action: #selector(quitAndStopAsking))
        let cancel = button("Cancel", prominent: false, key: "esc", action: #selector(cancelChoice))
        let quit = button("Quit", prominent: true, key: "↩", action: #selector(quitChoice))
        cancel.keyEquivalent = "\u{1b}"
        quit.keyEquivalent = "\r"
        neverAsk.setAccessibilityHelp("Quits now and stops asking. Turn it back on in Settings › General.")

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [neverAsk, spacer, cancel, quit])
        buttons.orientation = .horizontal; buttons.spacing = 8; buttons.alignment = .centerY
        buttons.setCustomSpacing(16, after: neverAsk)
        for view in [image, heading, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(view) }
        // One left edge for the icon's artwork, the heading and the buttons. A macOS app icon's artwork sits about
        // 10% inside its canvas, so the 60-point image starts 6 points further out.
        let inset: CGFloat = 24, iconArtInset: CGFloat = 6
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset - iconArtInset),
            image.topAnchor.constraint(equalTo: card.topAnchor, constant: inset - iconArtInset),
            image.widthAnchor.constraint(equalToConstant: 60), image.heightAnchor.constraint(equalToConstant: 60),
            heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -inset),
            heading.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            buttons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset)
        ])
        initialFirstResponder = quit
    }

    private func button(_ title: String, prominent: Bool, key: String?, action: Selector) -> NSButton {
        // A keyed button draws no title of its own: the title and its keycap are laid out side by side inside it, and
        // the button widens to hold both (never centred text with spaces left for the cap).
        let button = QuitDialogButton(title: key == nil ? title : "", prominent: prominent)
        button.target = self; button.action = action
        button.setAccessibilityLabel(title)
        guard let key else { return button }
        let label = NSTextField(labelWithString: title)
        label.font = QuitDialogButton.titleFont
        label.textColor = prominent ? BamTheme.white : BamTheme.ink
        label.setAccessibilityElement(false)
        let cap = QuitKeycap(key == "esc" ? "ESC" : key, onProminent: prominent)
        let content = QuitKeyedTitle(views: [label, cap])
        content.orientation = .horizontal; content.spacing = 8; content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        button.setAccessibilityHelp(key == "esc" ? "Escape" : "Return")
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -8)
        ])
        return button
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if let choice = QuitConfirmationModel.choice(keyCode: event.keyCode, modifiers: event.modifierFlags) { finish(choice) }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { finish(.cancel) }
    @objc private func cancelChoice() { finish(.cancel) }
    @objc private func quitChoice() { finish(.quit) }
    @objc private func quitAndStopAsking() { finish(.quitAndStopAsking) }
    private func finish(_ choice: QuitConfirmationChoice) {
        self.choice = choice
        if NSApp.modalWindow === self { NSApp.stopModal() }
    }
}

/// A keyed button's title and keycap. Clicks go to the button itself.
@MainActor private final class QuitKeyedTitle: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The dialog's buttons: flat and compact, in Bam's colours. Local to this panel, so the shared BamPillButton keeps
/// its raised look elsewhere. Hover lightens and pressing darkens the face; there is no lip.
@MainActor private final class QuitDialogButton: NSButton {
    static let radius: CGFloat = 8
    static var titleFont: NSFont { BamType.sans(13, weight: .medium) }
    private let prominent: Bool
    private var hovering = false { didSet { needsDisplay = true } }
    init(title: String, prominent: Bool) {
        self.prominent = prominent
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        let ink = prominent ? BamTheme.white : BamTheme.ink
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Self.titleFont, .foregroundColor: ink])
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        (prominent ? BamTheme.red : BamTheme.card).setFill(); face.fill()
        // A wash over the face: ink tints the quiet buttons the right way in light and dark.
        let wash: NSColor? = isHighlighted ? (prominent ? NSColor.black.withAlphaComponent(0.16) : BamTheme.ink.withAlphaComponent(0.10))
            : hovering ? (prominent ? NSColor.white.withAlphaComponent(0.12) : BamTheme.ink.withAlphaComponent(0.05)) : nil
        if let wash { wash.setFill(); face.fill() }
        (prominent ? BamTheme.redDeep : BamTheme.line).setStroke()
        face.lineWidth = 1; face.stroke()
        super.draw(dirtyRect)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += 28; return size }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A filled keycap (no outline), as in Little Bam: muted on the quiet buttons, a white tint on the red one.
@MainActor private final class QuitKeycap: NSView {
    private let onProminent: Bool
    init(_ key: String, onProminent: Bool) {
        self.onProminent = onProminent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        let ink = onProminent ? BamTheme.white : BamTheme.muted
        // Return is the SF Symbol: the monospaced font's ↩ falls back to a glyph too small to read.
        let label: NSView
        if key == "↩", let symbol = NSImage(systemSymbolName: "return", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            let image = NSImageView(image: symbol); image.contentTintColor = ink
            label = image
        } else {
            let text = NSTextField(labelWithString: key)
            text.font = BamType.mono(10.5, weight: .semibold); text.textColor = ink; text.alignment = .center
            label = text
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityElement(false); label.setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18), widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5)
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        layer?.backgroundColor = bamCG(onProminent ? NSColor.white.withAlphaComponent(0.22) : BamTheme.ink.withAlphaComponent(0.10))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// The card: Bam paper, a hairline border and a modest corner.
@MainActor private final class QuitConfirmationCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        layer?.backgroundColor = bamCG(BamTheme.surface)
        layer?.borderColor = bamCG(BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}
