import Foundation

// MARK: - Store links

/// Where a build comes from. One catalog listing may be backed by several of these.
enum ExtensionCatalogSourceKind: String, Sendable, Codable {
    case amo, chromeWebStore, safariAppStore, directPackage, local
}

/// A user-pasted store or package URL resolved to a source reference.
enum ExtensionStoreLink: Equatable, Sendable {
    case amo(slug: String)
    case chromeWebStore(id: String)
    case directPackage(URL)
    case safariAppStore(id: String)

    static let packageExtensions: Set<String> = ["xpi", "crx", "zip"]

    /// A Chrome Web Store ID is exactly 32 letters from `a` to `p` (hex digits mapped to letters).
    static func isChromeWebStoreID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("a"..."p").contains($0) }
    }

    static func isAMOSlug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 &&
            value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == "@" || $0 == "{" || $0 == "}" }
    }

    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if host == "addons.mozilla.org" {
            var index = 0
            if segments.first?.lowercased() != "firefox", segments.count > 1, segments[1].lowercased() == "firefox" { index = 1 }
            if segments.count > index + 2, segments[index].lowercased() == "firefox", segments[index + 1].lowercased() == "addon",
               Self.isAMOSlug(segments[index + 2]) {
                self = .amo(slug: segments[index + 2])
                return
            }
        }
        var storeSegments: ArraySlice<String>?
        if host == "chromewebstore.google.com", segments.first?.lowercased() == "detail" {
            storeSegments = segments.dropFirst()
        } else if host == "chrome.google.com", segments.count > 1, segments[0].lowercased() == "webstore", segments[1].lowercased() == "detail" {
            storeSegments = segments.dropFirst(2)
        }
        if let storeSegments, let id = storeSegments.last(where: { Self.isChromeWebStoreID($0.lowercased()) }) {
            self = .chromeWebStore(id: id.lowercased())
            return
        }
        if host == "apps.apple.com", let id = segments.last(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2 }) {
            self = .safariAppStore(id: String(id.dropFirst(2)))
            return
        }
        if Self.packageExtensions.contains(url.pathExtension.lowercased()) {
            self = .directPackage(url)
            return
        }
        return nil
    }

    var sourceKind: ExtensionCatalogSourceKind {
        switch self {
        case .amo: return .amo
        case .chromeWebStore: return .chromeWebStore
        case .safariAppStore: return .safariAppStore
        case .directPackage: return .directPackage
        }
    }
}

// MARK: - Catalog model

enum ExtensionBackgroundKind: String, Sendable, Codable {
    case page, scripts, serviceWorker, none
}

/// One concrete upstream build of a product. Fields marked optional in the design stay nil until the
/// package is unpacked (manifest version, background kind) or the source does not publish them.
struct ExtensionBuildCandidate: Sendable, Equatable, Codable {
    var source: ExtensionCatalogSourceKind
    /// The AMO GUID or Chrome Web Store ID; nil for direct and local packages until verified.
    var upstreamID: String?
    var name: String
    var publisher: String
    var version: String
    var downloadURL: URL?
    var size: Int?
    /// Lowercase hex SHA-256 the source published for the package, when it publishes one.
    var expectedSHA256: String?
    var manifestVersion: Int?
    var backgroundKind: ExtensionBackgroundKind?
    var permissions: [String] = []
    var hostPermissions: [String] = []
    var releasedAt: Date?
    var homepage: URL?
    var listingURL: URL?
    var iconURL: URL? = nil
    var summary: String? = nil
    var compatibilityNote: String? = nil
    /// Exact containing-app identity from Apple's catalog, used for Safari imports.
    var applicationBundleIdentifier: String? = nil

    /// Chrome candidates are resolved to current package URLs only when installed.
    /// Safari imports use an installed, verified containing app rather than a package URL.
    var canInstallInBam: Bool { source == .safariAppStore ? applicationBundleIdentifier != nil : (downloadURL != nil || source == .chromeWebStore) }

    /// A candidate for a pasted package URL; name and version are filled from the manifest after download.
    static func direct(_ url: URL) -> ExtensionBuildCandidate {
        ExtensionBuildCandidate(source: .directPackage, upstreamID: nil, name: url.lastPathComponent, publisher: "", version: "", downloadURL: url)
    }

    /// A candidate for a package file already on disk.
    static func local(_ fileURL: URL) -> ExtensionBuildCandidate {
        ExtensionBuildCandidate(source: .local, upstreamID: nil, name: fileURL.lastPathComponent, publisher: "", version: "", downloadURL: fileURL)
    }

    /// The expected hash as lowercase hex, accepting an `sha256:` prefix; nil when absent or malformed.
    var normalizedExpectedSHA256: String? {
        guard var value = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if value.hasPrefix("sha256:") { value.removeFirst("sha256:".count) }
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    /// Fills fields the manifest knows better than the listing did, without overriding published values.
    func applying(_ manifest: ExtensionManifestSummary) -> ExtensionBuildCandidate {
        var copy = self
        // AMO publishes a curated listing name; every other source only knows the manifest's.
        if copy.source != .amo || copy.name.isEmpty, !manifest.name.isEmpty { copy.name = manifest.name }
        if copy.version.isEmpty { copy.version = manifest.version }
        copy.manifestVersion = manifest.manifestVersion
        copy.backgroundKind = manifest.backgroundKind
        if copy.permissions.isEmpty && copy.hostPermissions.isEmpty {
            copy.permissions = manifest.permissions
            copy.hostPermissions = manifest.hostPermissions
        }
        if copy.homepage == nil { copy.homepage = manifest.homepage }
        return copy
    }
}

/// Canonical product identity across builds from different stores.
///
/// This is a heuristic: two builds are treated as the same product when they share an upstream ID
/// of the same kind, belong to the inspected cross-store map, or their names, publisher names
/// and homepage hosts all match after normalization. Publisher names and homepages are
/// self-declared by the extension author, so the UI must always show the source and publisher of
/// each build for the user to inspect before trusting a match.
struct ExtensionCatalogIdentity: Sendable, Equatable {
    var amoGUID: String?
    var chromeWebStoreID: String?
    var publisher: String
    var homepageHost: String?
    var knownProductID: String? = nil
    var safariAppStoreID: String? = nil
    var productName: String? = nil

