import AppKit
import UniformTypeIdentifiers
import WebKit

/// Arc's Capture (⇧⌘2): the window dims, the block under the pointer lights
/// up, a click takes that block and a drag takes any area. Yab's extras where
/// Arc has none: ↑/↓ widen to the parent block or narrow back, F takes the
/// whole page. The picture goes straight to the clipboard, and a small panel
/// beside it offers Copy, Save…, Share… and Retake.
///
/// Nothing is written anywhere unless the person chooses Save…, so private
/// windows leave no trace. Page structure is read by a script in its own
/// content world, invisible to the page.
@MainActor extension BrowserController {
    @objc func capturePage(_ sender: Any?) {
        guard let surface = pageCommandSurface else { NSSound.beep(); return }
        dismissAddress(); cancelPaging()
        tabNavigation.capture.begin(on: surface.web, owner: self)
    }
    @objc func captureFullPage(_ sender: Any?) {
        guard let surface = pageCommandSurface else { NSSound.beep(); return }
        dismissAddress(); cancelPaging()
        tabNavigation.capture.begin(on: surface.web, owner: self, fullPage: true)
    }
    var isCapturing: Bool { tabNavigation.capture.isActive }
}

@MainActor final class PageCaptureCoordinator: NSObject {
    static let world = WKContentWorld.world(name: "BamCapture")
    private weak var owner: BrowserController?
    private weak var web: WKWebView?
    private var overlay: CaptureOverlayView?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hoverToken = 0
    private(set) var image: NSImage?
    var isActive: Bool { overlay != nil }

    // MARK: Session

