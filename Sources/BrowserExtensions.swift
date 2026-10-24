import Foundation
import AppKit
import WebKit

/// A borrowed page surface. Enumerating extensions must not instantiate sleeping pages.
@MainActor struct BrowserExtensionSurface {
    let id: UUID
    let title: String
    let url: URL?
    let webView: WKWebView?
    let window: NSWindow?
    var isActive: Bool = false
    var isSelected: Bool = false
    var isPinned: Bool = false
}

struct BrowserExtensionRecord: Codable, Identifiable {
    let id: UUID
    let profileID: UUID
    var name: String
    var version: String
    var packageName: String
    var enabled: Bool = false
    var permissions: [String: Date] = [:]
    var patterns: [String: Date] = [:]
    var deniedPermissions: [String: Date] = [:]
    var deniedPatterns: [String: Date] = [:]
    var compatibilityNote: String? = nil
}

struct BrowserExtensionPermissionReview {
    let name: String
    let profileName: String
    let permissions: [String]
    let websites: [String]
    let unsupported: [String]
    let isOptional: Bool
    var compatibilityNote: String? = nil
}

@available(macOS 15.4, *)
@MainActor final class BrowserExtensions: NSObject {
    var surfaces: ((UUID) -> [BrowserExtensionSurface])?
    /// Optional live lookup; a nil result is authoritative, never a cache miss.
    var surface: ((UUID, UUID) -> BrowserExtensionSurface?)?
    var profileName: ((UUID) -> String)?
    var selectTab: ((UUID) -> Bool)?
    var closeTab: ((UUID) -> Bool)?
    var navigateTab: ((UUID, URL) -> Bool)?
    var reloadTab: ((UUID, Bool) -> Bool)?
    var createTab: ((URL, UUID, Bool) -> UUID?)?
    var onChange: (() -> Void)?
    /// Informs the browser that already loaded pages need a user-requested reload.
    var onReloadNeeded: ((UUID) -> Void)?
    /// Tests supply an explicit decision; production defaults to native review.
    var permissionPrompt: ((BrowserExtensionPermissionReview) -> Bool)?
    private(set) var records: [BrowserExtensionRecord] = []
    private(set) var lastError: String?
    private(set) var errors: [UUID: String] = [:]
    let isPrivate: Bool
    let storageURL: URL
    private let ownsTemporaryStorage: Bool
    private var runtimes: [UUID: BrowserExtensionRuntime] = [:]
    private var preparation: [UUID: Task<Void, Never>] = [:]
    private var loading = Set<UUID>()
    private var loadGeneration: [UUID: UUID] = [:]
    private var manager: ExtensionManagement?
    private var stopped = false

