import WebKit

/// A store is chosen before constructing a web view. Sharing a profile means
/// sharing this same store, including in nonpersistent previews.
///
/// Two policies:
/// - `standard` (the app, every existing caller): unchanged. Ephemeral sessions
///   use nonpersistent stores; otherwise each profile maps through
///   `PreviewProfile` to its persistent store.
/// - `isolated` (opt-in, for disposable runs such as a vendor probe): only the
///   listed profiles get a persistent store, each under its own task-owned
///   identifier. Any other profile, above all the default profile, gets a
///   nonpersistent store and is recorded. `PreviewProfile` is never consulted,
///   so the real Preview or default stores can't be reached.
@MainActor final class WebsiteProfileStore {
    enum Policy: Equatable {
        case standard(ephemeral: Bool)
        case isolated(allowed: [UUID: UUID])
    }
    enum IsolationError: LocalizedError, Equatable {
        /// The default profile, the Preview store, or the empty UUID.
        case reservedIdentifier(UUID)
        /// Two profiles were given the same store.
        case sharedStore(UUID)
        /// A store identifier equal to a profile ID is the standard mapping's
        /// persistent store for that profile, so it isn't task-owned.
        case storeMatchesProfile(UUID)
        var errorDescription: String? {
            switch self {
            case .reservedIdentifier(let id): return "\(id.uuidString) is reserved for Bam's own profiles and stores."
            case .sharedStore(let id): return "Store \(id.uuidString) is assigned to more than one profile."
            case .storeMatchesProfile(let id): return "Store \(id.uuidString) is a profile's own standard store."
            }
        }
    }
    /// Identifiers an isolated store may never use, as a profile or a store.
    static let reservedIdentifiers: Set<UUID> = [
        BrowserProfile.defaultID, PreviewProfile.defaultStoreIdentifier,
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    ]

    let policy: Policy
    /// True only for the standard ephemeral policy, as before.
    var ephemeral: Bool { if case .standard(let ephemeral) = policy { return ephemeral }; return false }
    /// Isolated: the task-owned identifiers, i.e. everything a cleanup may remove.
    var allowedStoreIdentifiers: Set<UUID> {
        if case .isolated(let allowed) = policy { return Set(allowed.values) }
        return []
    }
    /// Isolated: persistent identifiers actually opened, in order (each once).
    private(set) var openedPersistentIdentifiers: [UUID] = []
    /// Isolated: profiles that asked for a store but aren't listed (each once).
    /// They were given a nonpersistent store.
    private(set) var unlistedProfileRequests: [UUID] = []
    /// Set by `releaseStores()`; afterwards nothing persistent is opened again.
    private(set) var isReleased = false

    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private let makePersistent: (UUID) -> WKWebsiteDataStore

    init(ephemeral: Bool) {
        policy = .standard(ephemeral: ephemeral)
        makePersistent = { WKWebsiteDataStore(forIdentifier: $0) }
    }
    /// An isolated store for a disposable run. Throws for reserved, shared or
    /// profile-equal identifiers; nothing is opened until a view asks.
    /// `makePersistent` exists for tests, which must not create real stores.
    init(isolated allowed: [UUID: UUID], makePersistent: @escaping (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) }) throws {
        for (profile, store) in allowed {
            if Self.reservedIdentifiers.contains(profile) { throw IsolationError.reservedIdentifier(profile) }
            if Self.reservedIdentifiers.contains(store) { throw IsolationError.reservedIdentifier(store) }
            if allowed.keys.contains(store) { throw IsolationError.storeMatchesProfile(store) }
        }
        if let shared = Dictionary(grouping: allowed.values, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw IsolationError.sharedStore(shared)
        }
        policy = .isolated(allowed: allowed)
        self.makePersistent = makePersistent
    }

    func store(for profileID: UUID) -> WKWebsiteDataStore {
        if let existing = stores[profileID] { return existing }
        let store: WKWebsiteDataStore
        switch policy {
        case .standard(let ephemeral):
            if ephemeral { store = .nonPersistent() }
            else if let identifier = PreviewProfile.persistentIdentifier(for: profileID) { store = makePersistent(identifier) }
            else { store = .default() }
        case .isolated(let allowed):
            if let identifier = allowed[profileID], !isReleased {
                store = makePersistent(identifier)
                if !openedPersistentIdentifiers.contains(identifier) { openedPersistentIdentifiers.append(identifier) }
            } else {
                store = .nonPersistent()
                if allowed[profileID] == nil, !unlistedProfileRequests.contains(profileID) { unlistedProfileRequests.append(profileID) }
            }
        }
        stores[profileID] = store
        return store
    }
    /// Every store handed out so far (a private window wipes them when it closes).
    var openedStores: [WKWebsiteDataStore] { Array(stores.values) }
    func profileID(for store: WKWebsiteDataStore) -> UUID? {
        if let match = stores.first(where: { $0.value === store })?.key { return match }
        guard let identifier = store.identifier else { return nil }
        switch policy {
        case .standard(let ephemeral):
            guard !ephemeral else { return nil }
            return stores.keys.first(where: { PreviewProfile.persistentIdentifier(for: $0) == identifier })
        case .isolated(let allowed):
            return allowed.first(where: { $0.value == identifier })?.key
        }
    }
    /// Isolated cleanup: drops every cached store so the caller can release
    /// its views and remove `allowedStoreIdentifiers`. Later requests get
    /// nonpersistent stores, so a stray view can't reopen a removed store.
    func releaseStores() {
        stores.removeAll()
        if case .isolated = policy { isReleased = true }
    }
}
