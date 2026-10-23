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

    struct DiagnosticSnapshot {
        let axis: String
        let totalX: CGFloat
        let totalY: CGFloat
        let velocityX: CGFloat
    }
    var diagnostics: DiagnosticSnapshot {
        DiagnosticSnapshot(axis: String(describing: axis), totalX: accumulatedX,
                           totalY: accumulatedY, velocityX: velocityX)
    }

    private enum Axis { case idle, undecided, horizontal, vertical }
    private struct MotionSample { let time: TimeInterval; let position: CGFloat }
    private var axis = Axis.idle
    private var originSpace = 0
    private var pageWidth: CGFloat = 228
    private var accumulatedX: CGFloat = 0
    private var baseOffset: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var velocityX: CGFloat = 0
    private var motionSamples: [MotionSample] = []
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
            } else if vertical >= 12 && vertical >= horizontal * 1.25 {
                // A tiny vertical pickup is not a direction decision. Once
                // deliberate vertical travel is established, it remains locked.
                axis = .vertical
            }
            // An ambiguous diagonal stays unclaimed. Later horizontal intent can
            // still resolve it; a diagonal that never resolves scrolls normally.
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
        motionSamples.removeAll(keepingCapacity: true)
        suppressMomentum = false
    }

    private mutating func begin(space: Int, width: CGFloat, timestamp: TimeInterval) {
        reset()
        axis = .undecided
        originSpace = min(2, max(0, space))
        pageWidth = width.isFinite && width > 0 ? max(1, width) : 228
        previousTime = timestamp
        lastMovementTime = timestamp
        motionSamples = [MotionSample(time: timestamp, position: 0)]
    }

    private mutating func recordVelocity(deltaX: CGFloat, timestamp: TimeInterval) {
        let time = max(previousTime, timestamp)
        if deltaX != 0 {
            let sample = MotionSample(time: time, position: accumulatedX)
            if motionSamples.count > 1, motionSamples.last?.time == time {
                motionSamples[motionSamples.count - 1] = sample
            } else { motionSamples.append(sample) }
            // Keep the point before the window so its boundary can be interpolated.
            while motionSamples.count > 2 && motionSamples[1].time < time - 0.08 {
                motionSamples.removeFirst()
            }
            if motionSamples.count > 128 { motionSamples.removeFirst(motionSamples.count - 128) }
            velocityX = measuredVelocity()
            lastMovementTime = time
        }
        previousTime = time
    }

    private func measuredVelocity(releasedAt releaseTime: TimeInterval? = nil) -> CGFloat {
        guard motionSamples.count > 1, let latest = motionSamples.last else { return 0 }
        let lastIndex = motionSamples.count - 1
        let cutoff = latest.time - 0.08
        var startIndex = 0
        while startIndex + 1 < lastIndex && motionSamples[startIndex + 1].time <= cutoff { startIndex += 1 }

        // A substantial reversal should respond to its own direction promptly;
        // one-point release jitter must not replace the preceding motion window.
        let lastStep = latest.position - motionSamples[lastIndex - 1].position
        if lastStep != 0 {
            var turnIndex = lastIndex - 1
            while turnIndex > 0 {
                let step = motionSamples[turnIndex].position - motionSamples[turnIndex - 1].position
                if step * lastStep < 0 { break }
                turnIndex -= 1
            }
            if abs(latest.position - motionSamples[turnIndex].position) >= 6 {
                startIndex = max(startIndex, turnIndex)
            }
        }
        let start = motionSamples[startIndex]
        var startTime = start.time
        var startPosition = start.position
        if start.time < cutoff, startIndex < lastIndex {
            let next = motionSamples[startIndex + 1]
            if next.time > start.time {
                let fraction = CGFloat((cutoff - start.time) / (next.time - start.time))
                startTime = cutoff
                startPosition += (next.position - start.position) * fraction
            }
        }
        let elapsed = latest.time - startTime
        if elapsed > 0 {
            return (latest.position - startPosition) / CGFloat(max(elapsed, 1.0 / 240.0))
        }
        // A device can deliver all movement in its initial packet. Finger-up gives
        // that packet a measured duration; a held gesture is rejected as stale by
        // finish(), so this does not invent velocity after a pause.
        if let releaseTime, releaseTime > startTime {
            return (latest.position - startPosition) / CGFloat(max(releaseTime - startTime, 1.0 / 240.0))
        }
        return 0
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
        let speed = timestamp - lastMovementTime <= 0.12 ? measuredVelocity(releasedAt: timestamp) : 0
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
