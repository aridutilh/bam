import Foundation

@main
struct SpaceSwipeTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do {
            try verticalMotionIsNotClaimed()
            try horizontalDistanceCommitsAdjacentSpace()
            try shortDragCancelsAndFastFlickCommits()
            try elasticBoundariesNeverCommit()
            try cancellationAndMomentumAreSuppressed()
            try axisLockPersistsAndUnphasedWheelsAreIgnored()
            try touchAnnouncementsAndStationaryPhases()
            try interruptedAnimationAcquiresCurrentPosition()
            try physicalEndOverlappingMomentumFinishes()
            try interruptedBoundaryPreservesRubberBand()
            try reverseFlickCancelsAndReportsVelocity()
            try changedPhaseCanStartWithoutBegan()
            try previousAnimationCanCommitBeforeAxisLocks()
            print("PASS: swipe intent/axis lock, live animation handoff, release velocity, distance/flick commits, boundaries, real trackpad phases, cancellation, and momentum")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func send(_ machine: inout SpaceSwipeStateMachine, _ x: CGFloat, _ y: CGFloat,
                             _ phase: SpaceSwipeStateMachine.Phase, _ time: TimeInterval,
                             space: Int = 1, momentum: Bool = false, initialOffset: CGFloat = 0) -> SpaceSwipeStateMachine.Result {
        machine.handle(deltaX: x, deltaY: y, phase: phase, isMomentum: momentum,
                       timestamp: time, space: space, width: 228, initialOffset: initialOffset)
    }

    private static func send(_ machine: inout SpaceSwipeStateMachine,
                             _ phase: SpaceSwipeStateMachine.Phase, _ time: TimeInterval,
                             space: Int = 1, momentum: Bool = false) -> SpaceSwipeStateMachine.Result {
        send(&machine, 0, 0, phase, time, space: space, momentum: momentum)
    }

