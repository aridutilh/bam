import AppKit
import QuartzCore

/// Sidebar dimensions and standard unit-mass spring conversions.
/// The historical file/type names refer to local behavioral research. This file
/// contains independently written Swift, not extracted code, geometry, or artwork.
/// Numeric sidebar parameters were informed by those measurements.
enum RecoveredMetrics {
    static let preferredWidth: CGFloat = 228
    static let minWidth: CGFloat = 164
    static let maxWidth: CGFloat = 500
    static let collapseThreshold: CGFloat = 82

    static func stiffness(response: Double) -> Double {
        let response = max(abs(response), 0.0001)
        return pow(2 * .pi / response, 2)
    }

    static func damping(response: Double, ratio: Double) -> Double {
        let response = max(abs(response), 0.0001)
        return 4 * .pi * ratio / response
    }
}

/// Visible UI animations follow the display's refresh cadence. A quiet-display
/// fallback finishes state changes if their window is hidden or minimized.
private final class AnimationFrameClock: NSObject {
    private var displayLink: CADisplayLink?
    private var timer: Timer?
    private var update: (() -> Void)?
    private var lastDisplayFrame: CFTimeInterval = 0

    func start(view: NSView?, update: @escaping () -> Void) {
        stop()
        self.update = update
        if let view, view.window?.screen != nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            displayLink = link
            lastDisplayFrame = CACurrentMediaTime()
            link.add(to: .main, forMode: .common)
            let watchdog = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self, CACurrentMediaTime() - self.lastDisplayFrame > 0.10 else { return }
                self.update?()
            }
            timer = watchdog
            RunLoop.main.add(watchdog, forMode: .common)
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.update?() }
            timer.tolerance = 0.001
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        lastDisplayFrame = CACurrentMediaTime(); update?()
    }
    func stop() {
        displayLink?.invalidate(); displayLink = nil
        timer?.invalidate(); timer = nil
        update = nil
    }
    deinit { displayLink?.invalidate(); timer?.invalidate() }
}

/// A small analytical spring driver, evaluated against monotonic elapsed time.
/// The measured collection-layout pairs are (response: 0.55, ratio: 0.94)
/// and (response: 0.30, ratio: 0.99). They are response parameters, not durations.
/// Bam chooses the latter pair for space paging; its original symbol animations
/// use their own parameters. Sidebar presentation uses the cubic driver below.
final class SpringAnimator {
    weak var animationView: NSView?
    private let frameClock = AnimationFrameClock()
    private var generation: UInt = 0
    private var startTime: CFTimeInterval = 0
    private var startValue: CGFloat = 0
    private var targetValue: CGFloat = 0
    private var initialSpeed: Double = 0
    private(set) var value: CGFloat = 0
    /// Velocity in points per second, with the same sign as the animated value.
    private(set) var velocity: CGFloat = 0
    var isRunning: Bool { updateValue != nil }
    private var frequency: Double = 1
    private var ratio: Double = 1
    private var timeLimit: Double = 2
    private var updateValue: ((CGFloat) -> Void)?
    private var didComplete: (() -> Void)?

    func animate(
        from: CGFloat,
        to: CGFloat,
        response: Double,
        dampingRatio: Double,
        initialVelocity: CGFloat? = nil,
        update: @escaping (CGFloat) -> Void,
        completion: (() -> Void)? = nil
    ) {
        precondition(Thread.isMainThread, "SpringAnimator must run on the main thread")
        // Retargeting carries momentum unless the caller explicitly supplies a
        // velocity (including zero). stop() intentionally discards that momentum.
        // `from` stays authoritative, so a caller can preserve its displayed value.
        let inheritedVelocity = initialVelocity ?? (isRunning ? velocity : 0)
        stop()
        let token = generation
        guard from.isFinite, to.isFinite, response.isFinite, dampingRatio.isFinite,
              inheritedVelocity.isFinite else {
            value = to.isFinite ? to : 0
            update(value)
            if generation == token { completion?() }
            return
        }
        guard from != to || inheritedVelocity != 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, response > 0 else {
            value = to
            update(to)
            if generation == token { completion?() }
            return
        }

        startValue = from
        targetValue = to
        initialSpeed = Double(inheritedVelocity)
        value = from
        velocity = inheritedVelocity
        frequency = sqrt(RecoveredMetrics.stiffness(response: response))
        ratio = max(0, dampingRatio)
        timeLimit = max(2, response * 12)
        startTime = CACurrentMediaTime()
        updateValue = update
        didComplete = completion
        update(from)
        guard generation == token else { return }
        frameClock.start(view: animationView) { [weak self] in self?.tick() }
    }

    func stop() {
        generation &+= 1
        frameClock.stop()
        updateValue = nil
        didComplete = nil
        velocity = 0
    }

