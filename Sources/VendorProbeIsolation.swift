import Foundation

/// Pure rules for the vendor probe's opt-in normal-profile mode. Nothing here touches WebKit
/// directly: store removal and listing are injected, so every rule is testable without an app.
enum VendorProbeIsolation {
    /// Normal mode runs only inside the canonical development app.
    static let canonicalPreviewBundleIdentifier = "com.ari.bam.preview"

    enum Mode: String, Equatable { case `private`, normal }
    /// `BAM_VENDOR_PROFILE`: absent means today's private mode; anything unknown is refused (nil).
    static func mode(_ raw: String?) -> Mode? {
        guard let raw else { return .private }
        return Mode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
    static func allowsNormalMode(bundleIdentifier: String?) -> Bool { bundleIdentifier == canonicalPreviewBundleIdentifier }

    /// A run's own identifiers: fresh random UUIDs, pairwise distinct, never a reserved one.
    struct Identities: Equatable {
        let run: UUID, profile: UUID, store: UUID
    }
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static func makeIdentities(reserved: Set<UUID>, generate: () -> UUID = UUID.init) -> Identities? {
        let refused = reserved.union([zero])
        var taken = Set<UUID>()
        func next() -> UUID? {
            for _ in 0..<16 {
                let id = generate()
                if !refused.contains(id), taken.insert(id).inserted { return id }
            }
            return nil
        }
        guard let run = next(), let profile = next(), let store = next() else { return nil }
        return Identities(run: run, profile: profile, store: store)
    }

    // MARK: Mode validity

    /// One extension document's answers to the incognito questions. A field is nil unless the
    /// document returned an explicit boolean for it (for a list: for every element).
    struct IncognitoMeasurement: Equatable {
        var finished = true
        var inIncognitoContext: Bool?
        var allowedIncognitoAccess: Bool?
        var windowIncognito: [Bool]?
        var tabIncognito: [Bool]?
        var complete: Bool {
            finished && inIncognitoContext != nil && allowedIncognitoAccess != nil
                && windowIncognito?.isEmpty == false && tabIncognito?.isEmpty == false
        }
        var saysIncognito: Bool {
            inIncognitoContext == true || allowedIncognitoAccess == true
                || windowIncognito?.contains(true) == true || tabIncognito?.contains(true) == true
        }
    }
    /// A JSON boolean only. NSNumber 0/1 and strings are not booleans (`as? Bool` would accept 0/1).
    static func strictBool(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return (value as? Bool)
    }
    /// A list of JSON booleans, or nil if it isn't a list or any element is not a boolean.
    static func strictBools(_ value: Any?) -> [Bool]? {
        guard let list = value as? [Any] else { return nil }
        let flags = list.compactMap(strictBool)
        return flags.count == list.count ? flags : nil
    }
    /// Reads one document's result object (see `measurementScript`). An unfinished document is an
    /// incomplete sample, never omitted; only a non-object gives nil.
    static func measurement(from value: Any?) -> IncognitoMeasurement? {
        guard let object = value as? [String: Any] else { return nil }
        return IncognitoMeasurement(finished: object["state"] as? String == "done",
                                    inIncognitoContext: strictBool(object["inIncognitoContext"]),
                                    allowedIncognitoAccess: strictBool(object["allowedIncognitoAccess"]),
                                    windowIncognito: strictBools(object["windowIncognito"]), tabIncognito: strictBools(object["tabIncognito"]))
    }
    enum Verdict: Equatable {
        /// Every measured surface says not incognito and the controller writes nothing to disk.
        case normal
        /// Something reports private browsing, or storage isn't the required kind; the run is not a normal-profile observation.
        case notNormal(String)
        /// Nothing complete was measured, so the mode can't be claimed.
        case unmeasured(String)
    }
    /// Everything observed for one extension document across all evaluation rounds.
    struct DocumentEvidence: Equatable {
        /// The document's own random ID (set once by `measurementScript`), or a unique placeholder for a
        /// result without one, which therefore never merges with another result.
        let id: String
        var samples = 0
        /// The document's most recent answers; must be complete for a normal verdict.
        var latest: IncognitoMeasurement
        /// The first answer that reported private browsing, kept even if later answers differ.
        var firstIncognito: IncognitoMeasurement?
    }
    /// Groups rounds of results (one entry per live document per round, in any order) by document ID.
    /// Order within a round never matters; a document that has closed keeps its evidence.
    static func documents(fromRounds rounds: [[Any?]]) -> [DocumentEvidence] {
        var order: [String] = [], byID: [String: DocumentEvidence] = [:]
        for (r, round) in rounds.enumerated() {
            for (i, raw) in round.enumerated() {
                let sample = measurement(from: raw) ?? IncognitoMeasurement(finished: false)
                let given = ((raw as? [String: Any])?["doc"] as? String).flatMap { $0.isEmpty || $0.count > 64 ? nil : $0 }
                let id = given ?? "unidentified-\(r + 1)-\(i + 1)"
                var evidence = byID[id] ?? { order.append(id); return DocumentEvidence(id: id, latest: sample) }()
                evidence.samples += 1
                evidence.latest = sample
                if sample.saysIncognito, evidence.firstIncognito == nil { evidence.firstIncognito = sample }
                byID[id] = evidence
            }
        }
        return order.compactMap { byID[$0] }
    }
    /// The run-level verdict from every round: any document that ever reported private browsing makes it not
    /// normal; otherwise every document ever seen must have ended with complete explicit answers.
    static func verdict(rounds: [[Any?]], controllerConfigurationPersistent: Bool?,
                        openedStores: [UUID], expectedStore: UUID, refusedProfiles: [UUID]) -> Verdict {
        let docs = documents(fromRounds: rounds)
        if let doc = docs.first(where: { $0.firstIncognito != nil }), let marked = doc.firstIncognito {
            return .notNormal("an extension document reported private browsing during the run (inIncognitoContext \(String(describing: marked.inIncognitoContext)), allowedIncognitoAccess \(String(describing: marked.allowedIncognitoAccess)), windows \(marked.windowIncognito ?? []), tabs \(marked.tabIncognito ?? []))")
        }
        return verdict(docs.map(\.latest), controllerConfigurationPersistent: controllerConfigurationPersistent,
                       openedStores: openedStores, expectedStore: expectedStore, refusedProfiles: refusedProfiles)
    }
    /// `samples`: one entry per document, all of which must be complete with explicit answers.
    static func verdict(_ samples: [IncognitoMeasurement], controllerConfigurationPersistent: Bool?,
                        openedStores: [UUID], expectedStore: UUID, refusedProfiles: [UUID]) -> Verdict {
        if controllerConfigurationPersistent == true { return .notNormal("the extension controller configuration is persistent") }
        if controllerConfigurationPersistent == nil { return .unmeasured("no extension runtime reported its controller configuration") }
        if openedStores != [expectedStore] { return .notNormal("persistent stores opened \(openedStores.map(\.uuidString)), expected only the owned store") }
        if !refusedProfiles.isEmpty { return .notNormal("\(refusedProfiles.count) profile(s) outside the owned store asked for website data") }
        if let marked = samples.first(where: \.saysIncognito) {
            return .notNormal("an extension document reports private browsing (inIncognitoContext \(String(describing: marked.inIncognitoContext)), allowedIncognitoAccess \(String(describing: marked.allowedIncognitoAccess)), windows \(marked.windowIncognito ?? []), tabs \(marked.tabIncognito ?? []))")
        }
        guard !samples.isEmpty else { return .unmeasured("no extension document was measured") }
        // Every measured document must have answered every question with explicit booleans.
        if let index = samples.firstIndex(where: { !$0.complete }) {
            return .unmeasured("extension document \(index + 1) of \(samples.count) did not give explicit boolean answers for every question")
        }
        return .normal
    }
    /// Evaluated in each live extension document; the first call starts the asynchronous checks and
    /// later calls return what has been gathered on `globalThis`. Reads no page, storage or account data.
    static let measurementScript = """
    (() => {
      const g = globalThis;
      if (g.__bamModeProbe) return g.__bamModeProbe;
      // A random ID fixed for this document's lifetime, so rounds can be matched per document.
      let doc = null;
      try { doc = g.crypto && g.crypto.randomUUID ? g.crypto.randomUUID() : null; } catch (e) {}
      if (!doc) doc = "d" + Date.now().toString(36) + Math.random().toString(36).slice(2, 12);
      const r = g.__bamModeProbe = { state: "started", doc };
      const api = (typeof chrome === "object" && chrome) ? chrome : undefined;
      const note = (key, error) => { r[key] = String((error && error.message) || error).slice(0, 200); };
      // Only explicit booleans are recorded; anything missing or of another type is null.
      const flag = (value) => (typeof value === "boolean" ? value : null);
      try { r.inIncognitoContext = flag(api && api.extension ? api.extension.inIncognitoContext : undefined); } catch (e) { note("contextError", e); }
      (async () => {
        try { r.allowedIncognitoAccess = flag(await api.extension.isAllowedIncognitoAccess()); } catch (e) { note("accessError", e); }
        try { r.windowIncognito = (await api.windows.getAll()).map((w) => flag(w.incognito)); } catch (e) { note("windowsError", e); }
        try { r.tabIncognito = (await api.tabs.query({})).map((t) => flag(t.incognito)); } catch (e) { note("tabsError", e); }
        r.state = "done";
      })();
      return r;
    })()
    """

    // MARK: Bounded, confirmed cleanup of exactly one owned store

    struct CleanupResult: Equatable {
        var attempts = 0
        var removalError: String?
        var removalTimedOut = false
        /// The store identifier list was read (bounded) and no longer contains the owned store.
        var confirmedAbsent = false
        var refused: String?
        var removed: Bool { refused == nil && confirmedAbsent }
    }
    /// Removes only `store`, refusing reserved identifiers outright; one retry after `retryDelay`;
    /// then confirms absence from the store list. Every wait is bounded by `timeout`.
    /// `remove` and `list` deliver at most once each per call; a callback that never comes is a timeout.
    static func removeOwnedStore(_ store: UUID, reserved: Set<UUID>,
                                 remove: @escaping (UUID, @escaping (String?) -> Void) -> Void,
                                 list: @escaping (@escaping ([UUID]) -> Void) -> Void,
                                 timeout: TimeInterval, retryDelay: TimeInterval) async -> CleanupResult {
        var result = CleanupResult()
        guard !reserved.union([zero]).contains(store) else { result.refused = "reserved identifier"; return result }
        for attempt in 1...2 {
            result.attempts = attempt
            let outcome: String?? = await bounded(timeout) { done in remove(store) { done($0) } }
            if let outcome {
                result.removalTimedOut = false
                result.removalError = outcome
                if outcome == nil { break }
            } else {
                result.removalTimedOut = true
            }
            if attempt == 1 { try? await Task.sleep(nanoseconds: UInt64(max(0, retryDelay) * 1_000_000_000)) }
        }
        if let identifiers: [UUID] = await bounded(timeout, { done in list { done($0) } }) {
            result.confirmedAbsent = !identifiers.contains(store)
        }
        return result
    }
    struct GatedCleanup: Equatable {
        /// The controller and every owned page were released within the bound.
        var released = false
        /// nil when removal was not attempted because something was still alive.
        var removal: CleanupResult?
        var clean: Bool { released && removal?.removed == true }
    }
    /// WebKit requires every WKWebView using a store to be released before the store is removed. Polls
    /// `isReleased` until it holds or `releaseTimeout` passes; only then removes `store` via `removeOwnedStore`.
    /// If release never holds, `remove` and `list` are never called.
    static func removeOwnedStoreAfterRelease(_ store: UUID, reserved: Set<UUID>,
                                             isReleased: @escaping () -> Bool, releaseTimeout: TimeInterval, pollInterval: TimeInterval,
                                             remove: @escaping (UUID, @escaping (String?) -> Void) -> Void,
                                             list: @escaping (@escaping ([UUID]) -> Void) -> Void,
                                             timeout: TimeInterval, retryDelay: TimeInterval) async -> GatedCleanup {
        var gated = GatedCleanup()
        let deadline = Date().addingTimeInterval(max(0, releaseTimeout))
        while true {
            if isReleased() { gated.released = true; break }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, pollInterval) * 1_000_000_000))
        }
        guard gated.released else { return gated }
        gated.removal = await removeOwnedStore(store, reserved: reserved, remove: remove, list: list, timeout: timeout, retryDelay: retryDelay)
        return gated
    }

    /// Delivers the first callback value, or nil after `seconds`. Late callbacks are ignored.
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
    static func bounded<T>(_ seconds: TimeInterval, _ operation: @escaping (@escaping (T) -> Void) -> Void) async -> T? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds)) {
                if once.claim() { continuation.resume(returning: nil) }
            }
            operation { value in if once.claim() { continuation.resume(returning: value) } }
        }
    }
}
