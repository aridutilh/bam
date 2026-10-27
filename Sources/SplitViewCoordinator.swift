import AppKit
import WebKit

/// Two panes as separate cards with a gap between them, each with its own slim bar, like the
/// reference's Split View (measured from 2x captures: 10-point gap, 10-point corners, 32-point
/// bar, a thin ring in the Space's color on the focused pane, the gap itself is the divider).
/// BrowserController retains tab/session ownership and navigation delegates; this coordinator
/// only hosts the existing web views.
@MainActor final class SplitViewCoordinator: NSObject {
    enum Side: Int, CaseIterable { case left, right }
    static let gap: CGFloat = 10
    static let minimumPaneWidth: CGFloat = 220

    var view: NSView { container }
    private(set) var focusedSide: Side = .left
    var onNavigate: ((Side, URL) -> Void)?
    var onBack: ((Side) -> Void)?
    var onForward: ((Side) -> Void)?
    var onReload: ((Side) -> Void)?
    var onFocus: ((Side) -> Void)?
    var onClose: ((Side) -> Void)?
    var onUnsplit: (() -> Void)?
    var onReturnVideo: ((Side) -> Void)?
    /// The left pane's share of the width changed by a drag (0…1); the browser saves it with the Split.
    var onRatioChange: ((CGFloat) -> Void)?
    /// The focused pane's ring: the Space's color.
    var accent: NSColor = .controlAccentColor { didSet { refreshFocusAppearance() } }
    /// The left pane's share of the width (0…1).
    var ratio: CGFloat {
        get { dividerFraction }
        set { let clamped = newValue.isFinite ? min(0.9, max(0.1, newValue)) : 0.5
              if clamped != dividerFraction { dividerFraction = clamped; layoutPanes() } }
    }

    private let container = SplitContainer()
    private let leftPane = OrbitSplitPane(side: .left)
    private let rightPane = OrbitSplitPane(side: .right)
    private let gapView = SplitGap()
    private var dividerFraction: CGFloat = 0.5
    private var eventMonitor: Any?
    private var focusObserver: NSObjectProtocol?

