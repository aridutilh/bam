import AppKit
import QuartzCore

@MainActor final class ArkVideoPanel: NSPanel {
    var onEscape: (() -> Void)?
    weak var overlay: PiPOverlayView?
    var positionScreenFrames: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    var positionReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let positionAnimator = CubicAnimator()
    private var physicalVelocity = PiPPhysicalVelocity()
    private var scrollEndWork: DispatchWorkItem?
    private(set) var isScrollDragging = false
    private(set) var isPositionSnapRunning = false
    private var positionGeneration: UInt = 0
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { cancelPositioning(); onEscape?() }
    override func close() { cancelPositioning(); super.close() }
    override func orderOut(_ sender: Any?) { cancelPositioning(); super.orderOut(sender) }
    override func sendEvent(_ event: NSEvent) {
        // Intercept before controls/WebKit dispatch so hovering a button or the
        // volume slider moves the panel too, without clicking or taking focus.
        if handleScrollMotion(event) { return }
        if event.type == .keyDown {
            overlay?.revealControls()
            if event.keyCode == 53 { onEscape?(); return }
            if overlay?.handleKey(event) == true { return }
        }
        super.sendEvent(event)
    }

    @discardableResult func handleScrollMotion(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, event.window === self else { return false }
        let phase = event.phase
        guard event.hasPreciseScrollingDeltas || !phase.isEmpty || !event.momentumPhase.isEmpty else { return false }
        if phase.contains(.cancelled) {
            cancelPositioning()
            setFrame(PiPPositioning.releaseFrame(frame, screens: positionScreenFrames(), magnet: false), display: true)
            return true
        }
        // A latched inertial tail must never add movement, even if the last
        // physical end and the first momentum packet arrive together. A new
        // physical begin takes precedence over the previous stream's tail.
        if !event.momentumPhase.isEmpty && !phase.contains(.began) && !phase.contains(.mayBegin) {
            if isScrollDragging { finishScrollDrag(at: event.timestamp) }
            return true
        }
        if phase.contains(.ended) {
            if isScrollDragging { finishScrollDrag(at: event.timestamp) }
            return true
        }
        if phase.contains(.mayBegin) {
            cancelPositioning(); overlay?.revealControls(); return true
        }
        if phase.contains(.began) || (!isScrollDragging && !phase.contains(.stationary)) {
            cancelPositioning(); isScrollDragging = true
            physicalVelocity.begin(at: event.timestamp)
        }
        guard isScrollDragging else { return true }
        scrollEndWork?.cancel(); scrollEndWork = nil
        overlay?.revealControls()
        if !phase.contains(.stationary) {
            let delta = PiPPositioning.fingerDelta(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                                 invertedFromDevice: event.isDirectionInvertedFromDevice)
            physicalVelocity.record(delta, at: event.timestamp)
            let target = PiPPositioning.dragFrame(frame, delta: delta, screens: positionScreenFrames())
            setFrameOrigin(target.origin)
        } else {
            physicalVelocity.pause(at: event.timestamp)
        }
        if phase.isEmpty {
            // Precise devices without physical phases finish after a quiet
            // interval; momentum is handled above and cannot extend movement.
            let work = DispatchWorkItem { [weak self] in self?.finishScrollDrag(at: nil) }
            scrollEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        return true
    }

    func cancelPositioning() {
        scrollEndWork?.cancel(); scrollEndWork = nil
        isScrollDragging = false
        physicalVelocity.reset()
        positionGeneration &+= 1
        isPositionSnapRunning = false
        positionAnimator.stop()
    }
    private func finishScrollDrag(at timestamp: TimeInterval?) {
        // A quiet-time fallback has no recent finger-up packet: fit/snap locally
        // without resurrecting stale velocity. Momentum packets only end the
        // physical stream; their deltas never feed this continuation.
        let velocity = timestamp.map { physicalVelocity.velocity(at: $0) } ?? .zero
        finishPositioning(velocity: velocity, animated: true)
    }
    /// Called after AppKit's native click-drag loop returns on mouse-up too.
    func finishPointerDrag(animated: Bool = true) {
        finishPositioning(velocity: .zero, animated: animated)
    }
    private func finishPositioning(velocity: CGPoint, animated: Bool) {
        cancelPositioning()
        let start = frame
        let plan = PiPPositioning.releasePlan(start, velocity: velocity, screens: positionScreenFrames())
        let target = plan.frame
        guard target != start else { return }
        guard animated, !positionReduceMotion() else {
            setFrame(target, display: true); return
        }
        let generation = positionGeneration
        isPositionSnapRunning = true
        positionAnimator.animationView = contentView
        positionAnimator.animate(from: 0, to: 1, duration: plan.duration, controlPoints: (0.22, 0.61, 0.36, 1), update: { [weak self] progress in
            guard let self, self.positionGeneration == generation else { return }
            self.setFrame(NSRect(x: start.minX + (target.minX - start.minX) * progress,
                                 y: start.minY + (target.minY - start.minY) * progress,
                                 width: start.width + (target.width - start.width) * progress,
                                 height: start.height + (target.height - start.height) * progress), display: true)
        }, completion: { [weak self] in
            guard let self, self.positionGeneration == generation else { return }
            self.isPositionSnapRunning = false
        })
    }
    deinit { scrollEndWork?.cancel() }
}

/// AppKit controls stay above the rehosted page; no player cloning or custom
/// website JavaScript UI is needed. The empty overlay is also the drag surface.
@MainActor final class PiPOverlayView: NSView {
    var onReturn: (() -> Void)?
    var onClose: (() -> Void)?
    var onCommand: ((String, Double) -> Void)?
    private let controls = PiPControlsSurface()
    private let returnButton = PiPControlButton(symbol: "pip.exit", label: "Return to Tab (R)", name: "return")
    private let closeButton = PiPControlButton(symbol: "xmark", label: "Close Floating Video (Escape)", name: "close")
    private let backward = PiPControlButton(symbol: "gobackward.10", label: "Back 10 Seconds (Left Arrow)", name: "backward")
    private let play = PiPControlButton(symbol: "pause.fill", label: "Pause (Space)", name: "playPause")
    private let forward = PiPControlButton(symbol: "goforward.10", label: "Forward 10 Seconds (Right Arrow)", name: "forward")
    private let mute = PiPControlButton(symbol: "speaker.wave.2.fill", label: "Mute (M)", name: "mute")
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00")
    private let resizeGrip = PiPResizeGrip()
    private var tracking: NSTrackingArea?
    private var hideWork: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        controls.frame = bounds; controls.autoresizingMask = [.width, .height]
        addSubview(controls)
        for control in [returnButton, closeButton, backward, play, forward, mute, volume, time, resizeGrip] as [NSView] { controls.addSubview(control) }
        returnButton.handler = { [weak self] in self?.onReturn?() }
        closeButton.handler = { [weak self] in self?.onClose?() }
        backward.handler = { [weak self] in self?.onCommand?("seek", -10) }
        play.handler = { [weak self] in self?.onCommand?("play", 0) }
        forward.handler = { [weak self] in self?.onCommand?("seek", 10) }
        mute.handler = { [weak self] in self?.onCommand?("mute", 0) }
        volume.identifier = NSUserInterfaceItemIdentifier("pip.volume")
        volume.setAccessibilityLabel("Video Volume")
        volume.toolTip = "Volume (Up/Down Arrow)"
        volume.target = self; volume.action = #selector(volumeChanged)
        volume.isContinuous = true
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.textColor = .white; time.alignment = .right
        time.setAccessibilityElement(false)
        setAccessibilityLabel("Floating video. Drag or scroll with two fingers to move; flick to glide, or release near a corner to snap. Tab to navigate controls.")
        returnButton.nextKeyView = closeButton; closeButton.nextKeyView = backward
        backward.nextKeyView = play; play.nextKeyView = forward; forward.nextKeyView = mute
        mute.nextKeyView = volume; volume.nextKeyView = resizeGrip; resizeGrip.nextKeyView = returnButton
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        returnButton.frame = NSRect(x: 10, y: h - 42, width: 32, height: 32)
        closeButton.frame = NSRect(x: w - 42, y: h - 42, width: 32, height: 32)
        backward.frame = NSRect(x: w / 2 - 82, y: h / 2 - 22, width: 44, height: 44)
        play.frame = NSRect(x: w / 2 - 26, y: h / 2 - 26, width: 52, height: 52)
        forward.frame = NSRect(x: w / 2 + 38, y: h / 2 - 22, width: 44, height: 44)
        mute.frame = NSRect(x: 10, y: 10, width: 28, height: 28)
        volume.frame = NSRect(x: 43, y: 14, width: min(90, max(64, w - 128)), height: 20)
        time.frame = NSRect(x: w - 120, y: 17, width: 86, height: 16)
        time.isHidden = w < 300
        resizeGrip.frame = NSRect(x: w - 25, y: 2, width: 23, height: 23)
    }
    func update(_ state: [String: Any]) {
        let paused = state["paused"] as? Bool ?? true
        let muted = state["muted"] as? Bool ?? false
        let level = (state["volume"] as? NSNumber)?.doubleValue ?? 1
        play.configure(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Play (Space)" : "Pause (Space)")
        mute.configure(symbol: muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", label: muted ? "Unmute (M)" : "Mute (M)")
        if window?.firstResponder !== volume { volume.doubleValue = muted ? 0 : level }
        let seekable = state["canSeek"] as? Bool ?? false
        backward.isEnabled = seekable; forward.isEnabled = seekable
        let elapsed = (state["time"] as? NSNumber)?.doubleValue ?? 0
        let duration = (state["duration"] as? NSNumber)?.doubleValue ?? 0
        time.stringValue = duration > 0 ? "\(clock(elapsed)) / \(clock(duration))" : clock(elapsed)
    }
    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, min(seconds.isFinite ? seconds : 0, 35_999_999)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
    @objc private func volumeChanged() { onCommand?("volume", volume.doubleValue); revealControls() }
    func stop() { hideWork?.cancel(); hideWork = nil }
    func revealControls() {
        stop()
        setControlsVisible(true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let focused = self.window?.firstResponder as? NSView,
               focused !== self, focused.isDescendant(of: self.controls) { return }
            self.setControlsVisible(false)
        }
        hideWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2.3, execute: work)
    }
    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { revealControls() }
    override func mouseMoved(with event: NSEvent) { revealControls() }
    override func mouseExited(with event: NSEvent) {
        stop()
        if let focused = window?.firstResponder as? NSView, focused !== self, focused.isDescendant(of: controls) { return }
        setControlsVisible(false)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === controls || controls.alphaValue < 0.1 ? self : hit
    }
    override func mouseDown(with event: NSEvent) {
        revealControls(); window?.makeFirstResponder(self)
        if event.clickCount == 2 { onReturn?() }
        else if let panel = window as? ArkVideoPanel {
            panel.cancelPositioning()
            panel.performDrag(with: event)
            if panel.isVisible { panel.finishPointerDrag() }
        } else { window?.performDrag(with: event) }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              !(window?.firstResponder is NSControl), window?.firstResponder !== resizeGrip else { return false }
        switch event.keyCode {
        case 49: onCommand?("play", 0)
        case 123: onCommand?("seek", -10)
        case 124: onCommand?("seek", 10)
        case 126: onCommand?("volumeStep", 0.1)
        case 125: onCommand?("volumeStep", -0.1)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m": onCommand?("mute", 0)
            case "r": onReturn?()
            default: return false
            }
        }
        return true
    }
    deinit { hideWork?.cancel() }
}

