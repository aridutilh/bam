import AppKit
import CoreText

/// bambrowser.com's palette, as dynamic colors that follow the system
/// appearance the same way the site follows `prefers-color-scheme`:
/// matte pink paper in light mode, plum in dark, sale-sticker red for action.
@MainActor enum BamTheme {
    private static func dynamic(light: Int, dark: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }
    /// The page: `--bg`.
    static let bg = dynamic(light: 0xFAE1E8, dark: 0x241318)
    /// A quieter paper for wells and fields: `--surface`.
    static let surface = dynamic(light: 0xFFFAFA, dark: 0x2D1A20)
    /// Cards: `--card`.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x352027)
    /// Body text: `--ink`.
    static let ink = dynamic(light: 0x2A141B, dark: 0xFBEBEF)
    /// Secondary text: `--muted`.
    static let muted = dynamic(light: 0x6E5059, dark: 0xC9A6AF)
    /// The sticker red: `--red`.
    static let red = dynamic(light: 0xEE3123, dark: 0xFF4B3B)
    /// The red a button sits on: `--red-deep`.
    static let redDeep = dynamic(light: 0xC9271B, dark: 0xE5331F)
    /// Hairlines and borders: `--line`.
    static let line = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xFB / 255, green: 0xEB / 255, blue: 0xEF / 255, alpha: 0.16)
            : NSColor(srgbRed: 0x2A / 255, green: 0x14 / 255, blue: 0x1B / 255, alpha: 0.14)
    }
    /// A soft wash of red for picked chips and selected rows.
    static let redWash = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0x4B / 255, blue: 0x3B / 255, alpha: 0.18)
            : NSColor(srgbRed: 0xEE / 255, green: 0x31 / 255, blue: 0x23 / 255, alpha: 0.11)
    }
    /// The card shadow: `--shadow`, softened for stacked native cards.
    static let shadow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.45)
            : NSColor(srgbRed: 0x2A / 255, green: 0x14 / 255, blue: 0x1B / 255, alpha: 0.16)
    }
    static let white = NSColor.white
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension NSView {
    /// Resolves a dynamic color for a layer under this view's own appearance.
    func bamCG(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}

/// The site's type: Bricolage Grotesque for display, Instrument Sans for
/// everything else. Both are bundled under Resources/Fonts (SIL OFL) and
/// registered for this process at launch; the system fonts stand in if a
/// build lacks them, so nothing here can fail.
@MainActor enum BamType {
    static let displayFamily = "Bricolage Grotesque"
    static let sansFamily = "Instrument Sans"
    private static var registered = false
    private static var available: Set<String> = []

    /// Registers the bundled fonts once. Harnesses that run from a bare
    /// executable point `BAM_FONTS_DIR` at the folder instead.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        var folders: [URL] = []
        if let override = ProcessInfo.processInfo.environment["BAM_FONTS_DIR"] { folders.append(URL(fileURLWithPath: override)) }
        if let resources = Bundle.main.resourceURL { folders.append(resources.appendingPathComponent("Fonts")) }
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
        for family in [displayFamily, sansFamily] where NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false {
            available.insert(family)
        }
    }

    private static func wght(_ weight: NSFont.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return 200
        case .thin: return 250
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400 + weight.rawValue * 300
        }
    }
    private static func variable(_ family: String, size: CGFloat, weight: NSFont.Weight, opticalSize: Bool) -> NSFont? {
        registerFonts()
        guard available.contains(family) else { return nil }
        // Variable-font axes by their four-character tags.
        var axes: [NSNumber: NSNumber] = [0x77676874: NSNumber(value: Double(wght(weight)))] // wght
        if opticalSize { axes[0x6F70737A] = NSNumber(value: Double(min(96, max(12, size)))) } // opsz
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .variation: axes])
        return NSFont(descriptor: descriptor, size: size)
    }
    /// Headings and names.
    static func display(_ size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        variable(displayFamily, size: size, weight: weight, opticalSize: true) ?? NSFont.systemFont(ofSize: size, weight: weight == .bold ? .heavy : weight)
    }
    /// Body, labels and buttons.
    static func sans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        variable(sansFamily, size: size, weight: weight, opticalSize: false) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
    /// Keycaps.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Flat page paper that redraws when the appearance flips.
