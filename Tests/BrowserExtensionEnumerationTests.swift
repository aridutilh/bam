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
        print("PASS: Extension enumeration — \(checks)")
    }
}
