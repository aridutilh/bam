import AppKit
import WebKit

/// Adaptive palette surface: translucent in the system appearance instead of
/// the old forced-aqua cream card.
@MainActor final class PaletteCard: NSVisualEffectView {
    override var isFlipped: Bool { true }
    // Blur alone lets the page bleed through; a translucent wash keeps rows legible.
    private let wash = NSView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wash.wantsLayer = true
        addSubview(wash)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        wash.frame = bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// Arc-style site pill shown once Tab scopes the palette to one engine.
@MainActor final class PaletteEnginePill: NSView {
    private let label = NSTextField(labelWithString: "")
    // A truncating label can under-report intrinsicContentSize; measure the text.
    private var textWidth: CGFloat {
        let font = label.font ?? .systemFont(ofSize: 12, weight: .semibold)
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width)
    }
    var fittingWidth: CGFloat { textWidth + 24 }
    init(engine: SiteSearchEngine) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = engine.color.cgColor
        layer?.cornerRadius = 12
        label.stringValue = engine.name
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Searching \(engine.name). Press Delete to remove.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let width = textWidth
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// The command palette: open/search, Arc-style Tab-to-search site scoping,
/// remote suggestions, layout and dismissal.
extension BrowserController {
    private var defaultSuggestionEngine: SiteSearchEngine? {
        SiteSearchCatalog.engines.first { $0.host == "duckduckgo.com" }
    }

