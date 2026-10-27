import AppKit
import QuartzCore

/// Bam's own control kit for settings-style surfaces, drawn in the
/// bambrowser.com vocabulary: paper cards with a hairline and a soft shadow,
/// sticker-red actions, keycaps with a lip, Bricolage headings.
@MainActor enum BamStyle {
    static var reduceMotion: Bool { BamTheme.reduceMotion }
    /// The site's `.btn` radius at control height.
    static let pillRadius: CGFloat = 12
    static let cardRadius: CGFloat = 18
}

/// A pill switch. Space or Return flips it from the keyboard; a click flips
/// it; the knob glides unless Reduce Motion is on. On is sticker red.
@MainActor final class BamToggle: NSControl {
    var onChange: ((Bool) -> Void)?
    var accent: NSColor = BamTheme.red { didSet { paint(animated: false) } }
    var isOn = false { didSet { paint(animated: !BamStyle.reduceMotion); setAccessibilityValue(isOn ? "On" : "Off") } }
    private let track = CALayer()
    private let knob = CALayer()
    private var pressed = false
    /// Settings' denser size (34×20, as in Arc's lists); everything else keeps 44×26.
    private let compact: Bool
    private var knobSize: CGFloat { compact ? 16 : 20 }
    override convenience init(frame: NSRect) { self.init(compact: false) }
    init(compact: Bool) {
        self.compact = compact
        let size = compact ? NSSize(width: 34, height: 20) : NSSize(width: 44, height: 26)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        track.cornerRadius = size.height / 2
        knob.cornerRadius = knobSize / 2
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 2; knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(track); layer?.addSublayer(knob)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint(animated: false) }
    private func paint(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.18) }
        track.frame = bounds
        track.backgroundColor = bamCG(isOn ? accent : BamTheme.ink.withAlphaComponent(0.18))
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        track.borderWidth = focused ? 2 : 0
        track.borderColor = bamCG(BamTheme.ink.withAlphaComponent(0.6))
        let inset = (bounds.height - knobSize) / 2
        knob.frame = NSRect(x: isOn ? bounds.width - knobSize - inset : inset, y: inset, width: knobSize, height: knobSize)
        knob.backgroundColor = bamCG(isOn ? BamTheme.white : BamTheme.card)
        knob.shadowColor = bamCG(BamTheme.ink)
        knob.opacity = isEnabled ? 1 : 0.5
        CATransaction.commit()
        alphaValue = isEnabled ? 1 : 0.5
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

/// The site's `.btn`: prominent is sticker red sitting on a deep-red lip,
/// quiet is paper with a hairline. Pressing sinks it onto the lip.
@MainActor final class BamPillButton: NSButton {
    private let prominent: Bool
    /// Settings' denser size: 28 points tall, smaller type.
    private let compact: Bool
    private var radius: CGFloat { compact ? 9 : BamStyle.pillRadius }
    init(title: String, prominent: Bool = false, symbol: String? = nil, compact: Bool = false) {
        self.prominent = prominent
        self.compact = compact
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        self.title = title
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: compact ? 10.5 : 12, weight: .semibold))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: compact ? 28 : 34).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var ink: NSColor { prominent ? BamTheme.white : BamTheme.ink }
    private func paint() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BamType.sans(compact ? 12.5 : 13.5, weight: compact ? .semibold : .bold), .foregroundColor: ink
        ])
        contentTintColor = ink
        alphaValue = isEnabled ? 1 : 0.5
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let drop: CGFloat = prominent ? 2 : 1.5
        let pressed = isHighlighted
        // NSButton is flipped: y grows downward. The lip sits along the
        // bottom; the face rests `drop` points above it and pressing drops it.
        let lip = NSRect(x: 0, y: drop, width: bounds.width, height: bounds.height - drop)
        let face = NSRect(x: 0, y: pressed ? drop : 0, width: bounds.width, height: bounds.height - drop)
        let radius = self.radius
        (prominent ? BamTheme.redDeep : BamTheme.line).setFill()
        NSBezierPath(roundedRect: lip, xRadius: radius, yRadius: radius).fill()
        (prominent ? BamTheme.red : BamTheme.card).setFill()
        let facePath = NSBezierPath(roundedRect: face, xRadius: radius, yRadius: radius)
        facePath.fill()
        if !prominent {
            BamTheme.line.setStroke()
            let ring = NSBezierPath(roundedRect: face.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.75, yRadius: radius - 0.75)
            ring.lineWidth = 1.5; ring.stroke()
        }
        // The title rides the face: half a lip above centre, half below when pressed.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: pressed ? drop / 2 : -drop / 2)
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func layout() { super.layout(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var isHighlighted: Bool { didSet { paint() } }
    override var isEnabled: Bool { didSet { paint() } }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += compact ? 22 : 30; return size }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One choice in a row of chips, with an optional color dot. Picked is a red
/// wash with a red ring.
@MainActor final class BamChip: NSButton {
    var accent: NSColor = BamTheme.red { didSet { paint() } }
    var isPicked = false { didSet { paint(); setAccessibilityValue(isPicked ? "Selected" : "") } }
    private let dot: NSColor?
    private let compact: Bool
    init(title: String, dot: NSColor? = nil, compact: Bool = false) {
        self.dot = dot
        self.compact = compact
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        self.title = title
        if dot != nil {
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        layer?.cornerRadius = compact ? 12 : 15
        layer?.borderWidth = 1.5
        setAccessibilityRole(.radioButton)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: compact ? 24 : 30).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BamType.sans(compact ? 12 : 13, weight: isPicked ? .bold : .medium), .foregroundColor: BamTheme.ink
        ])
        if let dot {
            image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                dot.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
            }
        }
        layer?.backgroundColor = bamCG(isPicked ? BamTheme.redWash : BamTheme.bg)
        layer?.borderColor = bamCG(isPicked ? accent : BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override var intrinsicContentSize: NSSize { var size = super.intrinsicContentSize; size.width += compact ? 20 : 26; return size }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: compact ? 12 : 15, yRadius: compact ? 12 : 15).fill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.8 : 1 } }
}

