import AppKit
import QuartzCore

/// The first-run welcome: a full-window native sequence that personalizes the
/// first Space, optionally imports Chrome favorites, teaches two shortcuts and
/// offers the default-browser handoff. Flow decisions live in OnboardingModel;
/// this file owns presentation, motion and input routing. The sequence is
/// keyboard-first, skippable at every step, and honors Reduce Motion.
@MainActor final class OnboardingController: NSObject, NSTextFieldDelegate {
    private(set) var model: OnboardingModel
    var onApply: ((OnboardingResult) -> Void)?
    /// Called exactly once when the overlay leaves the window.
    var onDismiss: ((_ completed: Bool) -> Void)?

    private let overlay = OnboardingBackdropView()
    private var stage: OnboardingWindow?
    private let stepHost = NSView()
    private var stepView: NSView?
    private let backButton = OnboardingGlyphButton(symbol: "chevron.left", label: "Back")
    private let skipButton = OnboardingQuietButton(title: "Skip setup")
    private let dots = OnboardingDotsView()
    private var keyMonitor: Any?
    private var nameField: OnboardingNameField?
    private var keycaps: [String: OnboardingKeycapView] = [:]
    private var swatches: [OnboardingSwatchButton] = []
    private var colorNameLabel: NSTextField?
    private var finished = false
    private var revealWork: [DispatchWorkItem] = []

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(model: OnboardingModel) {
        self.model = model
        super.init()
    }

    // MARK: Presentation

