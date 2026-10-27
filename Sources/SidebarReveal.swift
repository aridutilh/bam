import AppKit
import QuartzCore

/// Arc's hidden-sidebar reveal. With the sidebar hidden (⌘S), resting the pointer at the window's left edge slides the
/// sidebar in as a floating card over the page; it slides away once the pointer leaves it. ⌘S while it floats pins it
/// back: the sidebar stays where it is and the page slides over to make room.
@MainActor extension BrowserController {
    static let floatingInset: CGFloat = 6
    /// How long the pointer rests at the edge before the sidebar comes, and lingers outside before it goes.
    static let floatingRevealDelay: TimeInterval = 0.08
    static let floatingDismissDelay: TimeInterval = 0.3
    static let floatingSlideDuration: TimeInterval = 0.2

    var isSidebarFloating: Bool { !session.sidebarVisible && floatingProgress > 0 }

    func configureFloatingSidebar() {
        floatingShell.isHidden = true
        floatingAnimator.animationView = root
        edgeZone.onEnter = { [weak self] in self?.pointerReachedEdge() }
        edgeZone.onExit = { [weak self] in self?.pointerLeftFloatingArea() }
        floatingShell.onEnter = { [weak self] in self?.cancelFloatingWork() }
        floatingShell.onExit = { [weak self] in self?.pointerLeftFloatingArea() }
    }

    func layoutFloatingSidebar(dockedWidth width: CGFloat, targetWidth: CGFloat, height h: CGFloat) {
        let canFloat = !session.sidebarVisible && spaceCreationPanel == nil
        edgeZone.frame = NSRect(x: 0, y: 0, width: 4, height: h)
        edgeZone.isHidden = !canFloat
        let inset = Self.floatingInset
        if pinningFromFloat {
            // Pinning back: the panel stays under the docked sidebar until the page has slid clear of it.
            floatingShell.isHidden = false
            // Opaque until done: the sidebar has no background of its own and the page slides out from under it.
            floatingShell.frame = NSRect(x: 0, y: 0, width: targetWidth, height: h)
            floatingShell.alphaValue = 1
            floatingShell.cornerRadius = 0
            if windowButtonOffset != .zero { windowButtonOffset = .zero; placeWindowButtons() }
            return
        }
        guard canFloat, floatingProgress > 0, width < 0.5 else {
            floatingShell.isHidden = true
            if windowButtonOffset != .zero { windowButtonOffset = .zero; placeWindowButtons() }
            return
        }
        let p = floatingProgress
        let frame = NSRect(x: inset - (1 - p) * (targetWidth + inset + 16), y: inset, width: targetWidth, height: h - 2 * inset)
        floatingShell.cornerRadius = 10
        floatingShell.alphaValue = 1
        floatingShell.frame = frame
        floatingShell.isHidden = false
        floatingShell.canvas.theme = root.theme
        floatingShell.canvas.space = root.space
        sidebar.frame = frame
        sidebar.isHidden = false
        // The window controls ride along with the card (they sit inside its top-left corner).
        windowButtonOffset = CGPoint(x: frame.minX, y: inset); placeWindowButtons()
        guard let window = view.window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.isHidden = p < 0.02; button.alphaValue = p
        }
    }

    private func cancelFloatingWork() { floatingRevealWork?.cancel(); floatingRevealWork = nil }

    private func pointerReachedEdge() {
        cancelFloatingWork()
        guard !session.sidebarVisible, spaceCreationPanel == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.setSidebarFloating(true) }
        floatingRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.floatingRevealDelay, execute: work)
    }

    private func pointerLeftFloatingArea() {
        cancelFloatingWork()
        guard !session.sidebarVisible else { return }
        // Still over the card or the edge (the pointer crossed from one to the other): stay.
        if let window = view.window {
            let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if (!floatingShell.isHidden && floatingShell.frame.insetBy(dx: -2, dy: -2).contains(point)) || edgeZone.frame.contains(point) { return }
        }
        let work = DispatchWorkItem { [weak self] in self?.setSidebarFloating(false) }
        floatingRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (floatingProgress > 0 ? Self.floatingDismissDelay : 0), execute: work)
    }

    /// Slides the floating sidebar in or out (instant with Reduce Motion).
    func setSidebarFloating(_ shown: Bool) {
        cancelFloatingWork()
        guard !session.sidebarVisible || !shown else { return }
        let target: CGFloat = shown ? 1 : 0
        guard floatingProgress != target || floatingAnimator.isRunning else { return }
        if shown { sidebar.layoutSubtreeIfNeeded() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.window == nil {
            floatingAnimator.stop(); floatingProgress = target; layoutBrowser(); return
        }
        // In: a quick ease-out, as Arc's card arrives. Out: ease-in, leaving faster at the end.
        floatingAnimator.animate(from: floatingProgress, to: target, duration: Self.floatingSlideDuration,
                                 controlPoints: shown ? (0.2, 0.8, 0.2, 1) : (0.4, 0, 0.8, 0.4), update: { [weak self] value in
            guard let self else { return }
            self.floatingProgress = value; self.layoutBrowser()
        })
    }
}

/// The floating sidebar's card: the Space's own canvas, rounded, with a soft shadow over the page.
@MainActor final class FloatingSidebarShell: NSView {
    let canvas = CanvasView()
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    var cornerRadius: CGFloat = 10 { didSet { canvas.layer?.cornerRadius = cornerRadius; layer?.shadowOpacity = cornerRadius > 0 ? 0.28 : 0 } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28; layer?.shadowRadius = 14; layer?.shadowOffset = CGSize(width: 0, height: -4)
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 10; canvas.layer?.masksToBounds = true; canvas.layer?.cornerCurve = .continuous
        canvas.layer?.borderWidth = 0.5
        addSubview(canvas)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); canvas.frame = bounds; updateBorder() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBorder() }
    private func updateBorder() {
        canvas.layer?.borderColor = (effectiveAppearance.isDarkChrome ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10)).cgColor
    }
    // The sidebar sits on top; the card itself never takes clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// A few points at the window's left edge that notice the pointer resting there while the sidebar is hidden.
/// Transparent to clicks: the page underneath keeps its own.
@MainActor final class SidebarEdgeZone: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
