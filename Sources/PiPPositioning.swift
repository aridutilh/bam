import Foundation

/// Independent window-placement geometry. Screens are AppKit global visible
/// frames (including negative coordinates), not full frames behind the Dock.
enum PiPPositioning {
    static let cornerInset: CGFloat = 16
    static let magneticRadius: CGFloat = 140

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
