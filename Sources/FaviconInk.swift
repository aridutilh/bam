import AppKit

/// Dark single-colour favicons (GitHub's black cat, Notion's N, Vercel's triangle) disappear on dark
/// chrome. Arc draws those marks white in dark mode; this does the same for every surface that shows a
/// favicon (sidebar rows and Favorites, the ⌃⇥ switcher, the command bar). Colourful icons and icons
/// that fill their square (their own background) are left exactly as they are.
@MainActor enum FaviconInk {
    private static let analysis = NSCache<NSImage, NSNumber>()
    private static let adaptive = NSCache<NSImage, NSImage>()

    /// The image to show: the original, or for a dark monochrome mark an image that draws white
    /// whenever it's drawn in a dark appearance (and as-is in light). Cached per original image,
    /// so identity stays stable for views that compare images.
    static func adapted(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        if let cached = adaptive.object(forKey: image) { return cached }
        guard isDarkMonochrome(image), let inverted = inverted(image) else { return image }
        let size = image.size
        let wrapped = NSImage(size: size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? inverted : image).draw(in: rect)
            return true
        }
        wrapped.cacheMode = .never
        wrapped.accessibilityDescription = image.accessibilityDescription
        adaptive.setObject(wrapped, forKey: image)
        return wrapped
    }

    /// The mark with its greys flipped (black ink → white, a light cut-out → dark), alpha kept: a black
    /// glyph turns white, and GitHub's dark disc with a light cat becomes a light disc with a dark cat.
    private static func inverted(_ image: NSImage) -> NSImage? {
        let side = 64
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return nil }
        for index in 0..<(side * side) {
            let a = Int(data[index * 4 + 3])
            for channel in 0..<3 { data[index * 4 + channel] = UInt8(max(0, a - Int(data[index * 4 + channel]))) }  // premultiplied invert
        }
        bitmap.size = image.size
        let result = NSImage(size: image.size); result.addRepresentation(bitmap)
        return result
    }

    /// True for a mark drawn in dark, unsaturated greys on a transparent background.
    static func isDarkMonochrome(_ image: NSImage) -> Bool {
        if let cached = analysis.object(forKey: image) { return cached.boolValue }
        let result = measure(image).map { $0.luminance < 0.35 && $0.saturation < 0.12 && $0.coverage > 0.04 && $0.coverage < 0.9 } ?? false
        analysis.setObject(NSNumber(value: result), forKey: image)
        return result
    }

    struct Measure { let luminance: Double; let saturation: Double; let coverage: Double }

    /// Averages over the visible pixels of a 32×32 rendering.
    static func measure(_ image: NSImage) -> Measure? {
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Measure the original in light appearance so an adapted image is never mistaken for a light one.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return nil }
        var weight = 0.0, luminance = 0.0, saturation = 0.0, visible = 0
        for index in 0..<(side * side) {
            let alpha = Double(data[index * 4 + 3]) / 255
            guard alpha > 0.3 else { continue }
            // Premultiplied: undo it to read the ink's own colour.
            let r = Double(data[index * 4]) / 255 / alpha, g = Double(data[index * 4 + 1]) / 255 / alpha, b = Double(data[index * 4 + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b)
            luminance += (0.2126 * r + 0.7152 * g + 0.0722 * b) * alpha
            saturation += (high - low) * alpha   // chroma: near-black greys don't count as colourful
            weight += alpha; visible += 1
        }
        guard weight > 0 else { return nil }
        return Measure(luminance: luminance / weight, saturation: saturation / weight, coverage: Double(visible) / Double(side * side))
    }
}