    /// Onboarding takes over the whole screen in a window of its own, like a
    /// stage. That also keeps the live browser's web views out of the responder
    /// chain, so Return and the training chords always reach the sequence.
    func present(over mainWindow: NSWindow?) {
        let screen = mainWindow?.screen ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Titled but chromeless keeps the native traffic lights, so the stage
        // can be minimized or closed (closing skips) like any other window.
        let window = OnboardingWindow(contentRect: frame,
                                      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.title = "Welcome to Bam"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovable = false
        // Follows the system like the website; the browser behind stays dark.
        window.appearance = nil
        window.backgroundColor = BamTheme.bg
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .transient]
        window.delegate = self
        stage = window
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = NSRect(origin: .zero, size: frame.size)
        overlay.setAccessibilityElement(true)
        overlay.setAccessibilityRole(.group)
        overlay.setAccessibilityLabel("Welcome to Bam")
        // Tint after the overlay joins the window: a Clear tint reaches
        // through overlay.window to make the stage itself translucent.
        window.contentView = overlay
        overlay.tint(colorIndex: model.colorIndex, glow: 1, animated: false)

        stepHost.translatesAutoresizingMaskIntoConstraints = false
        backButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        dots.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stepHost); overlay.addSubview(backButton)
        overlay.addSubview(skipButton); overlay.addSubview(dots)
        NSLayoutConstraint.activate([
            stepHost.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stepHost.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -8),
            stepHost.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            stepHost.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 48),
            // The top-left corner belongs to the traffic lights (and, on a
            // notched display, the camera housing); Back lives by the dots.
            backButton.trailingAnchor.constraint(equalTo: dots.leadingAnchor, constant: -24),
            backButton.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            skipButton.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            skipButton.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -22),
            dots.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -28)
        ])
        backButton.target = self; backButton.action = #selector(goBack)
        skipButton.target = self; skipButton.action = #selector(skip)
        overlay.onKey = { [weak self] event in self?.handleOverlayKey(event) ?? false }
        installKeyMonitor()
        showStep(animatedFrom: nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        if !Self.reduceMotion {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35; window.animator().alphaValue = 1
            }
        }
    }

    /// The stage fades and swells slightly, revealing the personalized browser
    /// already waiting behind it.
    private func dismiss(completed: Bool) {
        guard !finished, let window = stage else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cancelStagedReveals()
        if completed { onApply?(model.result) }
        let finish = { [weak self] in
            guard let self else { return }
            self.stage?.orderOut(nil)
            self.stage = nil
            self.onDismiss?(completed)
        }
        if Self.reduceMotion { finish(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            if let layer = overlay.layer {
                OnboardingMotion.centerAnchor(layer)
                let zoom = CABasicAnimation(keyPath: "transform.scale")
                zoom.fromValue = 1; zoom.toValue = 1.035
                zoom.duration = 0.45; zoom.timingFunction = CAMediaTimingFunction(name: .easeIn)
                layer.add(zoom, forKey: "zoom")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46, execute: DispatchWorkItem { finish() })
    }

    // MARK: Step flow

    @objc private func goBack() {
        guard !model.isFirstStep else { return }
        let previous = model.step
        model.goBack()
        showStep(animatedFrom: previous)
    }
    @objc private func skip() { dismiss(completed: false) }
    @objc private func advance() {
        if let nameField { model.spaceName = nameField.stringValue }
        if model.isLastStep { dismiss(completed: true); return }
        let previous = model.step
        model.advance()
        showStep(animatedFrom: previous)
    }

    private func showStep(animatedFrom previous: OnboardingStep?) {
        cancelStagedReveals()
        nameField = nil; keycaps = [:]; swatches = []; colorNameLabel = nil
        let content = buildStep(model.step)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true

        let outgoing = stepView
        stepView = content
        stepHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: stepHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: stepHost.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: stepHost.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: stepHost.widthAnchor)
        ])

        backButton.isHidden = model.isFirstStep || model.isLastStep
        skipButton.isHidden = model.isLastStep
        dots.configure(count: model.steps.count, current: model.stepIndex)
        overlay.tint(colorIndex: model.colorIndex,
                     glow: model.step == .color || model.step == .finale ? 1 : 0.45,
                     animated: previous != nil)

        let forward = previous.map { $0.rawValue < model.step.rawValue } ?? true
        if Self.reduceMotion || previous == nil {
            outgoing?.removeFromSuperview()
        } else {
            let away: CGFloat = forward ? 26 : -26
            if let outgoing {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    outgoing.animator().alphaValue = 0
                    slide(outgoing, toY: away)
                }, completionHandler: { outgoing.removeFromSuperview() })
            }
            content.alphaValue = 0
            slide(content, toY: -away, immediately: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                content.animator().alphaValue = 1
                slide(content, toY: 0)
            }
        }
        focusCurrentStep()
        if model.step == .hello, previous == nil, !Self.reduceMotion { stageHelloReveal(content) }
        if model.step == .finale { celebrate() }
    }

    private func slide(_ view: NSView, toY offset: CGFloat, immediately: Bool = false) {
        let transform = CATransform3DMakeTranslation(0, offset, 0)
        if immediately {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view.layer?.transform = transform; CATransaction.commit()
        } else {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = view.layer?.presentation()?.transform ?? view.layer?.transform
            slide.toValue = transform
            slide.duration = 0.4
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            view.layer?.add(slide, forKey: "slide")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view.layer?.transform = transform; CATransaction.commit()
        }
    }

    /// Focus is claimed when the step appears and re-asserted once the
    /// transition settles, in case appearance work moved it. The re-assert
    /// never touches an editing session the user has already started.
    private func focusCurrentStep(reassert: Bool = true) {
        guard let window = overlay.window else { return }
        if let nameField, model.step == .name {
            if !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(nameField)
                nameField.selectText(nil)
            }
        } else if window.firstResponder !== overlay {
            window.makeFirstResponder(overlay)
        }
        guard reassert else { return }
        let work = DispatchWorkItem { [weak self] in self?.focusCurrentStep(reassert: false) }
        revealWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Input

    /// Browser shortcuts stay quiet behind the overlay. Only system-level
    /// chords pass through; the training step claims its two targets.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.finished, event.window === self.overlay.window else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags.contains(.command) else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if self.model.step == .shortcuts, let pressed = KeyCombo.from(event: event),
               let target = OnboardingModel.shortcutTargets.first(where: { Self.trainingCombo(for: $0) == pressed }) {
                self.recordShortcut(target)
                return nil
            }
            // Quit, hide, minimize and full screen remain available.
            if flags == .command, ["q", "h", "m"].contains(key) { return event }
            if flags == [.command, .option], key == "h" { return event }
            if flags == [.command, .control], key == "f" { return event }
            // Text editing inside the overlay keeps the standard chords.
            if flags == .command, ["a", "c", "v", "x", "z"].contains(key),
               self.overlay.window?.firstResponder is NSTextView { return event }
            return nil
        }
    }

    private func handleOverlayKey(_ event: NSEvent) -> Bool {
        guard !finished else { return false }
        switch event.keyCode {
        case 36, 76: advance(); return true                      // Return / Enter
        case 53: if !model.isFirstStep { goBack(); return true } // Escape
            return false
        case 123, 124:                                           // Arrows retune the color step.
            guard model.step == .color else { return false }
            let delta = event.keyCode == 123 ? -1 : 1
            selectColor(min(ArkPalette.spaceColors.count - 1, max(0, model.colorIndex + delta)))
            return true
        default: return false
        }
    }

    /// The live chord for a training target, so a remapped New Tab is taught as itself.
    static func trainingCombo(for target: String) -> KeyCombo {
        ShortcutCommand(onboardingTarget: target).map { ShortcutStore.shared.combo(for: $0) } ?? KeyCombo(target, .command)
    }
    private func recordShortcut(_ key: String) {
        guard model.recordShortcut(key) else { keycaps[key]?.pulse(); return }
        keycaps[key]?.markDone()
        if model.shortcutsDone {
            let work = DispatchWorkItem { [weak self] in self?.advance() }
            revealWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    private func cancelStagedReveals() {
        for work in revealWork { work.cancel() }
        revealWork.removeAll()
    }

    // MARK: Steps

    private func buildStep(_ step: OnboardingStep) -> NSView {
        switch step {
        case .hello: return buildHello()
        case .tour: return buildTour()
        case .bring: return buildBring()
        case .extensions: return buildExtensions()
        case .color: return buildColor()
        case .name: return buildName()
        case .favorites: return buildFavorites()
        case .shortcuts: return buildShortcuts()
        case .defaultBrowser: return buildDefaultBrowser()
        case .finale: return buildFinale()
        }
    }

    private func column(spacing: CGFloat = 16, _ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        for view in views { view.wantsLayer = true }
        return stack
    }

    private func buildHello() -> NSView {
        let icon = OnboardingIconView()
        icon.image = SettingsController.appIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(true); icon.setAccessibilityRole(.image)
        icon.setAccessibilityLabel("Bam burst sticker")
        // The site's hero tile: the icon with a "NEW!" sticker over its corner.
        let tile = NSView(); tile.translatesAutoresizingMaskIntoConstraints = false
        let sticker = BamSticker("NEW!", diameter: 64)
        tile.addSubview(icon); tile.addSubview(sticker)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 168), tile.heightAnchor.constraint(equalToConstant: 150),
            icon.widthAnchor.constraint(equalToConstant: 136), icon.heightAnchor.constraint(equalToConstant: 136),
            icon.leadingAnchor.constraint(equalTo: tile.leadingAnchor), icon.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            sticker.trailingAnchor.constraint(equalTo: tile.trailingAnchor), sticker.topAnchor.constraint(equalTo: tile.topAnchor)
        ])
        // Two lines like the site's hero; a wrapping label so nothing truncates.
        let title = OnboardingText.headline("The browser\nthat goes ", red: "Bam.", size: 60)
        let subtitle = OnboardingText.subtitle("Native, fast, built on your Mac’s own WebKit.\nLet’s set yours up — it takes about a minute.")
        let begin = OnboardingPillButton(title: "Begin", prominent: true)
        begin.target = self; begin.action = #selector(advance)
        return column(spacing: 22, [tile, title, subtitle, OnboardingSpacer(height: 4), begin])
    }

    private func stageHelloReveal(_ content: NSView) {
        guard let stack = content as? NSStackView else { return }
        let views = stack.arrangedSubviews
        for view in views { view.alphaValue = 0 }
        for (index, view) in views.enumerated() {
            let work = DispatchWorkItem { [weak self] in
                guard self?.finished == false else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.5
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().alphaValue = 1
                }
                if index == 0 { OnboardingMotion.pop(view.layer, from: 0.4, wobble: true) }
                else { OnboardingMotion.rise(view.layer) }
            }
            revealWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(index) * 0.22, execute: work)
        }
    }

    private func buildColor() -> NSView {
        let title = OnboardingText.title("Pick your color.")
        let subtitle = OnboardingText.subtitle("Every Space wears one. Yours starts here —\nyou can change it any time.")
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 18
        for index in ArkPalette.spaceColors.indices {
            let swatch = OnboardingSwatchButton(colorIndex: index)
            swatch.target = self; swatch.action = #selector(swatchPicked(_:))
            swatch.isPicked = index == model.colorIndex
            swatches.append(swatch)
            row.addArrangedSubview(swatch)
        }
        let name = NSTextField(labelWithString: BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, model.colorIndex)])
        name.font = BamType.sans(15, weight: .bold)
        name.alignment = .center
        name.textColor = BamTheme.ink
        colorNameLabel = name
        let next = OnboardingPillButton(title: "Keep going", prominent: true)
        next.target = self; next.action = #selector(advance)
        return column(spacing: 18, [title, subtitle, OnboardingSpacer(height: 6), row, name, OnboardingSpacer(height: 6), next])
    }

    @objc private func swatchPicked(_ sender: OnboardingSwatchButton) { selectColor(sender.colorIndex) }

    private func selectColor(_ index: Int) {
        guard ArkPalette.spaceColors.indices.contains(index) else { return }
        model.colorIndex = index
        for swatch in swatches { swatch.isPicked = swatch.colorIndex == index }
        colorNameLabel?.stringValue = BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, index)]
        overlay.tint(colorIndex: index, glow: 1, animated: !Self.reduceMotion)
    }

    private func buildName() -> NSView {
        let title = OnboardingText.title("Name your first Space.")
        let subtitle = OnboardingText.subtitle("Work, play, plotting — what happens here?")
        let field = OnboardingNameField(string: model.spaceName)
        field.placeholderAttributedString = NSAttributedString(
            string: "Studio", attributes: [.foregroundColor: BamTheme.muted.withAlphaComponent(0.5),
                                           .font: OnboardingText.display(32, weight: .bold),
                                           .paragraphStyle: OnboardingText.centered])
        field.delegate = self
        field.escape = { [weak self] in self?.goBack() }
        field.target = self; field.action = #selector(advance)
        nameField = field
        let fieldWrap = OnboardingFieldBox(field: field)
        let symbols = NSStackView()
        symbols.orientation = .horizontal; symbols.spacing = 8
        for symbol in BrowserSpace.symbols {
            let button = OnboardingSymbolButton(symbol: symbol)
            button.isPicked = symbol == model.spaceSymbol
            button.target = self; button.action = #selector(symbolPicked(_:))
            symbols.addArrangedSubview(button)
        }
        let next = OnboardingPillButton(title: "Keep going", prominent: true)
        next.target = self; next.action = #selector(advance)
        return column(spacing: 18, [title, subtitle, OnboardingSpacer(height: 4), fieldWrap, symbols, OnboardingSpacer(height: 6), next])
    }

    @objc private func symbolPicked(_ sender: OnboardingSymbolButton) {
        model.spaceSymbol = sender.symbol
        guard let row = sender.superview as? NSStackView else { return }
        for case let button as OnboardingSymbolButton in row.arrangedSubviews {
            button.isPicked = button.symbol == sender.symbol
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let nameField { model.spaceName = nameField.stringValue }
    }

    private func buildFavorites() -> NSView {
        let title = OnboardingText.title("Bring your favorites.")
        let subtitle = OnboardingText.subtitle("Straight from Chrome’s bookmarks bar. They’ll live\nat the top of your sidebar — tweak the picks below.")
        let grid = NSStackView()
        grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 6
        var rowStack: NSStackView?
        for (index, bookmark) in model.bookmarks.enumerated() {
            if index % 2 == 0 {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
                row.distribution = .fillEqually
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalToConstant: 460).isActive = true
                grid.addArrangedSubview(row); rowStack = row
            }
            let toggle = OnboardingBookmarkToggle(bookmark: bookmark,
                                                  checked: model.selectedBookmarkAddresses.contains(bookmark.address))
            toggle.target = self; toggle.action = #selector(bookmarkToggled(_:))
            rowStack?.addArrangedSubview(toggle)
        }
        // A lone last row keeps column rhythm instead of stretching wide.
        if model.bookmarks.count % 2 == 1 { rowStack?.addArrangedSubview(NSView()) }
        let next = OnboardingPillButton(title: "Add favorites", prominent: true)
        next.target = self; next.action = #selector(advance)
        return column(spacing: 16, [title, subtitle, OnboardingSpacer(height: 2), grid, OnboardingSpacer(height: 6), next])
    }

    /// A short tour of what Bam actually does; each card names a real feature and how to reach it.
    private func buildTour() -> NSView {
        let title = OnboardingText.title("The good parts, built in.")
        let subtitle = OnboardingText.subtitle("A sidebar on the left, and everything else out of the way.")
        let features: [(String, String, String)] = [
            ("square.stack.3d.up", "Spaces", "Separate sidebars for work, home or one project. Swipe between them."),
            ("eye", "Peek", "Open a link over your page, then close it right where you were."),
            ("rectangle.split.2x1", "Split View", "Two pages side by side with a draggable divider."),
            ("pip", "Picture in Picture", "Leave a playing video and it floats. Pinch to resize it.")
        ]
        let grid = NSStackView(); grid.orientation = .vertical; grid.spacing = 12
        for pair in stride(from: 0, to: features.count, by: 2) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12; row.distribution = .fillEqually
            for (symbol, name, detail) in features[pair..<min(pair + 2, features.count)] {
                row.addArrangedSubview(OnboardingFeatureCard(symbol: symbol, title: name, detail: detail))
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 520).isActive = true
            grid.addArrangedSubview(row)
        }
        let next = OnboardingPillButton(title: "Continue", prominent: true)
        next.target = self; next.action = #selector(advance)
        return column(spacing: 18, [title, subtitle, OnboardingSpacer(height: 4), grid, OnboardingSpacer(height: 6), next])
    }

    /// Offered only when Arc's layout file is on this Mac. Choosing it opens Bam's own Import from
    /// Arc sheet after setup, with its preview; nothing is imported until you confirm there.
    private func buildBring() -> NSView {
        let title = OnboardingText.title("Coming from Arc?")
        let subtitle = OnboardingText.subtitle("Bring your Spaces, folders, pinned tabs and Favorites.\nYou’ll see exactly what comes in before anything changes.")
        let bring = OnboardingPillButton(title: "Bring from Arc", prominent: true)
        bring.target = self; bring.action = #selector(bringFromArc)
        let fresh = OnboardingQuietButton(title: "Start fresh")
        fresh.target = self; fresh.action = #selector(startFresh)
        return column(spacing: 18, [title, subtitle, OnboardingSpacer(height: 10), bring, fresh])
    }
    @objc private func bringFromArc() { model.bringsFromArc = true; advance() }
    @objc private func startFresh() { model.bringsFromArc = false; advance() }

    /// Optional: name a password manager and Add Extensions opens searching for it after setup.
    /// Nothing is installed here; you review it there like any extension.
    private func buildExtensions() -> NSView {
        let title = OnboardingText.title("Your password manager?")
        let subtitle = OnboardingText.subtitle("Pick yours and Bam will open Add Extensions with it after setup.\nYou review its permissions there before it can do anything.")
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
        for (index, name) in OnboardingModel.passwordManagers.enumerated() {
            let button = OnboardingPillButton(title: name, prominent: model.passwordManager == name)
            button.keyEquivalent = ""
            button.tag = index
            button.target = self; button.action = #selector(passwordManagerPicked(_:))
            button.setAccessibilityLabel("Find \(name) after setup")
            row.addArrangedSubview(button)
        }
        let later = OnboardingQuietButton(title: "Not now")
        later.target = self; later.action = #selector(noPasswordManager)
        return column(spacing: 18, [title, subtitle, OnboardingSpacer(height: 8), row, later])
    }
    @objc private func passwordManagerPicked(_ sender: NSButton) {
        let names = OnboardingModel.passwordManagers
        model.choosePasswordManager(names.indices.contains(sender.tag) ? names[sender.tag] : nil)
        advance()
    }
    @objc private func noPasswordManager() { model.choosePasswordManager(nil); advance() }

    @objc private func bookmarkToggled(_ sender: OnboardingBookmarkToggle) {
        model.toggleBookmark(sender.bookmark.address)
    }

    private func buildShortcuts() -> NSView {
        let title = OnboardingText.title("Learn two moves.")
        let subtitle = OnboardingText.subtitle("Bam is fastest from the keyboard. Try them now — really.")
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 36; row.alignment = .top
        let targets = [("t", "Open anything"), ("s", "Hide the sidebar")]
        for (key, caption) in targets {
            let keycap = OnboardingKeycapView(chord: Self.trainingCombo(for: key).display, caption: caption)
            if model.shortcutsCompleted.contains(key) {
                keycap.markDone(animated: false)
            }
            keycaps[key] = keycap
            row.addArrangedSubview(keycap)
        }
        let next = OnboardingPillButton(title: model.shortcutsDone ? "Keep going" : "I’ll learn later", prominent: model.shortcutsDone)
        next.target = self; next.action = #selector(advance)
        return column(spacing: 20, [title, subtitle, OnboardingSpacer(height: 8), row, OnboardingSpacer(height: 10), next])
    }

    private func buildDefaultBrowser() -> NSView {
        let title = OnboardingText.title("Make it official?")
        let subtitle = OnboardingText.subtitle("Links from other apps would open in Bam.\nmacOS will ask you to confirm.")
        let primary = OnboardingPillButton(title: "Make Bam my default", prominent: true)
        // Every step so far taught Return to mean "continue"; a system-level
        // change must never ride on that habit, so Return skips instead.
        primary.keyEquivalent = ""
        primary.target = self; primary.action = #selector(requestDefaultBrowser)
        let later = OnboardingQuietButton(title: "Maybe later")
        later.target = self; later.action = #selector(advance)
        return column(spacing: 18, [title, subtitle, OnboardingSpacer(height: 10), primary, later])
    }

    @objc private func requestDefaultBrowser() {
        // The system confirmation arrives asynchronously and on its own terms;
        // the sequence moves on so a dismissal never strands this screen.
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                 toOpenURLsWithScheme: "http") { _ in }
        advance()
    }

    private func buildFinale() -> NSView {
        let title = OnboardingText.headline("That’s it. ", red: "Bam.", size: 60)
        let names = BrowserSpace.colorNames
        let dress = model.colorIndex == BrowserSpace.prismColorIndex ? "every color at once"
            : model.colorIndex == BrowserSpace.clearColorIndex ? "glass"
            : names[min(names.count - 1, model.colorIndex)].lowercased()
        let next: String
        switch model.followUp {
        case .importFromArc: next = "\nNext, Bam shows what it will bring from Arc."
        case .findExtension(let name): next = "\nNext, Bam opens Add Extensions with \(name)."
        case .none: next = ""
        }
        let summary = OnboardingText.subtitle("“\(model.result.spaceName)” is dressed in \(dress) and ready to go.\(next)")
        let start = OnboardingPillButton(title: "Start browsing", prominent: true)
        start.target = self; start.action = #selector(advance)
        return column(spacing: 20, [title, summary, OnboardingSpacer(height: 10), start])
    }

    private func celebrate() {
        guard !Self.reduceMotion else { return }
        overlay.burstConfetti(accentIndex: model.colorIndex)
        NSSound(named: "Pop")?.play()
    }
}

