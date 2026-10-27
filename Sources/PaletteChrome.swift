import AppKit
import ObjectiveC

/// The palette's colors, after Yab's field: a near-white card on a soft, wide shadow in light appearance and a
/// raised graphite card in dark, with hairline edges and quiet gray fills for keycaps and footer buttons.
enum PaletteStyle {
    static func card(_ dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.165, green: 0.165, blue: 0.173, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 0.996, alpha: 1) }
    static func edge(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.075) }
    static func control(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.055) : NSColor(srgbRed: 0.973, green: 0.973, blue: 0.969, alpha: 1) }
    static func controlEdge(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.07) }
    static func keycap(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.075) }
    static func shadowOpacity(_ dark: Bool) -> Float { dark ? 0.5 : 0.17 }
}

/// The palette surface: a solid card that follows the window's appearance (light and dark), with a continuous
/// 20pt corner and a hairline edge. Its shadow is a sibling view, since the card clips its rows.
@MainActor final class PaletteCard: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PaletteGeometry.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search or enter address")
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var isDark: Bool { effectiveAppearance.isDarkPalette }
    /// Set while the card fades out after a pick: clicks go straight through to the page.
    var passesThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { passesThrough ? nil : super.hitTest(point) }
    private func paint() {
        let dark = isDark
        layer?.backgroundColor = PaletteStyle.card(dark).cgColor
        layer?.borderColor = PaletteStyle.edge(dark).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}

/// Two stacked shadows behind the card: a wide soft one that lifts it off the page and a tight one that draws its
/// edge against light pages.
@MainActor final class PaletteShadowView: NSView {
    private let contact = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(contact)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        guard let layer else { return }
        let dark = effectiveAppearance.isDarkPalette
        let radius = PaletteGeometry.cornerRadius
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.shadowPath = path
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = PaletteStyle.shadowOpacity(dark)
        layer.shadowRadius = 32
        // Layer space is unflipped here: a negative y pushes the shadow down the screen.
        layer.shadowOffset = CGSize(width: 0, height: -14)
        contact.frame = bounds
        contact.shadowPath = path
        contact.shadowColor = NSColor.black.cgColor
        contact.shadowOpacity = dark ? 0.35 : 0.07
        contact.shadowRadius = 2.5
        contact.shadowOffset = CGSize(width: 0, height: -1)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A small rounded key ("↩", "⌘", "K", "⇥").
@MainActor final class PaletteKeycap: NSView {
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    init(_ glyph: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.stringValue = glyph
        label.font = .systemFont(ofSize: glyph.count == 1 && glyph.first?.isLetter == true ? 12 : 13, weight: .medium)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(false)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static let size = NSSize(width: 21, height: 21)
    private func paint() { layer?.backgroundColor = PaletteStyle.keycap(effectiveAppearance.isDarkPalette).cgColor }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

/// "Search GitHub ⇥" at the field's right edge while the typed text names a site.
@MainActor final class PaletteTabHint: NSView {
    private let label = NSTextField(labelWithString: "")
    private let key = PaletteKeycap("⇥")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label); addSubview(key)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue.isEmpty ? nil : "\(newValue), press Tab"); isHidden = newValue.isEmpty; needsLayout = true }
    }
    var fittingWidth: CGFloat { label.measuredTextWidth + 4 + 8 + PaletteKeycap.size.width }
    override func layout() {
        super.layout()
        let keySize = PaletteKeycap.size
        key.frame = NSRect(x: bounds.width - keySize.width, y: (bounds.height - keySize.height) / 2, width: keySize.width, height: keySize.height)
        let width = max(0, key.frame.minX - 8)
        label.frame = NSRect(x: 0, y: (bounds.height - 17) / 2, width: width, height: 17)
    }
}

/// A capsule footer control that runs a closure on click.
@MainActor final class PaletteFooterButton: NSView {
    var onPress: (() -> Void)?
    private var pressed = false { didSet { paint() } }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        let dark = effectiveAppearance.isDarkPalette
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = PaletteStyle.control(dark)
            layer?.backgroundColor = (pressed ? base.blended(withFraction: 0.08, of: dark ? .white : .black) ?? base : base).cgColor
            layer?.borderColor = PaletteStyle.controlEdge(dark).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}

