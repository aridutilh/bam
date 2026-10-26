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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 452, height: 222),
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
        heading.font = BamType.display(22, weight: .heavy)
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
        buttons.orientation = .horizontal; buttons.spacing = 10; buttons.alignment = .centerY
        for view in [image, heading, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(view) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            image.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            image.widthAnchor.constraint(equalToConstant: 60), image.heightAnchor.constraint(equalToConstant: 60),
            heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -28),
            heading.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            buttons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22)
        ])
        initialFirstResponder = quit
    }

    private func button(_ title: String, prominent: Bool, key: String?, action: Selector) -> NSButton {
        // A keycap hint sits inside the pill after the title; room is left for it.
        let button = BamPillButton(title: key == nil ? title : title + "         ", prominent: prominent)
        button.target = self; button.action = action
        button.setAccessibilityLabel(title)
        guard let key else { return button }
        let cap = NSTextField(labelWithString: key)
        cap.font = BamType.sans(11, weight: .bold)
        cap.textColor = prominent ? BamTheme.white : BamTheme.muted
        cap.alignment = .center
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 5
        cap.layer?.borderWidth = 1
        cap.layer?.borderColor = cap.bamCG(prominent ? BamTheme.white.withAlphaComponent(0.6) : BamTheme.line)
        cap.setAccessibilityElement(false)
        cap.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(cap)
        button.setAccessibilityHelp(key == "esc" ? "Escape" : "Return")
        NSLayoutConstraint.activate([
            cap.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            cap.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            cap.heightAnchor.constraint(equalToConstant: 18)
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

/// The card: Bam paper, a hairline border and a soft corner.
@MainActor private final class QuitConfirmationCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        layer?.backgroundColor = bamCG(BamTheme.surface)
        layer?.borderColor = bamCG(BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}