@MainActor final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension OnboardingController: NSWindowDelegate {
    /// The red button means "get me out", not "lose my progress silently":
    /// it runs the same skip path, with its fade, and never tears the window
    /// down out from under the sequence.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        skip()
        return false
    }
}

// MARK: - Motion

@MainActor enum OnboardingMotion {
    /// AppKit pins layer-backed views at anchorPoint (0,0); scaling or
    /// rotating there grows from the corner. Re-anchor at the center, keeping
    /// the rendered frame where it is.
    static func centerAnchor(_ layer: CALayer) {
        let target = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != target else { return }
        let bounds = layer.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: layer.position.x + (target.x - layer.anchorPoint.x) * bounds.width,
                                 y: layer.position.y + (target.y - layer.anchorPoint.y) * bounds.height)
        layer.anchorPoint = target
        CATransaction.commit()
    }
    static func pop(_ layer: CALayer?, from scale: CGFloat, wobble: Bool = false) {
        guard let layer else { return }
        centerAnchor(layer)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = scale; spring.toValue = 1
        spring.mass = 1; spring.stiffness = 210; spring.damping = 15
        spring.initialVelocity = 6
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
        guard wobble else { return }
        let tilt = CASpringAnimation(keyPath: "transform.rotation.z")
        tilt.fromValue = -0.10; tilt.toValue = 0
        tilt.mass = 1; tilt.stiffness = 160; tilt.damping = 9
        tilt.duration = tilt.settlingDuration
        layer.add(tilt, forKey: "wobble")
    }
    static func rise(_ layer: CALayer?) {
        guard let layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 14; rise.toValue = 0
        rise.duration = 0.5
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(rise, forKey: "rise")
    }
}

