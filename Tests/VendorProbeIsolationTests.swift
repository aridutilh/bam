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
        check(I.measurement(from: "x") == nil, "a non-object result is not a measurement")
        check(I.measurement(from: ["state": "started", "inIncognitoContext": false])?.complete == false,
              "an unfinished document is an incomplete sample, not dropped")

        // Strict booleans, as the probe receives them (JSON text from the extension document).
        func parsed(_ json: String) -> I.IncognitoMeasurement? {
            I.measurement(from: try? JSONSerialization.jsonObject(with: Data(json.utf8)))
        }
        let explicit = parsed(#"{"state":"done","inIncognitoContext":false,"allowedIncognitoAccess":false,"windowIncognito":[false,false],"tabIncognito":[false]}"#)
        check(explicit?.complete == true && explicit?.saysIncognito == false, "explicit JSON booleans make a complete, non-incognito sample")
        check(parsed(#"{"state":"done","inIncognitoContext":false,"allowedIncognitoAccess":false,"windowIncognito":[null],"tabIncognito":[false]}"#)?.complete == false,
              "a window without an explicit incognito boolean is incomplete, not false")
        check(parsed(#"{"state":"done","inIncognitoContext":false,"allowedIncognitoAccess":false,"windowIncognito":[false,null],"tabIncognito":[false]}"#)?.windowIncognito == nil,
              "one missing element voids the whole window list")
        check(parsed(#"{"state":"done","inIncognitoContext":0,"allowedIncognitoAccess":false,"windowIncognito":[false],"tabIncognito":[1]}"#).map { $0.inIncognitoContext == nil && $0.tabIncognito == nil } == true,
              "0 and 1 are not booleans")
        check(I.strictBool(true) == true && I.strictBool(false) == false && I.strictBool(1) == nil && I.strictBool("true") == nil && I.strictBool(nil) == nil,
              "strictBool accepts only booleans")
        let incomplete = parsed(#"{"state":"done","inIncognitoContext":false,"allowedIncognitoAccess":false,"windowIncognito":[null],"tabIncognito":[false]}"#)!
        if case .unmeasured = I.verdict([clean, incomplete], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else {
            check(false, "one complete document beside an incomplete one is unmeasured, never normal")
        }
        checks += 1
        if case .unmeasured = I.verdict([clean, I.IncognitoMeasurement(finished: false)], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else {
            check(false, "an unfinished document beside a complete one is unmeasured")
        }
        checks += 1
        var marked = incomplete; marked.inIncognitoContext = true
        if case .notNormal = I.verdict([clean, marked], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: []) {} else {
            check(false, "explicit incognito evidence is not normal even in an incomplete sample")
        }
        checks += 1

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

        // Release gate: removal never runs while anything still holds the store.
        fake = FakeStores(present: [store])
        var gated = await I.removeOwnedStoreAfterRelease(store, reserved: reserved, isReleased: { false }, releaseTimeout: 0.2, pollInterval: 0.02,
                                                         remove: fake.remove, list: fake.list, timeout: 0.3, retryDelay: 0.05)
        check(!gated.released && gated.removal == nil && !gated.clean && fake.removeCalls.isEmpty && fake.present.contains(store),
              "release never happens: no removal call, not clean, even though remove/list would have succeeded")
        fake = FakeStores(present: [store])
        let releaseAt = Date().addingTimeInterval(0.1)
        gated = await I.removeOwnedStoreAfterRelease(store, reserved: reserved, isReleased: { Date() >= releaseAt }, releaseTimeout: 2, pollInterval: 0.02,
                                                     remove: fake.remove, list: fake.list, timeout: 0.3, retryDelay: 0.05)
        check(gated.released && gated.clean && fake.removeCalls == [store], "a late release is waited for, then only the owned store is removed")
        fake = FakeStores(present: [store]); fake.outcomes = ["busy", "busy"]
        gated = await I.removeOwnedStoreAfterRelease(store, reserved: reserved, isReleased: { true }, releaseTimeout: 1, pollInterval: 0.02,
                                                     remove: fake.remove, list: fake.list, timeout: 0.3, retryDelay: 0.05)
        check(gated.released && gated.removal?.attempts == 2 && !gated.clean, "released but the store still listed is not clean")

        // Stable document identity across rounds.
        func doc(_ id: String?, _ json: String) -> Any? {
            var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            if let id { object["doc"] = id }
            return object
        }
        let good = #"{"state":"done","inIncognitoContext":false,"allowedIncognitoAccess":false,"windowIncognito":[false],"tabIncognito":[false]}"#
        let privateOne = #"{"state":"done","inIncognitoContext":true,"allowedIncognitoAccess":false,"windowIncognito":[true],"tabIncognito":[true]}"#
        let unfinishedJSON = #"{"state":"started","inIncognitoContext":false}"#
        func roundVerdict(_ rounds: [[Any?]]) -> I.Verdict {
            I.verdict(rounds: rounds, controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: [])
        }
        check(roundVerdict([[doc("a", unfinishedJSON), doc("b", unfinishedJSON)], [doc("b", good), doc("a", good)]]) == .normal,
              "documents reordered between rounds still match by ID; all ended complete → normal")
        let swapped = I.documents(fromRounds: [[doc("a", privateOne), doc("b", good)], [doc("b", good), doc("a", good)]])
        check(swapped.count == 2 && swapped.first(where: { $0.id == "a" })?.firstIncognito != nil && swapped.first(where: { $0.id == "b" })?.firstIncognito == nil,
              "a reorder does not move one document's private answer onto another")
        if case .notNormal = roundVerdict([[doc("a", privateOne), doc("b", good)], [doc("b", good), doc("a", good)]]) {} else {
            check(false, "an earlier private answer is retained even after the document later answers normally")
        }
        checks += 1
        if case .notNormal = roundVerdict([[doc("a", good), doc("p", privateOne)], [doc("a", good)]]) {} else {
            check(false, "a private answer from a document that has since closed is retained")
        }
        checks += 1
        if case .unmeasured = roundVerdict([[doc("a", good), doc("c", unfinishedJSON)], [doc("a", good)]]) {} else {
            check(false, "a document that closed before answering completely leaves the run unmeasured")
        }
        checks += 1
        if case .unmeasured = roundVerdict([[doc(nil, good)], [doc(nil, good)], ["not an object"]]) {} else {
            check(false, "results without a document ID never merge; an unreadable one is an unfinished document")
        }
        checks += 1
        check(I.documents(fromRounds: [[doc(nil, good)], [doc(nil, good)]]).count == 2, "unidentified results are separate documents")
        check(roundVerdict([]) == .unmeasured("no extension document was measured"), "no rounds is unmeasured")

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