/// A paper card with a hairline and a soft shadow that stacks rows.
@MainActor class BamCard: NSView {
    let stack = NSStackView()
    /// Hairlines between rows; a card editing one thing in several rows turns them off.
    var showsSeparators = true
    /// Dashed cards are the site's asides (`.arc-note`).
    var isDashed = false { didSet { paint() } }
    var cornerRadius: CGFloat = BamStyle.cardRadius { didSet { layer?.cornerRadius = cornerRadius; paint() } }
    /// How far separators stop short of each edge; matches the rows' text inset.
    var separatorInset: CGFloat = 20
    /// Settings' quieter cards: a smaller, softer shadow under the hairline.
    var isQuiet = false { didSet { paint() } }
    private let dash = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = BamStyle.cardRadius
        layer?.masksToBounds = false
        dash.fillColor = nil
        dash.lineWidth = 1.5
        dash.lineDashPattern = [5, 4]
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
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.backgroundColor = bamCG(isDashed ? BamTheme.card.withAlphaComponent(0.6) : BamTheme.card)
        layer.borderWidth = isDashed ? 0 : 1.5
        layer.borderColor = bamCG(BamTheme.line)
        layer.shadowColor = bamCG(BamTheme.shadow)
        layer.shadowOpacity = isDashed ? 0 : isQuiet ? 0.45 : 1
        layer.shadowRadius = isQuiet ? 6 : 14
        layer.shadowOffset = CGSize(width: 0, height: isQuiet ? -2 : -7)
        if isDashed {
            if dash.superlayer == nil { layer.addSublayer(dash) }
            dash.frame = bounds
            dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            dash.strokeColor = bamCG(BamTheme.line)
        } else {
            dash.removeFromSuperlayer()
        }
        CATransaction.commit()
    }
    override func layout() { super.layout(); paint() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    func add(_ row: NSView) {
        if showsSeparators, !stack.arrangedSubviews.isEmpty {
            // Inset on both sides: the stack aligns its views to the leading edge, so the
            // line rides in a full-width holder that centers it.
            let holder = BamSeparatorHolder()
            let line = BamHairline()
            line.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(line)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: 1),
                line.topAnchor.constraint(equalTo: holder.topAnchor), line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: separatorInset),
                line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -separatorInset)
            ])
            stack.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