// MARK: - Backdrop

/// The stage: Bam's page paper (pink, plum in dark mode) with a soft glow in
/// the chosen Space colour, two faint bursts in the corners, confetti on the
/// finale. It swallows every event so the live browser underneath stays
/// untouched.
@MainActor final class OnboardingBackdropView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    private let glow = CAGradientLayer()
    private var prism: CAGradientLayer?
    private var confetti: CAEmitterLayer?
    private var paperAlpha: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.46)
        glow.endPoint = CGPoint(x: 1.05, y: 1.05)
        layer?.addSublayer(glow)
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        prism?.frame = bounds
        confetti?.frame = bounds
        confetti?.emitterPosition = CGPoint(x: bounds.midX, y: bounds.height + 8)
        confetti?.emitterSize = CGSize(width: bounds.width * 0.7, height: 1)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        BamTheme.bg.withAlphaComponent(paperAlpha).setFill(); bounds.fill()
        // Two big, quiet bursts peeking in from the corners, like the site's
        // sticker pile; the red wash keeps them in the paper rather than on it.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        BamTheme.red.withAlphaComponent(dark ? 0.16 : 0.09).setFill()
        let big = min(bounds.width, bounds.height) * 0.62
        BamSticker.burst(in: NSRect(x: -big * 0.42, y: -big * 0.38, width: big, height: big)).fill()
        BamSticker.burst(in: NSRect(x: bounds.width - big * 0.5, y: bounds.height - big * 0.55, width: big * 0.8, height: big * 0.8)).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    func tint(colorIndex: Int, glow glowStrength: CGFloat, animated: Bool) {
        let accent = ArkPalette.spaceColor(colorIndex)
        let glowColors = [accent.withAlphaComponent(0.30 * glowStrength).cgColor,
                          accent.withAlphaComponent(0).cgColor]
        if animated {
            let fade = CABasicAnimation(keyPath: "colors")
            fade.fromValue = glow.colors; fade.toValue = glowColors; fade.duration = 0.5
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(fade, forKey: "tint")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.colors = glowColors
        // Prism previews its live spectrum, softly, over the paper; Clear lets
        // the stage window go see-through so the desktop reads behind it.
        let prismActive = colorIndex == BrowserSpace.prismColorIndex
        if prismActive, prism == nil {
            let spectrum = PrismBackground.makeLayer()
            spectrum.frame = bounds
            spectrum.opacity = 0.35
            layer?.insertSublayer(spectrum, below: glow)
            prism = spectrum
        } else if !prismActive, let prism {
            // The spectrum's infinite animation stops when deselected.
            prism.removeFromSuperlayer()
            self.prism = nil
        }
        CATransaction.commit()
        let clear = colorIndex == BrowserSpace.clearColorIndex
        paperAlpha = clear ? 0.72 : 1
        needsDisplay = true
        if let window {
            window.isOpaque = !clear
            window.backgroundColor = clear ? .clear : BamTheme.bg
        }
    }

    func burstConfetti(accentIndex: Int) {
        confetti?.removeFromSuperlayer()
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.height + 8)
        emitter.emitterSize = CGSize(width: bounds.width * 0.7, height: 1)
        emitter.birthRate = 1
        // Sticker colours first, then the chosen Space colour: little bursts
        // and paper scraps.
        var palette: [(NSColor, Bool, Float)] = [
            (BamTheme.red, true, 22), (BamTheme.redDeep, false, 10),
            (NSColor(srgbRed: 0.98, green: 0.88, blue: 0.91, alpha: 1), false, 12),
            (.white, true, 8)
        ]
        palette.append((ArkPalette.spaceColor(accentIndex), true, 16))
        var cells: [CAEmitterCell] = []
        for (color, burst, rate) in palette {
            let cell = CAEmitterCell()
            cell.contents = Self.confettiImage(color: color, burst: burst)
            cell.birthRate = rate
            cell.lifetime = 4.2
            cell.velocity = 540; cell.velocityRange = 190
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 5
            cell.yAcceleration = 420
            cell.spin = 3.4; cell.spinRange = 5
            cell.scale = burst ? 0.55 : 0.6; cell.scaleRange = 0.35
            cell.alphaSpeed = -0.28
            cells.append(cell)
        }
        emitter.emitterCells = cells
        layer?.addSublayer(emitter)
        confetti = emitter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak emitter] in
            emitter?.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak emitter] in
            emitter?.removeFromSuperlayer()
            if self?.confetti === emitter { self?.confetti = nil }
        }
    }

    private static func confettiImage(color: NSColor, burst: Bool) -> CGImage? {
        let size = burst ? NSSize(width: 18, height: 18) : NSSize(width: 12, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            if burst { BamSticker.burst(in: rect).fill() }
            else { NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill() }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

// MARK: - Typography

/// The site's voice: Bricolage Grotesque headlines, Instrument Sans body.
@MainActor enum OnboardingText {
    static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 4
        return style
    }()
    static func display(_ size: CGFloat, weight: NSFont.Weight = .heavy) -> NSFont { BamType.display(size, weight: weight) }
    static func title(_ text: String, size: CGFloat = 46) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = display(size)
        label.textColor = BamTheme.ink
        label.alignment = .center
        return label
    }
    /// Ink words ending in a red "Bam.", wrapping, the way the site sets its hero.
    static func headline(_ words: String, red: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineHeightMultiple = 0.92
        let text = NSMutableAttributedString(string: words, attributes: [.font: display(size), .foregroundColor: BamTheme.ink, .paragraphStyle: style])
        text.append(NSAttributedString(string: red, attributes: [.font: display(size), .foregroundColor: BamTheme.red, .paragraphStyle: style]))
        label.attributedStringValue = text
        label.alignment = .center; label.isSelectable = false
        label.setAccessibilityLabel((words + red).replacingOccurrences(of: "\n", with: " "))
        return label
    }
    static func subtitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: BamType.sans(17), .foregroundColor: BamTheme.muted, .paragraphStyle: centered
        ])
        label.alignment = .center
        label.isSelectable = false
        return label
    }
}

