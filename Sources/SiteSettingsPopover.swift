import AppKit
import WebKit

/// What the site-settings popover can do. Each closure is an existing Bam action; the
/// browser supplies them (zoom as View › Zoom, keep-awake as Settings, Manage Extensions).
struct SiteSettingsActions {
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var resetZoom: () -> Void = {}
    var setKeepsAwake: (Bool) -> Void = { _ in }
    var manageSiteAccess: (UUID) -> Void = { _ in }
    var copyLink: () -> Void = {}
    var openSettings: () -> Void = {}
}

/// The page's own facts for the popover: address, connection and certificate, and zoom.
/// Keep-awake and extensions come from the browser, which owns them.
@MainActor enum SiteSettingsSource {
    static func context(for web: WKWebView, keepsAwake: Bool?, extensions: [SiteSettingsContext.ExtensionItem]) -> SiteSettingsContext {
        SiteSettingsContext(url: web.url,
                            connection: SiteSettingsModel.connection(url: web.url, onlySecureContent: web.hasOnlySecureContent,
                                                                     certificate: certificateSummary(web.serverTrust)),
                            pageZoom: Double(web.pageZoom), keepsAwake: keepsAwake, extensions: extensions,
                            blocksAds: ContentBlockingPreference.site(web.url) == nil || !ContentBlocking.shared.isAvailable ? nil
                                : ContentBlockingPreference.blocks(web.url) || !ContentBlockingPreference.isEnabled,
                            adBlockerOn: ContentBlockingPreference.isEnabled)
    }
    static func certificateSummary(_ trust: SecTrust?) -> String? {
        guard let trust, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}

/// The popover by the address: who you're connected to, page zoom, keep-awake, and which
/// extensions can use this site, each with a way into Site Access.
@MainActor final class SiteSettingsPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var controller: SiteSettingsViewController?
    var isShown: Bool { popover?.isShown == true }

    func show(relativeTo anchor: NSView, context: SiteSettingsContext, actions: SiteSettingsActions) {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let controller = SiteSettingsViewController(actions: actions)
        controller.screenHeight = anchor.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 700
        controller.update(context)
        let surface = NSPopover()
        surface.behavior = .transient
        surface.animates = !BamTheme.reduceMotion
        // Standard content area (not full-size): the 320-point view fills it exactly, inset from the popover's
        // border and arrow, so nothing is clipped and no popover chrome shows beside it.
        surface.contentViewController = controller
        surface.contentSize = controller.preferredContentSize
        surface.delegate = self
        popover = surface; self.controller = controller
        // Below the address field on screen, whichever way the anchor's coordinates run.
        surface.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }
    /// Live values after an action (zoom, keep-awake) or a navigation.
    func update(_ context: SiteSettingsContext) {
        guard let controller, isShown else { return }
        controller.update(context)
        popover?.contentSize = controller.preferredContentSize
    }
    func close() { popover?.performClose(nil) }
    func popoverDidClose(_ notification: Notification) { popover = nil; controller = nil }
}

