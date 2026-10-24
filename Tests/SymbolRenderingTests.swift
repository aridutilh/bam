import AppKit

/// Offscreen checks only: no windows, event synthesis, user preferences, or files.
/// Compile with Sources/SidebarSymbol.swift as a standalone executable.
@main @MainActor
struct SymbolRenderingTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0

    static func main() {
        do {
            try geometry()
            try renderedEllipsis()
            print("PASS: sidebar symbols — \(checks) checks: aspect fitting, tint, three round dots at 1×/2×, and legacy-stretch regression control")
        } catch {
            FileHandle.standardError.write(Data("FAIL: sidebar symbols — \(error)\n".utf8))
            exit(1)
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
    }

    private static func geometry() throws {
        let symbols = ["ellipsis", "chevron.left", "sidebar.left", "plus", "pip", "square.stack.3d.up", "sparkles"]
        let boxes = [NSRect(x: 7, y: 11, width: 13, height: 13), NSRect(x: -9, y: 6, width: 31, height: 17)]
        for symbol in symbols {
            guard let image = SidebarSymbol.image(named: symbol, color: .white, pointSize: 13) else {
                throw Failure(description: "System symbol \(symbol) was unavailable")
            }
            try check(image.size.width > 0 && image.size.height > 0, "\(symbol) has no intrinsic dimensions")
            for bounds in boxes {
                let fitted = SidebarSymbol.fittedRect(imageSize: image.size, in: bounds)
                try check(fitted.width > 0 && fitted.height > 0 && bounds.insetBy(dx: -0.001, dy: -0.001).contains(fitted),
                          "\(symbol) escaped its destination bounds: \(fitted) in \(bounds)")
                let sourceRatio = image.size.width / image.size.height
                try check(abs(fitted.width / fitted.height - sourceRatio) < 0.0001,
                          "\(symbol) was stretched from its native aspect ratio")
                try check(abs(fitted.midX - bounds.midX) < 0.0001 && abs(fitted.midY - bounds.midY) < 0.0001,
                          "\(symbol) was not centered in its destination")
            }
        }
        try check(SidebarSymbol.image(named: "ark.test.nonexistent.symbol", color: .white, pointSize: 13) == nil,
                  "A missing symbol did not fail safely")
    }

    private struct Dot {
        let width: Int
        let height: Int
        let aspect: Double
    }

    private struct Raster {
        let bitmap: NSBitmapImageRep
        let scale: Int

        func alpha(_ x: Int, _ y: Int) -> Double {
            Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }

        /// Separate the three dots by transparent columns. Measure their second
        /// moments, which tolerate antialiasing better than fixed pixel snapshots.
        func dots() -> [Dot] {
            var spans: [ClosedRange<Int>] = []
            var start: Int?
            for x in 0..<bitmap.pixelsWide {
                let occupied = (0..<bitmap.pixelsHigh).contains { alpha(x, $0) >= 0.15 }
                if occupied && start == nil { start = x }
                if !occupied, let first = start { spans.append(first...(x - 1)); start = nil }
            }
            if let start { spans.append(start...(bitmap.pixelsWide - 1)) }
            return spans.compactMap { span in
                var weight = 0.0, sumX = 0.0, sumY = 0.0
                var minY = bitmap.pixelsHigh, maxY = -1
                for x in span {
                    for y in 0..<bitmap.pixelsHigh {
                        let value = alpha(x, y)
                        weight += value; sumX += value * (Double(x) + 0.5); sumY += value * (Double(y) + 0.5)
                        if value >= 0.15 { minY = min(minY, y); maxY = max(maxY, y) }
                    }
                }
                guard weight > 0, maxY >= minY else { return nil }
                let cx = sumX / weight, cy = sumY / weight
                var momentX = 0.0, momentY = 0.0
                for x in span {
                    for y in 0..<bitmap.pixelsHigh {
                        let value = alpha(x, y)
                        momentX += value * pow(Double(x) + 0.5 - cx, 2)
                        momentY += value * pow(Double(y) + 0.5 - cy, 2)
                    }
                }
                // Include each pixel's area instead of treating a one-pixel dot
                // as a zero-width point; 1/12 is the variance of a unit square.
                let aspect = sqrt((momentX / weight + 1.0 / 12) / (momentY / weight + 1.0 / 12))
                return Dot(width: span.count, height: maxY - minY + 1, aspect: aspect)
            }
        }

        func meanTint() -> (red: Double, green: Double, blue: Double, weight: Double) {
            var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.15 else { continue }
                    let alpha = Double(color.alphaComponent)
                    red += Double(color.redComponent) * alpha
                    green += Double(color.greenComponent) * alpha
                    blue += Double(color.blueComponent) * alpha
                    weight += alpha
                }
            }
            return (red / max(1, weight), green / max(1, weight), blue / max(1, weight), weight)
        }
    }

    private static func render(_ image: NSImage, color: NSColor, scale: Int, side: CGFloat, legacyStretch: Bool = false) throws -> Raster {
        let canvas: CGFloat = 64
        let pixels = Int(canvas) * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure(description: "Could not allocate the \(scale)× symbol bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let bounds = NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
        // The old square-stretch operation exists only in this negative control.
        if legacyStretch {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: false, hints: nil)
        } else {
            SidebarSymbol.draw(named: "ellipsis", in: bounds, color: color, pointSize: 12)
        }
        context.flushGraphics()
        return Raster(bitmap: bitmap, scale: scale)
    }

    private static func renderedEllipsis() throws {
        let color = NSColor(srgbRed: 0.86, green: 0.10, blue: 0.22, alpha: 1)
        guard let image = SidebarSymbol.image(named: "ellipsis", color: color, pointSize: 12) else {
            throw Failure(description: "Ellipsis symbol was unavailable")
        }
        var normalizedWidths: [Double] = []
        var normalizedHeights: [Double] = []
        for scale in [1, 2] {
            // Enlarged offscreen rendering gives enough samples to assess shape
            // independently of single-pixel rounding at the real sidebar size.
            let raster = try render(image, color: color, scale: scale, side: 32)
            let dots = raster.dots()
            try check(dots.count == 3, "\(scale)× ellipsis rendered \(dots.count) ink groups instead of three")
            try check(dots.allSatisfy { (0.65...1.55).contains($0.aspect) },
                      "\(scale)× ellipsis dots are smeared: axis ratios \(dots.map(\.aspect))")
            let tint = raster.meanTint()
            try check(tint.weight > 1 && tint.red > tint.green * 2 && tint.red > tint.blue * 1.5,
                      "\(scale)× ellipsis lost its requested native palette tint")
            normalizedWidths.append(Double(dots.reduce(0) { $0 + $1.width }) / Double(3 * scale))
            normalizedHeights.append(Double(dots.reduce(0) { $0 + $1.height }) / Double(3 * scale))

            let actualSize = try render(image, color: color, scale: scale, side: 13)
            let smallDots = actualSize.dots()
            try check(smallDots.count == 3, "Actual sidebar-size ellipsis merged or lost dots at \(scale)×")
            try check(smallDots.allSatisfy { (0.45...2.0).contains($0.aspect) },
                      "Actual sidebar-size ellipsis contains stretched dots at \(scale)×")

            let old = try render(image, color: color, scale: scale, side: 32, legacyStretch: true).dots()
            try check(old.count == 3 && old.contains { !(0.65...1.55).contains($0.aspect) },
                      "The \(scale)× legacy-square control did not reproduce the aspect distortion")
        }
        try check(abs(normalizedWidths[0] - normalizedWidths[1]) <= 1.25
                    && abs(normalizedHeights[0] - normalizedHeights[1]) <= 1.25,
                  "Switching bitmap scale changed the ellipsis's point-space dot dimensions")
    }
}
