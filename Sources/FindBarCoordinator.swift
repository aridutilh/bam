import AppKit
import WebKit

/// Native WebKit find. WKFindResult exposes matchFound, not a total match count.
/// https://developer.apple.com/documentation/webkit/wkfindconfiguration
@MainActor final class FindBarCoordinator: NSObject, NSSearchFieldDelegate {
    var view: NSView { overlay }
    var isVisible: Bool { overlay.superview != nil && !overlay.isHidden }
    private(set) var matchFound: Bool?
    var statusText: String { overlay.status.stringValue }
    var searchText: String {
        get { overlay.search.stringValue }
        set {
            overlay.search.stringValue = newValue
            findNext()
        }
    }

    private let overlay = FindBarOverlay(frame: .zero)
    private weak var web: WKWebView?
    private var generation: UInt = 0
    private var pendingSearch: DispatchWorkItem?
    private var loadingObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    override init() {
        super.init()
        overlay.isHidden = true
        overlay.search.delegate = self
        overlay.previous.target = self; overlay.previous.action = #selector(previousAction)
        overlay.next.target = self; overlay.next.action = #selector(nextAction)
        overlay.close.target = self; overlay.close.action = #selector(closeAction)
    }

    /// Supply the page's card as host. The bar leaves its top 36 points unobstructed.
    func show(in host: NSView, web: WKWebView) {
        _ = attach(in: host, web: web)
        findNext()
        host.window?.makeFirstResponder(overlay.search)
        overlay.search.selectText(nil)
    }

    /// Command-G moves the existing query to the current window and performs
    /// exactly one search in the requested direction, without stealing page focus.
    func continueFind(in host: NSView, web: WKWebView, backwards: Bool) {
        let wasVisible = isVisible
        _ = attach(in: host, web: web)
        findNext(backwards: backwards)
        if !wasVisible && searchText.isEmpty {
            host.window?.makeFirstResponder(overlay.search)
        }
    }

    /// Controller refreshes keep the bar's host and page together, preserving focus.
    func synchronize(in host: NSView, web: WKWebView) {
        guard isVisible else { return }
        if attach(in: host, web: web) { findNext() }
    }

    @discardableResult private func attach(in host: NSView, web: WKWebView) -> Bool {
        let changed = overlay.superview !== host || self.web !== web
        if overlay.superview !== host {
            overlay.removeFromSuperview()
            overlay.frame = host.bounds
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.isHidden = false
        retarget(web: web, performSearch: false)
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        if changed || keyMonitor == nil { installKeyboardHandling() }
        return changed
    }

    /// Keeps the query, but invalidates all results from the previously selected page.
    func retarget(web: WKWebView?, performSearch: Bool = true) {
        guard self.web !== web else { return }
        invalidateSearch()
        clearHighlight(in: self.web)
        loadingObservation = nil
        self.web = web
        overlay.search.isEnabled = web != nil
        if let web {
            loadingObservation = web.observe(\.isLoading, options: [.new]) { [weak self, weak web] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let web, self.web === web, self.isVisible else { return }
                    if web.isLoading {
                        self.invalidateSearch()
                        self.setStatus(self.searchText.isEmpty ? "Find in page" : "Loading page…")
                    } else {
                        self.findNext()
                    }
                }
            }
        }
        if performSearch { findNext() }
    }

    func hide() {
        let wasVisible = isVisible
        let target = web
        let window = overlay.window
        invalidateSearch()
        clearHighlight(in: target)
        loadingObservation = nil
        web = nil
        overlay.isHidden = true
        overlay.removeFromSuperview()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        setStatus("Find in page")
        if wasVisible, let target, target.window === window {
            window?.makeFirstResponder(target)
        }
    }

