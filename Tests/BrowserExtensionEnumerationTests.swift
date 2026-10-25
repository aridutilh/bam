import Foundation
import WebKit

/// Exercises the actual adapters without creating windows, renderers or extension processes.
@main @MainActor enum BrowserExtensionEnumerationTests {
    struct Failure: Error { let message: String }
    static func main() async throws {
        guard #available(macOS 15.4, *) else { print("SKIP: Extension enumeration requires macOS 15.4"); return }
        try await run()
    }
    @available(macOS 15.4, *)
    static func run() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; checks += 1
        }
        let profile = UUID(), otherProfile = UUID(), a = UUID(), b = UUID(), c = UUID(), added = UUID()
        func page(_ id: UUID, title: String = "Page", active: Bool = false) -> BrowserExtensionSurface {
            BrowserExtensionSurface(id: id, title: title, url: URL(string: "https://example.invalid/"), webView: nil, window: nil, isActive: active)
        }
        let host = BrowserExtensions(storageURL: nil, isPrivate: true)
        let runtime = BrowserExtensionRuntime(owner: host, profileID: profile, dataStore: .nonPersistent())
        let window = BrowserExtensionWindow(runtime: runtime, key: ObjectIdentifier(runtime), native: nil)
        runtime.windows[window.key] = window
        runtime.orderedIDs = [a, b, c]
        var supplied = [page(c, active: true), page(a), page(b), page(added)]
        var calls = 0
        host.surfaces = { requestedProfile in calls += 1; return requestedProfile == profile ? supplied : [] }
        try check(window.tabIDs == [a, b, c], "Live provider reordering or additions changed reconciled tab order")
        try check(window.activeID == c, "Live active tab must win over the first member")
        supplied = [page(b), page(c), page(a)]
        try check(window.activeID == c, "An unfocused profile must remember its surviving active tab")
        supplied = [page(b), page(a)]
        try check(window.tabIDs == [a, b] && window.activeID == a, "Removed active tab must disappear before reconciliation and fall back in tab order")
        supplied = [page(b, active: true), page(a, active: true)]
        try check(window.activeID == a, "Multiple active candidates must use reconciled order")
        supplied = [page(b), page(b, title: "Duplicate", active: true), page(a)]
        try check(runtime.currentSurfaces().first { $0.id == b }?.title == "Page" && window.activeID == a,
                  "A duplicate later surface must not replace the first live surface or its active state")
        runtime.snapshots[a] = page(a, title: "Stale event snapshot")
        supplied = []
        try check(window.tabIDs.isEmpty && window.activeID == nil && runtime.currentSurface(a) == nil,
                  "Event snapshots must not authorize removed or moved tabs")
        let foreign = BrowserExtensionRuntime(owner: host, profileID: otherProfile, dataStore: .nonPersistent())
        foreign.orderedIDs = [a, b, c]
        supplied = [page(a)]
        try check(foreign.currentSurfaces().isEmpty && foreign.currentSurface(a) == nil, "Profile-specific provider boundaries must be retained")

        var lookupCalls = 0
        host.surface = { requestedProfile, id in
            lookupCalls += 1
            return requestedProfile == profile && id == b ? page(b, title: "Fresh direct lookup") : nil
        }
        calls = 0
        try check(runtime.currentSurface(b)?.title == "Fresh direct lookup" && lookupCalls == 1 && calls == 0,
                  "Single-tab lookup must consult the live resolver without enumerating other tabs")
        try check(runtime.currentSurface(a) == nil && calls == 0, "A resolver's nil result must never fall back to a stale bulk list")
        host.surface = { _, _ in page(b) }
        try check(runtime.currentSurface(a) == nil, "A malformed direct resolver must not substitute another tab's identity")
        host.surface = nil
        try check(runtime.currentSurface(a)?.id == a, "Hosts without a direct resolver must retain their live bulk fallback")

        for count in [100, 500, 1000] {
            supplied = (0..<count).map { _ in page(UUID()) }
            supplied[count - 1].isActive = true
            calls = 0
            runtime.reconcile()
            try check(calls <= 3 && runtime.tabs.count == count && window.activeID == supplied.last?.id,
                      "Reconciliation must use bounded snapshots and retain every tab at \(count) tabs")
            calls = 0
            try check(window.tabIDs.count == count && calls == 1, "Tab enumeration must take one live snapshot at \(count) tabs")
            calls = 0
            try check(window.activeID == supplied.last?.id && calls == 1, "Active-tab enumeration must take one live snapshot at \(count) tabs")
        }
        // Exercise the actual owned-context delegate methods. This inert original
        // extension has no scripts, pages, WebViews, windows, or network access.
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("bam-enumeration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try Data(#"{"manifest_version":3,"name":"Enumeration Fixture","version":"1.0","permissions":["tabs"]}"#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        let extensionObject = try await WKWebExtension(resourceBaseURL: package)
        let context = WKWebExtensionContext(for: extensionObject)
        try runtime.controller.load(context)
        defer { try? runtime.controller.unload(context) }
        var revision: UInt64 = 0
        var live: [UUID: BrowserExtensionSurface] = [:]
        host.surface = { requestedProfile, id in
            lookupCalls += 1
            return requestedProfile == profile ? live[id] : nil
        }
        host.surfaceRevision = { _ in revision }
        for count in [100, 500, 1000] {
            supplied = (0..<count).map { page(UUID(), title: "Current \($0)") }
            supplied[count - 1].isActive = true
            live = Dictionary(supplied.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            revision &+= 1
            runtime.reconcile()
            calls = 0; lookupCalls = 0
            var positionsCorrect = true, titlesCorrect = true, selectionCorrect = true
            for (index, item) in supplied.enumerated() {
                guard let adapter = runtime.tabs[item.id] else { throw Failure(message: "Missing live adapter") }
                positionsCorrect = positionsCorrect && adapter.indexInWindow(for: context) == index
                titlesCorrect = titlesCorrect && adapter.title(for: context) == item.title && adapter.url(for: context) == item.url
                selectionCorrect = selectionCorrect && adapter.isSelected(for: context) == (index == count - 1)
            }
            try check(positionsCorrect && titlesCorrect && selectionCorrect, "Owned-context enumeration returned wrong metadata/order/selection at \(count) tabs")
            try check(calls <= 1 && lookupCalls == count * 4, "Owned-context enumeration must share one topology but authorize each property live at \(count) tabs")

            let renamedID = supplied[0].id
            live[renamedID] = BrowserExtensionSurface(id: renamedID, title: "Live renamed title", url: URL(string: "https://example.invalid/changed"), webView: nil, window: nil, isPinned: true)
            try check(runtime.tabs[renamedID]!.title(for: context) == "Live renamed title"
                      && runtime.tabs[renamedID]!.url(for: context)?.path == "/changed"
                      && runtime.tabs[renamedID]!.isPinned(for: context),
                      "Cached topology must not cache live title, URL, or retention metadata")

            // Removal/profile migration is visible before event reconciliation,
            // including changed indices and rejection of the old adapter's actions.
            let removedID = supplied.removeFirst().id, lastID = supplied.last!.id
            let removedAdapter = runtime.tabs[removedID]!
            live.removeValue(forKey: removedID); revision &+= 1
            try check(removedAdapter.title(for: context) == nil && removedAdapter.indexInWindow(for: context) == NSNotFound,
                      "A cached topology must never expose a removed/profile-moved tab")
            try check(runtime.tabs[lastID]!.indexInWindow(for: context) == count - 2,
                      "Removing an earlier member must update subsequent indices before reconcile")
            var actionCalls = 0, actionErrors = 0
            host.closeTab = { _ in actionCalls += 1; return true }
            host.navigateTab = { _, _ in actionCalls += 1; return true }
            host.reloadTab = { _, _ in actionCalls += 1; return true }
            removedAdapter.close(for: context) { if $0 != nil { actionErrors += 1 } }
            removedAdapter.loadURL(URL(string: "https://example.invalid/new")!, for: context) { if $0 != nil { actionErrors += 1 } }
            removedAdapter.reload(fromOrigin: false, for: context) { if $0 != nil { actionErrors += 1 } }
            try check(actionCalls == 0 && actionErrors == 3, "A removed adapter must fail live authorization before action callbacks")

            let firstID = supplied[0].id
            for index in supplied.indices { supplied[index].isActive = index == 0 }
            live = Dictionary(supplied.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); revision &+= 1
            try check(runtime.tabs[firstID]!.isSelected(for: context) && !runtime.tabs[lastID]!.isSelected(for: context),
                      "A selection change must invalidate effective active selection before reconcile")
            for index in supplied.indices { supplied[index].isActive = false }
            live = Dictionary(supplied.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); revision &+= 1
            try check(window.activeID == firstID, "Hiding the profile must preserve its last live active member")
            supplied.removeFirst(); live.removeValue(forKey: firstID); revision &+= 1
            try check(window.activeID == supplied.first?.id, "Deleting the remembered selection must choose a surviving member")
        }
        let foreignContext = WKWebExtensionContext(for: extensionObject)
        calls = 0; lookupCalls = 0
        let ownedAdapter = runtime.tabs[supplied[0].id]!
        try check(ownedAdapter.title(for: foreignContext) == nil
                  && ownedAdapter.indexInWindow(for: foreignContext) == NSNotFound
                  && !ownedAdapter.isSelected(for: foreignContext) && calls == 0 && lookupCalls == 0,
                  "An unowned context must be rejected before any host lookup")

        func adapterIDs(_ adapters: [any WKWebExtensionTab]) -> [UUID] {
            adapters.compactMap { ($0 as? BrowserExtensionTab)?.id }
        }
        // WebKit can request the same full window array for each tab it checks.
        // Its wrappers may be reused, but their identity, order and live authority
        // must still follow changes made before event reconciliation.
        supplied = [page(a), page(b), page(c, active: true)]
        live = Dictionary(supplied.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        revision &+= 1; runtime.reconcile()
        calls = 0
        for _ in 0..<10 {
            try check(adapterIDs(window.tabs(for: context)) == [a, b, c]
                      && (window.activeTab(for: context) as? BrowserExtensionTab)?.id == c,
                      "Repeated window enumeration changed adapter order or active selection")
        }
        try check(calls <= 1, "Stable window callbacks must share their live topology snapshot")
        let originalA = runtime.tabs[a]!
        let replacement = BrowserExtensionTab(runtime: runtime, id: b)
        runtime.tabs[b] = replacement
        try check((window.tabs(for: context).first { ($0 as? BrowserExtensionTab)?.id == b } as? BrowserExtensionTab) === replacement,
                  "Replacing an adapter under an unchanged host revision must replace its cached window entry")
        runtime.tabs.removeValue(forKey: a)
        try check(adapterIDs(window.tabs(for: context)) == [b, c], "Removing an adapter must invalidate its cached window entry")
        runtime.tabs[a] = originalA
        try check(adapterIDs(window.tabs(for: context)) == [a, b, c], "Restoring a current adapter must restore its ordered window entry")
        runtime.orderedIDs = [c, b, a]
        try check(adapterIDs(window.tabs(for: context)) == [c, b, a] && originalA.indexInWindow(for: context) == 2,
                  "Reconciled order changes must invalidate the full window array and indices")

        // A host callback may replace a wrapper while a topology is being built.
        // Return the current wrapper and do not retain that changing snapshot.
        let reentrantReplacement = BrowserExtensionTab(runtime: runtime, id: b)
        var revisionReads = 0
        host.surfaceRevision = { _ in
            revisionReads += 1
            if revisionReads == 2 { runtime.tabs[b] = reentrantReplacement }
            return revision
        }
        runtime.orderedIDs = [a, b, c]
        try check((window.tabs(for: context)[1] as? BrowserExtensionTab) === reentrantReplacement,
                  "An adapter replaced by a host callback must not return the superseded wrapper")
        calls = 0
        _ = window.tabs(for: context)
        try check(calls == 1, "A topology whose wrappers changed during construction must not be retained")
        host.surfaceRevision = { _ in revision }

        supplied.removeAll { $0.id == b }; live.removeValue(forKey: b); revision &+= 1
        try check(adapterIDs(window.tabs(for: context)) == [a, c] && reentrantReplacement.title(for: context) == nil,
                  "A profile move must remove the window entry before reconciliation and deny its old wrapper")
        calls = 0; lookupCalls = 0
        try check(window.tabs(for: foreignContext).isEmpty && window.activeTab(for: foreignContext) == nil
                  && calls == 0 && lookupCalls == 0,
                  "A cached window array must not be exposed to an unowned context")

        // Unversioned/previews explicitly opt out: changing the live provider
        // without an invalidation signal must still update its window membership.
        host.surfaceRevision = { _ in nil }
        let fallbackID = supplied[0].id
        _ = window.tabs(for: context)
        supplied.removeFirst(); live.removeValue(forKey: fallbackID)
        try check(!adapterIDs(window.tabs(for: context)).contains(fallbackID), "An unversioned host must not reuse cached window adapters")

        // Even a broken host revision cannot authorize a stale tab: the cache is
        // advisory metadata, while the direct resolver remains the authority.
        host.surfaceRevision = { _ in revision }
        let revokedID = supplied[0].id
        _ = window.tabIDs
        live.removeValue(forKey: revokedID)
        try check(runtime.tabs[revokedID]!.title(for: context) == nil && runtime.tabs[revokedID]!.indexInWindow(for: context) == NSNotFound,
                  "A cached membership entry must not override fresh resolver denial")
        host.surface = nil; host.surfaceRevision = nil
        supplied = []
        runtime.reconcile()
        try check(runtime.tabs.isEmpty && runtime.windows.isEmpty && runtime.orderedIDs.isEmpty, "Closing all live tabs must clear adapters and window topology")
        host.shutdown()
        checks += try await nativeAuthority()
        print("PASS: Extension enumeration — \(checks)")
    }

    /// Original inert packages and synthetic signed-host metadata exercise the
    /// host's authority decisions. This test never executes any native helper.
    @available(macOS 15.4, *)
    static func nativeAuthority() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }; checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-native-authority-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Synthetic.app", isDirectory: true), executable = app.appendingPathComponent(ExtensionNativeMessaging.helperRelativePath)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/false\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": ExtensionNativeMessaging.applicationIdentifier], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let registration = root.appendingPathComponent(ExtensionNativeMessaging.applicationIdentifier + ".json")
        try JSONSerialization.data(withJSONObject: ["name": ExtensionNativeMessaging.applicationIdentifier, "type": "stdio",
            "path": executable.path, "allowed_origins": [ExtensionNativeMessaging.origin]]) .write(to: registration)
        let signature: ExtensionNativeMessaging.SignatureValidator = { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let isApp = path == app.resolvingSymlinksInPath().standardizedFileURL.path
            guard isApp || path == executable.resolvingSymlinksInPath().standardizedFileURL.path else { throw Failure(message: "Unexpected synthetic signature target") }
            return .init(identifier: isApp ? ExtensionNativeMessaging.applicationIdentifier : "synthetic-browser-support",
                teamIdentifier: ExtensionNativeMessaging.vendorTeamIdentifier, codeHash: isApp ? "synthetic-app" : "synthetic-host")
        }
        let policy = ExtensionNativeMessaging(searchDirectories: [root], signatureValidator: signature, browserValidator: {})
        let approved = try policy.discover()
        let verified = ExtensionNativeMessaging.chromeExtensionIdentifier
        let catalog = ExtensionCatalogRecord(source: .chromeWebStore, upstreamID: verified, listingURL: nil, downloadURL: nil,
            publisher: "Synthetic fixture", version: "1.0", sha256: "synthetic", provenance: "CRX3 signature verified for \(verified)",
            verifiedChromeExtensionID: verified, installedAt: Date())
        let profile = UUID(), otherProfile = UUID(), approvedID = UUID(), unapprovedID = UUID(), otherID = UUID()
        let granted = BrowserExtensionRecord(id: approvedID, profileID: profile, name: "Native Authority Fixture", version: "1.0", packageName: "package", enabled: true, catalog: catalog, nativeHost: approved)
        var oldText = granted; oldText.catalog?.verifiedChromeExtensionID = nil
        try check(!BrowserExtensions.supportsNativeCompanion(oldText), "Human-readable old verification text authorized desktop access")
        var wrongIdentity = granted; wrongIdentity.catalog?.verifiedChromeExtensionID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        try check(!BrowserExtensions.supportsNativeCompanion(wrongIdentity), "A different verified CRX identity authorized the 1Password companion")
        var wrongSource = granted; wrongSource.catalog?.source = .amo
        try check(!BrowserExtensions.supportsNativeCompanion(wrongSource), "A non-Chrome source authorized the Chrome companion")
        let unapproved = BrowserExtensionRecord(id: unapprovedID, profileID: profile, name: "Unapproved Fixture", version: "1.0", packageName: "package", enabled: true, catalog: catalog)
        let other = BrowserExtensionRecord(id: otherID, profileID: otherProfile, name: "Other Profile Fixture", version: "1.0", packageName: "package", enabled: true, catalog: catalog, nativeHost: approved)
        for record in [granted, unapproved, other] {
            let package = root.appendingPathComponent(record.id.uuidString).appendingPathComponent("package")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"Native Authority Fixture","description":"Original inert authority fixture","version":"1.0","permissions":["nativeMessaging"]}"#.utf8)
                .write(to: package.appendingPathComponent("manifest.json"))
        }
        try JSONEncoder().encode([granted, unapproved, other]).write(to: root.appendingPathComponent("registry.json"))
        let host = BrowserExtensions(storageURL: root)
        host.nativeMessagingPolicy = policy; host.permissionPrompt = { _ in true }; host.onReloadNeeded = nil
        defer { host.shutdown() }
        await host.prepare(profileID: profile, dataStore: .nonPersistent())
        await host.prepare(profileID: otherProfile, dataStore: .nonPersistent())
        guard let context = host.context(for: approvedID), let unapprovedContext = host.context(for: unapprovedID), let otherContext = host.context(for: otherID),
              let runtime = context.webExtensionController?.delegate as? BrowserExtensionRuntime,
              let otherRuntime = otherContext.webExtensionController?.delegate as? BrowserExtensionRuntime else {
            throw Failure(message: "Native authority fixture failed to load: \(host.errors)")
        }
        try check(runtime.approvedNativeHost(context) == approved, "Verified loaded context lost its separately reviewed host")
        try check(runtime.approvedNativeHost(unapprovedContext) == nil, "A verified package without a desktop grant gained access")
        try check(runtime.approvedNativeHost(otherContext) == nil && otherRuntime.approvedNativeHost(context) == nil && otherRuntime.approvedNativeHost(otherContext) == approved,
            "Desktop host authority crossed a profile/controller boundary")
        let foreignContext = WKWebExtensionContext(for: context.webExtension)
        foreignContext.uniqueIdentifier = context.uniqueIdentifier
        try check(runtime.approvedNativeHost(foreignContext) == nil, "Copying an approved identifier authorized an unowned context")
        context.grantedPermissions[.init(rawValue: "nativeMessaging")] = nil
        try check(runtime.approvedNativeHost(context) == nil, "Missing live nativeMessaging permission did not deny the host")
        context.grantedPermissions[.init(rawValue: "nativeMessaging")] = .distantFuture
        host.nativeHostPrompt = { _, _ in false }
        try await host.connectDesktopApp(id: unapprovedID)
        try check(runtime.approvedNativeHost(unapprovedContext) == nil && host.records.first { $0.id == unapprovedID }?.nativeHost == nil,
            "Canceling desktop review persisted a host grant")
        host.nativeHostPrompt = { _, _ in true }
        try await host.connectDesktopApp(id: unapprovedID)
        try check(runtime.approvedNativeHost(unapprovedContext) == approved, "Approved desktop review did not bind the discovered host")
        try host.disconnectDesktopApp(id: unapprovedID)
        try check(runtime.approvedNativeHost(unapprovedContext) == nil && host.records.first { $0.id == unapprovedID }?.nativeHost == nil,
            "Disconnect retained the desktop grant")
        try await host.connectDesktopApp(id: unapprovedID)
        try host.revokePermissions(id: unapprovedID)
        try check(runtime.approvedNativeHost(unapprovedContext) == nil && host.records.first { $0.id == unapprovedID }?.nativeHost == nil &&
            !unapprovedContext.hasPermission(.init(rawValue: "nativeMessaging")), "Revoking permissions retained native-app authority")
        var refusedRevokedConnection = false
        do { try await host.connectDesktopApp(id: unapprovedID) }
        catch { refusedRevokedConnection = true }
        try check(refusedRevokedConnection && host.records.first { $0.id == unapprovedID }?.nativeHost == nil,
            "Connecting after permission revocation falsely reported success or persisted a desktop grant")
        // Create a real pending runtime session, then unload synchronously before
        // its launch Task runs. The injected validator additionally forbids any
        // helper launch even if task scheduling changes in a future SDK.
        host.nativeMessagingPolicy = ExtensionNativeMessaging(searchDirectories: [root], signatureValidator: signature,
            browserValidator: { throw Failure(message: "Synthetic fixture forbids launching a native host") })
        var permissionReplies = 0, permissionReplyError: Error?
        otherRuntime.sendNative(["synthetic": true], context: otherContext) { _, error in permissionReplies += 1; permissionReplyError = error }
        try check(otherRuntime.nativeSessions.count == 1, "Permission-removal fixture did not retain its pending session")
        otherContext.grantedPermissions[.init(rawValue: "nativeMessaging")] = nil
        host.persistPermissions(otherContext)
        try check(host.records.first { $0.id == otherID }?.nativeHost == nil && otherRuntime.nativeSessions.isEmpty &&
            permissionReplies == 1 && permissionReplyError != nil && otherRuntime.approvedNativeHost(otherContext) == nil,
            "Removing WebKit nativeMessaging permission did not clear the grant and close its pending session")
        var replies = 0, replyError: Error?
        runtime.sendNative(["synthetic": true], context: context) { _, error in replies += 1; replyError = error }
        try check(runtime.nativeSessions.count == 1 && replies == 0, "Native request did not register its pending session")
        try await host.setEnabled(false, id: approvedID)
        try check(runtime.nativeSessions.isEmpty && replies == 1 && replyError != nil && runtime.approvedNativeHost(context) == nil,
            "Unloading failed to close a pending native session and reply once")
        await Task.yield()
        try check(replies == 1 && permissionReplies == 1, "Canceled native startup delivered a duplicate reply")
        host.shutdown()
        for controller in [runtime.controller, otherRuntime.controller] {
            let data = await controller.dataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes)
            await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: data)
        }
        return checks
    }
}
