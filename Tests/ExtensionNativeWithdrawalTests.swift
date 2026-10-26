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
        try check(host.restartGeneration[id, default: 0] == raceGeneration + 1 && host.isRestarting(id: id),
                  "Fixture: the panel withhold must start its restart (phase A) synchronously")
        let panelResult = await host.restartCompletion(id: id, generation: raceGeneration + 1)
        try check(panelResult == .restarted && (try current()) !== contextA, "Fixture: the panel restart must finish with a fresh context: \(String(describing: panelResult))")
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

        // MARK: Failed save AND failed unload (quarantine): says both, never "saved"; settles on a later save; Enable recovers.
        await settle()
        try await grantOptional()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registry.path)
        BrowserExtensions.siteAccessRestartUnloadFault = { $0 == id ? Failure(message: "injected unload failure") as NSError : nil }
        defer { BrowserExtensions.siteAccessRestartUnloadFault = nil }
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle()
        let quarantined = host.errors[id] ?? ""
        try check(host.context(for: id) == nil && record()?.enabled == false, "Fixture: the injected unload failure must quarantine the extension")
        try check(quarantined.contains("couldn’t save that change") && quarantined.contains("or stop it") && quarantined.contains("until you quit Bam") &&
                  !quarantined.contains("was saved") && !quarantined.contains("saved, reduced"),
                  "A failed save plus a failed unload must say both and never claim it was saved: \(quarantined)")
        BrowserExtensions.siteAccessRestartUnloadFault = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path)
        host.persistPermissions(other)
        try check(host.errors[id]?.hasPrefix("Site access was saved, but Withdrawal fixture couldn’t be stopped to apply it.") == true,
                  "Once saved, the warning must become the still-true quarantine outcome: \(host.errors[id] ?? "-")")
        try await host.setEnabled(true, id: id)
        try check(host.context(for: id) != nil && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil,
                  "Enable must stop the quarantined context and recover with the reduced access")

        // MARK: The restart's own successful save settles the unsaved state mid-call: the final text is the saved one.
        await settle()
        try await grantOptional()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registry.path)
        BrowserExtensions.siteAccessRestartLoadFault = { $0 == id ? Failure(message: "injected load failure") as NSError : nil }
        let midCall = try current()
        midCall.setPermissionStatus(.unknown, for: optionalSite)
        host.persistPermissions(midCall)                                        // detected; this save fails; restart queued
        try check(host.errors[id]?.contains("couldn’t save that change") == true, "Fixture: the detection's save must fail")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path)   // before the restart runs
        await settle()
        BrowserExtensions.siteAccessRestartLoadFault = nil
        try check(record()?.enabled == false && host.errors[id] == "Withdrawal fixture stopped and couldn’t restart after its site access changed. Enable it again in Manage Extensions.",
                  "When the helper's own save made the change durable, the final text must be the saved outcome: \(host.errors[id] ?? "-")")
        try await host.setEnabled(true, id: id)
        try check(host.context(for: id) != nil && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil, "Enable must recover")

        // MARK: Two-phase: a repeated withdrawal restarts again, each restart completing with its own generation.
        BrowserExtensions.siteAccessRestartLoadFault = nil
        try await grantOptional()
        let repeatStart = nativeRestarts, repeatGeneration = host.restartGeneration[id, default: 0]
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle()
        try await grantOptional()
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle()
        let first = await host.restartCompletion(id: id, generation: repeatGeneration + 1)
        let second = await host.restartCompletion(id: id, generation: repeatGeneration + 2)
        try check(nativeRestarts == repeatStart + 2 && host.restartGeneration[id, default: 0] == repeatGeneration + 2 && second == .restarted &&
                  (first == nil || first == .restarted || first == .superseded) && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil,
                  "Two withdrawals must restart twice, the latest completing: \(String(describing: first)), \(String(describing: second))")

        // MARK: Disable during the handoff, with an unsaved change: superseded, no fresh load, a neutral warning (no restart claim).
        try await grantOptional()
        let cancelStart = nativeRestarts
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registry.path)
        let cancelContext = try current()
        cancelContext.setPermissionStatus(.unknown, for: optionalSite)
        host.persistPermissions(cancelContext)                                  // detected; the save fails; restart queued
        var turns = 0
        while !host.isRestarting(id: id), turns < 200 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000); turns += 1 }
        try check(host.isRestarting(id: id) && nativeRestarts == cancelStart + 1, "Fixture: phase A must have run (handoff pending)")
        let cancelGeneration = host.restartGeneration[id, default: 0]
        do { try await host.setEnabled(false, id: id) } catch { /* the disable can't be saved either: read-only registry */ }
        let cancelled = await host.restartCompletion(id: id, generation: cancelGeneration)
        await settle()
        let neutral = host.errors[id] ?? ""
        try check(cancelled == .superseded && host.context(for: id) == nil && !host.isRestarting(id: id),
                  "Disable during the handoff must cancel it without loading: \(String(describing: cancelled))")
        try check(neutral.contains("couldn’t save that change") && neutral.contains("Until it’s saved") && !neutral.contains("restarted it"),
                  "A cancelled restart's unsaved warning must make no restart claim: \(neutral)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path)
        try await host.setEnabled(true, id: id)
        await settle()
        try check(host.context(for: id) != nil && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil, "Enable must recover with the reduced access")

        // MARK: Fail closed: an old view still alive at the deadline means no fresh load, the extension stays off.
        let savedDeadline = BrowserExtensions.siteAccessRestartReleaseDeadline
        BrowserExtensions.siteAccessRestartReleaseDeadline = 0.3
        defer { BrowserExtensions.siteAccessRestartReleaseDeadline = savedDeadline }
        var held: WKWebView? = WKWebView(frame: .zero)
        host.onExtensionRenderers = { phase, _, _ in phase == .retire ? [RetiredRendererProbe(held)] : [] }
        try await grantOptional()
        let timeoutStart = nativeRestarts, timeoutGeneration = host.restartGeneration[id, default: 0]
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle(1.2)
        let timedOut = await host.restartCompletion(id: id, generation: timeoutGeneration + 1)
        guard case .releaseTimedOut(let failure)? = timedOut else { throw Failure(message: "Expected releaseTimedOut, got \(String(describing: timedOut))") }
        try check(nativeRestarts == timeoutStart + 1 && host.context(for: id) == nil && record()?.enabled == false && host.errors[id] == failure,
                  "A held old view must fail closed: no fresh load, turned off, the helper's message: \(host.errors[id] ?? "-")")
        held = nil
        try await host.setEnabled(true, id: id)
        await settle()
        try check(host.context(for: id) != nil && (try current()).grantedPermissionMatchPatterns[optionalSite] == nil, "Once released, Enable must load with the reduced access")

        // MARK: Fail closed with the change unsaved: says it stays off and wasn't saved, never "saved"; a later save gives the saved wording.
        held = WKWebView(frame: .zero)
        try await grantOptional()
        let unsavedTimeoutGeneration = host.restartGeneration[id, default: 0]
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registry.path)
        (try current()).setPermissionStatus(.unknown, for: optionalSite)
        await settle(1.2)
        let unsavedTimedOut = await host.restartCompletion(id: id, generation: unsavedTimeoutGeneration + 1)
        let unsavedText = host.errors[id] ?? ""
        guard case .releaseTimedOut(let savedWording)? = unsavedTimedOut else { throw Failure(message: "Expected releaseTimedOut, got \(String(describing: unsavedTimedOut))") }
        try check(unsavedText.contains("off for now") && !unsavedText.contains("stays off") && unsavedText.contains("couldn’t save") &&
                  !unsavedText.contains("was saved") && host.context(for: id) == nil,
                  "An unsaved fail-closed restart must say it's off for now and wasn't saved, never that it stays off: \(unsavedText)")
        try check(savedWording.contains("couldn’t save that it’s off"), "Fixture: the helper's own message must carry its failed disable save: \(savedWording)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registry.path)
        host.persistPermissions(other)
        let durable = host.errors[id] ?? ""
        try check(durable == BrowserExtensions.releaseTimeoutMessage(name: "Withdrawal fixture", disableSaveError: nil, accessSaved: true),
                  "Once saved, the warning must be the durable fail-closed message: \(durable)")
        try check(durable.contains("stays off") && !durable.contains("couldn’t save") && !durable.contains("may load again") &&
                  !durable.contains("broader") && !durable.contains("last saved"),
                  "The durable message must not keep the obsolete save-failure or relaunch-risk language: \(durable)")
        held = nil; host.onExtensionRenderers = nil
        try await host.setEnabled(true, id: id)
        await settle()
        try check(host.context(for: id) != nil, "Recovery after release")
        return checks
    }
}