    init(amoGUID: String? = nil, chromeWebStoreID: String? = nil, publisher: String, homepageHost: String? = nil, productName: String? = nil) {
        self.amoGUID = amoGUID
        self.chromeWebStoreID = chromeWebStoreID
        self.publisher = publisher
        self.homepageHost = Self.normalizedHost(homepageHost)
        self.productName = productName.map(Self.normalizedPublisher)
    }

    init(_ candidate: ExtensionBuildCandidate) {
        self.init(amoGUID: candidate.source == .amo ? candidate.upstreamID : nil,
                  chromeWebStoreID: candidate.source == .chromeWebStore ? candidate.upstreamID : nil,
                  publisher: candidate.publisher,
                  homepageHost: candidate.homepage?.host, productName: candidate.name)
        knownProductID = ExtensionKnownProducts.product(for: candidate)?.id
        safariAppStoreID = candidate.source == .safariAppStore ? candidate.upstreamID : nil
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var value = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix(".") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    static func normalizedPublisher(_ publisher: String) -> String {
        publisher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func matches(_ other: ExtensionCatalogIdentity) -> Bool {
        // A self-declared clone must never join an inspected product merely by
        // copying its name, publisher and homepage into an unrelated store ID.
        if knownProductID != nil || other.knownProductID != nil {
            return knownProductID != nil && knownProductID == other.knownProductID
        }
        if let mine = safariAppStoreID, let theirs = other.safariAppStoreID { return mine == theirs }
        if let mine = amoGUID, let theirs = other.amoGUID { return mine.lowercased() == theirs.lowercased() }
        if let mine = chromeWebStoreID, let theirs = other.chromeWebStoreID { return mine.lowercased() == theirs.lowercased() }
        let publisher = Self.normalizedPublisher(self.publisher)
        guard !publisher.isEmpty, publisher == Self.normalizedPublisher(other.publisher),
              let host = homepageHost, host == other.homepageHost,
              let name = productName, !name.isEmpty, name == other.productName else { return false }
        return true
    }

    /// Merges another build's identifiers into this product identity.
    func absorbing(_ other: ExtensionCatalogIdentity) -> ExtensionCatalogIdentity {
        var copy = self
        if copy.amoGUID == nil { copy.amoGUID = other.amoGUID }
        if copy.chromeWebStoreID == nil { copy.chromeWebStoreID = other.chromeWebStoreID }
        if copy.homepageHost == nil { copy.homepageHost = other.homepageHost }
        if copy.publisher.isEmpty { copy.publisher = other.publisher }
        if copy.knownProductID == nil { copy.knownProductID = other.knownProductID }
        if copy.safariAppStoreID == nil { copy.safariAppStoreID = other.safariAppStoreID }
        if copy.productName == nil { copy.productName = other.productName }
        return copy
    }
}

// MARK: - HTTP

/// Injectable transport so adapters can be tested against canned responses.
protocol ExtensionHTTPClient: Sendable {
    /// Performs the request, following redirects, and returns the whole body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Performs the request; with `followingRedirects` false a 3xx response is returned as-is with its Location header.
    func response(for request: URLRequest, followingRedirects: Bool) async throws -> (Data, HTTPURLResponse)
    /// Streams the body into a new file at `destination`, failing once more than `byteLimit` bytes arrive.
    func download(for request: URLRequest, to destination: URL, byteLimit: Int) async throws -> HTTPURLResponse
}

extension ExtensionHTTPClient {
    func response(for request: URLRequest, followingRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request)
    }

    func download(for request: URLRequest, to destination: URL, byteLimit: Int) async throws -> HTTPURLResponse {
        let (body, response) = try await data(for: request)
        guard body.count <= byteLimit else { throw ExtensionPackageError("The download exceeds the \(byteLimit / 1_048_576) MiB limit.") }
        try body.write(to: destination, options: .withoutOverwriting)
        return response
    }
}

/// The production transport: an ephemeral session without cookies, redirect control via a task delegate, streaming downloads.
struct URLSessionExtensionHTTPClient: ExtensionHTTPClient {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ExtensionPackageError("The server returned a non-HTTP response.") }
        return http
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, try Self.http(response))
    }

    func response(for request: URLRequest, followingRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        if followingRedirects { return try await data(for: request) }
        let (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate())
        return (data, try Self.http(response))
    }

    func download(for request: URLRequest, to destination: URL, byteLimit: Int) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let http = try Self.http(response)
        guard (200..<300).contains(http.statusCode) else { return http }
        guard http.expectedContentLength <= Int64(byteLimit) else {
            throw ExtensionPackageError("The download exceeds the \(byteLimit / 1_048_576) MiB limit.")
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw ExtensionPackageError("The download file could not be created.")
        }
        var received = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        do {
            for try await byte in bytes {
                received += 1
                guard received <= byteLimit else { throw ExtensionPackageError("The download exceeds the \(byteLimit / 1_048_576) MiB limit.") }
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return http
    }
}

// MARK: - AMO

