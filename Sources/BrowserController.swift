import AppKit
import WebKit
import QuartzCore

/// The slowly shifting spectrum a Prism Space wears. Hues stay dark and
/// desaturated enough that sidebar text keeps its contrast at every phase.
@MainActor enum PrismBackground {
    static func makeLayer(dark: Bool = true) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0.1, y: 1)
        layer.endPoint = CGPoint(x: 0.9, y: 0)
        let frames = colorFrames(dark: dark)
        layer.colors = frames[0]
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return layer }
        let cycle = CAKeyframeAnimation(keyPath: "colors")
        cycle.values = frames + [frames[0]]
        cycle.duration = 24
        cycle.calculationMode = .linear
        cycle.repeatCount = .infinity
        layer.add(cycle, forKey: "prism")
        return layer
    }
    private static func colorFrames(dark: Bool) -> [[CGColor]] {
        // A curated hue path (blue → violet → magenta → red → amber → teal)
        // that skips the muddy yellow-green band a plain wheel sweep hits.
        // Light chrome keeps the same path as pale washes so dark text reads.
        [0.62, 0.75, 0.88, 0.98, 0.08, 0.45].map { (hue: CGFloat) in
            dark ? [NSColor(calibratedHue: hue, saturation: 0.56, brightness: 0.34, alpha: 1).cgColor,
                    NSColor(calibratedHue: fmod(hue + 0.12, 1), saturation: 0.48, brightness: 0.47, alpha: 1).cgColor]
                 : [NSColor(calibratedHue: hue, saturation: 0.16, brightness: 0.95, alpha: 1).cgColor,
                    NSColor(calibratedHue: fmod(hue + 0.12, 1), saturation: 0.12, brightness: 0.97, alpha: 1).cgColor]
        }
    }
}