    override init() {
        super.init()
        container.autoresizingMask = [.width, .height]
        container.setAccessibilityLabel("Split browser view")
        container.addSubview(leftPane); container.addSubview(rightPane); container.addSubview(gapView)
        container.layoutPanes = { [weak self] in self?.layoutPanes() }
        gapView.onDrag = { [weak self] x in self?.dragDivider(to: x) }
        gapView.onDragEnded = { [weak self] in guard let self else { return }; self.onRatioChange?(self.dividerFraction) }
        for pane in [leftPane, rightPane] {
            pane.onFocus = { [weak self, weak pane] in guard let pane else { return }; self?.setFocusedSide(pane.side) }
            pane.onSubmit = { [weak self, weak pane] text in
                guard let self, let pane else { return }
                guard let address = URLInput.resolve(text), let url = URL(string: address) else { NSSound.beep(); return }
                self.setFocusedSide(pane.side)
                pane.finishEditing(address: address)
                self.onNavigate?(pane.side, url)
            }
            pane.onBack = { [weak self, weak pane] in guard let self, let pane else { return }; self.setFocusedSide(pane.side); self.onBack?(pane.side) }
            pane.onForward = { [weak self, weak pane] in guard let self, let pane else { return }; self.setFocusedSide(pane.side); self.onForward?(pane.side) }
            pane.onReload = { [weak self, weak pane] in guard let self, let pane else { return }; self.setFocusedSide(pane.side); self.onReload?(pane.side) }
            pane.onClose = { [weak self, weak pane] in guard let self, let pane else { return }; self.setFocusedSide(pane.side); self.onClose?(pane.side) }
            pane.onUnsplit = { [weak self] in self?.onUnsplit?() }
            pane.onReturnVideo = { [weak self, weak pane] in guard let self, let pane else { return }; self.setFocusedSide(pane.side); self.onReturnVideo?(pane.side) }
        }
        refreshFocusAppearance()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.container.window, event.window === window, !self.container.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.container.convert(event.locationInWindow, from: nil)
            guard self.container.bounds.contains(point) else { return event }
            if self.leftPane.frame.contains(point) { self.setFocusedSide(.left) }
            else if self.rightPane.frame.contains(point) { self.setFocusedSide(.right) }
            return event
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.container.window else { return }
                self.synchronizeResponderFocus(in: window)
            }
        }
    }

    /// Passing nil creates a PiP placeholder. Repeating configure with the same
    /// hosted web view does not detach/reparent it or reset its navigation state.
    func configure(left: WKWebView?, right: WKWebView?, leftAddress: String, rightAddress: String) {
        leftPane.host(left); rightPane.host(right)
        leftPane.updateAddress(leftAddress, title: left?.title ?? "")
        rightPane.updateAddress(rightAddress, title: right?.title ?? "")
        leftPane.updateNavigation(canGoBack: left?.canGoBack ?? false, canGoForward: left?.canGoForward ?? false, isLoading: left?.isLoading ?? false)
        rightPane.updateNavigation(canGoBack: right?.canGoBack ?? false, canGoForward: right?.canGoForward ?? false, isLoading: right?.isLoading ?? false)
        layoutPanes()
    }

    /// KVO/title/progress refreshes do not move views or overwrite address edits.
    func updateMetadata(side: Side, address: String, title: String, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        let pane = pane(for: side)
        pane.updateAddress(address, title: title)
        pane.updateNavigation(canGoBack: canGoBack, canGoForward: canGoForward, isLoading: isLoading)
    }

    func focusAddress(_ side: Side) {
        setFocusedSide(side)
        pane(for: side).focusAddress()
    }

    /// Updates the selected pane without stealing keyboard focus. Useful when a
    /// controller restores a split group's remembered selection.
    func setFocusedSide(_ side: Side) {
        guard focusedSide != side else { return }
        focusedSide = side
        refreshFocusAppearance()
        onFocus?(side)
    }

    /// Only removes web views currently hosted here. A web view moved to PiP is
    /// never pulled out of that window, even if a stale weak reference remains.
    @discardableResult func detach() -> [Side: WKWebView] {
        var result: [Side: WKWebView] = [:]
        for pane in [leftPane, rightPane] {
            if let web = pane.detach() { result[pane.side] = web }
        }
        return result
    }

    /// A pane's frame in another view's coordinates (where the command bar centres over a new pane).
    func paneFrame(_ side: Side, in other: NSView) -> NSRect { other.convert(pane(for: side).frame, from: container) }
    private func pane(for side: Side) -> OrbitSplitPane { side == .left ? leftPane : rightPane }
    private func refreshFocusAppearance() {
        leftPane.setFocused(focusedSide == .left, accent: accent)
        rightPane.setFocused(focusedSide == .right, accent: accent)
    }
    private func synchronizeResponderFocus(in window: NSWindow) {
        guard !container.isHiddenOrHasHiddenAncestor else { return }
        var responder = window.firstResponder
        // AppKit's field editor is owned by the window, not by the text field.
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField { responder = field }
        var candidate = responder as? NSView
        while let current = candidate {
            if current === leftPane { setFocusedSide(.left); return }
            if current === rightPane { setFocusedSide(.right); return }
            candidate = current.superview
        }
    }

    private var availableWidth: CGFloat { max(0, container.bounds.width - Self.gap) }
    private var minimumWidth: CGFloat { min(Self.minimumPaneWidth, availableWidth / 2) }
    private func layoutPanes() {
        let available = availableWidth, height = container.bounds.height
        let width = min(max(minimumWidth, (available * dividerFraction).rounded()), max(0, available - minimumWidth))
        leftPane.frame = NSRect(x: 0, y: 0, width: width, height: height)
        gapView.frame = NSRect(x: width, y: 0, width: Self.gap, height: height)
        rightPane.frame = NSRect(x: width + Self.gap, y: 0, width: max(0, available - width), height: height)
    }
    /// Follows the pointer with the gap's middle; the panes keep their minimum width.
    private func dragDivider(to x: CGFloat) {
        guard availableWidth > 0 else { return }
        let left = min(max(minimumWidth, x - Self.gap / 2), availableWidth - minimumWidth)
        dividerFraction = left / availableWidth
        layoutPanes()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
}

