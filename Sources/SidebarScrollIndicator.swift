import AppKit
import QuartzCore

/// The tab list's scroll thumb, drawn where Arc draws it: in the gap between the sidebar's rows and the page card,
/// never over a row, its title or its close button.
///
/// - The list itself has no system scroller (an overlay scroller can only sit inside the list, over the rows'
///   trailing points, and becomes a 15-point track over them when macOS shows scroll bars always).
/// - This view spans that gap column for the list's height. As AppKit's overlay thumb does, it appears only when the
///   list scrolls (or while dragged), stays while the pointer rests on it (and widens), then fades out. Pointing at
///   the gap at rest never reveals it: that gap is where the sidebar is resized.
/// - It claims mouse events only on the visible thumb. Everywhere else in the gap, the sidebar resize handle beneath
///   it keeps working.
@MainActor final class SidebarScrollIndicator: NSView {
    /// The list being shown. Its document view is flipped (an NSTableView), so offsets grow downward.
    weak var scrollView: NSScrollView? { didSet { if oldValue !== scrollView { lastOffset = nil; refresh() } } }
    /// Off while the sidebar is hidden, collapsing or paging between Spaces.
    var isSuppressed = false { didSet { if oldValue != isSuppressed { refresh() } } }
    /// True while the pointer is on the visible thumb or dragging it (the resize handle's own bar hides meanwhile).
    var onInteractionChange: ((Bool) -> Void)?
    private(set) var isInteracting = false { didSet { if oldValue != isInteracting { onInteractionChange?(isInteracting) } } }

    private let thumb = CALayer()
    private var knob: NSRect?
    private var lastOffset: CGFloat?
    private var overThumb = false, dragging = false, flashing = false
    private var dragStart: (pointerY: CGFloat, offset: CGFloat)?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        thumb.opacity = 0
        layer?.addSublayer(thumb)
        setAccessibilityElement(false)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    /// The thumb's rect in a column `trackHeight` tall, or nil when everything fits. Pure, for tests.
    static func knobRect(trackHeight: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat, offset: CGFloat,
                         width: CGFloat) -> NSRect? {
        let inset = ArkMetrics.scrollThumbInset
        let track = trackHeight - 2 * inset
        guard contentHeight > visibleHeight + 0.5, visibleHeight > 0, track > ArkMetrics.scrollThumbMinLength else { return nil }
        let length = max(ArkMetrics.scrollThumbMinLength, track * visibleHeight / contentHeight)
        let travel = max(0, contentHeight - visibleHeight)
        let progress = travel > 0 ? min(1, max(0, offset / travel)) : 0
        return NSRect(x: ArkMetrics.scrollThumbLead, y: inset + (track - length) * progress, width: width, height: length)
    }

    /// Re-reads the list's geometry and scroll position. Called on every scroll, layout and page change.
    func refresh() {
        guard let scroll = scrollView, let superview, !isSuppressed, !isHidden,
              let document = scroll.documentView else { knob = nil; setThumb(visible: false, animated: false); return }
        // Vertically, the column covers exactly the list's visible area.
        let list = scroll.convert(scroll.bounds, to: superview)
        if frame.minY != list.minY || frame.height != list.height {
            setFrameOrigin(NSPoint(x: frame.minX, y: list.minY)); setFrameSize(NSSize(width: frame.width, height: list.height))
        }
        let clip = scroll.contentView
        let width = (overThumb || dragging) ? ArkMetrics.scrollThumbHoverWidth : ArkMetrics.scrollThumbWidth
        knob = Self.knobRect(trackHeight: bounds.height, contentHeight: document.frame.height, visibleHeight: clip.bounds.height,
                             offset: clip.bounds.minY, width: width)
        if let knob {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            thumb.frame = knob; thumb.cornerRadius = knob.width / 2
            CATransaction.commit()
        }
        // A changed offset is a scroll: show the thumb, then fade it once scrolling rests.
        let offset = clip.bounds.minY
        if let lastOffset, abs(lastOffset - offset) > 0.25 { flash() }
        lastOffset = offset
        // Hover only holds a thumb that is already showing; it never reveals one.
        setThumb(visible: knob != nil && (flashing || dragging || overThumb), animated: true)
        isInteracting = knob != nil && (overThumb || dragging)
        window?.invalidateCursorRects(for: self)
    }

    private func flash() {
        flashing = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashing = false; self.refresh()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func setThumb(visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        guard thumb.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(visible ? 0.12 : 0.3)
        thumb.opacity = target
        CATransaction.commit()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = (overThumb || dragging) ? 0.6 : 0.42
            thumb.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }

    // MARK: Pointer

    /// Only a visible thumb takes the pointer; the rest of the gap belongs to the resize handle beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let knob, thumb.opacity > 0, let superview else { return nil }
        let local = convert(point, from: superview)
        // The thumb's whole column is its target, for its height: a thin thumb is still easy to grab.
        return NSRect(x: 0, y: knob.minY, width: bounds.width, height: knob.height).contains(local) ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { setOverThumb(false) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    private func pointerMoved(_ event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        // Only a thumb already on screen can be pointed at; at rest the column is the resize handle's.
        let showing = thumb.opacity > 0
        setOverThumb(showing && (knob.map { y >= $0.minY && y <= $0.maxY } ?? false))
    }
    private func setOverThumb(_ over: Bool) {
        guard over != overThumb else { return }
        overThumb = over
        if over { hideWork?.cancel(); flashing = false } else if !dragging { flash() }
        updateColor(); refresh()
    }
    override func resetCursorRects() { if let knob { addCursorRect(NSRect(x: 0, y: knob.minY, width: bounds.width, height: knob.height), cursor: .arrow) } }

    override func mouseDown(with event: NSEvent) {
        guard let clip = scrollView?.contentView else { return }
        dragging = true; updateColor()
        dragStart = (convert(event.locationInWindow, from: nil).y, clip.bounds.minY)
        refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scroll = scrollView, let document = scroll.documentView, let knob else { return }
        let clip = scroll.contentView
        let travel = max(0, document.frame.height - clip.bounds.height)
        let track = bounds.height - 2 * ArkMetrics.scrollThumbInset - knob.height
        guard travel > 0, track > 0 else { return }
        let delta = convert(event.locationInWindow, from: nil).y - start.pointerY
        let offset = min(travel, max(0, start.offset + delta * travel / track))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offset))
        scroll.reflectScrolledClipView(clip)
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false; dragStart = nil; updateColor(); flash(); refresh()
    }
}