@MainActor final class CanvasView: NSView {
    var onLayout: (() -> Void)?
    var space = 0 {
        didSet {
            if space != oldValue { previewSpace = nil; previewTheme = nil; previewProgress = 0; updateAppearanceLayers() }
            needsDisplay = true
        }
    }
    var previewSpace: Int? { didSet { needsDisplay = true; updatePreviewEffects() } }
    var previewProgress: CGFloat = 0 { didSet { needsDisplay = true; updatePreviewEffects() } }
    /// The selected Space's imported Arc colors, drawn instead of its flat pair.
    var theme: SpaceTheme? { didSet { if theme != oldValue { needsDisplay = true } } }
    /// The theme of the Space a swipe is previewing, if it has one.
    var previewTheme: SpaceTheme? { didSet { if previewTheme != oldValue { needsDisplay = true } } }
    /// Fires when the selected Space's appearance needs the window itself to
    /// turn translucent (Clear) or opaque again.
    var onTranslucencyChange: ((Bool) -> Void)?
    /// Fires after the window's light/dark appearance changes, for layer colors.
    var onAppearanceChange: (() -> Void)?
    private var prism: CAGradientLayer?
    private var prismIsDark = true
    var isDark: Bool { effectiveAppearance.isDarkChrome }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        if let prism, prismIsDark != isDark {
            // Rebuild the spectrum for the new appearance, keeping its visibility.
            let hidden = prism.isHidden, opacity = prism.opacity
            prism.removeFromSuperlayer(); self.prism = nil
            installPrism(); self.prism?.isHidden = hidden; self.prism?.opacity = opacity
        }
        glass?.material = isDark ? .hudWindow : .sidebar
        onAppearanceChange?()
    }
    private var glass: NSVisualEffectView?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        prism?.frame = bounds
        CATransaction.commit()
        glass?.frame = bounds
        onLayout?()
    }
    /// Per-space window gradients. Onboarding previews the same table, so the
    /// chosen color shows exactly what the browser will wear. Prism and Clear
    /// carry fallback pairs here so swipe previews can still blend toward them.
    static let palettes: [[NSColor]] = [
        [NSColor(srgbRed: 0.20, green: 0.17, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.29, green: 0.23, blue: 0.29, alpha: 1)],
        [NSColor(srgbRed: 0.17, green: 0.24, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.27, green: 0.29, blue: 0.22, alpha: 1)],
        [NSColor(srgbRed: 0.16, green: 0.22, blue: 0.29, alpha: 1), NSColor(srgbRed: 0.26, green: 0.23, blue: 0.34, alpha: 1)],
        [NSColor(srgbRed: 0.29, green: 0.17, blue: 0.23, alpha: 1), NSColor(srgbRed: 0.34, green: 0.23, blue: 0.27, alpha: 1)],
        [NSColor(srgbRed: 0.28, green: 0.22, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.34, green: 0.28, blue: 0.21, alpha: 1)],
        [NSColor(srgbRed: 0.18, green: 0.19, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.28, green: 0.29, blue: 0.31, alpha: 1)],
        [NSColor(srgbRed: 0.19, green: 0.12, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.31, green: 0.15, blue: 0.28, alpha: 1)],
        [NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1), NSColor(srgbRed: 0.18, green: 0.18, blue: 0.21, alpha: 1)]
    ]
    /// Light chrome: pale washes of each Space color (Arc/Yab light windows),
    /// light enough for near-black sidebar text, tinted enough to tell Spaces apart.
    static let lightPalettes: [[NSColor]] = [
        [NSColor(srgbRed: 0.89, green: 0.86, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.94, green: 0.89, blue: 0.94, alpha: 1)],
        [NSColor(srgbRed: 0.87, green: 0.93, blue: 0.89, alpha: 1), NSColor(srgbRed: 0.93, green: 0.93, blue: 0.87, alpha: 1)],
        [NSColor(srgbRed: 0.86, green: 0.92, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.90, green: 0.89, blue: 0.97, alpha: 1)],
        [NSColor(srgbRed: 0.97, green: 0.87, blue: 0.90, alpha: 1), NSColor(srgbRed: 0.98, green: 0.91, blue: 0.90, alpha: 1)],
        [NSColor(srgbRed: 0.97, green: 0.92, blue: 0.84, alpha: 1), NSColor(srgbRed: 0.98, green: 0.94, blue: 0.88, alpha: 1)],
        [NSColor(srgbRed: 0.88, green: 0.88, blue: 0.90, alpha: 1), NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)],
        [NSColor(srgbRed: 0.90, green: 0.86, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.97, green: 0.87, blue: 0.93, alpha: 1)],
        [NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)]
    ]
    override func draw(_ dirtyRect: NSRect) {
        let palettes = isDark ? Self.palettes : Self.lightPalettes
        func pair(_ index: Int, _ theme: SpaceTheme?) -> [NSColor] {
            NSColor.themedCanvas(theme, colorIndex: index, dark: isDark) ?? palettes[min(palettes.count - 1, max(0, index))]
        }
        var colors = pair(space, theme)
        if let previewSpace {
            let progress = min(1, max(0, previewProgress))
            colors = zip(colors, pair(previewSpace, previewTheme)).map { $0.blended(withFraction: progress, of: $1) ?? $0 }
            // Glass hides during swipes, so previews into or out of Clear fade
            // the gradient itself toward transparency.
            let fromClear = space == BrowserSpace.clearColorIndex
            let toClear = previewSpace == BrowserSpace.clearColorIndex
            if fromClear || toClear {
                let clearAmount = fromClear && toClear ? 1 : fromClear ? 1 - progress : progress
                let alpha = 1 - clearAmount * 0.9
                colors = colors.map { $0.withAlphaComponent(alpha) }
            }
        } else if space == BrowserSpace.clearColorIndex {
            // At rest the glass and translucent window carry the look.
            colors = colors.map { $0.withAlphaComponent(0.1) }
        }
        NSGradient(colors: colors)?.draw(in: bounds, angle: 65)
    }

    private func updateAppearanceLayers() {
        let clear = space == BrowserSpace.clearColorIndex
        let prismActive = space == BrowserSpace.prismColorIndex
        if prismActive {
            installPrism()
        } else if let prism {
            // The spectrum's infinite animation must not outlive its Space.
            prism.removeFromSuperlayer()
            self.prism = nil
        }
        if clear, glass == nil {
            wantsLayer = true
            let view = NSVisualEffectView(frame: bounds)
            view.material = isDark ? .hudWindow : .sidebar
            view.blendingMode = .behindWindow
            view.state = .active
            view.autoresizingMask = [.width, .height]
            view.setAccessibilityElement(false)
            addSubview(view, positioned: .below, relativeTo: subviews.first)
            glass = view
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        prism?.isHidden = !prismActive
        prism?.opacity = 1
        CATransaction.commit()
        glass?.isHidden = !clear
        if lastReportedTranslucency != clear {
            lastReportedTranslucency = clear
            onTranslucencyChange?(clear)
        }
    }
    private var lastReportedTranslucency = false
    private func installPrism() {
        guard prism == nil else { return }
        wantsLayer = true
        // Re-creating per visit also re-samples Reduce Motion.
        prismIsDark = isDark
        let layer = PrismBackground.makeLayer(dark: prismIsDark)
        layer.frame = bounds
        self.layer?.insertSublayer(layer, at: 0)
        prism = layer
    }
    private func updatePreviewEffects() {
        let progress = Float(min(1, max(0, previewProgress)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if space == BrowserSpace.prismColorIndex {
            prism?.opacity = previewSpace == nil ? 1 : 1 - progress
        } else if previewSpace == BrowserSpace.prismColorIndex {
            // Fade the spectrum in while swiping toward a Prism Space.
            installPrism()
            prism?.isHidden = false
            prism?.opacity = progress
        } else if let prism, previewSpace == nil {
            prism.removeFromSuperlayer()
            self.prism = nil
        }
        CATransaction.commit()
        // Glass cannot blend; it steps aside during swipes so the gradient
        // fade in draw() shows, and returns when the preview settles.
        glass?.isHidden = !(space == BrowserSpace.clearColorIndex && previewSpace == nil)
    }
}

@MainActor final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class PaletteField: NSTextField {
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

@MainActor final class DismissView: NSView {
    var dismiss: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { dismiss?() }
}

@MainActor final class BrowserController: NSViewController, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let root = CanvasView()
    let sidebar = SidebarView(frame: .zero)
    let handle = ResizeHandleView(frame: .zero)
    /// The tab list's scroll thumb, in the gap between the sidebar and the card (above the resize handle, which it
    /// yields to everywhere but the visible thumb).
    let listScrollThumb = SidebarScrollIndicator(frame: .zero)
    let card = FlippedContainer()
    let webHost = FlippedContainer()
    let progress = NSView()
    let animator = CubicAnimator()
    let pagingAnimator = SpringAnimator()
    let pictureInPicture = PictureInPictureCoordinator()
    /// Auto-archive's timer and wake observer (BrowserTabArchive.swift).
    let tabArchiver = TabArchiver()
    let findBar = FindBarCoordinator()
    let pageFeedback = PageFeedbackCoordinator()
    let pageTools = PageToolsCoordinator()
    var pageCommandPasteboard: NSPasteboard = .general
    let downloads: DownloadCoordinator
    let profileStores: WebsiteProfileStore
    let favicons: WebsiteFaviconStore
    var faviconRefreshWork: DispatchWorkItem?
    var faviconDiscoveryWork: [UUID: DispatchWorkItem] = [:]
    var faviconDocumentGenerations: [UUID: UUID] = [:]
    /// Fixture seam (default on, normal behavior unchanged): when false, Bam runs no document favicon discovery script
    /// in any page, and pending discovery work and in-flight generations are dropped. Measurement fixtures that must
    /// not evaluate page JavaScript set it before loading their page.
    var documentFaviconDiscoveryEnabled = true {
        didSet {
            guard !documentFaviconDiscoveryEnabled else { return }
            faviconDiscoveryWork.values.forEach { $0.cancel() }; faviconDiscoveryWork.removeAll()
            faviconDocumentGenerations.removeAll()
        }
    }
    var profileLibraries: [UUID: BrowserLibrary] = [:]
    /// Frame observers that keep the traffic lights in the sidebar's toolbar row (placeWindowButtons).
    var windowButtonObservers: [NSObjectProtocol] = []
    var placingWindowButtons = false
    var library: BrowserLibrary { library(for: commandProfileID) }
    var confirmProfileChange: ((String) -> Bool)?
    var isApplyingProfileChange = false { didSet { invalidateExtensionSurfaceTopology() } }
    var extensionStorage: AnyObject?
    var extensionRefreshWork: DispatchWorkItem?
    /// Tabs whose loading state changed since extensions last saw them; a start and
    /// finish that land in one turn still produce a `tabs.onUpdated`.
    var extensionLoadingChanges: Set<UUID> = []
    var extensionSurfaceRevision: UInt64 = 0
    var extensionSurfaceWindow: ObjectIdentifier?
    var extensionTabIndices: [UUID: Int]?
    var peekExtensionIDs: [UUID: UUID] = [:] { didSet { invalidateExtensionSurfaceTopology() } }
    var navigationTokens: [UUID: UUID] = [:]
    var browserExtensionOrigins: [UUID: String] = [:]
    /// Tabs whose extension-page renderer was retired around an extension restart, by extension origin, and the tab
    /// whose page had focus (BrowserExtensionIntegration.handleExtensionRenderers).
    var retiredExtensionRenderers: [String: Set<UUID>] = [:]
    var retiredExtensionFocus: UUID?
    var retiredRendererProbes: [RetiredRendererProbe] = []
    /// Fixtures only (see ExtensionHostOverride); nil in the app.
    var extensionHostOverride: ExtensionHostOverride?
    var displayedTabID: UUID?
    var displayedMemberIDs: [UUID] = []
    var automaticDepartureQueue: [UUID] = []
    var automaticProbeInFlight = false
    private var automaticProbeToken: UUID?
    private var automaticProbeTabID: UUID?
    var retiringViews: [ObjectIdentifier: NSView] = [:]
    var splitCoordinators: [UUID: SplitViewCoordinator] = [:] { didSet { invalidateExtensionSurfaceTopology() } }
    var isShuttingDown = false { didSet { invalidateExtensionSurfaceTopology() } }
    /// While first-run onboarding covers the window, browser chrome must not
    /// react to swipes or menu commands behind it.
    var suspendsChromeInteraction = false
    var automaticallyShowsVideo = true
    var peeks: [UUID: PeekCoordinator] = [:] { didSet { invalidateExtensionSurfaceTopology() } }
    var littleWindows: [UUID: LittleBamController] = [:] { didSet { invalidateExtensionSurfaceTopology() } }
    var swipe = SpaceSwipeStateMachine()
    var scrollMonitor: Any?
    /// ⌃⇥ switcher, page thumbnails and tab-key monitors (TabSwitcher.swift).
    let tabNavigation = TabNavigationState()
    var trackingSwipe = false
    var pagingOffset: CGFloat = 0
    var pagingTarget: Int?
    private var pagingCommit: Int?
    private var capturedSpaceMomentum = false
    private var ignoreSpaceGestureUntilEnd = false
    private var rejectedSpaceGesture = false
    private var ignoredSpaceGestureEnd: DispatchWorkItem?
    private var unphasedScrollEnd: DispatchWorkItem?
    private var spaceScrollRoute = "idle"
    // A packet may visit the monitor, the tab list, and the sidebar responder.
    // Retain a small identity cache so nested dispatch cannot apply it twice.
    private var recentSpaceScrollEvents: [(event: NSEvent, consumed: Bool)] = []
    let sessionURL: URL
    var session: BrowserSession { didSet { invalidateExtensionSurfaceTopology() } }
    var displayedWidth: CGFloat
    var browsers: [UUID: WKWebView] = [:] { didSet { invalidateExtensionSurfaceTopology() } }
    var observations: [UUID: [NSKeyValueObservation]] = [:]
    var addressOverlay: DismissView?
    var addressField: PaletteField?
    var addressCard: NSView?
    var tabSearchResults: TabSearchResultsView?
    var paletteIcon: NSImageView?
    var paletteHint: NSTextField?
    var paletteSeparator: NSBox?
    var paletteGlow: NSView?
    var paletteTint: NSView?
    var spaceCreateIndicator: SpaceCreateIndicatorView?
    var spaceCreationPanel: SpaceCreationPanel?
    var spaceCreationKeyMonitor: Any?
    var paletteEnginePill: PaletteEnginePill?
    var paletteEngine: SiteSearchEngine?
    var paletteHintEngine: SiteSearchEngine?
    var paletteSuggestions: [String] = []
    let suggestionFetcher = SearchSuggestionFetcher()
    var newTabOnSubmit = false
    var privateMode: Bool
    /// A private window (File ▸ New Private Window): its own throwaway session and stores, no history,
    /// never saved or restored. `privateMode` is also true for it, and for the whole fresh preview.
    let isPrivateWindow: Bool
    var spaceManager: SpaceManagementController?
    var savedTabEditor: SavedTabEditorController?
    var arcImporter: ArcImportController?
    /// Icons carried over from Arc's cache for imported tabs, shown from memory.
    let importedTabIcons = ImportedTabIcons()
    /// Their bounded on-disk copy in Bam's support folder; nil for disposable
    /// (private/fresh preview) sessions, which keep imported icons in memory only.
    lazy var importedIconDisk: ImportedIconDiskCache? = privateMode ? nil
        : ImportedIconDiskCache(directory: sessionURL.deletingLastPathComponent().appendingPathComponent("ImportedIcons", isDirectory: true))
    let importedIconQueue = DispatchQueue(label: "com.ari.bam.imported-icons", qos: .utility)
    /// Icon batches from successive imports, decoded one at a time; cancelled at shutdown.
    let arcIconQueue = ArcIconImportQueue()
    /// Tabs created by an import, which must not reach the network for icons
    /// until the user opens them. Rebuilt when provenance changes.
    var importedTabIDsCache: (count: Int, ids: Set<UUID>)?
    var onSpacesChanged: (() -> Void)?
    var saveWork: DispatchWorkItem?
    var sessionWriter: SessionWriter?
    private var chromeRefreshWork: DispatchWorkItem?
    var tabErrors: [UUID: String] = [:]
    var pendingHome: Set<UUID> = []
    var pendingLoads: Set<UUID> = []
    /// Main tab views only: the visit each view's current document recorded, so its late title can correct that entry.
    var historyTitleFollowUps: [UUID: HistoryTitleFollowUp] = [:]
    var requestedAddresses: [UUID: String] = [:]
    let tabActivityProbe = TabActivityProbe()
    let tabResourcePolicy = TabResourcePolicy()
    var tabLastUsed: [UUID: TimeInterval] = [:]
    var sleepRestores: [UUID: TabSleepState] = [:]
    var nonGetDocuments: Set<UUID> = []
    var pendingNonGetDocuments: [UUID: Bool] = [:]
    var memoryPressure: TabResourcePolicy.Pressure = .normal
    var memoryPressureSource: DispatchSourceMemoryPressure?
    var sleepTask: Task<Void, Never>?
    var sleepPassID: UUID?
    var automaticTabSleeping = true
    var keepAwakeHosts: Set<String> = []
    /// The address field's site settings popover, and the page it describes.
    let siteSettings = SiteSettingsPopover()
    weak var siteSettingsWeb: WKWebView?
    /// The site the open popover describes; its actions are bound to it (see `siteSettingsOrigin(_:)`).
    var siteSettingsSite: String?

    /// `profileStores` is for disposable runs only (e.g. an isolated store from
    /// `WebsiteProfileStore(isolated:)`); nil keeps the standard store for `ephemeral`.
    init(sessionURL: URL, ephemeral: Bool = false, privateWindow: Bool = false, downloadCoordinator: DownloadCoordinator? = nil,
         profileStores: WebsiteProfileStore? = nil) {
        let ephemeral = ephemeral || privateWindow
        self.downloads = downloadCoordinator ?? DownloadCoordinator()
        self.sessionURL = sessionURL; self.privateMode = ephemeral; self.isPrivateWindow = privateWindow
        self.profileStores = profileStores ?? WebsiteProfileStore(ephemeral: ephemeral)
        self.favicons = WebsiteFaviconStore(directory: ephemeral ? nil : sessionURL.deletingLastPathComponent().appendingPathComponent("Favicons", isDirectory: true))
        session = privateWindow ? .privateWindow() : ephemeral ? .fresh() : SessionFile.load(sessionURL)
        if !ephemeral, UserDefaults.standard.object(forKey: "AutomaticallyShowPlayingVideo") != nil { automaticallyShowsVideo = UserDefaults.standard.bool(forKey: "AutomaticallyShowPlayingVideo") }
        displayedWidth = session.sidebarVisible ? CGFloat(session.sidebarWidth) : 0
        super.init(nibName: nil, bundle: nil)
        if !ephemeral {
            let writer = SessionWriter(url: sessionURL)
            writer.onError = { [weak self] error in
                NSLog("Session save: %@", error.localizedDescription)
                guard let self, self.isViewLoaded, !self.isShuttingDown, self.sessionWriter?.isLatestSnapshotSaved == false else { return }
                self.pageFeedback.show("Couldn’t save tabs", symbol: "exclamationmark.triangle", in: self.webHost)
            }
            sessionWriter = writer
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = root; root.wantsLayer = true; root.layer?.masksToBounds = true
        animator.animationView = root; pagingAnimator.animationView = root
        root.onLayout = { [weak self] in self?.layoutBrowser() }
        root.onTranslucencyChange = { [weak self] clear in self?.windowTranslucent = clear }
        root.onAppearanceChange = { [weak self] in self?.applyChromeColors() }
        [sidebar, card, handle, listScrollThumb].forEach(root.addSubview)
        sidebar.onTabListChange = { [weak self] in self?.refreshListScrollThumb() }
        listScrollThumb.onInteractionChange = { [weak self] active in self?.handle.isIndicatorSuppressed = active }
        card.wantsLayer = true
        card.layer?.cornerRadius = 10; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.addSubview(webHost)
        progress.wantsLayer = true
        card.addSubview(progress)
        applyChromeColors()
        configureFavicons()
        sidebar.onSelectTab = { [weak self] id in self?.select(id) }
        sidebar.onCloseTab = { [weak self] id in self?.close(id) }
        sidebar.onRemoveSavedTab = { [weak self] id in self?.removeSavedTab(id) }
        sidebar.onPinTab = { [weak self] id in self?.pinTab(id) }
        sidebar.onFavoriteTab = { [weak self] id in self?.favoriteTab(id) }
        sidebar.onEditSavedTab = { [weak self] id in self?.editSavedTab(id) }
        sidebar.onResetSavedTab = { [weak self] id in self?.resetSavedTab(id) }
        sidebar.onReorderSavedTab = { [weak self] id, direction in self?.reorderSavedTab(id, by: direction) }
        sidebar.onNewTab = { [weak self] in self?.newTab(nil) }
        sidebar.onSearch = { [weak self] in self?.focusAddress(nil) }
        sidebar.onBack = { [weak self] in self?.goBack(nil) }
        sidebar.onForward = { [weak self] in self?.goForward(nil) }
        sidebar.onReload = { [weak self] in self?.reload(nil) }
        sidebar.onToggleSidebar = { [weak self] in self?.toggleSidebar(nil) }
        sidebar.onSpaceChange = { [weak self] space in self?.changeSpace(space) }
        sidebar.onManageSpaces = { [weak self] in self?.manageSpaces(nil) }
        sidebar.spaceContextMenu = { [weak self] in self?.spaceContextMenu(for: $0) }
        sidebar.canDropOnFavorites = { [weak self] in self?.canMakeFavorite(byDropping: $0) ?? false }
        sidebar.onDropOnFavorites = { [weak self] id, anchor in self?.makeFavorite(byDropping: id, before: anchor) ?? false }
        sidebar.onMoveTab = { [weak self] id, space in self?.moveTab(id, toSpace: space) }
        // Footer Downloads button and its menu: the existing windows (View > Downloads ⌘J, History ⌘Y, Recently Closed).
        // Picture in Picture left the footer; it stays in View > Picture in Picture (⌥⌘P) and the command palette.
        sidebar.onShowDownloads = { [weak self] in self?.showDownloads(nil) }
        sidebar.onShowHistory = { [weak self] in self?.showHistory(nil) }
        sidebar.onShowRecentlyClosed = { [weak self] in self?.showArchive(nil) }
        sidebar.onExtensionAction = { [weak self] id, anchor in self?.invokeSidebarExtension(id, anchor: anchor) }
        sidebar.onExtensionsMenu = { [weak self] anchor in self?.showSidebarExtensions(anchor: anchor) }
        sidebar.onExtensionLibrary = { [weak self] in self?.showExtensionLibrary(nil) }
        sidebar.onSiteSettings = { [weak self] in self?.showSiteSettings(from: $0) }
        connectFolderCommands()
        sidebar.onSpaceScroll = { [weak self] event, source in
            guard let self else { return false }
            return self.handleSpaceScroll(event, source: source) == nil
        }
        pictureInPicture.onChange = { [weak self] in self?.showActive() }
        pictureInPicture.onReturnToTab = { [weak self] id in self?.returnToVideoTab(id) }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }; return self.handleSpaceScroll(event)
        }
        handle.onResize = { [weak self] width, ended in
            guard let self else { return }; self.cancelPaging(); self.animator.stop(); self.displayedWidth = width
            if width >= RecoveredMetrics.minWidth { self.session.sidebarWidth = Double(width) }
            self.layoutBrowser()
            if ended { self.save() }
        }
        handle.onCollapse = { [weak self] in self?.setSidebar(false) }
        handle.onReset = { [weak self] in self?.resetSidebar(nil) }
        startTabResourceMonitoring(); showActive(); refresh()
        restoreImportedIcons()
    }

    /// A Clear Space needs the window itself non-opaque so the desktop shows
    /// through; every other appearance restores the solid window.
    var windowTranslucent = false { didSet { applyWindowTranslucency() } }
    func applyWindowTranslucency() {
        guard let window = view.window else { return }
        window.isOpaque = !windowTranslucent
        window.backgroundColor = windowTranslucent ? .clear : BrowserChrome.windowBackground
        window.invalidateShadow()
    }
    override func viewDidAppear() { super.viewDidAppear(); applyWindowTranslucency(); layoutBrowser(); installTabNavigation() }

    /// Arc hides the traffic lights together with the sidebar: once the page
    /// owns the whole window the close/minimize/zoom buttons fade out with the
    /// card's margin, and they return as the sidebar slides back in.
    var windowButtonsHidden: Bool {
        guard let window = view.window else { return false }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .allSatisfy { window.standardWindowButton($0)?.isHidden ?? true }
    }
    func applyWindowButtons(collapse: CGFloat) {
        guard let window = view.window else { return }
        placeWindowButtons()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.alphaValue = 1 - collapse
            button.isHidden = collapse >= 1
        }
    }
    /// The traffic lights share one row with the sidebar's toggle and navigation buttons, as in Yab and Arc:
    /// centered `ArkMetrics.toolbarCenterY` from the top, the first light centered `trafficLightLeading` in.
    /// AppKit re-tiles the titlebar (resize, full screen, key changes), so the lights are put back whenever
    /// their frame changes. Full screen keeps the system's own placement in the revealed menu bar.
    func placeWindowButtons() {
        guard let window = view.window, let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        if windowButtonObservers.isEmpty {
            for observed in [close, container] {
                observed.postsFrameChangedNotifications = true
                windowButtonObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                                    object: observed, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeWindowButtons() }
                })
            }
        }
        guard !placingWindowButtons, !window.styleMask.contains(.fullScreen) else { return }
        placingWindowButtons = true; defer { placingWindowButtons = false }
        let height = ArkMetrics.toolbarCenterY * 2
        let frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        if container.frame != frame { container.frame = frame }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = kinds.compactMap { window.standardWindowButton($0) }
        // Keep the system's own spacing between the lights; only the group moves.
        let spacing = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.minX : 23
        for (index, button) in buttons.enumerated() {
            guard let parent = button.superview else { continue }
            let size = button.frame.size
            let center = NSPoint(x: ArkMetrics.trafficLightLeading + CGFloat(index) * spacing,
                                 y: parent.isFlipped ? ArkMetrics.toolbarCenterY : parent.bounds.height - ArkMetrics.toolbarCenterY)
            let origin = NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    var focusedTabID: UUID {
        guard let group = session.split(for: session.activeID), splitCoordinators[group.primaryID]?.focusedSide == .right else { return session.activeID }
        return group.secondaryID
    }
    var visibleMemberIDs: [UUID] {
        guard let group = session.split(for: session.activeID) else { return [session.activeID] }
        return [group.primaryID, group.secondaryID]
    }
    var activeWebView: WKWebView? { browsers[focusedTabID] }
    var commandWebView: WKWebView? {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { return little.webView }
        return peeks[session.activeID]?.webView ?? activeWebView
    }
    /// Points the thumb at the visible tab list; hidden while the sidebar is away, collapsing or paging Spaces.
    func refreshListScrollThumb() {
        listScrollThumb.isSuppressed = handle.isHidden || sidebar.isHidden || sidebar.isPagingSpaces || listScrollThumb.frame.width < 8
        listScrollThumb.scrollView = sidebar.tabListScrollView
        listScrollThumb.refresh()
    }
    func layoutBrowser() {
        let w = root.bounds.width, h = root.bounds.height
        guard w > 0 && h > 0 else { return }
        let targetWidth = CGFloat(session.sidebarWidth)
        let width = min(max(0, displayedWidth), max(164, w - 360))
        sidebar.frame = NSRect(x: width - targetWidth, y: 0, width: targetWidth, height: h)
        sidebar.layer?.transform = CATransform3DIdentity
        sidebar.alphaValue = 1
        sidebar.isHidden = width < 0.5 || spaceCreationPanel != nil
        // With the sidebar away the page owns the whole window, like Arc: the
        // card's margin, corner and border fade out continuously over the last
        // 80 points so nothing jumps, and no toolbar strip appears.
        let collapse = 1 - min(1, max(0, width / 80))
        let inset = 8 * (1 - collapse)
        card.frame = NSRect(x: width + inset, y: inset, width: max(100, w - width - 2 * inset), height: h - 2 * inset)
        // Arc/Yab frame the page with a soft corner and a barely-there edge.
        card.layer?.cornerRadius = 10 * (1 - collapse)
        card.layer?.borderColor = resolvedCGColor(BrowserChrome.cardEdge, for: card).copy(alpha: (root.isDark ? 0.09 : 0.10) * (1 - collapse))
        applyWindowButtons(collapse: collapse)
        webHost.frame = card.bounds
        if let web = activeWebView, web.superview === webHost { web.frame = webHost.bounds }
        for child in webHost.subviews where !(child is WKWebView) { child.frame = webHost.bounds }
        progress.isHidden = !(activeWebView?.isLoading ?? false)
        progress.frame = NSRect(x: 0, y: 0, width: card.bounds.width * CGFloat(activeWebView?.estimatedProgress ?? 0), height: 2)
        // The resize handle lives in the gap between the sidebar and the card, so it never covers the sidebar's
        // content edge (Favorites, rows, the list's overlay scroller) or the page.
        handle.frame = NSRect(x: max(0, width - ArkMetrics.sidebarTrailing), y: 44, width: max(6, inset + ArkMetrics.sidebarTrailing), height: max(0, h - 60))
        handle.currentWidth = targetWidth; handle.isHidden = !session.sidebarVisible || width < 100
        // The thumb's column: from the rows' trailing edge across the gap to the card.
        listScrollThumb.frame = NSRect(x: width - ArkMetrics.sidebarTrailing, y: listScrollThumb.frame.minY,
                                       width: inset + ArkMetrics.sidebarTrailing, height: listScrollThumb.frame.height)
        refreshListScrollThumb()
        if addressOverlay != nil { layoutPalette(width: w, height: h) }
        layoutSpaceCreation()
    }

    func webView(for tab: BrowserTab) -> WKWebView {
        if let cached = browsers[tab.id] { return cached }
        let configuration = WKWebViewConfiguration()
        configuration.adoptSafariUserAgent()
        configuration.websiteDataStore = profileStores.store(for: session.profileID(for: tab))
        configureExtensions(configuration, profileID: session.profileID(for: tab))
        let browser = WKWebView(frame: .zero, configuration: configuration)
        register(browser, id: tab.id)
        load(tab.address, in: browser, id: tab.id)
        if let state = tab.sleepState, state.address == tab.address {
            sleepRestores[tab.id] = state
            if let index = session.tabs.firstIndex(where: { $0.id == tab.id }) { session.tabs[index].sleepState = nil }
        }
        return browsers[tab.id] ?? browser
    }
    func register(_ browser: WKWebView, id: UUID) {
        browser.navigationDelegate = self; browser.uiDelegate = self
        ContentBlocking.shared.track(browser)
        browser.allowsBackForwardNavigationGestures = true
        BrowserPageGestures.configure(browser)
        WebsitePreferences.apply(to: browser) // Settings › Websites: default zoom, minimum font size.
        preparePageTools(browser)
        tabNavigation.linkStatus.install(in: browser, owner: self); reapplyMute(browser, id: id)
        browser.autoresizingMask = [.width, .height]
        browser.setAccessibilityLabel("Web content")
        browsers[id] = browser
        tabLastUsed[id] = ProcessInfo.processInfo.systemUptime
        observations[id] = [
            browser.observe(\.title, options: [.new]) { [weak self] web, _ in DispatchQueue.main.async { self?.updateMetadata(web) } },
            browser.observe(\.url, options: [.new]) { [weak self] web, _ in DispatchQueue.main.async { self?.updateMetadata(web) } },
            browser.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async {
                guard let self, self.visibleMemberIDs.contains(id) else { return }; self.layoutBrowser()
            } },
            browser.observe(\.isLoading, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async {
                guard let self else { return }
                // Every loading transition (start, finish, failure, stop) reaches extensions from here.
                self.noteExtensionLoadingChange(id)
                guard self.visibleMemberIDs.contains(id) else { return }; self.scheduleChromeRefresh()
            } }
        ]
    }
    func load(_ address: String, in browser: WKWebView, id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }), browsers[id] === browser else { return }
        invalidateFaviconDocument(id); historyTitleFollowUps.removeValue(forKey: id)
        let profile = session.profileID(for: tab), token = UUID()
        navigationTokens[id] = token
        tabActivityProbe.invalidate(browser); sleepRestores.removeValue(forKey: id)
        tabErrors.removeValue(forKey: id)
        requestedAddresses[id] = address; pendingLoads.insert(id)
        whenExtensionsReady(profileID: profile) { [weak self, weak browser] in
            guard let self, let browser, !self.isShuttingDown, self.navigationTokens[id] == token,
                  self.browsers[id] === browser,
                  let current = self.session.tabs.first(where: { $0.id == id }), self.session.profileID(for: current) == profile else { return }
            self.loadPrepared(address, in: browser, id: id, profileID: profile)
        }
    }
    private func loadPrepared(_ address: String, in browser: WKWebView, id: UUID, profileID: UUID) {
        let extensionURL = URLInput.extensionURL(address)
        if let extensionURL, !allowsExtensionPage(extensionURL, profileID: profileID) {
            pendingLoads.remove(id); pendingHome.remove(id)
            tabErrors[id] = extensionPageUnavailableMessage(extensionURL, profileID: profileID)
            refresh(); return
        }
        let origin = extensionURL?.host?.lowercased()
        var destination = browser
        if browserExtensionOrigins[id] != origin {
            // Extension pages require their context's configuration, which cannot
            // navigate outside its origin. Replace the renderer at that boundary.
            let configuration: WKWebViewConfiguration
            if let extensionURL, let configured = extensionPageConfiguration(extensionURL, profileID: profileID) { configuration = configured }
            else {
                configuration = WKWebViewConfiguration()
                configuration.adoptSafariUserAgent()
                configuration.websiteDataStore = profileStores.store(for: profileID)
                configureExtensions(configuration, profileID: profileID)
            }
            let wasVisible = visibleMemberIDs.contains(id)
            isApplyingProfileChange = true; retireProfilePage(id); isApplyingProfileChange = false
            destination = WKWebView(frame: browser.frame, configuration: configuration)
            register(destination, id: id); browserExtensionOrigins[id] = origin
            requestedAddresses[id] = address; pendingLoads.insert(id)
            if wasVisible { showActive() }
        }
        if ArcEaselReference.isReference(address) {
            // Never requested: an Easel reference has no page and no URL to load.
            pendingLoads.remove(id); pendingHome.remove(id)
        } else if address == "orbit://newtab" || address == "orbit://video" {
            pendingHome.insert(id)
            if let file = Bundle.main.url(forResource: address == "orbit://video" ? "PiPDemo" : "Home", withExtension: "html") { destination.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()) }
            else { destination.loadHTMLString("<h1>Bam</h1><p>Press Command-L to explore.</p>", baseURL: nil) }
        } else if let url = extensionURL ?? URLInput.directURL(address) {
            if extensionURL == nil { TabActivityProbe.install(in: destination.configuration) }
            pendingHome.remove(id); destination.load(URLRequest(url: url))
        } else {
            pendingLoads.remove(id); tabErrors[id] = "This address cannot be opened"; refresh()
        }
        scheduleExtensionRefresh()
    }
    func showActive() {
        guard let tab = session.active, !isShuttingDown, !isApplyingProfileChange else { return }
        noteTabShown(tab.id, leaving: displayedTabID)
        let arriving = visibleMemberIDs
        for id in arriving { tabLastUsed[id] = ProcessInfo.processInfo.systemUptime }
        let outgoing = displayedMemberIDs.filter { !arriving.contains($0) }
        for id in outgoing { tabLastUsed[id] = ProcessInfo.processInfo.systemUptime }
        stampViewed(arriving + outgoing) // Auto-archive counts from the last time a tab was on screen.
        let switched = displayedTabID != nil && displayedTabID != tab.id
        if switched { pageFeedback.hide() }
        // Capture actual hosts before restore callbacks or model changes can re-enter.
        let departingHosts = outgoing.compactMap { id in browsers[id].flatMap { hostedAncestor($0) } }
        let previousFocus = focusedView(in: view.window)
        let focusHosts = departingHosts + Array(retiringViews.values)
        let focusWasDeparting = previousFocus.map { focused in
            focusHosts.contains { focused === $0 || focused.isDescendant(of: $0) }
        } ?? false
        let focusWasWindow = view.window?.firstResponder === view.window
        displayedTabID = tab.id; displayedMemberIDs = arriving
        if switched, let source = pictureInPicture.referencedTabID, arriving.contains(source) { pictureInPicture.restore() }
        // Every queued page keeps its original window attachment until discovery
        // completes, including single tabs queued behind another pending probe.
        if automaticallyShowsVideo {
            for host in departingHosts where host.superview === webHost { retiringViews[ObjectIdentifier(host)] = host }
            if !outgoing.isEmpty { automaticallyFloatDeparture(outgoing) }
        }
        for (id, peek) in peeks { peek.setVisible(id == tab.id) }
        if let group = session.split(for: tab.id) { showSplit(group) }
        else if tab.isArcEasel {
            // An Arc Easel reference has no web page: a native explanation, no
            // renderer, no network. A page left from navigating away (then
            // resetting back to the reference) is retired, never shown.
            if browsers[tab.id] != nil { teardownPage(tab.id) }
            installActiveHost(EaselReferenceView(title: tab.displayTitle))
        } else {
            let browser = webView(for: tab)
            if pictureInPicture.owns(browser) {
                let placeholder = PiPPlaceholder(frame: webHost.bounds)
                placeholder.returnVideo = { [weak self] in self?.pictureInPicture.restore() }
                installActiveHost(placeholder)
            } else { installActiveHost(browser) }
        }
        refresh()
        // A covered retiring view is still a valid AppKit responder. Move only
        // departing page focus; preserve Find, the palette, and other windows.
        if (focusWasDeparting || (switched && focusWasWindow)), addressOverlay == nil, !findBar.isVisible,
           let window = view.window, window.isKeyWindow, NSApp.keyWindow === window,
           let destination = commandWebView, destination.window === window {
            window.makeFirstResponder(destination)
        }
    }
    /// Refreshing the selected page must not detach its live WebKit surface.
    /// Resolve the actual host first: the same tab ID can acquire a different
    /// renderer, a Split, or a PiP placeholder during synchronous callbacks.
    func installActiveHost(_ host: NSView) {
        for child in webHost.subviews where child !== host && retiringViews[ObjectIdentifier(child)] == nil {
            child.removeFromSuperview()
        }
        if host.superview !== webHost || webHost.subviews.last !== host {
            webHost.addSubview(host, positioned: .above, relativeTo: nil)
        }
        if host.frame != webHost.bounds { host.frame = webHost.bounds }
    }
    private func hostedAncestor(_ view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if candidate.superview === webHost { return candidate }
            current = candidate.superview
        }
        return nil
    }
    func focusedView(in window: NSWindow?) -> NSView? {
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSView { return owner }
        return window?.firstResponder as? NSView
    }
    private var activeRenderedHost: NSView? {
        if let group = session.split(for: session.activeID), let split = splitCoordinators[group.primaryID],
           split.view.superview === webHost { return split.view }
        if session.split(for: session.activeID) == nil, let web = browsers[session.activeID], web.superview === webHost { return web }
        return nil
    }
    func automaticallyFloatDeparture(_ candidates: [UUID]) {
        for id in candidates where !automaticDepartureQueue.contains(id) { automaticDepartureQueue.append(id) }
        drainAutomaticDepartures()
    }
    func drainAutomaticDepartures() {
        guard !automaticProbeInFlight else { return }
        guard automaticallyShowsVideo, !isShuttingDown, pictureInPicture.referencedTabID == nil else {
            automaticDepartureQueue.removeAll(); releaseRetiringViews(); return
        }
        while let first = automaticDepartureQueue.first,
              visibleMemberIDs.contains(first) || browsers[first] == nil || !session.tabs.contains(where: { $0.id == first }) {
            automaticDepartureQueue.removeFirst()
        }
        guard !automaticDepartureQueue.isEmpty else { releaseRetiringViews(); return }
        let id = automaticDepartureQueue.removeFirst()
        guard let outgoing = browsers[id] else { drainAutomaticDepartures(); return }
        let token = UUID()
        automaticProbeInFlight = true; automaticProbeToken = token; automaticProbeTabID = id
        pictureInPicture.automaticallyPresentIfPlaying(web: outgoing, tabID: id, shouldPresent: { [weak self, weak outgoing] in
            guard let self, let outgoing else { return false }
            return self.automaticProbeToken == token && !self.isShuttingDown && self.automaticallyShowsVideo
                && !self.visibleMemberIDs.contains(id) && self.session.tabs.contains(where: { $0.id == id })
                && self.browsers[id] === outgoing
        }, restore: { [weak self] _ in self?.showActive() }, completion: { [weak self] presented in
            guard let self, self.automaticProbeToken == token else { return }
            self.automaticProbeInFlight = false; self.automaticProbeToken = nil; self.automaticProbeTabID = nil
            if presented && self.pictureInPicture.activeTabID == id {
                self.automaticDepartureQueue.removeAll(); self.releaseRetiringViews()
            } else { self.drainAutomaticDepartures() }
        })
    }
    func cancelAutomaticDepartures() {
        let pendingID = automaticProbeTabID
        automaticProbeToken = nil; automaticProbeTabID = nil; automaticProbeInFlight = false
        automaticDepartureQueue.removeAll()
        if let pendingID, pictureInPicture.activeTabID == nil, pictureInPicture.referencedTabID == pendingID {
            pictureInPicture.restore()
        }
        releaseRetiringViews()
    }
    func releaseRetiringViews() {
        let activeHost = activeRenderedHost
        for retiringView in retiringViews.values {
            // A single page may already have moved into PiP. Never pull it out.
            if retiringView.superview === webHost, retiringView !== activeHost { retiringView.removeFromSuperview() }
        }
        retiringViews.removeAll()
    }
    func prepareToClose(persistSession: Bool = true) {
        guard !isShuttingDown else { return }
        saveWork?.cancel(); saveWork = nil
        chromeRefreshWork?.cancel(); chromeRefreshWork = nil
        faviconRefreshWork?.cancel(); faviconRefreshWork = nil
        faviconDiscoveryWork.values.forEach { $0.cancel() }; faviconDiscoveryWork.removeAll()
        faviconDocumentGenerations.removeAll(); favicons.shutdown()
        stopTabResourceMonitoring()
        stopExtensions()
        spaceManager?.cancel(nil)
        savedTabEditor?.cancel(nil)
        isShuttingDown = true; cancelAutomaticDepartures(); findBar.hide(); pageFeedback.hide(); downloads.cancelAll(); pictureInPicture.restore()
        arcIconQueue.cancelAll()
        for peek in Array(peeks.values) { peek.dismiss() }
        for little in Array(littleWindows.values) { little.close() }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor); scrollMonitor = nil }
        cancelPaging(); animator.stop()
        if persistSession {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            save(); _ = sessionWriter?.flush(timeout: 2)
            for library in profileLibraries.values {
                _ = library.flush(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            }
        }
    }
    func updateMetadata(_ web: WKWebView) {
        guard let pair = browsers.first(where: { $0.value === web }), let i = session.tabs.firstIndex(where: { $0.id == pair.key }) else { return }
        guard !pendingLoads.contains(pair.key), tabErrors[pair.key] == nil else { return }
        applyHistoryTitle(web, id: pair.key)
        let previous = session.tabs[i]
        if let url = web.url, ["https", "http"].contains(url.scheme ?? "") || allowsExtensionPage(url, profileID: session.profileID(for: session.tabs[i])) {
            session.tabs[i].address = url.absoluteString
            session.tabs[i].title = web.title?.isEmpty == false ? web.title! : url.host ?? "New tab"
        } else if web.url?.standardizedFileURL == Bundle.main.url(forResource: "PiPDemo", withExtension: "html")?.standardizedFileURL {
            session.tabs[i].address = "orbit://video"; session.tabs[i].title = "Picture in Picture demo"
        } else if web.url?.standardizedFileURL == Bundle.main.url(forResource: "Home", withExtension: "html")?.standardizedFileURL || (web.url == nil && pendingHome.contains(pair.key)) {
            session.tabs[i].address = "orbit://newtab"; session.tabs[i].title = "New tab"
        }
        guard session.tabs[i] != previous else { return }
        // Extensions hear every tab's URL and title changes (tabs.onUpdated), including same-document navigations and
        // tabs outside the shown Space, which reach here only through KVO and get no chrome refresh below. Coalesced;
        // reconcile publishes only real differences.
        scheduleExtensionRefresh()
        scheduleFaviconDiscovery(in: web)
        let tab = session.tabs[i]
        if tab.isFavorite || tab.space == session.space || tab.space == pagingTarget { scheduleChromeRefresh() }
        scheduleSave()
    }
    /// The current document's title, which WebKit often reports after didFinish, corrects the visit that
    /// document recorded. Memory only: the profile's library is already loaded (it recorded the visit) and
    /// is never created here. No new visit, event, time or order; bounded by HistoryTitleFollowUp.
    private func applyHistoryTitle(_ web: WKWebView, id: UUID) {
        guard !isShuttingDown, var followUp = historyTitleFollowUps[id] else { return }
        if followUp.apply(url: web.url, title: web.title, profileID: profileID(of: web), library: profileLibraries[followUp.profileID]) {
            historyTitleFollowUps[id] = followUp.isSpent ? nil : followUp
        }
    }
    func scheduleChromeRefresh() {
        guard chromeRefreshWork == nil, !isShuttingDown else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.chromeRefreshWork = nil; self?.refresh()
        }
        chromeRefreshWork = work
        DispatchQueue.main.async(execute: work)
    }
    func refresh() {
        guard isViewLoaded else { return }
        scheduleExtensionRefresh()
        refreshExtensionActions()
        root.theme = session.spaceDefinition(session.space)?.theme
        root.space = session.spaceDefinition(session.space)?.colorIndex ?? 0
        littleWindows.values.forEach { $0.refreshSpaces() }
        sidebar.configureSpaces(session.spaces)
        let tabs = sidebarItems(in: session)
        sidebar.update(tabs: tabs, space: session.space, canGoBack: activeWebView?.canGoBack ?? false, canGoForward: activeWebView?.canGoForward ?? false, isLoading: activeWebView?.isLoading ?? false)
        if let target = pagingTarget, target != session.space {
            sidebar.beginPaging(tabs: sidebarItems(for: target), space: target, direction: spaceDirection(to: target))
        }
        if let tab = session.active {
            let host = tab.addressLabel
            // While a Peek is up, the address field shows the Peek's page (as the reference does).
            if let peek = peeks[tab.id], peek.isShowing, let url = peek.pageURL {
                sidebar.setAddress(url.absoluteString, title: url.host?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? url.absoluteString)
            } else {
                sidebar.setAddress(tab.address, title: tabErrors[tab.id] ?? (tab.isHome ? "Search or enter URL" : host))
            }
            view.window?.title = "\(tab.displayTitle) — Bam"
        }
        refreshSplitMetadata()
        refreshFindTarget()
        refreshSiteSettings()
        layoutBrowser()
    }
    func select(_ id: UUID) {
        if let tab = session.tabs.first(where: { $0.id == id }), tab.isFavorite,
           !selectSpace(forProfile: session.profileID(for: tab)) { return }
        cancelPaging(); session.select(id); dismissAddress(); showActive(); save()
    }
    /// `archived`: auto-archive closed it, so the archive says so.
    func close(_ id: UUID, archived: Bool = false) {
        cancelPaging(); cancelAutomaticDepartures()
        let group = session.split(for: id)
        let closingIDs = group?.primaryID == id ? [id, group!.secondaryID] : [id]
        let closed = closingIDs.compactMap { closingID in session.tabs.first { $0.id == closingID } }
        let removed = closed.filter { !$0.isSaved }
        // An auto-archived blank tab just goes; there is nothing in it to restore.
        if let source = closed.first, !(archived && removed.allSatisfy(\.isHome)) {
            library(for: session.profileID(for: source)).recordClosed(tabs: removed, split: removed.count == 2, reason: archived ? .archived : nil)
        }
        _ = session.close(id)
        if let group, let split = splitCoordinators.removeValue(forKey: group.primaryID) {
            split.detach(); split.view.removeFromSuperview()
            retiringViews.removeValue(forKey: ObjectIdentifier(split.view))
        }
        for closingID in closingIDs { teardownPage(closingID) }
        showActive(); save()
    }
    /// Retires a tab's page completely: its web view, callbacks, load state,
    /// Peek and floating video. Used when a tab closes, and when a tab that had
    /// a page becomes an Arc Easel reference again (which has no page).
    func teardownPage(_ id: UUID) {
        invalidateFaviconDocument(id); historyTitleFollowUps.removeValue(forKey: id)
        peeks[id]?.dismiss()
        observations.removeValue(forKey: id)
        let web = browsers.removeValue(forKey: id)
        if let web { tabActivityProbe.invalidate(web) }
        tabLastUsed.removeValue(forKey: id); sleepRestores.removeValue(forKey: id); nonGetDocuments.remove(id); pendingNonGetDocuments.removeValue(forKey: id)
        web?.navigationDelegate = nil; web?.uiDelegate = nil; web?.stopLoading()
        // PiP restoration can synchronously re-enter showActive. The retired
        // view must no longer be discoverable by metadata or return callbacks.
        if let web, pictureInPicture.references(web) { pictureInPicture.restore() }
        if let web {
            web.pauseAllMediaPlayback(completionHandler: nil)
            retiringViews.removeValue(forKey: ObjectIdentifier(web)); web.removeFromSuperview()
        }
        navigationTokens.removeValue(forKey: id); browserExtensionOrigins.removeValue(forKey: id)
        pendingHome.remove(id); tabErrors.removeValue(forKey: id); pendingLoads.remove(id); requestedAddresses.removeValue(forKey: id)
    }
    /// The cross on an unloaded kept tab removes it, as in Arc and Yab. It leaves as an ordinary closed tab, so
    /// Reopen Closed Tab (⇧⌘T) and Recently Closed can bring the page back.
    func removeSavedTab(_ id: UUID) {
        cancelPaging()
        guard let tab = session.tabs.first(where: { $0.id == id }), tab.saved?.kind == .kept, session.split(for: id) == nil,
              session.setRetention(id: id, kind: nil) else { return }
        close(id)
    }
    func pinTab(_ id: UUID) {
        cancelPaging()
        guard let tab = session.tabs.first(where: { $0.id == id }),
              session.setRetention(id: id, kind: tab.saved?.kind == .kept ? nil : .kept) else { return }
        refresh(); refreshPaletteResults(); save()
    }
    /// A better title for a row whose own title is only its address: the latest history visit to that address with
    /// a real title. Reads only a profile library that is already loaded; nil otherwise (the row shows the host).
    func knownTitle(for tab: BrowserTab, in snapshot: BrowserSession) -> String? {
        let address = tab.isUnloaded ? (tab.saved?.address ?? tab.address) : tab.address
        guard tab.displayTitle.isEmpty || SidebarDisplayPolicy.looksLikeAddress(tab.displayTitle, address: address),
              let library = profileLibraries[snapshot.profileID(for: tab)] else { return nil }
        return library.history.first {
            $0.address == address && !$0.title.isEmpty && !SidebarDisplayPolicy.looksLikeAddress($0.title, address: address)
        }?.title
    }
    func sidebarItems(for space: Int) -> [SidebarTabItem] {
        var preview = session; preview.changeSpace(space)
        return sidebarItems(in: preview)
    }
    func cancelPaging() {
        SpaceSwipeDiagnostics.shared.record(["kind": "cancel", "space": session.space,
            "offset": pagingOffset, "tracking": trackingSwipe])
        unphasedScrollEnd?.cancel(); unphasedScrollEnd = nil
        quarantineActiveSpaceGesture()
        pagingAnimator.stop(); swipe.reset(); trackingSwipe = false
        capturedSpaceMomentum = false; pagingCommit = nil
        pagingOffset = 0; pagingTarget = nil; sidebar.endPaging()
        updateSpaceCreateIndicator(progress: nil)
        if spaceCreationPanel == nil { root.previewSpace = nil; root.previewProgress = 0 }
    }
    func changeSpace(_ space: Int) {
        guard session.spaceDefinition(space) != nil else { return }
        dismissAddress()
        dismissSpaceCreation()
        quarantineActiveSpaceGesture()
        swipe.reset(); trackingSwipe = false
        unphasedScrollEnd?.cancel(); unphasedScrollEnd = nil
        var velocity = pagingAnimator.isRunning ? pagingAnimator.velocity : 0
        if pagingAnimator.isRunning, pagingCommit != nil {
            if space == session.space { return }
            // Reverse the existing pair continuously. A third Space has no
            // displayed page in this pair, so finish its visuals before retargeting.
            if !sidebar.canReversePaging(to: space) {
                sidebar.endPaging(); pagingOffset = 0; velocity = 0
            }
        } else if let target = pagingTarget, target != space, space != session.space {
            // Replacing an undecided preview must not remove the only page
            // filling the exposed edge while its source is still displaced.
            sidebar.endPaging(); pagingOffset = 0; velocity = 0
        }
        pagingAnimator.stop(); pagingCommit = nil
        if space == session.space {
            if pagingOffset != 0 || sidebar.isPaging { finishPaging(commit: nil, initialVelocity: velocity) }
            return
        }
        swipe.reset(); trackingSwipe = false
        unphasedScrollEnd?.cancel(); unphasedScrollEnd = nil
        let direction = spaceDirection(to: space)
        sidebar.beginPaging(tabs: sidebarItems(for: space), space: space, direction: direction)
        pagingTarget = space
        finishPaging(commit: space, initialVelocity: velocity)
    }
    func handleSpaceScroll(_ event: NSEvent, source: SpaceScrollSource = .monitor) -> NSEvent? {
        guard !suspendsChromeInteraction else { return event }
        if let previous = recentSpaceScrollEvents.last(where: { $0.event === event }) {
            SpaceSwipeDiagnostics.shared.record(["kind": "duplicate", "source": source.rawValue,
                                                 "consumed": previous.consumed])
            return previous.consumed ? nil : event
        }
        let phase: SpaceSwipeStateMachine.Phase
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.contains(.changed) { phase = .changed }
        else if event.phase.contains(.stationary) { phase = .stationary }
        else { phase = .none }
        let point = sidebar.convert(event.locationInWindow, from: nil)
        let insideSidebar = sidebar.bounds.contains(point)
        let beforeSpace = session.space, beforeOffset = pagingOffset, beforeTracking = trackingSwipe
        let consumed = routeSpaceScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            phase: phase, isMomentum: !event.momentumPhase.isEmpty, timestamp: event.timestamp,
            isPrecise: event.hasPreciseScrollingDeltas,
            isInsideSidebar: insideSidebar,
            isFromBrowserWindow: event.window === view.window)
        recentSpaceScrollEvents.append((event, consumed))
        if recentSpaceScrollEvents.count > 32 { recentSpaceScrollEvents.removeFirst() }
        SpaceSwipeDiagnostics.shared.record(["kind": "event", "source": source.rawValue, "phase": String(describing: phase),
            "rawPhase": event.phase.rawValue, "rawMomentumPhase": event.momentumPhase.rawValue,
            "precise": event.hasPreciseScrollingDeltas, "insideSidebar": insideSidebar,
            "browserWindow": event.window === view.window, "eventWindowPresent": event.window != nil,
            "deltaX": event.scrollingDeltaX, "deltaY": event.scrollingDeltaY,
            "pointX": point.x, "pointY": point.y, "sidebarWidth": sidebar.bounds.width,
            "sidebarVisible": session.sidebarVisible, "overlay": addressOverlay != nil,
            "beforeSpace": beforeSpace, "space": session.space, "beforeOffset": beforeOffset,
            "offset": pagingOffset, "beforeTracking": beforeTracking, "tracking": trackingSwipe,
            "ignored": ignoreSpaceGestureUntilEnd, "rejected": rejectedSpaceGesture,
            "consumed": consumed, "route": spaceScrollRoute, "animationRunning": pagingAnimator.isRunning])
        return consumed ? nil : event
    }
    /// The event adapter and native regression fixture use the same routing path.
    /// Capture starts over the visible sidebar and survives pointer exit; ordinary
    /// webpage scrolling and nonprecise mouse wheels retain their own behavior.
    @discardableResult func routeSpaceScroll(deltaX: CGFloat, deltaY: CGFloat,
        phase: SpaceSwipeStateMachine.Phase, isMomentum: Bool, timestamp: TimeInterval,
        isPrecise: Bool, isInsideSidebar: Bool, isFromBrowserWindow: Bool) -> Bool {
        spaceScrollRoute = "window"
        guard isFromBrowserWindow else { return false }
        spaceScrollRoute = "hidden"
        guard session.sidebarVisible else { return false }
        spaceScrollRoute = "overlay"
        guard addressOverlay == nil, spaceManager == nil, savedTabEditor == nil else { return false }
        spaceScrollRoute = "wheel"
        guard isPrecise || phase != .none else { return false }
        if phase == .began || phase == .mayBegin {
            ignoreSpaceGestureUntilEnd = false
            ignoredSpaceGestureEnd?.cancel(); ignoredSpaceGestureEnd = nil
            rejectedSpaceGesture = !isInsideSidebar
        }
        if rejectedSpaceGesture {
            spaceScrollRoute = "outsideStart"
            if phase == .began || phase == .mayBegin {
                swipe.reset(); trackingSwipe = false; capturedSpaceMomentum = false
                unphasedScrollEnd?.cancel(); unphasedScrollEnd = nil
            }
            if phase == .ended || phase == .cancelled { rejectedSpaceGesture = false }
            return false
        }
        if ignoreSpaceGestureUntilEnd {
            spaceScrollRoute = "quarantine"
            if phase == .ended || phase == .cancelled {
                ignoreSpaceGestureUntilEnd = false; capturedSpaceMomentum = true
                ignoredSpaceGestureEnd?.cancel(); ignoredSpaceGestureEnd = nil
            } else { scheduleIgnoredGestureEnd() }
            return true
        }
        if phase == .began || phase == .mayBegin {
            unphasedScrollEnd?.cancel(); unphasedScrollEnd = nil
            trackingSwipe = isInsideSidebar; capturedSpaceMomentum = false
            if !trackingSwipe { spaceScrollRoute = "outside"; swipe.reset(); return false }
        } else if !trackingSwipe && !isMomentum && isInsideSidebar && (phase == .changed || phase == .none) {
            trackingSwipe = true
        }
        if isMomentum && capturedSpaceMomentum && !trackingSwipe { spaceScrollRoute = "momentum"; return true }
        spaceScrollRoute = "notTracking"
        guard trackingSwipe else { return false }
        spaceScrollRoute = "recognizer"
        // Some trackpad drivers provide precise deltas without physical phases.
        // Give those streams a quiet-period end, rather than ignoring them all.
        let unphased = phase == .none && !isMomentum
        let deliveredPhase: SpaceSwipeStateMachine.Phase = unphased ? .changed : phase
        if isMomentum && trackingSwipe && phase == .none {
            _ = applySpaceScroll(deltaX: 0, deltaY: 0, phase: .ended, isMomentum: false, timestamp: timestamp)
        }
        let consumed = applySpaceScroll(deltaX: deltaX, deltaY: deltaY, phase: deliveredPhase,
                                        isMomentum: isMomentum, timestamp: timestamp)
        if unphased {
            unphasedScrollEnd?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.trackingSwipe else { return }
                self.unphasedScrollEnd = nil
                _ = self.applySpaceScroll(deltaX: 0, deltaY: 0, phase: .ended, isMomentum: false, timestamp: timestamp + 0.12)
            }
            unphasedScrollEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else if phase == .ended || phase == .cancelled || isMomentum {
            unphasedScrollEnd?.cancel(); unphasedScrollEnd = nil
        }
        return consumed
    }
    private func quarantineActiveSpaceGesture() {
        if trackingSwipe {
            ignoreSpaceGestureUntilEnd = true
            scheduleIgnoredGestureEnd()
        }
    }
    private func scheduleIgnoredGestureEnd() {
        ignoredSpaceGestureEnd?.cancel()
        // Unphased devices have no finger-up event. Quarantine only their tail,
        // then permit the next gesture after a quiet period.
        let work = DispatchWorkItem { [weak self] in
            self?.ignoreSpaceGestureUntilEnd = false
            self?.ignoredSpaceGestureEnd = nil
        }
        ignoredSpaceGestureEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func applySpaceScroll(deltaX: CGFloat, deltaY: CGFloat, phase: SpaceSwipeStateMachine.Phase,
                                  isMomentum: Bool, timestamp: TimeInterval) -> Bool {
        // The creation panel owns the sidebar area; Space paging waits for it.
        guard spaceCreationPanel == nil else { return false }
        let before = SpaceSwipeDiagnostics.shared.isRecording ? swipe.diagnostics : nil
        let result = swipe.handle(deltaX: deltaX, deltaY: deltaY, phase: phase, isMomentum: isMomentum,
                                  timestamp: timestamp, space: session.spaceIndex(session.space) ?? 0, width: sidebar.bounds.width,
                                  // A committed page's remaining entrance offset is
                                  // visual only, not travel toward the previous Space.
                                  initialOffset: pagingCommit == nil ? pagingOffset : 0, spaceCount: session.spaces.count)
        SpaceSwipeDiagnostics.shared.record(["kind": "result", "phase": String(describing: phase),
            "momentum": isMomentum, "didLock": result.didLock, "consumed": result.shouldConsume,
            "finished": result.finished, "target": result.committedSpace ?? -1,
            "offset": result.previewOffset ?? pagingOffset, "releaseVelocity": result.releaseVelocity,
            "space": session.space, "axis": (result.finished ? before : swipe.diagnostics)?.axis ?? "idle",
            "totalX": (result.finished ? before : swipe.diagnostics)?.totalX ?? 0,
            "totalY": (result.finished ? before : swipe.diagnostics)?.totalY ?? 0,
            "velocityX": (result.finished ? before : swipe.diagnostics)?.velocityX ?? 0])
        if result.didLock {
            if pagingCommit != nil {
                sidebar.endPaging(); pagingOffset = 0; pagingTarget = nil
            }
            pagingAnimator.stop(); pagingCommit = nil
        }
        if let offset = result.previewOffset {
            pagingOffset = offset
            let direction: CGFloat = offset < 0 ? 1 : -1
            let targetIndex = (session.spaceIndex(session.space) ?? 0) + Int(direction)
            if session.spaces.indices.contains(targetIndex) {
                let target = session.spaces[targetIndex].id
                if pagingTarget != target {
                    sidebar.beginPaging(tabs: sidebarItems(for: target), space: target, direction: direction)
                    pagingTarget = target
                }
            } else if pagingTarget != nil { sidebar.endPaging(); pagingTarget = nil }
            sidebar.setPagingOffset(offset)
            root.previewTheme = pagingTarget.flatMap { session.spaceDefinition($0)?.theme }
            root.previewSpace = pagingTarget.flatMap { session.spaceDefinition($0)?.colorIndex }; root.previewProgress = abs(offset) / max(1, sidebar.bounds.width)
        }
        // Never advertise creation that the Space cap would refuse.
        let canCreate = session.spaces.count < BrowserSession.maximumSpaces && !isPrivateWindow
        if !result.finished { updateSpaceCreateIndicator(progress: canCreate ? result.createProgress : nil) }
        if phase == .ended || phase == .cancelled { trackingSwipe = false }
        if result.finished {
            updateSpaceCreateIndicator(progress: nil)
            capturedSpaceMomentum = result.shouldConsume
            finishPaging(commit: result.committedSpace.flatMap { session.spaces.indices.contains($0) ? session.spaces[$0].id : nil }, initialVelocity: result.releaseVelocity)
            if result.committedCreate && canCreate { openSpaceCreation() }
        }
        return result.shouldConsume
    }
    func finishPaging(commit: Int?, initialVelocity: CGFloat? = nil) {
        SpaceSwipeDiagnostics.shared.record(["kind": "settle", "space": session.space,
            "target": commit ?? -1, "offset": pagingOffset, "releaseVelocity": initialVelocity ?? 0])
        pagingCommit = commit
        if let commit {
            // Navigation is not an animation completion. Publish the selection
            // and attach the live destination before the next display frame.
            pagingOffset = sidebar.commitPaging(to: commit, preservingOffset: true)
            session.changeSpace(commit)
            showActive(); scheduleSave()
            SpaceSwipeDiagnostics.shared.record(["kind": "commit", "space": session.space,
                "target": commit, "offset": pagingOffset])
        }
        pagingAnimator.animate(from: pagingOffset, to: 0, response: 0.30, dampingRatio: 0.99,
            initialVelocity: initialVelocity, update: { [weak self] offset in
            guard let self else { return }
            self.pagingOffset = offset; self.sidebar.setPagingOffset(offset)
            // The creation panel owns the gradient preview while it is open.
            if commit == nil, self.spaceCreationPanel == nil {
                self.root.previewTheme = self.pagingTarget.flatMap { self.session.spaceDefinition($0)?.theme }
                self.root.previewSpace = self.pagingTarget.flatMap { self.session.spaceDefinition($0)?.colorIndex }
                self.root.previewProgress = abs(offset) / max(1, self.sidebar.bounds.width)
            }
        }, completion: { [weak self] in
            guard let self else { return }
            self.pagingCommit = nil
            self.sidebar.endPaging()
            self.pagingOffset = 0; self.pagingTarget = nil
            if self.spaceCreationPanel == nil { self.root.previewSpace = nil; self.root.previewProgress = 0 }
        })
    }
    func spaceDirection(to id: Int) -> CGFloat {
        (session.spaceIndex(id) ?? 0) > (session.spaceIndex(session.space) ?? 0) ? 1 : -1
    }
    func selectSpace(at index: Int) {
        guard session.spaces.indices.contains(index) else { return }
        changeSpace(session.spaces[index].id)
    }
    @objc func nextSpace(_ sender: Any?) { selectSpace(at: min(session.spaces.count - 1, (session.spaceIndex(session.space) ?? 0) + 1)) }
    @objc func previousSpace(_ sender: Any?) { selectSpace(at: max(0, (session.spaceIndex(session.space) ?? 0) - 1)) }
    func returnToVideoTab(_ id: UUID) {
        guard !isShuttingDown, session.tabs.contains(where: { $0.id == id }), let window = view.window else { return }
        let primaryID = session.split(for: id)?.primaryID ?? id
        peeks[primaryID]?.dismiss()
        select(id)
        // A nonactivating PiP can be clicked while another application is active.
        // Explicit Return restores the source window as well as the page.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let web = browsers[id], web.window === window { window.makeFirstResponder(web) }
        if let group = session.split(for: id) {
            splitCoordinators[group.primaryID]?.setFocusedSide(id == group.secondaryID ? .right : .left)
        }
        refresh()
    }
    func setSidebar(_ visible: Bool) {
        cancelPaging(); session.sidebarVisible = visible
        // Three concrete presentation-transition callbacks use this recovered curve.
        animator.animate(from: displayedWidth, to: visible ? CGFloat(session.sidebarWidth) : 0, duration: 0.08, controlPoints: (0.25, 0.46, 0.45, 0.94), update: { [weak self] value in
            guard let self else { return }; self.displayedWidth = value; self.layoutBrowser()
        }, completion: { [weak self] in self?.save() })
    }
    @objc func togglePictureInPicture(_ sender: Any?) {
        if pictureInPicture.activeTabID != nil, view.window?.isKeyWindow == false { pictureInPicture.restore(); return }
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { little.promoteToOrbit() }
        peeks[session.activeID]?.promoteToTab()
        guard let web = activeWebView else { return }
        pictureInPicture.toggle(web: web, tabID: focusedTabID, restore: { [weak self] _ in self?.showActive() }, report: { [weak self] message in
            guard let window = self?.view.window else { return }
            let alert = NSAlert(); alert.messageText = "Picture in Picture"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
        })
    }
    @objc func openVideoDemo(_ sender: Any?) {
        cancelPaging(); session.add(address: "orbit://video", title: "Picture in Picture demo"); showActive(); save()
    }
    func returnActiveVideo() { if let web = activeWebView, pictureInPicture.references(web) { pictureInPicture.restore() } }
    @objc func toggleSidebar(_ sender: Any?) { setSidebar(!session.sidebarVisible) }
    @objc func resetSidebar(_ sender: Any?) {
        session.sidebarWidth = 228; setSidebar(true)
    }
    /// Palette and menu entry points with no menu item of their own (View ▸ Appearance needs a menu item's value).
    /// App's View menu checkmarks follow through BrowserAppearance.didChange.
    @objc func useDarkAppearance(_ sender: Any?) { BrowserAppearance.apply(.dark) }
    @objc func useLightAppearance(_ sender: Any?) { BrowserAppearance.apply(.light) }
    @objc func useSystemAppearance(_ sender: Any?) { BrowserAppearance.apply(.system) }
    /// A tab dragged onto the Favorites grid. Exactly the session's own rule for a new Favorite (setRetention's): no Split members, no extension pages, a
    /// saveable address, room in that tab's profile. Folders and Splits aren't tabs here and are refused.
    func canMakeFavorite(byDropping id: UUID) -> Bool { session.canBecomeFavorite(id: id) }
    /// Makes the dropped tab a Favorite just before `anchor` (nil: at the end), then refreshes and saves as Add to
    /// Favorites does.
    func makeFavorite(byDropping id: UUID, before anchor: UUID?) -> Bool {
        guard session.canBecomeFavorite(id: id) else { return false }
        cancelPaging()
        guard session.makeFavorite(id: id, before: anchor) else { return false }
        refresh(); refreshPaletteResults(); save()
        return true
    }
    /// The Space-creation panel (it refuses, with a beep, past the Space cap).
    @objc func newSpace(_ sender: Any?) { openSpaceCreation() }
    @objc func newTab(_ sender: Any?) { cancelPaging(); openAddress(newTab: true, empty: true) }
    @objc func closeTab(_ sender: Any?) {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { little.close(); return }
        if let keyWindow = NSApp.keyWindow, keyWindow !== view.window {
            keyWindow.performClose(sender); return
        }
        if let peek = peeks[session.activeID], peek.isPresented { peek.dismiss(); return }
        // A private window goes away with its last tab, as Arc's does.
        if isPrivateWindow, session.visibleTabs.count <= 1 { view.window?.performClose(sender); return }
        close(session.activeID)
    }
    @objc func reopenTab(_ sender: Any?) { if let record = library.popClosed() { restoreClosed(record) } }
    @objc func togglePin(_ sender: Any?) { pinTab(focusedTabID) }
    @objc func goBack(_ sender: Any?) { returnActiveVideo(); commandWebView?.goBack() }
    @objc func goForward(_ sender: Any?) { returnActiveVideo(); commandWebView?.goForward() }
    @objc func reload(_ sender: Any?) {
        if let web = commandWebView, web !== activeWebView {
            if web.isLoading { web.stopLoading() }
            else if web.url == nil, let url = (web as? PreviewWKWebView)?.requestedURL { web.load(URLRequest(url: url)) }
            else { web.reload() }
            return
        }
        returnActiveVideo()
        if activeWebView?.isLoading == true || pendingLoads.contains(focusedTabID) { activeWebView?.stopLoading(); navigationTokens.removeValue(forKey: focusedTabID); pendingLoads.remove(focusedTabID) }
        else if tabErrors[focusedTabID] != nil, let address = requestedAddresses[focusedTabID] { navigate(address) }
        else { activeWebView?.reload() }
    }
    @objc func focusAddress(_ sender: Any?) {
        if let little = littleWindows.values.first(where: { $0.window?.isKeyWindow == true }) { little.focusAddress(); return }
        peeks[session.activeID]?.dismiss()
        if let split = splitCoordinators[session.activeID], session.split(for: session.activeID) != nil { split.focusAddress(split.focusedSide) }
        else { openAddress(newTab: false, empty: session.active?.isHome ?? true) }
    }
    @objc func zoomIn(_ sender: Any?) { if let web = commandWebView { zoom(web, by: 0.1) } }
    @objc func zoomOut(_ sender: Any?) { if let web = commandWebView { zoom(web, by: -0.1) } }
    @objc func actualSize(_ sender: Any?) { if let web = commandWebView { BrowserPageGestures.resetZoom(web) } }
    /// View › Zoom In / Zoom Out's step, within their limits (40%–300%).
    func zoom(_ web: WKWebView, by delta: CGFloat) { web.pageZoom = min(3, max(0.4, web.pageZoom + delta)) }

    // MARK: Site settings (the address field's button)

    /// Opens (or, if open, closes) site settings for the page in front: its connection, zoom, keep-awake and which of
    /// this profile's enabled extensions may use it. Every control acts on that same page, never a later active one.
    func showSiteSettings(from anchor: NSView) {
        guard let web = commandWebView, let site = Self.siteSettingsOrigin(web.url) else { NSSound.beep(); return }
        siteSettingsWeb = web; siteSettingsSite = site
        siteSettings.show(relativeTo: anchor, context: siteSettingsContext(for: web), actions: siteSettingsActions(for: web, site: site))
    }
    /// Re-reads the open popover's page; closes it once a different page is in front or this one has moved to another
    /// site, so no control can act on a site the popover no longer shows.
    func refreshSiteSettings() {
        guard siteSettings.isShown else { return }
        guard let web = siteSettingsWeb, web === commandWebView, siteSettingsIsCurrent(web, site: siteSettingsSite) else {
            siteSettings.close(); return
        }
        siteSettings.update(siteSettingsContext(for: web))
    }
    /// What site settings are bound to: a web page's scheme, host and port (the origin); any other page's whole URL.
    static func siteSettingsOrigin(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return url.absoluteString }
        return "\(url.scheme?.lowercased() ?? "")://\(host):\(url.port.map(String.init) ?? "")"
    }
    private func siteSettingsIsCurrent(_ web: WKWebView, site: String?) -> Bool {
        site != nil && siteSettings.isShown && siteSettingsWeb === web && siteSettingsSite == site && Self.siteSettingsOrigin(web.url) == site
    }
    private func siteSettingsContext(for web: WKWebView) -> SiteSettingsContext {
        let host = Self.keepAwakeHost(web.url)
        // Keep awake is remembered per host; a private window can't keep it, and non-web pages have no host.
        let awake: Bool? = privateMode ? nil : host.map { keepAwakeHosts.contains($0) }
        return SiteSettingsSource.context(for: web, keepsAwake: awake, extensions: siteExtensionAccess(for: web))
    }
    /// The host keep-awake protects, exactly as View › Keep This Site Awake names it (web pages only, lowercased).
    static func keepAwakeHost(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host?.lowercased()
    }
    /// Every action is bound to the page and site it was opened for, and does nothing (closing the popover) once that
    /// page has moved to another site: a late click can never change site A's settings while B is showing, or vice versa.
    private func siteSettingsActions(for web: WKWebView, site: String) -> SiteSettingsActions {
        var actions = SiteSettingsActions()
        /// The bound page, if still current; otherwise closes the popover.
        let current: () -> (BrowserController, WKWebView)? = { [weak self, weak web] in
            guard let self else { return nil }
            guard let web, self.siteSettingsIsCurrent(web, site: site) else { self.siteSettings.close(); return nil }
            return (self, web)
        }
        actions.zoomIn = { guard let (self_, web) = current() else { return }; self_.zoom(web, by: 0.1); self_.refreshSiteSettings() }
        actions.zoomOut = { guard let (self_, web) = current() else { return }; self_.zoom(web, by: -0.1); self_.refreshSiteSettings() }
        actions.resetZoom = { guard let (self_, web) = current() else { return }; BrowserPageGestures.resetZoom(web); self_.refreshSiteSettings() }
        let host = Self.keepAwakeHost(web.url)
        actions.setKeepsAwake = { on in
            guard let (self_, web) = current(), let host, Self.keepAwakeHost(web.url) == host, !self_.privateMode else { return }
            self_.setKeepAwake(host: host, on); self_.refreshSiteSettings()
        }
        actions.manageSiteAccess = { id in
            guard let (self_, _) = current() else { return }
            self_.siteSettings.close()
            self_.showExtensionSiteAccess(id)
        }
        actions.copyLink = {
            guard let (self_, web) = current(), let url = self_.cleanLink(for: web) else { return }
            self_.pageCommandPasteboard.clearContents()
            if self_.pageCommandPasteboard.setString(url.absoluteString, forType: .string), let host = web.superview {
                self_.pageFeedback.show("Link copied", symbol: "link", in: host)
            }
            self_.siteSettings.close()
        }
        actions.openSettings = { [weak self] in
            self?.siteSettings.close()
            NSApp.sendAction(Selector(("showSettings:")), to: nil, from: self)
        }
        return actions
    }
    /// What each enabled extension in this page's profile may do on it, from WebKit's own permission check:
    /// granted → allowed; requested or denied but not granted → withheld; never requested → not requested.
    private func siteExtensionAccess(for web: WKWebView) -> [SiteSettingsContext.ExtensionItem] {
        guard #available(macOS 15.4, *), let url = web.url, Self.keepAwakeHost(url) != nil else { return [] }
        let profile = profileID(of: web) ?? commandProfileID
        return browserExtensions.items(profileID: profile).filter(\.enabled).compactMap { record in
            guard let context = browserExtensions.context(for: record.id) else { return nil }
            let access: SiteSettingsContext.ExtensionAccess
            switch context.permissionStatus(for: url) {
            case .grantedExplicitly, .grantedImplicitly: access = .allowed
            case .deniedExplicitly, .deniedImplicitly, .requestedExplicitly, .requestedImplicitly: access = .withheld
            default: access = .notRequested
            }
            return SiteSettingsContext.ExtensionItem(id: record.id, name: record.name, access: access)
        }
    }
    /// Straight to one extension's Site Access editor (in the manager, with that extension selected).
    private func showExtensionSiteAccess(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        let profile = siteSettingsWeb.flatMap(profileID(of:)) ?? commandProfileID
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = profileStores.store(for: profile)
        preloadHistoryForExtensions(profileID: profile)
        browserExtensions.configure(configuration, profileID: profile)
        browserExtensions.showSiteAccess(extensionID: id, profileID: profile, relativeTo: NSApp.keyWindow ?? view.window)
    }
    func navigate(_ address: String) {
        peeks[session.activeID]?.dismiss()
        returnActiveVideo()
        let id = focusedTabID
        guard let i = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        // Leaving an Easel reference (a native view) for a web address must
        // install the new page as the visible host, not just load it hidden.
        let leavingNativeView = session.tabs[i].isArcEasel
        session.tabs[i].address = address; session.tabs[i].title = address == "orbit://newtab" ? "New tab" : (address == "orbit://video" ? "Picture in Picture demo" : URL(string: address)?.host ?? address)
        let browser = webView(for: session.tabs[i]); load(address, in: browser, id: id)
        dismissAddress()
        if leavingNativeView { showActive() } else { refresh() }
        save()
    }
    func scheduleSave() {
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.save() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func save() {
        guard !privateMode else { return }
        saveWork?.cancel(); saveWork = nil
        sessionWriter?.enqueue(session)
    }
    /// Called before teardown. New edits made during an async write must also
    /// reach disk before the main actor allows the application to terminate.
    func flushSessionForTermination(timeout: TimeInterval = 5) async -> Bool {
        guard !privateMode else { return true }
        save()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            if let writer = sessionWriter {
                guard await writer.flushAsync(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) else { return false }
            }
            // Awaiting disk keeps the app responsive: another profile may gain
            // a visit during either flush. Recheck every live library below.
            for library in Array(profileLibraries.values) {
                guard await library.flushAsync(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) else { return false }
            }
            if saveWork != nil { save(); continue }
            if sessionWriter?.isLatestSnapshotSaved != false,
               profileLibraries.values.allSatisfy(\.isLatestSnapshotSaved) { return true }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    // The command palette (open, search, site-scoped search, layout, dismissal)
    // lives in CommandPalette.swift.

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tabActivityProbe.invalidate(webView)
        if let id = browsers.first(where: { $0.value === webView })?.key {
            invalidateFaviconDocument(id); historyTitleFollowUps.removeValue(forKey: id)
            tabErrors.removeValue(forKey: id); pendingLoads.insert(id)
        }
        if visibleMemberIDs.contains(where: { browsers[$0] === webView }) { scheduleChromeRefresh() }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let id = browsers.first(where: { $0.value === webView })?.key {
            pendingLoads.remove(id)
            if let nonGet = pendingNonGetDocuments.removeValue(forKey: id) {
                if nonGet { nonGetDocuments.insert(id) } else { nonGetDocuments.remove(id) }
            }
        }
        updateMetadata(webView); scheduleExtensionRefresh()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = browsers.first(where: { $0.value === webView })?.key { tabErrors.removeValue(forKey: id); pendingLoads.remove(id) }
        updateMetadata(webView)
        restoreSleepingPage(webView)
        scheduleFaviconDiscovery(in: webView)
        if let id = browsers.first(where: { $0.value === webView })?.key { historyTitleFollowUps.removeValue(forKey: id) }
        if let url = webView.url, let profile = profileID(of: webView),
           let visit = library(for: profile).recordVisit(title: webView.title ?? url.host ?? "Page", address: url.absoluteString),
           let id = browsers.first(where: { $0.value === webView })?.key {
            historyTitleFollowUps[id] = HistoryTitleFollowUp(profileID: profile, visit: visit)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error, web: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error, web: webView) }
    func showError(_ error: Error, web: WKWebView) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if let id = browsers.first(where: { $0.value === web })?.key {
            pendingLoads.remove(id); pendingNonGetDocuments.removeValue(forKey: id); historyTitleFollowUps.removeValue(forKey: id)
            if let failed = (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String, URLInput.directURL(failed) != nil { requestedAddresses[id] = failed }
            tabErrors[id] = ContentBlocking.stoppedPage(error) ? "Page blocked by Bam’s filter lists" : "Couldn’t load page — ⌘R to retry"; refresh()
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tabActivityProbe.invalidate(webView)
        guard let id = browsers.first(where: { $0.value === webView })?.key else { return }
        historyTitleFollowUps.removeValue(forKey: id)
        if nonGetDocuments.contains(id) {
            if pictureInPicture.references(webView) { pictureInPicture.restore() }
            pendingLoads.remove(id)
            tabErrors[id] = "Page process ended — reload manually to retry"
            refresh(); return
        }
        if visibleMemberIDs.contains(id) || pictureInPicture.references(webView) || session.split(for: id) != nil {
            if pictureInPicture.references(webView) { pictureInPicture.restore() }
            webView.reload()
        } else if let address = webView.url?.absoluteString, ["http", "https"].contains(webView.url?.scheme ?? "") {
            // The process is already gone. Avoid resurrecting every background
            // renderer under pressure; selection performs a fresh load.
            releaseSleepingPage(id, web: webView, state: TabSleepState(address: address, scrollX: 0, scrollY: 0))
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload, ["http", "https", "blob", "data"].contains(scheme) { decisionHandler(.download); return }
        if scheme == "orbit", url.host == "newtab" {
            decisionHandler(.cancel)
            guard navigationAction.targetFrame?.isMainFrame == true,
                  let sourceID = browsers.first(where: { $0.value === webView })?.key else { return }
            navigatePane(sourceID, address: "orbit://newtab")
            return
        }
        if scheme == "file" {
            guard let resources = Bundle.main.resourceURL, url.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/") else { decisionHandler(.cancel); return }
        } else if ["webkit-extension", "safari-web-extension"].contains(scheme) {
            guard let profile = profileID(of: webView), allowsExtensionPage(url, profileID: profile) else { decisionHandler(.cancel); return }
        } else if !["http", "https", "about"].contains(scheme) { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated, let address = URLInput.directURL(url.absoluteString) {
            let modifiers = navigationAction.modifierFlags
            if modifiers.contains([.command, .option]) { openLittleOrbit(url: address, profileID: profileID(of: webView)); decisionHandler(.cancel); return }
            if modifiers.contains(.command) {
                if let profile = profileID(of: webView) {
                    _ = openProfileTab(address, profileID: profile, active: modifiers.contains(.shift),
                                       opener: browsers.first(where: { $0.value === webView })?.key)
                }
                decisionHandler(.cancel); return
            }
            let sourceID = browsers.first(where: { $0.value === webView })?.key
            let sourceTab = sourceID.flatMap { id in session.tabs.first(where: { $0.id == id }) }
            let crossesPinnedOrigin = sourceTab?.pinned == true && address.host?.lowercased() != webView.url?.host?.lowercased()
            if let sourceID, visibleMemberIDs.contains(sourceID), modifiers.contains(.shift) || crossesPinnedOrigin {
                if let group = session.split(for: sourceID) {
                    splitCoordinators[group.primaryID]?.setFocusedSide(sourceID == group.secondaryID ? .right : .left)
                }
                openPeek(address); decisionHandler(.cancel); return
            }
        }
        if navigationAction.targetFrame?.isMainFrame == true, let id = browsers.first(where: { $0.value === webView })?.key {
            invalidateFaviconDocument(id)
            let newOrigin = ["webkit-extension", "safari-web-extension"].contains(scheme) ? url.host?.lowercased() : nil
            if browserExtensionOrigins[id] != newOrigin {
                // Do not replay a form submission across renderer configurations.
                guard navigationAction.request.httpMethod?.uppercased() == "GET" else { decisionHandler(.cancel); return }
                decisionHandler(.cancel)
                navigatePane(id, address: url.absoluteString); return
            }
            if ["http", "https"].contains(scheme) { TabActivityProbe.install(in: webView.configuration) }
            tabActivityProbe.invalidate(webView)
            // Classify the new document only after commit. A failed GET must
            // not erase protection for the POST response still displayed.
            pendingNonGetDocuments[id] = navigationAction.request.httpMethod?.uppercased() != "GET"
            if sleepRestores[id]?.address != url.absoluteString { sleepRestores.removeValue(forKey: id) }
            requestedAddresses[id] = scheme == "file" ? (url.lastPathComponent == "PiPDemo.html" ? "orbit://video" : "orbit://newtab") : url.absoluteString
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, let profile = profileID(of: webView) {
            _ = openProfileTab(url, profileID: profile, active: true, opener: browsers.first(where: { $0.value === webView })?.key)
        }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page message"; alert.informativeText = message; alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window) { _ in completionHandler() } } else { completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Page confirmation"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        if let window = view.window { alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) } } else { completionHandler(false) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt; let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); input.stringValue = defaultText ?? ""; alert.accessoryView = input; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        if let window = view.window { alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) } } else { completionHandler(nil) }
    }
}

