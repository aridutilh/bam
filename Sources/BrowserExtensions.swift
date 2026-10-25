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
    /// Live loading state, so `tabs.onUpdated` reports `status: "complete"` when a page finishes.
    var isLoading: Bool = false
    /// The loading flag changed since the last list, even if it is back where it was.
    var loadingChanged: Bool = false
    /// A Little Bam window: one page, no tabs. Its window is reported to extensions as `popup`.
    var isSinglePage: Bool = false
    /// A Peek shown in the browser window after its tabs. New tabs land before Peeks.
    var isPeek: Bool = false
}

struct BrowserExtensionRecord: Codable, Identifiable {
    let id: UUID
    let profileID: UUID
    var name: String
    var version: String
    var packageName: String
    var enabled: Bool = false
    var permissions: [String: Date] = [:]
    /// The effective host grants, written only by the site-access apply step (a cache of the choice below, never read
    /// back as authority).
    var patterns: [String: Date] = [:]
    /// The site-access choice (`ExtensionSiteAccess.State` in its own JSON shape). Plain Data so the record decodes on
    /// every supported system; nil before site access existed (migrated once at load). Unreadable data refuses the load.
    var siteAccess: Data? = nil
    /// Host grants WebKit holds with a finite expiry, by provenance: part of the user's site choice (requested), or
    /// from the extension's optional requests. Honored until they lapse; never extended or re-dated.
    /// A new install whose first review hasn't been approved yet (canceled, or still open). Its first approval, at
    /// install or on a later Enable, grants every requested site. Cleared by that approval or by Revoke Permissions.
    /// nil for every older record: those keep their stored or migrated choice (a fully revoked one stays revoked).
    var awaitingFirstReview: Bool? = nil
    var timedSiteGrants: [String: Date]? = nil
    var timedOptionalSiteGrants: [String: Date]? = nil
    var deniedPermissions: [String: Date] = [:]
    var deniedPatterns: [String: Date] = [:]
    var compatibilityNote: String? = nil
    /// Requested permissions Bam's compatibility layer stands in for; nil before 0.17.
    var compatibility: [String]? = nil
    /// Reviewed Bam-provided permissions, tracked separately from WebKit's APIs.
    var compatibilityGrants: [String: Date]? = nil
    /// Where the package came from and how it was verified; nil for folder imports.
    var catalog: ExtensionCatalogRecord? = nil
    /// Signed Safari WebExtension provenance; its private .appex remains unmodified.
    var safariBundle: SafariExtensionBundle? = nil
    /// Separately reviewed desktop host, scoped by this record's extension/profile.
    var nativeHost: ExtensionNativeMessaging.Host? = nil
    /// Static declarativeNetRequest disclosure for `version`; replaced (never appended) when re-audited.
    var staticRuleAudit: ExtensionStaticRuleAudit? = nil
    /// The value WebKit exposes as `runtime.id` and uses to address the extension. Chosen once at install: the
    /// CRX3-verified Chrome Web Store ID for a store install whose publisher key derives that listing ID; nil for
    /// everything else (folders, direct packages, unverified CRXs, Safari bundles, installs from before this field),
    /// which keep the installation UUID. Never changed afterwards: WebKit keys extension storage by it.
    var runtimeIdentifier: String? = nil
    /// The context's unique identifier (`runtime.id`). The context's base URL always keeps the installation UUID host,
    /// so extension resource URLs cannot be used by websites to recognize installed extensions.
    var contextIdentifier: String { runtimeIdentifier ?? id.uuidString.lowercased() }
    /// Everything Bam discloses about this install: the current static-rule audit first (it can change what the
    /// extension does), then preparation notes.
    var disclosedNote: String? {
        let notes = [staticRuleAudit?.note, compatibilityNote].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// Lightweight native action state for visible chrome. Reading it never opens a popup.
@MainActor struct BrowserExtensionActionItem {
    let id: UUID
    let name: String
    let label: String
    let icon: NSImage?
    let badge: String
    let isEnabled: Bool
}

struct BrowserExtensionUpdateCancelled: LocalizedError {
    let name: String
    var errorDescription: String? { "Update canceled. \(name) was left unchanged." }
}

struct BrowserExtensionPermissionReview {
    let name: String
    let profileName: String
    let permissions: [String]
    let websites: [String]
    let unsupported: [String]
    let isOptional: Bool
    var compatibilityNote: String? = nil
    /// Permissions provided by Bam's limited compatibility layer rather than WebKit.
    var bridged: [String] = []
    var nativeCompanionAvailable = false
}

@available(macOS 15.4, *)
@MainActor final class BrowserExtensions: NSObject {
    /// Test seam for the tab metadata regressions: called with "issued" after a token is issued and "answering" after
    /// it is redeemed, before the runtime answers. nil in production.
    static var metadataTestHook: ((String) -> Void)?
    var surfaces: ((UUID) -> [BrowserExtensionSurface])?
    /// Optional live lookup; a nil result is authoritative, never a cache miss.
    var surface: ((UUID, UUID) -> BrowserExtensionSurface?)?
    /// A synchronous host revision for topology only. Nil opts into live reads.
    /// The host must advance it before any membership, ordering, or selection
    /// change. Per-tab authorization always uses the independent live resolver.
    var surfaceRevision: ((UUID) -> UInt64?)?
    var profileName: ((UUID) -> String)?
    var selectTab: ((UUID) -> Bool)?
    var closeTab: ((UUID) -> Bool)?
    var navigateTab: ((UUID, URL) -> Bool)?
    var reloadTab: ((UUID, Bool) -> Bool)?
    var createTab: ((URL, UUID, Bool) -> UUID?)?
    /// True only while `createTab` runs for a pinned `tabs.create`: the browser then creates the tab kept in the
    /// same step, before anything can publish it as ordinary. A pinned request travels through the same
    /// `createTab` hook, so whatever wraps or gates that hook (a fixture's allowed addresses) still applies.
    private(set) var createsKeptTab = false
    /// Like `createsKeptTab`: set only while `createTab` runs for `tabs.create` with an index before the end.
    /// The browser places the new tab immediately before this tab, in the same step it is added.
    private(set) var createsTabBefore: UUID?
    /// True for a host whose `createTab` honors `createsTabBefore`. Others refuse insertion before creating anything.
    var placesTabsBeforeAnchor = false
    func createTab(_ url: URL, profileID: UUID, active: Bool, kept: Bool, before anchor: UUID? = nil) -> UUID? {
        createsKeptTab = kept; createsTabBefore = anchor
        defer { createsKeptTab = false; createsTabBefore = nil }
        return createTab?(url, profileID, active)
    }
    /// `tabs.update({pinned})` for one tab of a profile (tab, profile, pinned): nil when the tab now has the
    /// requested state, otherwise the reason Bam refused. See ExtensionPinnedPolicy.
    var setTabPinned: ((UUID, UUID, Bool) -> String?)?
    /// Opens a separate window (Little Bam) in the profile; returns its native window.
    var createWindow: ((URL?, UUID, Bool) -> NSWindow?)?
    /// Saved items of one login profile for bookmarks.getTree (see ExtensionBookmarkTree's input contract).
    /// Called on the main actor only for a granted, registered context of that profile's own runtime.
    var bookmarkSnapshot: ((UUID) -> ExtensionBookmarkTree.Input?)?
    /// One login profile's in-memory history visits, newest first (see ExtensionHistory's hook contract).
    var historySnapshot: ((UUID) -> [ExtensionHistory.Visit]?)?
    /// The integration reports a genuine change in a profile's library; only that profile's extensions hear it.
    func historyChanged(profileID: UUID, change: ExtensionHistory.Change) {
        guard !isPrivate, let runtime = runtimes[profileID] else { return }
        runtime.compatibility.dispatchHistory(change)
    }
    /// Closes a window an extension created; the main browser window refuses.
    var closeWindow: ((NSWindow) -> Bool)?
    /// Starts a download requested by an extension document through Bam's downloads.
    var startDownload: ((WKWebView, URL, String) -> Bool)?
    var onChange: (() -> Void)?
    /// Informs the browser that already loaded pages need a user-requested reload.
    var onReloadNeeded: ((UUID) -> Void)?
    /// Tests supply an explicit decision; production defaults to native review.
    var permissionPrompt: ((BrowserExtensionPermissionReview) -> Bool)?
    /// Native parser dependency; tests can hold its completion across an explicit
    /// user mutation without assuming WebKit's async initializer suspends.
    var packageParser: @MainActor (URL) async throws -> WKWebExtension = { try await WKWebExtension(resourceBaseURL: $0) }
    var safariImporter = SafariExtensionImport()
    var nativeMessagingPolicy = ExtensionNativeMessaging()
    var nativeHostPrompt: ((BrowserExtensionRecord, ExtensionNativeMessaging.Host) -> Bool)?
    /// Fixtures turn this off to run an older prepared worker adapter before upgrading it.
    var refreshesWorkerAdapters = true
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
    private var updating = Set<UUID>()
    private var mutationRevisions: [UUID: UInt64] = [:]
    private var permissionRevisions: [UUID: UInt64] = [:]
    private var manager: ExtensionManagement?
    private var stopped = false

    /// Refusal when an extension's compatibility transport is closed (for example after Revoke Permissions).
    static let compatibilityTransportUnavailable = "This native application is not available in Bam."
    static let supportedPermissions: Set<String> = ["activeTab", "alarms", "clipboardWrite", "contextMenus", "menus", "cookies", "declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]
    // windows.create/update/remove are implemented through Little Bam windows since 0.17.
    // notifications/downloads/management are absent from WebKit; Bam's compatibility
    // layer defines them in extension pages when the manifest requests them.
    static let unsupportedAPIs: Set<String> = ["browser.runtime.sendNativeMessage", "browser.runtime.connectNative", "browser.tabs.move", "browser.tabs.duplicate", "browser.tabs.highlight", "browser.tabs.discard", "browser.bookmarks", "browser.history", "browser.identity", "browser.sessions"]
    nonisolated static var browserVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Where each profile's extension controller keeps extension data (extension storage and
    /// WebKit's per-extension state). Private-data access never depends on this; it follows `isPrivate`.
    enum ControllerStorage: Sendable, Equatable {
        /// Existing behavior: non-persistent for a private host; otherwise the profile's persistent
        /// identifier when one exists, else WebKit's default configuration.
        case automatic
        /// Always non-persistent, even for a non-private host whose pages use a persistent website
        /// store. For disposable normal-profile probes: WebKit offers no public removal for a
        /// persistent controller configuration, so it must not be created for throwaway runs.
        case nonPersistent
    }
    let controllerStorage: ControllerStorage
    nonisolated static func usesNonPersistentController(isPrivate: Bool, storage: ControllerStorage) -> Bool {
        isPrivate || storage == .nonPersistent
    }

    init(storageURL: URL?, isPrivate: Bool = false, controllerStorage: ControllerStorage = .automatic) {
        self.isPrivate = isPrivate
        self.controllerStorage = controllerStorage
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
    /// Verified store/link installs and updates; created on first use so the
    /// network stack stays idle for folder-only users.
    private(set) lazy var installer = ExtensionInstaller(host: self)
    private var library: ExtensionLibraryPanel?
    func showLibrary(profileID: UUID, relativeTo window: NSWindow?) {
        if library == nil { library = ExtensionLibraryPanel(host: self, installer: installer) }
        library?.show(profileID: profileID, relativeTo: window)
    }
    func actionItems(profileID: UUID, tabID: UUID?) -> [BrowserExtensionActionItem] {
        guard let runtime = runtimes[profileID] else { return [] }
        if let tabID, runtime.currentSurface(tabID) == nil { return [] }
        let tab = tabID.flatMap { runtime.tabs[$0] }
        return items(profileID: profileID).compactMap { record in
            guard record.enabled, let context = runtime.contexts[record.id], let action = context.action(for: tab) else { return nil }
            return BrowserExtensionActionItem(id: record.id, name: record.name, label: action.label,
                icon: action.icon(for: NSSize(width: 24, height: 24)), badge: action.badgeText, isEnabled: action.isEnabled)
        }
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
        if let tabID {
            guard runtime.tabs[tabID] != nil, let surface = runtime.currentSurface(tabID), surface.isActive,
                  anchor == nil || anchor?.window === surface.window else { return }
        }
        let tab = tabID.flatMap { runtime.tabs[$0] }
        guard context.action(for: tab)?.isEnabled == true else { return }
        runtime.popupAnchor = anchor; runtime.popupTabID = tabID; runtime.popupContextID = context.uniqueIdentifier
        context.performAction(for: tab)
    }

    /// Copies only the explicitly selected package, then reviews capabilities before loading.
    /// The verified Chrome Web Store ID for `runtime.id`, or nil. Only a store install whose CRX3 publisher signature
    /// verified and whose derived ID is exactly the listing's ID qualifies; never a user- or package-chosen value.
    nonisolated static func verifiedRuntimeIdentifier(for catalog: ExtensionCatalogRecord?) -> String? {
        guard let catalog, catalog.source == .chromeWebStore, let verified = catalog.verifiedChromeExtensionID, verified == catalog.upstreamID,
              verified.count == 32, verified.unicodeScalars.allSatisfy({ ("a"..."p").contains(Character($0)) }) else { return nil }
        return verified
    }
    /// The record an extension context belongs to: its base URL host is always the installation UUID.
    nonisolated static func recordID(of context: WKWebExtensionContext) -> UUID? { context.baseURL.host.flatMap { UUID(uuidString: $0) } }

    @discardableResult func importPackage(at source: URL, profileID: UUID, catalog: ExtensionCatalogRecord? = nil) async throws -> UUID {
        try Task.checkCancellation()
        guard runtimes[profileID] != nil else { throw Self.failure("Open this profile before installing an extension.") }
        let runtimeIdentifier = Self.verifiedRuntimeIdentifier(for: catalog)
        // One context per identifier in a profile's controller: a second install of the same store extension is refused.
        if let runtimeIdentifier, records.contains(where: { $0.profileID == profileID && $0.contextIdentifier == runtimeIdentifier }) {
            throw Self.failure("This extension is already installed in this profile.")
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw Self.failure("Choose an unpacked extension folder containing manifest.json. Use Add from Store or Link for archives, CRX files and store listings.")
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
            let compatibilityNote = try Self.preparePackage(package, originalManifestURL: folder.appendingPathComponent("original-manifest.json"))
            let ext = try await packageParser(package)
            try Task.checkCancellation()
            guard ext.errors.isEmpty else { throw Self.failure(ext.errors.map(\.localizedDescription).joined(separator: "\n")) }
            guard !stopped else { throw Self.failure("The browser is closing.") }
            guard runtimeIdentifier == nil || !records.contains(where: { $0.profileID == profileID && $0.contextIdentifier == runtimeIdentifier }) else {
                throw Self.failure("This extension is already installed in this profile.")
            }
            var record = BrowserExtensionRecord(id: id, profileID: profileID, name: ext.displayName ?? "Unnamed extension", version: ext.version ?? "", packageName: name, compatibilityNote: compatibilityNote, catalog: catalog)
            record.runtimeIdentifier = runtimeIdentifier
            record.awaitingFirstReview = true
            records.append(record)
            try persist()
            do { try await load(id, review: true, parsed: ext) }
            catch is CancellationError { throw CancellationError() }
            catch { setError(error, for: id) }
            changed()
            return id
        } catch {
            records.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: folder)
            try? persist()
            throw error
        }
    }

    /// Disclosed adaptations of the private copy. Original extension scripts stay byte-identical.
    static func preparePackage(_ package: URL, originalManifestURL: URL) throws -> String? {
        var notes = [try ExtensionPackagePreparation.prepare(package: package, originalManifestURL: originalManifestURL),
                     try ExtensionContentScriptPreparation.prepare(package: package, originalManifestURL: originalManifestURL)].compactMap { $0 }
        let manifest = try manifestForPreparation(package)
        if let note = try ExtensionServiceWorkerPreparation.prepare(package: package, originalManifestURL: originalManifestURL,
            adapterSource: ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: browserVersion)) { notes.append(note) }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
    private static func manifestForPreparation(_ package: URL) throws -> [String: Any] {
        let url = package.appendingPathComponent("manifest.json")
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw failure("The extension manifest must be a regular file.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: ExtensionPackagePreparation.maximumManifestBytes + 1) ?? Data()
        guard data.count <= ExtensionPackagePreparation.maximumManifestBytes,
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid or oversized extension manifest.") }
        return manifest
    }

    /// Import the signed WebExtension in an installed Safari app, without copying
    /// its accounts or changing the app/extension signature.
    @discardableResult func importSafariBundle(_ bundle: SafariExtensionBundle, profileID: UUID, catalog: ExtensionCatalogRecord? = nil) async throws -> UUID {
        try Task.checkCancellation()
        guard runtimes[profileID] != nil else { throw Self.failure("Open this profile before installing an extension.") }
        let id = UUID(), folder = storageURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let package = folder.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        do {
            let snapshot = try safariImporter.snapshot(bundle, to: package.appendingPathComponent("Extension.appex", isDirectory: true))
            guard let appExtension = Bundle(url: snapshot) else { throw Self.failure("The Safari extension bundle could not be opened.") }
            let ext = try await WKWebExtension(appExtensionBundle: appExtension)
            try Task.checkCancellation()
            guard ext.errors.isEmpty, !stopped else { throw Self.failure(ext.errors.map(\.localizedDescription).joined(separator: "\n")) }
            let note = "Imported the signed Safari WebExtension without modifying its bundle. The containing app must remain installed; add it again after the app updates. Native companion-app features are unavailable in Bam. No Safari account data is imported."
            var record = BrowserExtensionRecord(id: id, profileID: profileID, name: ext.displayName ?? bundle.displayName,
                version: ext.version ?? bundle.version, packageName: "package", compatibilityNote: note, catalog: catalog, safariBundle: bundle)
            record.awaitingFirstReview = true
            records.append(record)
            try persist()
            do { try await load(id, review: true, parsed: ext) }
            catch is CancellationError { throw CancellationError() }
            catch { setError(error, for: id) }
            changed(); return id
        } catch {
            records.removeAll { $0.id == id }; try? FileManager.default.removeItem(at: folder); try? persist(); throw error
        }
    }

    func noteUpdateCheck(id: UUID, available: String?) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].catalog != nil else { return }
        records[i].catalog?.lastUpdateCheck = Date(); records[i].catalog?.availableVersion = available
        try? persist(); changed()
    }

    /// Swaps the private package in place so the extension keeps its identifier,
    /// WebKit storage, grants and profile. The previous package is restored on failure.
    func replacePackage(id: UUID, with source: URL, catalog: ExtensionCatalogRecord, safariBundle: SafariExtensionBundle? = nil) async throws {
        guard let before = records.first(where: { $0.id == id }), let runtime = runtimes[before.profileID],
              !loading.contains(id), !updating.contains(id) else { throw Self.failure("This extension is not ready to update.") }
        guard (before.safariBundle == nil) == (safariBundle == nil) else { throw Self.failure("An update must use the installed extension's original package type.") }
        updating.insert(id); defer { updating.remove(id) }
        let initialRevision = mutationRevisions[id, default: 0]
        let initialPermissionRevision = permissionRevisions[id, default: 0]
        let oldContext = runtime.contexts[id]
        try Task.checkCancellation()
        if let safariBundle { try safariImporter.validate(safariBundle) } else { try Self.validatePackageSize(source) }
        let folder = storageURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let package = folder.appendingPathComponent(before.packageName)
        let token = UUID().uuidString
        let incoming = folder.appendingPathComponent("package-incoming-" + token)
        let incomingManifest = folder.appendingPathComponent("original-manifest-incoming-" + token + ".json")
        let previous = folder.appendingPathComponent("package-previous-" + token)
        let previousManifest = folder.appendingPathComponent("original-manifest-previous-" + token + ".json")
        let originalManifest = folder.appendingPathComponent("original-manifest.json")
        let incomingWorker = incomingManifest.appendingPathExtension("worker-preparation.json")
        let previousWorker = previousManifest.appendingPathExtension("worker-preparation.json")
        let originalWorker = originalManifest.appendingPathExtension("worker-preparation.json")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: incoming); try? fm.removeItem(at: incomingManifest); try? fm.removeItem(at: incomingWorker) }
        // Prepare and review before touching the running extension. Cancel must
        // preserve its package, loaded context, permissions and signed-in storage.
        let note: String?, ext: WKWebExtension
        if let safariBundle {
            try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
            let snapshot = try safariImporter.snapshot(safariBundle, to: incoming.appendingPathComponent("Extension.appex", isDirectory: true))
            guard let bundle = Bundle(url: snapshot) else { throw Self.failure("The Safari extension bundle could not be opened.") }
            ext = try await WKWebExtension(appExtensionBundle: bundle)
            note = "Updated the signed Safari WebExtension without modifying its bundle. The containing app must remain installed. Native companion-app features are unavailable in Bam."
        } else {
            try fm.copyItem(at: source, to: incoming)
            try Self.validatePackageSize(incoming)
            note = try Self.preparePackage(incoming, originalManifestURL: incomingManifest)
            ext = try await packageParser(incoming)
        }
        try Task.checkCancellation()
        guard !stopped, mutationRevisions[id, default: 0] == initialRevision,
              runtime.contexts[id] === oldContext else { throw BrowserExtensionUpdateCancelled(name: before.name) }
        guard ext.errors.isEmpty else { throw Self.failure(ext.errors.map(\.localizedDescription).joined(separator: "\n")) }
        var replacement = Self.retainingDeclaredPermissions(before, for: ext)
        replacement.name = ext.displayName ?? before.name; replacement.version = ext.version ?? ""
        replacement.compatibilityNote = note; replacement.catalog = catalog
        replacement.safariBundle = safariBundle
        // The new package's own static-rule audit (Safari bundles are not audited); load keeps it while current.
        if safariBundle == nil {
            let package = incoming, version = replacement.version
            replacement.staticRuleAudit = await Task.detached(priority: .utility) { ExtensionStaticRuleAudit.audit(package: package, version: version) }.value
            try Task.checkCancellation()
            guard !stopped, mutationRevisions[id, default: 0] == initialRevision,
                  runtime.contexts[id] === oldContext else { throw BrowserExtensionUpdateCancelled(name: before.name) }
        } else { replacement.staticRuleAudit = nil }
        if !Self.supportsNativeCompanion(replacement) || !ext.requestedPermissions.contains(.init(rawValue: "nativeMessaging")) { replacement.nativeHost = nil }
        // Site access for the new version: the stored choice, narrowed to what it still declares. New requests are
        // pending and are only granted when the update's review approves them; declining cancels the whole update,
        // so the old version keeps its access (a broader replacing declaration could otherwise narrow it).
        let newDeclarations = ExtensionSiteAccess.Declarations(ext)
        var nextSite: ExtensionSiteAccess.State
        var priorTimed = Self.timed(before)
        if let stored = try ExtensionSiteAccessEngine.decode(before.siteAccess) { nextSite = stored }
        else {
            let migrated = ExtensionSiteAccessEngine.migrate(patterns: before.patterns, declarations: oldContext.map { ExtensionSiteAccess.Declarations($0.webExtension) } ?? newDeclarations)
            nextSite = migrated.state; priorTimed = migrated.timed
        }
        nextSite = ExtensionSiteAccess.updated(nextSite, to: newDeclarations)
        let pendingSites = ExtensionSiteAccess.pendingRequests(nextSite, declarations: newDeclarations)
        if before.enabled {
            let requested = Set(ext.requestedPermissions.map(\.rawValue))
            let supported = requested.intersection(Self.supportedPermissions)
            let bridged = ExtensionCompatibility.plan(manifest: ext.manifest).provided.filter { ExtensionCompatibility.bridgedPermissions.contains($0) }
            let patterns = pendingSites
            let review = BrowserExtensionPermissionReview(name: replacement.name, profileName: profileName?(before.profileID) ?? "Current profile",
                permissions: supported.sorted(), websites: patterns, unsupported: requested.subtracting(supported).subtracting(bridged).subtracting(Self.supportsNativeCompanion(replacement) ? ["nativeMessaging"] : []).sorted(),
                isOptional: false, compatibilityNote: replacement.disclosedNote, bridged: bridged,
                nativeCompanionAvailable: Self.supportsNativeCompanion(replacement) && requested.contains("nativeMessaging"))
            guard approve(review) else { throw BrowserExtensionUpdateCancelled(name: before.name) }
            try Task.checkCancellation()
            for permission in supported {
                replacement.permissions[permission] = .distantFuture
                replacement.deniedPermissions.removeValue(forKey: permission)
            }
            replacement.compatibilityGrants = Dictionary(uniqueKeysWithValues: bridged.map { ($0, Date.distantFuture) })
            nextSite = ExtensionSiteAccess.accepting(pendingSites, in: nextSite, declarations: newDeclarations)
            for pattern in pendingSites { replacement.deniedPatterns.removeValue(forKey: pattern) }
        }
        // An install still awaiting its first review keeps waiting: its first approval grants the new version's requests.
        if before.awaitingFirstReview != true {
            let nextTimed = ExtensionSiteAccessEngine.live(priorTimed, declarations: newDeclarations)
            replacement.siteAccess = ExtensionSiteAccessEngine.encode(nextSite)
            Self.store(nextTimed, in: &replacement)
            replacement.patterns = ExtensionSiteAccessEngine.target(nextSite, timed: nextTimed, declarations: newDeclarations)
        }
        // Native permission dialogs run a nested loop. Deletion, disabling and
        // shutdown while reviewing must win over this update.
        guard !stopped, mutationRevisions[id, default: 0] == initialRevision,
              let index = records.firstIndex(where: { $0.id == id && $0.profileID == before.profileID }),
              records[index].enabled == before.enabled, runtime.contexts[id] === oldContext else {
            throw BrowserExtensionUpdateCancelled(name: before.name)
        }
        var unloaded = false, movedPackage = false, movedManifest = false, installedManifest = false
        var movedWorker = false, installedWorker = false
        do {
            if let oldContext {
                runtime.closePopup(for: oldContext); try runtime.controller.unload(oldContext)
                runtime.disconnectNative(oldContext); runtime.compatibility.remove(oldContext); runtime.contexts.removeValue(forKey: id); unloaded = true
            }
            try fm.moveItem(at: package, to: previous); movedPackage = true
            if fm.fileExists(atPath: originalManifest.path) { try fm.moveItem(at: originalManifest, to: previousManifest); movedManifest = true }
            if fm.fileExists(atPath: originalWorker.path) { try fm.moveItem(at: originalWorker, to: previousWorker); movedWorker = true }
            try fm.moveItem(at: incoming, to: package)
            if fm.fileExists(atPath: incomingManifest.path) { try fm.moveItem(at: incomingManifest, to: originalManifest); installedManifest = true }
            if fm.fileExists(atPath: incomingWorker.path) { try fm.moveItem(at: incomingWorker, to: originalWorker); installedWorker = true }
            records[index] = replacement
            try persist()
            if before.enabled {
                // Reparse at the final URL; a context parsed in staging would keep
                // looking for its scripts in the now-moved staging directory.
                try await load(id, review: false)
                try Task.checkCancellation()
                guard !stopped, mutationRevisions[id, default: 0] == initialRevision else { throw BrowserExtensionUpdateCancelled(name: before.name) }
                guard runtime.contexts[id] != nil else { throw Self.failure("The updated extension could not be activated.") }
            }
            try? fm.removeItem(at: previous); try? fm.removeItem(at: previousManifest); try? fm.removeItem(at: previousWorker)
            errors.removeValue(forKey: id)
            if before.enabled { onReloadNeeded?(before.profileID) }
            changed()
        } catch {
            // Never revive an extension the user removed while WebKit was loading.
            guard let currentIndex = records.firstIndex(where: { $0.id == id }) else { throw error }
            let interrupted = stopped || Task.isCancelled || mutationRevisions[id, default: 0] != initialRevision
            var restored = before
            // Explicit permission changes during WebKit's async parse are newer
            // than the update's snapshot and must survive its rollback.
            if permissionRevisions[id, default: 0] != initialPermissionRevision {
                restored.permissions = records[currentIndex].permissions; restored.patterns = records[currentIndex].patterns
                restored.deniedPermissions = records[currentIndex].deniedPermissions; restored.deniedPatterns = records[currentIndex].deniedPatterns
                restored.compatibilityGrants = records[currentIndex].compatibilityGrants
                restored.nativeHost = records[currentIndex].nativeHost
                // The newer site choice and time-limited grants (a revoke, narrowing or prompt during the update)
                // win too, so neither the old package's reload nor a later enable restores older authority.
                restored.siteAccess = records[currentIndex].siteAccess
                restored.timedSiteGrants = records[currentIndex].timedSiteGrants; restored.timedOptionalSiteGrants = records[currentIndex].timedOptionalSiteGrants
                if let oldContext { restored = Self.retainingDeclaredPermissions(restored, for: oldContext.webExtension) }
            }
            // A newer disable/revoke/remove action or shutdown must never be
            // turned into a reload of the old package by an obsolete update.
            if interrupted { restored.enabled = false }
            if let context = runtime.contexts[id], context !== oldContext {
                runtime.closePopup(for: context); try? runtime.controller.unload(context)
                runtime.disconnectNative(context); runtime.compatibility.remove(context); runtime.contexts.removeValue(forKey: id)
            }
            if movedPackage { try? fm.removeItem(at: package); try? fm.moveItem(at: previous, to: package) }
            if installedManifest { try? fm.removeItem(at: originalManifest) }
            if movedManifest { try? fm.moveItem(at: previousManifest, to: originalManifest) }
            if installedWorker { try? fm.removeItem(at: originalWorker) }
            if movedWorker { try? fm.moveItem(at: previousWorker, to: originalWorker) }
            records[currentIndex] = restored
            try? persist()
            if unloaded && restored.enabled && !interrupted {
                do { try await load(id, review: false) }
                catch {
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].enabled = false; try? persist() }
                    setError(error, for: id)
                }
            }
            changed()
            throw error
        }
    }

    /// Keep only unexpired grants/denials the new package still declares. A
    /// narrower previously granted site remains valid under a broad declaration.
    private static func retainingDeclaredPermissions(_ record: BrowserExtensionRecord, for ext: WKWebExtension) -> BrowserExtensionRecord {
        var result = record
        let declared = Set(ext.requestedPermissions.union(ext.optionalPermissions).map(\.rawValue))
        let patterns = ext.allRequestedMatchPatterns.union(ext.optionalPermissionMatchPatterns)
        let now = Date()
        result.permissions = record.permissions.filter { declared.contains($0.key) && supportedPermissions.contains($0.key) && $0.value > now }
        result.deniedPermissions = record.deniedPermissions.filter { declared.contains($0.key) && $0.value > now }
        result.compatibilityGrants = record.compatibilityGrants?.filter { declared.contains($0.key) && $0.value > now }
        func validPatterns(_ values: [String: Date]) -> [String: Date] {
            values.filter { key, expiry in
                guard expiry > now, let retained = try? WKWebExtension.MatchPattern(string: key) else { return false }
                return patterns.contains { $0.matches(retained) }
            }
        }
        result.patterns = validPatterns(record.patterns); result.deniedPatterns = validPatterns(record.deniedPatterns)
        return result
    }
    private func noteMutation(_ id: UUID, permissions: Bool = false) {
        mutationRevisions[id, default: 0] &+= 1
        if permissions { permissionRevisions[id, default: 0] &+= 1 }
    }

    func setEnabled(_ enabled: Bool, id: UUID) async throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        noteMutation(id)
        if enabled { try await load(id, review: true) }
        else {
            loadGeneration.removeValue(forKey: id)
            if let runtime = runtimes[records[i].profileID], let context = runtime.contexts[id] {
                runtime.closePopup(for: context)
                try runtime.controller.unload(context)
                runtime.disconnectNative(context); runtime.compatibility.remove(context)
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
            let matching = data.filter { $0.uniqueIdentifier == record.contextIdentifier }
            await runtime.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: matching)
        }
        records.removeAll { $0.id == id }; errors.removeValue(forKey: id)
        try persist()
        try FileManager.default.removeItem(at: storageURL.appendingPathComponent(record.id.uuidString, isDirectory: true))
        changed()
    }
    // MARK: Site access (engine API for the Manage Extensions panel; see work/chrome-site-access-engine-handoff.md)

    private static func timed(_ record: BrowserExtensionRecord) -> ExtensionSiteAccessEngine.Timed {
        .init(requested: record.timedSiteGrants ?? [:], optional: record.timedOptionalSiteGrants ?? [:])
    }
    private static func store(_ timed: ExtensionSiteAccessEngine.Timed, in record: inout BrowserExtensionRecord) {
        record.timedSiteGrants = timed.requested.isEmpty ? nil : timed.requested
        record.timedOptionalSiteGrants = timed.optional.isEmpty ? nil : timed.optional
    }

    /// The extension's current site access; declarations are nil while it isn't loaded.
    func siteAccess(id: UUID) -> BrowserExtensionSiteAccessSnapshot? {
        guard let record = records.first(where: { $0.id == id }), let state = try? ExtensionSiteAccessEngine.decode(record.siteAccess) ?? .withheld() else { return nil }
        let context = context(for: id)
        let declarations = context.map { ExtensionSiteAccess.Declarations($0.webExtension) }
        let timed = declarations.map { ExtensionSiteAccessEngine.live(Self.timed(record), declarations: $0) } ?? Self.timed(record)
        let granted = Set((context?.grantedPermissions.keys.map(\.rawValue)) ?? record.permissions.filter { $0.value > Date() }.map(\.key))
        return BrowserExtensionSiteAccessSnapshot(id: id, profileID: record.profileID, revision: siteAccessRevision(record, context: context),
                                                  state: state, declarations: declarations, timed: timed,
                                                  effective: record.patterns.filter { $0.value > Date() }.keys.sorted(), oneTimeAccess: ExtensionSiteAccess.providesOneTimeAccess(grantedPermissions: granted))
    }
    /// Everything a displayed snapshot (or an open prompt) depends on. An update, reload, revoke, prompt or other
    /// change makes it differ.
    private func siteAccessRevision(_ record: BrowserExtensionRecord, context: WKWebExtensionContext?) -> BrowserExtensionSiteAccessSnapshot.Revision {
        .init(stored: record.siteAccess, timed: Self.timed(record), patterns: record.patterns, version: record.version, enabled: record.enabled,
              context: context.map { ObjectIdentifier($0).hashValue }, declarations: context.map { ExtensionSiteAccess.Declarations($0.webExtension) })
    }

    /// Applies one panel action and returns the authoritative snapshot. The action must name the extension, profile
    /// and revision of the snapshot the user saw: if anything changed since (an update with new hosts, a reload, a
    /// prompt), it is refused as `.stale` and nothing is approved. Nothing changes on any failure, including a failed
    /// save (the live extension and the record both stay as they were).
    /// `displayed` is what the panel showed when the user acted; it must equal the live declarations.
    @discardableResult func performSiteAccess(id: UUID, profileID: UUID, revision: BrowserExtensionSiteAccessSnapshot.Revision,
                                              displayed: ExtensionSiteAccess.Declarations,
                                              change: BrowserExtensionSiteAccessChange) throws -> BrowserExtensionSiteAccessSnapshot {
        guard !stopped, let index = records.firstIndex(where: { $0.id == id }), records[index].profileID == profileID else { throw BrowserExtensionSiteAccessFailure.failed("This extension is no longer installed in this profile.") }
        guard !loading.contains(id), !updating.contains(id) else { throw BrowserExtensionSiteAccessFailure.stale }
        guard let context = context(for: id) else { throw BrowserExtensionSiteAccessFailure.failed("Enable the extension to change its site access.") }
        let declarations = ExtensionSiteAccess.Declarations(context.webExtension)
        guard siteAccessRevision(records[index], context: context) == revision, declarations == displayed else { throw BrowserExtensionSiteAccessFailure.stale }
        let state: ExtensionSiteAccess.State
        do { state = try ExtensionSiteAccessEngine.decode(records[index].siteAccess) ?? .withheld() }
        catch { throw BrowserExtensionSiteAccessFailure.failed(error.localizedDescription) }
        var next = state
        switch change {
        case .choose(.withheld): next = .withheld(optionalGrants: state.optionalGrants)
        // Approves exactly what the user saw (equal to the live declarations, checked above).
        case .choose(.allRequested): next = .allRequested(approving: displayed, optionalGrants: state.optionalGrants)
        case .choose(.specific): throw BrowserExtensionSiteAccessFailure.failed("Add a site to allow it.")
        case .addSite(let input, let includeSubdomains):
            // From Withheld or All requested, adding a site starts a list with just that site.
            let base: ExtensionSiteAccess.Mode = { if case .specific = state.mode { return state.mode }; return .withheld }()
            switch ExtensionSiteAccess.addSite(input, includeSubdomains: includeSubdomains, to: base, declarations: declarations) {
            case .failure(let refusal): throw BrowserExtensionSiteAccessFailure.refused(refusal)
            case .success(let mode):
                if case .specific(let sites) = mode { next = .specific(sites, optionalGrants: state.optionalGrants) }
            }
        case .removeSite(let site):
            let mode = ExtensionSiteAccess.removeSite(site, from: state.mode)
            if case .specific(let sites) = mode { next = .specific(sites, optionalGrants: state.optionalGrants) } else { next = .withheld(optionalGrants: state.optionalGrants) }
        case .acceptPending(let reviewed):
            next = ExtensionSiteAccess.accepting(reviewed, in: state, declarations: declarations)
        }
        let timed = ExtensionSiteAccessEngine.timed(Self.timed(records[index]), after: change, from: state, to: next)
        try applySiteAccess(index: index, state: next, timed: timed, declarations: declarations, context: context)
        guard let snapshot = siteAccess(id: id) else { throw BrowserExtensionSiteAccessFailure.failed("Site access could not be read back.") }
        return snapshot
    }

    /// A runtime prompt's view of the extension before it asks: how each item would be recorded (by its site; no
    /// site or an unreadable state refuses it) and the revision the answer is bound to.
    func promptDecisions<Item: Hashable>(_ items: [(Item, String?)], for context: WKWebExtensionContext)
        -> (decisions: [Item: ExtensionSiteAccessEngine.Provenance], revision: BrowserExtensionSiteAccessSnapshot.Revision?) {
        let index = ownedRecordIndex(for: context)
        let state = index.flatMap { try? ExtensionSiteAccessEngine.decode(records[$0].siteAccess) ?? .withheld() }
        let declarations = ExtensionSiteAccess.Declarations(context.webExtension)
        var result: [Item: ExtensionSiteAccessEngine.Provenance] = [:]
        for (item, site) in items { result[item] = site.flatMap { site in state.map { ExtensionSiteAccessEngine.promptDecision(site, in: $0, declarations: declarations) } } ?? .refused }
        return (result, state == nil ? nil : index.map { siteAccessRevision(records[$0], context: context) })
    }

    /// Whether a prompt's answer still applies: nothing changed during the dialog (no revoke, mode change, panel
    /// change, update or reload). A stale answer neither grants nor denies anything.
    func promptIsCurrent(_ context: WKWebExtensionContext, revision: BrowserExtensionSiteAccessSnapshot.Revision?) -> Bool {
        guard !stopped, let revision, let index = ownedRecordIndex(for: context), !updating.contains(records[index].id) else { return false }
        return siteAccessRevision(records[index], context: context) == revision
    }

    /// Records a current prompt's approvals with provenance; false (stale, or the choice didn't save) grants nothing.
    func recordSiteApprovals(_ context: WKWebExtensionContext, _ approved: [ExtensionSiteAccessEngine.Provenance], revision: BrowserExtensionSiteAccessSnapshot.Revision?) -> Bool {
        guard promptIsCurrent(context, revision: revision), let index = ownedRecordIndex(for: context) else { return false }
        guard !approved.isEmpty else { return true }
        guard let state = try? ExtensionSiteAccessEngine.decode(records[index].siteAccess) ?? .withheld() else { return false }
        let recorded = ExtensionSiteAccessEngine.recording(approved, in: state, timed: Self.timed(records[index]))
        do { try applySiteAccess(index: index, state: recorded.state, timed: recorded.timed, declarations: .init(context.webExtension), context: context); return true }
        catch { setError(error, for: records[index].id); return false }
    }

    /// The only writer of host grants after load: stores the choice, recomputes the effective grants, applies them to
    /// the live context, persists, and asks for a reload when open pages lost access. A failed save restores the
    /// record and the live context and throws: nothing is reported as saved that a restart would undo.
    private func applySiteAccess(index: Int, state: ExtensionSiteAccess.State, timed: ExtensionSiteAccessEngine.Timed,
                                 declarations: ExtensionSiteAccess.Declarations, context: WKWebExtensionContext?) throws {
        let previous = records[index]
        let previousLive = context.map { ($0.grantedPermissionMatchPatterns, $0.deniedPermissionMatchPatterns) }
        let live = ExtensionSiteAccessEngine.live(timed, declarations: declarations)
        let target = ExtensionSiteAccessEngine.target(state, timed: live, declarations: declarations)
        let lost = Set(previous.patterns.keys).subtracting(target.keys)
        records[index].siteAccess = ExtensionSiteAccessEngine.encode(state)
        Self.store(live, in: &records[index])
        records[index].patterns = target
        for pattern in target.keys { records[index].deniedPatterns.removeValue(forKey: pattern) }
        if let context {
            // Candidate fix (native lifecycle regression: all-host content still injected into fresh documents after a
            // bulk grant replacement). First reset, one by one through the public per-pattern API, every live grant the
            // target no longer includes, so WebKit takes its per-pattern removal path for each; then apply the exact
            // target as before. No denial is added, nothing is widened, and no shared controller script is touched.
            // Order matters: WebKit coalesces all-host injection under the canonical `*://*/*` key, and removing an
            // all-host pattern re-adds content for the all-host grants that remain. So specific patterns go first, then
            // other all-host forms (`<all_urls>`, `https://*/*`, …), and the canonical `*://*/*` strictly last.
            let kept = Set(target.keys)
            let withdrawn = context.grantedPermissionMatchPatterns.keys.filter { !kept.contains($0.string) }
            func removalRank(_ pattern: WKWebExtension.MatchPattern) -> Int {
                if pattern.string == "*://*/*" { return 2 }
                return pattern.matchesAllHosts || pattern.matchesAllURLs ? 1 : 0
            }
            for pattern in withdrawn.sorted(by: { (removalRank($0), $0.string) < (removalRank($1), $1.string) }) {
                context.setPermissionStatus(.unknown, for: pattern)
            }
            context.deniedPermissionMatchPatterns = Self.matchPatterns(records[index].deniedPatterns)
            context.grantedPermissionMatchPatterns = Self.matchPatterns(target)
        }
        do { try persist() } catch {
            records[index] = previous
            if let context, let previousLive { context.deniedPermissionMatchPatterns = previousLive.1; context.grantedPermissionMatchPatterns = previousLive.0 }
            throw BrowserExtensionSiteAccessFailure.failed("Site access couldn't be saved, so nothing changed. \(error.localizedDescription)")
        }
        noteMutation(previous.id, permissions: true)
        if !lost.isEmpty { onReloadNeeded?(previous.profileID) }
        changed()
    }

    func revokePermissions(id: UUID) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        noteMutation(id, permissions: true); loadGeneration.removeValue(forKey: id)
        records[i].permissions = [:]; records[i].patterns = [:]; records[i].compatibilityGrants = [:]; records[i].nativeHost = nil
        // Revoking withholds every site, including optional and time-limited grants.
        records[i].siteAccess = ExtensionSiteAccessEngine.encode(.withheld()); records[i].timedSiteGrants = nil; records[i].timedOptionalSiteGrants = nil
        records[i].awaitingFirstReview = nil   // Revoke also cancels a pending first approval: Enable then reviews no sites.
        if let runtime = runtimes[records[i].profileID], let context = runtime.contexts[id] { runtime.disconnectNative(context); runtime.compatibility.revoke(context) }
        if let context = context(for: id) { context.grantedPermissions = [:]; context.grantedPermissionMatchPatterns = [:] }
        try persist(); onReloadNeeded?(records[i].profileID); changed()
    }

    private func load(_ id: UUID, review: Bool, parsed: WKWebExtension? = nil) async throws {
        try Task.checkCancellation()
        guard !loading.contains(id), let stored = records.first(where: { $0.id == id }), let runtime = runtimes[stored.profileID] else { return }
        var record = stored
        if runtime.contexts[id] != nil { return }
        let token = UUID(); loadGeneration[id] = token
        loading.insert(id); defer { loading.remove(id); if loadGeneration[id] == token { loadGeneration.removeValue(forKey: id) } }
        // Older disabled worker installs gain the adapter only when explicitly
        // re-enabled and reviewed. Do not silently rewrite a running extension.
        if review, parsed == nil, record.safariBundle == nil {
            let package = packageURL(record)
            let manifest = try Self.manifestForPreparation(package)
            if !ExtensionServiceWorkerPreparation.isPrepared(manifest: manifest),
               (manifest["background"] as? [String: Any])?["service_worker"] != nil,
               let note = try ExtensionServiceWorkerPreparation.prepare(package: package,
                    originalManifestURL: package.deletingLastPathComponent().appendingPathComponent("original-manifest.json"),
                    adapterSource: ExtensionCompatibility.workerScript(manifest: manifest, browserVersion: Self.browserVersion)) {
                record.compatibilityNote = [record.compatibilityNote, note].compactMap { $0 }.joined(separator: " ")
                if let index = records.firstIndex(where: { $0.id == id }) { records[index].compatibilityNote = record.compatibilityNote; try persist() }
            }
        }
        // Refresh our own exact adapter bytes before parsing an installed package.
        // This changes no grants or vendor scripts and never touches signed Safari bundles.
        if parsed == nil, record.safariBundle == nil,
           try ExtensionContentScriptPreparation.refreshBamAdapters(package: packageURL(record)) > 0 {
            let note = "Updated Bam's content-script adapter (select-picker state, idle callbacks). Extension scripts are unchanged."
            record.compatibilityNote = [record.compatibilityNote, note].compactMap { $0 }.joined(separator: " ")
            if let index = records.firstIndex(where: { $0.id == id }) { records[index].compatibilityNote = record.compatibilityNote; try persist() }
        }
        // Refresh Bam's own worker adapter (it embeds this Bam's version and API layer) in a
        // package prepared by an earlier Bam, only when every prepared file still verifies.
        // Vendor scripts, the manifest, grants and extension storage are unchanged. A package
        // that does not verify is left exactly as it was and loads as it did before.
        if refreshesWorkerAdapters, parsed == nil, record.safariBundle == nil {
            let package = packageURL(record)
            let refreshed: Bool
            do {
                refreshed = try ExtensionServiceWorkerPreparation.refreshAdapter(package: package,
                    originalManifestURL: package.deletingLastPathComponent().appendingPathComponent("original-manifest.json"),
                    adapterSource: ExtensionCompatibility.workerScript(manifest: Self.manifestForPreparation(package), browserVersion: Self.browserVersion))
            } catch {
                refreshed = false
                // Verification failures write nothing; a failure after the adapter write leaves the
                // new adapter with old metadata, which the next load completes.
                NSLog("Bam could not finish refreshing the worker preparation for extension %@: %@", id.uuidString, error.localizedDescription)
            }
            if refreshed {
                let note = "Updated Bam's service-worker compatibility adapter. Extension scripts are unchanged."
                if record.compatibilityNote?.contains(note) != true {
                    record.compatibilityNote = [record.compatibilityNote, note].compactMap { $0 }.joined(separator: " ")
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].compatibilityNote = record.compatibilityNote; try persist() }
                }
            }
        }
        // Static declarativeNetRequest disclosure: read-only, once per extension version and audit format, off the
        // main actor. New installs, updates (which reset it) and installs from an earlier Bam all pass here.
        if record.safariBundle == nil, record.staticRuleAudit?.isCurrent(for: record.version) != true {
            let package = packageURL(record), version = record.version
            let audit = await Task.detached(priority: .utility) { ExtensionStaticRuleAudit.audit(package: package, version: version) }.value
            try Task.checkCancellation()
            guard !stopped, loadGeneration[id] == token else { return }
            if let index = records.firstIndex(where: { $0.id == id }), records[index].version == version {
                records[index].staticRuleAudit = audit; record.staticRuleAudit = audit; try persist()
            }
        }
        let ext: WKWebExtension
        if let safari = record.safariBundle {
            try safariImporter.validate(safari)
            let snapshot = packageURL(record).appendingPathComponent("Extension.appex", isDirectory: true)
            try safariImporter.validateSnapshot(at: snapshot, original: safari)
            if let parsed { ext = parsed }
            else {
                guard let bundle = Bundle(url: snapshot) else { throw Self.failure("The Safari extension snapshot is missing.") }
                ext = try await WKWebExtension(appExtensionBundle: bundle)
            }
        } else if let parsed { ext = parsed } else { ext = try await packageParser(packageURL(record)) }
        try Task.checkCancellation()
        guard ext.errors.isEmpty else { throw Self.failure(ext.errors.map(\.localizedDescription).joined(separator: "\n")) }
        guard !stopped, loadGeneration[id] == token, let initialIndex = records.firstIndex(where: { $0.id == id }), review || records[initialIndex].enabled else { return }
        var index = initialIndex
        let plan = ExtensionCompatibility.plan(manifest: ext.manifest)
        let bridged = plan.provided.filter { ExtensionCompatibility.bridgedPermissions.contains($0) }
        // Site access: a new install's first review (at install, or on Enable after a canceled install) approves all
        // requested sites; anything else keeps its stored choice, migrating a record from before site access exists
        // once (never widening, never extending an expiry).
        let declarations = ExtensionSiteAccess.Declarations(ext)
        let installing = records[index].awaitingFirstReview == true
        var siteState = try ExtensionSiteAccessEngine.decode(records[index].siteAccess)
        var siteTimed = ExtensionSiteAccessEngine.live(Self.timed(records[index]), declarations: declarations)
        if siteState == nil && !installing {
            let migrated = ExtensionSiteAccessEngine.migrate(patterns: records[index].patterns, declarations: declarations)
            siteState = migrated.state; siteTimed = migrated.timed
        }
        if review {
            let requested = Set(ext.requestedPermissions.map(\.rawValue))
            let supported = requested.intersection(Self.supportedPermissions)
            // An install reviews everything requested; re-enabling reviews only the sites its stored choice grants.
            let patterns = installing ? declarations.requested
                : ExtensionSiteAccessEngine.target(siteState ?? .withheld(), timed: siteTimed, declarations: declarations).keys.sorted()
            let details = BrowserExtensionPermissionReview(name: record.name, profileName: profileName?(record.profileID) ?? "Current profile", permissions: supported.sorted(), websites: patterns,
                unsupported: requested.subtracting(supported).subtracting(bridged).subtracting(Self.supportsNativeCompanion(record) ? ["nativeMessaging"] : []).sorted(), isOptional: false, compatibilityNote: record.disclosedNote, bridged: bridged,
                nativeCompanionAvailable: Self.supportsNativeCompanion(record) && requested.contains("nativeMessaging"))
            guard approve(details) else { changed(); return }
            try Task.checkCancellation()
            // Native review runs a nested loop; deletion, disabling or shutdown wins.
            guard !stopped, loadGeneration[id] == token,
                  let currentIndex = records.firstIndex(where: { $0.id == id && $0.profileID == record.profileID }) else { return }
            index = currentIndex
            records[index].permissions = Dictionary(uniqueKeysWithValues: supported.map { ($0, Date.distantFuture) })
            records[index].deniedPermissions = [:]
            if installing {
                siteState = .allRequested(approving: declarations); siteTimed = .init(); records[index].deniedPatterns = [:]
                records[index].awaitingFirstReview = nil
            }
            records[index].compatibilityGrants = Dictionary(uniqueKeysWithValues: bridged.map { ($0, Date.distantFuture) })
        }
        // Older installs recorded their reviewed shim list but not separate grants.
        // A fully revoked record must never regain access during migration.
        if records[index].compatibilityGrants == nil {
            let prior = records[index]
            let canMigrate = prior.enabled && (!prior.permissions.isEmpty || !prior.patterns.isEmpty)
            records[index].compatibilityGrants = Dictionary(uniqueKeysWithValues:
                (canMigrate ? prior.compatibility ?? [] : []).filter { bridged.contains($0) }.map { ($0, Date.distantFuture) })
        }
        // The only writer of host grants: the choice's patterns plus live time-limited grants.
        let siteTarget = ExtensionSiteAccessEngine.target(siteState ?? .withheld(), timed: siteTimed, declarations: declarations)
        records[index].siteAccess = ExtensionSiteAccessEngine.encode(siteState ?? .withheld())
        Self.store(siteTimed, in: &records[index])
        records[index].patterns = siteTarget
        for pattern in siteTarget.keys { records[index].deniedPatterns.removeValue(forKey: pattern) }
        let current = records[index]
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = current.contextIdentifier
        context.baseURL = URL(string: "webkit-extension://\(id.uuidString.lowercased())/")!
        context.unsupportedAPIs = Self.unsupportedAPIs
        context.hasAccessToPrivateData = isPrivate
        context.grantedPermissions = Dictionary(uniqueKeysWithValues: current.permissions.filter { Self.supportedPermissions.contains($0.key) }.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
        if current.safariBundle == nil && (ExtensionServiceWorkerPreparation.isPrepared(manifest: ext.manifest) || Self.supportsNativeCompanion(current)) {
            context.unsupportedAPIs.subtract(["browser.runtime.sendNativeMessage", "browser.runtime.connectNative"])
            context.grantedPermissions[.init(rawValue: "nativeMessaging")] = .distantFuture
        }
        context.grantedPermissionMatchPatterns = Self.matchPatterns(current.patterns)
        context.deniedPermissions = Dictionary(uniqueKeysWithValues: current.deniedPermissions.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
        context.deniedPermissionMatchPatterns = Self.matchPatterns(current.deniedPatterns)
        // The layer only defines what WebKit lacks, scoped to this extension's origin.
        runtime.compatibility.install(plan, for: context)
        do { try runtime.controller.load(context) } catch { runtime.disconnectNative(context); runtime.compatibility.remove(context); throw error }
        runtime.contexts[id] = context
        records[index].enabled = true; records[index].compatibility = bridged; errors.removeValue(forKey: id)
        do { try persist() } catch {
            runtime.contexts.removeValue(forKey: id); runtime.disconnectNative(context); runtime.compatibility.remove(context); try? runtime.controller.unload(context); records[index].enabled = false; throw error
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
    /// The record of a live context, only when that exact context object is the record's loaded context in the record's
    /// own profile runtime. The base-URL host maps a context to its record; this identity check is what authorizes.
    func ownedRecordIndex(for context: WKWebExtensionContext) -> Int? {
        guard let id = Self.recordID(of: context), let index = records.firstIndex(where: { $0.id == id }),
              runtimes[records[index].profileID]?.contexts[id] === context else { return nil }
        return index
    }
    func persistPermissions(_ context: WKWebExtensionContext) {
        guard let i = ownedRecordIndex(for: context) else { return }
        let id = records[i].id
        let before = records[i]
        records[i].permissions = Dictionary(uniqueKeysWithValues: context.grantedPermissions.filter { Self.supportedPermissions.contains($0.key.rawValue) }.map { ($0.key.rawValue, $0.value) })
        records[i].deniedPermissions = Dictionary(uniqueKeysWithValues: context.deniedPermissions.map { ($0.key.rawValue, $0.value) })
        records[i].deniedPatterns = Dictionary(uniqueKeysWithValues: context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
        if !context.hasPermission(.init(rawValue: "nativeMessaging")) { records[i].nativeHost = nil }
        // Host grants are not read back as authority. Two WebKit-side changes are honored: a grant WebKit removed
        // (the extension's permissions.remove, or a lapse) leaves the choice, and a declared grant with a finite expiry
        // is kept as time-limited with its own date (never extended).
        if let state = try? ExtensionSiteAccessEngine.decode(records[i].siteAccess) {
            let live = Dictionary(uniqueKeysWithValues: context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
            let reconciled = ExtensionSiteAccessEngine.reconcile(state, timed: Self.timed(records[i]), applied: records[i].patterns,
                                                                  live: live, declarations: ExtensionSiteAccess.Declarations(context.webExtension))
            records[i].siteAccess = ExtensionSiteAccessEngine.encode(reconciled.state)
            Self.store(reconciled.timed, in: &records[i])
            records[i].patterns = reconciled.target
        }
        if before.permissions != records[i].permissions || before.patterns != records[i].patterns || before.siteAccess != records[i].siteAccess || before.timedSiteGrants != records[i].timedSiteGrants || before.timedOptionalSiteGrants != records[i].timedOptionalSiteGrants || before.deniedPermissions != records[i].deniedPermissions || before.deniedPatterns != records[i].deniedPatterns || before.nativeHost != records[i].nativeHost { noteMutation(id, permissions: true) }
        if let runtime = runtimes[records[i].profileID], runtime.approvedNativeHost(context) == nil { runtime.disconnectNative(context) }
        do { try persist() } catch { setError(error, for: id) }
    }
    private func persist() throws {
        if ownsTemporaryStorage { return }
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: storageURL.appendingPathComponent("registry.json"), options: .atomic)
    }
    static func supportsNativeCompanion(_ record: BrowserExtensionRecord) -> Bool {
        guard record.safariBundle == nil, let catalog = record.catalog else { return false }
        let expected = ExtensionNativeMessaging.chromeExtensionIdentifier
        return catalog.source == .chromeWebStore && catalog.upstreamID == expected && catalog.verifiedChromeExtensionID == expected
    }
    func connectDesktopApp(id: UUID) async throws {
        guard !stopped, let record = records.first(where: { $0.id == id }), record.enabled,
              Self.supportsNativeCompanion(record), let context = context(for: id) else {
            throw Self.failure("Enable the verified Chrome Web Store build of 1Password before connecting its desktop app. Older installations may need a verified update or reinstall.")
        }
        guard context.isLoaded, context.webExtension.requestedPermissions.contains(.init(rawValue: "nativeMessaging")),
              context.hasPermission(.init(rawValue: "nativeMessaging")) else {
            throw Self.failure("1Password’s native messaging permission is unavailable. Disable and re-enable the extension to review its permissions before connecting the desktop app.")
        }
        let revision = mutationRevisions[id, default: 0], policy = nativeMessagingPolicy
        let host = try await Task.detached(priority: .utility) { try policy.validateBrowser(); return try policy.discover() }.value
        try Task.checkCancellation()
        guard !stopped, mutationRevisions[id, default: 0] == revision, self.context(for: id) === context else { return }
        let approved: Bool
        if let nativeHostPrompt { approved = nativeHostPrompt(record, host) }
        else {
            let alert = NSAlert(); alert.messageText = "Connect 1Password’s desktop app?"
            alert.informativeText = "Profile: \(profileName?(record.profileID) ?? "Current profile")\n\nAllow this verified 1Password extension to exchange messages with \(host.applicationURL.lastPathComponent)? You’ll also need to trust Bam in 1Password’s Settings → Browsers.\n\nApp: \(host.applicationURL.path)\nHost: \(host.executableURL.path)\nVerified publisher: \(host.teamIdentifier)\n\nThis access is separate from website permissions. Disconnect it here or revoke the extension’s permissions at any time. App updates require a new review."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Connect")
            approved = alert.runModal() == .alertSecondButtonReturn
        }
        guard approved else { return }
        try await Task.detached(priority: .utility) { try policy.validate(host) }.value
        try Task.checkCancellation()
        guard !stopped, mutationRevisions[id, default: 0] == revision, self.context(for: id) === context,
              let index = records.firstIndex(where: { $0.id == id && $0.profileID == record.profileID }), records[index].enabled else { return }
        let previous = records[index].nativeHost
        records[index].nativeHost = host
        do { try persist() } catch { records[index].nativeHost = previous; throw error }
        noteMutation(id, permissions: true); errors.removeValue(forKey: id); changed()
    }
    func disconnectDesktopApp(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        noteMutation(id, permissions: true); records[index].nativeHost = nil
        if let runtime = runtimes[records[index].profileID], let context = runtime.contexts[id] { runtime.disconnectNative(context) }
        try persist(); changed()
    }
    func setError(_ error: Error, for id: UUID? = nil) {
        lastError = error.localizedDescription
        if let id { errors[id] = error.localizedDescription }
        changed()
    }
    func changed() { manager?.refresh(); library?.refreshInstalledState(); onChange?() }
    func shutdown() {
        stopped = true; manager?.close(); manager = nil; library?.close(); library = nil
        for task in preparation.values { task.cancel() }; preparation.removeAll()
        for runtime in runtimes.values { for context in runtime.contexts.values { runtime.closePopup(for: context); try? runtime.controller.unload(context) }; runtime.contexts.removeAll(); runtime.shutdown() }
        runtimes.removeAll()
        surfaces = nil; selectTab = nil; closeTab = nil; navigateTab = nil; reloadTab = nil; createTab = nil; setTabPinned = nil; createWindow = nil; bookmarkSnapshot = nil; historySnapshot = nil; closeWindow = nil; startDownload = nil
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
    let compatibility: ExtensionCompatibilityBridge
    var contexts: [UUID: WKWebExtensionContext] = [:]
    var tabs: [UUID: BrowserExtensionTab] = [:] { didSet { invalidateTopologyCache() } }
    var windows: [ObjectIdentifier: BrowserExtensionWindow] = [:] { didSet { invalidateTopologyCache() } }
    var snapshots: [UUID: BrowserExtensionSurface] = [:]
    var orderedIDs: [UUID] = [] { didSet { invalidateTopologyCache() } }
    private struct WindowTopology {
        var ids: [UUID]
        var indices: [UUID: Int]
        var activeID: UUID?
        var adapters: [any WKWebExtensionTab]
        var isSinglePage: Bool
    }
    private var topologyCache: (revision: UInt64, windows: [ObjectIdentifier: WindowTopology])?
    private var topologyMutation: UInt64 = 0
    /// Records every computed topology (cache hits return that same computation): per window, its adapter, kind and
    /// ordered tab adapters. Every window and index WebKit is served comes from a recorded computation, so a change and
    /// change-back between two observations (ABA), a replaced adapter or a membership change advances it. An unstable
    /// computation (the host changed during it) is never cached, so the next read records the real state.
    private var metadataGeneration = ExtensionTabMetadata.Generation()
    weak var popupAnchor: NSView?
    var popupTabID: UUID?
    var popupContextID: String?
    private var activePopupTabID: UUID?
    private var activePopup: WKWebExtension.Action?
    private var activePopupPopover: NSPopover?
    private var lastFocusedWindow: ObjectIdentifier?
    private var reportedActiveTabs: [ObjectIdentifier: UUID] = [:]
    /// Windows whose surfaces are single-page (Little Bam), reported as `popup`.
    private(set) var singlePageWindows: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []

    init(owner: BrowserExtensions, profileID: UUID, dataStore: WKWebsiteDataStore) {
        self.owner = owner; self.profileID = profileID; self.dataStore = dataStore
        let configuration: WKWebExtensionController.Configuration
        if BrowserExtensions.usesNonPersistentController(isPrivate: owner.isPrivate, storage: owner.controllerStorage) { configuration = .nonPersistent() }
        // Development previews keep a separate persistent store; production's
        // legacy Default profile continues using WebKit's default store.
        else if let identifier = PreviewProfile.persistentIdentifier(for: profileID) { configuration = WKWebExtensionController.Configuration(identifier: identifier) }
        else { configuration = .default() }
        configuration.defaultWebsiteDataStore = dataStore
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = dataStore
        // Extension pages fetch sites themselves (vidIQ reads YouTube HTML from its
        // background); a bare WebKit user agent gets served different documents.
        webConfiguration.adoptSafariUserAgent()
        // Materialize the shared controller before WebKit copies the configuration.
        // A default lazy UCC read through controller.configuration belongs to a copy.
        webConfiguration.userContentController = extensionContentController
        configuration.webViewConfiguration = webConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        compatibility = ExtensionCompatibilityBridge(controller: controller, dataStore: dataStore, contentController: extensionContentController, browserVersion: BrowserExtensions.browserVersion)
        super.init(); controller.delegate = self
        ExtensionNotificationCenter.shared.register(compatibility)
        compatibility.isNotificationDeliveryAvailable = { ExtensionNotificationCenter.shared.isAvailable }
        compatibility.postNotification = { identifier, title, body, buttons, isAuthorized in
            await ExtensionNotificationCenter.shared.post(identifier: identifier, title: title, body: body, buttons: buttons, isAuthorized: isAuthorized)
        }
        compatibility.startDownload = { [weak self] web, download in self?.owner?.startDownload?(web, download.url, download.filename) == true }
        compatibility.workerDownload = { [weak self] context, download in
            guard let self, self.owns(context), let web = self.currentSurfaces().first(where: { $0.isActive })?.webView else { return false }
            return self.owner?.startDownload?(web, download.url, download.filename) == true
        }
        compatibility.isPrivateHost = owner.isPrivate
        compatibility.bookmarkInput = { [weak self] in
            guard let self, let owner = self.owner, !owner.isPrivate else { return nil }
            return owner.bookmarkSnapshot?(self.profileID)
        }
        compatibility.historyVisits = { [weak self] in
            guard let self, let owner = self.owner, !owner.isPrivate else { return nil }
            return owner.historySnapshot?(self.profileID).map { Array($0.prefix(ExtensionHistory.maximumVisits)) }
        }
        compatibility.tabMetadataBinding = { [weak self] context in self?.tabMetadataBinding(for: context) }
        compatibility.answerTabMetadata = { [weak self] context, issued, request in self?.answerTabMetadata(for: context, issued: issued, request: request) }
        compatibility.permissionGranted = { [weak self] context, permission in
            guard let self, let record = self.ownedRecord(for: context), record.enabled else { return false }
            return (record.compatibilityGrants?[permission] ?? .distantPast) > Date()
        }
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
                        if let error = context.errors.first { self.owner?.setError(error, for: BrowserExtensions.recordID(of: context)) }
                    } else {
                        self.owner?.persistPermissions(context)
                    }
                }
            })
        }
        // WebKit owns the popover delegate and disposes its web view on close.
        // Track the presented popover, not just the reusable extension action:
        // a delayed notification from its old popup must not clear a new one.
        observeWindowGeometry()
        observers.append(NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let closed = notification.object as? NSPopover,
                      self.activePopupPopover === closed else { return }
                self.clearPopupPresentation()
            }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    // windows.onBoundsChanged: a committed move or resize of a window this profile exposes (its own `windows`
    // map, so other profiles' and unexposed windows never signal) signals this profile's contexts. Live
    // resizes are ignored until they end; moves and programmatic resizes settle for boundsSettleDelay with no
    // further change. Because the adapter compares every window it reads, a signal is held while any window
    // of this profile is in a live resize or a mouse button is down, so no read sees uncommitted bounds.
    static let boundsSettleDelay: TimeInterval = 0.3
    /// AppKit's live-resize state. Replaceable only so the canonical fixture can hold a window mid-resize
    /// without input injection; a real pointer drag remains a separate root check.
    var isInLiveResize: (NSWindow) -> Bool = { $0.inLiveResize }
    private var boundsGenerations: [ObjectIdentifier: Int] = [:]
    /// Signals sent (fixture diagnostics only).
    private(set) var boundsSignalCount = 0
    func observeWindowGeometry() {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow, isResize = notification.name == NSWindow.didResizeNotification
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    self.windowGeometryChanged(window, liveResizeStep: isResize && self.isInLiveResize(window))
                }
            })
        }
    }
    func windowGeometryChanged(_ window: NSWindow, liveResizeStep: Bool) {
        let key = ObjectIdentifier(window)
        guard !liveResizeStep, windows[key]?.native === window else { return }
        let generation = (boundsGenerations[key] ?? 0) + 1
        boundsGenerations[key] = generation
        scheduleBoundsSignal(key, generation: generation, window: window)
    }
    private func scheduleBoundsSignal(_ key: ObjectIdentifier, generation: Int, window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.boundsSettleDelay) { [weak self, weak window] in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.boundsGenerations[key] == generation, self.windows[key]?.native === window else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 || self.windows.values.contains(where: { $0.native.map(self.isInLiveResize) == true }) {
                    self.scheduleBoundsSignal(key, generation: generation, window: window); return
                }
                self.boundsGenerations.removeValue(forKey: key)
                self.boundsSignalCount += 1
                self.compatibility.signalWindowBoundsChanged()
            }
        }
    }
    private func clearPopupPresentation() { activePopup = nil; activePopupPopover = nil; activePopupTabID = nil }
    var nativeSessions: [UUID: BrowserExtensionNativeSession] = [:]
    func shutdown() { boundsGenerations.removeAll(); disconnectAllNative(); compatibility.shutdown(); ExtensionNotificationCenter.shared.unregister(compatibility) }
    func closePopup(for context: WKWebExtensionContext) {
        if popupContextID == context.uniqueIdentifier { popupAnchor = nil; popupTabID = nil; popupContextID = nil }
        if let action = activePopup, action.webExtensionContext === context { clearPopupPresentation(); action.closePopup() }
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
    private func invalidateTopologyCache() {
        topologyMutation &+= 1
        topologyCache = nil
    }
    /// Cache topology and lightweight adapters, never page objects or permission
    /// decisions. Adapters hold a weak runtime and still authorize every live read.
    /// Hosts unable to guarantee synchronous invalidation retain fully live reads.
    private func topology() -> [ObjectIdentifier: WindowTopology] {
        let mutation = topologyMutation
        let revision = owner?.surfaceRevision?(profileID)
        if let revision, let cached = topologyCache, cached.revision == revision { return cached.windows }
        let grouped = Dictionary(grouping: currentSurfaces(), by: windowKey)
        var result: [ObjectIdentifier: WindowTopology] = [:]
        for (key, members) in grouped {
            let ids = members.map(\.id)
            let indices = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            result[key] = WindowTopology(ids: ids, indices: indices, activeID: windows[key]?.activeID(in: members), adapters: [],
                                         isSinglePage: members.contains(where: \.isSinglePage))
        }
        // A host callback is allowed to change its revision while producing data.
        // Do not retain a result from a changing or unversioned host.
        let stable = revision.map { owner?.surfaceRevision?(profileID) == $0 && topologyMutation == mutation } ?? false
        // Materialize adapters after the last host callback: a callback can
        // replace an adapter even when the host's own revision stays unchanged.
        result = result.mapValues { topology in
            var topology = topology
            topology.adapters = topology.ids.compactMap { tabs[$0] }
            return topology
        }
        if let revision, stable {
            topologyCache = (revision, result)
        } else { topologyCache = nil }
        // A window or tab without an adapter is recorded by its window key, which no adapter can equal.
        // Adapter replacement that reuses an address is still caught by the mutation counter in the token's binding.
        metadataGeneration.record(result.map { key, topology in
            ExtensionTabMetadata.ObservedWindow(adapter: (windows[key].map(ObjectIdentifier.init) ?? key).hashValue, isSinglePage: topology.isSinglePage,
                                                tabs: topology.ids.map { (tabs[$0].map(ObjectIdentifier.init) ?? key).hashValue })
        })
        return result
    }
    func tabIDs(in key: ObjectIdentifier) -> [UUID] { topology()[key]?.ids ?? [] }
    /// The window and index of a tab from one observed topology (never the live surface), so `windowId` and `index`
    /// that WebKit reports come from the same observation the metadata generation records.
    func placement(of id: UUID) -> (key: ObjectIdentifier, index: Int)? {
        for (key, topology) in topology() { if let index = topology.indices[id] { return (key, index) } }
        return nil
    }
    func isSinglePageWindow(_ key: ObjectIdentifier) -> Bool { topology()[key]?.isSinglePage ?? singlePageWindows.contains(key) }

    // MARK: Tab metadata (read-only; see work/chrome-tab-metadata-api.md)

    /// Only the exact loaded context registered for this runtime's own record (same profile), holding `tabs` now,
    /// within the private-data boundary. Controller identity alone is not authority. Nothing else is granted or checked.
    private func allowsTabMetadata(_ context: WKWebExtensionContext) -> Bool {
        guard context.isLoaded, owns(context), let owner, let index = owner.ownedRecordIndex(for: context),
              owner.records[index].profileID == profileID, owner.records[index].enabled,
              let id = BrowserExtensions.recordID(of: context), contexts[id] === context else { return false }
        return context.hasPermission(.tabs) && (!owner.isPrivate || context.hasAccessToPrivateData)
    }
    private func metadataBinding(_ context: WKWebExtensionContext) -> ExtensionTabMetadata.Binding {
        ExtensionTabMetadata.Binding(context: context.uniqueIdentifier, runtime: ObjectIdentifier(self).hashValue, profile: profileID,
                                     generation: metadataGeneration.value, mutation: topologyMutation)
    }
    /// The binding a token is issued for: forces an observation first. nil when metadata isn't allowed.
    func tabMetadataBinding(for context: WKWebExtensionContext) -> ExtensionTabMetadata.Binding? {
        guard allowsTabMetadata(context) else { return nil }
        _ = topology()
        return metadataBinding(context)
    }
    /// Answers a redeemed request from the observation its token was issued for: per entry, the tab adapter's own
    /// `url(for:)`/`title(for:)` (what WebKit would show with host access) when admissible, else nil (left redacted).
    /// With a filter, only matching tabs get a value (WebKit semantics: a tab it can't evaluate never matches).
    /// nil for the whole request (fall back to WebKit's answer) when: metadata isn't allowed any more; the observation,
    /// adapters, context, runtime or profile differ from `issued`, including after reading values (which calls the
    /// host); window kinds are ambiguous; the title budget runs out; or a filtered answer wouldn't fit the response.
    func answerTabMetadata(for context: WKWebExtensionContext, issued: ExtensionTabMetadata.Binding,
                           request: ExtensionTabMetadata.Request) -> [ExtensionTabMetadata.Value?]? {
        guard allowsTabMetadata(context) else { return nil }
        let observed = topology()
        guard metadataBinding(context) == issued else { return nil }
        let normal = observed.values.filter { !$0.isSinglePage }, popups = observed.values.filter(\.isSinglePage)
        guard normal.count == request.normalCount, request.normalCount <= 1, popups.count == request.popupCount else { return nil }
        let normalIDs = normal.first?.ids ?? []
        // Several Little Bam windows can't be told apart by WebKit window ID here: their tabs stay redacted.
        let popupIDs = popups.count == 1 && popups[0].ids.count == 1 ? popups[0].ids : []
        let urlPatterns = request.filter?.urlPatterns?.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        var budget = ExtensionTabMetadata.titleMatchBudget
        var values: [ExtensionTabMetadata.Value?] = []
        values.reserveCapacity(request.entries.count)
        for entry in request.entries {
            let id: UUID?
            switch entry.window {
            case .normal: id = normalIDs.indices.contains(entry.index) ? normalIDs[entry.index] : nil
            case .popup: id = entry.index == 0 ? popupIDs.first : nil
            }
            guard let id, let tab = tabs[id], let url = tab.url(for: context),
                  let value = ExtensionTabMetadata.admissible(url: url, title: tab.title(for: context)) else { values.append(nil); continue }
            if let filter = request.filter {
                // An unparseable URL pattern is skipped, as WebKit does; no valid pattern then matches nothing.
                if filter.urlPatterns != nil, !(urlPatterns ?? []).contains(where: { $0.matches(url) }) { values.append(nil); continue }
                if let title = filter.title {
                    switch ExtensionTabMetadata.titleMatches(title, value.title ?? "", budget: &budget) {
                    case .match: break
                    case .noMatch: values.append(nil); continue
                    case .exhausted: return nil
                    }
                }
            }
            values.append(value)
        }
        if request.filter != nil, !ExtensionTabMetadata.responseFits(values) { return nil }
        // Reading values called the host: answer only if the observation is still the issued one.
        _ = topology()
        guard allowsTabMetadata(context), metadataBinding(context) == issued else { return nil }
        return values
    }

    func tabAdapters(in key: ObjectIdentifier) -> [any WKWebExtensionTab] { topology()[key]?.adapters ?? [] }
    func tabIndex(_ id: UUID, in key: ObjectIdentifier) -> Int { topology()[key]?.indices[id] ?? NSNotFound }
    func activeTabID(in key: ObjectIdentifier) -> UUID? { topology()[key]?.activeID }

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
        // A popup belongs to the tab where it was invoked. Do not leave a vault
        // or tab-specific action floating over a different page or login profile.
        if let action = activePopup, let id = (action.associatedTab as? BrowserExtensionTab)?.id ?? activePopupTabID,
           fresh[id]?.isActive != true || fresh[id]?.url != snapshots[id]?.url {
            clearPopupPresentation(); action.closePopup(); popupAnchor = nil; popupTabID = nil; popupContextID = nil
        }
        let old = snapshots, previousWindowKeys = Set(windows.keys)
        for id in orderedIDs where fresh[id] == nil { if let tab = tabs[id] { controller.didCloseTab(tab) }; tabs.removeValue(forKey: id) }
        snapshots = fresh; orderedIDs = ids
        let neededWindows = Set(supplied.map(windowKey))
        singlePageWindows = Set(supplied.filter(\.isSinglePage).map(windowKey))
        for key in Array(windows.keys) where !neededWindows.contains(key) { if let window = windows.removeValue(forKey: key) { controller.didCloseWindow(window) } }
        var openedWindow = false
        for item in supplied {
            let key = windowKey(item)
            if windows[key] == nil { let window = BrowserExtensionWindow(runtime: self, key: key, native: item.window); windows[key] = window; controller.didOpenWindow(window); openedWindow = true }
            if tabs[item.id] == nil { let tab = BrowserExtensionTab(runtime: self, id: item.id); tabs[item.id] = tab; controller.didOpenTab(tab) }
            else if let previous = old[item.id], let tab = tabs[item.id] {
                var properties: WKWebExtension.TabChangedProperties = []
                if previous.title != item.title { properties.insert(.title) }
                if previous.url != item.url || previous.webView !== item.webView { properties.insert(.URL); properties.insert(.loading) }
                if previous.isPinned != item.isPinned { properties.insert(.pinned) }
                if previous.isLoading != item.isLoading || item.loadingChanged { properties.insert(.loading) }
                if !properties.isEmpty { controller.didChangeTabProperties(properties, for: tab) }
            }
        }
        // A new window joins windows.onBoundsChanged baselines: the adapter re-reads and remembers it without
        // reporting (it reports only differences), so the window's first committed move is not missed.
        if openedWindow { compatibility.signalWindowBoundsChanged(topologyOnly: true) }
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
        // The target window and index are honored or refused before anything is created.
        let targetWindow = configuration.window.map { $0 as? BrowserExtensionWindow }
        let target: ExtensionWindowTargeting.Window? = targetWindow.map { window in
            guard let window, window.runtime === self, windows[window.key] === window else { return .otherProfile }
            return singlePageWindows.contains(window.key) ? .singlePage : .browser
        }
        // A new tab lands after this profile's tabs in the window, before any exposed Peek.
        func windowTabs() -> [BrowserExtensionSurface] {
            (targetWindow ?? nil).map { window in currentSurfaces().filter { windowKey($0) == window.key && !$0.isPeek } } ?? []
        }
        var tabsInWindow = windowTabs()
        let canInsert = owner?.placesTabsBeforeAnchor == true
        // An insertion is resolved against the live order: publish pending changes first, so the tab the extension
        // indexed is the one now at that index.
        if owns(context), canInsert, target == .browser, ExtensionWindowTargeting.insertionAnchor(index: configuration.index, landing: tabsInWindow.count) != nil {
            reconcile(); tabsInWindow = windowTabs()
        }
        let landing = tabsInWindow.count
        if owns(context), let refusal = ExtensionWindowTargeting.tabCreation(target: target, index: configuration.index,
                landing: landing, windowTabCount: (targetWindow ?? nil).map { tabIDs(in: $0.key).count } ?? 0, canInsert: canInsert) {
            completionHandler(nil, BrowserExtensions.failure(refusal)); return
        }
        let anchor = ExtensionWindowTargeting.insertionAnchor(index: configuration.index, landing: landing).map { tabsInWindow[$0].id }
        // Pinned means a Bam kept tab (never a Favorite), placed at the requested index like any other new tab.
        let pinned = configuration.shouldBePinned
        if owns(context), let url = configuration.url, let refusal = ExtensionPinnedPolicy.creationRefusal(url: url, pinned: pinned) {
            completionHandler(nil, BrowserExtensions.failure(refusal)); return
        }
        guard owns(context), let url = configuration.url, (["http", "https"].contains(url.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url, ownedBy: context)),
              !configuration.shouldBeMuted, !configuration.shouldReaderModeBeActive,
              let id = owner?.createTab(url, profileID: profileID, active: configuration.shouldBeActive, kept: pinned, before: anchor) else {
            completionHandler(nil, BrowserExtensions.failure("Bam can open ordinary HTTP/HTTPS pages or this extension’s own pages in this profile only.")); return
        }
        // A host that did not keep the tab must not leave an ordinary one behind a pinned request.
        // Checked against the live host before this runtime publishes the tab to any extension.
        if pinned, currentSurface(id)?.isPinned != true {
            _ = owner?.closeTab?(id)
            completionHandler(nil, BrowserExtensions.failure("Bam could not keep the new tab, so it was not opened.")); return
        }
        // An inserted tab must report exactly the requested index; reconcile adopts this live order.
        // Otherwise it is removed (unkept first, so nothing is left behind) before any extension hears of it.
        if anchor != nil, let window = targetWindow ?? nil,
           (owner?.surfaces?(profileID) ?? []).filter({ accepts($0) && windowKey($0) == window.key && !$0.isPeek }).map(\.id).firstIndex(of: id) != configuration.index {
            if pinned { _ = owner?.setTabPinned?(id, profileID, false) }
            _ = owner?.closeTab?(id)
            completionHandler(nil, BrowserExtensions.failure(ExtensionWindowTargeting.placementRefusal(index: configuration.index))); return
        }
        reconcile(); guard let tab = tabs[id] else { completionHandler(nil, BrowserExtensions.failure("The new tab is not in this extension’s profile.")); return }
        completionHandler(tab, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void) {
        let url = configuration.tabURLs.first
        let type: ExtensionWindowTargeting.RequestedType = configuration.windowType == .popup ? .popup : configuration.windowType == .normal ? .normal : .other
        let state: ExtensionWindowTargeting.RequestedState = switch configuration.windowState {
            case .minimized: .minimized
            case .maximized: .maximized
            case .fullscreen: .fullscreen
            default: .normal
        }
        if owns(context), let refusal = ExtensionWindowTargeting.windowCreation(type: type, state: state, urlCount: configuration.tabURLs.count,
                hasTabs: !configuration.tabs.isEmpty, requestsBounds: ExtensionWindowTargeting.requestsBounds(configuration.frame)) {
            completionHandler(nil, BrowserExtensions.failure(refusal)); return
        }
        guard owns(context), !configuration.shouldBePrivate, configuration.tabURLs.count <= 1, configuration.tabs.isEmpty,
              url == nil || ["http", "https"].contains(url!.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url!, ownedBy: context),
              let native = owner?.createWindow?(url, profileID, configuration.shouldBeFocused) else {
            completionHandler(nil, BrowserExtensions.failure("Bam opens extension windows as Little Bam windows with one ordinary or extension page in this profile.")); return
        }
        reconcile()
        guard let window = windows[ObjectIdentifier(native)] else { completionHandler(nil, BrowserExtensions.failure("The new window is not in this extension’s profile.")); return }
        if configuration.windowState == .minimized { native.miniaturize(nil) }
        completionHandler(window, nil)
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
    /// WebKit's *implicit* URL requests: it asks here before tab and window reads, script and CSS injection, cookies,
    /// captureVisibleTab, detectLanguage, getMatchedRules, devtools eval and failed CORS loads, and would grant `*://host/*`
    /// on approval. Chrome never prompts from those calls: an extension regains a withheld or optional site only through
    /// an explicit request (`permissions.request`, which WebKit routes to `promptForPermissionMatchPatterns` below) or a
    /// user gesture (activeTab), and the user can allow a site in Site Access. So Bam answers every implicit request
    /// empty, at once: no review, no denial, no record change. The call then proceeds without that access (tab url/title
    /// stay blank for the tab metadata facade to supply; injection fails with WebKit's own access error).
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler([], nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        guard authorizes(tab, for: context), let owner else { completionHandler([], nil); return }
        let (decisions, revision) = owner.promptDecisions(patterns.map { ($0, Optional($0.string)) }, for: context)
        let offered = patterns.filter { decisions[$0].map { $0 != .refused } ?? false }
        let review = BrowserExtensionPermissionReview(name: context.webExtension.displayName ?? "Extension", profileName: owner.profileName?(profileID) ?? "Current profile", permissions: [], websites: offered.map(\.string).sorted(), unsupported: [], isOptional: true)
        let approved = !offered.isEmpty && owner.approve(review) ? offered : []
        guard authorizes(tab, for: context), owner.promptIsCurrent(context, revision: revision) else { completionHandler([], nil); return }
        // Bound to the state the dialog was computed from: a revoke, mode change or update meanwhile grants nothing.
        let granted = owner.recordSiteApprovals(context, approved.compactMap { decisions[$0] }, revision: revision) ? approved : []
        for pattern in offered where !approved.contains(pattern) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        owner.persistPermissions(context); completionHandler(granted, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let associatedID = (action.associatedTab as? BrowserExtensionTab)?.id
        let requested = popupContextID == context.uniqueIdentifier && (associatedID == nil || associatedID == popupTabID)
        let tabID = associatedID ?? (requested ? popupTabID : nil)
        let requestedAnchor = requested ? popupAnchor : nil
        if requested { popupAnchor = nil; popupTabID = nil; popupContextID = nil }
        let surface = tabID.flatMap(currentSurface) ?? (tabID == nil ? currentSurfaces().first { $0.isActive && $0.window?.isKeyWindow == true } : nil)
        guard authorizes(action.associatedTab, for: context), let surface, surface.isActive,
              let popup = action.popupPopover, let anchor = requestedAnchor ?? surface.window?.contentView,
              anchor.window === surface.window, anchor.window?.isVisible == true else {
            completionHandler(BrowserExtensions.failure("Open a page in this profile to show its extension popup.")); return
        }
        // Closing this same WK action would destroy the freshly loaded popup
        // that WebKit is asking us to present, leaving an empty gray popover.
        if let previous = activePopup, previous !== action { clearPopupPresentation(); previous.closePopup() }
        activePopup = action; activePopupPopover = popup; activePopupTabID = surface.id
        popup.behavior = .transient
        // A real toolbar button is the anchor; large menu fallback surfaces use
        // their top-right corner. Never reposition the popup over unrelated chrome.
        let isButton = anchor is NSButton
        let rect = isButton ? anchor.bounds : NSRect(x: max(0, anchor.bounds.maxX - 28), y: anchor.isFlipped ? 0 : anchor.bounds.maxY - 28, width: 28, height: 28)
        popup.show(relativeTo: rect, of: anchor, preferredEdge: isButton ? .maxX : .minY)
        completionHandler(nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) { if owns(context) { owner?.changed() } }
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for context: WKWebExtensionContext, replyHandler: @escaping (Any?, Error?) -> Void) {
        guard controller === self.controller else { replyHandler(nil, BrowserExtensions.failure("This extension controller is not authorized.")); return }
        if applicationIdentifier == ExtensionNativeMessaging.applicationIdentifier {
            sendNative(message, context: context, reply: replyHandler); return
        }
        guard allowsCompatibilityTransport(context), applicationIdentifier == ExtensionCompatibility.nativeApplicationIdentifier else {
            replyHandler(nil, BrowserExtensions.failure(BrowserExtensions.compatibilityTransportUnavailable)); return
        }
        Task { @MainActor in
            let (value, error) = await compatibility.receiveNativeMessage(message, context: context)
            replyHandler(value, error)
        }
    }
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard controller === self.controller else { completionHandler(BrowserExtensions.failure("This extension controller is not authorized.")); return }
        if port.applicationIdentifier == ExtensionNativeMessaging.applicationIdentifier {
            connectNative(port, context: context, completion: completionHandler); return
        }
        guard allowsCompatibilityTransport(context), port.applicationIdentifier == ExtensionCompatibility.nativeApplicationIdentifier else {
            completionHandler(BrowserExtensions.failure(BrowserExtensions.compatibilityTransportUnavailable)); return
        }
        completionHandler(compatibility.connectNativePort(port, context: context))
    }
    /// This profile's record for a context, only when that exact context is the record's loaded context here.
    func ownedRecord(for context: WKWebExtensionContext) -> BrowserExtensionRecord? {
        guard owns(context), let id = BrowserExtensions.recordID(of: context), contexts[id] === context else { return nil }
        return owner?.records.first { $0.id == id && $0.profileID == profileID }
    }
    private func allowsCompatibilityTransport(_ context: WKWebExtensionContext) -> Bool {
        guard owns(context), context.hasPermission(.init(rawValue: "nativeMessaging")),
              ExtensionServiceWorkerPreparation.isPrepared(manifest: context.webExtension.manifest),
              let record = ownedRecord(for: context) else { return false }
        return record.safariBundle == nil
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
    /// Resolve once per callback, including the live profile/controller/store check.
    /// Event snapshots and window topology never authorize a tab operation.
    private func authorizedSurface(_ context: WKWebExtensionContext) -> BrowserExtensionSurface? {
        guard runtime?.owns(context) == true else { return nil }
        return surface
    }
    private func valid(_ context: WKWebExtensionContext) -> Bool { authorizedSurface(context) != nil }
    // Window and index come from the runtime's observed topology (one recorded observation), not the live surface;
    // the live surface still authorizes the read.
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard authorizedSurface(context) != nil, let runtime, let placement = runtime.placement(of: id) else { return nil }
        return runtime.windows[placement.key]
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard authorizedSurface(context) != nil, let runtime, let placement = runtime.placement(of: id),
              runtime.windows[placement.key] != nil else { return NSNotFound }
        return placement.index
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let web = authorizedSurface(context)?.webView,
              web.configuration.webExtensionController === context.webExtensionController else { return nil }
        return web
    }
    func title(for context: WKWebExtensionContext) -> String? { authorizedSurface(context)?.title }
    func url(for context: WKWebExtensionContext) -> URL? {
        guard let url = authorizedSurface(context)?.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url, ownedBy: context) else { return nil }
        return url
    }
    func isPinned(for context: WKWebExtensionContext) -> Bool { authorizedSurface(context)?.isPinned == true }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let surface = authorizedSurface(context), let runtime else { return false }
        return surface.isSelected || runtime.windows[runtime.windowKey(surface)]?.activeID == id
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { webView(for: context)?.isLoading != true }
    func size(for context: WKWebExtensionContext) -> CGSize { webView(for: context)?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView(for: context)?.pageZoom ?? 1) }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let web = webView(for: context), zoomFactor >= 0.25, zoomFactor <= 5 else { completionHandler(BrowserExtensions.failure("This page cannot be zoomed.")); return }
        web.pageZoom = zoomFactor; completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let web = webView(for: context), web.canGoBack else { completionHandler(BrowserExtensions.failure("This page cannot go back.")); return }
        web.goBack(); completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let web = webView(for: context), web.canGoForward else { completionHandler(BrowserExtensions.failure("This page cannot go forward.")); return }
        web.goForward(); completionHandler(nil)
    }
    /// tabs.detectLanguage: the page's recognizable text, else its declared language, else `und`.
    /// Bam samples the page itself, so it requires access to this tab (a host grant or the
    /// tab's `activeTab` grant); Chrome answers from browser state without that requirement.
    /// The sample is read in an isolated world, never returned, and discarded unless the same
    /// document of the same tab is still accessible when it arrives.
    func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        let denied = BrowserExtensions.failure("This page's language is not available to this extension.")
        guard let web = webView(for: context), let url = url(for: context), context.hasAccess(to: url, in: self) else { completionHandler(nil, denied); return }
        web.callAsyncJavaScript(ExtensionLanguageDetection.sampleScript, arguments: [:], in: nil, in: Self.languageWorld) { [weak self, weak web, weak context] result in
            guard let self, let web, let context, context.isLoaded, self.webView(for: context) === web, let current = self.url(for: context),
                  Self.sameDocument(current, url), context.hasAccess(to: current, in: self) else { completionHandler(nil, denied); return }
            guard case .success(let value) = result, let sample = value as? [String: Any],
                  let sampled = (sample["url"] as? String).flatMap(URL.init(string:)), Self.sameDocument(sampled, url) else {
                completionHandler(nil, BrowserExtensions.failure("The page language could not be detected.")); return
            }
            completionHandler(Locale(identifier: ExtensionLanguageDetection.language(declared: sample["declared"] as? String, text: sample["text"] as? String)), nil)
        }
    }
    /// Same document: equal apart from a fragment, which a same-page jump changes.
    private static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        var left = URLComponents(url: a, resolvingAgainstBaseURL: false), right = URLComponents(url: b, resolvingAgainstBaseURL: false)
        left?.fragment = nil; right?.fragment = nil
        return left != nil && left?.url == right?.url
    }
    private static let languageWorld = WKContentWorld.world(name: "BamLanguageDetection")
    /// tabs.captureVisibleTab: a snapshot of the live page, which the extension already has host access to.
    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (NSImage?, Error?) -> Void) {
        guard let web = webView(for: context), let url = url(for: context), context.hasAccess(to: url, in: self) else { completionHandler(nil, BrowserExtensions.failure("This page cannot be captured.")); return }
        web.takeSnapshot(with: configuration) { image, error in completionHandler(image, error) }
    }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { url(for: context) != nil }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(valid(context) && runtime?.owner?.selectTab?(id) == true ? nil : BrowserExtensions.failure("This tab cannot be activated.")) }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(valid(context) && runtime?.owner?.closeTab?(id) == true ? nil : BrowserExtensions.failure("This tab cannot be closed.")) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard valid(context), (["http", "https"].contains(url.scheme?.lowercased() ?? "") || BrowserExtensions.isExtensionURL(url, ownedBy: context)), runtime?.owner?.navigateTab?(id, url) == true else { completionHandler(BrowserExtensions.failure("Only HTTP/HTTPS or this extension’s own pages in this profile are supported.")); return }; completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(valid(context) && runtime?.owner?.reloadTab?(id, fromOrigin) == true ? nil : BrowserExtensions.failure("This page cannot be reloaded.")) }
    /// Pinned is Bam's kept state; see ExtensionPinnedPolicy for what an extension may change.
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let surface = authorizedSurface(context), let runtime else { completionHandler(BrowserExtensions.failure("This tab cannot be pinned or unpinned.")); return }
        guard !surface.isPeek, !surface.isSinglePage else {
            completionHandler(BrowserExtensions.failure("Only tabs in Bam’s sidebar can be pinned or unpinned.")); return
        }
        guard let apply = runtime.owner?.setTabPinned else { completionHandler(BrowserExtensions.failure("This tab cannot be pinned or unpinned.")); return }
        if let refusal = apply(id, runtime.profileID, pinned) { completionHandler(BrowserExtensions.failure(refusal)); return }
        // Publish the change (tabs.onUpdated pinned) before WebKit reads the updated tab back.
        runtime.reconcile()
        completionHandler(nil)
    }
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
    var tabIDs: [UUID] { runtime?.tabIDs(in: key) ?? [] }
    /// Each profile exposes a virtual window, even while another profile is visible.
    /// WebKit requires every nonempty window to contain its active tab. Preserve
    /// that profile's selection independently from physical window focus.
    var activeID: UUID? { runtime?.activeTabID(in: key) }
    func activeID(in members: [BrowserExtensionSurface]) -> UUID? {
        if let visible = members.first(where: \.isActive) { rememberedActiveID = visible.id }
        else if rememberedActiveID.map({ id in members.contains { $0.id == id } }) != true { rememberedActiveID = members.first?.id }
        return rememberedActiveID
    }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { guard runtime?.owns(context) == true else { return [] }; return runtime?.tabAdapters(in: key) ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { guard runtime?.owns(context) == true else { return nil }; return activeID.flatMap { runtime?.tabs[$0] } }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { runtime?.owner?.isPrivate == true }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { runtime?.isSinglePageWindow(key) == true ? .popup : .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { native?.isMiniaturized == true ? .minimized : .normal }
    func frame(for context: WKWebExtensionContext) -> CGRect { native?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { native?.screen?.frame ?? .null }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard runtime?.owns(context) == true, !tabIDs.isEmpty, let native else { completionHandler(BrowserExtensions.failure("This profile has no open window.")); return }
        native.makeKeyAndOrderFront(nil); completionHandler(nil)
    }
    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard runtime?.owns(context) == true, let native else { completionHandler(BrowserExtensions.failure("This profile has no open window.")); return }
        switch state {
        case .minimized: native.miniaturize(nil)
        case .normal, .maximized: if native.isMiniaturized { native.deminiaturize(nil) }
        default: completionHandler(BrowserExtensions.failure("Full-screen extension windows are not supported.")); return
        }
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard runtime?.owns(context) == true, let native, runtime?.owner?.closeWindow?(native) == true else { completionHandler(BrowserExtensions.failure("Bam closes only Little Bam windows this extension opened.")); return }
        completionHandler(nil)
    }
}