    private static func verticalMotionIsNotClaimed() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0)
        let first = send(&machine, 2, 15, .changed, 0.02)
        let later = send(&machine, -150, 0, .changed, 0.04)
        let end = send(&machine, .ended, 0.05)
        try check(!first.shouldConsume && !later.shouldConsume && !end.shouldConsume,
                  "A vertical gesture must remain available to ordinary scrolling")
        try check(end.committedSpace == nil && end.previewOffset == nil, "Vertical motion produced a page result")
    }

    private static func horizontalDistanceCommitsAdjacentSpace() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0)
        let preview = send(&machine, -65, 2, .changed, 0.1)
        let end = send(&machine, .ended, 0.3)
        try check(preview.shouldConsume && preview.previewOffset == -65, "Horizontal drag preview is incorrect")
        try check(end.finished && end.committedSpace == 2, "Leftward travel should commit the next space")
        _ = send(&machine, .began, 1)
        _ = send(&machine, 70, 0, .changed, 1.1)
        let previous = send(&machine, .ended, 1.3)
        try check(previous.committedSpace == 0, "Rightward travel should commit the previous space")
    }

    private static func shortDragCancelsAndFastFlickCommits() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0)
        _ = send(&machine, -20, 0, .changed, 0.08)
        let short = send(&machine, .ended, 0.3)
        try check(short.finished && short.committedSpace == nil, "A short, slow drag should settle back")
        _ = send(&machine, .began, 1)
        _ = send(&machine, -20, 0, .changed, 1.01)
        let flick = send(&machine, .ended, 1.02)
        try check(flick.committedSpace == 2, "A fast, deliberate flick should commit below the distance threshold")
        _ = send(&machine, .began, 2)
        _ = send(&machine, -20, 0, .changed, 2.01)
        let paused = send(&machine, .ended, 2.3)
        try check(paused.committedSpace == nil, "Old velocity must not commit after a pause")
    }

    private static func elasticBoundariesNeverCommit() throws {
        for (space, delta): (Int, CGFloat) in [(0, 100), (2, -100)] {
            var machine = SpaceSwipeStateMachine()
            _ = send(&machine, .began, 0, space: space)
            let preview = send(&machine, delta, 0, .changed, 0.02, space: space)
            let end = send(&machine, .ended, 0.03, space: space)
            guard let offset = preview.previewOffset else { throw Failure(description: "Boundary must show elastic feedback") }
            try check(abs(offset) > 0 && abs(offset) < abs(delta), "Boundary did not reduce the drag displacement")
            try check((offset < 0) == (delta < 0), "Boundary feedback changed direction")
            try check(end.finished && end.committedSpace == nil, "Swiping past the outer space must not commit")
        }
    }

    private static func cancellationAndMomentumAreSuppressed() throws {
        var machine = SpaceSwipeStateMachine()
        let unrelated = send(&machine, -200, 0, .none, 0, momentum: true)
        try check(!unrelated.shouldConsume, "Unrelated momentum should not be captured")
        _ = send(&machine, .began, 1)
        _ = send(&machine, -80, 0, .changed, 1.02)
        let cancelled = send(&machine, .cancelled, 1.03)
        try check(cancelled.finished && cancelled.committedSpace == nil, "Cancelled gesture committed a space")
        let tail = send(&machine, -400, 0, .none, 1.04, momentum: true)
        try check(tail.shouldConsume && tail.previewOffset == nil && !tail.finished && tail.committedSpace == nil,
                  "Momentum tail must be swallowed without updating or committing a page")
        _ = send(&machine, .began, 2)
        let vertical = send(&machine, 0, 30, .changed, 2.02)
        let freshTail = send(&machine, 0, 100, .none, 2.03, momentum: true)
        try check(!vertical.shouldConsume && !freshTail.shouldConsume, "A new vertical gesture inherited old momentum suppression")
    }

    private static func axisLockPersistsAndUnphasedWheelsAreIgnored() throws {
        var machine = SpaceSwipeStateMachine()
        let wheel = send(&machine, -100, 0, .none, 0)
        try check(!wheel.shouldConsume && wheel.previewOffset == nil, "Unphased wheel scroll was treated as a swipe")
        _ = send(&machine, .began, 1)
        _ = send(&machine, -15, 0, .changed, 1.02)
        let diagonal = send(&machine, -10, 90, .changed, 1.04)
        try check(diagonal.shouldConsume && diagonal.previewOffset == -25, "A claimed horizontal gesture lost its axis lock")
        machine.reset()
        let end = send(&machine, .ended, 1.1)
        try check(!end.shouldConsume && !end.finished, "reset() left a pending gesture")
    }

    private static func touchAnnouncementsAndStationaryPhases() throws {
        var machine = SpaceSwipeStateMachine()
        let touch = send(&machine, .mayBegin, 0)
        let stationary = send(&machine, .stationary, 0.01)
        try check(!touch.shouldConsume && touch.previewOffset == nil && !stationary.shouldConsume,
                  "Touch-only phases must not interrupt a settling page")
        _ = send(&machine, .began, 0.02)
        let locked = send(&machine, -15, 0, .changed, 0.04)
        let held = send(&machine, .stationary, 0.06)
        try check(locked.didLock && held.shouldConsume && held.previewOffset == -15 && !held.didLock,
                  "A stationary phase lost horizontal ownership or reacquired it")
    }

    private static func interruptedAnimationAcquiresCurrentPosition() throws {
        var machine = SpaceSwipeStateMachine()
        let began = send(&machine, 0, 0, .began, 0, initialOffset: -80)
        let undecided = send(&machine, -2, 0, .changed, 0.01, initialOffset: -100)
        let claimed = send(&machine, -6, 0, .changed, 0.02, initialOffset: -120)
        let moved = send(&machine, -10, 0, .changed, 0.03, initialOffset: -200)
        try check(!began.didLock && began.previewOffset == nil && undecided.previewOffset == nil,
                  "The animation was interrupted before horizontal intent")
        try check(claimed.didLock && claimed.previewOffset == -128,
                  "Handoff did not sample the live animation position when horizontal intent locked")
        try check(!moved.didLock && moved.previewOffset == -138,
                  "A claimed drag re-sampled its baseline, causing cumulative jumps")
    }

    private static func physicalEndOverlappingMomentumFinishes() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0)
        _ = send(&machine, -70, 0, .changed, 0.1)
        let ended = send(&machine, -100, 0, .ended, 0.11, momentum: true)
        try check(ended.finished && ended.committedSpace == 2 && ended.previewOffset == -70,
                  "A physical finger-up with momentum either stranded the page or included momentum travel")
        let tail = send(&machine, -200, 0, .none, 0.12, momentum: true)
        try check(tail.shouldConsume && !tail.finished && tail.previewOffset == nil,
                  "The overlapping momentum tail generated another transition")
        _ = send(&machine, .began, 1)
        _ = send(&machine, -80, 0, .changed, 1.1)
        let cancelled = send(&machine, 0, 0, .cancelled, 1.11, momentum: true)
        try check(cancelled.finished && cancelled.committedSpace == nil && cancelled.releaseVelocity == 0,
                  "Physical cancellation with momentum did not cancel the claimed swipe")
    }

    private static func interruptedBoundaryPreservesRubberBand() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0, space: 0)
        let first = send(&machine, 100, 0, .changed, 0.1, space: 0)
        guard let offset = first.previewOffset else { throw Failure(description: "Missing boundary preview") }
        _ = send(&machine, .ended, 0.3, space: 0)
        _ = send(&machine, .began, 1, space: 0)
        let resumed = send(&machine, 6, 0, .changed, 1.1, space: 0, initialOffset: offset)
        let expected: CGFloat = 228 * (1 - 1 / (1 + 106 * 0.55 / 228))
        try check(abs((resumed.previewOffset ?? -1) - expected) < 0.0001,
                  "Re-grabbing elastic feedback applied the rubber band twice")
    }

    private static func reverseFlickCancelsAndReportsVelocity() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0)
        _ = send(&machine, 20, 0, .changed, 0.01, initialOffset: -160)
        let reverse = send(&machine, .ended, 0.02)
        try check(reverse.committedSpace == nil && reverse.previewOffset == -140 && reverse.releaseVelocity > 650,
                  "A reverse flick should settle back while preserving release velocity")
        _ = send(&machine, .began, 1)
        _ = send(&machine, -20, 0, .changed, 1.01)
        let fast = send(&machine, .ended, 1.02)
        try check(fast.committedSpace == 2 && fast.releaseVelocity < -650,
                  "A committed flick lost velocity before the settling animation")
        _ = send(&machine, .began, 2)
        _ = send(&machine, -20, 0, .changed, 2.01)
        let paused = send(&machine, .ended, 2.3)
        try check(paused.releaseVelocity == 0, "Old velocity survived a pause before finger-up")
    }

    private static func changedPhaseCanStartWithoutBegan() throws {
        var machine = SpaceSwipeStateMachine()
        let first = send(&machine, -65, 0, .changed, 1)
        let end = send(&machine, .ended, 1.2)
        try check(first.didLock && first.previewOffset == -65 && end.committedSpace == 2,
                  "A valid stream whose first delivered phase is changed was dropped")
    }


    private static func previousAnimationCanCommitBeforeAxisLocks() throws {
        var machine = SpaceSwipeStateMachine()
        _ = send(&machine, .began, 0, space: 0)
        _ = send(&machine, -2, 0, .changed, 0.01, space: 0, initialOffset: -200)
        let lock = send(&machine, -6, 0, .changed, 0.02, space: 1, initialOffset: 0)
        _ = send(&machine, -70, 0, .changed, 0.1, space: 1)
        let end = send(&machine, .ended, 0.3, space: 1)
        try check(lock.didLock && lock.previewOffset == -8 && end.committedSpace == 2,
                  "A transition that settled during undecided intent left a stale origin space")
    }

}