/// The hello icon with a soft paper shadow that follows the appearance.
@MainActor final class OnboardingIconView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 0.35; layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        paint()
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    private func paint() { layer?.shadowColor = bamCG(BamTheme.shadow) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

@MainActor final class OnboardingSpacer: NSView {
    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
}

// MARK: - Controls

/// The site's button at stage size: a face resting on a lip, red for the main
/// move and paper for the quiet one. Pressing sinks the face onto the lip.
@MainActor final class OnboardingPillButton: NSButton {
    private let prominent: Bool
    private static let drop: CGFloat = 3
    init(title: String, prominent: Bool) {
        self.prominent = prominent
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        keyEquivalent = prominent ? "\r" : ""
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BamType.sans(16, weight: .bold),
            .foregroundColor: prominent ? BamTheme.white : BamTheme.ink
        ])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 50).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 176).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize; size.width += 56; return size
    }
    override func draw(_ dirtyRect: NSRect) {
        // NSButton is flipped: the lip sits along the bottom edge.
        let drop = Self.drop, pressed = isHighlighted, radius: CGFloat = 16
        let lip = NSRect(x: 0, y: drop, width: bounds.width, height: bounds.height - drop)
        let face = NSRect(x: 0, y: pressed ? drop : 0, width: bounds.width, height: bounds.height - drop)
        (prominent ? BamTheme.redDeep : BamTheme.line).setFill()
        NSBezierPath(roundedRect: lip, xRadius: radius, yRadius: radius).fill()
        (prominent ? BamTheme.red : BamTheme.card).setFill()
        NSBezierPath(roundedRect: face, xRadius: radius, yRadius: radius).fill()
        if !prominent {
            BamTheme.line.setStroke()
            let ring = NSBezierPath(roundedRect: face.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.75, yRadius: radius - 0.75)
            ring.lineWidth = 1.5; ring.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: pressed ? drop / 2 : -drop / 2)
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class OnboardingQuietButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BamType.sans(14, weight: .semibold),
            .foregroundColor: BamTheme.muted
        ])
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A round paper button with one symbol (Back).
@MainActor final class OnboardingGlyphButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        contentTintColor = BamTheme.ink
        layer?.cornerRadius = 17
        layer?.borderWidth = 1.5
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    private func paint() {
        layer?.backgroundColor = bamCG(BamTheme.card)
        layer?.borderColor = bamCG(BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class OnboardingSwatchButton: NSButton {
    let colorIndex: Int
    private let ring = CALayer()
    var isPicked = false {
        didSet {
            guard isPicked != oldValue else { return }
            updateSelection()
            if isPicked, !OnboardingController.reduceMotion { OnboardingMotion.pop(layer, from: 0.84) }
        }
    }
    init(colorIndex: Int) {
        self.colorIndex = colorIndex
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        if colorIndex == BrowserSpace.prismColorIndex {
            // The Prism swatch wears a brighter slice of its own spectrum.
            let rainbow = CAGradientLayer()
            rainbow.colors = (0..<6).map {
                NSColor(calibratedHue: CGFloat($0) / 6, saturation: 0.55, brightness: 0.88, alpha: 1).cgColor
            }
            rainbow.startPoint = CGPoint(x: 0, y: 1); rainbow.endPoint = CGPoint(x: 1, y: 0)
            rainbow.frame = NSRect(x: 0, y: 0, width: 54, height: 54)
            rainbow.cornerRadius = 27
            layer?.insertSublayer(rainbow, at: 0)
        } else if colorIndex != BrowserSpace.clearColorIndex {
            layer?.backgroundColor = ArkPalette.spaceColor(colorIndex).cgColor
        }
        layer?.cornerRadius = 27
        ring.cornerRadius = 32
        ring.frame = NSRect(x: -5, y: -5, width: 64, height: 64)
        layer?.addSublayer(ring)
        setAccessibilityLabel("\(BrowserSpace.colorNames[min(BrowserSpace.colorNames.count - 1, colorIndex)]) Space color")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 54).isActive = true
        heightAnchor.constraint(equalToConstant: 54).isActive = true
        paint()
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    private func paint() {
        // Clear is a paper disc with a hairline; the ring is ink on every swatch.
        if colorIndex == BrowserSpace.clearColorIndex {
            layer?.backgroundColor = bamCG(BamTheme.card)
            layer?.borderWidth = 1.5
            layer?.borderColor = bamCG(BamTheme.line)
        }
        ring.borderColor = bamCG(BamTheme.ink)
    }
    private func updateSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.borderWidth = isPicked ? 3 : 0
        CATransaction.commit()
        setAccessibilityValue(isPicked ? "Selected" : "")
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class OnboardingSymbolButton: NSButton {
    let symbol: String
    var isPicked = false { didSet { paint() } }
    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        setAccessibilityLabel("Space icon \(symbol)")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 38).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    private func paint() {
        image = SidebarSymbol.image(named: symbol, color: isPicked ? BamTheme.red : BamTheme.ink, pointSize: 14)
        layer?.backgroundColor = bamCG(isPicked ? BamTheme.redWash : BamTheme.card)
        layer?.borderColor = bamCG(isPicked ? BamTheme.red : BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Centres a tall display face inside the field; NSTextFieldCell otherwise
/// pins the line to the top and the variable font's ascenders clip.
@MainActor final class OnboardingNameCell: NSTextFieldCell {
    /// super.select/edit call drawingRect again; the flag keeps the centring
    /// from being applied twice to the field editor.
    private var placingEditor = false
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inner = super.drawingRect(forBounds: rect)
        guard !placingEditor else { return inner }
        let needed = cellSize(forBounds: rect).height
        let delta = inner.height - needed
        if delta > 0 { inner.origin.y += delta / 2; inner.size.height = needed }
        return inner
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        let centred = drawingRect(forBounds: rect)
        placingEditor = true; defer { placingEditor = false }
        super.select(withFrame: centred, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        let centred = drawingRect(forBounds: rect)
        placingEditor = true; defer { placingEditor = false }
        super.edit(withFrame: centred, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}

@MainActor final class OnboardingNameField: NSTextField {
    var escape: (() -> Void)?
    /// Fires when focus arrives or leaves, so the box can colour its hairline.
    var onFocusChange: (() -> Void)?
    override class var cellClass: AnyClass? { get { OnboardingNameCell.self } set {} }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return accepted
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = OnboardingText.display(32, weight: .bold)
        textColor = BamTheme.ink
        alignment = .center
        // Single-line mode lays the variable display face out against its
        // hhea metrics and clips the ascenders; the ordinary path measures glyphs.
        usesSingleLineMode = false
        maximumNumberOfLines = 1
        cell?.wraps = false; cell?.isScrollable = true
        cell?.lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("Space name")
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    override func cancelOperation(_ sender: Any?) { escape?() }
}

/// A paper card around the name field; the hairline turns red while typing.
@MainActor final class OnboardingFieldBox: NSView {
    private weak var field: OnboardingNameField?
    init(field: OnboardingNameField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 420),
            heightAnchor.constraint(equalToConstant: 76),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22)
        ])
        paint()
        field.onFocusChange = { [weak self] in self?.paint() }
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    private func paint() {
        let editing = field?.currentEditor() != nil
        layer?.backgroundColor = bamCG(BamTheme.card)
        layer?.borderColor = bamCG(editing ? BamTheme.red : BamTheme.line)
        layer?.shadowColor = bamCG(BamTheme.line)
        layer?.shadowOpacity = 1; layer?.shadowRadius = 0
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// A site keycap at training size: paper cap on a hard lip, the chord in
/// mono, a caption below. Done turns the cap red-rimmed with a check sticker.
@MainActor final class OnboardingKeycapView: NSView {
    private let check = NSImageView()
    private let cap = NSView()
    private let keyLabel: NSTextField
    private var done: NSColor?
    init(chord: String, caption: String) {
        keyLabel = NSTextField(labelWithString: chord)
        super.init(frame: .zero)
        wantsLayer = true
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 16
        cap.layer?.borderWidth = 1.5
        cap.layer?.masksToBounds = false
        keyLabel.font = BamType.mono(26, weight: .bold)
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = BamType.sans(14, weight: .medium)
        captionLabel.textColor = BamTheme.muted
        captionLabel.alignment = .center
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
        check.symbolConfiguration = .init(pointSize: 24, weight: .bold)
        check.alphaValue = 0
        check.wantsLayer = true
        for view in [cap, keyLabel, captionLabel, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Press \(chord): \(caption)")
        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.centerXAnchor.constraint(equalTo: centerXAnchor),
            cap.widthAnchor.constraint(equalToConstant: 124),
            cap.heightAnchor.constraint(equalToConstant: 72),
            keyLabel.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: cap.centerYAnchor, constant: -1),
            captionLabel.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 12),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: cap.widthAnchor),
            check.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: 11),
            check.topAnchor.constraint(equalTo: cap.topAnchor, constant: -11)
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
    private func paint() {
        cap.layer?.backgroundColor = cap.bamCG(BamTheme.card)
        cap.layer?.borderColor = cap.bamCG(done ?? BamTheme.line)
        // The lip: a hard, unblurred shadow three points down.
        cap.layer?.shadowColor = cap.bamCG(done?.withAlphaComponent(0.9) ?? BamTheme.ink.withAlphaComponent(0.22))
        cap.layer?.shadowOpacity = 1
        cap.layer?.shadowRadius = 0
        cap.layer?.shadowOffset = CGSize(width: 0, height: -3)
        keyLabel.textColor = done ?? BamTheme.ink
        check.contentTintColor = done ?? BamTheme.red
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }

    func markDone(animated: Bool = true) {
        done = BamTheme.red
        check.alphaValue = 1
        paint()
        setAccessibilityValue("Done")
        guard animated, !OnboardingController.reduceMotion else { return }
        OnboardingMotion.pop(check.layer, from: 0.2)
        OnboardingMotion.pop(cap.layer, from: 0.92)
    }
    func pulse() {
        guard !OnboardingController.reduceMotion else { return }
        OnboardingMotion.pop(cap.layer, from: 0.95)
    }
}

@MainActor final class OnboardingBookmarkToggle: NSButton {
    let bookmark: OnboardingBookmark
    init(bookmark: OnboardingBookmark, checked: Bool) {
        self.bookmark = bookmark
        super.init(frame: .zero)
        setButtonType(.switch)
        let host = URL(string: bookmark.address)?.host.map { " — \($0)" } ?? ""
        attributedTitle = NSAttributedString(
            string: bookmark.title,
            attributes: [.font: BamType.sans(14, weight: .medium), .foregroundColor: BamTheme.ink])
        state = checked ? .on : .off
        lineBreakMode = .byTruncatingTail
        toolTip = bookmark.title + host
        setAccessibilityLabel("Favorite \(bookmark.title)")
    }
    required init?(coder: NSCoder) { fatalError("Onboarding is created programmatically") }
}

/// Progress dots: the current step is a red pill, the others hairline dots.
@MainActor final class OnboardingDotsView: NSView {
    private var dotLayers: [CALayer] = []
    private var current = -1
    func configure(count: Int, current index: Int) {
        wantsLayer = true
        if dotLayers.count != count {
            for dot in dotLayers { dot.removeFromSuperlayer() }
            dotLayers = (0..<count).map { _ in
                let dot = CALayer(); dot.cornerRadius = 3.5; layer?.addSublayer(dot); return dot
            }
            invalidateIntrinsicContentSize()
        }
        current = index
        relayout()
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(max(0, dotLayers.count - 1)) * 15 + 22, height: 7)
    }
    override func layout() { super.layout(); relayout() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); relayout() }
    private func relayout() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(OnboardingController.reduceMotion ? 0 : 0.3)
        var x: CGFloat = 0
        for (index, dot) in dotLayers.enumerated() {
            let wide = index == current
            dot.frame = NSRect(x: x, y: 0, width: wide ? 22 : 7, height: 7)
            dot.backgroundColor = bamCG(wide ? BamTheme.red : BamTheme.ink.withAlphaComponent(0.18))
            x += (wide ? 22 : 7) + 8
        }
        CATransaction.commit()
    }
}

// MARK: - Browser integration

extension BrowserController {
    /// The onboarding overlay owns the window while it is up: Space swipes and
    /// chrome menu actions stand down, and transient chrome is put away.
    func setOnboardingActive(_ active: Bool) {
        suspendsChromeInteraction = active
        guard active else { return }
        cancelPaging(); dismissAddress(); findBar.hide(); pageFeedback.hide()
    }

    func applyOnboarding(_ result: OnboardingResult) {
        cancelPaging()
        OnboardingApplication.apply(result, to: &session)
        showActive(); refreshPaletteResults(); save(); onSpacesChanged?()
    }
}

/// One feature in the tour: a symbol, its name and one sentence, on a soft card.
@MainActor final class OnboardingFeatureCard: NSView {
    init(symbol: String, title: String, detail: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1.5
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        icon.contentTintColor = BamTheme.red
        let name = NSTextField(labelWithString: title)
        name.font = BamType.sans(15, weight: .bold); name.textColor = BamTheme.ink
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = BamType.sans(12.5); text.textColor = BamTheme.muted
        let stack = NSStackView(views: [icon, name, text])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 112)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(detail)")
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() {
        layer?.backgroundColor = bamCG(BamTheme.card.withAlphaComponent(0.82))
        layer?.borderColor = bamCG(BamTheme.line)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}
