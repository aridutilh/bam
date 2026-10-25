import WebKit

/// Store-policy seam for disposable runs. No real persistent store is ever
/// created: the isolated policy's persistent factory is replaced by one that
/// records identifiers and hands back nonpersistent stores.
@main enum WebsiteProfileStoreTests {
    @MainActor static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func refused(_ allowed: [UUID: UUID]) -> WebsiteProfileStore.IsolationError? {
            do { _ = try WebsiteProfileStore(isolated: allowed, makePersistent: { _ in .nonPersistent() }); return nil }
            catch let error as WebsiteProfileStore.IsolationError { return error }
            catch { return nil }
        }
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let preview = PreviewProfile.defaultStoreIdentifier, defaultProfile = BrowserProfile.defaultID

        // Standard policy: unchanged behavior for every existing caller.
        let standard = WebsiteProfileStore(ephemeral: true)
        let standardStore = standard.store(for: defaultProfile)
        require(standard.policy == .standard(ephemeral: true) && standard.ephemeral, "init(ephemeral:) keeps the standard policy")
        require(!standardStore.isPersistent && standard.store(for: defaultProfile) === standardStore
                && standard.profileID(for: standardStore) == defaultProfile, "Ephemeral standard stores are nonpersistent and shared per profile")
        require(standard.allowedStoreIdentifiers.isEmpty && standard.openedPersistentIdentifiers.isEmpty && standard.unlistedProfileRequests.isEmpty,
                "The standard policy reports nothing")

        // Isolated policy refuses Bam's own identifiers and unsafe mappings.
        let profile = UUID(), storeID = UUID()
        require(refused([defaultProfile: UUID()]) == .reservedIdentifier(defaultProfile), "The default profile can't be given a persistent store")
        require(refused([UUID(): preview]) == .reservedIdentifier(preview), "The real Preview store identifier is refused")
        require(refused([UUID(): defaultProfile]) == .reservedIdentifier(defaultProfile), "The default profile ID is refused as a store")
        require(refused([preview: UUID()]) == .reservedIdentifier(preview), "The Preview store ID is refused as a profile")
        require(refused([UUID(): zero]) == .reservedIdentifier(zero), "The empty UUID is refused")
        let shared = UUID()
        require(refused([UUID(): shared, UUID(): shared]) == .sharedStore(shared), "Two profiles can't share one task store")
        let other = UUID()
        require(refused([profile: other, other: UUID()]) == .storeMatchesProfile(other), "A store equal to a profile ID (its standard store) is refused")
        require(refused([profile: profile]) == .storeMatchesProfile(profile), "A profile can't use its own ID as its store")
        require(refused([:]) == nil && refused([profile: storeID]) == nil, "Empty and well-formed maps are accepted")

        // Isolated store: only the listed profile opens its own persistent store.
        var opened: [UUID] = []
        let isolated = try! WebsiteProfileStore(isolated: [profile: storeID], makePersistent: { opened.append($0); return .nonPersistent() })
        require(opened.isEmpty && isolated.openedPersistentIdentifiers.isEmpty, "Nothing is opened until a view asks")
        require(!isolated.ephemeral && isolated.allowedStoreIdentifiers == [storeID], "Cleanup scope is exactly the task-owned store")
        let owned = isolated.store(for: profile)
        require(opened == [storeID] && isolated.store(for: profile) === owned && opened == [storeID],
                "The listed profile opens its task store once and reuses it")
        require(isolated.profileID(for: owned) == profile, "A task store maps back to its profile")
        let stray = isolated.store(for: defaultProfile)
        let strangerProfile = UUID(), stranger = isolated.store(for: strangerProfile)
        _ = isolated.store(for: defaultProfile)
        require(!stray.isPersistent && !stranger.isPersistent && stray !== owned && stranger !== stray,
                "The default profile and unknown profiles get nonpersistent stores of their own")
        require(opened == [storeID] && !opened.contains(preview) && !opened.contains(defaultProfile),
                "No request reaches the Preview or default store, or any other persistent store")
        require(isolated.unlistedProfileRequests == [defaultProfile, strangerProfile], "Unlisted requests are recorded once each, in order")
        require(isolated.openedPersistentIdentifiers == [storeID], "Opened persistent stores are reported for the run's report")

        // Cleanup: after release nothing persistent can be reopened.
        isolated.releaseStores()
        let afterRelease = isolated.store(for: profile)
        require(isolated.isReleased && afterRelease !== owned && !afterRelease.isPersistent && opened == [storeID],
                "After release a stray request gets a nonpersistent store, never the removed task store")
        require(isolated.unlistedProfileRequests == [defaultProfile, strangerProfile], "A listed profile after release isn't miscounted as unlisted")
        print("PASS: \(checks) website store policy checks")
    }
}
