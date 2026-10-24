import AppKit

/// Hidden native-panel checks and pure geometry. Events are local objects passed
/// to sendEvent directly; none is posted or synthesized into the system queue.
@MainActor enum PiPPositioningSmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @discardableResult static func run() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: "PiP positioning: " + message) }
            count += 1
        }
        let display = CGRect(x: 0, y: 24, width: 1200, height: 776)
        let size = CGSize(width: 320, height: 180)
        let free = CGRect(origin: CGPoint(x: 400, y: 250), size: size)
        try check(PiPPositioning.releaseFrame(free, screens: [display]) == free,
                  "free interior placement was attracted to a corner")
        let edge = CGRect(origin: CGPoint(x: 0, y: 250), size: size)
        try check(PiPPositioning.releaseFrame(edge, screens: [display]) == edge,
                  "middle-of-edge placement was attracted to a corner")
        let nearTopRight = CGRect(origin: CGPoint(x: 850, y: 600), size: size)
        try check(PiPPositioning.releaseFrame(nearTopRight, screens: [display]).origin == CGPoint(x: 864, y: 604),
                  "top-right corner did not respect visible bounds and inset")
        let left = CGRect(x: -1000, y: -120, width: 1000, height: 720)
        let nearLeft = CGRect(origin: CGPoint(x: -979, y: -98), size: size)
        try check(PiPPositioning.releaseFrame(nearLeft, screens: [display, left]).origin == CGPoint(x: -984, y: -104),
                  "negative-coordinate display corner was incorrect")
        let outside = CGRect(origin: CGPoint(x: 1100, y: 700), size: size)
        try check(PiPPositioning.releaseFrame(outside, screens: [display], magnet: false) == CGRect(x: 880, y: 620, width: 320, height: 180),
                  "release did not fit a partly offscreen panel into visible bounds")
        let right = CGRect(x: 1200, y: 0, width: 1200, height: 800)
        let crossing = CGRect(x: 870, y: 220, width: 320, height: 180)
        let crossed = PiPPositioning.dragFrame(crossing, delta: CGPoint(x: 200, y: 0), screens: [display, right])
        try check(crossed.minX == 1070 && PiPPositioning.destinationScreen(for: crossed, screens: [display, right]) == right,
                  "drag clamped to the old display instead of crossing the boundary")
        let gap = CGRect(x: 1350, y: 260, width: 320, height: 180)
        let separated = CGRect(x: 1800, y: 0, width: 1200, height: 800)
        try check(PiPPositioning.releaseFrame(gap, screens: [display, separated]).minX == 1800,
                  "release between displays did not choose the nearest visible display")
        let oversized = CGRect(x: 100, y: 100, width: 1600, height: 900)
        let fitted = PiPPositioning.releaseFrame(oversized, screens: [display])
        try check(display.contains(fitted) && abs(fitted.width / fitted.height - 16.0 / 9.0) < 0.001,
                  "moving onto a smaller display lost visibility or video aspect ratio")
        try check(PiPPositioning.releaseFrame(free, screens: []) == free,
                  "missing screen data changed free placement")
        try check(PiPPositioning.fingerDelta(x: 12, y: -8, invertedFromDevice: true) == CGPoint(x: 12, y: 8)
                  && PiPPositioning.fingerDelta(x: -12, y: 8, invertedFromDevice: false) == CGPoint(x: 12, y: 8),
                  "window movement changed direction with the scrolling preference")
        try check(PiPPositioning.fingerDelta(x: .nan, y: .infinity, invertedFromDevice: true) == .zero,
                  "invalid deltas escaped into window geometry")

        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let start = CGRect(x: visible.midX - 160, y: visible.midY - 90, width: 320, height: 180)
        let previousKey = NSApp.keyWindow
        let previousResponder = previousKey?.firstResponder
        let panel = ArkVideoPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 320, height: 180)
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.positionScreenFrames = { [visible] }
        let overlay = PiPOverlayView(frame: CGRect(origin: .zero, size: start.size))
        panel.contentView = overlay; panel.overlay = overlay
        overlay.layoutSubtreeIfNeeded()
        defer { overlay.stop(); panel.close() }
        let slider = descendants(of: overlay).first { $0.identifier?.rawValue == "pip.volume" }
        guard let slider else { throw Failure(description: "PiP positioning: volume control missing") }
        let hover = slider.convert(CGPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil)
        var time = ProcessInfo.processInfo.systemUptime
        func event(_ x: CGFloat = 0, _ y: CGFloat = 0, phase: NSEvent.Phase,
                   momentum: NSEvent.Phase = [], precise: Bool = true,
                   inverted: Bool = true) -> PositionScrollEvent {
            time += 0.02
            return PositionScrollEvent(window: panel, point: hover, x: x, y: y,
                phase: phase, momentum: momentum, precise: precise, inverted: inverted, time: time)
        }
        let original = panel.frame.origin
        panel.sendEvent(event(10, 12, phase: .began))
        try check(panel.isScrollDragging && near(panel.frame.origin, CGPoint(x: original.x + 10, y: original.y - 12)),
                  "two-finger begin over the volume control did not move the panel")
        panel.sendEvent(event(-5, -7, phase: .changed))
        try check(near(panel.frame.origin, CGPoint(x: original.x + 5, y: original.y - 5)),
                  "two-dimensional hover movement had incorrect deltas")
        let beforeStationary = panel.frame
        panel.sendEvent(event(500, 500, phase: .stationary))
        try check(panel.frame == beforeStationary, "stationary packet moved the panel")
        panel.sendEvent(event(500, 500, phase: .ended, momentum: .began))
        let released = panel.frame
        panel.sendEvent(event(500, -500, phase: [], momentum: .changed))
        try check(!panel.isScrollDragging && panel.frame == released,
                  "inertial tail moved the panel after finger-up")
        try check(NSApp.keyWindow === previousKey && previousKey?.firstResponder === previousResponder && !panel.isKeyWindow,
                  "hover movement stole key-window or keyboard focus")
        panel.sendEvent(event(3, 4, phase: .began, momentum: .ended))
        try check(panel.isScrollDragging && near(panel.frame.origin, CGPoint(x: released.minX + 3, y: released.minY - 4)),
                  "a fresh physical begin was swallowed with the old inertial tail")
        panel.sendEvent(event(phase: .cancelled))
        try check(!panel.handleScrollMotion(event(0, -1, phase: [], precise: false)),
                  "ordinary mouse-wheel scrolling was treated as a two-finger drag")

        let closeCorner = CGRect(x: visible.minX + 25, y: visible.minY + 22, width: 320, height: 180)
        panel.setFrame(closeCorner, display: false)
        panel.finishPointerDrag(animated: false)
        try check(panel.frame.origin == CGPoint(x: visible.minX + 16, y: visible.minY + 16),
                  "native drag release did not use corner placement")
        panel.setFrame(closeCorner, display: false)
        panel.finishPointerDrag()
        try check(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? !panel.isPositionSnapRunning : panel.isPositionSnapRunning,
                  "snap animation did not respect Reduce Motion")
        let interrupted = panel.frame.origin
        panel.sendEvent(event(60, -50, phase: .began))
        let expected = CGPoint(x: interrupted.x + 60, y: interrupted.y + 50)
        spin(for: 0.24)
        try check(!panel.isPositionSnapRunning && near(panel.frame.origin, expected),
                  "a cancelled snap later overwrote the new gesture")
        panel.sendEvent(event(phase: .cancelled))
        try check(!panel.isScrollDragging && !panel.isPositionSnapRunning && near(panel.frame.origin, expected),
                  "gesture cancellation attracted free placement to a corner")

        panel.setFrame(closeCorner, display: false)
        panel.sendEvent(event(-2, 2, phase: []))
        try check(panel.isScrollDragging, "precise unphased input did not start a drag")
        spin(until: { !panel.isScrollDragging && !panel.isPositionSnapRunning }, timeout: 0.7)
        try check(!panel.isScrollDragging && !panel.isPositionSnapRunning
                    && near(panel.frame.origin, CGPoint(x: visible.minX + 16, y: visible.minY + 16)),
                  "precise unphased input did not finish and snap after a quiet period")
        let smallDisplay = CGRect(x: visible.minX, y: visible.minY, width: 200, height: 120)
        panel.positionScreenFrames = { [smallDisplay] }
        panel.setFrame(closeCorner, display: false)
        panel.finishPointerDrag(animated: false)
        try check(panel.frame.width <= 201 && panel.frame.height <= 121
                    && abs(panel.frame.width / panel.frame.height - 16.0 / 9.0) < 0.02,
                  "native minimum-size enforcement prevented fitting a smaller display: frame=\(panel.frame), minimum=\(panel.contentMinSize)")
        panel.positionScreenFrames = { [visible] }
        panel.setFrame(closeCorner, display: false)
        panel.finishPointerDrag()
        panel.close()
        let closedFrame = panel.frame
        spin(for: 0.24)
        try check(!panel.isPositionSnapRunning && !panel.isScrollDragging && panel.frame == closedFrame,
                  "closing the panel left a pending positioning update")
        return count
    }

    private static func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants(of: $0) }
    }
    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
    }
    private static func spin(for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { _ = RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.01))) }
    }
    private static func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}

private final class PositionScrollEvent: NSEvent {
    private weak var targetWindow: NSWindow?
    private let point: CGPoint
    private let x: CGFloat, y: CGFloat
    private let physicalPhase: NSEvent.Phase, inertialPhase: NSEvent.Phase
    private let precise: Bool, inverted: Bool
    private let time: TimeInterval
    init(window: NSWindow, point: CGPoint, x: CGFloat, y: CGFloat,
         phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, inverted: Bool, time: TimeInterval) {
        targetWindow = window; self.point = point; self.x = x; self.y = y
        physicalPhase = phase; inertialPhase = momentum; self.precise = precise; self.inverted = inverted; self.time = time
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Position fixture is not decoded") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: CGPoint { point }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { physicalPhase }
    override var momentumPhase: NSEvent.Phase { inertialPhase }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var timestamp: TimeInterval { time }
}
