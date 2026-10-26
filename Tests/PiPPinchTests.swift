import Foundation
import CoreGraphics

/// Pinch-resizing the floating video: aspect kept, limits honoured, fingers' point fixed, stays on screen.
@main struct PiPPinchTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
    static func main() {
        do { try run(); print("PASS: \(checks) PiP pinch checks") }
        catch { print("FAIL: PiP pinch — \(error)"); exit(1) }
    }
    static func run() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let start = CGRect(x: 900, y: 40, width: 480, height: 270)
        let aspect: CGFloat = 16.0 / 9.0
        let center = CGPoint(x: start.midX, y: start.midY)

        let bigger = PiPPositioning.pinchFrame(start, scale: 1.25, anchor: center, aspect: aspect, minimumWidth: 320, screens: [screen])
        try check(close(bigger.width, 600) && close(bigger.width / bigger.height, aspect), "Pinch out did not grow with the aspect kept: \(bigger)")
        try check(close(bigger.midX, center.x) && close(bigger.midY, center.y), "The point under the fingers moved: \(bigger)")
        try check(screen.contains(bigger), "A grown panel left the screen: \(bigger)")

        let smaller = PiPPositioning.pinchFrame(start, scale: 0.5, anchor: center, aspect: aspect, minimumWidth: 320, screens: [screen])
        try check(close(smaller.width, 320) && close(smaller.height, 180), "Pinch in went below the minimum: \(smaller)")

        // Huge pinch stops at the screen; it never covers more than fits.
        let huge = PiPPositioning.pinchFrame(start, scale: 10, anchor: center, aspect: aspect, minimumWidth: 320, screens: [screen])
        try check(huge.width <= screen.width + 0.01 && huge.height <= screen.height + 0.01 && close(huge.width / huge.height, aspect)
                  && screen.contains(huge.insetBy(dx: 0.01, dy: 0.01)), "An oversized pinch escaped the screen: \(huge)")

        // Pinching at a corner keeps that corner under the fingers.
        let corner = CGPoint(x: start.maxX, y: start.minY)
        let shrunk = PiPPositioning.pinchFrame(start, scale: 0.8, anchor: corner, aspect: aspect, minimumWidth: 320, screens: [screen])
        try check(close(shrunk.maxX, start.maxX) && close(shrunk.minY, start.minY) && close(shrunk.width, 384), "A corner pinch drifted: \(shrunk)")

        // Portrait video uses its own aspect and minimum.
        let portrait = CGRect(x: 100, y: 100, width: 202.5, height: 360)
        let tall = PiPPositioning.pinchFrame(portrait, scale: 3, anchor: CGPoint(x: 200, y: 280), aspect: 9.0 / 16.0, minimumWidth: 180, screens: [screen])
        try check(close(tall.width / tall.height, 9.0 / 16.0) && tall.height <= screen.height + 0.01, "Portrait pinch broke its aspect or limit: \(tall)")

        // Invalid input leaves the frame alone.
        try check(PiPPositioning.pinchFrame(start, scale: .nan, anchor: center, aspect: aspect, minimumWidth: 320, screens: [screen]) == start
                  && PiPPositioning.pinchFrame(start, scale: 0, anchor: center, aspect: aspect, minimumWidth: 320, screens: [screen]) == start,
                  "An invalid pinch changed the frame")
    }
}