/// Adapter over the public addons.mozilla.org v5 API.
struct AMOSource: Sendable {
    static let defaultBaseURL = URL(string: "https://addons.mozilla.org")!
    let client: any ExtensionHTTPClient
    let userAgent: String
    let baseURL: URL

    init(client: any ExtensionHTTPClient = URLSessionExtensionHTTPClient(), bamVersion: String, baseURL: URL = AMOSource.defaultBaseURL) {
        self.client = client
        self.userAgent = Self.userAgent(bamVersion: bamVersion)
        self.baseURL = baseURL
    }

    static func userAgent(bamVersion: String) -> String { "Bam/\(bamVersion) (+https://bambrowser.com)" }

    func addon(_ slugOrGUID: String) async throws -> ExtensionBuildCandidate {
        let encoded = slugOrGUID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slugOrGUID
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/api/v5/addons/addon/\(encoded)/"
        components.queryItems = [URLQueryItem(name: "lang", value: "en-US")]
        let object = try await json(from: components.url!)
        return try Self.candidate(fromAddonJSON: object)
    }

    func search(_ query: String) async throws -> [ExtensionBuildCandidate] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/v5/addons/search/"
        components.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "app", value: "firefox"),
            URLQueryItem(name: "type", value: "extension"), URLQueryItem(name: "sort", value: "users"),
            URLQueryItem(name: "page_size", value: "10"), URLQueryItem(name: "lang", value: "en-US")
        ]
        let object = try await json(from: components.url!)
        guard let results = object["results"] as? [[String: Any]] else {
            throw ExtensionPackageError("The AMO search response has no results array.")
        }
        return results.compactMap { try? Self.candidate(fromAddonJSON: $0) }
    }

    private func json(from url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ExtensionPackageError("addons.mozilla.org answered HTTP \(response.statusCode) for \(url.path).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionPackageError("addons.mozilla.org returned something other than a JSON object.")
        }
        return object
    }

    /// AMO returns translated fields either as a localized dictionary (possibly with `_default`) or, with `lang=`, as a string.
    static func localized(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let string = dictionary["en-US"] as? String, !string.isEmpty { return string }
        if let fallback = dictionary["_default"] as? String, let string = dictionary[fallback] as? String, !string.isEmpty { return string }
        for key in dictionary.keys.sorted() where key != "_default" {
            if let string = dictionary[key] as? String, !string.isEmpty { return string }
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    static func isHostPattern(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://")
    }

    /// Moves host patterns out of an API permission list and appends them to the host list without duplicates.
    static func splitHostPatterns(_ permissions: [String], hostPermissions: [String]) -> (permissions: [String], hostPermissions: [String]) {
        var hosts: [String] = []
        for pattern in hostPermissions + permissions.filter(isHostPattern) where !hosts.contains(pattern) { hosts.append(pattern) }
        return (permissions.filter { !isHostPattern($0) }, hosts)
    }

    static func candidate(fromAddonJSON object: [String: Any]) throws -> ExtensionBuildCandidate {
        guard let guid = object["guid"] as? String, let slug = object["slug"] as? String,
              let current = object["current_version"] as? [String: Any] else {
            throw ExtensionPackageError("The AMO add-on record lacks a guid, slug or current version.")
        }
        guard let file = current["file"] as? [String: Any] ?? (current["files"] as? [[String: Any]])?.first,
              let urlString = file["url"] as? String, let downloadURL = URL(string: urlString), downloadURL.scheme == "https" else {
            throw ExtensionPackageError("The AMO add-on record has no downloadable file.")
        }
        var hash: String?
        if let raw = file["hash"] as? String {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "sha256" { hash = parts[1].lowercased() }
        }
        // AMO lists MV2-style host patterns inside `permissions` even when `host_permissions` is present.
        let (permissions, hostPermissions) = splitHostPatterns(file["permissions"] as? [String] ?? [], hostPermissions: file["host_permissions"] as? [String] ?? [])
        let authors = (object["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        var homepage: URL?
        if let homepageObject = object["homepage"] as? [String: Any] {
            homepage = localized(homepageObject["url"]).flatMap(URL.init(string:))
        } else {
            homepage = localized(object["homepage"]).flatMap(URL.init(string:))
        }
        return ExtensionBuildCandidate(
            source: .amo, upstreamID: guid,
            name: localized(object["name"]) ?? slug,
            publisher: authors.joined(separator: ", "),
            version: current["version"] as? String ?? "",
            downloadURL: downloadURL,
            size: file["size"] as? Int,
            expectedSHA256: hash,
            manifestVersion: file["manifest_version"] as? Int,
            backgroundKind: nil,
            permissions: permissions, hostPermissions: hostPermissions,
            releasedAt: date(file["created"]) ?? date(object["last_updated"]),
            homepage: homepage,
            listingURL: URL(string: "https://addons.mozilla.org/firefox/addon/\(slug)/"),
            iconURL: (object["icon_url"] as? String).flatMap(URL.init(string:)),
            summary: localized(object["summary"]))
    }
}

// MARK: - Chrome Web Store

/// Resolves Chrome Web Store builds through Google's update service.
///
/// There is no public catalog or search API for the Chrome Web Store. The `update2/crx` endpoint
/// used here is the one Google's own documentation points at for fetching a CRX by ID (the
/// `clients2.google.com/service/update2/crx` form appears in Chrome's install documentation),
/// but it is not a supported third-party catalog contract: parameters, product-version gating and
/// redirect shape may change without notice. Observed on 2026-10-24: with `prodversion=130.0.0.0`
/// the service answers HTTP 204 for an extension whose manifest requires Chrome 140, and with
/// `prodversion=141.0.0.0` it redirects to the package. Google ignores non-Chrome User-Agents on
/// this request, so a Chrome-like User-Agent is sent to this endpoint only.
struct ChromeWebStoreSource: Sendable {
    static let defaultProductVersion = "141.0.0.0"
    static let maximumRedirects = 5
    let client: any ExtensionHTTPClient
    let productVersion: String
    let resolverBaseURL: URL

    init(client: any ExtensionHTTPClient = URLSessionExtensionHTTPClient(), productVersion: String = ChromeWebStoreSource.defaultProductVersion,
         resolverBaseURL: URL = URL(string: "https://clients2.google.com/service/update2/crx")!) {
        self.client = client
        self.productVersion = productVersion
        self.resolverBaseURL = resolverBaseURL
    }

    static func chromeUserAgent(productVersion: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(productVersion) Safari/537.36"
    }

    static func listingURL(for id: String) -> URL {
        URL(string: "https://chromewebstore.google.com/detail/\(id)")!
    }

    static func publisherLabel(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           let host = ExtensionCatalogIdentity.normalizedHost(url.host) { return host }
        return value
    }

    static func compatibilityNote(for id: String) -> String? {
        switch id.lowercased() {
        case "fdjamakpfbbddfjaooikfcpapjohcfmg":
            return "Dashlane's Chrome build opens its welcome popup and annotates login forms in Bam. Startup connection errors remain; sign-in and autofill are unverified."
        case "aeblfdkhhhdcdjpifhhbdiojplfjncoa":
            return "1Password's Chrome build reaches its welcome page in Bam. Desktop-app integration is unavailable; sign-in and autofill are unverified."
        default: return nil
        }
    }

    static func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://chromewebstore.google.com")!
        components.path = "/search/" + query
        components.queryItems = [URLQueryItem(name: "hl", value: "en")]
        return components.url!
    }

    /// The public search page currently contains JSON search records. This is
    /// deliberately a best-effort adapter, not an undocumented RPC or a claim
    /// that Google provides a supported catalog API. No returned script runs.
    func search(_ query: String) async throws -> [ExtensionBuildCandidate] {
        var request = URLRequest(url: Self.searchURL(for: query))
        request.timeoutInterval = 15
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ExtensionPackageError("Chrome Web Store search answered HTTP \(response.statusCode).")
        }
        return try Self.searchCandidates(fromHTML: data)
    }

    static func searchCandidates(fromHTML data: Data) throws -> [ExtensionBuildCandidate] {
        guard data.count <= 4 * 1_048_576, let html = String(data: data, encoding: .utf8) else {
            throw ExtensionPackageError("Chrome Web Store search returned an unreadable or oversized page.")
        }
        var results: [ExtensionBuildCandidate] = [], seen = Set<String>(), parsed = false
        func visit(_ value: Any, depth: Int) {
            guard depth < 40, results.count < 20, let array = value as? [Any] else { return }
            if array.count > 7, let id = array[0] as? String, ExtensionStoreLink.isChromeWebStoreID(id),
               let name = array[2] as? String, !name.isEmpty, let summary = array[6] as? String,
               let rawPublisher = array[7] as? String, seen.insert(id).inserted {
                let publisher = publisherLabel(rawPublisher)
                // The manifest position has changed before. Recognize its keys,
                // not a numeric offset, and treat its metadata as store claims.
                let manifest = array.compactMap { $0 as? String }.first { $0.hasPrefix("{") && $0.contains("\"manifest_version\"") }
                    .flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let background = manifest?["background"] as? [String: Any]
                let kind: ExtensionBackgroundKind? = background?["service_worker"] is String ? .serviceWorker :
                    background?["page"] is String ? .page : background?["scripts"] is [String] ? .scripts : manifest != nil ? ExtensionBackgroundKind.none : nil
                let permissions = AMOSource.splitHostPatterns(manifest?["permissions"] as? [String] ?? [], hostPermissions: manifest?["host_permissions"] as? [String] ?? [])
                var homepage = (manifest?["homepage_url"] as? String).flatMap(URL.init(string:))
                if homepage == nil, publisher.contains("."), !publisher.contains(" ") { homepage = URL(string: "https://" + publisher) }
                let icon = (array[1] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                results.append(ExtensionBuildCandidate(source: .chromeWebStore, upstreamID: id, name: name, publisher: publisher,
                    version: manifest?["version"] as? String ?? "", manifestVersion: manifest?["manifest_version"] as? Int,
                    backgroundKind: kind, permissions: permissions.permissions, hostPermissions: permissions.hostPermissions,
                    homepage: homepage, listingURL: listingURL(for: id), iconURL: icon, summary: summary,
                    compatibilityNote: compatibilityNote(for: id)))
                return
            }
            for child in array { visit(child, depth: depth + 1) }
        }
        // Read only JSON arrays in Google's data callbacks. Balanced JSON scanning
        // handles nested arrays and brackets inside escaped manifest strings.
        for fragment in html.components(separatedBy: "AF_initDataCallback(").dropFirst() {
            let script = String(fragment.prefix(while: { $0 != "<" }))
            // ds:0 is generic page configuration (also present on consent/error
            // pages). Only the observed search dataset can establish an empty
            // search; a changed schema must yield a source availability notice.
            guard let marker = script.range(of: "data:"),
                  script[..<marker.lowerBound].range(of: #"key\s*:\s*['"]ds:1['"]"#, options: .regularExpression) != nil,
                  let start = script[marker.upperBound...].firstIndex(of: "[") else { continue }
            var nesting = 0, inString = false, escaped = false
            for index in script[start...].indices {
                let character = script[index]
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                } else if character == "\"" { inString = true }
                else if character == "[" { nesting += 1 }
                else if character == "]" {
                    nesting -= 1
                    if nesting == 0 {
                        let json = Data(script[start...index].utf8)
                        if let object = try? JSONSerialization.jsonObject(with: json) { parsed = true; visit(object, depth: 0) }
                        break
                    }
                }
            }
        }
        guard parsed else { throw ExtensionPackageError("Chrome Web Store search changed or is unavailable. Paste a listing link to install a specific extension.") }
        return results
    }

    func resolverURL(for id: String) -> URL {
        var components = URLComponents(url: resolverBaseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "response=redirect&prodversion=\(productVersion)&acceptformat=crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc"
        return components.url!
    }

    /// Parses `<ID_UPPER>_8_12_42_36.crx` into `8.12.42.36`; nil when the filename does not match the ID.
    static func version(fromPackageURL url: URL, id: String) -> String? {
        let filename = url.lastPathComponent
        guard filename.lowercased().hasSuffix(".crx") else { return nil }
        let stem = String(filename.dropLast(4))
        let prefix = id.uppercased() + "_"
        guard stem.uppercased().hasPrefix(prefix) else { return nil }
        let parts = stem.dropFirst(prefix.count).split(separator: "_", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.joined(separator: ".")
    }

    /// Resolves the current build for a store ID without downloading it. Name and publisher stay
    /// placeholders until the package is unpacked, since the resolver publishes neither.
    func candidate(for id: String) async throws -> ExtensionBuildCandidate {
        let id = id.lowercased()
        guard ExtensionStoreLink.isChromeWebStoreID(id) else { throw ExtensionPackageError("\(id) is not a Chrome Web Store ID.") }
        var url = resolverURL(for: id)
        var finalURL: URL?
        for _ in 0...Self.maximumRedirects {
            var request = URLRequest(url: url)
            request.setValue(Self.chromeUserAgent(productVersion: productVersion), forHTTPHeaderField: "User-Agent")
            let (_, response) = try await client.response(for: request, followingRedirects: false)
            switch response.statusCode {
            case 301, 302, 303, 307, 308:
                guard let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw ExtensionPackageError("The Chrome Web Store resolver redirected without a Location.")
                }
                guard next.scheme == "https" else { throw ExtensionPackageError("The Chrome Web Store resolver redirected to a non-HTTPS URL.") }
                if Self.version(fromPackageURL: next, id: id) != nil { finalURL = next } else { url = next; continue }
            case 204:
                throw ExtensionPackageError("The Chrome Web Store offers no build of \(id) for Chrome \(productVersion); the extension may require a newer browser version.")
            case 200..<300:
                finalURL = response.url ?? url
            default:
                throw ExtensionPackageError("The Chrome Web Store resolver answered HTTP \(response.statusCode) for \(id).")
            }
            break
        }
        guard let finalURL else { throw ExtensionPackageError("The Chrome Web Store resolver redirected too many times for \(id).") }
        return ExtensionBuildCandidate(
            source: .chromeWebStore, upstreamID: id, name: id, publisher: "",
            version: Self.version(fromPackageURL: finalURL, id: id) ?? "",
            downloadURL: finalURL, listingURL: Self.listingURL(for: id), compatibilityNote: Self.compatibilityNote(for: id))
    }

    /// Name, version and permissions from a downloaded package's manifest, with `__MSG_key__` names resolved.
    static func metadata(from unpackedManifestURL: URL) throws -> ExtensionManifestSummary {
        try ExtensionManifestSummary.read(manifestURL: unpackedManifestURL)
    }
}

// MARK: - Unified discovery

/// Store IDs, rather than names supplied by publishers, link the products whose
/// variants Bam has inspected. Keep this list small and evidence-backed.
enum ExtensionKnownProducts {
    struct Product: Sendable {
        var id: String
        var name: String
        var amoSlug: String
        var amoGUID: String
        var chromeID: String
        var safariID: String?
    }
    static let all: [Product] = [
        Product(id: "dashlane", name: "Dashlane", amoSlug: "dashlane", amoGUID: "jetpack-extension@dashlane.com", chromeID: "fdjamakpfbbddfjaooikfcpapjohcfmg", safariID: "517914548"),
        Product(id: "1password", name: "1Password", amoSlug: "1password-x-password-manager", amoGUID: "{d634138d-c276-4fc8-924b-40a0ea21d284}", chromeID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", safariID: "1569813296"),
        Product(id: "vidiq", name: "vidIQ", amoSlug: "vidiq-vision-youtube", amoGUID: "firefox@vid.io", chromeID: "pachckjkecffpdphbpmfolblodfkgbhl", safariID: nil),
        // Verified 2026-10-24 against bitwarden.com/download's three store links
        // and addons.mozilla.org/api/v5/addons/addon/bitwarden-password-manager/.
        Product(id: "bitwarden", name: "Bitwarden", amoSlug: "bitwarden-password-manager", amoGUID: "{446900e4-71c2-419f-a6a7-df9c091e268b}", chromeID: "nngceckbapebfimnlniiiahkandclblb", safariID: "1352778147")
    ]
    static func product(for candidate: ExtensionBuildCandidate) -> Product? {
        guard let id = candidate.upstreamID?.lowercased() else { return nil }
        return all.first { product in
            switch candidate.source {
            case .amo: return product.amoGUID.lowercased() == id
            case .chromeWebStore: return product.chromeID == id
            case .safariAppStore: return product.safariID == id
            case .directPackage, .local: return false
            }
        }
    }
    static func product(for link: ExtensionStoreLink) -> Product? {
        all.first { product in
            switch link {
            case .amo(let slug): return product.amoSlug == slug.lowercased() || product.amoGUID.lowercased() == slug.lowercased()
            case .chromeWebStore(let id): return product.chromeID == id.lowercased()
            case .safariAppStore(let id): return product.safariID == id
            case .directPackage: return false
            }
        }
    }
}

/// The Mac App Store distributes containing apps, not downloadable extension
/// archives. These records remain explicit App Store handoffs until Bam has a
/// tested signed-app-extension import route.
struct SafariAppStoreSource: Sendable {
    let client: any ExtensionHTTPClient
    static let availabilityNote = "Bam can add the signed WebExtension from this app after it is installed through the App Store. Native companion-app features are unavailable; Safari account data is not imported."

    static func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: query), URLQueryItem(name: "entity", value: "macSoftware"),
                                 URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "country", value: "us")]
        return components.url!
    }
    static func lookupURL(for id: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "entity", value: "macSoftware"), URLQueryItem(name: "country", value: "us")]
        return components.url!
    }
    private func records(at url: URL) async throws -> [[String: Any]] {
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode), data.count <= 4 * 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["results"] as? [[String: Any]] else {
            throw ExtensionPackageError("Safari's App Store catalog is temporarily unavailable.")
        }
        return rows
    }
    static func candidate(from object: [String: Any], requireSafariMention: Bool = true) -> ExtensionBuildCandidate? {
        guard let number = object["trackId"] as? NSNumber, let name = object["trackName"] as? String,
              let rawURL = object["trackViewUrl"] as? String, let url = URL(string: rawURL),
              url.scheme == "https", url.host == "apps.apple.com" else { return nil }
        let id = number.stringValue, description = object["description"] as? String ?? ""
        let text = (name + " " + description).lowercased()
        let known = ExtensionKnownProducts.all.contains { $0.safariID == id }
        guard !requireSafariMention || known || (text.contains("safari") && text.contains("extension")) else { return nil }
        return ExtensionBuildCandidate(source: .safariAppStore, upstreamID: id, name: name,
            publisher: object["sellerName"] as? String ?? object["artistName"] as? String ?? "",
            version: object["version"] as? String ?? "", homepage: (object["sellerUrl"] as? String).flatMap(URL.init(string:)),
            listingURL: url, iconURL: (object["artworkUrl100"] as? String).flatMap(URL.init(string:)),
            summary: description.components(separatedBy: "\n").first, compatibilityNote: availabilityNote,
            applicationBundleIdentifier: object["bundleId"] as? String)
    }
    func search(_ query: String) async throws -> [ExtensionBuildCandidate] {
        try await records(at: Self.searchURL(for: query)).compactMap { Self.candidate(from: $0) }
    }
    func candidate(for id: String) async throws -> ExtensionBuildCandidate {
        guard !id.isEmpty, id.count <= 20, id.allSatisfy(\.isNumber),
              let candidate = try await records(at: Self.lookupURL(for: id)).compactMap({ Self.candidate(from: $0) }).first(where: { $0.upstreamID == id }) else {
            throw ExtensionPackageError("That App Store listing does not identify a Safari extension available in the Mac catalog.")
        }
        return candidate
    }
}