/// Shown when an Arc Easel reference is selected: what it is, honestly, with
/// no web content and no link to Arc (Bam can't open or verify the canvas).
@MainActor final class EaselReferenceView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }
    var shownName: String { title.stringValue }
    init(title name: String) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor; icon.setAccessibilityElement(false)
        title.stringValue = name; title.font = .systemFont(ofSize: 20, weight: .semibold); title.alignment = .center
        title.lineBreakMode = .byTruncatingTail; title.textColor = .labelColor
        message.stringValue = "An Easel from Arc. Bam kept its name and its place in your sidebar, but not its canvas — that stays in Arc. Bam can’t open Easels."
        message.font = .systemFont(ofSize: 13); message.alignment = .center; message.textColor = .secondaryLabelColor
        [icon, title, message].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(name). Easel from Arc; its canvas wasn’t imported.")
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func applyColors() { layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    override func layout() {
        super.layout()
        let width = min(420, max(0, bounds.width - 48)), x = (bounds.width - width) / 2
        let messageHeight = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400)).height ?? 40
        let total = 44 + 14 + 26 + 10 + messageHeight
        var y = max(24, (bounds.height - total) / 2)
        icon.frame = NSRect(x: bounds.midX - 22, y: y, width: 44, height: 44); y += 58
        title.frame = NSRect(x: x, y: y, width: width, height: 26); y += 36
        message.frame = NSRect(x: x, y: y, width: width, height: messageHeight)
    }
}

