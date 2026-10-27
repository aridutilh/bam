import AppKit
import QuartzCore

/// A trailing button on a confirmation, such as Share on "Copied Current URL".
struct PageFeedbackAction {
    var symbol: String
    var label: String
    /// Gets the button to anchor UI to, and a call to make once that UI has closed:
    /// the confirmation stays up until then, so what is anchored to it is not orphaned.
    var perform: @MainActor (NSView, @escaping @MainActor () -> Void) -> Void
}

/// A transient confirmation in the page's top-right corner, without changing
/// its first responder or intercepting pointer input outside its own button.
/// Measured from Arc's copy toast: a frosted pill about 46 points tall, 8
/// points in from the page's corner, that grows from its center in ~0.2 s,
/// stays about 4.5 s (longer while the pointer rests on it) and shrinks away.
@MainActor final class PageFeedbackCoordinator {
    var view: NSView { overlay }
    var isVisible: Bool { overlay.superview != nil && !overlay.isHidden }
    private(set) var message: String?
    static let displayDuration: TimeInterval = 4.5

    private let overlay = PageFeedbackOverlay(frame: .zero)
    private let motion = CubicAnimator()
    private var dismissal: DispatchWorkItem?
    private var generation: UInt = 0

    init() { overlay.isHidden = true }

    func show(_ message: String, symbol: String, in host: NSView, action: PageFeedbackAction? = nil) {
        guard !message.isEmpty else { hide(); return }
        generation &+= 1
        let request = generation
        dismissal?.cancel(); dismissal = nil
        motion.stop()
        let sameHost = overlay.superview === host
        if !sameHost {
            overlay.removeFromSuperview()
            overlay.frame = host.bounds
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlay.alphaValue = 0
            overlay.setPopProgress(0)
        }
        self.message = message
        overlay.configure(message: message, action: action.map { action in
            PageFeedbackAction(symbol: action.symbol, label: action.label) { [weak self] anchor, _ in
                // Held while the action's UI is open, then a little longer.
                self?.dismissal?.cancel(); self?.dismissal = nil
                action.perform(anchor) { self?.schedule(request: request, after: 2) }
            }
        })
        overlay.isHidden = false
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        motion.animationView = overlay
        overlay.setPopProgress(1)
        overlay.alphaValue = 1
        // Core Animation times the grow from its first rendered frame, so a
        // busy main thread cannot skip the start of it. Arc's grow is even, not
        // front-loaded: about a fifth, half, three quarters, then settled.
        if !BamTheme.reduceMotion { overlay.animateIn(from: sameHost ? 0.85 : 0.2) }
        schedule(request: request, after: Self.displayDuration)
        if let application = NSApp {
            NSAccessibility.post(element: application, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func schedule(request: UInt, after delay: TimeInterval) {
        guard generation == request else { return }
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            // Resting the pointer on the confirmation keeps it.
            if self.overlay.containsPointer { self.schedule(request: request, after: 1); return }
            self.fadeOut(request: request)
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        generation &+= 1
        dismissal?.cancel(); dismissal = nil
        motion.stop()
        overlay.stopAnimations()
        overlay.setPopProgress(1)
        message = nil
        overlay.isHidden = true
        overlay.removeFromSuperview()
        overlay.alphaValue = 0
    }

    private func fadeOut(request: UInt) {
        guard generation == request, isVisible else { return }
        dismissal = nil
        guard !BamTheme.reduceMotion else { hide(); return }
        overlay.stopAnimations()
        motion.animate(from: 1, to: 0, duration: 0.16, controlPoints: (0.4, 0, 0.9, 0.6), update: { [weak self] progress in
            guard let self, self.generation == request else { return }
            self.overlay.setPopProgress(0.12 + 0.88 * progress)
            self.overlay.alphaValue = progress
        }, completion: { [weak self] in
            guard let self, self.generation == request else { return }
            self.hide()
        })
    }

    deinit { dismissal?.cancel() }
}

@MainActor private final class PageFeedbackOverlay: NSView {
    private let pill = PageFeedbackCard(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let button = PageFeedbackButton(frame: .zero)
    private var action: PageFeedbackAction?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("page.feedback")
        setAccessibilityElement(false)
        pill.identifier = NSUserInterfaceItemIdentifier("page.feedback.pill")
        pill.setAccessibilityElement(false)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        button.target = self
        button.action = #selector(performAction)
        addSubview(pill)
        pill.addSubview(label); pill.addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("Page feedback is created programmatically") }

    var containsPointer: Bool {
        guard let window, !isHidden else { return false }
        let point = pill.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return pill.bounds.contains(point)
    }

    func configure(message: String, action: PageFeedbackAction?) {
        label.stringValue = message
        self.action = action
        button.isHidden = action == nil
        if let action {
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.label)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            button.setAccessibilityLabel(action.label)
            button.toolTip = action.label
        }
    }

    @objc private func performAction() { action?.perform(button, {}) }

    override func layout() {
        super.layout()
        // Measure the real font and leave the text cell's drawing padding, so
        // a short confirmation never truncates when the page has room.
        let font = label.font ?? .systemFont(ofSize: 14, weight: .semibold)
        let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 10
        let inset = min(8, max(0, bounds.width / 8))
        let insetY = min(8, max(0, bounds.height / 8))
        let available = max(0, bounds.width - 2 * inset)
        let buttonWidth: CGFloat = 31, gap: CGFloat = 3
        let lead: CGFloat = 12
        // A narrow Split pane drops the button before it shortens the words.
        let wantsButton = action != nil && lead + textWidth + gap + buttonWidth + 8 <= available
        button.isHidden = !wantsButton
        let trailing: CGFloat = wantsButton ? 12 : lead + 2
        let content = lead + textWidth + (wantsButton ? gap + buttonWidth : 0) + trailing
        let width = min(max(wantsButton ? 0 : 120, content), min(460, available))
        let height = min(46, max(0, bounds.height - 2 * insetY))
        pill.frame = NSRect(x: max(0, bounds.width - inset - width), y: insetY, width: width, height: height)
        let labelHeight = min(20, height)
        let labelWidth = max(0, width - lead - trailing - (wantsButton ? gap + buttonWidth : 0))
        label.frame = NSRect(x: min(lead, width), y: (height - labelHeight) / 2, width: labelWidth, height: labelHeight)
        let buttonHeight = min(28, height)
        button.frame = NSRect(x: width - trailing - buttonWidth, y: (height - buttonHeight) / 2, width: buttonWidth, height: buttonHeight)
        pill.needsLayout = true
        applyPopScale()
    }

    private var popScale: CGFloat = 1

    /// 0 is a pinpoint at the pill's center, 1 its natural size.
    func setPopProgress(_ progress: CGFloat) {
        popScale = 0.2 + 0.8 * min(1, max(0, progress))
        applyPopScale()
    }

    private func centeredScale(_ scale: CGFloat, in layer: CALayer) -> CATransform3D {
        // Scale around the pill's center whatever anchor AppKit gave its layer.
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = x * (1 - scale)
        transform.m42 = y * (1 - scale)
        return transform
    }

    private func applyPopScale() {
        guard let layer = pill.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = centeredScale(popScale, in: layer)
        CATransaction.commit()
    }

    func animateIn(from scale: CGFloat) {
        guard let layer = pill.layer else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: centeredScale(scale, in: layer))
        grow.toValue = NSValue(caTransform3D: centeredScale(1, in: layer))
        grow.duration = 0.24
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = scale < 0.5 ? 0 : 0.6
        fade.toValue = 1
        fade.duration = 0.17
        layer.add(grow, forKey: "pop.grow")
        layer.add(fade, forKey: "pop.fade")
    }

    func stopAnimations() {
        pill.layer?.removeAnimation(forKey: "pop.grow")
        pill.layer?.removeAnimation(forKey: "pop.fade")
    }

    /// Only the action button takes clicks; the page under the words stays clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !button.isHidden, popScale > 0.95, let superview else { return nil }
        let local = button.convert(point, from: superview)
        return button.bounds.contains(local) ? button : nil
    }
}

