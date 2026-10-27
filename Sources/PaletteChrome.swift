import AppKit
import ObjectiveC

/// The palette's colors, as Arc's command bar: a near-black card in dark appearance and a near-white one in light,
/// both washed faintly with the current Space's color, a hairline edge, and a soft shadow.
enum PaletteStyle {
    static func base(_ dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.094, green: 0.094, blue: 0.098, alpha: 1) : NSColor(srgbRed: 0.988, green: 0.988, blue: 0.988, alpha: 1) }
    /// The card: its base with a little of the Space in it.
    @MainActor static func card(dark: Bool, tint: NSColor?) -> NSColor {
        let base = base(dark)
        guard let tint else { return base }
        var resolved: NSColor?
        (dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua))?.performAsCurrentDrawingAppearance {
            resolved = tint.usingColorSpace(.sRGB)
        }
        return base.blended(withFraction: dark ? 0.05 : 0.06, of: resolved ?? tint) ?? base
    }
    static func edge(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.13) }
    static func separator(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.08) }
    static func keycap(_ dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.06) }
    static func shadowOpacity(_ dark: Bool) -> Float { dark ? 0.45 : 0.16 }
}

/// The palette surface: a solid card that follows the window's appearance, tinted by the Space, with a 10pt
/// corner and a hairline edge. Its shadow is a sibling view, since the card clips its rows.
@MainActor final class PaletteCard: NSView {
    override var isFlipped: Bool { true }
    /// The current Space's color, washed into the card.
    var spaceTint: NSColor? { didSet { paint() } }
    private let separator = NSView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PaletteGeometry.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        separator.wantsLayer = true
        separator.setAccessibilityElement(false)
        addSubview(separator)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search or Enter URL")
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var isDark: Bool { effectiveAppearance.isDarkPalette }
    private func paint() {
        let dark = isDark
        layer?.backgroundColor = PaletteStyle.card(dark: dark, tint: spaceTint).cgColor
        layer?.borderColor = PaletteStyle.edge(dark).cgColor
        separator.layer?.backgroundColor = PaletteStyle.separator(dark).cgColor
    }
    override func layout() {
        super.layout()
        // The hairline under the input row, inset from the card's edges.
        separator.frame = NSRect(x: 10, y: PaletteGeometry.inputHeight, width: max(0, bounds.width - 20), height: 1)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}

/// A soft shadow behind the card that lifts it off the page.
@MainActor final class PaletteShadowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        guard let layer else { return }
        let radius = PaletteGeometry.cornerRadius
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = PaletteStyle.shadowOpacity(effectiveAppearance.isDarkPalette)
        layer.shadowRadius = 24
        // Layer space is unflipped here: a negative y pushes the shadow down the screen.
        layer.shadowOffset = CGSize(width: 0, height: -10)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// "Search GitHub  [Tab]" at the field's right edge while the typed text names a site, as Arc shows it.
@MainActor final class PaletteTabHint: NSView {
    private let label = NSTextField(labelWithString: "")
    private let key = NSView()
    private let keyLabel = NSTextField(labelWithString: "Tab")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        keyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .center
        key.wantsLayer = true
        key.layer?.cornerRadius = 5
        key.layer?.cornerCurve = .continuous
        for view in [label, key, keyLabel] as [NSView] { view.setAccessibilityElement(false) }
        addSubview(label); addSubview(key); key.addSubview(keyLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue.isEmpty ? nil : "\(newValue), press Tab"); isHidden = newValue.isEmpty; needsLayout = true }
    }
    private var keyWidth: CGFloat { keyLabel.measuredTextWidth + 14 }
    var fittingWidth: CGFloat { label.measuredTextWidth + 4 + 8 + keyWidth }
    private func paint() { key.layer?.backgroundColor = PaletteStyle.keycap(effectiveAppearance.isDarkPalette).cgColor }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func layout() {
        super.layout()
        let keyHeight: CGFloat = 24
        key.frame = NSRect(x: bounds.width - keyWidth, y: (bounds.height - keyHeight) / 2, width: keyWidth, height: keyHeight)
        let labelHeight = keyLabel.intrinsicContentSize.height
        keyLabel.frame = NSRect(x: 0, y: (keyHeight - labelHeight) / 2, width: keyWidth, height: labelHeight)
        label.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: max(0, key.frame.minX - 8), height: 18)
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
/// what was typed under an inline completion, the history index, the shadow and hint views, and the key monitor.
@MainActor final class PaletteState {
    /// Exactly what the person typed; the field may show a completed ending after it.
    var typed = ""
    var completion: PaletteCompletion?
    /// Set by a delete key so the next text change doesn't complete again.
    var suppressCompletion = false
    /// The field's text after the last change, to tell a typed letter from a paste.
    var lastFieldText = ""
    var history = PaletteHistoryIndex(visits: [])
    var candidates: [PaletteCompletionCandidate] = []
    var openTabKeys: Set<String> = []
    /// ⌘L's address as it opened, so its untouched state lists this page first.
    var openedAddress: String?
    var shadow: PaletteShadowView?
    var tabHint: PaletteTabHint?
    var keyMonitor: Any?
    /// The field editor's selection look before the completion style.
    var savedSelectionAttributes: [NSAttributedString.Key: Any]?
    weak var styledEditor: NSTextView?
    /// Set when the bar opened over a new, empty Split pane: what it opens loads there, and dismissing it
    /// with Esc or a click outside closes that pane again while it is still empty.
    var splitPaneID: UUID?
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
    /// The empty Split pane the open bar belongs to, without creating palette state.
    var paletteSplitPaneID: UUID? { (objc_getAssociatedObject(self, &paletteStateKey) as? PaletteState)?.splitPaneID }
    func resetPaletteState() {
        guard let state = objc_getAssociatedObject(self, &paletteStateKey) as? PaletteState else { return }
        if let monitor = state.keyMonitor { NSEvent.removeMonitor(monitor) }
        if let editor = state.styledEditor, let saved = state.savedSelectionAttributes { editor.selectedTextAttributes = saved }
        objc_setAssociatedObject(self, &paletteStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