struct ExtensionCatalogSearchResult: Sendable {
    var candidates: [ExtensionBuildCandidate]
    var notices: [String]
}

struct ExtensionCatalogSearch: Sendable {
    let amo: AMOSource
    let chrome: ChromeWebStoreSource
    let safari: SafariAppStoreSource
    init(client: any ExtensionHTTPClient = URLSessionExtensionHTTPClient(), bamVersion: String) {
        amo = AMOSource(client: client, bamVersion: bamVersion)
        chrome = ChromeWebStoreSource(client: client)
        safari = SafariAppStoreSource(client: client)
    }
    private func attempt(_ label: String, operation: @Sendable () async throws -> [ExtensionBuildCandidate]) async -> ExtensionCatalogSearchResult {
        do { return ExtensionCatalogSearchResult(candidates: try await operation(), notices: []) }
        catch { return ExtensionCatalogSearchResult(candidates: [], notices: ["\(label) is unavailable. Results from other stores are still shown."]) }
    }
    static func combine(_ results: [ExtensionCatalogSearchResult]) -> ExtensionCatalogSearchResult {
        var seen = Set<String>()
        let candidates = results.flatMap(\.candidates).filter {
            seen.insert($0.source.rawValue + ":" + ($0.upstreamID ?? $0.listingURL?.absoluteString ?? $0.name)).inserted
        }
        return ExtensionCatalogSearchResult(candidates: candidates, notices: Array(Set(results.flatMap(\.notices))).sorted())
    }

