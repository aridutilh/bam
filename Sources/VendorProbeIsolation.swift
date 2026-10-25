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

    /// One extension document's answers to the incognito questions.
    struct IncognitoMeasurement: Equatable {
        var inIncognitoContext: Bool?
        var allowedIncognitoAccess: Bool?
        var windowIncognito: [Bool]?
        var tabIncognito: [Bool]?
        var complete: Bool { inIncognitoContext != nil && allowedIncognitoAccess != nil && windowIncognito?.isEmpty == false && tabIncognito?.isEmpty == false }
        var saysIncognito: Bool {
            inIncognitoContext == true || allowedIncognitoAccess == true
                || windowIncognito?.contains(true) == true || tabIncognito?.contains(true) == true
        }
    }
    /// Reads the measurement script's result object (see `measurementScript`).
    static func measurement(from value: Any?) -> IncognitoMeasurement? {
        guard let object = value as? [String: Any], object["state"] as? String == "done" else { return nil }
        func flags(_ key: String) -> [Bool]? { (object[key] as? [Any])?.compactMap { $0 as? Bool } }
        return IncognitoMeasurement(inIncognitoContext: object["inIncognitoContext"] as? Bool,
                                    allowedIncognitoAccess: object["allowedIncognitoAccess"] as? Bool,
                                    windowIncognito: flags("windowIncognito"), tabIncognito: flags("tabIncognito"))
    }
    enum Verdict: Equatable {
        /// Every measured surface says not incognito and the controller writes nothing to disk.
        case normal
        /// Something reports private browsing, or storage isn't the required kind; the run is not a normal-profile observation.
        case notNormal(String)
        /// Nothing complete was measured, so the mode can't be claimed.
        case unmeasured(String)
    }
    static func verdict(_ samples: [IncognitoMeasurement], controllerConfigurationPersistent: Bool?,
                        openedStores: [UUID], expectedStore: UUID, refusedProfiles: [UUID]) -> Verdict {
        if controllerConfigurationPersistent == true { return .notNormal("the extension controller configuration is persistent") }
        if controllerConfigurationPersistent == nil { return .unmeasured("no extension runtime reported its controller configuration") }
        if openedStores != [expectedStore] { return .notNormal("persistent stores opened \(openedStores.map(\.uuidString)), expected only the owned store") }
        if !refusedProfiles.isEmpty { return .notNormal("\(refusedProfiles.count) profile(s) outside the owned store asked for website data") }
        if let marked = samples.first(where: \.saysIncognito) {
            return .notNormal("an extension document reports private browsing (inIncognitoContext \(String(describing: marked.inIncognitoContext)), allowedIncognitoAccess \(String(describing: marked.allowedIncognitoAccess)), windows \(marked.windowIncognito ?? []), tabs \(marked.tabIncognito ?? []))")
        }
        guard samples.contains(where: \.complete) else { return .unmeasured("no extension document completed the incognito measurement") }
        return .normal
    }
    /// Evaluated in each live extension document; the first call starts the asynchronous checks and
    /// later calls return what has been gathered on `globalThis`. Reads no page, storage or account data.
    static let measurementScript = """
    (() => {
      const g = globalThis;
      if (g.__bamModeProbe) return g.__bamModeProbe;
      const r = g.__bamModeProbe = { state: "started" };
      const api = (typeof chrome === "object" && chrome) ? chrome : undefined;
      const note = (key, error) => { r[key] = String((error && error.message) || error).slice(0, 200); };
      try { r.inIncognitoContext = api && api.extension ? api.extension.inIncognitoContext : undefined; } catch (e) { note("contextError", e); }
      (async () => {
        try { r.allowedIncognitoAccess = await api.extension.isAllowedIncognitoAccess(); } catch (e) { note("accessError", e); }
        try { r.windowIncognito = (await api.windows.getAll()).map((w) => w.incognito === true); } catch (e) { note("windowsError", e); }
        try { r.tabIncognito = (await api.tabs.query({})).map((t) => t.incognito === true); } catch (e) { note("tabsError", e); }
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