    private func tick() {
        let token = generation
        let elapsed = CACurrentMediaTime() - startTime
        let (displacement, speed) = springState(at: elapsed)
        let settled = abs(displacement) < 0.05 && abs(speed) < 0.5
        if settled || elapsed >= timeLimit || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let update = updateValue
            let completion = didComplete
            frameClock.stop()
            updateValue = nil
            didComplete = nil
            value = targetValue
            velocity = 0
            update?(targetValue)
            if generation == token { completion?() }
        } else {
            value = targetValue + CGFloat(displacement)
            velocity = CGFloat(speed)
            updateValue?(value)
        }
    }

    // Solves x'' + 2ζωx' + ω²x = 0 with an arbitrary displacement and velocity.
    // Elapsed-time evaluation avoids accumulating numerical error after delayed frames.
    private func springState(at time: Double) -> (Double, Double) {
        let omega = frequency
        let displacement = Double(startValue - targetValue)
        let speed = initialSpeed
        if abs(ratio - 1) < 0.00001 {
            let decay = exp(-omega * time)
            let coefficient = speed + omega * displacement
            return (decay * (displacement + coefficient * time),
                    decay * (speed - omega * coefficient * time))
        }
        if ratio < 1 {
            let decayRate = ratio * omega
            let damped = omega * sqrt(1 - ratio * ratio)
            let decay = exp(-decayRate * time)
            let sine = sin(damped * time)
            let cosine = cos(damped * time)
            let position = decay * (displacement * cosine + (speed + decayRate * displacement) / damped * sine)
            let velocity = decay * (speed * cosine - (decayRate * speed + omega * omega * displacement) / damped * sine)
            return (position, velocity)
        }
        let root = sqrt(ratio * ratio - 1)
        // The reciprocal form avoids subtracting nearly equal values for large ζ.
        let slow = -omega / (ratio + root)
        let fast = -omega * (ratio + root)
        let denominator = slow - fast
        let slowWeight = (speed - fast * displacement) / denominator
        let fastWeight = (slow * displacement - speed) / denominator
        let slowTerm = slowWeight * exp(slow * time)
        let fastTerm = fastWeight * exp(fast * time)
        return (slowTerm + fastTerm, slow * slowTerm + fast * fastTerm)
    }

    deinit { frameClock.stop() }
}

/// Independently implemented fixed-duration cubic easing.
/// The sidebar's default timing parameters were informed by local measurements.
/// The hidden-to-anchored path uses 0.08 seconds and (0.25, 0.46, 0.45, 0.94).
/// This driver intentionally does not reuse the collection-layout spring settings.
final class CubicAnimator {
    weak var animationView: NSView?
    private let frameClock = AnimationFrameClock()
    private var generation: UInt = 0
    private var startTime: CFTimeInterval = 0
    private var duration: Double = 0.08
    private var startValue: CGFloat = 0
    private var targetValue: CGFloat = 0
    private var points = (0.25, 0.46, 0.45, 0.94)
    private var updateValue: ((CGFloat) -> Void)?
    private var didComplete: (() -> Void)?
    private(set) var value: CGFloat = 0
    var isRunning: Bool { updateValue != nil }

    func animate(from: CGFloat, to: CGFloat, duration: Double,
                 controlPoints: (Double, Double, Double, Double),
                 update: @escaping (CGFloat) -> Void, completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread, "CubicAnimator must run on the main thread")
        stop()
        let token = generation
        let validPoints = [controlPoints.0, controlPoints.1, controlPoints.2, controlPoints.3].allSatisfy(\.isFinite)
            && (0...1).contains(controlPoints.0) && (0...1).contains(controlPoints.2)
        guard from.isFinite, to.isFinite, duration.isFinite, duration > 0, from != to,
              validPoints, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            value = to.isFinite ? to : 0
            update(value)
            if generation == token { completion?() }
            return
        }
        startValue = from
        targetValue = to
        self.duration = duration
        points = controlPoints
        value = from
        updateValue = update
        didComplete = completion
        startTime = CACurrentMediaTime()
        update(from)
        guard generation == token else { return }
        frameClock.start(view: animationView) { [weak self] in self?.tick() }
    }

    func stop() {
        generation &+= 1
        frameClock.stop()
        updateValue = nil
        didComplete = nil
    }

    private func tick() {
        let token = generation
        let elapsed = max(0, CACurrentMediaTime() - startTime)
        if elapsed >= duration || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let update = updateValue
            let completion = didComplete
            frameClock.stop()
            updateValue = nil
            didComplete = nil
            value = targetValue
            update?(value)
            if generation == token { completion?() }
            return
        }
        let timeFraction = elapsed / duration
        // Cubic timing maps x to elapsed time: invert x before evaluating y.
        // Bisection is stable at flat tangents and adds negligible work at 120 Hz.
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let midpoint = (low + high) / 2
            if cubic(midpoint, points.0, points.2) < timeFraction { low = midpoint }
            else { high = midpoint }
        }
        let progress = cubic((low + high) / 2, points.1, points.3)
        value = startValue + (targetValue - startValue) * CGFloat(progress)
        updateValue?(value)
    }

    private func cubic(_ t: Double, _ first: Double, _ second: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first + 3 * inverse * t * t * second + t * t * t
    }

    deinit { frameClock.stop() }
}