    static func normalizedSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Source APIs use different ranking systems. Put direct name matches ahead
    /// of broad recommendations across the combined results, while keeping the
    /// original store/API order for equal relevance.
    static func ranked(_ candidates: [ExtensionBuildCandidate], for query: String) -> [ExtensionBuildCandidate] {
        let query = normalizedSearchText(query)
        guard !query.isEmpty else { return candidates }
        let queryWords = query.split(separator: " ")
        func rank(_ candidate: ExtensionBuildCandidate) -> Int {
            let title = normalizedSearchText(candidate.name)
            if title == query { return 0 }
            if title.hasPrefix(query + " ") { return 1 }
            if (" " + title + " ").contains(" " + query + " ") { return 2 }
            let titleWords = Set(title.split(separator: " "))
            if queryWords.allSatisfy({ titleWords.contains($0) }) { return 3 }
            if title.contains(query) { return 4 }
            return 5
        }
        return candidates.enumerated().map { (index: $0.offset, candidate: $0.element, rank: rank($0.element)) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }.map(\.candidate)
    }
    func search(_ query: String) async -> ExtensionCatalogSearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await featured() }
        async let firefox = attempt("Firefox Add-ons") { try await amo.search(query) }
        async let google = attempt("Chrome Web Store search") { try await chrome.search(query) }
        async let apple = attempt("Safari App Store search") { try await safari.search(query) }
        var combined = await Self.combine([firefox, google, apple])
        combined.candidates = Self.ranked(combined.candidates, for: query)
        return combined
    }
    func featured() async -> ExtensionCatalogSearchResult {
        // Query live stores once for each familiar product. No invented versions,
        // stale download links, or unsupported installation claims are cached.
        await withTaskGroup(of: (Int, ExtensionCatalogSearchResult).self) { group in
            for (index, product) in ExtensionKnownProducts.all.enumerated() {
                group.addTask { (index, await search(product.name)) }
            }
            var values: [(Int, ExtensionCatalogSearchResult)] = []
            for await value in group { values.append(value) }
            let merged = Self.combine(values.sorted { $0.0 < $1.0 }.map(\.1))
            return ExtensionCatalogSearchResult(candidates: merged.candidates.filter { ExtensionKnownProducts.product(for: $0) != nil }, notices: merged.notices)
        }
    }
    func resolve(_ link: ExtensionStoreLink) async throws -> ExtensionCatalogSearchResult {
        let exact: ExtensionBuildCandidate
        switch link {
        case .amo(let slug): exact = try await amo.addon(slug)
        case .chromeWebStore(let id):
            var candidate = try await chrome.candidate(for: id)
            if let product = ExtensionKnownProducts.product(for: link) { candidate.name = product.name }
            exact = candidate
        case .safariAppStore(let id): exact = try await safari.candidate(for: id)
        case .directPackage(let url): exact = .direct(url)
        }
        guard let product = ExtensionKnownProducts.product(for: link) else { return ExtensionCatalogSearchResult(candidates: [exact], notices: []) }
        let alternatives = await search(product.name)
        // Prefer search metadata to the Chrome resolver's placeholders, but retain
        // the exact requested build even if the store search is unavailable.
        return Self.combine([ExtensionCatalogSearchResult(candidates: alternatives.candidates.filter { ExtensionKnownProducts.product(for: $0)?.id == product.id }, notices: alternatives.notices),
                             ExtensionCatalogSearchResult(candidates: [exact], notices: [])])
    }
}