    func begin(on web: WKWebView, owner: BrowserController, fullPage: Bool = false) {
        end()
        guard let content = web.window?.contentView else { return }
        self.owner = owner; self.web = web
        let overlay = CaptureOverlayView(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onHover = { [weak self] point in self?.hover(at: point) }
        overlay.onClick = { [weak self] in self?.captureHovered() }
        overlay.onDrag = { [weak self] rect in self?.capture(rect: rect) }
        overlay.onRetake = { [weak self] in self?.retake() }
        overlay.onCopy = { [weak self] in self?.copyImage() }
        overlay.onSave = { [weak self] in self?.save() }
        overlay.onShare = { [weak self] view in self?.share(from: view) }
        overlay.onCancel = { [weak self] in self?.end() }
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.page = web
        self.overlay = overlay
        web.window?.makeFirstResponder(overlay)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let overlay = self.overlay, event.window === overlay.window else { return event }
            return self.handleKey(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: web.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.overlay?.isShowingResult == false { self?.end() } }
        }
        if fullPage { captureFullPage() }
        else if let window = web.window {
            let point = overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if overlay.pageFrame.contains(point) { hover(at: point) }
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        overlay?.removeFromSuperview(); overlay = nil
        image = nil; hoverToken += 1
        if let owner, let web, web.window != nil { web.window?.makeFirstResponder(owner.commandWebView ?? web) }
    }

    private func retake() {
        guard let web, let owner else { end(); return }
        begin(on: web, owner: owner)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let overlay else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 { end(); return true }                                       // Esc
        if overlay.isShowingResult {
            if flags == .command, event.charactersIgnoringModifiers == "c" { copyImage(); return true }
            if flags == .command, event.charactersIgnoringModifiers == "s" { save(); return true }
            if flags.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "r" { retake(); return true }
            return flags.contains(.command) ? false : true
        }
        switch (event.keyCode, flags) {
        case (126, []): walk("up"); return true                                             // ↑ parent block
        case (125, []): walk("down"); return true                                           // ↓ back toward the pointer
        case (36, []), (76, []): captureHovered(); return true                              // Return
        case (3, []): captureFullPage(); return true                                        // F
        default: return !flags.contains(.command)
        }
    }

    // MARK: Picking blocks

    /// Defines the picker on first use (in its own world) and answers in CSS pixels of the viewport.
    private static let picker = #"""
    if (!window.__bamCapture) {
      const box = (e) => { const r = e.getBoundingClientRect(); return {x: r.left, y: r.top, w: r.width, h: r.height}; };
      const same = (a, b) => Math.abs(a.x - b.x) < 1 && Math.abs(a.y - b.y) < 1 && Math.abs(a.w - b.w) < 1 && Math.abs(a.h - b.h) < 1;
      const block = (e) => {
        const r = e.getBoundingClientRect(), s = getComputedStyle(e);
        return r.width >= 48 && r.height >= 24 && s.display !== 'inline' && s.display !== 'contents' && s.visibility !== 'hidden';
      };
      // A block that draws its own box (fill, border, shadow, rounded corners) or is media reads as one thing, like Arc picks.
      const boxy = (e) => {
        if (/^(IMG|VIDEO|CANVAS|SVG|IFRAME|PICTURE|FIGURE|TABLE|PRE|BLOCKQUOTE|ARTICLE|SECTION|ASIDE|NAV|HEADER|FOOTER|FORM)$/i.test(e.tagName)) return true;
        const s = getComputedStyle(e);
        const filled = s.backgroundColor && !/rgba\(\d+, \d+, \d+, 0\)|transparent/.test(s.backgroundColor);
        return filled || s.backgroundImage !== 'none' || s.boxShadow !== 'none' || parseFloat(s.borderTopWidth) > 0 || parseFloat(s.borderTopLeftRadius) > 0;
      };
      let chain = [], index = 0;
      window.__bamCapture = {
        at(x, y) {
          chain = []; index = 0;
          let e = document.elementFromPoint(x, y);
          while (e && e !== document.documentElement) { chain.push(e); e = e.parentElement || (e.getRootNode && e.getRootNode().host) || null; }
          const area = innerWidth * innerHeight;
          const first = chain.findIndex(e => block(e) && e !== document.body);
          if (first < 0) return null;
          // Climb a few levels to the nearest block with its own box, unless it's most of the page.
          index = first;
          for (let i = first; i < Math.min(chain.length, first + 6); i++) {
            const e = chain[i]; if (e === document.body) break;
            if (block(e) && boxy(e) && box(e).w * box(e).h < area * 0.6) { index = i; break; }
          }
          // A block covering nearly the whole page is the page: keep the smaller one under it.
          if (box(chain[index]).w * box(chain[index]).h > area * 0.92 && index > 0) index -= 1;
          return box(chain[index]);
        },
        walk(direction) {
          if (!chain.length) return null;
          const current = box(chain[index]);
          if (direction === 'up') {
            while (index < chain.length - 1) { index += 1; if (chain[index] !== document.body && !same(box(chain[index]), current) && block(chain[index])) break; }
          } else {
            while (index > 0) { index -= 1; if (!same(box(chain[index]), current) && block(chain[index])) break; }
          }
          return box(chain[index]);
        }
      };
    }
    """#

    private var cssScale: CGFloat { (web?.pageZoom ?? 1) * (web?.magnification ?? 1) }

    private func hover(at point: NSPoint) {
        guard let web, let overlay, !overlay.isShowingResult else { return }
        let local = web.convert(point, from: overlay)
        hoverToken += 1; let token = hoverToken
        let scale = cssScale
        web.callAsyncJavaScript(Self.picker + "return window.__bamCapture.at(x, y);",
                                arguments: ["x": local.x / scale, "y": local.y / scale], in: nil, in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, token == self.hoverToken else { return }
                self.showBlock(try? result.get())
            }
        }
    }

    private func walk(_ direction: String) {
        guard let web else { return }
        hoverToken += 1; let token = hoverToken
        web.callAsyncJavaScript(Self.picker + "return window.__bamCapture.walk(direction);",
                                arguments: ["direction": direction], in: nil, in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, token == self.hoverToken else { return }
                if let value = try? result.get(), !(value is NSNull) { self.showBlock(value) }
            }
        }
    }

    /// CSS box → overlay rect, clipped to the visible page.
    private func showBlock(_ value: Any?) {
        guard let web, let overlay else { return }
        guard let box = value as? [String: Any], let x = (box["x"] as? NSNumber)?.doubleValue, let y = (box["y"] as? NSNumber)?.doubleValue,
              let w = (box["w"] as? NSNumber)?.doubleValue, let h = (box["h"] as? NSNumber)?.doubleValue else { overlay.setHighlight(nil); return }
        let scale = cssScale
        let inWeb = NSRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
        let rect = web.convert(inWeb, to: overlay).intersection(overlay.pageFrame)
        overlay.setHighlight(rect.width >= 4 && rect.height >= 4 ? rect : nil)
    }

    // MARK: Taking the picture

    private func captureHovered() {
        guard let rect = overlay?.highlight else { NSSound.beep(); return }
        capture(rect: rect)
    }

    private func capture(rect: NSRect) {
        guard let web, let overlay else { return }
        let area = rect.intersection(overlay.pageFrame)
        guard area.width >= 4, area.height >= 4 else { return }
        hoverToken += 1
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.convert(area, from: overlay)
        configuration.afterScreenUpdates = false
        web.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image, self.overlay === overlay else { NSSound.beep(); return }
                self.finish(image, outline: area)
            }
        }
    }

    private func captureFullPage() {
        guard let web, let overlay else { return }
        hoverToken += 1
        overlay.setBusy(true)
        web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.overlay === overlay else { return }
                overlay.setBusy(false)
                guard let data = try? result.get(), let image = Self.render(pdf: data) else { NSSound.beep(); return }
                self.finish(image, outline: overlay.pageFrame.insetBy(dx: 1, dy: 1))
            }
        }
    }

    /// The page's single tall PDF page as a 2x bitmap, capped so a very long page stays a sensible size.
    static func render(pdf data: Data) -> NSImage? {
        guard let rep = NSPDFImageRep(data: data) else { return nil }
        let size = rep.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(2, 16_000 / max(size.width, size.height))
        let pixels = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size); image.addRepresentation(bitmap)
        return image
    }

    private func finish(_ image: NSImage, outline: NSRect) {
        self.image = image
        let copied = writeToPasteboard(image)
        overlay?.showResult(outline: outline, copied: copied)
    }

    // MARK: Actions

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult private func writeToPasteboard(_ image: NSImage) -> Bool {
        guard let png = Self.pngData(image) else { return false }
        let pasteboard = owner?.pageCommandPasteboard ?? .general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        return pasteboard.setData(png, forType: .png) && pasteboard.setData(image.tiffRepresentation, forType: .tiff)
    }

    private func copyImage() {
        guard let image else { return }
        overlay?.flashCopied(writeToPasteboard(image))
    }

    private func save() {
        guard let image, let window = overlay?.window, let png = Self.pngData(image) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = Self.fileName(host: web?.url?.host)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic); self?.end() }
            catch { NSSound.beep() }
        }
    }

    static func fileName(host: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let site = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }.map { " \($0)" } ?? ""
        return "Capture\(site) \(formatter.string(from: date)).png"
    }

    private func share(from view: NSView) {
        guard let image else { return }
        NSSharingServicePicker(items: [image]).show(relativeTo: view.bounds, of: view, preferredEdge: .minX)
    }
}

/// The capture surface over the whole window: a dim veil with the chosen block
/// cut out and outlined, the hint at the bottom of the page, then the result
/// panel beside the picture.
@MainActor final class CaptureOverlayView: NSView {
    var onHover: ((NSPoint) -> Void)?
    var onClick: (() -> Void)?
    var onDrag: ((NSRect) -> Void)?
    var onRetake: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onShare: ((NSView) -> Void)?
    var onCancel: (() -> Void)?
    /// The page being captured; its frame (in this view) bounds hovering, dragging and the hint.
    weak var page: WKWebView? { didSet { needsLayout = true } }
    var pageFrame: NSRect {
        guard let page, page.window === window, window != nil else { return bounds }
        return page.convert(page.bounds, to: self)
    }
    private(set) var highlight: NSRect?
    private(set) var isShowingResult = false

    private let veil = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let hint = CaptureHintView()
    private var panel: CaptureResultPanel?
    private var dragStart: NSPoint?
    private var dragging = false
    private var spinner: NSProgressIndicator?
    private static let veilAlpha: CGFloat = 0.5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        veil.fillRule = .evenOdd
        veil.fillColor = NSColor.black.withAlphaComponent(Self.veilAlpha).cgColor
        layer?.addSublayer(veil)
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        outline.shadowColor = NSColor.black.cgColor; outline.shadowOpacity = 0.35; outline.shadowRadius = 3; outline.shadowOffset = .zero
        layer?.addSublayer(outline)
        addSubview(hint)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Capture. Click a block or drag an area of the page. Up arrow widens, F takes the whole page, Escape cancels.")
        updateVeil(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = hint.fittingSize
        hint.frame = NSRect(x: (pageFrame.midX - size.width / 2).rounded(), y: (pageFrame.maxY - size.height - 30).rounded(),
                            width: size.width, height: size.height)
        spinner?.frame = NSRect(x: pageFrame.midX - 16, y: pageFrame.midY - 16, width: 32, height: 32)
        updateVeil(animated: false)
        if let panel { place(panel) }
    }

    func setHighlight(_ rect: NSRect?) {
        guard rect != highlight else { return }
        highlight = rect
        updateVeil(animated: true)
    }

    private func updateVeil(animated: Bool) {
        let full = CGPath(rect: bounds, transform: nil)
        let veilPath = CGMutablePath(); veilPath.addPath(full)
        var outlinePath: CGPath?
        if let rect = highlight {
            let rounded = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            veilPath.addPath(rounded); outlinePath = rounded
        }
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !dragging
        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        if animate {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            for (layer, path) in [(veil, veilPath as CGPath), (outline, outlinePath ?? CGPath(rect: .zero, transform: nil))] {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = layer.presentation()?.path ?? layer.path
                animation.toValue = path
                layer.add(animation, forKey: "path")
            }
        }
        veil.path = veilPath
        outline.path = outlinePath
        outline.isHidden = outlinePath == nil
        CATransaction.commit()
    }

    func setBusy(_ busy: Bool) {
        if busy {
            let indicator = NSProgressIndicator(); indicator.style = .spinning; indicator.controlSize = .regular
            indicator.appearance = NSAppearance(named: .darkAqua)
            addSubview(indicator); indicator.startAnimation(nil); spinner = indicator; needsLayout = true
        } else { spinner?.removeFromSuperview(); spinner = nil }
    }

    // MARK: Result

    func showResult(outline rect: NSRect, copied: Bool) {
        isShowingResult = true
        highlight = rect
        hint.isHidden = true
        veil.fillColor = NSColor.clear.cgColor
        outline.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        updateVeil(animated: false)
        let panel = CaptureResultPanel(copied: copied)
        panel.onCopy = { [weak self] in self?.onCopy?() }
        panel.onSave = { [weak self] in self?.onSave?() }
        panel.onShare = { [weak self, weak panel] in if let panel { self?.onShare?(panel.shareRow) } }
        panel.onRetake = { [weak self] in self?.onRetake?() }
        addSubview(panel)
        self.panel = panel
        place(panel)
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
        NSAccessibility.post(element: panel, notification: .created)
    }

    func flashCopied(_ ok: Bool) { panel?.setStatus(copied: ok) }

    /// Arc puts the panel just right of the picture, top-aligned; left of it, or inside, when there's no room.
    private func place(_ panel: CaptureResultPanel) {
        guard let rect = highlight else { return }
        let size = panel.fittingSize, gap: CGFloat = 10
        let page = pageFrame
        var x = rect.maxX + gap, y = rect.minY
        if x + size.width > page.maxX - 8 { x = rect.minX - gap - size.width }
        if x < page.minX + 8 {   // no room either side (a full-page capture): inside, top-right
            x = min(rect.maxX, page.maxX) - size.width - 12; y = max(rect.minY, page.minY) + 12
        }
        y = min(max(y, page.minY + 12), page.maxY - size.height - 12)
        panel.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Pointer

    override func resetCursorRects() {
        guard !isShowingResult else { return }
        addCursorRect(pageFrame, cursor: Self.cameraCursor)
    }
    static let cameraCursor: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            guard let symbol = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return true }
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8); shadow.shadowBlurRadius = 2; shadow.set()
            let tinted = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard !isShowingResult else { return }
        let point = convert(event.locationInWindow, from: nil)
        if pageFrame.contains(point) { onHover?(point) } else { setHighlight(nil) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isShowingResult {
            if panel?.frame.contains(point) != true { onCancel?() }
            return
        }
        guard pageFrame.contains(point) else { onCancel?(); return }
        dragStart = point; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isShowingResult, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(point.x - start.x, point.y - start.y) < 4 { return }
        dragging = true
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        setHighlight(rect.intersection(pageFrame))
    }
    override func mouseUp(with event: NSEvent) {
        guard !isShowingResult, dragStart != nil else { return }
        defer { dragStart = nil; dragging = false }
        if dragging, let rect = highlight { onDrag?(rect) } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func scrollWheel(with event: NSEvent) {}
}

/// "Click or drag to capture a portion of this page", in Arc's white pill.
@MainActor final class CaptureHintView: NSView {
    private let label = NSTextField(labelWithString: "Click or drag to capture a portion of this page")
    private let keys = NSTextField(labelWithString: "↑ wider · F whole page · esc")
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 20; layer?.cornerCurve = .continuous
        shadow = { let s = NSShadow(); s.shadowBlurRadius = 16; s.shadowOffset = NSSize(width: 0, height: -4); s.shadowColor = NSColor.black.withAlphaComponent(0.25); return s }()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(srgbRed: 0.25, green: 0.33, blue: 0.93, alpha: 1)
        keys.font = .systemFont(ofSize: 12, weight: .regular)
        keys.textColor = NSColor(white: 0, alpha: 0.4)
        addSubview(label); addSubview(keys)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var fittingSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width + keys.intrinsicContentSize.width) + 18 * 2 + 14, height: 40)
    }
    override func layout() {
        super.layout()
        let main = label.intrinsicContentSize, extra = keys.intrinsicContentSize
        label.frame = NSRect(x: 18, y: ((bounds.height - main.height) / 2).rounded(), width: ceil(main.width), height: main.height)
        keys.frame = NSRect(x: label.frame.maxX + 14, y: ((bounds.height - extra.height) / 2).rounded() + 1, width: ceil(extra.width), height: extra.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The panel beside a capture: a "Copied" status row, then Copy, Save…, Share…
/// and Retake, styled like Arc's.
@MainActor final class CaptureResultPanel: NSVisualEffectView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onShare: (() -> Void)?
    var onRetake: (() -> Void)?
    private let status = CaptureRow(title: "Copied to Clipboard", symbol: "checkmark.circle.fill", shortcut: nil)
    private(set) var shareRow = CaptureRow(title: "Share…", symbol: "square.and.arrow.up", shortcut: nil)
    private var rows: [NSView] = []
    private var tint: NSView?
    private static let width: CGFloat = 200

    override var isFlipped: Bool { true }

    init(copied: Bool) {
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        layer?.borderWidth = 1; layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        let tint = NSView(); tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.55).cgColor
        tint.autoresizingMask = [.width, .height]; addSubview(tint); self.tint = tint
        status.isStatus = true
        let copy = CaptureRow(title: "Copy", symbol: "doc.on.doc", shortcut: "⌘C")
        let save = CaptureRow(title: "Save…", symbol: "square.and.arrow.down", shortcut: "⌘S")
        let retake = CaptureRow(title: "Retake", symbol: "arrow.counterclockwise", shortcut: "R")
        copy.action = { [weak self] in self?.onCopy?() }
        save.action = { [weak self] in self?.onSave?() }
        shareRow.action = { [weak self] in self?.onShare?() }
        retake.action = { [weak self] in self?.onRetake?() }
        rows = [status, Separator(), copy, save, shareRow, Separator(), retake]
        rows.forEach(addSubview)
        setStatus(copied: copied)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Capture")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setStatus(copied: Bool) {
        status.title = copied ? "Copied to Clipboard" : "Couldn’t copy"
        status.flash()
    }

    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: rows.reduce(10) { $0 + (($1 is Separator) ? 11 : 28) })
    }
    override func layout() {
        super.layout()
        tint?.frame = bounds
        var y: CGFloat = 5
        for row in rows {
            let height: CGFloat = row is Separator ? 11 : 28
            row.frame = NSRect(x: 5, y: y, width: bounds.width - 10, height: height)
            y += height
        }
    }

    final class Separator: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 1, alpha: 0.12).setFill()
            NSRect(x: 8, y: (bounds.midY).rounded(), width: bounds.width - 16, height: 1).fill()
        }
    }
}

/// One row of the result panel: icon, title, shortcut; highlighted under the pointer like a menu item.
@MainActor final class CaptureRow: NSView {
    var action: (() -> Void)?
    var isStatus = false { didSet { applyStyle() } }
    var title: String { get { label.stringValue } set { label.stringValue = newValue; setAccessibilityLabel(newValue) } }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true; applyStyle() } }
    override var isFlipped: Bool { true }

    init(title: String, symbol: String, shortcut: String?) {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        label.stringValue = title; label.font = .systemFont(ofSize: 13)
        key.stringValue = shortcut ?? ""; key.font = .systemFont(ofSize: 12); key.alignment = .right
        [icon, label, key].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func flash() {
        guard isStatus, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        alphaValue = 0.3
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; animator().alphaValue = 1 }
    }
    private func applyStyle() {
        let ink = hovered && !isStatus ? NSColor.white : NSColor(white: 1, alpha: isStatus ? 0.7 : 0.9)
        label.textColor = ink; key.textColor = NSColor(white: 1, alpha: hovered ? 0.85 : 0.45)
        icon.contentTintColor = isStatus ? NSColor.systemGreen : ink
        setAccessibilityRole(isStatus ? .staticText : .button)
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let lineHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 32, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width - 32 - (key.stringValue.isEmpty ? 8 : 44), height: lineHeight)
        key.frame = NSRect(x: bounds.width - 48, y: ((bounds.height - lineHeight) / 2).rounded() + 1, width: 40, height: lineHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hovered, !isStatus else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard !isStatus, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func accessibilityPerformPress() -> Bool { guard !isStatus else { return false }; action?(); return true }
}
