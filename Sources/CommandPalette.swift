import AppKit
import WebKit

/// Arc-style site pill shown once Tab scopes the palette to one engine.
@MainActor final class PaletteEnginePill: NSView {
    private let label = NSTextField(labelWithString: "")
    // Text width + the field cell's own slack + the capsule's side padding.
    private var labelWidth: CGFloat { label.measuredTextWidth + 6 }
    var fittingWidth: CGFloat { labelWidth + 22 }
    init(engine: SiteSearchEngine) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = engine.color.cgColor
        layer?.cornerRadius = 12
        label.stringValue = engine.name
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = engine.accentTextColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Searching \(engine.name). Press Delete to remove.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let width = labelWidth
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}


/// How a palette pick opens: Return (this tab after ⌘L, a new tab after ⌘T), ⇧⌘↩ a new tab, ⌘↩ a background tab,
/// or beside the current page in a Split.
enum PaletteOpenMode { case standard, newTab, background, split }

/// The command palette ("the field"): open and search, inline completion, open and visited pages, Quick Actions,
/// calculator, Tab-to-search site scoping, remote suggestions, the footer and its actions, layout and dismissal.
extension BrowserController {
    /// The chosen default engine supplies suggestions when it has an endpoint;
    /// otherwise DuckDuckGo keeps autocomplete alive.
    private var defaultSuggestionEngine: SiteSearchEngine? {
        let chosen = SiteSearchCatalog.engines.first { $0.host == URLInput.searchEngine.rawValue }
        if chosen?.suggestTemplate != nil { return chosen }
        return SiteSearchCatalog.engines.first { $0.host == "duckduckgo.com" }
    }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func openAddress(newTab: Bool, empty: Bool) {
        cancelPaging(); dismissAddress(animated: false); view.window?.makeKeyAndOrderFront(nil); newTabOnSubmit = newTab
        let state = paletteState
        prepareSuggestionSources(state)
        // No dimming: the page stays as it is, as in Yab. A click outside still closes.
        let overlay = DismissView(); overlay.wantsLayer = true
        overlay.dismiss = { [weak self] in self?.dismissAddress() }
        let shadow = PaletteShadowView()
        overlay.addSubview(shadow)
        // The card clips to rounded corners, so a sibling behind it carries the
        // site-colored glow as a shadow path once a search engine is scoped.
        let glow = NSView(); glow.wantsLayer = true
        glow.layer?.shadowOpacity = 0; glow.layer?.shadowOffset = .zero
        overlay.addSubview(glow)
        let box = PaletteCard()
        let tint = NSView(); tint.wantsLayer = true
        tint.alphaValue = 0
        tint.setAccessibilityElement(false)
        box.addSubview(tint)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        box.addSubview(icon)
        let field = PaletteField(); field.font = .systemFont(ofSize: 20, weight: .regular)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.cell?.usesSingleLineMode = false; field.maximumNumberOfLines = 1; field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.placeholderString = "Search or enter address"; field.stringValue = empty ? "" : session.active?.address ?? ""
        field.target = self; field.action = #selector(submitAddress); field.delegate = self
        field.escape = { [weak self] in self?.paletteEscape() }; field.setAccessibilityLabel("Search or enter address")
        box.addSubview(field)
        // Kept for compatibility with callers that read the hint's text; the visible hint is the keycap view.
        let hint = NSTextField(labelWithString: ""); hint.isHidden = true
        box.addSubview(hint)
        let tabHint = PaletteTabHint(); tabHint.text = ""
        box.addSubview(tabHint)
        let results = TabSearchResultsView(frame: .zero)
        results.opensInNewTab = newTab
        let resultsScroll = NSScrollView()
        resultsScroll.drawsBackground = false; resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true; resultsScroll.scrollerStyle = .overlay
        resultsScroll.hasHorizontalScroller = false; resultsScroll.horizontalScrollElasticity = .none
        resultsScroll.verticalScrollElasticity = .none
        resultsScroll.automaticallyAdjustsContentInsets = false
        resultsScroll.documentView = results
        results.faviconProvider = { [weak self] in self?.favicon(forTabID: $0) }
        results.siteFaviconProvider = { [weak self] url, allowFetch in self?.favicon(forSiteURL: url, allowFetch: allowFetch) }
        results.onSelect = { [weak self] id in self?.selectSearchResult(id) }
        results.onSubmitQuery = { [weak self] query in self?.submitAddressQuery(query) }
        results.onSearch = { [weak self] text in self?.submitPaletteSearch(text) }
        results.onCommand = { [weak self] command in self?.performPaletteCommand(command) }
        results.onOpenAddress = { [weak self] address, newTab in self?.openPaletteAddress(address, mode: newTab ? .newTab : .standard) }
        results.onCopy = { [weak self] text in self?.copyFromPalette(text, message: "Answer copied", symbol: "equal") }
        box.addSubview(resultsScroll)
        let footer = PaletteFooterView()
        footer.onReturn = { [weak self] in self?.submitAddress(nil) }
        footer.onActions = { [weak self] anchor in self?.showPaletteActions(from: anchor) }
        footer.onPlaces = { [weak self] anchor in self?.showPalettePlaces(from: anchor) }
        results.onSelectionChange = { [weak footer, weak results] in
            guard let footer, let results else { return }
            footer.setReturnTitle(results.returnTitle)
        }
        box.addSubview(footer)
        overlay.addSubview(box); root.addSubview(overlay)
        addressOverlay = overlay; addressField = field; addressCard = box; tabSearchResults = results
        paletteIcon = icon; paletteHint = hint; paletteSeparator = nil
        paletteGlow = glow; paletteTint = tint
        state.footer = footer; state.shadow = shadow; state.tabHint = tabHint
        state.typed = field.stringValue
        installPaletteKeyMonitor(state)
        refreshPaletteResults(); layoutBrowser()
        animatePaletteIn(box, shadow: shadow)
        view.window?.makeFirstResponder(field); field.selectText(nil)
    }

