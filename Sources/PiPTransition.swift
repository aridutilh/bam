import AppKit
import WebKit

/// An inert image, never a second player. Keeping it inside the web view makes
/// it survive the controller's synchronous tab/split reparenting.
@MainActor final class PiPTransitionImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(image: NSImage?, frame: NSRect, identifier: String) {
        super.init(frame: frame)
        self.image = image
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        imageScaling = .scaleAxesIndependently
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class PiPRestoration {
    let token: UUID
    let identity: ObjectIdentifier
    weak var web: WKWebView?
    let alpha: CGFloat
    let panel: ArkVideoPanel?
    let cover: PiPTransitionImage
    var deadline: DispatchWorkItem?
    var ready = false
    var finishing = false

    init(token: UUID, web: WKWebView, alpha: CGFloat, panel: ArkVideoPanel?, image: NSImage?) {
        self.token = token; identity = ObjectIdentifier(web); self.web = web; self.alpha = alpha; self.panel = panel
        cover = PiPTransitionImage(image: image, frame: web.bounds, identifier: "pip.restorationCover")
    }

    func cancel() {
        deadline?.cancel(); deadline = nil
        cover.layer?.removeAllAnimations(); cover.removeFromSuperview()
        panel?.delegate = nil; panel?.onEscape = nil; panel?.overlay = nil
        panel?.orderOut(nil); panel?.close()
        web?.alphaValue = alpha
    }
}

struct PiPVideoGeometry {
    let rect: NSRect
    let viewport: NSSize

    init?(_ value: Any?) {
        guard let info = value as? [String: Any], let rect = info["rect"] as? [String: Any],
              let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let width = rect["width"] as? Double, let height = rect["height"] as? Double,
              let viewportWidth = info["viewportWidth"] as? Double,
              let viewportHeight = info["viewportHeight"] as? Double,
              [x, y, width, height, viewportWidth, viewportHeight].allSatisfy(\.isFinite),
              width > 0, height > 0, viewportWidth > 0, viewportHeight > 0 else { return nil }
        self.rect = NSRect(x: x, y: y, width: width, height: height)
        viewport = NSSize(width: viewportWidth, height: viewportHeight)
    }

    @MainActor func screenRect(in web: WKWebView) -> NSRect? {
        guard let window = web.window, window.isVisible, !web.isHiddenOrHasHiddenAncestor else { return nil }
        let scaleX = web.bounds.width / viewport.width, scaleY = web.bounds.height / viewport.height
        let local = NSRect(x: rect.minX * scaleX,
                           y: web.isFlipped ? rect.minY * scaleY : web.bounds.height - rect.maxY * scaleY,
                           width: rect.width * scaleX, height: rect.height * scaleY)
        let visible = local.intersection(web.visibleRect)
        guard visible.width > 24, visible.height > 24 else { return nil }
        return window.convertToScreen(web.convert(visible, to: nil))
    }

    func crop(from image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        let x = image.size.width / viewport.width, y = image.size.height / viewport.height
        let source = NSRect(x: rect.minX * x, y: image.size.height - rect.maxY * y,
                            width: rect.width * x, height: rect.height * y)
            .intersection(NSRect(origin: .zero, size: image.size))
        guard source.width > 1, source.height > 1 else { return nil }
        return NSImage(size: source.size, flipped: false) { destination in
            image.draw(in: destination, from: source, operation: .copy, fraction: 1)
            return true
        }
    }
}
