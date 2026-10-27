import AppKit
import WebKit

// Private windows (File ▸ New Private Window, ⇧⌘N), modeled on Arc's incognito window:
// a near-black window with one Space and a small "Private" label under the address field,
// no Space buttons, no history, no extensions. Its website data lives in nonpersistent
// stores that are wiped and released when the window closes, and nothing about it is
// saved or restored.

extension BrowserSession {
    /// A private window's whole session: one Space holding one blank tab.
    static func privateWindow() -> BrowserSession {
        let home = BrowserTab(title: "New tab", address: "orbit://newtab", space: 0)
        let space = BrowserSpace(id: 0, name: "Private", symbol: "eye.slash", colorIndex: 5, theme: PrivateWindowStyle.theme)
        return BrowserSession(tabs: [home], activeID: home.id, lastSelectedTabIDsBySpace: [0: home.id], spaces: [space])
    }
}

enum PrivateWindowStyle {
    /// Selection follows Arc's incognito indigo (sampled #5361d8).
    /// Arc's incognito window is a flat blue-black (sampled #101318), in light and dark alike.
    static let background = SpaceTheme.RGBA(red: 0x10 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0)!
    static let theme: SpaceTheme? = {
        let roles = SpaceTheme.Roles(background: background, backgroundExtra: background,
                                     title: SpaceTheme.RGBA(red: 1, green: 1, blue: 1)!, subtitle: nil)
        return SpaceTheme(gradient: [background], light: roles, dark: roles,
                          accent: SpaceTheme.RGBA(red: 0x53 / 255.0, green: 0x61 / 255.0, blue: 0xd8 / 255.0)!)
    }()
}

extension PaletteCommandCatalog {
    /// Commands that make no sense in a private window: Spaces, folders, extensions,
    /// history it never keeps, setup, and windows that belong to the main browser.
    static let hiddenInPrivateWindow: Set<String> = [
        "manage-spaces", "new-space", "next-space", "previous-space", "new-folder", "import-arc",
        "extensions", "add-extension", "history", "little-window", "welcome"
    ]
    static func availableInPrivateWindow(_ command: PaletteCommand) -> Bool { !hiddenInPrivateWindow.contains(command.id) }
}

/// Tells app-wide features whether a page belongs to a private window, by its website data store.
@MainActor enum PrivateBrowsing {
    private static let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
    static func register(_ store: WKWebsiteDataStore) { stores.add(store) }
    static func isPrivate(_ web: WKWebView) -> Bool { stores.contains(web.configuration.websiteDataStore) }
}

extension BrowserController {
    /// Wipes everything a private window's pages stored, then releases its pages.
    /// Called once, as its window closes.
    func discardPrivateWindowData() {
        guard isPrivateWindow else { return }
        prepareToClose(persistSession: false)
        // App-wide key monitors would otherwise outlive the window (their closures hold it weakly).
        tabNavigation.monitors.forEach(NSEvent.removeMonitor); tabNavigation.monitors.removeAll()
        if let observer = tabNavigation.resignObserver { NotificationCenter.default.removeObserver(observer); tabNavigation.resignObserver = nil }
        for id in Array(browsers.keys) { teardownPage(id) }
        for store in profileStores.openedStores {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        profileStores.releaseStores()
    }
}

/// One private window and its controller. The app delegate keeps these until they close.
@MainActor final class PrivateWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let controller: BrowserController
    var onClose: ((PrivateWindowController) -> Void)?

    init(supportDirectory: URL, cascadeFrom reference: NSWindow?) {
        // The session URL is never written (private controllers have no session writer); it only names a folder.
        controller = BrowserController(sessionURL: supportDirectory.appendingPathComponent("private-session.json"), privateWindow: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Private"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false; window.minSize = NSSize(width: 760, height: 540)
        // Dark like Arc's incognito window, whatever View ▸ Appearance says.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(spaceTheme: PrivateWindowStyle.background)
        window.contentViewController = controller
        controller.sidebar.isPrivateWindow = true
        window.delegate = self
        if let reference, reference.isVisible {
            // Arc opens its incognito window exactly over the window you were in.
            window.setFrame(reference.frame, display: false)
        } else {
            let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            window.setContentSize(NSSize(width: min(1260, available.width - 60), height: min(800, available.height - 60)))
            window.center()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        // Arc opens a new incognito window with the command bar up.
        controller.openAddress(newTab: false, empty: true)
    }

    func windowWillClose(_ notification: Notification) {
        controller.discardPrivateWindowData()
        window.contentViewController = nil
        window.delegate = nil
        onClose?(self)
    }
}

/// The target of every browser menu command. AppKit asks it about each selector; it hands the
/// message to the browser in the key window: a private window's own controller, or the main
/// browser otherwise (which also answers for its Little Bam windows, Peek and panels).
@MainActor final class BrowserCommandRouter: NSObject, NSMenuItemValidation {
    weak var main: BrowserController?
    var privateWindows: () -> [PrivateWindowController] = { [] }
    /// Commands that always belong to the main browser, even with a private window in front.
    static let mainOnly: Set<Selector> = [
        #selector(BrowserController.newLittleOrbit(_:)), #selector(BrowserController.importFromArc(_:))
    ]
    /// Commands a private window doesn't offer (it has one Space, no folders, no extensions, no history).
    static let unavailableInPrivate: Set<Selector> = [
        #selector(BrowserController.manageSpaces(_:)), #selector(BrowserController.newFolder(_:)),
        #selector(BrowserController.nextSpace(_:)), #selector(BrowserController.previousSpace(_:)),
        #selector(BrowserController.showHistory(_:)), #selector(BrowserController.togglePin(_:)),
        #selector(BrowserController.toggleFavorite(_:)), #selector(BrowserController.showExtensionLibrary(_:))
    ]
    /// The private window in front, if any. Sheets, popovers and child panels count as their parent window,
    /// and a Little Bam opened from a private window (⌥⌘-click, Peek) counts as that window.
    var keyPrivateWindow: PrivateWindowController? {
        var window = NSApp.keyWindow ?? NSApp.mainWindow
        while let current = window {
            if let match = privateWindows().first(where: { entry in
                entry.window === current || entry.controller.littleWindows.values.contains { $0.window === current }
            }) { return match }
            window = current.sheetParent ?? current.parent
        }
        return nil
    }
    func target(for selector: Selector?) -> BrowserController? {
        if let selector, Self.mainOnly.contains(selector) { return main }
        return keyPrivateWindow?.controller ?? main
    }
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return target(for: aSelector)?.responds(to: aSelector) ?? false
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? { target(for: aSelector) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let target = target(for: action) else { return false }
        if target.isPrivateWindow, Self.unavailableInPrivate.contains(action) { return false }
        return target.validateMenuItem(menuItem)
    }
}