    static let supportedPermissions: Set<String> = ["activeTab", "alarms", "clipboardWrite", "contextMenus", "menus", "cookies", "declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]
    static let unsupportedAPIs: Set<String> = ["browser.runtime.sendNativeMessage", "browser.runtime.connectNative", "browser.windows.create", "browser.windows.remove", "browser.windows.update", "browser.tabs.move", "browser.tabs.duplicate", "browser.tabs.highlight", "browser.tabs.discard", "browser.tabs.detectLanguage", "browser.bookmarks", "browser.history", "browser.downloads", "browser.identity", "browser.management", "browser.sessions", "browser.notifications"]

    init(storageURL: URL?, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        ownsTemporaryStorage = storageURL == nil || isPrivate
        self.storageURL = ownsTemporaryStorage
            ? FileManager.default.temporaryDirectory.appendingPathComponent("bam-extensions-\(UUID().uuidString)", isDirectory: true)
            : storageURL!
        super.init()
        if !ownsTemporaryStorage {
            let registry = self.storageURL.appendingPathComponent("registry.json")
            if FileManager.default.fileExists(atPath: registry.path) {
                do {
                    let decoded = try JSONDecoder().decode([BrowserExtensionRecord].self, from: Data(contentsOf: registry))
                    var seen = Set<UUID>()
                    records = decoded.filter { seen.insert($0.id).inserted && $0.packageName == "package" }
                } catch { lastError = "Extensions could not be restored: \(error.localizedDescription)" }
            }
        }
    }

    /// Call after assigning the page's profile data store, before creating WKWebView.
    func configure(_ configuration: WKWebViewConfiguration, profileID: UUID) {
        let runtime = ensureRuntime(profileID: profileID, dataStore: configuration.websiteDataStore)
        configuration.websiteDataStore = runtime.dataStore
        configuration.webExtensionController = runtime.controller
    }

    func prepare(profileID: UUID, dataStore: WKWebsiteDataStore) async {
        _ = ensureRuntime(profileID: profileID, dataStore: dataStore)
        await ready(profileID: profileID)
    }

    /// Await before a profile page's first navigation; empty profiles finish immediately.
    func ready(profileID: UUID) async { await preparation[profileID]?.value }

    func whenReady(profileID: UUID, perform: @escaping @MainActor () -> Void) {
        guard let task = preparation[profileID] else { perform(); return }
        Task { @MainActor [weak self] in await task.value; guard self?.stopped == false else { return }; perform() }
    }

    private func ensureRuntime(profileID: UUID, dataStore: WKWebsiteDataStore) -> BrowserExtensionRuntime {
        if let existing = runtimes[profileID] { return existing }
        let runtime = BrowserExtensionRuntime(owner: self, profileID: profileID, dataStore: dataStore)
        runtimes[profileID] = runtime
        if records.contains(where: { $0.profileID == profileID && $0.enabled }) {
            preparation[profileID] = Task { @MainActor [weak self] in
                guard let self else { return }
                for record in self.records where record.profileID == profileID && record.enabled {
                    do { try await self.load(record.id, review: false) }
                    catch { self.setError(error, for: record.id) }
                }
                self.preparation.removeValue(forKey: profileID)
            }
        }
        return runtime
    }

    func reconcile() { for runtime in runtimes.values { runtime.reconcile() } }
    func context(for id: UUID) -> WKWebExtensionContext? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        return runtimes[record.profileID]?.contexts[id]
    }
    func allowsExtensionURL(_ url: URL, profileID: UUID) -> Bool {
        guard let context = runtimes[profileID]?.controller.extensionContext(for: url) else { return false }
        return Self.isExtensionURL(url, ownedBy: context)
    }
    func configuration(forExtensionURL url: URL, profileID: UUID) -> WKWebViewConfiguration? {
        guard let runtime = runtimes[profileID], let context = runtime.controller.extensionContext(for: url),
              Self.isExtensionURL(url, ownedBy: context) else { return nil }
        let configuration = context.webViewConfiguration
        configuration?.websiteDataStore = runtime.dataStore
        return configuration
    }
    static func isExtensionURL(_ url: URL, ownedBy context: WKWebExtensionContext) -> Bool {
        url.scheme == context.baseURL.scheme && url.host == context.baseURL.host && url.port == context.baseURL.port && url.user == nil && url.password == nil
    }
    func items(profileID: UUID) -> [BrowserExtensionRecord] { records.filter { $0.profileID == profileID } }
    func showManager(profileID: UUID, relativeTo window: NSWindow?) {
        if manager == nil { manager = ExtensionManagement(host: self) }
        manager?.show(profileID: profileID, relativeTo: window)
    }
    func actionsMenu(profileID: UUID, tabID: UUID?, anchor: NSView) -> NSMenu {
        let menu = NSMenu(title: "Extensions")
        for record in items(profileID: profileID) where record.enabled && context(for: record.id) != nil {
            let item = NSMenuItem(title: record.name, action: #selector(invokeMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ExtensionActionRequest(id: record.id, tabID: tabID, anchor: anchor)
            if let context = context(for: record.id) {
                let action = context.action(for: tabID.flatMap { runtimes[profileID]?.tabs[$0] })
                item.image = action?.icon(for: NSSize(width: 16, height: 16))
                item.isEnabled = action?.isEnabled ?? true
            }
            menu.addItem(item)
            // These items and actions are implemented by WebKit, and fetched fresh.
            if let context = context(for: record.id), let tabID, let runtime = runtimes[profileID],
               runtime.currentSurface(tabID) != nil, let tab = runtime.tabs[tabID] {
                let nativeItems = context.menuItems(for: tab)
                if !nativeItems.isEmpty {
                    let commands = NSMenuItem(title: "\(record.name) · Tab Commands", action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: commands.title)
                    for nativeItem in nativeItems { submenu.addItem(nativeItem) }
                    commands.submenu = submenu; menu.addItem(commands)
                }
            }
        }
        if menu.items.isEmpty { let item = NSMenuItem(title: "No enabled extensions", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        return menu
    }
    @objc private func invokeMenuAction(_ item: NSMenuItem) {
        guard let request = item.representedObject as? ExtensionActionRequest else { return }
        performAction(extensionID: request.id, tabID: request.tabID, anchor: request.anchor)
    }
    func performAction(extensionID: UUID, tabID: UUID?, anchor: NSView?) {
        guard let record = records.first(where: { $0.id == extensionID && $0.enabled }),
              let runtime = runtimes[record.profileID], let context = runtime.contexts[extensionID] else { return }
        runtime.reconcile()
        guard tabID == nil || runtime.tabs[tabID!] != nil else { return }
        runtime.popupAnchor = anchor
        context.performAction(for: tabID.flatMap { runtime.tabs[$0] })
    }

    /// Copies only the explicitly selected package, then reviews capabilities before loading.
    @discardableResult func importPackage(at source: URL, profileID: UUID) async throws -> UUID {
        guard runtimes[profileID] != nil else { throw Self.failure("Open this profile before installing an extension.") }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw Self.failure("Choose an unpacked extension folder containing manifest.json. Archives, CRX and browser stores are not supported.")
        }
        try Self.validatePackageSize(source)
        let id = UUID(), name = "package"
        let folder = storageURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let package = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: package)
            // Recheck the private copy: the selected folder may change while copied.
            try Self.validatePackageSize(package)
            let compatibilityNote = try ExtensionPackagePreparation.prepare(package: package, originalManifestURL: folder.appendingPathComponent("original-manifest.json"))
            let ext = try await WKWebExtension(resourceBaseURL: package)
            guard ext.errors.isEmpty else { throw Self.failure(ext.errors.map(\.localizedDescription).joined(separator: "\n")) }
            guard !stopped else { throw Self.failure("The browser is closing.") }
            records.append(BrowserExtensionRecord(id: id, profileID: profileID, name: ext.displayName ?? "Unnamed extension", version: ext.version ?? "", packageName: name, compatibilityNote: compatibilityNote))
            try persist()
            do { try await load(id, review: true, parsed: ext) } catch { setError(error, for: id) }
            changed()
            return id
        } catch {
            records.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID) async throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if enabled { try await load(id, review: true) }
        else {
            loadGeneration.removeValue(forKey: id)
            if let runtime = runtimes[records[i].profileID], let context = runtime.contexts[id] {
                runtime.closePopup(for: context)
                try runtime.controller.unload(context)
                runtime.contexts.removeValue(forKey: id)
            }
            records[i].enabled = false
            try persist(); onReloadNeeded?(records[i].profileID); changed()
        }
    }
    func remove(id: UUID) async throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        try await setEnabled(false, id: id)
        if let runtime = runtimes[record.profileID] {
            let data = await runtime.controller.dataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes)
            let matching = data.filter { $0.uniqueIdentifier == id.uuidString.lowercased() }
            await runtime.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: matching)
        }
        records.removeAll { $0.id == id }; errors.removeValue(forKey: id)
        try persist()
        try FileManager.default.removeItem(at: storageURL.appendingPathComponent(record.id.uuidString, isDirectory: true))
        changed()
    }
    func revokePermissions(id: UUID) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].permissions = [:]; records[i].patterns = [:]
        if let context = context(for: id) { context.grantedPermissions = [:]; context.grantedPermissionMatchPatterns = [:] }
        try persist(); onReloadNeeded?(records[i].profileID); changed()
    }

    private func load(_ id: UUID, review: Bool, parsed: WKWebExtension? = nil) async throws {
        guard !loading.contains(id), let record = records.first(where: { $0.id == id }), let runtime = runtimes[record.profileID] else { return }
        if runtime.contexts[id] != nil { return }
        let token = UUID(); loadGeneration[id] = token
        loading.insert(id); defer { loading.remove(id); if loadGeneration[id] == token { loadGeneration.removeValue(forKey: id) } }
        let ext: WKWebExtension
        if let parsed { ext = parsed } else { ext = try await WKWebExtension(resourceBaseURL: packageURL(record)) }
        guard ext.errors.isEmpty else { throw Self.failure(ext.errors.map(\.localizedDescription).joined(separator: "\n")) }
        guard !stopped, loadGeneration[id] == token, let initialIndex = records.firstIndex(where: { $0.id == id }), review || records[initialIndex].enabled else { return }
        var index = initialIndex
        if review {
            let requested = Set(ext.requestedPermissions.map(\.rawValue))
            let supported = requested.intersection(Self.supportedPermissions)
            let patterns = ext.allRequestedMatchPatterns.map(\.string).sorted()
            let details = BrowserExtensionPermissionReview(name: record.name, profileName: profileName?(record.profileID) ?? "Current profile", permissions: supported.sorted(), websites: patterns,
                unsupported: requested.subtracting(supported).sorted(), isOptional: false, compatibilityNote: record.compatibilityNote)
            guard approve(details) else { changed(); return }
            // Native review runs a nested loop; deletion, disabling or shutdown wins.
            guard !stopped, loadGeneration[id] == token,
                  let currentIndex = records.firstIndex(where: { $0.id == id && $0.profileID == record.profileID }) else { return }
            index = currentIndex
            records[index].permissions = Dictionary(uniqueKeysWithValues: supported.map { ($0, Date.distantFuture) })
            records[index].patterns = Dictionary(uniqueKeysWithValues: patterns.map { ($0, Date.distantFuture) })
            records[index].deniedPermissions = [:]; records[index].deniedPatterns = [:]
        }
        let current = records[index]
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = id.uuidString.lowercased()
        context.baseURL = URL(string: "webkit-extension://\(id.uuidString.lowercased())/")!
        context.unsupportedAPIs = Self.unsupportedAPIs
        context.hasAccessToPrivateData = isPrivate
        context.grantedPermissions = Dictionary(uniqueKeysWithValues: current.permissions.filter { Self.supportedPermissions.contains($0.key) }.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
        context.grantedPermissionMatchPatterns = Self.matchPatterns(current.patterns)
        context.deniedPermissions = Dictionary(uniqueKeysWithValues: current.deniedPermissions.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
        context.deniedPermissionMatchPatterns = Self.matchPatterns(current.deniedPatterns)
        try runtime.controller.load(context)
        runtime.contexts[id] = context
        records[index].enabled = true; errors.removeValue(forKey: id)
        do { try persist() } catch {
            runtime.contexts.removeValue(forKey: id); try? runtime.controller.unload(context); records[index].enabled = false; throw error
        }
        runtime.reconcile()
        if review { onReloadNeeded?(record.profileID) }
        changed()
    }
    private static func matchPatterns(_ values: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
        var result: [WKWebExtension.MatchPattern: Date] = [:]
        for (key, expiry) in values { if let pattern = try? WKWebExtension.MatchPattern(string: key) { result[pattern] = expiry } }
        return result
    }
    private func packageURL(_ record: BrowserExtensionRecord) -> URL { storageURL.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.packageName) }
    func approve(_ review: BrowserExtensionPermissionReview) -> Bool { permissionPrompt?(review) ?? ExtensionManagement.reviewPermissions(review) }
    func persistPermissions(_ context: WKWebExtensionContext) {
        guard let id = UUID(uuidString: context.uniqueIdentifier), let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].permissions = Dictionary(uniqueKeysWithValues: context.grantedPermissions.map { ($0.key.rawValue, $0.value) })
        records[i].patterns = Dictionary(uniqueKeysWithValues: context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
        records[i].deniedPermissions = Dictionary(uniqueKeysWithValues: context.deniedPermissions.map { ($0.key.rawValue, $0.value) })
        records[i].deniedPatterns = Dictionary(uniqueKeysWithValues: context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
        do { try persist() } catch { setError(error, for: id) }
    }
    private func persist() throws {
        if ownsTemporaryStorage { return }
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: storageURL.appendingPathComponent("registry.json"), options: .atomic)
    }
    func setError(_ error: Error, for id: UUID? = nil) {
        lastError = error.localizedDescription
        if let id { errors[id] = error.localizedDescription }
        changed()
    }
    func changed() { manager?.refresh(); onChange?() }
    func shutdown() {
        stopped = true; manager?.close(); manager = nil
        for task in preparation.values { task.cancel() }; preparation.removeAll()
        for runtime in runtimes.values { for context in runtime.contexts.values { runtime.closePopup(for: context); try? runtime.controller.unload(context) }; runtime.contexts.removeAll() }
        runtimes.removeAll()
        surfaces = nil; selectTab = nil; closeTab = nil; navigateTab = nil; reloadTab = nil; createTab = nil
        if ownsTemporaryStorage { try? FileManager.default.removeItem(at: storageURL) }
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "BamExtensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func validatePackageSize(_ url: URL) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let initial = try url.resourceValues(forKeys: keys)
        guard initial.isDirectory == true, initial.isSymbolicLink != true else { throw failure("Choose a regular extension folder without symbolic links.") }
        var bytes: Int64 = 0, count = 1
        var traversalError: Error?
        do {
            guard let items = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in traversalError = error; return false }) else { throw failure("This extension folder cannot be read.") }
            for case let file as URL in items {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw failure("Extension folders must contain regular files, without symbolic links.") }
                count += 1; if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
                guard count <= 10_000, bytes <= 100 * 1_024 * 1_024 else { throw failure("This local extension exceeds Bam’s 100 MB / 10,000-file import limit.") }
            }
            if let traversalError { throw traversalError }
        }
        guard bytes <= 100 * 1_024 * 1_024 else { throw failure("This local extension exceeds Bam’s 100 MB import limit.") }
    }
}