@MainActor private final class PiPControlsSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Subtle gradients keep controls legible without a permanent toolbar.
        NSGradient(colors: [.black.withAlphaComponent(0.56), .clear, .black.withAlphaComponent(0.50)])?
            .draw(in: bounds, angle: 90)
    }
}

@MainActor private final class PiPControlButton: NSButton {
    var handler: (() -> Void)?
    init(symbol: String, label: String, name: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("pip.\(name)")
        isBordered = false; imagePosition = .imageOnly; focusRingType = .exterior
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        contentTintColor = .white
        target = self; action = #selector(pressed)
        configure(symbol: symbol, label: label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: identifier?.rawValue == "pip.playPause" ? 22 : 16, weight: .medium))
        toolTip = label; setAccessibilityLabel(label)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() { super.layout(); layer?.cornerRadius = min(bounds.width, bounds.height) / 2 }
    @objc private func pressed() { handler?() }
}

@MainActor private final class PiPResizeGrip: NSView {
    private var startPoint = NSPoint.zero
    private var startFrame = NSRect.zero
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("pip.resize")
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("Resize Floating Video")
        toolTip = "Drag to resize video"
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5
        path.move(to: NSPoint(x: 7, y: 4)); path.line(to: NSPoint(x: 18, y: 15))
        path.move(to: NSPoint(x: 12, y: 4)); path.line(to: NSPoint(x: 18, y: 10)); path.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        (window as? ArkVideoPanel)?.cancelPositioning()
        window?.makeFirstResponder(self)
        startPoint = NSEvent.mouseLocation; startFrame = window?.frame ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let ratio = window.contentAspectRatio.width / max(0.001, window.contentAspectRatio.height)
        let delta = NSEvent.mouseLocation
        let dx = delta.x - startPoint.x, dy = -(delta.y - startPoint.y) * ratio
        resize(to: startFrame.width + (abs(dx) >= abs(dy) ? dx : dy), from: startFrame)
    }
    private func resize(to requestedWidth: CGFloat, from frame: NSRect) {
        guard let window else { return }
        (window as? ArkVideoPanel)?.cancelPositioning()
        let ratio = window.contentAspectRatio.width / max(0.001, window.contentAspectRatio.height)
        let visible = window.screen?.visibleFrame ?? frame
        let limit = min(visible.width, visible.height * ratio)
        let width = min(max(window.contentMinSize.width, requestedWidth), max(window.contentMinSize.width, limit))
        let size = NSSize(width: width, height: width / ratio)
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        setAccessibilityValue("\(Int(width)) points wide")
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard let window else { return false }; resize(to: window.frame.width + 40, from: window.frame); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard let window else { return false }; resize(to: window.frame.width - 40, from: window.frame); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 || event.keyCode == 126 { _ = accessibilityPerformIncrement() }
        else if event.keyCode == 123 || event.keyCode == 125 { _ = accessibilityPerformDecrement() }
        else { super.keyDown(with: event) }
    }
}