/// The full-width row that holds a card's inset hairline.
@MainActor final class BamSeparatorHolder: NSView {
    override init(frame: NSRect) { super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Title, optional detail text and a trailing control.
@MainActor final class BamRow: NSView {
    /// What Settings' search finds a row by.
    let title: String
    let detail: String?
    /// Extra words the search matches ("zoom" finds Page zoom by its old name, and so on).
    var keywords: [String] = []
    init(title: String, detail: String? = nil, control: NSView? = nil, enabled: Bool = true, compact: Bool = false) {
        self.title = title
        self.detail = detail
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let inset: CGFloat = compact ? 16 : 20, vertical: CGFloat = compact ? 10 : 15
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = BamType.sans(compact ? 13.5 : 15, weight: .semibold)
        titleLabel.textColor = enabled ? BamTheme.ink : BamTheme.muted
        titleLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView()
        text.orientation = .vertical; text.alignment = .leading; text.spacing = compact ? 1 : 3
        text.addArrangedSubview(titleLabel)
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = BamType.sans(compact ? 12 : 13)
            detailLabel.textColor = BamTheme.muted
            detailLabel.isSelectable = false
            text.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        var constraints = [
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            text.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: compact ? 7 : 10),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16)
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// Settings' search landed here: a red wash that fades out over a second and a half.
    func flash() {
        guard let layer else { return }
        let wash = CABasicAnimation(keyPath: "backgroundColor")
        wash.fromValue = bamCG(BamTheme.redWash)
        wash.toValue = bamCG(BamTheme.redWash.withAlphaComponent(0))
        wash.duration = BamStyle.reduceMotion ? 0.01 : 1.6
        wash.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.cornerRadius = 10
        layer.add(wash, forKey: "flash")
    }
}

/// The site's `kbd`: a mono cap on page paper with a thicker bottom edge.
@MainActor class BamKeycap: NSView {
    enum Tone { case resting, recording, refused }
    private let label = NSTextField(labelWithString: "")
    var text: String { get { label.stringValue } set { label.stringValue = newValue } }
    var tone: Tone = .resting { didSet { paint() } }
    /// A placeholder cap ("—" for a command without a shortcut) reads quieter.
    var isDimmed = false { didSet { paint() } }
    init(_ keys: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        label.stringValue = keys
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func paint() {
        let live = tone != .resting
        label.font = tone == .recording ? BamType.sans(12, weight: .semibold) : BamType.mono(12)
        label.textColor = live ? BamTheme.red : isDimmed ? BamTheme.muted : BamTheme.ink
        layer?.backgroundColor = bamCG(tone == .refused ? BamTheme.redWash : tone == .recording ? BamTheme.card : BamTheme.bg)
        layer?.borderColor = bamCG(live ? BamTheme.red : BamTheme.line)
        layer?.borderWidth = live ? 1.5 : 1
        // The lip: a hard, unblurred shadow one and a half points down; a
        // recording cap sits pressed, without it.
        layer?.shadowColor = bamCG(BamTheme.ink.withAlphaComponent(tone == .recording ? 0 : 0.28))
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 0
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// A borderless editable field on page paper; the ring turns red while
/// editing. Escape reverts.
/// Centers a single line of text (and its editor) vertically, with room on the sides.
final class BamCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let inset = rect.insetBy(dx: 8, dy: 0)
        let height = min(inset.height, cellSize(forBounds: inset).height)
        return NSRect(x: inset.minX, y: inset.minY + (inset.height - height) / 2, width: inset.width, height: height)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centered(super.drawingRect(forBounds: rect)) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

@MainActor final class BamTextField: NSTextField {
    /// Return true to accept the value; false reverts the field.
    var onCommit: ((String) -> Bool)?
    private var committed = ""
    private var editing = false
    override class var cellClass: AnyClass? { get { BamCenteredTextFieldCell.self } set {} }
    init(string: String, placeholder: String) {
        super.init(frame: .zero)
        stringValue = string; committed = string
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: BamType.sans(14, weight: .medium), .foregroundColor: BamTheme.muted
        ])
        isBezeled = false; isBordered = false; drawsBackground = true
        backgroundColor = BamTheme.bg
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        focusRingType = .none
        font = BamType.sans(14, weight: .medium)
        textColor = BamTheme.ink
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        (cell as? NSTextFieldCell)?.isScrollable = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        target = self; action = #selector(commit)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() { layer?.borderColor = bamCG(editing ? BamTheme.red : BamTheme.line) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        editing = true; paint()
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        editing = false; paint()
        commit()
    }
    @objc private func commit() {
        guard stringValue != committed else { return }
        if onCommit?(stringValue) == true { committed = stringValue } else { stringValue = committed }
    }
    override func cancelOperation(_ sender: Any?) {
        stringValue = committed
        window?.makeFirstResponder(nil)
    }
}

/// Dresses an existing frame-laid-out Aqua panel (Manage Spaces, Extensions,
/// Downloads, History) in Bam's paper, ink, cards and pills without changing
/// its controls' names, frames or actions, so fixtures that drive it by title
/// keep working.
@MainActor enum BamSheetStyle {
    static func dress(window: NSWindow?, root: NSView, colorIndex: Int = 0) {
        // Follow the system like the website; the browser window stays dark on its own.
        window?.appearance = nil
        window?.backgroundColor = BamTheme.bg
        window?.titlebarAppearsTransparent = true
        let paper = BamSurfaceView(frame: root.bounds)
        paper.autoresizingMask = [.width, .height]
        root.addSubview(paper, positioned: .below, relativeTo: nil)
        restyle(root)
        // Plain buttons and fields carry resolved CGColors; refresh them on a flip.
        paper.onAppearanceChange = { [weak root] in root.map(repaint) }
    }
    /// Re-resolves the colours `restyle` baked into layers, without touching
    /// fonts, titles or hierarchy.
    static func repaint(_ view: NSView) {
        for child in view.subviews where !(child is BamSurfaceView) {
            switch child {
            case is NSPopUpButton, is BamPillButton, is BamChip: break
            case let button as NSButton where button.layer != nil && !button.isBordered:
                pillColors(button, prominent: button.keyEquivalent == "\r")
            case let field as NSTextField where field.isEditable:
                field.layer?.borderColor = field.bamCG(BamTheme.line)
            default: repaint(child)
            }
        }
    }
    static func restyle(_ view: NSView) {
        for child in view.subviews where !(child is BamSurfaceView) {
            switch child {
            case let popup as NSPopUpButton:
                popup.bezelStyle = .texturedRounded
                popup.font = BamType.sans(13, weight: .medium)
            case is BamPillButton, is BamChip: break
            case let button as NSButton:
                pill(button, prominent: button.keyEquivalent == "\r")
            case let search as NSSearchField:
                search.font = BamType.sans(13)
                search.focusRingType = .none
            case let field as NSTextField where field.isEditable:
                field.isBezeled = false; field.isBordered = false; field.drawsBackground = true
                field.backgroundColor = BamTheme.bg
                field.wantsLayer = true; field.layer?.cornerRadius = 8
                field.layer?.borderWidth = 1.5; field.layer?.borderColor = field.bamCG(BamTheme.line)
                field.focusRingType = .none; field.textColor = BamTheme.ink
                field.font = BamType.sans(field.font?.pointSize ?? 13, weight: .medium)
            case let label as NSTextField:
                let size = label.font?.pointSize ?? 12
                if size >= 18 {
                    label.font = BamType.display(size + 4, weight: .heavy); label.textColor = BamTheme.ink
                } else {
                    let secondary = label.textColor == .secondaryLabelColor
                    label.font = BamType.sans(size + 0.5, weight: secondary ? .regular : weight(of: label.font))
                    label.textColor = secondary ? BamTheme.muted : BamTheme.ink
                }
            case let scroll as NSScrollView:
                scroll.borderType = .noBorder; scroll.drawsBackground = false
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 14; scroll.layer?.masksToBounds = true
                scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
                // A paper card behind the list; NSScrollView repaints its own layer.
                let backing = BamCardBacking(frame: scroll.frame)
                view.addSubview(backing, positioned: .below, relativeTo: scroll)
                if scroll.translatesAutoresizingMaskIntoConstraints {
                    backing.autoresizingMask = scroll.autoresizingMask
                } else {
                    backing.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([backing.topAnchor.constraint(equalTo: scroll.topAnchor), backing.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
                                                 backing.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), backing.trailingAnchor.constraint(equalTo: scroll.trailingAnchor)])
                }
                if let table = scroll.documentView as? NSTableView {
                    table.backgroundColor = .clear
                    table.usesAlternatingRowBackgroundColors = false
                    table.style = .plain
                    table.gridStyleMask = []
                    table.intercellSpacing = NSSize(width: 0, height: 2)
                }
            default:
                restyle(child)
            }
        }
    }
    private static func weight(of font: NSFont?) -> NSFont.Weight {
        guard let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
              let raw = traits[.weight] as? CGFloat else { return .regular }
        if raw >= NSFont.Weight.bold.rawValue { return .bold }
        if raw >= NSFont.Weight.semibold.rawValue { return .semibold }
        if raw >= NSFont.Weight.medium.rawValue { return .medium }
        return .regular
    }
    /// Replaces a bezel button with a site button, in place.
    static func pill(_ button: NSButton, prominent: Bool) {
        let title = button.title
        button.isBordered = false
        button.wantsLayer = true
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BamType.sans(13, weight: .bold),
            .foregroundColor: prominent ? BamTheme.white : BamTheme.ink
        ])
        button.contentTintColor = prominent ? BamTheme.white : BamTheme.ink
        // Frame-laid-out buttons are sized already; autolayout ones are not yet.
        let height = button.frame.height
        button.layer?.cornerRadius = height == 0 || height >= 2 * BamStyle.pillRadius ? BamStyle.pillRadius : height / 2
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        if !button.translatesAutoresizingMaskIntoConstraints, !button.constraints.contains(where: { $0.firstAttribute == .height }) {
            let tall = button.heightAnchor.constraint(equalToConstant: 32); tall.priority = .init(900); tall.isActive = true
        }
        button.layer?.masksToBounds = false
        button.layer?.borderWidth = prominent ? 0 : 1.5
        button.layer?.shadowOpacity = 1
        button.layer?.shadowRadius = 0
        button.layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        pillColors(button, prominent: prominent)
    }
    private static func pillColors(_ button: NSButton, prominent: Bool) {
        button.layer?.backgroundColor = button.bamCG(prominent ? BamTheme.red : BamTheme.card)
        button.layer?.borderColor = button.bamCG(BamTheme.line)
        button.layer?.shadowColor = button.bamCG(prominent ? BamTheme.redDeep : BamTheme.line)
    }
}