@MainActor final class BamSurfaceView: NSView {
    var fill: NSColor = BamTheme.bg { didSet { needsDisplay = true } }
    /// Runs when the system appearance flips, so the panel this paper backs
    /// can re-resolve colours it baked into plain AppKit controls' layers.
    var onAppearanceChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true; onAppearanceChange?()
    }
}

/// A paper card drawn behind a list, with the card's hairline.
@MainActor final class BamCardBacking: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        BamTheme.card.setFill(); path.fill()
        BamTheme.line.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}

/// A hairline that follows the appearance.
@MainActor final class BamHairline: NSBox {
    init() {
        super.init(frame: .zero)
        boxType = .custom; borderWidth = 0; cornerRadius = 0
        fillColor = BamTheme.line
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The site's sale-sticker burst with a word on it: twelve points, round
/// joins, the label tilted eight degrees the way every sticker on
/// bambrowser.com is. `ink` swaps red for card paper (the "draft" sticker).
@MainActor final class BamSticker: NSView {
    var text: String { didSet { needsDisplay = true } }
    var ink = false { didSet { needsDisplay = true } }
    var tilt: CGFloat = -8
    private let diameter: CGFloat
    init(_ text: String, diameter: CGFloat = 92) {
        self.text = text; self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// The same polygon the site builds: `burstPoints(12, 92, 66)` in a 200 box.
    static func burst(in rect: NSRect, points: Int = 12, outer: CGFloat = 92, inner: CGFloat = 66) -> NSBezierPath {
        let path = NSBezierPath()
        let scale = min(rect.width, rect.height) / 200
        let center = NSPoint(x: rect.midX, y: rect.midY)
        for index in 0..<(points * 2) {
            let angle = CGFloat.pi * CGFloat(index) / CGFloat(points) - .pi / 2
            let radius = (index % 2 == 0 ? outer : inner) * scale
            let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 16 * scale
        return path
    }
    override func draw(_ dirtyRect: NSRect) {
        let fill = ink ? BamTheme.card : BamTheme.red
        let label = ink ? BamTheme.ink : BamTheme.white
        // The stroke rounds the points; inset so it stays inside the view.
        let path = Self.burst(in: bounds.insetBy(dx: bounds.width * 0.06, dy: bounds.height * 0.06))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = BamTheme.shadow.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = diameter * 0.08
        shadow.shadowOffset = NSSize(width: 0, height: -diameter * 0.05)
        shadow.set()
        fill.setFill(); fill.setStroke()
        path.fill(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let size = max(9, diameter * 0.16)
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BamType.display(size, weight: .heavy), .foregroundColor: label, .paragraphStyle: style, .kern: 0.2
        ]
        let string = NSAttributedString(string: text.uppercased(), attributes: attributes)
        let width = diameter * 0.72
        let measured = string.boundingRect(with: NSSize(width: width, height: diameter), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: tilt)
        transform.concat()
        string.draw(with: NSRect(x: -width / 2, y: -measured.height / 2, width: width, height: measured.height), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A small red word in a pill: "Current", "On".
@MainActor final class BamBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String { didSet { label.stringValue = text.uppercased() } }
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.stringValue = text.uppercased()
        label.font = BamType.sans(10.5, weight: .bold)
        label.textColor = BamTheme.red
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() { layer?.backgroundColor = bamCG(BamTheme.redWash) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// Table selection in the site's red wash instead of Aqua blue.
@MainActor final class BamTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        BamTheme.redWash.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        BamTheme.red.withAlphaComponent(0.55).setStroke()
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 8.5, yRadius: 8.5)
        ring.lineWidth = 1.5
        ring.stroke()
    }
    override var isEmphasized: Bool { get { true } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