/// Native AppKit resize handling and an originally drawn grip.
/// Numeric width thresholds, snap gates, haptic delay, and pulse timing were
/// informed by local measurements; drawing and event handling are Bam code.
final class ResizeHandleView: NSView {
    var onResize: ((CGFloat, Bool) -> Void)?
    var onCollapse: (() -> Void)?
    var currentWidth: CGFloat = RecoveredMetrics.preferredWidth {
        didSet { setAccessibilityValue("\(Int(currentWidth)) points") }
    }
    var onReset: (() -> Void)?

    private let indicator = CALayer()
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isDragging = false
    private var startingWidth: CGFloat = RecoveredMetrics.preferredWidth
    private var startingX: CGFloat = 0
    private var previousX: CGFloat = 0
    private var previousTime: TimeInterval = 0
    private var canSnap = false
    private var isSnapped = false
    private var snapTime: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        indicator.cornerRadius = 1.5
        indicator.opacity = 0
        layer?.addSublayer(indicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Sidebar width")
        updateColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            indicator.backgroundColor = NSColor.labelColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        let height = min(32, max(0, bounds.height - 16))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = CGRect(x: bounds.midX - 1.5, y: bounds.midY - height / 2, width: 3, height: height)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshIndicator()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshIndicator()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            currentWidth = RecoveredMetrics.preferredWidth
            onReset?()
            return
        }
        isDragging = true
        startingWidth = currentWidth
        startingX = event.locationInWindow.x
        previousX = startingX
        previousTime = event.timestamp
        canSnap = false
        isSnapped = false
        refreshIndicator()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let x = event.locationInWindow.x
        let interval = event.timestamp - previousTime
        let velocity = interval > 0 ? Double(x - previousX) / interval : 0
        previousX = x
        previousTime = event.timestamp
        let raw = roundedWidth(at: x)
        var width = liveWidth(raw)
        let distanceToPreferred = RecoveredMetrics.preferredWidth - width
        let inSnapBand = abs(distanceToPreferred) < 14

        if !inSnapBand {
            canSnap = true
            leaveSnap(at: event.timestamp)
        } else if isSnapped {
            width = RecoveredMetrics.preferredWidth
        } else if canSnap, abs(velocity) < 50,
                  (velocity < 0) != (distanceToPreferred < 0) {
            isSnapped = true
            snapTime = event.timestamp
            width = RecoveredMetrics.preferredWidth
            alignmentFeedback()
            pulseIndicator()
        }

        currentWidth = width
        setAccessibilityValue("\(Int(width)) points")
        refreshIndicator()
        onResize?(width, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let raw = roundedWidth(at: event.locationInWindow.x)
        let shouldCollapse = raw <= RecoveredMetrics.collapseThreshold
        let width: CGFloat
        if shouldCollapse {
            width = 0
        } else if isSnapped, abs(raw - RecoveredMetrics.preferredWidth) < 14 {
            width = RecoveredMetrics.preferredWidth
        } else {
            width = min(RecoveredMetrics.maxWidth, max(RecoveredMetrics.minWidth, raw))
        }
        isSnapped = false
        currentWidth = width
        setAccessibilityValue("\(Int(width)) points")
        refreshIndicator()
        onResize?(width, true)
        if shouldCollapse { onCollapse?() }
    }

    private func roundedWidth(at windowX: CGFloat) -> CGFloat {
        // ARM64 FRINTA: nearest integer, with half-way values away from zero.
        (startingWidth + windowX - startingX).rounded(.toNearestOrAwayFromZero)
    }

    private func liveWidth(_ raw: CGFloat) -> CGFloat {
        if raw < RecoveredMetrics.collapseThreshold { return 0 }
        return min(RecoveredMetrics.maxWidth, max(RecoveredMetrics.minWidth, raw))
    }

    private func leaveSnap(at time: TimeInterval) {
        guard isSnapped else { return }
        isSnapped = false
        if time - snapTime > 0.5 { alignmentFeedback() }
    }

    private func alignmentFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// True while the sidebar's scroll thumb, which shares this gap, is under the pointer or being dragged: the two
    /// bars would otherwise draw on top of each other.
    var isIndicatorSuppressed = false { didSet { if oldValue != isIndicatorSuppressed { refreshIndicator() } } }

    private func refreshIndicator() {
        let opacity: Float = !isIndicatorSuppressed && (isHovered || isDragging || isSnapped) ? 0.5 : 0
        guard indicator.opacity != opacity else { return }
        let previous = indicator.presentation()?.opacity ?? indicator.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.opacity = opacity
        CATransaction.commit()
        indicator.removeAnimation(forKey: "visibility")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = previous
        animation.toValue = opacity
        animation.duration = 0.2
        indicator.add(animation, forKey: "visibility")
    }

    private func pulseIndicator() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = 1.0
        animation.toValue = 1.7
        animation.duration = 0.08
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
        indicator.add(animation, forKey: "snap")
    }
}