/// A keycap that records: click it and the next chord becomes the shortcut.
/// Escape keeps the old one, Delete restores the default. A chord another command
/// wears goes to `onConflict` (Settings asks whether to take it over); one an
/// extension wears is refused with a flash of red. A command with no shortcut shows "—".
@MainActor final class BamShortcutRecorder: BamKeycap {
    let commandID: String
    private let commandTitle: String
    /// The chord and the title of the command wearing it. Without a handler, conflicts are refused.
    var onConflict: ((KeyCombo, String) -> Void)?
    private var monitor: Any?
    private var recording = false { didSet { show() } }
    private var refused = false { didSet { show() } }

    convenience init(command: ShortcutCommand) { self.init(id: command.menuID, title: command.title) }
    init(id: String, title: String) {
        commandID = id
        commandTitle = title
        super.init(ShortcutStore.shared.combo(forID: id)?.display ?? "—")
        widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title) shortcut")
        // Reset-all and edits from elsewhere reach every cap; the section itself
        // is not rebuilt for a shortcut change.
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: ShortcutStore.didChange, object: nil)
        show()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    @objc private func storeChanged() { if !recording { show() } }

    private func show() {
        let combo = ShortcutStore.shared.combo(forID: commandID)
        text = recording ? "Type a shortcut" : combo?.display ?? "—"
        isDimmed = combo == nil && !recording
        tone = refused ? .refused : recording ? .recording : .resting
        let now = combo.map { "Escape keeps \($0.display)" } ?? "Escape keeps it without one"
        toolTip = recording ? "Press the new shortcut. \(now); Delete restores the default."
            : combo.map { "\($0.spoken). Click to change." } ?? "No shortcut. Click to add one."
        setAccessibilityValue(recording ? "Recording" : combo?.spoken ?? "None")
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if recording { stop() } else { start() }
    }
    override func keyDown(with event: NSEvent) {
        // Space or Return on the focused keycap starts recording, like a button.
        if !recording, event.charactersIgnoringModifiers == " " || event.keyCode == 36 { start(); return }
        super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { start(); return true }

    func start() {
        guard !recording else { return }
        window?.makeFirstResponder(self)
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type != .keyDown {
            // A click on the cap itself reaches mouseDown and ends recording
            // there; a click anywhere else ends it here and goes through.
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) { stop() }
            return event
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x1B: stop(); return nil                                                  // Escape keeps the old chord
        case 0x7F, 0xF728: ShortcutStore.shared.reset(id: commandID); stop(); return nil // Delete restores the default
        default: break
        }
        guard let combo = KeyCombo.from(event: event) else { NSSound.beep(); return nil }
        switch ShortcutStore.shared.assign(combo, to: commandID) {
        case .assigned: stop()
        case .taken(let owner):
            stop()
            if let onConflict { onConflict(combo, owner) } else { refuse(combo, owner: owner) }
        case .reserved(let owner): refuse(combo, owner: owner)
        }
        return nil
    }
    private func refuse(_ combo: KeyCombo, owner: String) {
        NSSound.beep()
        toolTip = "\(combo.display) already opens \(owner)."
        refused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refused = false }
    }
}
