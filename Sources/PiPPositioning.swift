import Foundation

/// Independent window-placement geometry. Screens are AppKit global visible
/// frames (including negative coordinates), not full frames behind the Dock.
enum PiPPositioning {
    static let cornerInset: CGFloat = 8
    static let magneticRadius: CGFloat = 240
    // Original Bam tuning, guided by the reference's long decelerating sweeps.
    // These are not recovered Arc constants.
    static let minimumFlickSpeed: CGFloat = 450
    static let projectionTime: CGFloat = 0.24
    static let maximumFlickSpeed: CGFloat = 6000
    static let directionalAxisFraction: CGFloat = 0.35

    struct ReleasePlan {
        let frame: CGRect
        let duration: TimeInterval
        let isFlick: Bool
    }

    static func releasePlan(_ frame: CGRect, velocity: CGPoint, screens: [CGRect]) -> ReleasePlan {
        guard valid(frame), destinationScreen(for: frame, screens: screens) != nil else {
            return ReleasePlan(frame: frame, duration: 0.22, isFlick: false)
        }
        let velocity = boundedVelocity(velocity)
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= minimumFlickSpeed else {
            return ReleasePlan(frame: releaseFrame(frame, screens: screens), duration: 0.22, isFlick: false)
        }
        let projected = frame.offsetBy(dx: velocity.x * projectionTime, dy: velocity.y * projectionTime)
        let target = directionalCorner(projected, velocity: velocity, speed: speed, screens: screens)
        let travel = hypot(target.minX - frame.minX, target.minY - frame.minY)
        let duration = 0.35 + 0.20 * Double(min(1, travel / 800))
        return ReleasePlan(frame: target, duration: duration, isFlick: true)
    }

    private static func directionalCorner(_ projected: CGRect, velocity: CGPoint, speed: CGFloat,
                                          screens: [CGRect]) -> CGRect {
        guard let screen = destinationScreen(for: projected, screens: screens) else { return projected }
        let fitted = fit(projected, inside: screen)
        guard fitted.width + 2 * cornerInset <= screen.width,
              fitted.height + 2 * cornerInset <= screen.height else { return fitted }
        let left = screen.minX + cornerInset, right = screen.maxX - fitted.width - cornerInset
        let bottom = screen.minY + cornerInset, top = screen.maxY - fitted.height - cornerInset
        // A deliberate flick commits to its direction, even if its short
        // projection is still nearer the opposite corner. Small orthogonal
        // motion chooses the nearest edge instead of changing that intention.
        let rightward = abs(velocity.x) >= directionalAxisFraction * speed
            ? velocity.x > 0 : abs(projected.minX - right) < abs(projected.minX - left)
        let upward = abs(velocity.y) >= directionalAxisFraction * speed
            ? velocity.y > 0 : abs(projected.minY - top) < abs(projected.minY - bottom)
        return CGRect(x: rightward ? right : left, y: upward ? top : bottom,
                      width: fitted.width, height: fitted.height)
    }

    static func boundedVelocity(_ velocity: CGPoint) -> CGPoint {
        guard velocity.x.isFinite, velocity.y.isFinite else { return .zero }
        let speed = hypot(velocity.x, velocity.y)
        guard speed > maximumFlickSpeed else { return velocity }
        let scale = maximumFlickSpeed / speed
        return CGPoint(x: velocity.x * scale, y: velocity.y * scale)
    }

    static func fingerDelta(x: CGFloat, y: CGFloat, invertedFromDevice: Bool) -> CGPoint {
        // Normalize the scrolling preference, then convert scroll Y into
        // AppKit's upward-positive global window coordinates. A natural upward
        // scroll has negative deltaY; following those fingers moves the panel up.
        let direction: CGFloat = invertedFromDevice ? 1 : -1
        return CGPoint(x: x.isFinite ? x * direction : 0, y: y.isFinite ? -y * direction : 0)
    }

    static func dragFrame(_ frame: CGRect, delta: CGPoint, screens: [CGRect]) -> CGRect {
        guard valid(frame), delta.x.isFinite, delta.y.isFinite else { return frame }
        let moved = frame.offsetBy(dx: delta.x, dy: delta.y)
        let usable = screens.filter(valid)
        guard let first = usable.first else { return moved }
        // Constrain only the outside of the display arrangement while fingers
        // are down. Clamping to one screen here prevents crossing its boundary.
        let desktop = usable.dropFirst().reduce(first) { $0.union($1) }
        return fit(moved, inside: desktop, resizeToFit: false)
    }

