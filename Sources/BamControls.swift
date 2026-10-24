import AppKit
import QuartzCore

/// Bam's own control kit for settings-style surfaces: the same ink, washes
/// and pill shapes as onboarding and the sidebar, instead of Aqua controls.
@MainActor enum BamStyle {
    static let cardFill = NSColor.white.withAlphaComponent(0.06)
    static let cardBorder = NSColor.white.withAlphaComponent(0.12)
    static let separator = NSColor.white.withAlphaComponent(0.08)
    static let chipFill = NSColor.white.withAlphaComponent(0.07)
    static let chipPicked = NSColor.white.withAlphaComponent(0.18)
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The per-Space gradient wash and glow the browser window wears, as a plain
/// background that passes events through (onboarding's backdrop swallows them).
@MainActor final class BamBackdropView: NSView {
    private let wash = CAGradientLayer()
    private let glow = CAGradientLayer()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        wash.startPoint = CGPoint(x: 0.1, y: 1); wash.endPoint = CGPoint(x: 0.9, y: 0)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.85, y: 0.1); glow.endPoint = CGPoint(x: 1.5, y: 0.9)
        layer?.addSublayer(wash); layer?.addSublayer(glow)
        tint(colorIndex: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.frame = bounds; glow.frame = bounds
        CATransaction.commit()
    }
    func tint(colorIndex: Int) {
        let pair = CanvasView.palettes[min(CanvasView.palettes.count - 1, max(0, colorIndex))]
        let accent = ArkPalette.spaceColor(colorIndex)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.colors = pair.map(\.cgColor)
        glow.colors = [accent.withAlphaComponent(0.22).cgColor, accent.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }
}

/// A pill switch. Space or Return flips it from the keyboard; a click flips
/// it; the knob glides unless Reduce Motion is on.
@MainActor final class BamToggle: NSControl {
    var onChange: ((Bool) -> Void)?
    var accent: NSColor = ArkPalette.spaceColor(0) { didSet { paint(animated: false) } }
    var isOn = false { didSet { paint(animated: !BamStyle.reduceMotion); setAccessibilityValue(isOn ? "On" : "Off") } }
    private let track = CALayer()
    private let knob = CALayer()
    private var pressed = false
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 42, height: 24))
        wantsLayer = true
        track.cornerRadius = 12
        knob.cornerRadius = 10
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor; knob.shadowOpacity = 0.35
        knob.shadowRadius = 2; knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(track); layer?.addSublayer(knob)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 42).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue("Off")
        paint(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { paint(animated: false); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { DispatchQueue.main.async { self.paint(animated: false) }; return super.resignFirstResponder() }
    override func layout() { super.layout(); paint(animated: false) }
    private func paint(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.18) }
        track.frame = bounds
        track.backgroundColor = (isOn ? accent : NSColor.white.withAlphaComponent(0.16)).cgColor
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        track.borderWidth = focused ? 2 : 0
        track.borderColor = accent.withAlphaComponent(0.9).cgColor
        knob.frame = NSRect(x: isOn ? 20 : 2, y: 2, width: 20, height: 20)
        knob.opacity = isEnabled ? 1 : 0.5
        CATransaction.commit()
        alphaValue = isEnabled ? 1 : 0.55
    }
    private func flip() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }; pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { flip() }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { flip() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A rounded pill button: quiet (translucent) or prominent (ink-filled).
@MainActor final class BamPillButton: NSButton {
    private let prominent: Bool
    init(title: String, prominent: Bool = false, symbol: String? = nil) {
        self.prominent = prominent
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        let ink = prominent ? NSColor(white: 0.08, alpha: 1) : ArkPalette.ink
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink
        ])
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            contentTintColor = ink
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        layer?.backgroundColor = (prominent ? ArkPalette.ink : NSColor.white.withAlphaComponent(0.09)).cgColor
        layer?.cornerRadius = 16
        if !prominent {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += 30; return size }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.8 : 1 } }
}

/// One choice in a row of chips, with an optional color dot.
@MainActor final class BamChip: NSButton {
    var accent: NSColor = ArkPalette.spaceColor(0) { didSet { paint() } }
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }
    init(title: String, dot: NSColor? = nil) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ArkPalette.ink
        ])
        if let dot {
            image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                dot.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
            }
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        setAccessibilityRole(.radioButton)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        layer?.backgroundColor = (isPicked ? BamStyle.chipPicked : BamStyle.chipFill).cgColor
        layer?.borderColor = (isPicked ? accent.withAlphaComponent(0.9) : NSColor.white.withAlphaComponent(0.08)).cgColor
    }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += 26; return size }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 15, yRadius: 15).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A translucent card that stacks rows with hairline separators.