@MainActor final class PiPPlaceholder: NSView {
    var returnVideo: (() -> Void)?
    private let title = NSTextField(labelWithString: "Playing in Picture in Picture")
    private let button = NSButton(title: "Return video to tab", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
        title.textColor = .labelColor; title.font = .systemFont(ofSize: 20, weight: .medium); title.alignment = .center
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(returnClicked)
        addSubview(title); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); title.frame = NSRect(x: 20, y: bounds.midY-36, width: bounds.width-40, height: 30); button.frame = NSRect(x: bounds.midX-95, y: bounds.midY+10, width: 190, height: 32) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: self)
    }
    @objc func returnClicked() { returnVideo?() }
}

/// Window and page-frame colors for both appearances.
@MainActor enum BrowserChrome {
    /// Behind the page while it loads, and the blank new-tab surface.
    static let pageSurface = NSColor.chrome(light: NSColor(white: 0.985, alpha: 1), dark: NSColor(white: 0.10, alpha: 1))
    static let windowBackground = NSColor.chrome(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(white: 0.10, alpha: 1))
    static let cardEdge = NSColor.chrome(light: .black, dark: .white)
    static let progress = NSColor.chrome(light: NSColor(srgbRed: 0.42, green: 0.33, blue: 0.70, alpha: 1),
                                         dark: NSColor(srgbRed: 0.47, green: 0.39, blue: 0.66, alpha: 1))
}

@MainActor extension BrowserController {
    /// Layer-backed chrome stores fixed CGColors; re-resolve them for the current appearance.
    func applyChromeColors() {
        card.layer?.backgroundColor = resolvedCGColor(BrowserChrome.pageSurface, for: card)
        progress.layer?.backgroundColor = resolvedCGColor(BrowserChrome.progress, for: progress)
        if isViewLoaded { layoutBrowser() }
        applyWindowTranslucency()
    }
}