/// Holds the panes; transparent, so the window shows in the gap between them.
@MainActor private final class SplitContainer: NSView {
    var layoutPanes: (() -> Void)?
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutPanes?() }
    override func layout() { super.layout(); layoutPanes?() }
}

/// The gap between the panes is the divider: point at it for the resize cursor, drag to move it.
@MainActor private final class SplitGap: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { onDragEnded?() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Split divider" }
}

/// Draws only; clicks go to the page under it.
@MainActor private final class SplitPassThrough: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class OrbitSplitAddressField: NSTextField {
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

/// Split's pane colors: a slim bar a shade off the page, a hairline under it.
@MainActor private enum SplitTone {
    static let bar = NSColor.chrome(light: NSColor(white: 0.975, alpha: 1), dark: NSColor(white: 0.13, alpha: 1))
    static let line = NSColor.chrome(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07))
    static let edge = NSColor.chrome(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.09))
    static func ink(_ alpha: CGFloat) -> NSColor {
        .chrome(light: NSColor(white: 0.1, alpha: alpha), dark: NSColor(white: 1, alpha: alpha))
    }
}

/// One small symbol button in a pane's bar.
@MainActor private final class SplitBarButton: NSButton {
    private var hovering = false
    var dimmed = false { didSet { paint() } }
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 6
        configure(symbol: symbol, label: label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        toolTip = label; setAccessibilityLabel(label)
        paint()
    }
    private func paint() {
        contentTintColor = SplitTone.ink(!isEnabled ? 0.22 : (dimmed ? 0.5 : 0.7))
        layer?.backgroundColor = hovering && isEnabled ? resolvedCGColor(SplitTone.ink(0.08), for: self) : NSColor.clear.cgColor
    }
    override var isEnabled: Bool { didSet { paint() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }
}

/// The pane's site in the middle of its bar: a link symbol and the host; click it to edit the address.
@MainActor private final class SplitSiteButton: NSButton {
    var host = "" { didSet { paint() } }
    var dimmed = false { didSet { paint() } }
    init() {
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true; layer?.cornerRadius = 6
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading; imageHugsTitle = true
        lineBreakMode = .byTruncatingTail
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        let ink = SplitTone.ink(dimmed ? 0.5 : 0.85)
        image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        contentTintColor = SplitTone.ink(dimmed ? 0.35 : 0.55)
        attributedTitle = NSAttributedString(string: host.isEmpty ? "Search or Enter URL…" : " " + host, attributes: [
            .font: BamType.sans(12.5, weight: .medium), .foregroundColor: host.isEmpty ? SplitTone.ink(0.4) : ink])
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

@MainActor private final class OrbitSplitPane: NSView, NSTextFieldDelegate {
    static let barHeight: CGFloat = 32
    let side: SplitViewCoordinator.Side
    var onFocus: (() -> Void)?
    var onSubmit: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onClose: (() -> Void)?
    var onUnsplit: (() -> Void)?
    var onReturnVideo: (() -> Void)?
    private(set) var isFocused = false
    private weak var webView: WKWebView?
    private let bar = NSView()
    private let line = NSView()
    private let content = NSView()
    private let ring = SplitPassThrough()
    private let address = OrbitSplitAddressField()
    private let site = SplitSiteButton()
    private let back = SplitBarButton(symbol: "arrow.left", label: "Back")
    private let forward = SplitBarButton(symbol: "arrow.right", label: "Forward")
    private let reload = SplitBarButton(symbol: "arrow.clockwise", label: "Reload")
    private let close = SplitBarButton(symbol: "xmark", label: "Close this pane")
    private let unsplit = SplitBarButton(symbol: "rectangle.split.2x1", label: "Separate Split into Tabs")
    private let placeholder = NSTextField(labelWithString: "Video is playing in Picture in Picture")
    private let returnVideo = NSButton(title: "Return Video", target: nil, action: nil)
    private var latestAddress = ""
    private var isEditingAddress = false { didSet { address.isHidden = !isEditingAddress; site.isHidden = isEditingAddress } }
    private var accent: NSColor = .controlAccentColor
    override var isFlipped: Bool { true }

    init(side: SplitViewCoordinator.Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10; layer?.masksToBounds = true
        setAccessibilityLabel(side == .left ? "Left browser pane" : "Right browser pane")
        for subview in [content, bar, line] { addSubview(subview) }
        for control in [back, forward, reload, site, address, unsplit, close] as [NSView] { bar.addSubview(control) }
        bar.wantsLayer = true; line.wantsLayer = true; content.wantsLayer = true
        // The focus ring sits above the page, inside the rounded card.
        ring.wantsLayer = true; ring.layer?.cornerRadius = 10; ring.layer?.borderWidth = 1
        addSubview(ring, positioned: .above, relativeTo: nil)
        content.addSubview(placeholder); content.addSubview(returnVideo)
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 3
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        returnVideo.bezelStyle = .rounded
        returnVideo.target = self; returnVideo.action = #selector(returnVideoPressed)
        address.isEditable = true; address.isSelectable = true
        address.isBordered = false; address.drawsBackground = false; address.focusRingType = .none
        address.font = BamType.sans(12.5, weight: .medium); address.alignment = .center
        address.placeholderString = "Search or Enter URL…"
        address.lineBreakMode = .byTruncatingMiddle
        (address.cell as? NSTextFieldCell)?.isScrollable = true
        address.setAccessibilityLabel(side == .left ? "Left pane address" : "Right pane address")
        address.delegate = self; address.target = self; address.action = #selector(submitAddress)
        address.escape = { [weak self] in guard let self else { return }; self.finishEditing(address: self.latestAddress) }
        address.isHidden = true
        site.target = self; site.action = #selector(editAddress)
        site.setAccessibilityLabel(side == .left ? "Left pane site; click to edit the address" : "Right pane site; click to edit the address")
        for (button, action) in [(back, #selector(backPressed)), (forward, #selector(forwardPressed)), (reload, #selector(reloadPressed)),
                                 (close, #selector(closePressed)), (unsplit, #selector(unsplitPressed))] {
            button.target = self; button.action = action
        }
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
        bar.layer?.backgroundColor = resolvedCGColor(SplitTone.bar, for: self)
        line.layer?.backgroundColor = resolvedCGColor(SplitTone.line, for: self)
        content.layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
        ring.layer?.borderColor = isFocused ? resolvedCGColor(accent.withAlphaComponent(0.7), for: self) : resolvedCGColor(SplitTone.edge, for: self)
        ring.layer?.borderWidth = isFocused ? 1.5 : 1
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    /// The focused pane shows its ring and its full bar; the other's bar steps back.
    func setFocused(_ focused: Bool, accent: NSColor) {
        isFocused = focused; self.accent = accent
        for button in [back, forward, close] { button.dimmed = !focused }
        site.dimmed = !focused
        reload.isHidden = !focused; unsplit.isHidden = !focused
        applyColors()
        needsLayout = true
    }

    func host(_ web: WKWebView?) {
        if webView !== web {
            if let current = webView, current.superview === content { current.removeFromSuperview() }
            webView = web
        }
        if let web {
            if web.superview !== content { content.addSubview(web) }
            web.autoresizingMask = [.width, .height]
            web.frame = content.bounds
        }
        placeholder.isHidden = web != nil
        returnVideo.isHidden = web != nil
        needsLayout = true
    }
    func detach() -> WKWebView? {
        let owned = webView.flatMap { $0.superview === content ? $0 : nil }
        owned?.removeFromSuperview()
        webView = nil
        return owned
    }
    func updateAddress(_ value: String, title: String) {
        latestAddress = value
        let shown = value == "orbit://newtab" ? "" : value
        site.host = URL(string: shown)?.host?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? shown
        site.toolTip = title.isEmpty ? shown : "\(title)\n\(shown)"
        if !isEditingAddress { address.stringValue = shown }
        needsLayout = true
    }
    func updateNavigation(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        back.isEnabled = canGoBack; forward.isEnabled = canGoForward
        reload.configure(symbol: isLoading ? "xmark" : "arrow.clockwise", label: isLoading ? "Stop loading" : "Reload")
    }
    func focusAddress() {
        onFocus?()
        address.stringValue = latestAddress == "orbit://newtab" ? "" : latestAddress
        isEditingAddress = true
        needsLayout = true; layoutSubtreeIfNeeded()
        window?.makeFirstResponder(address)
        address.selectText(nil)
    }
    func finishEditing(address value: String) {
        isEditingAddress = false
        latestAddress = value
        address.stringValue = value == "orbit://newtab" ? "" : value
        if let web = webView, web.superview === content { window?.makeFirstResponder(web) }
        else { window?.makeFirstResponder(returnVideo) }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { isEditingAddress = true; onFocus?() }
    func controlTextDidEndEditing(_ obj: Notification) {
        // AppKit sends this notification before the Return target/action.
        // Preserve the typed value until submitAddress consumes it.
        let movement = (obj.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        if movement == NSTextMovement.return.rawValue { return }
        isEditingAddress = false
        address.stringValue = latestAddress == "orbit://newtab" ? "" : latestAddress
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(address: latestAddress); return true }
        return false
    }
    override func layout() {
        super.layout()
        let width = bounds.width, barHeight = Self.barHeight
        bar.frame = NSRect(x: 0, y: 0, width: width, height: barHeight)
        line.frame = NSRect(x: 0, y: barHeight - 1, width: width, height: 1)
        content.frame = NSRect(x: 0, y: barHeight, width: width, height: max(0, bounds.height - barHeight))
        ring.frame = bounds
        let size: CGFloat = 24, y = (barHeight - size) / 2
        var x: CGFloat = 8
        back.frame = NSRect(x: x, y: y, width: size, height: size); x += size + 2
        forward.frame = NSRect(x: x, y: y, width: size, height: size); x += size + 2
        if !reload.isHidden { reload.frame = NSRect(x: x, y: y, width: size, height: size); x += size + 2 }
        let leftEnd = x + 6
        var right = width - 8
        close.frame = NSRect(x: right - size, y: y, width: size, height: size); right -= size + 2
        if !unsplit.isHidden { unsplit.frame = NSRect(x: right - size, y: y, width: size, height: size); right -= size + 2 }
        let rightStart = right - 6
        // The site sits centered in the bar when there is room, else in the gap between the controls.
        let gap = NSRect(x: leftEnd, y: y, width: max(0, rightStart - leftEnd), height: size)
        let siteWidth = min(gap.width, site.intrinsicContentSize.width + 16)
        let siteX = min(max(width / 2 - siteWidth / 2, gap.minX), max(gap.minX, gap.maxX - siteWidth))
        site.frame = NSRect(x: siteX, y: y, width: siteWidth, height: size)
        address.frame = gap.insetBy(dx: 0, dy: 4)
        if let web = webView, web.superview === content { web.frame = content.bounds }
        placeholder.frame = NSRect(x: 12, y: content.bounds.midY + 4, width: max(0, width - 24), height: 54)
        returnVideo.frame = NSRect(x: max(6, (width - 130) / 2), y: content.bounds.midY - 34, width: min(130, max(0, width - 12)), height: 30)
    }
    @objc private func editAddress() { focusAddress() }
    @objc private func submitAddress() { onSubmit?(address.stringValue) }
    @objc private func backPressed() { onBack?() }
    @objc private func forwardPressed() { onForward?() }
    @objc private func reloadPressed() { onReload?() }
    @objc private func closePressed() { onClose?() }
    @objc private func unsplitPressed() { onUnsplit?() }
    @objc private func returnVideoPressed() { onReturnVideo?() }
}