@MainActor private final class SiteSettingsViewController: NSViewController {
    private let actions: SiteSettingsActions
    private let column = NSStackView()
    /// The anchor screen's visible height; the extension list scrolls within what is left of it.
    var screenHeight: CGFloat = 700
    private static let rowHeight: CGFloat = 40, rowSpacing: CGFloat = 6
    init(actions: SiteSettingsActions) { self.actions = actions; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = SiteSettingsBackground(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor), column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor), column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 320)
        ])
        view = root
        view.setAccessibilityLabel("Site settings")
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.autorecalculatesKeyViewLoop = true }

    func update(_ context: SiteSettingsContext) {
        _ = view
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width: CGFloat = 292
        func full(_ view: NSView) { column.addArrangedSubview(view); view.widthAnchor.constraint(equalToConstant: width).isActive = true }

        // Who you're connected to.
        let title = label(SiteSettingsModel.title(context), font: BamType.sans(15, weight: .bold), color: BamTheme.ink)
        title.lineBreakMode = .byTruncatingMiddle
        full(title)
        let security = SiteSettingsModel.security(context)
        let icon = NSImageView(image: NSImage(systemSymbolName: security.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = security.warning ? BamTheme.red : BamTheme.muted
        let headline = label(security.headline, font: BamType.sans(12.5, weight: .semibold), color: security.warning ? BamTheme.red : BamTheme.ink)
        let securityRow = NSStackView(views: [icon, headline]); securityRow.spacing = 6
        securityRow.setAccessibilityElement(true); securityRow.setAccessibilityLabel(security.headline + (security.detail.map { ". " + $0 } ?? ""))
        full(securityRow)
        if let detail = security.detail {
            let text = NSTextField(wrappingLabelWithString: detail)
            text.font = BamType.sans(11.5); text.textColor = BamTheme.muted; text.setAccessibilityElement(false)
            full(text)
        }
        divider()

        // Page zoom, with View › Zoom's limits.
        let zoom = SiteSettingsModel.zoom(context)
        let minus = symbolButton("minus", "Zoom Out", enabled: zoom.canZoomOut) { [actions] in actions.zoomOut() }
        let plus = symbolButton("plus", "Zoom In", enabled: zoom.canZoomIn) { [actions] in actions.zoomIn() }
        let level = label(zoom.label, font: BamType.mono(12), color: BamTheme.ink)
        level.setAccessibilityLabel("Page zoom \(zoom.label)")
        let reset = textButton("Reset", enabled: zoom.canReset) { [actions] in actions.resetZoom() }
        let zoomRow = NSStackView(views: [label("Zoom", font: BamType.sans(13, weight: .medium), color: BamTheme.ink), NSView(), minus, level, plus, reset])
        zoomRow.spacing = 8
        full(zoomRow)

        if let awake = context.keepsAwake {
            let toggle = BamToggle(frame: .zero)
            toggle.isOn = awake
            toggle.onChange = { [actions] in actions.setKeepsAwake($0) }
            toggle.setAccessibilityLabel("Keep this site awake")
            let awakeRow = NSStackView(views: [label("Keep this site awake", font: BamType.sans(13, weight: .medium), color: BamTheme.ink), NSView(), toggle])
            full(awakeRow)
        }

        if let blocks = context.blocksAds {
            let toggle = BamToggle(frame: .zero)
            toggle.isOn = blocks && context.adBlockerOn
            toggle.isEnabled = context.adBlockerOn
            let url = context.url
            // The page reloads, as it must for WebKit to load what was blocked (or stop loading it).
            toggle.onChange = { ContentBlocking.shared.setBlocks($0, forSiteOf: url) }
            toggle.setAccessibilityLabel("Block ads and trackers")
            let name = label("Block ads and trackers", font: BamType.sans(13, weight: .medium), color: context.adBlockerOn ? BamTheme.ink : BamTheme.muted)
            full(NSStackView(views: [name, NSView(), toggle]))
            if let detail = SiteSettingsModel.adsDetail(context) {
                let text = label(detail, font: BamType.sans(11.5), color: BamTheme.muted)
                full(text)
                column.setCustomSpacing(12, after: text)
                if let previous = column.arrangedSubviews.dropLast().last { column.setCustomSpacing(3, after: previous) }
            }
        }

        // Extensions and their access to this site.
        let items = SiteSettingsModel.extensions(context)
        var listHeight: NSLayoutConstraint?
        if !items.isEmpty {
            divider()
            full(label("Extensions", font: BamType.sans(11, weight: .bold), color: BamTheme.muted))
            // Rows scroll in a bounded list so a long list never pushes the popover off a small screen;
            // the actions above and below it stay visible.
            let list = NSStackView(); list.orientation = .vertical; list.alignment = .leading; list.spacing = Self.rowSpacing
            list.translatesAutoresizingMaskIntoConstraints = false
            let document = SiteSettingsListDocument(); document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(list)
            let scroll = NSScrollView()
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.documentView = document
            scroll.setAccessibilityLabel("Extensions on this site")
            NSLayoutConstraint.activate([
                list.leadingAnchor.constraint(equalTo: document.leadingAnchor), list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                list.topAnchor.constraint(equalTo: document.topAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            full(scroll)
            let height = scroll.heightAnchor.constraint(equalToConstant: 0); height.isActive = true
            listHeight = height
            for item in items {
                let name = label(item.name, font: BamType.sans(13, weight: .medium), color: BamTheme.ink)
                name.lineBreakMode = .byTruncatingTail
                let status = label(SiteSettingsModel.accessText(item.access), font: BamType.sans(11.5), color: BamTheme.muted)
                let text = NSStackView(views: [name, status]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
                text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                let id = item.id
                let manage = textButton("Site Access…", enabled: true) { [actions] in actions.manageSiteAccess(id) }
                manage.setAccessibilityLabel("Site Access for \(item.name)")
                let row = NSStackView(views: [text, NSView(), manage]); row.alignment = .centerY
                row.translatesAutoresizingMaskIntoConstraints = false
                list.addArrangedSubview(row)
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        divider()
        let copy = textButton("Copy Link", enabled: context.url != nil) { [actions] in actions.copyLink() }
        let settings = textButton("Settings…", enabled: true) { [actions] in actions.openSettings() }
        full(NSStackView(views: [copy, NSView(), settings]))
        view.layoutSubtreeIfNeeded()
        if let listHeight {
            // Fixed parts measured with an empty list; the list gets the rest of the screen (less a margin).
            let fixed = view.fittingSize.height
            listHeight.constant = SiteSettingsModel.extensionListHeight(rows: items.count, rowHeight: Self.rowHeight, spacing: Self.rowSpacing,
                                                                        available: screenHeight - fixed - 48)
            view.layoutSubtreeIfNeeded()
        }
        preferredContentSize = view.fittingSize
    }

    private func divider() {
        let line = NSBox(); line.boxType = .separator
        column.addArrangedSubview(line); line.widthAnchor.constraint(equalToConstant: 292).isActive = true
    }
    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = font; label.textColor = color; return label
    }
    private func symbolButton(_ symbol: String, _ name: String, enabled: Bool, _ run: @escaping () -> Void) -> NSButton {
        let button = SiteSettingsButton(run: run)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        button.isBordered = false; button.contentTintColor = BamTheme.ink; button.isEnabled = enabled
        button.toolTip = name; button.setAccessibilityLabel(name)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
    private func textButton(_ title: String, enabled: Bool, _ run: @escaping () -> Void) -> NSButton {
        let button = SiteSettingsButton(run: run)
        button.isBordered = false; button.isEnabled = enabled
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BamType.sans(12, weight: .semibold), .foregroundColor: enabled ? BamTheme.red : BamTheme.muted
        ])
        return button
    }
}

@MainActor private final class SiteSettingsButton: NSButton {
    private let run: () -> Void
    init(run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        target = self; action = #selector(press)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func press() { run() }
    /// Tabbing to a button in the scrolling extension list brings it into view.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds) }
        return accepted
    }
}

@MainActor private final class SiteSettingsBackground: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; paint() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func paint() { layer?.backgroundColor = bamCG(BamTheme.surface) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}

/// The scrolling list's document, laid out top-down.
@MainActor private final class SiteSettingsListDocument: NSView {
    override var isFlipped: Bool { true }
}
