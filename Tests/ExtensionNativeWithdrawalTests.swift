import Foundation
import WebKit

/// Native host withdrawal → restart (work/native-host-withdrawal-restart-contract.md), in-process on real loaded contexts
/// with WebKit's own permission notifications (non-persistent controller and store; no windows or app).
/// Removals use `setPermissionStatus(.unknown, for:)`, WebKit's removal and notification path. That is component
/// evidence for Bam's handling, not proof of what a real JavaScript `permissions.remove` call does natively (root's
/// native acceptance covers that). After every withdrawal the context is re-read: a restart replaces it.
@main @MainActor enum ExtensionNativeWithdrawalTests {
    struct Failure: Error { let message: String }
    static func main() async {
        guard #available(macOS 15.4, *) else { print("SKIP: extensions need macOS 15.4"); return }
        do { print("PASS: native host withdrawal (\(try await run()) checks)") }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @available(macOS 15.4, *)
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }
        func settle(_ seconds: Double = 0.5) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-native-withdrawal-\(UUID().uuidString)", isDirectory: true)
        let registry = root.appendingPathComponent("Extensions", isDirectory: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path); try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "name": "Withdrawal fixture", "version": "1.0", "description": "Original",
            "permissions": ["tabs"], "host_permissions": ["http://127.0.0.1/*"], "optional_host_permissions": ["http://localhost/*"]
        ]).write(to: package.appendingPathComponent("manifest.json"))

        let host = BrowserExtensions(storageURL: registry, controllerStorage: .nonPersistent)
        defer { host.shutdown(); BrowserExtensions.nativeWithdrawalRestartHook = nil }
        host.permissionPrompt = { _ in true }
        let profile = UUID()
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        host.configure(configuration, profileID: profile); await host.ready(profileID: profile)
        let id = try await host.importPackage(at: package, profileID: profile)
        var nativeRestarts = 0
        BrowserExtensions.nativeWithdrawalRestartHook = { if $0 == id { nativeRestarts += 1 } }
        let optionalSite = try WKWebExtension.MatchPattern(string: "http://localhost/*")
        let requested = "http://127.0.0.1/*", optionalURL = URL(string: "http://localhost/page")!
        func current() throws -> WKWebExtensionContext {
            guard let context = host.context(for: id) else { throw Failure(message: "No current context: \(host.errors[id] ?? "-")") }
            return context
        }
        func record() -> BrowserExtensionRecord? { host.records.first { $0.id == id } }
        func grantOptional() async throws {
            let context = try current()
            guard let runtime = context.webExtensionController?.delegate as? BrowserExtensionRuntime, let controller = context.webExtensionController else {
                throw Failure(message: "No runtime")
            }
            var granted: Set<WKWebExtension.MatchPattern>?
            runtime.webExtensionController(controller, promptForPermissionMatchPatterns: [optionalSite], in: nil, for: context) { value, _ in granted = value }
            await settle()
            try check(granted == [optionalSite] && host.siteAccess(id: id)?.state.optionalGrants == [optionalSite.string], "Fixture: the optional site must be granted explicitly")
        }

        // MARK: Granting is not a withdrawal.
        try await grantOptional()
        try check(nativeRestarts == 0, "Granting access must not restart")

        // MARK: WebKit-side removal: one deferred restart; the stored choice and the live context are reduced; nothing regranted.
        let generation = host.restartGeneration[id, default: 0]
        let before = try current()
        before.setPermissionStatus(.unknown, for: optionalSite)
        await settle()
        let after = try current()
        try check(nativeRestarts == 1 && host.restartGeneration[id, default: 0] == generation + 1, "A WebKit-side removal must restart exactly once")
        try check(host.siteAccess(id: id)?.state.optionalGrants.isEmpty == true && record()?.patterns[optionalSite.string] == nil &&
                  after.grantedPermissionMatchPatterns[optionalSite] == nil && after.permissionStatus(for: optionalURL) != .grantedExplicitly,
                  "The removed site must stay removed in the record and the live context")
        try check(record()?.patterns[requested] != nil && record()?.deniedPatterns.isEmpty == true, "Other grants and denials must be exactly kept")
        await settle()
        try check(nativeRestarts == 1, "The restart's own reload must not trigger another restart")

        // MARK: Finite expiry: kept exactly (never extended), then a restart once it lapses.
        let expiring = try current()
        expiring.setPermissionStatus(.grantedExplicitly, for: optionalSite, expirationDate: Date(timeIntervalSinceNow: 1.5))
        host.persistPermissions(expiring)
        let liveExpiry = expiring.grantedPermissionMatchPatterns[optionalSite]
        try check(liveExpiry != nil && record()?.timedOptionalSiteGrants?[optionalSite.string] == liveExpiry && record()?.patterns[optionalSite.string] == liveExpiry,
                  "A finite grant must be stored with WebKit's own expiry, never extended")
        try check(nativeRestarts == 1, "A finite grant is not a withdrawal")
        await settle(3.2)
        try check(nativeRestarts == 2 && record()?.timedOptionalSiteGrants?[optionalSite.string] == nil &&
                  (try current()).grantedPermissionMatchPatterns[optionalSite] == nil, "A lapsed grant must be withdrawn with a restart")

        // MARK: No echo from Bam's own withdrawals (panel withhold restarts in its own path).
        guard let snapshot = host.siteAccess(id: id), let declarations = snapshot.declarations else { throw Failure(message: "No snapshot") }
        let panelGeneration = host.restartGeneration[id, default: 0]
        _ = try host.performSiteAccess(id: id, profileID: profile, revision: snapshot.revision, displayed: declarations, change: .choose(.withheld))
        await settle()
        try check(nativeRestarts == 2 && host.restartGeneration[id, default: 0] == panelGeneration + 1,
                  "A panel withhold must restart once, in its own path, and not again from native detection")
        guard let withheld = host.siteAccess(id: id) else { throw Failure(message: "No snapshot after withhold") }
        _ = try host.performSiteAccess(id: id, profileID: profile, revision: withheld.revision, displayed: declarations, change: .choose(.allRequested))
        await settle()

        // MARK: Native withdrawal A, then a panel restart before A's task runs, then native withdrawal B on the fresh
        // context. The panel restart covers A, but not B: B must still restart.
        try await grantOptional()
        let restartsBeforeRace = nativeRestarts
        let contextA = try current()
        contextA.setPermissionStatus(.unknown, for: optionalSite)
        host.persistPermissions(contextA)                                    // A detected and queued (not yet run)
        guard let raceSnapshot = host.siteAccess(id: id), let raceDeclarations = raceSnapshot.declarations else { throw Failure(message: "No snapshot for the race") }
        let raceGeneration = host.restartGeneration[id, default: 0]
        _ = try host.performSiteAccess(id: id, profileID: profile, revision: raceSnapshot.revision, displayed: raceDeclarations, change: .choose(.withheld))
        try check(host.restartGeneration[id, default: 0] == raceGeneration + 1 && (try current()) !== contextA,
                  "Fixture: the panel withhold must restart synchronously, with a fresh context")
        let contextB = try current()
        contextB.setPermissionStatus(.grantedExplicitly, for: optionalSite, expirationDate: Date(timeIntervalSinceNow: 600))
        host.persistPermissions(contextB)                                    // recorded as a time-limited optional grant
        try check(record()?.patterns[optionalSite.string] != nil, "Fixture: B's grant must be recorded before it's withdrawn")
        contextB.setPermissionStatus(.unknown, for: optionalSite)
        host.persistPermissions(contextB)                                    // B detected while A's task is still queued
        await settle()
        try check(nativeRestarts == restartsBeforeRace + 1 && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil,
                  "A withdrawal after a panel restart must get its own restart, even while an older one was queued: restarts=\(nativeRestarts - restartsBeforeRace)")
        await settle()
        try check(nativeRestarts == restartsBeforeRace + 1, "The race must not produce extra restarts")
        guard let afterRace = host.siteAccess(id: id) else { throw Failure(message: "No snapshot after the race") }
        _ = try host.performSiteAccess(id: id, profileID: profile, revision: afterRace.revision, displayed: raceDeclarations, change: .choose(.allRequested))
        await settle()

        // MARK: A withdrawal detected while the extension is disabled stays pending and runs after Enable.
        try await grantOptional()
        let restartsBeforeDisable = nativeRestarts
        let pendingContext = try current()
        pendingContext.setPermissionStatus(.unknown, for: optionalSite)
        host.persistPermissions(pendingContext)
        try await host.setEnabled(false, id: id)
        await settle()
        try check(nativeRestarts == restartsBeforeDisable, "A disabled extension can't restart; the withdrawal must wait")
        try await host.setEnabled(true, id: id)
        await settle()
        try check(nativeRestarts == restartsBeforeDisable + 1 && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil,
                  "A pending withdrawal must not be lost: it must restart after Enable")

        // MARK: Save failure fails closed: the restart still removes live access, and the error explains what wasn't saved.
        try await grantOptional()
        let restartsBeforeSaveFailure = nativeRestarts
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registry.path)
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle()
        try check(nativeRestarts == restartsBeforeSaveFailure + 1 && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil,
                  "An unsaved withdrawal must still restart without the access")
        try check(host.errors[id]?.contains("restarted it without that access, but couldn’t save the change") == true,
                  "After a successful restart the error must say it restarted but wasn't saved: \(host.errors[id] ?? "-")")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path)
        host.persistPermissions(try current())
        try check(host.errors[id] == nil, "A later successful save must clear the unsaved-withdrawal warning: \(host.errors[id] ?? "-")")

        // MARK: Failed save AND failed restart: the message states both, never "saved", and stays until any save succeeds.
        let otherID = try await host.importPackage(at: package, profileID: profile)   // a second extension, for an unrelated save
        try await grantOptional()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registry.path)
        BrowserExtensions.siteAccessRestartLoadFault = { $0 == id ? Failure(message: "injected load failure") as NSError : nil }
        defer { BrowserExtensions.siteAccessRestartLoadFault = nil }
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle()
        let combined = host.errors[id] ?? ""
        try check(host.context(for: id) == nil && record()?.enabled == false, "Fixture: the injected load failure must stop the extension")
        try check(combined.contains("stopped because it couldn’t restart") && combined.contains("couldn’t save that change") &&
                  !combined.contains("was saved") && !combined.contains("saved, reduced"),
                  "A failed save plus a failed restart must say both and never claim it was saved: \(combined)")
        if let other = host.context(for: otherID) { host.persistPermissions(other) }        // still read-only: the warning stays
        try check(host.errors[id] == combined, "The warning must stay while saving still fails")
        BrowserExtensions.siteAccessRestartLoadFault = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path)
        guard let other = host.context(for: otherID) else { throw Failure(message: "No second extension") }
        host.persistPermissions(other)                                                      // an unrelated, successful full save
        try check(host.errors[id] == "Withdrawal fixture stopped and couldn’t restart after its site access changed. Enable it again in Manage Extensions.",
                  "Any successful registry save must replace the warning with the outcome that's still true: \(host.errors[id] ?? "-")")
        try await host.setEnabled(true, id: id)
        try check(host.context(for: id) != nil && host.errors[id] == nil && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil,
                  "Enable must recover with the reduced access")
        return checks
    }
}