@available(macOS 15.4, *)
@MainActor private final class ExtensionActionRequest: NSObject {
    let id: UUID; let tabID: UUID?; weak var anchor: NSView?
    init(id: UUID, tabID: UUID?, anchor: NSView) { self.id = id; self.tabID = tabID; self.anchor = anchor }
}

@available(macOS 15.4, *)
@MainActor final class BrowserExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    weak var owner: BrowserExtensions?
    let profileID: UUID
    let dataStore: WKWebsiteDataStore
    let controller: WKWebExtensionController
    let extensionContentController = WKUserContentController()
    var contexts: [UUID: WKWebExtensionContext] = [:]
    var tabs: [UUID: BrowserExtensionTab] = [:]
    var windows: [ObjectIdentifier: BrowserExtensionWindow] = [:]
    var snapshots: [UUID: BrowserExtensionSurface] = [:]
    var orderedIDs: [UUID] = []
    weak var popupAnchor: NSView?
    private var activePopup: WKWebExtension.Action?
    private var lastFocusedWindow: ObjectIdentifier?
    private var reportedActiveTabs: [ObjectIdentifier: UUID] = [:]
    private var observers: [NSObjectProtocol] = []

    init(owner: BrowserExtensions, profileID: UUID, dataStore: WKWebsiteDataStore) {
        self.owner = owner; self.profileID = profileID; self.dataStore = dataStore
        let configuration = owner.isPrivate ? WKWebExtensionController.Configuration.nonPersistent() : WKWebExtensionController.Configuration(identifier: profileID)
        configuration.defaultWebsiteDataStore = dataStore
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = dataStore
        // Materialize the shared controller before WebKit copies the configuration.
        // A default lazy UCC read through controller.configuration belongs to a copy.
        webConfiguration.userContentController = extensionContentController
        configuration.webViewConfiguration = webConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init(); controller.delegate = self
        let names: [Notification.Name] = [WKWebExtensionContext.errorsDidUpdateNotification,
            WKWebExtensionContext.permissionsWereGrantedNotification, WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification, WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification, WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification, WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self, let context = notification.object as? WKWebExtensionContext,
                          context.webExtensionController === self.controller else { return }
                    if name == WKWebExtensionContext.errorsDidUpdateNotification {
                        if let error = context.errors.first { self.owner?.setError(error, for: UUID(uuidString: context.uniqueIdentifier)) }
                    } else {
                        self.owner?.persistPermissions(context)
                    }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func closePopup(for context: WKWebExtensionContext) {
        if activePopup?.webExtensionContext === context { activePopup?.closePopup(); activePopup = nil }
        context.action(for: nil)?.closePopup()
    }
    func owns(_ context: WKWebExtensionContext) -> Bool { context.webExtensionController === controller }
    /// Cached event snapshots are never authority for a live browser action.
    func currentSurface(_ id: UUID) -> BrowserExtensionSurface? {
        let surface: BrowserExtensionSurface?
        if let lookup = owner?.surface { surface = lookup(profileID, id) }
        else { surface = owner?.surfaces?(profileID).first(where: { $0.id == id }) }
        guard let surface, surface.id == id, accepts(surface) else { return nil }
        return surface
    }
    private func accepts(_ surface: BrowserExtensionSurface) -> Bool {
        guard let web = surface.webView else { return true }
        return web.configuration.webExtensionController === controller && web.configuration.websiteDataStore === dataStore
    }
    /// One borrowed snapshot per enumeration, discarded before returning to WebKit.
    /// Keep reconciled ordering, but read membership and ownership from the live host.
    func currentSurfaces() -> [BrowserExtensionSurface] {
        var live: [UUID: BrowserExtensionSurface] = [:]
        var seen = Set<UUID>()
        for surface in owner?.surfaces?(profileID) ?? [] where seen.insert(surface.id).inserted {
            if accepts(surface) { live[surface.id] = surface }
        }
        return orderedIDs.compactMap { live[$0] }
    }
    func authorizes(_ tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) -> Bool {
        guard owns(context) else { return false }
        guard let tab else { return true }
        guard let tab = tab as? BrowserExtensionTab, tab.runtime === self else { return false }
        return currentSurface(tab.id) != nil
    }
    func windowKey(_ surface: BrowserExtensionSurface) -> ObjectIdentifier { surface.window.map(ObjectIdentifier.init) ?? ObjectIdentifier(self) }
    func reconcile() {
        guard let owner else { return }
        // A misrouted live view is rejected even if the caller supplies a wrong list.
        let supplied = (owner.surfaces?(profileID) ?? []).filter { $0.webView == nil || $0.webView?.configuration.webExtensionController === controller }
        var fresh: [UUID: BrowserExtensionSurface] = [:], ids: [UUID] = []
        for item in supplied where fresh[item.id] == nil { fresh[item.id] = item; ids.append(item.id) }
        let old = snapshots, previousWindowKeys = Set(windows.keys)
        for id in orderedIDs where fresh[id] == nil { if let tab = tabs[id] { controller.didCloseTab(tab) }; tabs.removeValue(forKey: id) }
        snapshots = fresh; orderedIDs = ids
        let neededWindows = Set(supplied.map(windowKey))
        for key in Array(windows.keys) where !neededWindows.contains(key) { if let window = windows.removeValue(forKey: key) { controller.didCloseWindow(window) } }
        for item in supplied {
            let key = windowKey(item)
            if windows[key] == nil { let window = BrowserExtensionWindow(runtime: self, key: key, native: item.window); windows[key] = window; controller.didOpenWindow(window) }
            if tabs[item.id] == nil { let tab = BrowserExtensionTab(runtime: self, id: item.id); tabs[item.id] = tab; controller.didOpenTab(tab) }
            else if let previous = old[item.id], let tab = tabs[item.id] {
                var properties: WKWebExtension.TabChangedProperties = []
                if previous.title != item.title { properties.insert(.title) }
                if previous.url != item.url || previous.webView !== item.webView { properties.insert(.URL); properties.insert(.loading) }
                if previous.isPinned != item.isPinned { properties.insert(.pinned) }
                if !properties.isEmpty { controller.didChangeTabProperties(properties, for: tab) }
            }
        }
        reportedActiveTabs = reportedActiveTabs.filter { windows[$0.key] != nil }
        let activeMembers = Dictionary(grouping: currentSurfaces(), by: windowKey)
        for (key, window) in windows {
            let previous = reportedActiveTabs[key], active = window.activeID(in: activeMembers[key] ?? [])
            if active != previous, let active, let tab = tabs[active] {
                controller.didActivateTab(tab, previousActiveTab: previous.flatMap { tabs[$0] })
            }
            reportedActiveTabs[key] = active
        }
        let selected = ids.filter { fresh[$0]?.isSelected == true && old[$0]?.isSelected != true }.compactMap { tabs[$0] }
        let deselected = ids.filter { fresh[$0]?.isSelected != true && old[$0]?.isSelected == true }.compactMap { tabs[$0] }
        if !selected.isEmpty { controller.didSelectTabs(selected) }
        if !deselected.isEmpty { controller.didDeselectTabs(deselected) }
        let focused = focusedWindow(), focusedID = focused.map(ObjectIdentifier.init)
        // didOpenWindow implicitly focuses the virtual window in WebKit. Restore
        // actual focus after topology changes, including an unfocused profile.
        if focusedID != lastFocusedWindow || previousWindowKeys != Set(windows.keys) { lastFocusedWindow = focusedID; controller.didFocusWindow(focused) }
    }
    func focusedWindow() -> BrowserExtensionWindow? { focusedWindow(in: currentSurfaces()) }
    private func focusedWindow(in surfaces: [BrowserExtensionSurface]) -> BrowserExtensionWindow? {
        let activeWindows = Set(surfaces.filter(\.isActive).map(windowKey))
        return windows.values.first { $0.native?.isKeyWindow == true && activeWindows.contains($0.key) }
    }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard owns(context) else { return [] }
        let surfaces = currentSurfaces()
        var seen = Set<ObjectIdentifier>()
        let ordered = surfaces.map(windowKey).filter { seen.insert($0).inserted }.compactMap { windows[$0] }
        if let focused = focusedWindow(in: surfaces) { return [focused] + ordered.filter { $0 !== focused } }
        return ordered
    }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owns(context) ? focusedWindow() : nil }
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard owns(context), let url = configuration.url, (["http", "https"].contains(url.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url, ownedBy: context)),
              !configuration.shouldBePinned, !configuration.shouldBeMuted, !configuration.shouldReaderModeBeActive,
              let id = owner?.createTab?(url, profileID, configuration.shouldBeActive) else {
            completionHandler(nil, BrowserExtensions.failure("Bam can open ordinary HTTP/HTTPS pages or this extension’s own pages in this profile only.")); return
        }
        reconcile(); guard let tab = tabs[id] else { completionHandler(nil, BrowserExtensions.failure("The new tab is not in this extension’s profile.")); return }
        completionHandler(tab, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        guard authorizes(tab, for: context), let owner else { completionHandler([], nil); return }
        let requested = Set(permissions.map(\.rawValue)), supported = requested.intersection(BrowserExtensions.supportedPermissions)
        let review = BrowserExtensionPermissionReview(name: context.webExtension.displayName ?? "Extension", profileName: owner.profileName?(profileID) ?? "Current profile", permissions: supported.sorted(), websites: [], unsupported: requested.subtracting(supported).sorted(), isOptional: true)
        let granted = !supported.isEmpty && owner.approve(review) ? Set(supported.map { WKWebExtension.Permission(rawValue: $0) }) : []
        guard authorizes(tab, for: context) else { completionHandler([], nil); return }
        for permission in permissions { context.setPermissionStatus(granted.contains(permission) ? .grantedExplicitly : .deniedExplicitly, for: permission) }
        owner.persistPermissions(context); completionHandler(granted, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        guard authorizes(tab, for: context), let owner else { completionHandler([], nil); return }
        let eligible = Set(urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") })
        let review = BrowserExtensionPermissionReview(name: context.webExtension.displayName ?? "Extension", profileName: owner.profileName?(profileID) ?? "Current profile", permissions: [], websites: eligible.map { $0.absoluteString }.sorted(), unsupported: [], isOptional: true)
        let granted = !eligible.isEmpty && owner.approve(review) ? eligible : []
        guard authorizes(tab, for: context) else { completionHandler([], nil); return }
        for url in urls { context.setPermissionStatus(granted.contains(url) ? .grantedExplicitly : .deniedExplicitly, for: url) }
        owner.persistPermissions(context); completionHandler(granted, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        guard authorizes(tab, for: context), let owner else { completionHandler([], nil); return }
        let review = BrowserExtensionPermissionReview(name: context.webExtension.displayName ?? "Extension", profileName: owner.profileName?(profileID) ?? "Current profile", permissions: [], websites: patterns.map(\.string).sorted(), unsupported: [], isOptional: true)
        let granted = !patterns.isEmpty && owner.approve(review) ? patterns : []
        guard authorizes(tab, for: context) else { completionHandler([], nil); return }
        for pattern in patterns { context.setPermissionStatus(granted.contains(pattern) ? .grantedExplicitly : .deniedExplicitly, for: pattern) }
        owner.persistPermissions(context); completionHandler(granted, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard authorizes(action.associatedTab, for: context), let popup = action.popupPopover,
              let anchor = popupAnchor ?? (action.associatedTab as? BrowserExtensionTab)?.surface?.window?.contentView,
              anchor.window?.isVisible == true else { completionHandler(BrowserExtensions.failure("Open a page in this profile to show its extension popup.")); return }
        activePopup?.closePopup(); activePopup = action
        popup.show(relativeTo: NSRect(x: max(0, anchor.bounds.maxX - 28), y: anchor.isFlipped ? 0 : anchor.bounds.maxY - 28, width: 28, height: 28), of: anchor, preferredEdge: .minY)
        completionHandler(nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) { if owns(context) { owner?.changed() } }
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for context: WKWebExtensionContext, replyHandler: @escaping (Any?, Error?) -> Void) {
        replyHandler(nil, BrowserExtensions.failure("Native messaging is not supported by Bam."))
    }
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(BrowserExtensions.failure("Native messaging is not supported by Bam."))
    }
    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard owns(context), let url = context.optionsPageURL, BrowserExtensions.isExtensionURL(url, ownedBy: context),
              owner?.createTab?(url, profileID, true) != nil else { completionHandler(BrowserExtensions.failure("This extension’s options page could not be opened.")); return }
        reconcile(); completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor final class BrowserExtensionTab: NSObject, WKWebExtensionTab {
    weak var runtime: BrowserExtensionRuntime?
    let id: UUID
    init(runtime: BrowserExtensionRuntime, id: UUID) { self.runtime = runtime; self.id = id }
    var surface: BrowserExtensionSurface? { runtime?.currentSurface(id) }
    private func valid(_ context: WKWebExtensionContext) -> Bool { runtime?.owns(context) == true && surface != nil }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { guard valid(context), let runtime, let surface else { return nil }; return runtime.windows[runtime.windowKey(surface)] }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { guard valid(context), let window = window(for: context) as? BrowserExtensionWindow else { return NSNotFound }; return window.tabIDs.firstIndex(of: id) ?? NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { guard valid(context), let web = surface?.webView, web.configuration.webExtensionController === context.webExtensionController else { return nil }; return web }
    func title(for context: WKWebExtensionContext) -> String? { valid(context) ? surface?.title : nil }
    func url(for context: WKWebExtensionContext) -> URL? { guard valid(context), let url = surface?.url, (["http", "https"].contains(url.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url, ownedBy: context)) else { return nil }; return url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { valid(context) && surface?.isPinned == true }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        valid(context) && (surface?.isSelected == true || (window(for: context) as? BrowserExtensionWindow)?.activeID == id)
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { webView(for: context)?.isLoading != true }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { url(for: context) != nil }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(valid(context) && runtime?.owner?.selectTab?(id) == true ? nil : BrowserExtensions.failure("This tab cannot be activated.")) }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(valid(context) && runtime?.owner?.closeTab?(id) == true ? nil : BrowserExtensions.failure("This tab cannot be closed.")) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard valid(context), (["http", "https"].contains(url.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url, ownedBy: context)), runtime?.owner?.navigateTab?(id, url) == true else { completionHandler(BrowserExtensions.failure("Only HTTP/HTTPS or this extension’s own pages in this profile are supported.")); return }; completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(valid(context) && runtime?.owner?.reloadTab?(id, fromOrigin) == true ? nil : BrowserExtensions.failure("This page cannot be reloaded.")) }
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(BrowserExtensions.failure("Extensions cannot change saved tabs in Bam.")) }
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(BrowserExtensions.failure("Extension multi-selection is not supported.")) }
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(BrowserExtensions.failure("Extension mute controls are not supported.")) }
    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(BrowserExtensions.failure("Reader mode is not supported.")) }
}

