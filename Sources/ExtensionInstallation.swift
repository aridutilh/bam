import Foundation

/// Provenance kept with an installed extension so the manager can show where a
/// package came from, how it was verified and which upstream build it tracks.
struct ExtensionCatalogRecord: Codable, Equatable {
    var source: ExtensionCatalogSourceKind
    var upstreamID: String?
    var listingURL: URL?
    var downloadURL: URL?
    var publisher: String
    var version: String
    var sha256: String
    /// Human-readable verification result ("AMO-published SHA-256 matched", "CRX3 signature verified for <id>", …).
    var provenance: String
    var installedAt: Date
    var updatedAt: Date?
    var lastUpdateCheck: Date?
    var availableVersion: String?

    var sourceLabel: String {
        switch source {
        case .amo: return "Firefox Add-ons"
        case .chromeWebStore: return "Chrome Web Store"
        case .directPackage: return "Direct download"
        case .local: return "Local folder"
        }
    }
}

/// One product shown once, with every upstream build Bam knows about and the
/// build it would pick. Reasons are shown; the user can still choose another build.
struct ExtensionProductListing: Equatable {
    var identity: ExtensionCatalogIdentity
    var candidates: [ExtensionBuildCandidate]
    var recommended: ExtensionBuildCandidate
    var reasons: [String]
    var name: String { recommended.name }
    var publisher: String { recommended.publisher }
}

/// Picks a build on what Bam can actually run, not on a fixed store preference.
@available(macOS 15.4, *)
enum ExtensionBuildResolver {
    /// Dated observations from Bam's own vendor probes, keyed by upstream ID.
    /// They are evidence for ordering, never a compatibility promise.
    static let observations: [String: String] = [
        "jetpack-extension@dashlane.com": "2026-10-24: background runs, welcome popup and options page render, field icons inject into a login form.",
        "fdjamakpfbbddfjaooikfcpapjohcfmg": "2026-10-24 (earlier draft): MV3 service worker build reported runtime.connect without listeners; welcome flow not reached.",
        "{d634138d-c276-4fc8-924b-40a0ea21d284}": "2026-10-24: HTML background page can receive Bam's compatibility layer; startup previously stopped at chrome.notifications.",
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa": "2026-10-24: MV3 service worker build (Chrome 140+) cannot receive Bam's compatibility layer; requires notifications and nativeMessaging.",
        "firefox@vid.io": "2026-10-24: loads with no context errors; popup renders; YouTube content scripts inject but the overlay has not been observed yet.",
        "pachckjkecffpdphbpmfolblodfkgbhl": "2026-10-24: MV3 service worker build; same content scripts as the Firefox build; untested in Bam.",
    ]

    static func recommend(_ candidates: [ExtensionBuildCandidate]) -> (ExtensionBuildCandidate, [String])? {
        guard !candidates.isEmpty else { return nil }
        var reasons: [String] = []
        func score(_ c: ExtensionBuildCandidate) -> Int {
            var s = 0
            let needsLayer = !Set(c.permissions).intersection(ExtensionCompatibility.bridgedPermissions).isEmpty
            // A service worker background cannot be reached by Bam's compatibility layer.
            if c.backgroundKind == .serviceWorker { s -= needsLayer ? 40 : 5 }
            if c.backgroundKind == .page || c.backgroundKind == .scripts { s += 10 }
            if c.permissions.contains("nativeMessaging") { s -= 3 }
            if c.source == .amo { s += 2 }  // published hash, no product-version gate
            if let id = c.upstreamID, let note = observations[id] {
                if note.contains("cannot receive") || note.contains("not reached") || note.contains("stopped at") { s -= 15 }
                if note.contains("inject") || note.contains("render") { s += 8 }
            }
            return s
        }
        let ranked = candidates.sorted { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : compareVersions(a.version, b.version) == .orderedDescending
        }
        let pick = ranked[0]
        if pick.backgroundKind == .serviceWorker {
            reasons.append("This build runs its background as a service worker, which Bam's compatibility layer cannot reach.")
        } else if pick.backgroundKind != nil {
            reasons.append("HTML background page: Bam's compatibility layer can stand in for missing APIs.")
        }
        if candidates.count > 1 { reasons.append("Other builds of the same product are listed below; Bam picked \(pick.source == .amo ? "the Firefox Add-ons build" : pick.source == .chromeWebStore ? "the Chrome Web Store build" : "this build").") }
        if let id = pick.upstreamID, let note = observations[id] { reasons.append("Bam probe: " + note) }
        return (pick, reasons)
    }