@MainActor class BamCard: NSView {
    let stack = NSStackView()
    /// Hairlines between rows; a card editing one thing in several rows turns them off.
    var showsSeparators = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = BamStyle.cardFill.cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = BamStyle.cardBorder.cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func add(_ row: NSView) {
        if showsSeparators, !stack.arrangedSubviews.isEmpty {
            let line = NSView(); line.wantsLayer = true
            line.layer?.backgroundColor = BamStyle.separator.cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

/// Title, optional detail text and a trailing control.
@MainActor final class BamRow: NSView {
    init(title: String, detail: String? = nil, control: NSView? = nil, enabled: Bool = true) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = enabled ? ArkPalette.ink : ArkPalette.secondary
        titleLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView()
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        text.addArrangedSubview(titleLabel)
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = ArkPalette.secondary
            detailLabel.isSelectable = false
            text.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        var constraints = [
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16)
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A keycap label like onboarding's, at row size: "⌘ ,".
@MainActor final class BamKeycap: NSView {
    init(_ keys: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        let label = NSTextField(labelWithString: keys)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = ArkPalette.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A borderless editable field on a translucent box; Escape reverts.
@MainActor final class BamTextField: NSTextField {
    var onCommit: ((String) -> Void)?
    private var committed = ""
    init(string: String, placeholder: String) {
        super.init(frame: .zero)
        stringValue = string; committed = string
        placeholderString = placeholder
        isBezeled = false; isBordered = false; drawsBackground = true
        backgroundColor = NSColor.white.withAlphaComponent(0.07)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        focusRingType = .none
        font = .systemFont(ofSize: 14, weight: .medium)
        textColor = ArkPalette.ink
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        (cell as? NSTextFieldCell)?.isScrollable = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        target = self; action = #selector(commit)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        commit()
    }
    @objc private func commit() {
        guard stringValue != committed else { return }
        committed = stringValue
        onCommit?(stringValue)
    }
    override func cancelOperation(_ sender: Any?) {
        stringValue = committed
        window?.makeFirstResponder(nil)
    }
}

/// Dresses an existing frame-laid-out Aqua panel (Manage Spaces, Extensions)
/// in Bam's wash, ink, cards and pills without changing its controls' names,
/// frames or actions, so fixtures that drive it by title keep working.
@MainActor enum BamSheetStyle {
    static func dress(window: NSWindow?, root: NSView, colorIndex: Int) {
        window?.appearance = NSAppearance(named: .darkAqua)
        window?.backgroundColor = NSColor(white: 0.10, alpha: 1)
        let backdrop = BamBackdropView(frame: root.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.tint(colorIndex: colorIndex)
        root.addSubview(backdrop, positioned: .below, relativeTo: nil)
        restyle(root)
    }
    static func restyle(_ view: NSView) {
        for child in view.subviews where !(child is BamBackdropView) {
            switch child {
            case let popup as NSPopUpButton:
                popup.bezelStyle = .texturedRounded
            case let button as NSButton:
                pill(button, prominent: button.keyEquivalent == "\r")
            case let field as NSTextField where field.isEditable:
                field.isBezeled = false; field.isBordered = false; field.drawsBackground = true
                field.backgroundColor = NSColor.white.withAlphaComponent(0.07)
                field.wantsLayer = true; field.layer?.cornerRadius = 8
                field.layer?.borderWidth = 1; field.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
                field.focusRingType = .none; field.textColor = ArkPalette.ink
            case let label as NSTextField:
                let size = label.font?.pointSize ?? 12
                if size >= 18 { label.font = OnboardingText.serif(size + 2, weight: .bold); label.textColor = ArkPalette.ink }
                else if label.textColor == .secondaryLabelColor { label.textColor = ArkPalette.secondary }
                else { label.textColor = ArkPalette.ink }
            case let scroll as NSScrollView:
                scroll.borderType = .noBorder; scroll.drawsBackground = false
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12
                scroll.layer?.backgroundColor = BamStyle.cardFill.cgColor
                scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = BamStyle.cardBorder.cgColor
                if let table = scroll.documentView as? NSTableView {
                    table.backgroundColor = .clear
                    table.usesAlternatingRowBackgroundColors = false
                    table.style = .plain
                }
            default:
                restyle(child)
            }
        }
    }
    static func pill(_ button: NSButton, prominent: Bool) {
        let title = button.title
        button.isBordered = false
        button.wantsLayer = true
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: prominent ? NSColor(white: 0.08, alpha: 1) : ArkPalette.ink
        ])
        button.layer?.backgroundColor = (prominent ? ArkPalette.ink : NSColor.white.withAlphaComponent(0.09)).cgColor
        button.layer?.cornerRadius = min(16, button.frame.height / 2)
        if !prominent {
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        }
    }
}
