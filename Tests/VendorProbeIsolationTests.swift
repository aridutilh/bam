import Foundation

/// Pure checks of the vendor probe's normal-profile rules: identities, mode and app guard,
/// incognito verdict, and bounded confirmed removal of exactly one owned store.
@main enum VendorProbeIsolationTests {
    nonisolated(unsafe) static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        guard ok else { fputs("FAIL: Vendor probe isolation — \(message)\n", stderr); exit(1) }
        checks += 1
    }
    typealias I = VendorProbeIsolation

    /// Records every identifier `remove` is asked for; scripted outcomes per call.
    final class FakeStores: @unchecked Sendable {
        private let lock = NSLock()
        var outcomes: [String?] = []          // per remove call; "never" means no callback
        var listing: [UUID]? = []              // nil means list never answers
        var present: Set<UUID>
        private(set) var removeCalls: [UUID] = []
        init(present: Set<UUID>) { self.present = present }
        func remove(_ id: UUID, _ done: @escaping (String?) -> Void) {
            lock.lock(); removeCalls.append(id)
            let outcome = outcomes.isEmpty ? nil : outcomes.removeFirst()
            if outcome == nil { present.remove(id) }
            lock.unlock()
            if outcome == "never" { return }
            DispatchQueue.global().async { done(outcome) }
        }
        func list(_ done: @escaping ([UUID]) -> Void) {
            lock.lock(); let snapshot = listing == nil ? nil : Array(present); lock.unlock()
            guard let snapshot else { return }
            DispatchQueue.global().async { done(snapshot) }
        }
    }

    static func cleanup(_ fake: FakeStores, store: UUID, reserved: Set<UUID> = []) async -> I.CleanupResult {
        await I.removeOwnedStore(store, reserved: reserved, remove: fake.remove, list: fake.list, timeout: 0.3, retryDelay: 0.05)
    }

    static func main() async {
        let defaultProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let previewStore = UUID(uuidString: "D3E83D79-9B31-4C32-83CD-3A6C06BDF593")!
        let reserved: Set<UUID> = [defaultProfile, previewStore]

        // Mode and app identity.
        check(I.mode(nil) == .private && I.mode("normal") == .normal && I.mode(" Normal ") == .normal && I.mode("private") == .private,
              "absent means private; normal and private parse")
        check(I.mode("incognito") == nil && I.mode("") == nil, "unknown modes are refused")
        check(I.allowsNormalMode(bundleIdentifier: "com.ari.bam.preview") && !I.allowsNormalMode(bundleIdentifier: "com.ari.orbitprototype")
              && !I.allowsNormalMode(bundleIdentifier: nil), "normal mode only in canonical Bam Preview")

        // Identities: never reserved or zero, pairwise distinct, even if the generator offers them first.
        var offered = [previewStore, defaultProfile, I.zero, previewStore]
        let a = UUID(), b = UUID(), c = UUID()
        offered += [a, a, b, c]
        let ids = I.makeIdentities(reserved: reserved, generate: { offered.isEmpty ? UUID() : offered.removeFirst() })
        check(ids == I.Identities(run: a, profile: b, store: c), "reserved, zero and repeated identifiers are skipped")
        check(I.makeIdentities(reserved: reserved, generate: { previewStore }) == nil, "a generator that only yields reserved IDs gives none")
        let fresh = I.makeIdentities(reserved: reserved)!
        check(Set([fresh.run, fresh.profile, fresh.store]).count == 3 && reserved.isDisjoint(with: [fresh.run, fresh.profile, fresh.store]),
              "real identities are distinct and unreserved")

        // Verdict.
        let store = UUID()
        let clean = I.IncognitoMeasurement(inIncognitoContext: false, allowedIncognitoAccess: false, windowIncognito: [false], tabIncognito: [false, false])
        check(I.verdict([clean], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) == .normal,
              "all surfaces not incognito, non-persistent controller, only the owned store → normal")
        var context = clean; context.inIncognitoContext = true
        if case .notNormal = I.verdict([clean, context], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else { check(false, "inIncognitoContext true in any document → not normal") }
        checks += 1
        var windows = clean; windows.windowIncognito = [false, true]
        if case .notNormal = I.verdict([windows], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else { check(false, "an incognito window → not normal") }
        checks += 1
        var access = clean; access.allowedIncognitoAccess = true
        if case .notNormal = I.verdict([access], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else { check(false, "private-data access → not normal") }
        checks += 1
        if case .notNormal = I.verdict([clean], controllerConfigurationPersistent: true, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else { check(false, "persistent controller configuration → not normal") }
        checks += 1
        if case .notNormal = I.verdict([clean], controllerConfigurationPersistent: false, openedStores: [store, UUID()], expectedStore: store, refusedProfiles: []) {} else { check(false, "any extra persistent store → not normal") }
        checks += 1
        if case .notNormal = I.verdict([clean], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: [defaultProfile]) {} else { check(false, "a refused profile request → not normal") }
        checks += 1
        var partial = clean; partial.tabIncognito = nil
        if case .unmeasured = I.verdict([partial], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else { check(false, "an incomplete measurement → unmeasured") }
        checks += 1
        if case .unmeasured = I.verdict([], controllerConfigurationPersistent: nil, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else { check(false, "no runtime → unmeasured") }
        checks += 1
        check(I.measurement(from: ["state": "done", "inIncognitoContext": false, "allowedIncognitoAccess": false,
                                   "windowIncognito": [false], "tabIncognito": [false]]) == clean.with(tabs: [false]),
              "the script's result object parses")
        check(I.measurement(from: ["state": "started"]) == nil && I.measurement(from: "x") == nil, "an unfinished or foreign result is not a measurement")

        // Cleanup.
        let owned = UUID(), other = UUID()
        var fake = FakeStores(present: [owned, other])
        var result = await cleanup(fake, store: owned)
        check(result.removed && result.attempts == 1 && fake.removeCalls == [owned], "success removes only the owned store, confirmed by the list")
        check(fake.present == [other], "the other store is untouched")

        fake = FakeStores(present: [owned]); fake.outcomes = ["busy", nil]
        result = await cleanup(fake, store: owned)
        check(result.removed && result.attempts == 2 && result.removalError == nil && fake.removeCalls == [owned, owned], "one retry after an error")

        fake = FakeStores(present: [owned]); fake.outcomes = ["busy", "busy"]
        result = await cleanup(fake, store: owned)
        check(!result.removed && result.attempts == 2 && result.removalError == "busy" && !result.confirmedAbsent, "a persistent error is reported, not removed")

        fake = FakeStores(present: [owned]); fake.outcomes = ["never", "never"]
        let started = Date()
        result = await cleanup(fake, store: owned)
        check(result.removalTimedOut && !result.confirmedAbsent && Date().timeIntervalSince(started) < 2, "a removal that never answers times out, bounded")

        fake = FakeStores(present: [owned]); fake.outcomes = ["never"]   // late success via the retry
        result = await cleanup(fake, store: owned)
        check(result.removed && result.attempts == 2, "a timed-out first attempt can be completed by the retry")

        fake = FakeStores(present: [owned]); fake.listing = nil
        result = await cleanup(fake, store: owned)
        check(!result.removed && !result.confirmedAbsent, "an unanswered list means removal is not confirmed")

        fake = FakeStores(present: [previewStore])
        result = await cleanup(fake, store: previewStore, reserved: reserved)
        check(result.refused != nil && !result.removed && fake.removeCalls.isEmpty, "a reserved identifier is refused without calling remove")
        result = await cleanup(fake, store: I.zero, reserved: reserved)
        check(result.refused != nil && fake.removeCalls.isEmpty, "the zero identifier is refused")

        // Bounded: late callbacks are ignored, first value wins.
        let late: Int? = await I.bounded(0.1) { done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { done(1) } }
        check(late == nil, "a late callback is ignored after the bound")
        let first: Int? = await I.bounded(1) { done in done(1); done(2) }
        check(first == 1, "only the first callback value is delivered")

        print("PASS: Vendor probe isolation — \(checks) checks")
    }
}

private extension VendorProbeIsolation.IncognitoMeasurement {
    func with(tabs: [Bool]) -> Self { var copy = self; copy.tabIncognito = tabs; return copy }
}