    /// Dotted numeric comparison; non-numeric parts compare lexically after numbers.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map(String.init), pb = b.split(separator: ".").map(String.init)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0", y = i < pb.count ? pb[i] : "0"
            if let nx = Int(x), let ny = Int(y) { if nx != ny { return nx < ny ? .orderedAscending : .orderedDescending } }
            else if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Resolves a pasted link or search text into product listings, fetches a chosen
/// build through the verified pipeline and hands the unpacked folder to the host's
/// existing importer. Updates keep the installed extension's identity and storage.
@available(macOS 15.4, *)
@MainActor final class ExtensionInstaller {
    private weak var host: BrowserExtensions?
    let amo: AMOSource
    let chromeWebStore: ChromeWebStoreSource
    let fetcher: ExtensionPackageFetch
    private(set) var isBusy = false
    var statusChanged: ((String) -> Void)?

    init(host: BrowserExtensions, client: any ExtensionHTTPClient = URLSessionExtensionHTTPClient(), bamVersion: String = BrowserExtensions.browserVersion) {
        self.host = host
        amo = AMOSource(client: client, bamVersion: bamVersion)
        chromeWebStore = ChromeWebStoreSource(client: client)
        fetcher = ExtensionPackageFetch(client: client, bamVersion: bamVersion)
    }

    /// A store link gives one product; anything else searches Firefox Add-ons, the
    /// only public catalog. Chrome Web Store products are reached by link.
    func resolve(_ text: String) async throws -> [ExtensionProductListing] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let link = ExtensionStoreLink(parsing: trimmed) {
            let candidate: ExtensionBuildCandidate
            switch link {
            case .amo(let slug): candidate = try await amo.addon(slug)
            case .chromeWebStore(let id): candidate = try await chromeWebStore.candidate(for: id)
            case .directPackage(let url): candidate = .direct(url)
            }
            return [listing(for: [candidate])]
        }
        let results = try await amo.search(trimmed)
        return Self.group(results)
    }

    /// Groups candidates into product listings by catalog identity.
    static func group(_ candidates: [ExtensionBuildCandidate]) -> [ExtensionProductListing] {
        var listings: [ExtensionProductListing] = []
        for candidate in candidates {
            let identity = ExtensionCatalogIdentity(candidate)
            if let index = listings.firstIndex(where: { $0.identity.matches(identity) }) {
                listings[index].candidates.append(candidate)
                listings[index].identity = listings[index].identity.absorbing(identity)
                if let (pick, reasons) = ExtensionBuildResolver.recommend(listings[index].candidates) { listings[index].recommended = pick; listings[index].reasons = reasons }
            } else if let (pick, reasons) = ExtensionBuildResolver.recommend([candidate]) {
                listings.append(ExtensionProductListing(identity: identity, candidates: [candidate], recommended: pick, reasons: reasons))
            }
        }
        return listings
    }
    private func listing(for candidates: [ExtensionBuildCandidate]) -> ExtensionProductListing {
        let (pick, reasons) = ExtensionBuildResolver.recommend(candidates)!
        var identity = ExtensionCatalogIdentity(candidates[0])
        for c in candidates.dropFirst() { identity = identity.absorbing(ExtensionCatalogIdentity(c)) }
        return ExtensionProductListing(identity: identity, candidates: candidates, recommended: pick, reasons: reasons)
    }

    /// After a Chrome Web Store fetch the manifest names the product; look for the
    /// same product on Firefox Add-ons so the user sees one listing with both builds.
    func alternatives(for fetched: ExtensionFetchedPackage) async -> [ExtensionBuildCandidate] {
        guard fetched.candidate.source == .chromeWebStore, !fetched.candidate.name.isEmpty, fetched.candidate.name != fetched.candidate.upstreamID else { return [] }
        let identity = ExtensionCatalogIdentity(fetched.candidate)
        let results = (try? await amo.search(fetched.candidate.name)) ?? []
        return results.filter { ExtensionCatalogIdentity($0).matches(identity) }
    }