    /// History and open tabs, gathered once per palette: ranking and completion then cost nothing per keystroke.
    private func prepareSuggestionSources(_ state: PaletteState) {
        let visits = library.history.map { PaletteVisit(address: $0.address, title: $0.title, visitedAt: $0.visitedAt) }
        state.history = PaletteHistoryIndex(visits: visits)
        var candidates = state.history.sites.map { PaletteCompletionCandidate(address: $0.address, title: $0.title, weight: $0.score) }
        for tab in session.tabs where !tab.isHome {
            let address = tab.isUnloaded ? (tab.saved?.address ?? tab.address) : tab.address
            candidates.append(PaletteCompletionCandidate(address: address, title: tab.displayTitle, weight: tab.isFavorite ? 3 : 2))
        }
        state.candidates = candidates
        state.openTabKeys = Set(session.tabs.map { PaletteAddressKey.key($0.isUnloaded ? ($0.saved?.address ?? $0.address) : $0.address) })
    }

    /// A quick scale-and-fade from 97%: the card settles in about 150ms, ease-out.
    private func animatePaletteIn(_ box: NSView, shadow: NSView) {
        guard !reduceMotion else { return }
        for view in [box, shadow] {
            guard let layer = view.layer else { continue }
            let w = view.bounds.width / 2, h = view.bounds.height / 2
            var start = CATransform3DMakeTranslation(w, h, 0)
            start = CATransform3DScale(start, 0.97, 0.97, 1)
            start = CATransform3DTranslate(start, -w, -h, 0)
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = start; scale.toValue = CATransform3DIdentity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.15
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(group, forKey: "paletteIn")
        }
    }