@available(macOS 15.4, *)
@MainActor final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var runtime: BrowserExtensionRuntime?
    let key: ObjectIdentifier
    weak var native: NSWindow?
    private var rememberedActiveID: UUID?
    init(runtime: BrowserExtensionRuntime, key: ObjectIdentifier, native: NSWindow?) { self.runtime = runtime; self.key = key; self.native = native }
    private var members: [BrowserExtensionSurface] {
        guard let runtime else { return [] }
        return runtime.currentSurfaces().filter { runtime.windowKey($0) == key }
    }
    var tabIDs: [UUID] { members.map(\.id) }
    /// Each profile exposes a virtual window, even while another profile is visible.
    /// WebKit requires every nonempty window to contain its active tab. Preserve
    /// that profile's selection independently from physical window focus.
    var activeID: UUID? { activeID(in: members) }
    func activeID(in members: [BrowserExtensionSurface]) -> UUID? {
        if let visible = members.first(where: \.isActive) { rememberedActiveID = visible.id }
        else if rememberedActiveID.map({ id in members.contains { $0.id == id } }) != true { rememberedActiveID = members.first?.id }
        return rememberedActiveID
    }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { guard runtime?.owns(context) == true else { return [] }; return tabIDs.compactMap { runtime?.tabs[$0] } }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { guard runtime?.owns(context) == true else { return nil }; return activeID.flatMap { runtime?.tabs[$0] } }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { runtime?.owner?.isPrivate == true }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { native?.isMiniaturized == true ? .minimized : .normal }
    func frame(for context: WKWebExtensionContext) -> CGRect { native?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { native?.screen?.frame ?? .null }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard runtime?.owns(context) == true, !tabIDs.isEmpty, let native else { completionHandler(BrowserExtensions.failure("This profile has no open window.")); return }
        native.makeKeyAndOrderFront(nil); completionHandler(nil)
    }
}
