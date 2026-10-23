import Foundation

/// Pure interaction logic for a two-finger horizontal sidebar swipe.
/// Thresholds, rubber-banding, and velocity filtering are prototype choices;
/// they are not claimed to be recovered Arc constants.
struct SpaceSwipeStateMachine {
    enum Phase { case began, changed, ended, cancelled, none }

    struct Result {
        var shouldConsume = false
        /// Nil means the caller should leave its current visual state unchanged.
        var previewOffset: CGFloat?
        /// An adjacent space in 0...2. Nil on cancellation or insufficient travel.
        var committedSpace: Int?
        var finished = false
    }

    private enum Axis { case idle, undecided, horizontal, vertical }
    private var axis = Axis.idle
    private var originSpace = 0
    private var pageWidth: CGFloat = 228
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var velocityX: CGFloat = 0
    private var hasVelocity = false
    private var previousTime: TimeInterval = 0
    private var lastMovementTime: TimeInterval = 0
    private var suppressMomentum = false

    /// Positive scrollingDeltaX moves content right and selects the previous space.
    /// Negative scrollingDeltaX moves content left and selects the next space.
    /// Feed physical scroll phase separately from whether momentumPhase is nonempty.
    mutating func handle(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: Phase,
        isMomentum: Bool,
        timestamp: TimeInterval,
        space: Int,
        width: CGFloat
    ) -> Result {
        // Momentum must never initiate or advance a page swipe. Once this gesture
        // has been claimed, keep consuming its tail so it cannot scroll other UI.
        if isMomentum {
            return Result(shouldConsume: suppressMomentum || axis == .horizontal)
        }
        guard phase != .none else { return Result() }
        guard deltaX.isFinite, deltaY.isFinite, timestamp.isFinite else {
            return finish(commitAllowed: false, timestamp: previousTime)
        }
        if phase == .began || (axis == .idle && phase == .changed) {
            begin(space: space, width: width, timestamp: timestamp)
        }
        guard axis != .idle else { return Result() }
        if phase == .cancelled {
            return finish(commitAllowed: false, timestamp: timestamp)
        }

        accumulatedX += deltaX
        accumulatedY += deltaY
        recordVelocity(deltaX: deltaX, timestamp: timestamp)
        if axis == .undecided {
            let horizontal = abs(accumulatedX)
            let vertical = abs(accumulatedY)
            if horizontal >= 6 && horizontal >= vertical * 1.25 {
                axis = .horizontal
                suppressMomentum = true
            } else if vertical >= 6 && vertical >= horizontal * 1.1 {
                axis = .vertical
            } else if max(horizontal, vertical) >= 12 {
                // Ambiguous diagonal movement belongs to ordinary scrolling.
                axis = .vertical
            }
        }
        if phase == .ended {
            return finish(commitAllowed: true, timestamp: timestamp)
        }
        guard axis == .horizontal else { return Result() }
        return Result(shouldConsume: true, previewOffset: displayedOffset)
    }

    mutating func reset() {
        axis = .idle
        accumulatedX = 0
        accumulatedY = 0
        velocityX = 0
        hasVelocity = false
        suppressMomentum = false
    }

    private mutating func begin(space: Int, width: CGFloat, timestamp: TimeInterval) {
        reset()
        axis = .undecided
        originSpace = min(2, max(0, space))
        pageWidth = width.isFinite && width > 0 ? max(1, width) : 228
        previousTime = timestamp
        lastMovementTime = timestamp
    }

    private mutating func recordVelocity(deltaX: CGFloat, timestamp: TimeInterval) {
        let elapsed = timestamp - previousTime
        if deltaX != 0 {
            if elapsed > 0 && elapsed <= 0.1 {
                let instantaneous = deltaX / CGFloat(max(elapsed, 1.0 / 240.0))
                velocityX = hasVelocity ? velocityX * 0.65 + instantaneous * 0.35 : instantaneous
                hasVelocity = true
            } else if elapsed > 0.1 {
                velocityX = 0
                hasVelocity = false
            }
            lastMovementTime = max(lastMovementTime, timestamp)
        }
        previousTime = max(previousTime, timestamp)
    }

    private var displayedOffset: CGFloat {
        let blocked = (accumulatedX > 0 && originSpace == 0)
            || (accumulatedX < 0 && originSpace == 2)
        if blocked {
            // A continuous, diminishing displacement that never reaches one page.
            let magnitude = pageWidth * (1 - 1 / (1 + abs(accumulatedX) * 0.55 / pageWidth))
            return accumulatedX < 0 ? -magnitude : magnitude
        }
        return min(pageWidth, max(-pageWidth, accumulatedX))
    }

    private mutating func finish(commitAllowed: Bool, timestamp: TimeInterval) -> Result {
        guard axis == .horizontal else {
            reset()
            return Result()
        }
        let offset = displayedOffset
        let distanceThreshold = max(48, min(100, pageWidth * 0.24))
        let speed = timestamp - lastMovementTime <= 0.12 ? velocityX : 0
        let matchingDirection = (speed < 0) == (accumulatedX < 0)
        let enoughDistance = abs(accumulatedX) >= distanceThreshold
        let fastFlick = abs(accumulatedX) >= 12 && abs(speed) >= 650 && matchingDirection
        let direction = accumulatedX > 0 ? -1 : 1
        let candidate = originSpace + direction
        let target = commitAllowed && (enoughDistance || fastFlick) && (0...2).contains(candidate)
            ? candidate : nil
        reset()
        suppressMomentum = true
        return Result(shouldConsume: true, previewOffset: offset, committedSpace: target, finished: true)
    }
}
