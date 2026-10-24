import AppKit

/// A transient confirmation attached to the current page, without changing its
/// first responder or intercepting pointer input.
@MainActor final class PageFeedbackCoordinator {
    var view: NSView { overlay }
    var isVisible: Bool { overlay.superview != nil && !overlay.isHidden }
    private(set) var message: String?

    private let overlay = PageFeedbackOverlay(frame: .zero)
    private let fade = CubicAnimator()
    private var dismissal: DispatchWorkItem?
    private var generation: UInt = 0

    init() { overlay.isHidden = true }

    func show(_ message: String, symbol: String, in host: NSView) {
        guard !message.isEmpty else { hide(); return }
        generation &+= 1
        let request = generation
        dismissal?.cancel(); dismissal = nil
        fade.stop()
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
        fade.animationView = overlay
        fade.animate(from: overlay.alphaValue, to: 1, duration: 0.12,
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
    private let pill = NSVisualEffectView(frame: .zero)
    private let icon = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("page.feedback")
        setAccessibilityElement(false)
        pill.identifier = NSUserInterfaceItemIdentifier("page.feedback.pill")
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.appearance = NSAppearance(named: .darkAqua)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 18
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        pill.setAccessibilityElement(false)
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
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
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
    }

    override func layout() {
        super.layout()
        // Intrinsic width can omit text-cell drawing padding and truncate a
        // short confirmation even when its host has ample room. Measure the
        // actual font and reserve padding inside the label as well as the pill.
        let font = label.font ?? .systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 12
        let width = max(0, min(textWidth + 52, min(420, bounds.width - 32)))
        let height = min(36, max(0, bounds.height))
        // This full-host overlay is flipped even when its host is not, so the
        // confirmation stays 28 points from the visual top in either host.
        pill.frame = NSRect(x: max(0, (bounds.width - width) / 2),
                            y: min(28, max(0, bounds.height - height)), width: width, height: height)
        pill.layer?.cornerRadius = height / 2
        icon.frame = NSRect(x: 14, y: (height - 16) / 2, width: 16, height: 16)
        let labelHeight = min(18, height)
        label.frame = NSRect(x: 38, y: (height - labelHeight) / 2,
                             width: max(0, width - 52), height: labelHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