    func openAddress(newTab: Bool, empty: Bool) {
        cancelPaging(); dismissAddress(); view.window?.makeKeyAndOrderFront(nil); newTabOnSubmit = newTab
        let overlay = DismissView(); overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        overlay.dismiss = { [weak self] in self?.dismissAddress() }
        // The card clips to rounded corners, so a sibling behind it carries the
        // site-colored glow as a shadow path once a search engine is scoped.
        let glow = NSView(); glow.wantsLayer = true
        glow.layer?.shadowOpacity = 0; glow.layer?.shadowOffset = .zero
        overlay.addSubview(glow)
        let box = PaletteCard()
        box.material = .popover; box.blendingMode = .withinWindow; box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 16; box.layer?.masksToBounds = true
        let tint = NSView(); tint.wantsLayer = true
        tint.alphaValue = 0
        tint.setAccessibilityElement(false)
        box.addSubview(tint)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        box.addSubview(icon)
        let field = PaletteField(); field.font = .systemFont(ofSize: 18, weight: .regular)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.placeholderString = "Search or Enter URL…"; field.stringValue = empty ? "" : session.active?.address ?? ""
        field.target = self; field.action = #selector(submitAddress); field.delegate = self
        field.escape = { [weak self] in self?.dismissAddress() }; field.setAccessibilityLabel("Search or enter URL")
        box.addSubview(field)
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 12, weight: .medium); hint.textColor = .secondaryLabelColor
        hint.alignment = .right; hint.lineBreakMode = .byClipping
        hint.setAccessibilityElement(false)
        box.addSubview(hint)
        let line = NSBox(); line.boxType = .separator
        box.addSubview(line)
        let results = TabSearchResultsView(frame: .zero)
        results.onSelect = { [weak self] id in self?.selectSearchResult(id) }
        results.onSubmitQuery = { [weak self] query in self?.submitAddressQuery(query) }
        results.onSearch = { [weak self] text in self?.submitPaletteSearch(text) }
        box.addSubview(results)
        overlay.addSubview(box); root.addSubview(overlay)
        addressOverlay = overlay; addressField = field; addressCard = box; tabSearchResults = results
        paletteIcon = icon; paletteHint = hint; paletteSeparator = line
        paletteGlow = glow; paletteTint = tint
        refreshPaletteResults(); layoutBrowser()
        box.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12; box.animator().alphaValue = 1 }
        view.window?.makeFirstResponder(field); field.selectText(nil)
    }

    func layoutPalette(width w: CGFloat, height h: CGFloat) {
        guard let overlay = addressOverlay, let content = addressCard else { return }
        overlay.frame = root.bounds
        let cw = min(620, w - 60)
        let inputHeight: CGFloat = 54
        let rowsHeight = tabSearchResults?.preferredHeight ?? 44
        content.frame = NSRect(x: (w - cw) / 2, y: min(110, h * 0.12), width: cw, height: inputHeight + 7 + rowsHeight + 8)
        paletteGlow?.frame = content.frame
        paletteGlow?.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: content.frame.size),
                                                cornerWidth: 16, cornerHeight: 16, transform: nil)
        paletteTint?.frame = content.bounds
        paletteIcon?.frame = NSRect(x: 22, y: (inputHeight - 16) / 2, width: 16, height: 16)
        var fieldX: CGFloat = 50
        if let pill = paletteEnginePill {
            let pillWidth = min(180, pill.fittingWidth)
            pill.frame = NSRect(x: 50, y: (inputHeight - 24) / 2, width: pillWidth, height: 24)
            fieldX = 50 + pillWidth + 10
        }
        var hintWidth: CGFloat = 0
        if let hint = paletteHint, !hint.stringValue.isEmpty {
            hintWidth = min(220, hint.intrinsicContentSize.width + 8)
            hint.frame = NSRect(x: cw - hintWidth - 20, y: (inputHeight - 15) / 2, width: hintWidth, height: 15)
            hint.isHidden = false
        } else { paletteHint?.isHidden = true }
        addressField?.frame = NSRect(x: fieldX, y: (inputHeight - 26) / 2, width: max(40, cw - fieldX - hintWidth - 34), height: 26)
        paletteSeparator?.frame = NSRect(x: 14, y: inputHeight, width: cw - 28, height: 1)
        tabSearchResults?.frame = NSRect(x: 10, y: inputHeight + 7, width: cw - 20, height: rowsHeight)
    }

    @objc func submitAddress(_ sender: Any?) {
        if tabSearchResults?.activateSelection() == true { return }
        if paletteEngine != nil { submitPaletteSearch(addressField?.stringValue ?? ""); return }
        submitAddressQuery(addressField?.stringValue ?? "")
    }
    func submitAddressQuery(_ query: String) {
        guard let address = URLInput.resolve(query) else { NSSound.beep(); return }
        openResolvedAddress(address)
    }
    /// A scoped or suggested search: the active engine wins, else the default.
    func submitPaletteSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { NSSound.beep(); return }
        if let engine = paletteEngine, let address = engine.searchURL(for: query) { openResolvedAddress(address) }
        else { submitAddressQuery(query) }
    }
    private func openResolvedAddress(_ address: String) {
        if newTabOnSubmit { session.add(address: address); dismissAddress(); showActive(); save() }
        else { navigate(address) }
    }

    func refreshPaletteResults() {
        guard let field = addressField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if paletteEngine == nil {
            paletteHintEngine = SiteSearchCatalog.match(trimmed)
            paletteHint?.stringValue = paletteHintEngine.map { "Search \($0.name)  ⇥" } ?? ""
        } else {
            paletteHintEngine = nil
            paletteHint?.stringValue = ""
        }
        if trimmed.isEmpty { paletteSuggestions = []; suggestionFetcher.cancel() }
        else if let engine = paletteEngine ?? defaultSuggestionEngine {
            suggestionFetcher.fetch(url: engine.suggestURL(for: trimmed), query: trimmed) { [weak self] suggestions in
                guard let self, self.addressField != nil else { return }
                self.paletteSuggestions = suggestions
                self.applyPaletteResults()
            }
        }
        applyPaletteResults()
    }
    private func applyPaletteResults() {
        guard let field = addressField else { return }
        tabSearchResults?.update(tabs: session.tabs, query: field.stringValue, activeID: focusedTabID,
                                 canCreate: true, spaces: session.spaces,
                                 engine: paletteEngine, suggestions: paletteSuggestions)
        layoutBrowser()
    }

    @discardableResult func activatePaletteEngineHint() -> Bool {
        guard paletteEngine == nil,
              let engine = paletteHintEngine ?? SiteSearchCatalog.match(addressField?.stringValue ?? "") else { return false }
        paletteEngine = engine
        paletteHintEngine = nil
        paletteSuggestions = []
        let pill = PaletteEnginePill(engine: engine)
        addressCard?.addSubview(pill)
        paletteEnginePill = pill
        addressField?.stringValue = ""
        addressField?.placeholderString = "Search \(engine.name)…"
        paletteHint?.stringValue = ""
        refreshPaletteResults()
        popInEnginePill(pill)
        igniteEngineGlow(engine)
        return true
    }
    /// Arc-style scope flash: the panel blooms in the site's color and settles
    /// into a subtle halo and interior wash while the engine stays scoped.
    private func igniteEngineGlow(_ engine: SiteSearchEngine) {
        guard let glow = paletteGlow?.layer, let tint = paletteTint else { return }
        glow.shadowColor = engine.color.cgColor
        tint.layer?.backgroundColor = engine.color.cgColor
        glow.shadowOpacity = 0.4; glow.shadowRadius = 26
        tint.alphaValue = 0.12
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let bloom = CAKeyframeAnimation(keyPath: "shadowOpacity")
        bloom.values = [0, 0.85, 0.4]; bloom.keyTimes = [0, 0.3, 1]
        let spread = CAKeyframeAnimation(keyPath: "shadowRadius")
        spread.values = [12, 52, 26]; spread.keyTimes = [0, 0.3, 1]
        for animation in [bloom, spread] {
            animation.duration = 0.55
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            glow.add(animation, forKey: animation.keyPath)
        }
        let wash = CAKeyframeAnimation(keyPath: "opacity")
        wash.values = [0, 0.3, 0.12]; wash.keyTimes = [0, 0.3, 1]; wash.duration = 0.55
        tint.layer?.add(wash, forKey: "wash")
    }
    private func extinguishEngineGlow() {
        guard let glow = paletteGlow?.layer, let tint = paletteTint else { return }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = glow.presentation()?.shadowOpacity ?? glow.shadowOpacity
            fade.toValue = 0; fade.duration = 0.2
            glow.add(fade, forKey: "shadowOpacity")
        }
        glow.shadowOpacity = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            tint.animator().alphaValue = 0
        }
    }
    /// Springs the pill in from the left once layout has given it its frame.
    private func popInEnginePill(_ pill: PaletteEnginePill) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = pill.layer else { return }
        pill.layoutSubtreeIfNeeded()
        let w = pill.bounds.width / 2, h = pill.bounds.height / 2
        var start = CATransform3DMakeTranslation(w - 10, h, 0)
        start = CATransform3DScale(start, 0.55, 0.55, 1)
        start = CATransform3DTranslate(start, -w, -h, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = start
        spring.toValue = CATransform3DIdentity
        spring.damping = 16; spring.stiffness = 380; spring.mass = 1; spring.initialVelocity = 6
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.14
        layer.add(spring, forKey: "pop")
        layer.add(fade, forKey: "fade")
    }
    func clearPaletteEngine() {
        guard paletteEngine != nil else { return }
        paletteEngine = nil
        paletteSuggestions = []
        let pill = paletteEnginePill
        paletteEnginePill = nil
        if let pill, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                pill.animator().alphaValue = 0
            }, completionHandler: { pill.removeFromSuperview() })
        } else { pill?.removeFromSuperview() }
        extinguishEngineGlow()
        addressField?.placeholderString = "Search or Enter URL…"
        refreshPaletteResults()
    }

    func selectSearchResult(_ id: UUID) {
        select(id)
        if let group = session.split(for: id), let split = splitCoordinators[group.primaryID] {
            split.setFocusedSide(id == group.secondaryID ? .right : .left)
        }
        view.window?.makeFirstResponder(commandWebView)
    }

    func controlTextDidChange(_ obj: Notification) { if obj.object as AnyObject? === addressField { refreshPaletteResults() } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismissAddress(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { tabSearchResults?.moveSelection(delta: 1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { tabSearchResults?.moveSelection(delta: -1); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submitAddress(control); return true }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // Tab scopes the palette to the hinted site; otherwise keep focus put.
            activatePaletteEngineHint(); return true
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)),
           paletteEngine != nil, addressField?.stringValue.isEmpty == true {
            clearPaletteEngine(); return true
        }
        return false
    }

    func dismissAddress() {
        suggestionFetcher.cancel()
        addressOverlay?.removeFromSuperview()
        addressOverlay = nil; addressField = nil; addressCard = nil; tabSearchResults = nil
        paletteIcon = nil; paletteHint = nil; paletteSeparator = nil; paletteEnginePill = nil
        paletteGlow = nil; paletteTint = nil
        paletteEngine = nil; paletteHintEngine = nil; paletteSuggestions = []
        view.window?.makeFirstResponder(commandWebView)
    }
}
