import AppKit

/// Standalone smoke checks. Compile with RecoveredMotion.swift only; the separate
/// Tests/main.swift executable tests browser state. These checks never create a
/// window, synthesize events, or change accessibility preferences.
@main
struct MotionTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        do {
            try check(Thread.isMainThread, "Motion tests must run on the main thread")
            try numericConversions()
            try cubicEndpointAndReplacement()
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            try reachesEndpoint(response: 0.55, ratio: 0.94, reduceMotion: reduceMotion)
            try reachesEndpoint(response: 0.30, ratio: 0.99, reduceMotion: reduceMotion)
            try reachesEndpoint(response: 0.24, ratio: 0.90, reduceMotion: reduceMotion)
            try reachesEndpoint(response: 0.36, ratio: 0.62, reduceMotion: reduceMotion)
            try reachesEndpoint(response: 0.12, ratio: 1, reduceMotion: reduceMotion)
            try reachesEndpoint(response: 0.12, ratio: 1.6, reduceMotion: reduceMotion)
            try stopDuringUpdateSuppressesCompletion(reduceMotion: reduceMotion)
            try replacementCompletesOnlyNewAnimation(reduceMotion: reduceMotion)
            if !reduceMotion {
                try retargetPreservesVelocity()
                for ratio in [0.62, 0.7, 1.0, 1.6] { try seededVelocityReturnsToSameEndpoint(ratio: ratio) }
            }
            print("PASS: motion math, endpoints, cancellation, replacement, and velocity handling")
            if reduceMotion {
                print("Reduce Motion is enabled: immediate endpoint and reentrant cancellation/replacement paths checked; timed interpolation was not exercised.")
            } else {
                print("Timed interpolation checked for the sidebar and original symbol spring profiles, critical damping, and overdamping.")
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try check(actual.isFinite && abs(actual - expected) <= max(1, abs(expected)) * 1e-12,
                  "\(message): expected \(expected), got \(actual)")
    }

    private static func numericConversions() throws {
        // Independently evaluated unit-mass equations for the configured sidebar parameter pairs.
        try near(RecoveredMetrics.stiffness(response: 0.55), 130.5071656342394, "0.55-second stiffness")
        try near(RecoveredMetrics.damping(response: 0.55, ratio: 0.94), 21.4770697772684, "0.55/0.94 damping")
        try near(RecoveredMetrics.stiffness(response: 0.30), 438.6490844928604, "0.30-second stiffness")
        try near(RecoveredMetrics.damping(response: 0.30, ratio: 0.99), 41.469023027385276, "0.30/0.99 damping")
        try near(RecoveredMetrics.stiffness(response: 0), RecoveredMetrics.stiffness(response: 0.0001), "Zero-response floor")
        try near(RecoveredMetrics.damping(response: 0, ratio: 1), RecoveredMetrics.damping(response: 0.0001, ratio: 1), "Zero-response damping floor")
    }

    private static func reachesEndpoint(response: Double, ratio: Double, reduceMotion: Bool) throws {
        let animator = SpringAnimator()
        defer { animator.stop() }
        var samples: [CGFloat] = []
        var completionCount = 0
        animator.animate(from: 0, to: 228, response: response, dampingRatio: ratio,
                         update: { samples.append($0) },
                         completion: { completionCount += 1 })
        try check(wait(timeout: max(1.5, response * 4), until: { completionCount > 0 }),
                  "Spring \(response)/\(ratio) failed to complete within its smoke-test deadline")
        let countAtCompletion = samples.count
        runLoop(for: 0.04)
        try check(completionCount == 1, "Spring completion must fire exactly once")
        try check(samples.allSatisfy(\.isFinite), "Spring emitted a nonfinite value")
        try check(samples.last == 228, "Spring must finish at the exact target")
        try check(samples.count == countAtCompletion, "Completed spring continued emitting updates")
        if reduceMotion {
            try check(samples == [228], "Reduce Motion should deliver the target immediately")
        } else {
            try check(samples.first == 0, "Animated spring should begin at its supplied start")
            try check(samples.contains(where: { $0 > 0 && $0 < 228 }), "Spring emitted no intermediate value")
        }
    }

    private static func stopDuringUpdateSuppressesCompletion(reduceMotion: Bool) throws {
        let animator = SpringAnimator()
        defer { animator.stop() }
        var updates = 0
        var stopped = false
        var completions = 0
        animator.animate(from: 0, to: 500, response: 0.6, dampingRatio: 0.94, update: { _ in
            updates += 1
            // With motion enabled, stop from an actual timer callback. With the
            // user's Reduce Motion preference, stop from the immediate update.
            if reduceMotion || updates >= 2 {
                stopped = true
                animator.stop()
            }
        }, completion: { completions += 1 })
        try check(wait(timeout: 1, until: { stopped }), "Cancellation test never received an update")
        let stoppedUpdateCount = updates
        runLoop(for: 0.15)
        try check(completions == 0, "stop() must suppress the cancelled completion")
        try check(updates == stoppedUpdateCount, "stop() must suppress further updates")
    }