/// Frosted glass with a hairline rim and a soft shadow, light or dark with the page chrome.
@MainActor private final class PageFeedbackCard: NSView {
    private let glass = NSVisualEffectView(frame: .zero)
    private let tint = CALayer()
    private let rim = CAShapeLayer()
    private var displayOptionsObserver: NSObjectProtocol?
    private static let radius: CGFloat = 12
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.material = .popover
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Self.radius
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.setAccessibilityElement(false)
        addSubview(glass)
        glass.layer?.addSublayer(tint)
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        rim.fillColor = nil
        rim.lineWidth = 1
        layer?.addSublayer(rim)
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.needsLayout = true } }
    }
    required init?(coder: NSCoder) { fatalError("Page feedback is created programmatically") }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Self.radius - 0.5, cornerHeight: Self.radius - 0.5, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = glass.bounds
        tint.backgroundColor = (dark ? NSColor(white: 0.16, alpha: solid ? 1 : 0.35)
                                     : NSColor(white: 0.97, alpha: solid ? 1 : 0.45)).cgColor
        rim.frame = bounds
        rim.path = path
        rim.strokeColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.11)).cgColor
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        layer?.shadowOpacity = dark ? 0.38 : 0.16
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
}

/// The small rounded-square button at the pill's end.
@MainActor private final class PageFeedbackButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        contentTintColor = .labelColor
        focusRingType = .none
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let pressed = isHighlighted
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        let fill: NSColor = dark ? NSColor.white.withAlphaComponent(pressed ? 0.2 : hovering ? 0.15 : 0.09)
                                 : NSColor.white.withAlphaComponent(pressed ? 0.45 : hovering ? 0.9 : 0.65)
        fill.setFill(); shape.fill()
        (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.13)).setStroke()
        shape.lineWidth = 1; shape.stroke()
        if let image {
            let size = image.size
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            let tinted = image.copy() as! NSImage
            tinted.lockFocus(); NSColor.labelColor.set(); NSRect(origin: .zero, size: size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(in: rect)
        }
    }
}