    /// Downloads, verifies and unpacks one build, then installs it through the host.
    /// The returned ID is a record, not proof the extension works; the host's
    /// permission review can still cancel activation.
    func install(_ candidate: ExtensionBuildCandidate, profileID: UUID) async throws -> UUID {
        guard let host else { throw BrowserExtensions.failure("The browser is closing.") }
        guard !isBusy else { throw BrowserExtensions.failure("Another extension installation is in progress.") }
        isBusy = true; defer { isBusy = false }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("bam-extension-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        statusChanged?("Downloading \(candidate.name)…")
        let fetched = try await fetcher.fetch(candidate, into: staging)
        statusChanged?("Verified \(fetched.candidate.name) \(fetched.candidate.version). Reviewing permissions…")
        let record = Self.catalogRecord(for: fetched, installedAt: Date())
        return try await host.importPackage(at: fetched.packageURL, profileID: profileID, catalog: record)
    }

    static func catalogRecord(for fetched: ExtensionFetchedPackage, installedAt: Date, previous: ExtensionCatalogRecord? = nil) -> ExtensionCatalogRecord {
        let provenance: String
        switch fetched.provenance {
        case .amoHashMatched: provenance = "Firefox Add-ons published SHA-256 matched"
        case .crx3SignatureVerified(let id): provenance = "CRX3 publisher signature verified (\(id))"
        case .unverifiedDirectDownload: provenance = "Direct download over HTTPS; no publisher signature checked"
        case .local: provenance = "Local folder; trusted by the user"
        }
        return ExtensionCatalogRecord(source: fetched.candidate.source, upstreamID: fetched.candidate.upstreamID, listingURL: fetched.candidate.listingURL,
                                      downloadURL: fetched.candidate.downloadURL, publisher: fetched.candidate.publisher, version: fetched.candidate.version,
                                      sha256: fetched.sha256, provenance: provenance, installedAt: previous?.installedAt ?? installedAt,
                                      updatedAt: previous == nil ? nil : installedAt, lastUpdateCheck: Date(), availableVersion: nil)
    }

    /// Asks the installed build's own source for its current version. Never
    /// switches an extension to another store: storage formats can differ.
    func checkForUpdate(_ record: BrowserExtensionRecord) async throws -> ExtensionBuildCandidate? {
        guard let catalog = record.catalog, let id = catalog.upstreamID else { return nil }
        let candidate: ExtensionBuildCandidate
        switch catalog.source {
        case .amo: candidate = try await amo.addon(id)
        case .chromeWebStore: candidate = try await chromeWebStore.candidate(for: id)
        case .directPackage, .local: return nil
        }
        let current = record.version.isEmpty ? catalog.version : record.version
        host?.noteUpdateCheck(id: record.id, available: ExtensionBuildResolver.compareVersions(candidate.version, current) == .orderedDescending ? candidate.version : nil)
        return ExtensionBuildResolver.compareVersions(candidate.version, current) == .orderedDescending ? candidate : nil
    }

    /// Replaces the package in place, keeping the extension's identifier, storage,
    /// grants and profile. The source must match the installed build's source.
    func update(_ record: BrowserExtensionRecord, to candidate: ExtensionBuildCandidate) async throws {
        guard let host else { throw BrowserExtensions.failure("The browser is closing.") }
        guard let catalog = record.catalog, catalog.source == candidate.source, catalog.upstreamID == candidate.upstreamID else {
            throw BrowserExtensions.failure("Updates only follow the build that was installed. Install the other build separately instead of switching stores.")
        }
        guard !isBusy else { throw BrowserExtensions.failure("Another extension installation is in progress.") }
        isBusy = true; defer { isBusy = false }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("bam-extension-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        statusChanged?("Downloading \(candidate.name) \(candidate.version)…")
        let fetched = try await fetcher.fetch(candidate, into: staging)
        let updated = Self.catalogRecord(for: fetched, installedAt: Date(), previous: catalog)
        try await host.replacePackage(id: record.id, with: fetched.packageURL, catalog: updated)
    }
}
