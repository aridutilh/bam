import Foundation

/// Pure interaction logic for a two-finger horizontal sidebar swipe.
/// Thresholds, rubber-banding, and velocity filtering are prototype choices;
/// they are not claimed to be recovered Arc constants.
struct SpaceSwipeStateMachine {
    enum Phase { case mayBegin, began, changed, stationary, ended, cancelled, none }

    struct Result {
        var shouldConsume = false
        /// True only on the event that acquires horizontal ownership.
        var didLock = false
        /// Nil means the caller should leave its current visual state unchanged.
        var previewOffset: CGFloat?
        /// An adjacent space in 0...2. Nil on cancellation or insufficient travel.
        var committedSpace: Int?
        var finished = false
        /// Points per second in displayed coordinates, for the settling spring.
        var releaseVelocity: CGFloat = 0
    }

    private enum Axis { case idle, undecided, horizontal, vertical }
    private var axis = Axis.idle
    private var originSpace = 0
    private var pageWidth: CGFloat = 228
    private var accumulatedX: CGFloat = 0
    private var baseOffset: CGFloat = 0
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
        width: CGFloat,
        initialOffset: CGFloat = 0
    ) -> Result {
        // Momentum must never initiate or advance a page swipe. Once this gesture
        // has been claimed, keep consuming its tail so it cannot scroll other UI.
        if isMomentum && phase != .ended && phase != .cancelled {
            return Result(shouldConsume: suppressMomentum || axis == .horizontal)
        }
        // mayBegin is only a touch announcement. It must not reset a settling
        // page, acquire an axis, or discard suppression of the preceding tail.
        guard phase != .none && phase != .mayBegin else { return Result() }
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
        if phase == .ended && isMomentum {
            // Some devices attach the momentum announcement to the physical
            // finger-up event. Finish once, without adding momentum displacement.
            return finish(commitAllowed: true, timestamp: timestamp)
        }

        accumulatedX += deltaX
        accumulatedY += deltaY
        recordVelocity(deltaX: deltaX, timestamp: timestamp)
        var didLock = false
        if axis == .undecided {
            let horizontal = abs(accumulatedX)
            let vertical = abs(accumulatedY)
            if horizontal >= 6 && horizontal >= vertical * 1.25 {
                axis = .horizontal
                suppressMomentum = true
                didLock = true
                // The caller may still be animating while intent is undecided.
                // Sample its current displayed position only at ownership, then
                // keep this baseline fixed throughout the finger-driven drag.
                // The previous transition may have committed since finger-down.
                // Its current page/width, like its position, become authoritative.
                originSpace = min(2, max(0, space))
                pageWidth = width.isFinite && width > 0 ? max(1, width) : 228
                baseOffset = rawOffset(forDisplayedOffset: initialOffset.isFinite ? initialOffset : 0)
            } else if vertical >= 6 && vertical >= horizontal * 1.1 {
                axis = .vertical
            } else if max(horizontal, vertical) >= 12 {
                // Ambiguous diagonal movement belongs to ordinary scrolling.
                axis = .vertical
            }
        }
        if phase == .ended {
            return finish(commitAllowed: true, timestamp: timestamp, didLock: didLock)
        }
        guard axis == .horizontal else { return Result() }
        return Result(shouldConsume: true, didLock: didLock, previewOffset: displayedOffset)
    }

    mutating func reset() {
        axis = .idle
        accumulatedX = 0
        baseOffset = 0
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

    private var rawOffset: CGFloat { baseOffset + accumulatedX }

    private func isBlocked(_ offset: CGFloat) -> Bool {
        (offset > 0 && originSpace == 0) || (offset < 0 && originSpace == 2)
    }

    private func rawOffset(forDisplayedOffset offset: CGFloat) -> CGFloat {
        guard isBlocked(offset) else { return min(pageWidth, max(-pageWidth, offset)) }
        // Invert the rubber band so re-grabbing a boundary spring never jumps.
        let magnitude = min(abs(offset), pageWidth * 0.99)
        let raw = magnitude * pageWidth / (0.55 * (pageWidth - magnitude))
        return offset < 0 ? -raw : raw
    }

    private var displayedOffset: CGFloat {
        let raw = rawOffset
        if isBlocked(raw) {
            // A continuous, diminishing displacement that never reaches one page.
            let magnitude = pageWidth * (1 - 1 / (1 + abs(raw) * 0.55 / pageWidth))
            return raw < 0 ? -magnitude : magnitude
        }
        return min(pageWidth, max(-pageWidth, raw))
    }

    private mutating func finish(commitAllowed: Bool, timestamp: TimeInterval, didLock: Bool = false) -> Result {
        guard axis == .horizontal else {
            reset()
            return Result()
        }
        let offset = displayedOffset
        let raw = rawOffset
        let distanceThreshold = max(48, min(100, pageWidth * 0.24))
        let speed = timestamp - lastMovementTime <= 0.12 ? velocityX : 0
        let matchingDirection = (speed < 0) == (raw < 0)
        // A deliberate reverse flick cancels a partly completed transition.
        let reversing = abs(speed) >= 650 && !matchingDirection
        let enoughDistance = abs(raw) >= distanceThreshold && !reversing
        let fastFlick = abs(accumulatedX) >= 12 && abs(speed) >= 650 && matchingDirection
        let direction = raw > 0 ? -1 : 1
        let candidate = originSpace + direction
        let target = commitAllowed && (enoughDistance || fastFlick) && (0...2).contains(candidate)
            ? candidate : nil
        var releaseSpeed = min(2400, max(-2400, speed))
        if isBlocked(raw) {
            let denominator: CGFloat = 1 + abs(raw) * 0.55 / pageWidth
            releaseSpeed *= 0.55 / (denominator * denominator)
        } else if abs(raw) >= pageWidth && matchingDirection {
            releaseSpeed = 0
        }
        reset()
        suppressMomentum = true
        return Result(shouldConsume: true, didLock: didLock, previewOffset: offset,
                      committedSpace: target, finished: true,
                      releaseVelocity: commitAllowed ? releaseSpeed : 0)
    }
}