    static func releaseFrame(_ frame: CGRect, screens: [CGRect], magnet: Bool = true) -> CGRect {
        guard valid(frame), let screen = destinationScreen(for: frame, screens: screens) else { return frame }
        let fitted = fit(frame, inside: screen)
        guard magnet, fitted.width + 2 * cornerInset <= screen.width,
              fitted.height + 2 * cornerInset <= screen.height else { return fitted }
        let left = screen.minX + cornerInset, right = screen.maxX - fitted.width - cornerInset
        let bottom = screen.minY + cornerInset, top = screen.maxY - fitted.height - cornerInset
        let corners = [CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom),
                       CGPoint(x: left, y: top), CGPoint(x: right, y: top)]
        let closest = corners.min { distanceSquared($0, fitted.origin) < distanceSquared($1, fitted.origin) }!
        guard distanceSquared(closest, fitted.origin) <= magneticRadius * magneticRadius else { return fitted }
        return CGRect(origin: closest, size: fitted.size)
    }

    static func destinationScreen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        let usable = screens.filter(valid)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return usable.min { lhs, rhs in
            let leftArea = overlap(frame, lhs), rightArea = overlap(frame, rhs)
            if abs(leftArea - rightArea) > 0.001 { return leftArea > rightArea }
            return distanceSquared(center, nearestPoint(center, in: lhs)) < distanceSquared(center, nearestPoint(center, in: rhs))
        }
    }

    private static func fit(_ frame: CGRect, inside bounds: CGRect, resizeToFit: Bool = true) -> CGRect {
        // Moving onto a smaller display must not strand controls offscreen.
        // Shrink only when necessary, preserving the video's aspect ratio.
        let scale = resizeToFit ? min(1, min(bounds.width / frame.width, bounds.height / frame.height)) : 1
        let width = frame.width * scale, height = frame.height * scale
        return CGRect(x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - width)),
                      y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - height)),
                      width: width, height: height)
    }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    private static func nearestPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

/// Tracks only physical packets, never OS momentum. Position samples make the
/// estimate independent of packet frequency; equal timestamps are coalesced.
struct PiPPhysicalVelocity {
    private struct Sample { let time: TimeInterval; let position: CGPoint }
    private var samples: [Sample] = []
    private var position = CGPoint.zero
    private var lastDirection = CGPoint.zero
    private var lastMotionTime: TimeInterval?
    private static let window: TimeInterval = 0.08
    private static let stale: TimeInterval = 0.12

    mutating func reset() { self = Self() }

    mutating func begin(at time: TimeInterval) {
        reset()
        guard time.isFinite else { return }
        samples = [Sample(time: time, position: .zero)]
    }

    mutating func pause(at time: TimeInterval) {
        // Stationary fingers must not launch an earlier fast movement.
        begin(at: time)
    }

    mutating func record(_ delta: CGPoint, at time: TimeInterval) {
        guard time.isFinite, delta.x.isFinite, delta.y.isFinite else { reset(); return }
        guard let previous = samples.last else { begin(at: time); return }
        guard time >= previous.time else { begin(at: time); return }
        if delta.x * lastDirection.x + delta.y * lastDirection.y < 0 {
            // Even a small intentional reversal cancels the old launch. The new
            // direction must build its own velocity instead of averaging with it.
            samples = [previous]
        }
        position.x += delta.x; position.y += delta.y
        if delta.x != 0 || delta.y != 0 {
            lastDirection = delta; lastMotionTime = time
        }
        let sample = Sample(time: time, position: position)
        if time == samples.last?.time { samples[samples.count - 1] = sample }
        else { samples.append(sample) }
        while samples.count > 2 && samples[1].time < time - Self.window { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }

    func velocity(at time: TimeInterval) -> CGPoint {
        guard time.isFinite, let last = samples.last, let motionTime = lastMotionTime,
              time >= last.time, time - motionTime <= Self.stale, samples.count >= 2 else { return .zero }
        let startTime = max(samples[0].time, time - Self.window)
        let duration = time - startTime
        guard duration >= 1.0 / 240, startTime < last.time else { return .zero }
        var start = samples[0].position
        for index in 1..<samples.count {
            let before = samples[index - 1], after = samples[index]
            if startTime <= after.time {
                let fraction = CGFloat((startTime - before.time) / (after.time - before.time))
                start = CGPoint(x: before.position.x + (after.position.x - before.position.x) * fraction,
                                y: before.position.y + (after.position.y - before.position.y) * fraction)
                break
            }
        }
        // Including the quiet interval between the final packet and finger-up
        // naturally decays the estimate, reaching zero after the sample window.
        return PiPPositioning.boundedVelocity(CGPoint(x: (position.x - start.x) / duration,
                                                      y: (position.y - start.y) / duration))
    }
}
