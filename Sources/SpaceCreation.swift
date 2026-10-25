import AppKit
import WebKit

/// The circle that fills while overscrolling past the last Space, prompting a
/// new Space the way Arc's end-of-spaces pull does.
@MainActor final class SpaceCreateIndicatorView: NSView {
    var progress: CGFloat = 0 {
        didSet {
            needsDisplay = true
            if progress >= 1, oldValue < 1 { pop() }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Keep swiping to create a new Space")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func pop() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let w = bounds.width / 2, h = bounds.height / 2
        func scaled(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(w, h, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -w, -h, 0)
        }
        let spring = CAKeyframeAnimation(keyPath: "transform")
        spring.values = [scaled(1), scaled(1.18), scaled(1)]
        spring.keyTimes = [0, 0.4, 1]
        spring.duration = 0.28
        layer.add(spring, forKey: "pop")
    }
    override func draw(_ dirtyRect: NSRect) {
        let full = progress >= 1
        let circle = bounds.insetBy(dx: 5, dy: 5)
        if full {
            ArkPalette.ink.setFill()
            NSBezierPath(ovalIn: circle).fill()
        } else {
            ArkPalette.ink.withAlphaComponent(0.28).setStroke()
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = 3.5
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
                          radius: circle.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * max(0, min(1, progress)), clockwise: true)
            arc.lineWidth = 3.5
            arc.lineCapStyle = .round
            ArkPalette.ink.setStroke()
            arc.stroke()
        }
        let plus = NSBezierPath()
        let arm: CGFloat = bounds.width * 0.17
        plus.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY))
        plus.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - arm))
        plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + arm))
        plus.lineWidth = 3
        plus.lineCapStyle = .round
        (full ? NSColor.chrome(light: .white, dark: NSColor.black.withAlphaComponent(0.8)) : ArkPalette.ink).setStroke()
        plus.stroke()
    }
}

/// The stacked-photos illustration at the top of the creation panel. Drawn
/// natively: fanned white-framed cards with abstract photo content.
@MainActor private final class SpaceCardStackView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let cards: [(angle: CGFloat, dx: CGFloat, fills: [NSColor])] = [
            (-14, -14, [NSColor(srgbRed: 0.42, green: 0.55, blue: 0.40, alpha: 1)]),
            (9, 12, [NSColor(srgbRed: 0.70, green: 0.46, blue: 0.34, alpha: 1)]),
            (-2, 0, [NSColor(srgbRed: 0.55, green: 0.57, blue: 0.62, alpha: 1),
                     NSColor(srgbRed: 0.78, green: 0.30, blue: 0.26, alpha: 1)])
        ]
        for card in cards {
            guard let context = NSGraphicsContext.current else { continue }
            context.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX + card.dx, yBy: bounds.midY)
            transform.rotate(byDegrees: card.angle)
            transform.concat()
            let frame = NSRect(x: -16, y: -21, width: 32, height: 42)
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 3.5, yRadius: 3.5).fill()
            NSShadow().set()
            // Abstract photo area inside the white border, leaving a wider base.
            let photo = NSRect(x: frame.minX + 3, y: frame.minY + 9, width: frame.width - 6, height: frame.height - 12)
            card.fills[0].setFill()
            NSBezierPath(roundedRect: photo, xRadius: 1.5, yRadius: 1.5).fill()
            if card.fills.count > 1 {
                card.fills[1].setFill()
                NSBezierPath(ovalIn: NSRect(x: photo.midX - 5, y: photo.midY - 1, width: 10, height: 10)).fill()
            }
            context.restoreGraphicsState()
        }
    }
}

/// A row container with the panel's shared rounded style.
@MainActor private final class SpaceCreationRow: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = resolvedCGColor(ArkPalette.field, for: self)
        layer?.cornerRadius = 11
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(ArkPalette.field, for: self)
    }
    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

/// Arc-style Space creation panel shown in the sidebar area: illustration,
/// name, profile, theme and the Create/Cancel actions.
@MainActor final class SpaceCreationPanel: NSView {
    var onCreate: ((String, Int, UUID) -> Void)?
    var onCancel: (() -> Void)?
    var onPreviewTheme: ((Int) -> Void)?

