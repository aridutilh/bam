import Foundation
import WebKit

/// Exercises the actual adapters without creating windows, renderers or extension processes.
@main @MainActor enum BrowserExtensionEnumerationTests {
    struct Failure: Error { let message: String }
    static func main() throws {
        guard #available(macOS 15.4, *) else { print("SKIP: Extension enumeration requires macOS 15.4"); return }
        try run()
    }
    @available(macOS 15.4, *)
    static func run() throws {
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
        supplied = []
        runtime.reconcile()
        try check(runtime.tabs.isEmpty && runtime.windows.isEmpty && runtime.orderedIDs.isEmpty, "Closing all live tabs must clear adapters and window topology")
        host.shutdown()
        print("PASS: Extension enumeration — \(checks)")
    }
}
