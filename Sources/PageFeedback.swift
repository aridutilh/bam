import AppKit
import QuartzCore

/// A transient confirmation attached to the current page, without changing its
/// first responder or intercepting pointer input.
@MainActor final class PageFeedbackCoordinator {
    var view: NSView { overlay }
    var isVisible: Bool { overlay.superview != nil && !overlay.isHidden }
    private(set) var message: String?

    private let overlay = PageFeedbackOverlay(frame: .zero)
    private let fade = CubicAnimator()
    private let pop = CubicAnimator()
    private var dismissal: DispatchWorkItem?
    private var generation: UInt = 0

    init() { overlay.isHidden = true }

    func show(_ message: String, symbol: String, in host: NSView) {
        guard !message.isEmpty else { hide(); return }
        generation &+= 1
        let request = generation
        dismissal?.cancel(); dismissal = nil
        fade.stop()
        pop.stop()
        let sameHost = overlay.superview === host
        if !sameHost {
            overlay.removeFromSuperview()
            overlay.frame = host.bounds
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlay.alphaValue = 0
        }
        self.message = message
        overlay.configure(message: message, symbol: symbol)
        overlay.isHidden = false
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        pop.animationView = overlay
        pop.animate(from: 0, to: 1, duration: 0.28,
                    controlPoints: (0, 0, 1, 1), update: { [weak self] progress in
            guard let self, self.generation == request else { return }
            self.overlay.setPopProgress(progress)
        })
        fade.animationView = overlay
        fade.animate(from: overlay.alphaValue, to: 1, duration: 0.08,
                     controlPoints: (0.22, 0.61, 0.36, 1), update: { [weak self] value in
            guard let self, self.generation == request else { return }
            self.overlay.alphaValue = value
        })
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.fadeOut(request: request)
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        if let application = NSApp {
            NSAccessibility.post(element: application, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func hide() {
        generation &+= 1
        dismissal?.cancel(); dismissal = nil
        fade.stop()
        pop.stop()
        overlay.setPopProgress(1)
        message = nil
        overlay.isHidden = true
        overlay.removeFromSuperview()
        overlay.alphaValue = 0
    }

    private func fadeOut(request: UInt) {
        guard generation == request, isVisible else { return }
        dismissal = nil
        fade.animate(from: overlay.alphaValue, to: 0, duration: 0.16,
                     controlPoints: (0.25, 0.1, 0.25, 1), update: { [weak self] value in
            guard let self, self.generation == request else { return }
            self.overlay.alphaValue = value
        }, completion: { [weak self] in
            guard let self, self.generation == request else { return }
            self.hide()
        })
    }

    deinit { dismissal?.cancel() }
}

@MainActor private final class PageFeedbackOverlay: NSView {
    private let pill = PageFeedbackCard(frame: .zero)
    private let icon = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("page.feedback")
        setAccessibilityElement(false)
        pill.identifier = NSUserInterfaceItemIdentifier("page.feedback.pill")
        pill.setAccessibilityElement(false)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        addSubview(pill)
        pill.addSubview(icon); pill.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Page feedback is created programmatically") }

    func configure(message: String, symbol: String) {
        label.stringValue = message
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    override func layout() {
        super.layout()
        // Intrinsic width can omit text-cell drawing padding and truncate a
        // short confirmation even when its host has ample room. Measure the
        // actual font and reserve padding inside the label as well as the pill.
        let font = label.font ?? .systemFont(ofSize: 13, weight: .semibold)
        let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 12
        // Omit the redundant symbol when a narrow Split pane needs the space.
        let compact = textWidth + 66 > bounds.width - 32
        let insetX = min(compact ? 8 : 16, max(0, bounds.width / 8))
        let leading: CGFloat = compact ? 22 : 44
        let padding: CGFloat = compact ? 44 : 66
        let insetY = min(16, max(0, bounds.height / 8))
        let width = max(0, min(textWidth + padding, min(420, bounds.width - 2 * insetX)))
        let height = min(46, max(0, bounds.height - 2 * insetY))
        // Flipped overlay coordinates keep the tag at the visual bottom-right
        // of this page, including an individual Split pane or a preview window.
        pill.frame = NSRect(x: max(0, bounds.width - insetX - width),
                            y: bounds.maxY - insetY - height, width: width, height: height)
        let iconSize = min(14, height)
        icon.isHidden = compact
        icon.frame = NSRect(x: min(22, width), y: (height - iconSize) / 2,
                            width: min(iconSize, max(0, width - 22)), height: iconSize)
        let labelHeight = min(20, height)
        label.frame = NSRect(x: min(leading, width), y: (height - labelHeight) / 2,
                             width: max(0, width - padding), height: labelHeight)
        pill.needsLayout = true
        applyPopScale()
    }

    private var popScale: CGFloat = 1

    func setPopProgress(_ progress: CGFloat) {
        // A short impact, then a single small settle. Text returns to its exact
        // native scale; Reduce Motion jumps directly to progress 1.
        let t = min(1, max(0, progress))
        if t < 0.44 {
            let rise = 1 - pow(1 - t / 0.44, 3)
            popScale = 0.88 + 0.155 * rise
        } else {
            let settle = (t - 0.44) / 0.56
            popScale = 1 + 0.035 * pow(1 - settle, 3)
        }
        applyPopScale()
    }

    private func applyPopScale() {
        guard let layer = pill.layer else { return }
        // Preserve AppKit's layer anchor and view frame. Scale around the card
        // center even if AppKit uses a non-central anchor on this backing layer.
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var transform = CATransform3DMakeScale(popScale, popScale, 1)
        transform.m41 = x * (1 - popScale)
        transform.m42 = y * (1 - popScale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A restrained, original comic-burst silhouette cut from native frosted glass.
/// Points stay outside the text's quiet central band, with a fine rim and soft
/// shadow rather than an opaque cartoon fill.
@MainActor private final class PageFeedbackCard: NSView {
    private let glass = NSVisualEffectView(frame: .zero)
    private let rim = CAShapeLayer()
    private var maskSize: NSSize = .zero
    private var displayOptionsObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.setAccessibilityElement(false)
        addSubview(glass)
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        rim.lineWidth = 0.75
        rim.lineJoin = .round
        layer?.addSublayer(rim)
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.needsLayout = true }
    }
    required init?(coder: NSCoder) { fatalError("Page feedback is created programmatically") }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.78
        let path = Self.outline(in: bounds)
        if maskSize != bounds.size {
            maskSize = bounds.size
            glass.maskImage = NSImage(size: bounds.size, flipped: true) { _ in
                NSColor.black.setFill(); path.fill(); return true
            }
        }
        let cgPath = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            switch path.element(at: index, associatedPoints: &points) {
            case .moveTo: cgPath.move(to: points[0])
            case .lineTo: cgPath.addLine(to: points[0])
            case .closePath: cgPath.closeSubpath()
            default: break
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rim.frame = bounds
        rim.path = cgPath
        rim.fillColor = NSColor.white.withAlphaComponent(0.035).cgColor
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        rim.strokeColor = (dark ? NSColor.white.withAlphaComponent(0.28)
                              : NSColor.black.withAlphaComponent(0.14)).cgColor
        layer?.shadowPath = cgPath
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    private static func outline(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height
        let path = NSBezierPath()
        guard w >= 44, h >= 24 else { return path }
        let points: [NSPoint] = [
            .init(x: 2, y: h * 0.48), .init(x: 11, y: h * 0.30),
            .init(x: 8, y: 7), .init(x: 27, y: 9),
            .init(x: 33, y: 2), .init(x: 42, y: 7),
            .init(x: w - 37, y: 7), .init(x: w - 25, y: 2),
            .init(x: w - 23, y: 9), .init(x: w - 7, y: 7),
            .init(x: w - 10, y: h * 0.35), .init(x: w - 2, y: h * 0.53),
            .init(x: w - 11, y: h * 0.67), .init(x: w - 8, y: h - 7),
            .init(x: w - 28, y: h - 9), .init(x: w - 35, y: h - 2),
            .init(x: w - 43, y: h - 7), .init(x: 39, y: h - 7),
            .init(x: 25, y: h - 2), .init(x: 24, y: h - 9),
            .init(x: 7, y: h - 7), .init(x: 10, y: h * 0.64)
        ]
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
        return path
    }
}