// MARK: - Manifest summary

/// The listing-relevant parts of an unpacked package's manifest.json.
struct ExtensionManifestSummary: Sendable, Equatable {
    var name: String
    var description: String?
    var version: String
    var manifestVersion: Int?
    var backgroundKind: ExtensionBackgroundKind
    var permissions: [String]
    var hostPermissions: [String]
    var homepage: URL?
    var defaultLocale: String?

    static func read(fromUnpackedPackage packageURL: URL) throws -> ExtensionManifestSummary {
        try read(manifestURL: packageURL.appendingPathComponent("manifest.json"))
    }

    static func read(manifestURL: URL) throws -> ExtensionManifestSummary {
        let packageURL = manifestURL.deletingLastPathComponent()
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= ExtensionZipArchive.maximumManifestBytes else {
            throw ExtensionPackageError("The extension manifest must be a regular file no larger than 1 MiB.")
        }
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw ExtensionPackageError("The extension manifest must be a JSON object.")
        }
        let defaultLocale = manifest["default_locale"] as? String
        func resolve(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            return resolveMessages(in: string, packageURL: packageURL, defaultLocale: defaultLocale)
        }
        let manifestVersion = manifest["manifest_version"] as? Int
        var kind = ExtensionBackgroundKind.none
        if let background = manifest["background"] as? [String: Any] {
            if background["service_worker"] is String { kind = .serviceWorker }
            else if background["page"] is String { kind = .page }
            else if let scripts = background["scripts"] as? [String], !scripts.isEmpty { kind = .scripts }
        }
        let (permissions, hostPermissions) = AMOSource.splitHostPatterns(manifest["permissions"] as? [String] ?? [],
                                                                         hostPermissions: manifest["host_permissions"] as? [String] ?? [])
        return ExtensionManifestSummary(
            name: resolve(manifest["name"]) ?? "",
            description: resolve(manifest["description"]),
            version: manifest["version"] as? String ?? "",
            manifestVersion: manifestVersion,
            backgroundKind: kind,
            permissions: permissions,
            hostPermissions: hostPermissions,
            homepage: (manifest["homepage_url"] as? String).flatMap(URL.init(string:)),
            defaultLocale: defaultLocale)
    }

    /// Replaces every `__MSG_key__` with the message from `_locales/<default_locale>/messages.json`,
    /// then `en`, then `en_US`. Keys match case-insensitively, as Chrome treats them. Unknown keys stay verbatim.
    static func resolveMessages(in value: String, packageURL: URL, defaultLocale: String?) -> String {
        guard value.contains("__MSG_") else { return value }
        var locales: [String] = []
        for locale in [defaultLocale, "en", "en_US"].compactMap({ $0 }) where !locales.contains(locale) { locales.append(locale) }
        var tables: [[String: Any]] = []
        for locale in locales {
            guard !locale.contains("/"), !locale.contains(".."), !locale.isEmpty else { continue }
            let url = packageURL.appendingPathComponent("_locales").appendingPathComponent(locale).appendingPathComponent("messages.json")
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= ExtensionZipArchive.maximumManifestBytes,
                  let data = try? Data(contentsOf: url), let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            tables.append(table)
        }
        guard !tables.isEmpty, let regex = try? NSRegularExpression(pattern: "__MSG_([A-Za-z0-9_@]+)__") else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: value), let wholeRange = Range(match.range, in: value) else { continue }
            let key = String(value[keyRange])
            for table in tables {
                let entry = table[key] as? [String: Any] ?? table.first { $0.key.lowercased() == key.lowercased() }?.value as? [String: Any]
                if let message = entry?["message"] as? String {
                    result.replaceSubrange(wholeRange, with: message)
                    break
                }
            }
        }
        return result
    }
}