    func findNext(backwards: Bool = false) {
        invalidateSearch()
        guard isVisible else { return }
        guard let web else { setStatus("No page"); return }
        let query = searchText
        guard !query.isEmpty else {
            clearHighlight(in: web)
            setStatus("Find in page")
            return
        }
        guard !web.isLoading else { setStatus("Loading page…"); return }
        let request = generation
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = false
        configuration.wraps = true
        configuration.backwards = backwards
        setStatus("Searching…")
        web.find(query, configuration: configuration) { [weak self, weak web] result in
            guard let self, let web, self.isVisible, self.web === web,
                  self.generation == request, self.searchText == query else { return }
            self.matchFound = result.matchFound
            self.setStatus(result.matchFound ? "Match" : "No matches", missing: !result.matchFound)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        invalidateSearch()
        guard isVisible else { return }
        if searchText.isEmpty { findNext(); return }
        setStatus(web == nil ? "No page" : "Searching…")
        let work = DispatchWorkItem { [weak self] in self?.findNext() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            findNext(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hide(); return true }
        return false
    }

    private func invalidateSearch() {
        generation &+= 1
        pendingSearch?.cancel()
        pendingSearch = nil
        matchFound = nil
    }

    private func clearHighlight(in web: WKWebView?) {
        // Empty native searches dismiss WebKit's find selection without changing the DOM.
        web?.find("", configuration: WKFindConfiguration(), completionHandler: { _ in })
    }

    private func setStatus(_ text: String, missing: Bool = false) {
        overlay.status.stringValue = text
        overlay.status.textColor = missing ? .systemRed : .secondaryLabelColor
        let canFind = web != nil && !searchText.isEmpty
        overlay.previous.isEnabled = canFind
        overlay.next.isEnabled = canFind
    }

    private func installKeyboardHandling() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.overlay.window,
                  self.overlay.window?.attachedSheet == nil else { return event }
            if event.keyCode == 53 { self.hide(); return nil }
            return event
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let window = overlay.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    @objc private func previousAction() { findNext(backwards: true) }
    @objc private func nextAction() { findNext() }
    @objc private func closeAction() { hide() }

    deinit {
        pendingSearch?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}

@MainActor private final class FindBarOverlay: NSView {
    let bar = NSVisualEffectView()
    let search = NSSearchField()
    let status = NSTextField(labelWithString: "Find in page")
    let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!, target: nil, action: nil)
    let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!, target: nil, action: nil)
    let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close find")!, target: nil, action: nil)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.material = .popover; bar.blendingMode = .withinWindow; bar.state = .active
        bar.wantsLayer = true; bar.layer?.cornerRadius = 9
        bar.layer?.borderWidth = 1; bar.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(bar)
        search.placeholderString = "Find in page"
        search.setAccessibilityLabel("Find in page")
        search.font = .systemFont(ofSize: 13)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        for button in [previous, next, close] { button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly }
        previous.toolTip = "Previous match (Shift-Return)"
        next.toolTip = "Next match (Return)"
        close.toolTip = "Close find (Escape)"
        [search, status, previous, next, close].forEach(bar.addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(0, min(520, bounds.width - 24))
        bar.frame = NSRect(x: max(0, bounds.width - width - 12), y: 36, width: width, height: 40)
        let hasStatus = width >= 360
        let statusWidth: CGFloat = hasStatus ? 83 : 0
        let searchWidth = max(30, width - statusWidth - 108)
        // NSVisualEffectView uses AppKit's bottom-up coordinates.
        search.frame = NSRect(x: 8, y: 8, width: searchWidth, height: 24)
        status.isHidden = !hasStatus
        status.frame = NSRect(x: search.frame.maxX + 3, y: 12, width: statusWidth, height: 16)
        let buttonsX = width - 92
        previous.frame = NSRect(x: buttonsX, y: 7, width: 27, height: 26)
        next.frame = NSRect(x: buttonsX + 28, y: 7, width: 27, height: 26)
        close.frame = NSRect(x: buttonsX + 60, y: 7, width: 26, height: 26)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bar.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