    private let stack = SpaceCardStackView()
    private let title = NSTextField(labelWithString: "Create a Space")
    private let subtitle = NSTextField(wrappingLabelWithString: "Separate your tabs for life, work, projects, and more.")
    private let nameRow = SpaceCreationRow()
    private let nameIcon = NSImageView()
    let nameField = PaletteField()
    private let profileRow = SpaceCreationRow()
    private let profileIcon = NSImageView()
    private let profileLabel = NSTextField(labelWithString: "Profile")
    private let profileChip = NSButton(title: "Default", target: nil, action: nil)
    private let themeRow = SpaceCreationRow()
    private let themeIcon = NSImageView()
    private let themeLabel = NSTextField(labelWithString: "Choose a Theme")
    private var swatches: [NSButton] = []
    private var themeExpanded = false
    private let createButton = NSButton(title: "Create Space", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let nameError = NSTextField(wrappingLabelWithString: "Use 1–60 characters without control characters.")
    private let profiles: [BrowserProfile]
    private(set) var selectedProfileID: UUID
    private(set) var selectedColorIndex: Int
    override var isFlipped: Bool { true }

    init(profiles: [BrowserProfile], defaultName: String, initialColorIndex: Int) {
        self.profiles = profiles.isEmpty ? BrowserProfile.defaults : profiles
        self.selectedProfileID = BrowserProfile.defaultID
        self.selectedColorIndex = max(0, min(CanvasView.palettes.count - 1, initialColorIndex))
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        addSubview(stack)

        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = ArkPalette.ink
        title.alignment = .center
        addSubview(title)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = ArkPalette.secondary
        subtitle.alignment = .center
        addSubview(subtitle)

        addSubview(nameRow)
        nameIcon.image = NSImage(systemSymbolName: "plus.square.dashed", accessibilityDescription: nil)
        nameIcon.contentTintColor = ArkPalette.secondary
        nameIcon.setAccessibilityElement(false)
        nameRow.addSubview(nameIcon)
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.isBordered = false; nameField.drawsBackground = false; nameField.focusRingType = .none
        nameField.textColor = ArkPalette.ink
        nameField.placeholderAttributedString = NSAttributedString(
            string: defaultName,
            attributes: [.foregroundColor: ArkPalette.secondary.withAlphaComponent(0.75),
                         .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        nameField.setAccessibilityLabel("Space name")
        nameField.escape = { [weak self] in self?.onCancel?() }
        nameField.delegate = self
        nameRow.addSubview(nameField)
        nameError.font = .systemFont(ofSize: 11)
        nameError.textColor = NSColor(srgbRed: 1, green: 0.62, blue: 0.56, alpha: 1)
        nameError.alignment = .center
        nameError.isHidden = true
        addSubview(nameError)

        addSubview(profileRow)
        profileIcon.image = NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: nil)
        profileIcon.contentTintColor = ArkPalette.secondary
        profileIcon.setAccessibilityElement(false)
        profileRow.addSubview(profileIcon)
        profileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        profileLabel.textColor = ArkPalette.ink
        profileRow.addSubview(profileLabel)
        profileChip.bezelStyle = .badge
        profileChip.font = .systemFont(ofSize: 11, weight: .semibold)
        profileChip.target = self
        profileChip.action = #selector(showProfileMenu)
        profileChip.setAccessibilityLabel("Profile for this Space")
        profileRow.addSubview(profileChip)
        profileRow.onClick = { [weak self] in self?.showProfileMenu() }

        addSubview(themeRow)
        themeIcon.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil)
        themeIcon.contentTintColor = ArkPalette.secondary
        themeIcon.setAccessibilityElement(false)
        themeRow.addSubview(themeIcon)
        themeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        themeLabel.textColor = ArkPalette.ink
        themeRow.addSubview(themeLabel)
        themeRow.onClick = { [weak self] in self?.toggleTheme() }
        themeRow.setAccessibilityElement(true)
        themeRow.setAccessibilityRole(.button)
        themeRow.setAccessibilityLabel("Choose a theme")

        for index in CanvasView.palettes.indices {
            let swatch = NSButton(title: "", target: self, action: #selector(chooseTheme(_:)))
            swatch.isBordered = false
            swatch.tag = index
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 13
            swatch.setAccessibilityLabel("\(BrowserSpace.colorNames[min(index, BrowserSpace.colorNames.count - 1)]) theme")
            swatch.isHidden = true
            addSubview(swatch)
            swatches.append(swatch)
        }

        createButton.isBordered = false
        createButton.wantsLayer = true
        createButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        createButton.layer?.cornerRadius = 11
        createButton.attributedTitle = NSAttributedString(
            string: "Create Space",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        createButton.target = self
        createButton.action = #selector(create)
        createButton.keyEquivalent = "\r"
        addSubview(createButton)
        cancelButton.isBordered = false
        cancelButton.attributedTitle = NSAttributedString(
            string: "Cancel",
            attributes: [.foregroundColor: ArkPalette.secondary, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        addSubview(cancelButton)

        refreshProfileChip()
        refreshSwatchSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refreshProfileChip() {
        let name = profiles.first(where: { $0.id == selectedProfileID })?.name ?? "Default"
        profileChip.attributedTitle = NSAttributedString(
            string: name,
            attributes: [.foregroundColor: ArkPalette.ink, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        profileChip.sizeToFit()
        needsLayout = true
    }
    @objc private func showProfileMenu() {
        let menu = NSMenu()
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(chooseProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == selectedProfileID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: profileChip.frame.minX, y: profileChip.frame.maxY + 4), in: profileRow)
    }
    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectedProfileID = id
        refreshProfileChip()
    }
    private func toggleTheme() {
        themeExpanded.toggle()
        for swatch in swatches { swatch.isHidden = !themeExpanded }
        needsLayout = true
        superview?.needsLayout = true
    }
    @objc private func chooseTheme(_ sender: NSButton) {
        selectedColorIndex = sender.tag
        refreshSwatchSelection()
        onPreviewTheme?(sender.tag)
    }
    /// Swatches preview the window wash for the current appearance.
    private func refreshSwatchSelection() {
        let palettes = effectiveAppearance.isDarkChrome ? CanvasView.palettes : CanvasView.lightPalettes
        for (index, swatch) in swatches.enumerated() {
            let pair = palettes[min(index, palettes.count - 1)]
            swatch.layer?.backgroundColor = pair[0].blended(withFraction: 0.5, of: pair[1])?.cgColor
            swatch.layer?.borderWidth = index == selectedColorIndex ? 2.5 : (effectiveAppearance.isDarkChrome ? 0 : 1)
            swatch.layer?.borderColor = resolvedCGColor(index == selectedColorIndex ? ArkPalette.ink : ArkPalette.separator, for: self)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSwatchSelection(); refreshProfileChip()
    }
    @objc private func create() {
        onCreate?(nameField.stringValue, selectedColorIndex, selectedProfileID)
    }
    @objc private func cancel() { onCancel?() }
    func showNameError() {
        nameError.isHidden = false
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
        needsLayout = true
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject? === nameField { nameError.isHidden = true }
    }

    override func layout() {
        super.layout()
        let margin: CGFloat = 20
        let cw = bounds.width - margin * 2
        // Flow from the top; short windows drop the illustration, and the
        // action buttons never ride up over the content.
        let compact = bounds.height < 560
        stack.isHidden = compact
        var y: CGFloat = compact ? 28 : 96
        if !compact {
            stack.frame = NSRect(x: bounds.midX - 40, y: y, width: 80, height: 76)
            y += 90
        }
        title.frame = NSRect(x: margin, y: y, width: cw, height: 22); y += 26
        subtitle.frame = NSRect(x: margin + 8, y: y, width: cw - 16, height: 34); y += 56
        nameRow.frame = NSRect(x: margin, y: y, width: cw, height: 42); y += 50
        nameIcon.frame = NSRect(x: 12, y: 12, width: 18, height: 18)
        nameField.frame = NSRect(x: 40, y: 12, width: nameRow.bounds.width - 52, height: 19)
        if !nameError.isHidden {
            nameError.frame = NSRect(x: margin, y: y - 6, width: cw, height: 15); y += 16
        }
        profileRow.frame = NSRect(x: margin, y: y, width: cw, height: 42); y += 50
        profileIcon.frame = NSRect(x: 12, y: 12, width: 18, height: 18)
        profileLabel.frame = NSRect(x: 40, y: 13, width: 70, height: 17)
        let chipWidth = max(54, profileChip.fittingSize.width + 14)
        profileChip.frame = NSRect(x: 40 + 70 + 6, y: 11, width: min(chipWidth, profileRow.bounds.width - 128), height: 20)
        themeRow.frame = NSRect(x: margin, y: y, width: cw, height: 42); y += 50
        themeIcon.frame = NSRect(x: 12, y: 12, width: 18, height: 18)
        themeLabel.frame = NSRect(x: 40, y: 13, width: themeRow.bounds.width - 52, height: 17)
        if themeExpanded {
            let count = swatches.count
            let spacing: CGFloat = 8
            let size: CGFloat = 26
            let total = CGFloat(count) * size + CGFloat(count - 1) * spacing
            var x = bounds.midX - total / 2
            for swatch in swatches {
                swatch.frame = NSRect(x: x, y: y, width: size, height: size)
                x += size + spacing
            }
            y += size + 12
        }
        let buttonsTop = max(y + 12, bounds.height - 96)
        createButton.frame = NSRect(x: margin, y: buttonsTop, width: cw, height: 40)
        cancelButton.frame = NSRect(x: margin, y: buttonsTop + 48, width: cw, height: 24)
    }
}

extension SpaceCreationPanel: NSTextFieldDelegate {}

extension BrowserController {
    func nextSpaceName() -> String {
        var suffix = 1, name = "New Space"
        while session.spaces.contains(where: { $0.name == name }) { suffix += 1; name = "New Space \(suffix)" }
        return name
    }

    func updateSpaceCreateIndicator(progress: CGFloat?) {
        guard let progress else {
            spaceCreateIndicator?.removeFromSuperview()
            spaceCreateIndicator = nil
            return
        }
        let indicator: SpaceCreateIndicatorView
        if let existing = spaceCreateIndicator { indicator = existing }
        else {
            indicator = SpaceCreateIndicatorView(frame: .zero)
            root.addSubview(indicator)
            spaceCreateIndicator = indicator
        }
        let side: CGFloat = 46
        let anchor = sidebar.frame.width > 40 ? sidebar.frame : NSRect(x: 0, y: 0, width: 240, height: root.bounds.height)
        indicator.frame = NSRect(x: anchor.midX - side / 2, y: anchor.midY - side / 2, width: side, height: side)
        indicator.alphaValue = 0.35 + 0.65 * progress
        indicator.progress = progress
    }

    func openSpaceCreation() {
        guard spaceCreationPanel == nil else { return }
        guard session.spaces.count < BrowserSession.maximumSpaces else { NSSound.beep(); return }
        dismissAddress()
        // Stop the rubber-band settle; its per-frame preview writes and
        // completion would otherwise clobber the panel's theme preview.
        cancelPaging()
        // Default to cycling the flat colors; Prism/Clear apply only by choice.
        let initialColor = session.spaces.count % BrowserSpace.flatColorCount
        let panel = SpaceCreationPanel(profiles: session.profiles, defaultName: nextSpaceName(), initialColorIndex: initialColor)
        panel.onCancel = { [weak self] in self?.dismissSpaceCreation() }
        panel.onPreviewTheme = { [weak self] index in
            self?.root.previewSpace = index
            self?.root.previewProgress = 1
        }
        panel.onCreate = { [weak self] name, colorIndex, profileID in
            self?.createSpaceFromPanel(name: name, colorIndex: colorIndex, profileID: profileID)
        }
        root.addSubview(panel)
        spaceCreationPanel = panel
        sidebar.isHidden = true
        root.previewSpace = initialColor
        root.previewProgress = 1
        layoutBrowser()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        view.window?.makeFirstResponder(panel.nameField)
        // Escape cancels wherever focus sits, including the web page.
        spaceCreationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.spaceCreationPanel != nil, event.keyCode == 53,
                  event.window === self.view.window, self.addressOverlay == nil else { return event }
            self.dismissSpaceCreation()
            return nil
        }
    }

    func layoutSpaceCreation() {
        guard let panel = spaceCreationPanel else { return }
        let width = max(250, min(300, CGFloat(session.sidebarWidth)))
        panel.frame = NSRect(x: 0, y: 0, width: width, height: root.bounds.height)
    }

    func dismissSpaceCreation() {
        guard let panel = spaceCreationPanel else { return }
        if let monitor = spaceCreationKeyMonitor { NSEvent.removeMonitor(monitor); spaceCreationKeyMonitor = nil }
        spaceCreationPanel = nil
        panel.removeFromSuperview()
        sidebar.isHidden = false
        root.previewSpace = nil
        root.previewProgress = 0
        view.window?.makeFirstResponder(commandWebView)
    }

    func createSpaceFromPanel(name: String, colorIndex: Int, profileID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? nextSpaceName() : trimmed
        guard let id = session.createSpace(name: finalName, symbol: "sparkles", colorIndex: colorIndex, profileID: profileID) else {
            // The Space cap was checked before opening; a refusal here means the name.
            spaceCreationPanel?.showNameError(); NSSound.beep(); return
        }
        dismissSpaceCreation()
        changeSpace(id)
        onSpacesChanged?()
        refresh(); save()
    }
}