// MARK: - Fetch pipeline

enum ExtensionPackageFormat: String, Sendable, Codable {
    case crx3, zip
}

/// How much the fetched bytes can be trusted; the UI must show this alongside source and publisher.
enum ExtensionPackageProvenance: Sendable, Equatable {
    /// Served over TLS and matching the SHA-256 that addons.mozilla.org published for the file.
    case amoHashMatched
    /// The CRX3 publisher signature verified over the whole payload; the derived ID is attached.
    case crx3SignatureVerified(id: String)
    /// A plain ZIP or XPI from a pasted URL with no hash to compare against: TLS only.
    case unverifiedDirectDownload
    /// A package file chosen from local disk.
    case local
}

struct ExtensionFetchedPackage: Sendable {
    /// The unpacked package directory (manifest.json at its root).
    let packageURL: URL
    /// The downloaded archive as received.
    let archiveURL: URL
    let sha256: String
    let format: ExtensionPackageFormat
    let crxVerification: ExtensionCrxPackage.Verification?
    /// The candidate with manifest-derived fields filled in.
    let candidate: ExtensionBuildCandidate
    let provenance: ExtensionPackageProvenance
}

/// Downloads a candidate into a staging directory, checks its hash and signature, and unpacks it.
struct ExtensionPackageFetch: Sendable {
    static let maximumDownloadBytes = ExtensionZipArchive.maximumTotalBytes
    let client: any ExtensionHTTPClient
    let userAgent: String