    func layoutPalette(width w: CGFloat, height h: CGFloat) {
        guard let overlay = addressOverlay, let content = addressCard else { return }
        overlay.frame = root.bounds
        let state = paletteState
        let cw = PaletteGeometry.width(forWindowWidth: w)
        let inputHeight = PaletteGeometry.inputHeight
        let rowsHeight = tabSearchResults?.preferredHeight ?? 44
        let fit = PaletteGeometry.fit(windowHeight: h, resultsHeight: rowsHeight)
        let cardHeight = PaletteGeometry.resultsTop + fit.visibleResultsHeight + PaletteGeometry.footerHeight
        content.frame = NSRect(x: ((w - cw) / 2).rounded(), y: fit.top, width: cw, height: cardHeight)
        state.shadow?.frame = content.frame
        paletteGlow?.frame = content.frame
        let radius = PaletteGeometry.cornerRadius
        paletteGlow?.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: content.frame.size),
                                                cornerWidth: radius, cornerHeight: radius, transform: nil)
        paletteTint?.frame = content.bounds
        // The magnifier and every row icon share one center line, 26pt in; text starts 49pt in.
        paletteIcon?.frame = NSRect(x: 17, y: (inputHeight - 18) / 2, width: 18, height: 18)
        var fieldX: CGFloat = 46
        if let pill = paletteEnginePill {
            // The full engine name always renders; the field absorbs the squeeze.
            let pillWidth = pill.fittingWidth
            pill.frame = NSRect(x: 46, y: (inputHeight - 26) / 2, width: pillWidth, height: 26)
            fieldX = 46 + pillWidth + 10
        }
        var hintWidth: CGFloat = 0
        if let tabHint = state.tabHint, !tabHint.text.isEmpty {
            hintWidth = tabHint.fittingWidth
            tabHint.frame = NSRect(x: cw - hintWidth - 17, y: (inputHeight - 24) / 2, width: hintWidth, height: 24)
            hintWidth += 12
        }
        let fieldHeight: CGFloat = 26
        addressField?.frame = NSRect(x: fieldX, y: (inputHeight - fieldHeight) / 2, width: max(40, cw - fieldX - hintWidth - 20), height: fieldHeight)
        if let results = tabSearchResults, let scroll = results.enclosingScrollView {
            scroll.frame = NSRect(x: 7, y: PaletteGeometry.resultsTop, width: cw - 14, height: fit.visibleResultsHeight)
            results.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(rowsHeight, 1))
            results.revealSelection()
        }
        state.footer?.frame = NSRect(x: 0, y: cardHeight - PaletteGeometry.footerHeight, width: cw, height: PaletteGeometry.footerHeight)
    }

    @objc func submitAddress(_ sender: Any?) {
        if tabSearchResults?.activateSelection() == true { return }
        if paletteEngine != nil { submitPaletteSearch(paletteQueryText); return }
        submitAddressQuery(paletteQueryText)
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

    /// Opens a web address picked in the palette the way the keys asked.
    func openPaletteAddress(_ address: String, mode: PaletteOpenMode) {
        switch mode {
        case .standard: openResolvedAddress(address)
        case .newTab: session.add(address: address); dismissAddress(); showActive(); save()
        case .background:
            // The tab joins the list asleep and loads when you go to it; this page stays put.
            let host = URL(string: address)?.host ?? address
            session.tabs.append(BrowserTab(title: host, address: address, space: session.space))
            dismissAddress(); refresh(); save()
            pageFeedback.show("Opened in background", symbol: "square.on.square", in: webHost)
        case .split:
            let primary = session.activeID
            var draft = session
            let id = draft.add(address: address)
            guard session.split(for: primary) == nil, session.active?.isFavorite != true,
                  draft.makeSplit(primary: primary, secondary: id) else { openPaletteAddress(address, mode: .newTab); return }
            session = draft; dismissAddress(); showActive(); save()
            splitCoordinators[primary]?.setFocusedSide(.right)
        }
    }
    /// The web address a palette row stands for, if it has one.
    private func paletteAddress(for target: PaletteTarget) -> String? {
        switch target {
        case .tab(_, let address): return URLInput.directURL(address)?.absoluteString
        case .address(let address, _): return address
        case .query(let text): return URLInput.resolve(text)
        case .search(let text):
            if let engine = paletteEngine { return engine.searchURL(for: text) }
            return URLInput.resolve(text)
        case .command, .calculation: return nil
        }
    }
    /// ⌘↩, ⇧⌘↩ and the actions menu: open the selected row as asked. Tabs and commands just activate.
    func openPaletteSelection(mode: PaletteOpenMode) {
        guard let results = tabSearchResults else { return }
        let target = results.selectedTarget ?? (paletteQueryText.isEmpty ? nil : .query(paletteQueryText))
        guard let target else { NSSound.beep(); return }
        switch target {
        case .tab, .command, .calculation: submitAddress(nil)
        default:
            guard let address = paletteAddress(for: target) else { NSSound.beep(); return }
            openPaletteAddress(address, mode: mode)
        }
    }
    func copyPaletteSelectionLink() {
        guard let target = tabSearchResults?.selectedTarget else { NSSound.beep(); return }
        if case .calculation(let calculation) = target { copyFromPalette(calculation.plain, message: "Answer copied", symbol: "equal"); return }
        guard let address = paletteAddress(for: target) else { NSSound.beep(); return }
        copyFromPalette(address, message: "Link copied", symbol: "link")
    }
    func copyFromPalette(_ text: String, message: String, symbol: String) {
        pageCommandPasteboard.clearContents()
        pageCommandPasteboard.setString(text, forType: .string)
        dismissAddress()
        pageFeedback.show(message, symbol: symbol, in: webHost)
    }

    /// ⌘K: a short list of what can be done with the selected row.
    func showPaletteActions(from anchor: NSView? = nil) {
        guard let results = tabSearchResults, let target = results.selectedTarget else { NSSound.beep(); return }
        let menu = NSMenu(title: "Actions")
        menu.autoenablesItems = false
        let item = PaletteMenuAction.item
        switch target {
        case .tab(let id, _):
            menu.addItem(item("Switch to Tab", "arrow.right.square", "\r", []) { [weak self] in self?.selectSearchResult(id) })
            if paletteAddress(for: target) != nil {
                menu.addItem(item("Copy Link", "link", "c", [.command, .shift]) { [weak self] in self?.copyPaletteSelectionLink() })
            }
            menu.addItem(.separator())
            menu.addItem(item("Close Tab", "xmark", "", []) { [weak self] in
                guard let self else { return }
                self.close(id)
                if self.addressField != nil { self.prepareSuggestionSources(self.paletteState); self.refreshPaletteResults() }
            })
        case .command(let command):
            menu.addItem(item("Run \(command.title)", command.symbol, "\r", []) { [weak self] in self?.performPaletteCommand(command) })
        case .calculation(let calculation):
            menu.addItem(item("Copy Answer", "doc.on.doc", "\r", []) { [weak self] in
                self?.copyFromPalette(calculation.plain, message: "Answer copied", symbol: "equal")
            })
        default:
            menu.addItem(item("Open", "arrow.up.right", "\r", []) { [weak self] in self?.submitAddress(nil) })
            menu.addItem(item("Open in New Tab", "plus.square", "\r", [.command, .shift]) { [weak self] in self?.openPaletteSelection(mode: .newTab) })
            menu.addItem(item("Open in Background", "square.on.square", "\r", [.command]) { [weak self] in self?.openPaletteSelection(mode: .background) })
            if session.split(for: session.activeID) == nil, session.active?.isFavorite != true {
                menu.addItem(item("Open in Split View", "rectangle.split.2x1", "", []) { [weak self] in self?.openPaletteSelection(mode: .split) })
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy Link", "link", "c", [.command, .shift]) { [weak self] in self?.copyPaletteSelectionLink() })
        }
        let source = anchor ?? paletteState.footer?.actionsAnchor
        guard let source else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: source.bounds.height + 6), in: source)
    }

    /// The footer's places button: the browser's lists you can jump into.
    func showPalettePlaces(from anchor: NSView) {
        let menu = NSMenu(title: "Places")
        menu.autoenablesItems = false
        for id in ["history", "downloads", "recently-closed", "settings"] {
            guard let command = PaletteCommandCatalog.commands.first(where: { $0.id == id }) else { continue }
            menu.addItem(PaletteMenuAction.item(command.title, symbol: command.symbol) { [weak self] in self?.performPaletteCommand(command) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    /// What the person typed: the field's text without a completed ending.
    var paletteQueryText: String {
        guard let field = addressField else { return "" }
        let state = paletteState
        if let completion = state.completion, field.stringValue == completion.text { return completion.typed }
        return field.stringValue
    }

    func refreshPaletteResults() {
        guard let field = addressField else { return }
        let state = paletteState
        // Text set from outside (⌘L's address, tests) drops a stale completion.
        if let completion = state.completion, field.stringValue != completion.text { state.completion = nil }
        let typed = paletteQueryText
        state.typed = typed
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if paletteEngine == nil {
            paletteHintEngine = SiteSearchCatalog.match(trimmed)
            paletteHint?.stringValue = paletteHintEngine.map { "Search \($0.name)  ⇥" } ?? ""
            state.tabHint?.text = paletteHintEngine.map { "Search \($0.name)" } ?? ""
        } else {
            paletteHintEngine = nil
            paletteHint?.stringValue = ""
            state.tabHint?.text = ""
        }
        // Address-like text never feeds remote autocomplete: ⌘L prefills the
        // current page URL, which must not leave the app just for opening the bar.
        let urlLike = trimmed.contains("://") || (!trimmed.contains(" ") && trimmed.contains("."))
        let suggestURL = (paletteEngine ?? defaultSuggestionEngine)?.suggestURL(for: trimmed)
        if let suggestURL, !trimmed.isEmpty, !urlLike {
            suggestionFetcher.fetch(url: suggestURL) { [weak self] suggestions in
                guard let self, self.addressField != nil else { return }
                self.paletteSuggestions = suggestions
                self.applyPaletteResults()
            }
        } else {
            paletteSuggestions = []
            suggestionFetcher.cancel()
        }
        applyPaletteResults()
    }
    private func applyPaletteResults() {
        guard addressField != nil else { return }
        let state = paletteState
        let typed = state.typed
        let scoped = paletteEngine != nil
        let commands = scoped ? [] : PaletteCommandCatalog.matches(typed)
        let activeSpace = session.spaces.first { $0.id == session.space }
        let recent = session.tabs.map(\.id).enumerated()
            .sorted { lhs, rhs in
                let a = tabLastUsed[lhs.element] ?? -1, b = tabLastUsed[rhs.element] ?? -1
                return a != b ? a > b : lhs.offset < rhs.offset
            }.map(\.element)
        let folders = Dictionary(session.folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        tabSearchResults?.update(tabs: session.tabs, query: typed, activeID: focusedTabID,
                                 canCreate: true, spaces: session.spaces, profiles: session.profiles,
                                 engine: paletteEngine, suggestions: paletteSuggestions, commands: commands,
                                 selectionTint: activeSpace.map { ArkPalette.spaceTint(for: $0) },
                                 history: scoped ? [] : state.history.matches(typed, excluding: state.openTabKeys, limit: 3),
                                 completion: scoped ? nil : state.completion,
                                 recentTabIDs: recent,
                                 calculation: scoped ? nil : PaletteCalculator.evaluate(typed),
                                 quickActions: scoped ? [] : PaletteQuickActionCatalog.matches(typed),
                                 folderNames: folders, searchEngineName: URLInput.searchEngine.name)
        // Only the palette's own frames depend on its results: no whole-browser layout per keystroke or suggestion.
        layoutPalette(width: root.bounds.width, height: root.bounds.height)
    }
    /// Runs a catalog command through the responder chain once the palette is
    /// gone, so the same entry reaches the controller, the app delegate, or a
    /// Little Bam window depending on where it was typed.
    func performPaletteCommand(_ command: PaletteCommand) {
        dismissAddress()
        if !NSApp.sendAction(Selector(command.action), to: nil, from: self) { NSSound.beep() }
    }

    // MARK: Inline completion

    private var paletteEditor: NSTextView? {
        guard let field = addressField, let editor = field.currentEditor() as? NSTextView else { return nil }
        return editor
    }
    /// Finishes the typed text with the best open or visited site ("git" → "github.com"), when the caret is at the
    /// end and the text looks like the start of an address. A Quick Action alias ("doc") is never completed over.
    private func computeCompletion(for typed: String) -> PaletteCompletion? {
        guard paletteEngine == nil, !typed.isEmpty else { return nil }
        if PaletteQuickActionCatalog.matches(typed).contains(where: \.leading) { return nil }
        if PaletteCommandCatalog.matches(typed).contains(where: \.leading) { return nil }
        return PaletteAutocomplete.complete(typed, candidates: paletteState.candidates)
    }
    /// Shows the completion as a selected gray ending, so typing on replaces it and Delete removes it.
    private func applyCompletionToField() {
        guard let editor = paletteEditor else { return }
        let state = paletteState
        if let completion = state.completion, !completion.tail.isEmpty {
            if state.styledEditor == nil {
                state.savedSelectionAttributes = editor.selectedTextAttributes
                state.styledEditor = editor
            }
            editor.selectedTextAttributes = [.backgroundColor: NSColor.labelColor.withAlphaComponent(editor.effectiveAppearance.isDarkPalette ? 0.2 : 0.12),
                                             .foregroundColor: NSColor.labelColor]
            editor.string = completion.text
            let start = (completion.typed as NSString).length
            editor.setSelectedRange(NSRange(location: start, length: (completion.text as NSString).length - start))
        } else if let saved = state.savedSelectionAttributes, let styled = state.styledEditor {
            styled.selectedTextAttributes = saved
            state.savedSelectionAttributes = nil; state.styledEditor = nil
        }
    }
    /// → or ⇥ takes the gray ending: it becomes typed text and the caret moves to the end.
    @discardableResult private func acceptPaletteCompletion() -> Bool {
        let state = paletteState
        guard let completion = state.completion, !completion.tail.isEmpty, let editor = paletteEditor else { return false }
        editor.setSelectedRange(NSRange(location: (completion.text as NSString).length, length: 0))
        state.typed = completion.text
        state.completion = computeCompletion(for: completion.text)
        applyCompletionToField()
        refreshPaletteResults()
        return true
    }
    private func dropPaletteCompletion() -> Bool {
        let state = paletteState
        guard let completion = state.completion, !completion.tail.isEmpty, let editor = paletteEditor else { return false }
        state.completion = nil
        editor.string = completion.typed
        editor.setSelectedRange(NSRange(location: (completion.typed as NSString).length, length: 0))
        applyCompletionToField()
        refreshPaletteResults()
        return true
    }

    @discardableResult func activatePaletteEngineHint() -> Bool {
        guard paletteEngine == nil,
              let engine = paletteHintEngine ?? SiteSearchCatalog.match(paletteQueryText) else { return false }
        paletteEngine = engine
        paletteHintEngine = nil
        paletteSuggestions = []
        paletteState.completion = nil
        applyCompletionToField()
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
        tint.alphaValue = (addressCard?.effectiveAppearance.isDarkPalette ?? true) ? 0.1 : 0.06
        guard !reduceMotion else { return }
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
        wash.values = [0, 0.26, Double(tint.alphaValue)]; wash.keyTimes = [0, 0.3, 1]; wash.duration = 0.55
        tint.layer?.add(wash, forKey: "wash")
    }
    private func extinguishEngineGlow() {
        guard let glow = paletteGlow?.layer, let tint = paletteTint else { return }
        if !reduceMotion {
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = glow.presentation()?.shadowOpacity ?? glow.shadowOpacity
            fade.toValue = 0; fade.duration = 0.2
            glow.add(fade, forKey: "shadowOpacity")
        }
        glow.shadowOpacity = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            tint.animator().alphaValue = 0
        }
    }
    /// Springs the pill in from the left once layout has given it its frame.
    private func popInEnginePill(_ pill: PaletteEnginePill) {
        guard !reduceMotion, let layer = pill.layer else { return }
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
        if let pill, !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                pill.animator().alphaValue = 0
            }, completionHandler: { pill.removeFromSuperview() })
        } else { pill?.removeFromSuperview() }
        extinguishEngineGlow()
        addressField?.placeholderString = "Search or enter address"
        refreshPaletteResults()
    }

    func selectSearchResult(_ id: UUID) {
        select(id)
        if let group = session.split(for: id), let split = splitCoordinators[group.primaryID] {
            split.setFocusedSide(id == group.secondaryID ? .right : .left)
        }
        view.window?.makeFirstResponder(commandWebView)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as AnyObject? === addressField, let field = addressField else { return }
        let state = paletteState
        let text = field.stringValue
        let editor = paletteEditor
        let caretAtEnd = editor.map { $0.selectedRange().location == ($0.string as NSString).length && $0.selectedRange().length == 0 } ?? true
        if state.suppressCompletion || !caretAtEnd || editor?.hasMarkedText() == true {
            state.suppressCompletion = false
            state.completion = nil
        } else {
            state.completion = computeCompletion(for: text)
        }
        state.typed = text
        applyCompletionToField()
        refreshPaletteResults()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { paletteEscape(); return true }
        // A held arrow key auto-repeats: step instantly and stop at the ends instead of gliding and wrapping.
        let repeating = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.isARepeat == true
        if commandSelector == #selector(NSResponder.moveDown(_:)) { tabSearchResults?.moveSelection(delta: 1, repeating: repeating); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { tabSearchResults?.moveSelection(delta: -1, repeating: repeating); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submitAddress(control); return true }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // Tab scopes the palette to the hinted site; otherwise it takes the gray ending.
            if !activatePaletteEngineHint() { acceptPaletteCompletion() }
            return true
        }
        if [#selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
            #selector(NSResponder.moveToEndOfParagraph(_:)), #selector(NSResponder.moveToEndOfDocument(_:))].contains(commandSelector),
           acceptPaletteCompletion() { return true }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)),
           paletteEngine != nil, addressField?.stringValue.isEmpty == true {
            clearPaletteEngine(); return true
        }
        // Delete removes the gray ending; the next change must not bring it straight back.
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) || commandSelector == #selector(NSResponder.deleteForward(_:))
            || commandSelector == #selector(NSResponder.deleteWordBackward(_:)) || commandSelector == #selector(NSResponder.deleteToBeginningOfLine(_:)) {
            if dropPaletteCompletion() { return true }
            paletteState.suppressCompletion = true
        }
        return false
    }

    /// Esc goes back one step, then closes: a scoped site, then a gray ending, then the palette.
    func paletteEscape() {
        if paletteEngine != nil { clearPaletteEngine(); return }
        if dropPaletteCompletion() { return }
        dismissAddress()
    }

    /// ⌘K, ⌘↩, ⇧⌘↩ and ⇧⌘C reach the field before the menus do while it has focus.
    private func installPaletteKeyMonitor(_ state: PaletteState) {
        state.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let field = self.addressField, event.window === self.view.window,
                  let editor = event.window?.firstResponder as? NSTextView, editor.delegate === field else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags == .command, key == "k" { self.showPaletteActions(); return nil }
            if flags == .command, isReturn { self.openPaletteSelection(mode: .background); return nil }
            if flags == [.command, .shift], isReturn { self.openPaletteSelection(mode: .newTab); return nil }
            if flags == [.command, .shift], key == "c", editor.selectedRange().length == 0 || self.paletteState.completion != nil {
                self.copyPaletteSelectionLink(); return nil
            }
            return event
        }
    }

    func dismissAddress() { dismissAddress(animated: true) }
    func dismissAddress(animated: Bool) {
        suggestionFetcher.cancel()
        let overlay = addressOverlay
        if let overlay {
            overlay.dismiss = nil
            if animated && !reduceMotion {
                // A quick fade, without holding up whatever the pick does next.
                overlay.subviews.forEach { $0.setAccessibilityElement(false) }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.1
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    overlay.animator().alphaValue = 0
                }, completionHandler: { overlay.removeFromSuperview() })
            } else { overlay.removeFromSuperview() }
        }
        addressOverlay = nil; addressField = nil; addressCard = nil; tabSearchResults = nil
        paletteIcon = nil; paletteHint = nil; paletteSeparator = nil; paletteEnginePill = nil
        paletteGlow = nil; paletteTint = nil
        paletteEngine = nil; paletteHintEngine = nil; paletteSuggestions = []
        resetPaletteState()
        view.window?.makeFirstResponder(commandWebView)
    }
}
