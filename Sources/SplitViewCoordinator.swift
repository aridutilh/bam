import AppKit
import WebKit

/// Native two-pane presentation. BrowserController retains tab/session ownership
/// and navigation delegates; this coordinator only hosts the existing web views.
@MainActor final class SplitViewCoordinator: NSObject, NSSplitViewDelegate {
    enum Side: Int, CaseIterable { case left, right }

    var view: NSView { splitView }
    private(set) var focusedSide: Side = .left
    var onNavigate: ((Side, URL) -> Void)?
    var onBack: ((Side) -> Void)?
    var onForward: ((Side) -> Void)?
    var onReload: ((Side) -> Void)?
    var onFocus: ((Side) -> Void)?
    var onClose: ((Side) -> Void)?
    var onUnsplit: (() -> Void)?
    var onReturnVideo: ((Side) -> Void)?

    private let splitView = OrbitNativeSplitView(frame: .zero)
    private let leftPane = OrbitSplitPane(side: .left)
    private let rightPane = OrbitSplitPane(side: .right)
    private var dividerFraction: CGFloat = 0.5
    private var isLayingOut = false
    private var eventMonitor: Any?
    private var focusObserver: NSObjectProtocol?

    override init() {
        super.init()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]
        splitView.setAccessibilityLabel("Split browser view")
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.layoutPanes = { [weak self] in self?.layoutPanes() }
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
            guard let self, let window = self.splitView.window, event.window === window, !self.splitView.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.splitView.convert(event.locationInWindow, from: nil)
            guard self.splitView.bounds.contains(point) else { return event }
            if self.leftPane.frame.contains(point) { self.setFocusedSide(.left) }
            else if self.rightPane.frame.contains(point) { self.setFocusedSide(.right) }
            return event
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.splitView.window else { return }
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

    private func pane(for side: Side) -> OrbitSplitPane { side == .left ? leftPane : rightPane }
    private func refreshFocusAppearance() {
        leftPane.isFocused = focusedSide == .left
        rightPane.isFocused = focusedSide == .right
    }
    private func synchronizeResponderFocus(in window: NSWindow) {
        guard !splitView.isHiddenOrHasHiddenAncestor else { return }
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

    private var availableWidth: CGFloat { max(0, splitView.bounds.width - splitView.dividerThickness) }
    private var minimumPaneWidth: CGFloat { min(200, availableWidth / 2) }
    private func layoutPanes() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let available = availableWidth
        let width = min(max(minimumPaneWidth, available * dividerFraction), max(0, available - minimumPaneWidth))
        leftPane.frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
        rightPane.frame = NSRect(x: width + splitView.dividerThickness, y: 0, width: max(0, available - width), height: splitView.bounds.height)
        leftPane.needsLayout = true; rightPane.needsLayout = true
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(proposedMinimumPosition, minimumPaneWidth) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(proposedMaximumPosition, availableWidth - minimumPaneWidth) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isLayingOut, availableWidth > 0 else { return }
        dividerFraction = min(1, max(0, leftPane.frame.width / availableWidth))
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
}

@MainActor private final class OrbitNativeSplitView: NSSplitView {
    var layoutPanes: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutPanes?() }
}

@MainActor private final class OrbitSplitAddressField: NSTextField {
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

@MainActor private final class OrbitSplitPane: NSView, NSTextFieldDelegate {
    let side: SplitViewCoordinator.Side
    var onFocus: (() -> Void)?
    var onSubmit: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onClose: (() -> Void)?
    var onUnsplit: (() -> Void)?
    var onReturnVideo: (() -> Void)?
    var isFocused = false { didSet { needsDisplay = true } }
    private weak var webView: WKWebView?
    private let content = NSView()
    private let address = OrbitSplitAddressField()
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private let close = NSButton()
    private let unsplit = NSButton()
    private let placeholder = NSTextField(labelWithString: "Video is playing in Picture in Picture")
    private let returnVideo = NSButton(title: "Return Video", target: nil, action: nil)
    private var latestAddress = ""
    private var isEditingAddress = false
    override var isFlipped: Bool { true }