    init(client: any ExtensionHTTPClient = URLSessionExtensionHTTPClient(), bamVersion: String) {
        self.client = client
        self.userAgent = AMOSource.userAgent(bamVersion: bamVersion)
    }

    /// `staging` is created if needed and receives `download.<ext>` and `package/`; the caller owns and removes it.
    func fetch(_ candidate: ExtensionBuildCandidate, into staging: URL) async throws -> ExtensionFetchedPackage {
        guard let source = candidate.downloadURL else { throw ExtensionPackageError("The build has no download URL.") }
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let archiveURL = staging.appendingPathComponent("download." + (source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()))
        if fm.fileExists(atPath: archiveURL.path) { try fm.removeItem(at: archiveURL) }
        if source.isFileURL {
            guard candidate.source == .local else { throw ExtensionPackageError("Only local candidates may use file URLs.") }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= Self.maximumDownloadBytes else {
                throw ExtensionPackageError("The local package must be a regular file no larger than 100 MiB.")
            }
            try fm.copyItem(at: source, to: archiveURL)
        } else {
            guard source.scheme?.lowercased() == "https" else { throw ExtensionPackageError("Packages are only downloaded over HTTPS.") }
            var request = URLRequest(url: source)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let response = try await client.download(for: request, to: archiveURL, byteLimit: Self.maximumDownloadBytes)
            guard (200..<300).contains(response.statusCode) else {
                try? fm.removeItem(at: archiveURL)
                throw ExtensionPackageError("The package download answered HTTP \(response.statusCode).")
            }
        }

        let sha256 = try ExtensionPackageDigest.sha256(ofFileAt: archiveURL)
        if candidate.expectedSHA256 != nil {
            guard let expected = candidate.normalizedExpectedSHA256 else {
                throw ExtensionPackageError("The published SHA-256 for this build is malformed; refusing to install without a checkable hash.")
            }
            guard expected == sha256 else {
                throw ExtensionPackageError("The downloaded package's SHA-256 (\(sha256)) does not match the published hash (\(expected)).")
            }
        }

        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let packageURL = staging.appendingPathComponent("package", isDirectory: true)
        if fm.fileExists(atPath: packageURL.path) { try fm.removeItem(at: packageURL) }
        var format: ExtensionPackageFormat
        var verification: ExtensionCrxPackage.Verification?
        if ExtensionCrxPackage.looksLikeCRX(data) {
            format = .crx3
            let crx = try ExtensionCrxPackage(data: data)
            let expectedID = candidate.source == .chromeWebStore ? candidate.upstreamID : nil
            let result = crx.verify(expectedID: expectedID)
            guard result.verified else {
                throw ExtensionPackageError("The CRX signature could not be verified: \(result.failure ?? "unknown failure")")
            }
            verification = result
            try ExtensionZipArchive(data: crx.payloadZIP).extract(to: packageURL)
        } else if ExtensionZipArchive.looksLikeZip(data) {
            format = .zip
            try ExtensionZipArchive(data: data).extract(to: packageURL)
        } else {
            throw ExtensionPackageError("The download is neither a CRX nor a ZIP package.")
        }

        let provenance: ExtensionPackageProvenance
        if let verification {
            provenance = .crx3SignatureVerified(id: verification.extensionID)
        } else if candidate.source == .local {
            provenance = .local
        } else if candidate.source == .amo, candidate.normalizedExpectedSHA256 == sha256 {
            provenance = .amoHashMatched
        } else {
            provenance = .unverifiedDirectDownload
        }
        var enriched = candidate
        if let summary = try? ExtensionManifestSummary.read(fromUnpackedPackage: packageURL) { enriched = candidate.applying(summary) }
        if enriched.upstreamID == nil, let verification { enriched.upstreamID = verification.extensionID }
        return ExtensionFetchedPackage(packageURL: packageURL, archiveURL: archiveURL, sha256: sha256, format: format,
                                       crxVerification: verification, candidate: enriched, provenance: provenance)
    }
}
