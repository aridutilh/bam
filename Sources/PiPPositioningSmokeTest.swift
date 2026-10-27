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
        let edge = CGRect(origin: CGPoint(x: 0, y: 322), size: size)
        try check(PiPPositioning.releaseFrame(edge, screens: [display]) == edge,
                  "middle-of-edge placement was attracted to a corner")
        let nearTopRight = CGRect(origin: CGPoint(x: 850, y: 600), size: size)
        try check(PiPPositioning.releaseFrame(nearTopRight, screens: [display]).origin == CGPoint(x: 872, y: 612),
                  "top-right corner did not respect visible bounds and inset")
        // A 120-by-160 offset is 200 points from the corner: inside the wider
        // release radius, while a 180-by-180 offset is outside 240 points.
        let gentleApproach = CGRect(origin: CGPoint(x: 752, y: 452), size: size)
        try check(PiPPositioning.releaseFrame(gentleApproach, screens: [display]).origin == CGPoint(x: 872, y: 612),
                  "a release 200 points from the corner did not use the wider magnet")
        let outsideRadius = CGRect(origin: CGPoint(x: 692, y: 432), size: size)
        try check(PiPPositioning.releaseFrame(outsideRadius, screens: [display]) == outsideRadius,
                  "corner capture ignored combined-axis distance or exceeded its radius")
        try check(PiPPositioning.dragFrame(gentleApproach, delta: .zero, screens: [display]) == gentleApproach,
                  "corner attraction pulled the panel while fingers were still down")
        let left = CGRect(x: -1000, y: -120, width: 1000, height: 720)
        let nearLeft = CGRect(origin: CGPoint(x: -979, y: -98), size: size)
        try check(PiPPositioning.releaseFrame(nearLeft, screens: [display, left]).origin == CGPoint(x: -992, y: -112),
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

        let flick = PiPPositioning.releasePlan(free, velocity: CGPoint(x: 1900, y: 1400), screens: [display])
        try check(flick.isFlick && flick.frame.origin == CGPoint(x: 872, y: 612),
                  "a fast diagonal release from the interior did not project into corner capture")
        try check((0.35...0.55).contains(flick.duration), "flick continuation duration escaped its bounds")
        let slow = PiPPositioning.releasePlan(free, velocity: CGPoint(x: 300, y: 200), screens: [display])
        try check(!slow.isFlick && slow.frame == free && slow.duration == 0.22,
                  "slow release coasted away from deliberate free placement")
        let extreme = PiPPositioning.releasePlan(free, velocity: CGPoint(x: 300_000, y: 400_000), screens: [display])
        let capped = PiPPositioning.boundedVelocity(CGPoint(x: 300_000, y: 400_000))
        try check(abs(hypot(capped.x, capped.y) - 6000) < 0.01 && display.contains(extreme.frame),
                  "extreme velocity exceeded the speed limit or visible display")
        let crossFlick = PiPPositioning.releasePlan(crossing, velocity: CGPoint(x: 2200, y: 0), screens: [display, right])
        try check(right.contains(crossFlick.frame), "projected release could not cross to the adjacent display")
        try check(PiPPositioning.releasePlan(free, velocity: CGPoint(x: 2000, y: 2000), screens: []).frame == free,
                  "a flick moved the window without usable display bounds")
        let leftInterior = CGRect(x: 40, y: 200, width: 320, height: 180)
        let moderateRight = PiPPositioning.releasePlan(leftInterior, velocity: CGPoint(x: 500, y: 0), screens: [display])
        try check(moderateRight.frame.origin == CGPoint(x: 872, y: 32),
                  "moderate rightward flick stopped short or chose the closer left corner")
        let moderateDiagonal = PiPPositioning.releasePlan(leftInterior, velocity: CGPoint(x: 340, y: 340), screens: [display])
        try check(moderateDiagonal.frame.origin == CGPoint(x: 872, y: 612),
                  "diagonal flick did not commit to both directed edges")
        let upperLeft = CGRect(x: 40, y: 500, width: 320, height: 180)
        let almostHorizontal = PiPPositioning.releasePlan(upperLeft, velocity: CGPoint(x: 500, y: -50), screens: [display])
        try check(almostHorizontal.frame.origin == CGPoint(x: 872, y: 612),
                  "small vertical drift sent a horizontal flick to the far vertical edge")
        let downDiagonal = PiPPositioning.releasePlan(upperLeft, velocity: CGPoint(x: 500, y: -200), screens: [display])
        try check(downDiagonal.frame.origin == CGPoint(x: 872, y: 32),
                  "a dominant downward component failed to choose the bottom corner")
        let almostVertical = PiPPositioning.releasePlan(leftInterior, velocity: CGPoint(x: 50, y: 500), screens: [display])
        try check(almostVertical.frame.origin == CGPoint(x: 8, y: 612),
                  "small horizontal drift overrode the nearer edge of a vertical flick")
        let upperRight = CGRect(x: 800, y: 500, width: 320, height: 180)
        let opposite = PiPPositioning.releasePlan(upperRight, velocity: CGPoint(x: -500, y: 0), screens: [display])
        try check(opposite.frame.origin == CGPoint(x: 8, y: 612),
                  "leftward flick chose the nearby right corner instead of its direction")
        try check(PiPPositioning.releasePlan(free, velocity: CGPoint(x: 449, y: 0), screens: [display]).frame == free,
                  "subthreshold movement lost free placement after directional corner changes")
        try check(crossFlick.frame.origin == CGPoint(x: 2072, y: 8),
                  "flick corner was chosen on the departure display instead of the projected destination")
        let negativeFlick = PiPPositioning.releasePlan(free, velocity: CGPoint(x: -3700, y: 0), screens: [display, left])
        try check(negativeFlick.frame.origin == CGPoint(x: -992, y: 412),
                  "directional corner placement mishandled a negative-coordinate destination display")
        let largeFlick = PiPPositioning.releasePlan(oversized, velocity: CGPoint(x: 600, y: 600), screens: [display])
        try check(display.contains(largeFlick.frame) && abs(largeFlick.frame.width / largeFlick.frame.height - 16.0 / 9.0) < 0.001,
                  "large-panel corner commitment produced invalid insets or lost aspect ratio")
        let nearRight = CGRect(x: 800, y: 80, width: 320, height: 180)
        let shortTravel = PiPPositioning.releasePlan(nearRight, velocity: CGPoint(x: 500, y: 0), screens: [display])
        try check(moderateRight.duration > shortTravel.duration && (0.35...0.55).contains(moderateRight.duration)
                    && (0.35...0.55).contains(shortTravel.duration),
                  "far corner travel did not receive a longer bounded settling duration")

        // Tucking behind a screen edge.
        let hanging = CGRect(x: 1050, y: 300, width: 320, height: 180)   // 170 of 320 past the right edge
        let tuck = PiPPositioning.releasePlan(hanging, velocity: .zero, screens: [display])
        try check(tuck.tuck == .right && tuck.frame.minX == display.maxX - PiPPositioning.tuckSliver
                    && tuck.frame.minY == 300 && tuck.frame.size == size,
                  "a panel hanging well past the right edge did not tuck behind it with a sliver showing")
        let hangingLeft = CGRect(x: -150, y: 300, width: 320, height: 180)
        try check(PiPPositioning.releasePlan(hangingLeft, velocity: .zero, screens: [display]).tuck == .left,
                  "a panel hanging past the left edge did not tuck left")
        let barelyOver = CGRect(x: 960, y: 300, width: 320, height: 180)   // 80 of 320 over: under the threshold
        try check(PiPPositioning.releasePlan(barelyOver, velocity: .zero, screens: [display]).tuck == nil,
                  "a small overhang tucked instead of fitting back on screen")
        let rightCorner = CGRect(x: 872, y: 32, width: 320, height: 180)
        try check(PiPPositioning.releasePlan(rightCorner, velocity: CGPoint(x: 1400, y: 100), screens: [display]).tuck == .right,
                  "a sideways throw from against the right edge did not tuck")
        try check(PiPPositioning.releasePlan(leftInterior, velocity: CGPoint(x: 1400, y: 0), screens: [display]).tuck == nil,
                  "a throw from the middle tucked instead of going to its corner")
        try check(PiPPositioning.releasePlan(crossing, velocity: CGPoint(x: 2200, y: 0), screens: [display, right]).tuck == nil
                    && PiPPositioning.releasePlan(CGRect(x: 1000, y: 300, width: 320, height: 180), velocity: .zero,
                                                  screens: [display, right]).tuck == nil,
                  "an edge shared with another display tucked instead of crossing")
        try check(PiPPositioning.releasePlan(oversized, velocity: CGPoint(x: 3000, y: 0), screens: [display]).tuck == nil,
                  "a video too large for a sliver tucked")
        let peeked = PiPPositioning.tuckedFrame(tuck.frame, side: .right, screens: [display], peek: true)
        try check(peeked.minX == display.maxX - PiPPositioning.tuckSliver - PiPPositioning.tuckPeek,
                  "pointing at the sliver did not slide a little more out")
        let back = PiPPositioning.untuckedFrame(tuck.frame, side: .right, screens: [display])
        try check(display.contains(back) && back.maxX == display.maxX - PiPPositioning.cornerInset,
                  "bringing it back did not land against the same edge")
        try check(PiPPositioning.untuckedFrame(CGRect(x: 1172, y: 40, width: 320, height: 180), side: .right, screens: [display]).origin
                    == CGPoint(x: 872, y: 32), "a video tucked near a corner did not come back into that corner")
        try check(PiPPositioning.releasePlan(tuck.frame, velocity: .zero, screens: [display]).tuck == .right,
                  "a tucked video released in place (pinch, click) left its tuck")

        var velocity = PiPPhysicalVelocity()
        velocity.begin(at: 1)
        velocity.record(.zero, at: 1)
        velocity.record(CGPoint(x: 20, y: 10), at: 1.02)
        velocity.record(CGPoint(x: 20, y: 10), at: 1.04)
        velocity.record(CGPoint(x: 20, y: 10), at: 1.06)
        try check(near(velocity.velocity(at: 1.06), CGPoint(x: 1000, y: 500)),
                  "recent physical velocity had incorrect time or axis units")
        var coalesced = PiPPhysicalVelocity()
        coalesced.begin(at: 1)
        coalesced.record(CGPoint(x: 10, y: 5), at: 1.02)
        coalesced.record(CGPoint(x: 10, y: 5), at: 1.02)
        coalesced.record(CGPoint(x: 40, y: 20), at: 1.06)
        try check(near(coalesced.velocity(at: 1.06), velocity.velocity(at: 1.06)),
                  "coalesced timestamps changed the physical velocity")
        let quietVelocity = velocity.velocity(at: 1.15)
        try check(quietVelocity == .zero && velocity.velocity(at: 1.30) == .zero,
                  "a quiet or stale release resurrected old velocity")
        velocity.record(CGPoint(x: -2, y: -1), at: 1.07)
        let reversed = velocity.velocity(at: 1.08)
        try check(reversed.x < 0 && reversed.y < 0 && hypot(reversed.x, reversed.y) < 450,
                  "small reversal launched the preceding fast direction")
        velocity.pause(at: 1.09)
        try check(velocity.velocity(at: 1.10) == .zero, "stationary fingers retained launch velocity")
        coalesced.begin(at: 2)
        coalesced.record(CGPoint(x: 100, y: 100), at: 2)
        coalesced.record(CGPoint(x: 100, y: 100), at: 2)
        try check(coalesced.velocity(at: 2.01) == .zero,
                  "same-time packets invented a duration or inherited an earlier gesture")
        coalesced.record(CGPoint(x: 100, y: 100), at: 1.9)
        try check(coalesced.velocity(at: 2.02) == .zero, "out-of-order time produced a spurious flick")

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
        try check(panel.frame.origin == CGPoint(x: visible.minX + 8, y: visible.minY + 8),
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
                    && near(panel.frame.origin, CGPoint(x: visible.minX + 8, y: visible.minY + 8)),
                  "precise unphased input did not finish and snap after a quiet period")
        // Deterministic in-process physical packets exercise the actual panel
        // event adapter. These never enter the system event queue or take focus.
        panel.positionScreenFrames = { [display] }
        panel.positionReduceMotion = { false }
        let animatesFlick = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func startFlick() {
            panel.cancelPositioning()
            panel.setFrame(free, display: false)
            panel.sendEvent(event(phase: .began))
            for _ in 0..<3 { panel.sendEvent(event(70, -55, phase: .changed)) }
        }
        let corner = CGPoint(x: 872, y: 612)
        startFlick()
        let fingerUpFrame = panel.frame
        panel.sendEvent(event(phase: .ended, momentum: .began))
        try check(!panel.isScrollDragging && (animatesFlick
                    ? panel.isPositionSnapRunning && panel.frame == fingerUpFrame
                    : !panel.isPositionSnapRunning && near(panel.frame.origin, corner)),
                  "fast release did not continue from the displayed frame or honor Reduce Motion")
        let immediatelyReleased = panel.frame
        panel.sendEvent(event(1000, -1000, phase: [], momentum: .changed))
        try check(panel.frame == immediatelyReleased && panel.isPositionSnapRunning == animatesFlick,
                  "OS momentum added a second movement driver")
        spin(for: 0.16)
        try check(animatesFlick
                    ? panel.frame.minX > fingerUpFrame.minX && panel.frame.minX < corner.x
                        && panel.frame.minY > fingerUpFrame.minY && panel.frame.minY < corner.y
                    : near(panel.frame.origin, corner),
                  "flick continuation did not visibly travel toward its landing point")
        spin(until: { !panel.isPositionSnapRunning }, timeout: 0.8)
        try check(!panel.isPositionSnapRunning && near(panel.frame.origin, corner),
                  "native flick did not finish at the projected corner")
        panel.sendEvent(event(-1000, 1000, phase: [], momentum: .changed))
        try check(near(panel.frame.origin, corner) && !panel.isPositionSnapRunning,
                  "late inertia restarted or reversed a completed continuation")

        startFlick()
        panel.sendEvent(event(900, -900, phase: [], momentum: .began))
        try check(!panel.isScrollDragging && (animatesFlick
                    ? panel.isPositionSnapRunning : near(panel.frame.origin, corner)),
                  "momentum-first release failed to finish the physical gesture")
        let midContinuation = panel.frame.origin
        panel.sendEvent(event(-8, 5, phase: .began, momentum: .ended))
        let takeover = CGPoint(x: midContinuation.x - 8, y: midContinuation.y - 5)
        spin(for: 0.6)
        try check(panel.isScrollDragging && !panel.isPositionSnapRunning && near(panel.frame.origin, takeover),
                  "new physical input failed to interrupt a flick at its displayed frame")
        panel.sendEvent(event(phase: .cancelled))
        startFlick()
        panel.sendEvent(event(phase: .ended))
        panel.sendEvent(event(phase: .mayBegin))
        let held = panel.frame
        spin(for: 0.6)
        try check(!panel.isScrollDragging && !panel.isPositionSnapRunning && panel.frame == held,
                  "mayBegin did not cancel an old continuation")

        panel.cancelPositioning(); panel.setFrame(free, display: false)
        panel.sendEvent(event(phase: .began))
        for _ in 0..<3 { panel.sendEvent(event(2, -1, phase: .changed)) }
        let gentleFrame = panel.frame
        panel.sendEvent(event(phase: .ended))
        try check(!panel.isPositionSnapRunning && panel.frame == gentleFrame,
                  "slow native release lost free interior placement")
        panel.cancelPositioning(); panel.setFrame(leftInterior, display: false)
        panel.sendEvent(event(phase: .began))
        for _ in 0..<3 { panel.sendEvent(event(14, 0, phase: .changed)) }
        let moderateFingerUp = panel.frame
        panel.sendEvent(event(phase: .ended))
        try check(animatesFlick ? panel.isPositionSnapRunning && panel.frame == moderateFingerUp
                    : near(panel.frame.origin, CGPoint(x: 872, y: 32)),
                  "moderate native flick failed to start its directed corner commitment")
        spin(until: { !panel.isPositionSnapRunning }, timeout: 0.8)
        try check(near(panel.frame.origin, CGPoint(x: 872, y: 32)),
                  "moderate native flick stopped at its short projection instead of the far corner")
        startFlick()
        let staleFrame = panel.frame
        time += 0.2
        panel.sendEvent(event(phase: .ended))
        try check(!panel.isPositionSnapRunning && panel.frame == staleFrame,
                  "delayed native finger-up reused stale velocity")
        startFlick()
        panel.sendEvent(event(-2, 2, phase: .changed))
        let reversalFrame = panel.frame
        panel.sendEvent(event(phase: .ended))
        try check(!panel.isPositionSnapRunning && panel.frame == reversalFrame,
                  "native direction reversal launched the earlier flick")
        startFlick()
        panel.sendEvent(event(phase: .stationary))
        let stationaryFrame = panel.frame
        panel.sendEvent(event(phase: .ended))
        try check(!panel.isPositionSnapRunning && panel.frame == stationaryFrame,
                  "native stationary pause reused preceding fast movement")
        panel.cancelPositioning(); panel.setFrame(free, display: false)
        for _ in 0..<3 { panel.sendEvent(event(70, -55, phase: [])) }
        let unphasedFrame = panel.frame
        spin(until: { !panel.isScrollDragging && !panel.isPositionSnapRunning }, timeout: 0.8)
        try check(!panel.isScrollDragging && !panel.isPositionSnapRunning && panel.frame == unphasedFrame,
                  "quiet fallback launched old unphased velocity")
        startFlick()
        panel.positionReduceMotion = { true }
        panel.sendEvent(event(phase: .ended))
        try check(!panel.isPositionSnapRunning && near(panel.frame.origin, corner),
                  "Reduce Motion did not place the flick destination without animation")
        panel.positionReduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        try check(NSApp.keyWindow === previousKey && previousKey?.firstResponder === previousResponder,
                  "flick continuation or interruption changed keyboard focus")
        panel.positionScreenFrames = { [visible] }

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
