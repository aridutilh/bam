import AppKit

/// Dark one-colour favicons get a white ink on dark chrome; colourful and full-square icons don't.
@main @MainActor struct FaviconInkTests {
    nonisolated(unsafe) static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) }; count += 1 }
    static func icon(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in draw(rect); return true }
    }
    static func pixel(_ image: NSImage, appearance: NSAppearance.Name) -> (Double, Double) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32)) }
        NSGraphicsContext.restoreGraphicsState()
        let c = rep.colorAt(x: 16, y: 16)!.usingColorSpace(.deviceRGB)!
        return (Double(c.brightnessComponent), Double(c.alphaComponent))
    }
    static func main() {
        // GitHub-like: a black disc on transparent.
        let mark = icon { r in NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill() }
        expect(FaviconInk.isDarkMonochrome(mark), "A black mark on transparent is dark monochrome")
        let adapted = FaviconInk.adapted(mark)!
        expect(adapted !== mark && FaviconInk.adapted(mark) === adapted, "The adapted image is cached (stable identity)")
        expect(pixel(adapted, appearance: .darkAqua).0 > 0.85, "It draws light on dark chrome")
        expect(pixel(adapted, appearance: .aqua).0 < 0.15, "It stays black on light chrome")
        // GitHub-style: a dark disc with a light mark inside flips to a light disc with a dark mark.
        let disc = icon { r in NSColor(white: 0.13, alpha: 1).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 13, dy: 13)).fill() }
        let flipped = FaviconInk.adapted(disc)!
        expect(flipped !== disc && pixel(flipped, appearance: .darkAqua).0 < 0.2, "The light cut-out turns dark on dark chrome")
        // Colourful, and a dark icon with its own full background, are untouched.
        let colourful = icon { r in NSColor.systemRed.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill() }
        expect(FaviconInk.adapted(colourful) === colourful, "Colourful icons are left alone")
        let square = icon { r in NSColor.black.setFill(); r.fill(); NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 10, dy: 10)).fill() }
        expect(FaviconInk.adapted(square) === square, "A dark tile with its own background (X, Threads) is left alone")
        let grey = icon { r in NSColor(white: 0.55, alpha: 1).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill() }
        expect(FaviconInk.adapted(grey) === grey, "Mid-grey marks already read on dark and are left alone")
        print("PASS: \(count) favicon ink checks")
    }
}