    init(side: SplitViewCoordinator.Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityLabel(side == .left ? "Left browser pane" : "Right browser pane")
        for subview in [content, address, back, forward, reload, close, unsplit] { addSubview(subview) }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        content.addSubview(placeholder); content.addSubview(returnVideo)
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 3
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        returnVideo.bezelStyle = .rounded
        returnVideo.target = self; returnVideo.action = #selector(returnVideoPressed)
        address.isEditable = true; address.isSelectable = true
        address.isBordered = true; address.bezelStyle = .roundedBezel
        address.font = .systemFont(ofSize: 11)
        address.placeholderString = "Search or enter URL"
        address.lineBreakMode = .byTruncatingMiddle
        address.setAccessibilityLabel(side == .left ? "Left pane address" : "Right pane address")
        address.delegate = self; address.target = self; address.action = #selector(submitAddress)
        address.escape = { [weak self] in guard let self else { return }; self.finishEditing(address: self.latestAddress) }
        setup(back, symbol: "chevron.left", label: "Back", action: #selector(backPressed))
        setup(forward, symbol: "chevron.right", label: "Forward", action: #selector(forwardPressed))
        setup(reload, symbol: "arrow.clockwise", label: "Reload", action: #selector(reloadPressed))
        setup(close, symbol: "xmark", label: "Close this pane", action: #selector(closePressed))
        setup(unsplit, symbol: "rectangle", label: "Return to a single tab", action: #selector(unsplitPressed))
        unsplit.isHidden = side == .left
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func setup(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false; button.bezelStyle = .inline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = self; button.action = action
        button.toolTip = label; button.setAccessibilityLabel(label)
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
        address.toolTip = title.isEmpty ? value : "\(title)\n\(value)"
        if !isEditingAddress { address.stringValue = value == "orbit://newtab" ? "" : value }
    }
    func updateNavigation(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        back.isEnabled = canGoBack; forward.isEnabled = canGoForward
        let label = isLoading ? "Stop loading" : "Reload"
        reload.image = NSImage(systemSymbolName: isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: label)
        reload.toolTip = label; reload.setAccessibilityLabel(label)
    }
    func focusAddress() {
        onFocus?()
        address.stringValue = latestAddress == "orbit://newtab" ? "" : latestAddress
        isEditingAddress = true
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
        isEditingAddress = false
        // AppKit sends this notification before the Return target/action.
        // Preserve the typed value until submitAddress consumes it.
        let movement = (obj.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        if movement == NSTextMovement.return.rawValue { return }
        address.stringValue = latestAddress == "orbit://newtab" ? "" : latestAddress
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(address: latestAddress); return true }
        return false
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        let chrome: CGFloat = 36
        content.frame = NSRect(x: 0, y: chrome, width: width, height: max(0, bounds.height - chrome))
        back.frame = NSRect(x: 4, y: 7, width: 20, height: 22)
        forward.frame = NSRect(x: 25, y: 7, width: 20, height: 22)
        reload.frame = NSRect(x: 46, y: 7, width: 20, height: 22)
        let trailing: CGFloat = side == .right ? 52 : 28
        address.frame = NSRect(x: 70, y: 6, width: max(30, width - 76 - trailing), height: 24)
        close.frame = NSRect(x: max(0, width - 25), y: 7, width: 20, height: 22)
        unsplit.frame = NSRect(x: max(0, width - 49), y: 7, width: 20, height: 22)
        if let web = webView, web.superview === content { web.frame = content.bounds }
        placeholder.frame = NSRect(x: 12, y: content.bounds.midY + 4, width: max(0, width - 24), height: 54)
        returnVideo.frame = NSRect(x: max(6, (width - 130) / 2), y: content.bounds.midY - 34, width: min(130, max(0, width - 12)), height: 30)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.65) : NSColor.separatorColor).setFill()
        NSRect(x: 0, y: 35, width: bounds.width, height: 1).fill()
    }
    @objc private func submitAddress() { onSubmit?(address.stringValue) }
    @objc private func backPressed() { onBack?() }
    @objc private func forwardPressed() { onForward?() }
    @objc private func reloadPressed() { onReload?() }
    @objc private func closePressed() { onClose?() }
    @objc private func unsplitPressed() { onUnsplit?() }
    @objc private func returnVideoPressed() { onReturnVideo?() }
}