    private static func replacementCompletesOnlyNewAnimation(reduceMotion: Bool) throws {
        let animator = SpringAnimator()
        defer { animator.stop() }
        var oldUpdates = 0
        var oldCompletions = 0
        var replacementStarted = false
        var newCompletions = 0
        var replacementValues: [CGFloat] = []
        animator.animate(from: 0, to: 500, response: 0.6, dampingRatio: 0.94, update: { value in
            oldUpdates += 1
            if !replacementStarted && (reduceMotion || oldUpdates >= 2) {
                replacementStarted = true
                animator.animate(from: value, to: 120, response: 0.08, dampingRatio: 0.99,
                                 update: { replacementValues.append($0) },
                                 completion: { newCompletions += 1 })
            }
        }, completion: { oldCompletions += 1 })
        try check(wait(timeout: 1.5, until: { newCompletions > 0 }), "Replacement animation did not complete")
        let finalOldUpdates = oldUpdates
        let finalNewUpdates = replacementValues.count
        runLoop(for: 0.15)
        try check(replacementStarted, "Replacement was never started")
        try check(oldCompletions == 0, "Replaced animation incorrectly completed")
        try check(newCompletions == 1, "Replacement must complete exactly once")
        try check(replacementValues.last == 120, "Replacement missed its exact endpoint")
        try check(replacementValues.allSatisfy(\.isFinite), "Replacement emitted a nonfinite value")
        try check(oldUpdates == finalOldUpdates && replacementValues.count == finalNewUpdates,
                  "An animation continued emitting after replacement completed")
    }

    private static func cubicEndpointAndReplacement() throws {
        let animator = CubicAnimator()
        defer { animator.stop() }
        var firstCompletions = 0
        var values: [CGFloat] = []
        animator.animate(from: 0, to: 228, duration: 0.08, controlPoints: (0.25, 0.46, 0.45, 0.94),
                         update: { values.append($0) }, completion: { firstCompletions += 1 })
        try check(wait(timeout: 0.5, until: { firstCompletions > 0 }), "Cubic animation did not complete")
        try check(firstCompletions == 1 && values.last == 228, "Cubic animation missed its endpoint")
        try check(values.allSatisfy(\.isFinite), "Cubic animation emitted a nonfinite value")
        var obsoleteCompletions = 0
        var replacementCompletions = 0
        var didReplace = false
        animator.animate(from: 228, to: 0, duration: 0.08, controlPoints: (0.25, 0.46, 0.45, 0.94),
                         update: { value in
            guard !didReplace else { return }
            didReplace = true
            animator.animate(from: value, to: 77, duration: 0.04, controlPoints: (0.25, 0.46, 0.45, 0.94),
                             update: { _ in }, completion: { replacementCompletions += 1 })
        }, completion: { obsoleteCompletions += 1 })
        try check(wait(timeout: 0.5, until: { replacementCompletions > 0 }), "Cubic replacement failed to finish")
        runLoop(for: 0.03)
        try check(obsoleteCompletions == 0 && replacementCompletions == 1 && animator.value == 77,
                  "Cubic replacement fired an obsolete completion or missed its target")
    }

    private static func retargetPreservesVelocity() throws {
        let animator = SpringAnimator()
        defer { animator.stop() }
        var oldCompletions = 0
        var intermediateCompletions = 0
        var finalCompletions = 0
        animator.animate(from: 0, to: 500, response: 0.6, dampingRatio: 0.94,
                         update: { _ in }, completion: { oldCompletions += 1 })
        try check(wait(timeout: 1, until: { animator.value > 10 }), "Retarget test did not reach a moving state")
        let previousValue = animator.value
        let previousVelocity = animator.velocity
        try check(previousVelocity > 0, "Retarget test must begin with positive momentum")
        var replacementFirstValue: CGFloat?
        animator.animate(from: previousValue, to: -100, response: 0.3, dampingRatio: 0.99,
                         update: { if replacementFirstValue == nil { replacementFirstValue = $0 } },
                         completion: { intermediateCompletions += 1 })
        try check(replacementFirstValue == previousValue, "Retargeting jumped from the displayed value")
        try check(animator.velocity == previousVelocity, "Retargeting discarded the existing velocity")
        animator.animate(from: animator.value, to: 120, response: 0.08, dampingRatio: 0.99,
                         initialVelocity: 0, update: { _ in }, completion: { finalCompletions += 1 })
        try check(animator.velocity == 0, "An explicit zero velocity must override inherited momentum")
        try check(wait(timeout: 1.5, until: { finalCompletions == 1 }), "Explicit-velocity replacement did not finish")
        try check(animator.value == 120 && animator.velocity == 0, "Finished spring must have exact position and zero velocity")
        try check(oldCompletions == 0 && intermediateCompletions == 0, "Retargeted springs fired obsolete completions")
        animator.stop()
        try check(!animator.isRunning && animator.velocity == 0, "stop() must clear running state and momentum")
    }

    private static func seededVelocityReturnsToSameEndpoint(ratio: Double) throws {
        let animator = SpringAnimator()
        defer { animator.stop() }
        var samples: [CGFloat] = []
        var completions = 0
        animator.animate(from: 0, to: 0, response: 0.15, dampingRatio: ratio,
                         initialVelocity: 200, update: { samples.append($0) },
                         completion: { completions += 1 })
        try check(animator.isRunning && animator.velocity == 200,
                  "A nonzero initial velocity should animate even when start and target match")
        try check(wait(timeout: 1.5, until: { completions > 0 }), "Seeded spring did not settle")
        try check(samples.contains(where: { $0 > 0 }), "Seeded spring did not move in its initial velocity direction")
        try check(samples.allSatisfy(\.isFinite), "Seeded spring emitted a nonfinite value")
        try check(samples.last == 0 && completions == 1, "Seeded spring failed to return to its target")
    }

    @discardableResult
    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            // Avoid busy spinning if the run loop has no active source after stop().
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }

    private static func runLoop(for duration: TimeInterval) {
        _ = wait(timeout: duration, until: { false })
    }
}
