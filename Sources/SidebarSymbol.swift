import AppKit

/// Keep SF Symbols in their native representation until AppKit draws them in
/// the destination context. Tinting with lockFocus would rasterize them first.
@MainActor enum SidebarSymbol {
    static func image(named name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    static func fittedRect(imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard [imageSize.width, imageSize.height, bounds.origin.x, bounds.origin.y,
               bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func draw(named name: String, in bounds: NSRect, color: NSColor,
                     pointSize: CGFloat, opacity: CGFloat = 1) {
        guard let image = image(named: name, color: color, pointSize: pointSize) else { return }
        let destination = fittedRect(imageSize: image.size, in: bounds)
        guard !destination.isEmpty else { return }
        image.draw(in: destination, from: .zero, operation: .sourceOver,
                   fraction: opacity, respectFlipped: true, hints: nil)
    }
}