/// The palette's footer, as Yab's: a places button on the left; on the right, what Return does for the selected
/// row and "Actions ⌘K".
@MainActor final class PaletteFooterView: NSView {
    var onPlaces: ((NSView) -> Void)?
    var onReturn: (() -> Void)?
    var onActions: ((NSView) -> Void)?
    private let places = PaletteFooterButton()
    private let placesIcon = NSImageView()
    private let trailing = PaletteFooterButton()
    private let returnZone = PaletteFooterButton()
    private let returnLabel = NSTextField(labelWithString: "Open")
    private let returnKey = PaletteKeycap("↩")
    private let actionsZone = PaletteFooterButton()
    private let actionsLabel = NSTextField(labelWithString: "Actions")
    private let commandKey = PaletteKeycap("⌘")
    private let kKey = PaletteKeycap("K")
    override var isFlipped: Bool { true }
    var actionsAnchor: NSView { actionsZone }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placesIcon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        placesIcon.contentTintColor = .secondaryLabelColor
        placesIcon.setAccessibilityElement(false)
        places.addSubview(placesIcon)
        places.setAccessibilityLabel("Places: History, Downloads, Recently Closed")
        places.toolTip = "History, Downloads, Recently Closed"
        places.onPress = { [weak self] in guard let self else { return }; self.onPlaces?(self.places) }
        addSubview(places)
        addSubview(trailing)
        // The two halves of the right capsule are borderless zones inside one outline.
        for zone in [returnZone, actionsZone] {
            zone.layer?.borderWidth = 0
            zone.layer?.backgroundColor = NSColor.clear.cgColor
            trailing.addSubview(zone)
        }
        returnZone.onPress = { [weak self] in self?.onReturn?() }
        actionsZone.onPress = { [weak self] in guard let self else { return }; self.onActions?(self.actionsZone) }
        actionsZone.setAccessibilityLabel("Actions, Command K")
        for label in [returnLabel, actionsLabel] {
            label.font = .systemFont(ofSize: 13.5, weight: .medium)
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
        }
        returnLabel.textColor = .labelColor
        actionsLabel.textColor = .secondaryLabelColor
        returnZone.addSubview(returnLabel); returnZone.addSubview(returnKey)
        actionsZone.addSubview(actionsLabel); actionsZone.addSubview(commandKey); actionsZone.addSubview(kKey)
        setReturnTitle("Open")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var returnTitle: String { returnLabel.stringValue }
    func setReturnTitle(_ title: String) {
        guard returnLabel.stringValue != title || returnZone.accessibilityLabel() == nil else { return }
        returnLabel.stringValue = title
        returnZone.setAccessibilityLabel("\(title), Return")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let height: CGFloat = 34
        let y = (bounds.height - height) / 2
        places.frame = NSRect(x: 7, y: y, width: height, height: height)
        placesIcon.frame = NSRect(x: 9, y: 9, width: 16, height: 16)
        let key = PaletteKeycap.size
        let keyY = (height - key.height) / 2
        let returnWidth = 16 + returnLabel.measuredTextWidth + 4 + 8 + key.width + 8
        let actionsWidth = 10 + actionsLabel.measuredTextWidth + 4 + 8 + key.width + 3 + key.width + 7
        let total = returnWidth + actionsWidth
        trailing.frame = NSRect(x: bounds.width - 7 - total, y: y, width: total, height: height)
        returnZone.frame = NSRect(x: 0, y: 0, width: returnWidth, height: height)
        actionsZone.frame = NSRect(x: returnWidth, y: 0, width: actionsWidth, height: height)
        returnLabel.frame = NSRect(x: 16, y: (height - 17) / 2, width: returnLabel.measuredTextWidth + 4, height: 17)
        returnKey.frame = NSRect(x: returnLabel.frame.maxX + 8, y: keyY, width: key.width, height: key.height)
        actionsLabel.frame = NSRect(x: 10, y: (height - 17) / 2, width: actionsLabel.measuredTextWidth + 4, height: 17)
        commandKey.frame = NSRect(x: actionsLabel.frame.maxX + 8, y: keyY, width: key.width, height: key.height)
        kKey.frame = NSRect(x: commandKey.frame.maxX + 3, y: keyY, width: key.width, height: key.height)
    }
}

/// Runs a closure from an NSMenuItem.
@MainActor final class PaletteMenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func perform(_ sender: Any?) { run() }
    static func item(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [],
                     run: @escaping () -> Void) -> NSMenuItem {
        let action = PaletteMenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(perform(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = action
        item.representedObject = action  // the item keeps its target alive
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

/// Per-palette state that doesn't fit the controller's stored properties (they live in BrowserController.swift):
/// what was typed under an inline completion, the history index, the footer and the key monitor.
@MainActor final class PaletteState {
    /// Exactly what the person typed; the field may show a completed ending after it.
    var typed = ""
    var completion: PaletteCompletion?
    /// Set by a delete key so the next text change doesn't complete again.
    var suppressCompletion = false
    var history = PaletteHistoryIndex(visits: [])
    var candidates: [PaletteCompletionCandidate] = []
    var openTabKeys: Set<String> = []
    var footer: PaletteFooterView?
    var shadow: PaletteShadowView?
    var tabHint: PaletteTabHint?
    var keyMonitor: Any?
    /// The field editor's selection look before the gray completion style.
    var savedSelectionAttributes: [NSAttributedString.Key: Any]?
    weak var styledEditor: NSTextView?
}

private nonisolated(unsafe) var paletteStateKey: UInt8 = 0

extension BrowserController {
    /// The open palette's extra state, created on demand.
    var paletteState: PaletteState {
        if let state = objc_getAssociatedObject(self, &paletteStateKey) as? PaletteState { return state }
        let state = PaletteState()
        objc_setAssociatedObject(self, &paletteStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
    func resetPaletteState() {
        if let monitor = (objc_getAssociatedObject(self, &paletteStateKey) as? PaletteState)?.keyMonitor { NSEvent.removeMonitor(monitor) }
        if let state = objc_getAssociatedObject(self, &paletteStateKey) as? PaletteState,
           let editor = state.styledEditor, let saved = state.savedSelectionAttributes {
            editor.selectedTextAttributes = saved
        }
        objc_setAssociatedObject(self, &paletteStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
