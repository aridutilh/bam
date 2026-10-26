import Foundation
import CryptoKit
import Security

@main struct ExtensionCatalogTests {
    static var checks = 0
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
        checks += 1
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CheckFailure(description: "Usage: catalog-tests <scoped temporary directory>")
            }
            try await run(in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("Extension catalog: \(checks) checks passed")
        } catch {
            fputs("FAIL: Extension catalog: \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: Fake transport

    final class FakeClient: ExtensionHTTPClient, @unchecked Sendable {
        struct Route {
            var status: Int
            var headers: [String: String] = [:]
            var body: Data = Data()
            var finalURL: URL? = nil
        }
        var routes: [String: Route] = [:]
        var requests: [URLRequest] = []
        private let lock = NSLock()

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let route = lock.withLock { requests.append(request); return routes[request.url?.absoluteString ?? ""] }
            guard let url = request.url, let route else {
                throw CheckFailure(description: "unexpected request: \(request.url?.absoluteString ?? "nil")")
            }
            let response = HTTPURLResponse(url: route.finalURL ?? url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
            return (route.body, response)
        }

        func userAgent(forRequestTo fragment: String) -> String? {
            requests.last { $0.url?.absoluteString.contains(fragment) == true }?.value(forHTTPHeaderField: "User-Agent")
        }
    }

    // MARK: Fixture builders (stored ZIP, CRX3)

    static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    static func le32(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)] }

    static func zip(_ files: [(String, Data)]) -> Data {
        var body = Data(), central = Data()
        for (name, data) in files {
            let nameBytes = Array(name.utf8), crc = ExtensionCRC32.checksum(data), offset = UInt32(body.count)
            body.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0))
            body.append(contentsOf: nameBytes)
            body.append(data)
            central.append(contentsOf: le32(0x0201_4B50) + le16(0x031E) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: nameBytes)
        }
        var archive = body
        archive.append(central)
        archive.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(UInt32(central.count)) + le32(UInt32(body.count)) + le16(0))
        return archive
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, out: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value != 0 { byte |= 0x80 }; out.append(byte) } while value != 0
        return out
    }
    static func field(_ number: UInt64, _ bytes: Data) -> Data { Data(varint(number << 3 | 2) + varint(UInt64(bytes.count))) + bytes }
    static func derLength(_ length: Int) -> [UInt8] {
        length < 0x80 ? [UInt8(length)] : length <= 0xFF ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
    }

    struct TestKey {
        let privateKey: SecKey
        let spki: Data
        var id: String { ExtensionCrxPackage.extensionID(forPublicKey: spki) }
    }

    static func makeKey() throws -> TestKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CheckFailure(description: "key generation failed: \(String(describing: error?.takeRetainedValue()))")
        }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = [0x03] + derLength(pkcs1.count + 1) + [0x00] + [UInt8](pkcs1)
        let content = algorithm + bitString
        return TestKey(privateKey: privateKey, spki: Data([0x30] + derLength(content.count) + content))
    }

    static func crx(payload: Data, key: TestKey) throws -> Data {
        let signedData = field(1, Data(SHA256.hash(data: key.spki).prefix(16)))
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        message.append(contentsOf: le32(UInt32(signedData.count)))
        message.append(signedData)
        message.append(payload)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key.privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data? else {
            throw CheckFailure(description: "signing failed")
        }
        let header = field(2, field(1, key.spki) + field(2, signature)) + field(10000, signedData)
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: le32(3) + le32(UInt32(header.count)))
        crx.append(header)
        crx.append(payload)
        return crx
    }

    static func manifest(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    // MARK: Suite

    static func run(in parent: URL) async throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("catalog-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func rejects<T>(_ label: String, containing fragment: String? = nil, _ body: () async throws -> T) async throws {
            do { _ = try await body() } catch {
                let text = "\(error)"
                try check(fragment == nil || text.contains(fragment!), "\(label): error mentions '\(fragment ?? "")' (got \(text))")
                return
            }
            throw CheckFailure(description: "\(label): expected a rejection")
        }

        // Link parsing
        let cwsID = "pachckjkecffpdphbpmfolblodfkgbhl"
        let table: [(String, ExtensionStoreLink?)] = [
            ("https://addons.mozilla.org/en-US/firefox/addon/vidiq-vision-youtube/", .amo(slug: "vidiq-vision-youtube")),
            ("https://addons.mozilla.org/firefox/addon/ublock-origin", .amo(slug: "ublock-origin")),
            ("https://ADDONS.MOZILLA.ORG/de/firefox/addon/some_addon.v2/reviews/?src=search", .amo(slug: "some_addon.v2")),
            ("  https://addons.mozilla.org/pt-BR/firefox/addon/x/versions/ ", .amo(slug: "x")),
            ("https://addons.mozilla.org/en-US/android/addon/x/", nil),
            ("https://addons.mozilla.org/en-US/firefox/collections/x/", nil),
            ("https://addons.mozilla.org/firefox/downloads/file/4321/vidiq-1.2.3.xpi", .directPackage(URL(string: "https://addons.mozilla.org/firefox/downloads/file/4321/vidiq-1.2.3.xpi")!)),
            ("https://chromewebstore.google.com/detail/vidiq-vision-for-youtube/\(cwsID)", .chromeWebStore(id: cwsID)),
            ("https://chromewebstore.google.com/detail/\(cwsID)?hl=en", .chromeWebStore(id: cwsID)),
            ("https://chrome.google.com/webstore/detail/vidiq/\(cwsID)", .chromeWebStore(id: cwsID)),
            ("https://ChromeWebStore.google.com/detail/name/\(cwsID.uppercased())", .chromeWebStore(id: cwsID)),
            ("https://chromewebstore.google.com/detail/name/abcdefghijklmnopabcdefghijklmnoq", nil),
            ("https://chromewebstore.google.com/detail/name/abcdefghijklmnop", nil),
            ("https://chromewebstore.google.com/category/extensions", nil),
            ("https://example.com/path/pkg.CRX?download=1", .directPackage(URL(string: "https://example.com/path/pkg.CRX?download=1")!)),
            ("https://example.com/pkg.zip", .directPackage(URL(string: "https://example.com/pkg.zip")!)),
            ("http://example.com/pkg.zip", nil),
            ("http://addons.mozilla.org/en-US/firefox/addon/x/", nil),
            ("https://example.com/pkg.tar.gz", nil),
            ("https://example.com/", nil),
            ("not a url", nil),
            ("", nil)
        ]
        for (text, expected) in table {
            try check(ExtensionStoreLink(parsing: text) == expected, "Link parse of \(text.debugDescription) yields \(String(describing: expected))")
        }
        try check(ExtensionStoreLink.amo(slug: "x").sourceKind == .amo && ExtensionStoreLink.chromeWebStore(id: cwsID).sourceKind == .chromeWebStore, "Links map to source kinds")

        // AMO adapter
        let client = FakeClient()
        let amo = AMOSource(client: client, bamVersion: "0.16.0")
        let addonJSON: [String: Any] = [
            "guid": "{a5d8f3a1-0000-4000-8000-000000000001}", "slug": "vidiq-vision-youtube",
            "name": ["en-US": "vidIQ Vision for YouTube", "de": "vidIQ"],
            "authors": [["name": "vidIQ", "url": "https://addons.mozilla.org/en-US/firefox/user/1/"]],
            "homepage": ["url": ["en-US": "https://www.vidiq.com/"], "outgoing": ["en-US": "https://prod.outgoing.prod.webservices.mozgcp.net/x"]],
            "last_updated": "2026-09-30T10:00:00Z",
            "current_version": [
                "version": "3.146.0",
                "file": ["url": "https://addons.mozilla.org/firefox/downloads/file/4567/vidiq_vision_for_youtube-3.146.0.xpi", "size": 123_456,
                         "hash": "sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                         "permissions": ["storage", "tabs", "*://*.youtube.com/*", "<all_urls>"], "created": "2026-09-29T08:30:00Z"]
            ]
        ]
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/vidiq-vision-youtube/?lang=en-US"] = .init(status: 200, body: try JSONSerialization.data(withJSONObject: addonJSON))
        let candidate = try await amo.addon("vidiq-vision-youtube")
        try check(client.userAgent(forRequestTo: "/api/v5/addons/addon/") == "Bam/0.16.0 (+https://bambrowser.com)", "AMO requests carry the Bam User-Agent")
        try check(candidate.source == .amo && candidate.upstreamID == "{a5d8f3a1-0000-4000-8000-000000000001}" && candidate.name == "vidIQ Vision for YouTube" &&
                  candidate.publisher == "vidIQ" && candidate.version == "3.146.0" && candidate.size == 123_456, "AMO add-on fields map to the candidate")
        try check(candidate.downloadURL?.absoluteString == "https://addons.mozilla.org/firefox/downloads/file/4567/vidiq_vision_for_youtube-3.146.0.xpi" &&
                  candidate.expectedSHA256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" &&
                  candidate.normalizedExpectedSHA256 == candidate.expectedSHA256, "The AMO hash is split from its sha256: prefix and lowercased")
        try check(candidate.permissions == ["storage", "tabs"] && candidate.hostPermissions == ["*://*.youtube.com/*", "<all_urls>"], "Host patterns are separated from API permissions")
        try check(candidate.homepage?.absoluteString == "https://www.vidiq.com/" && candidate.listingURL?.absoluteString == "https://addons.mozilla.org/firefox/addon/vidiq-vision-youtube/",
                  "Localized homepage and listing URL resolve")
        try check(candidate.releasedAt == ISO8601DateFormatter().date(from: "2026-09-29T08:30:00Z") && candidate.manifestVersion == nil && candidate.backgroundKind == nil,
                  "Release date comes from the file; unpack-only fields stay nil")
        var stringForms = addonJSON
        stringForms["name"] = "Plain Name"
        stringForms["homepage"] = ["url": "https://plain.example", "outgoing": "x"]
        stringForms["guid"] = "plain@example.com"
        stringForms["authors"] = [["name": "A"], ["name": "B"]]
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/plain@example.com/?lang=en-US"] = .init(status: 200, body: try JSONSerialization.data(withJSONObject: stringForms))
        let plain = try await amo.addon("plain@example.com")
        try check(plain.name == "Plain Name" && plain.homepage?.host == "plain.example" && plain.publisher == "A, B", "Plain-string localized fields and multiple authors are handled")
        var mixedHosts = addonJSON
        mixedHosts["current_version"] = ["version": "1", "file": ["url": "https://addons.mozilla.org/f.xpi", "permissions": ["storage", "*://a.example/*", "<all_urls>"], "host_permissions": ["<all_urls>"]]]
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/mixed/?lang=en-US"] = .init(status: 200, body: try JSONSerialization.data(withJSONObject: mixedHosts))
        let mixed = try await amo.addon("mixed")
        try check(mixed.permissions == ["storage"] && mixed.hostPermissions == ["<all_urls>", "*://a.example/*"], "Host patterns listed under permissions join host_permissions without duplicates")
        var defaultForm = addonJSON
        defaultForm["name"] = ["_default": "fr", "fr": "Nom"]
        defaultForm["homepage"] = NSNull()
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/fr/?lang=en-US"] = .init(status: 200, body: try JSONSerialization.data(withJSONObject: defaultForm))
        let french = try await amo.addon("fr")
        try check(french.name == "Nom" && french.homepage == nil, "The _default locale is honored and a null homepage is tolerated")
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/missing/?lang=en-US"] = .init(status: 404, body: Data("{\"detail\":\"Not found.\"}".utf8))
        try await rejects("amo-404", containing: "HTTP 404") { try await amo.addon("missing") }
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/broken/?lang=en-US"] = .init(status: 200, body: Data("[]".utf8))
        try await rejects("amo-not-object", containing: "JSON object") { try await amo.addon("broken") }
        var noFile = addonJSON
        noFile["current_version"] = ["version": "1"]
        client.routes["https://addons.mozilla.org/api/v5/addons/addon/nofile/?lang=en-US"] = .init(status: 200, body: try JSONSerialization.data(withJSONObject: noFile))
        try await rejects("amo-no-file", containing: "downloadable") { try await amo.addon("nofile") }
        client.routes["https://addons.mozilla.org/api/v5/addons/search/?q=vid%20iq&app=firefox&type=extension&sort=users&page_size=10&lang=en-US"] =
            .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["results": [addonJSON, stringForms, ["guid": "junk"]]]))
        let results = try await amo.search("vid iq")
        try check(results.count == 2 && results[0].name == "vidIQ Vision for YouTube" && results[1].name == "Plain Name", "Search maps every well-formed result and skips malformed ones")

        // Chrome Web Store adapter
        let cws = ChromeWebStoreSource(client: client)
        let resolver = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=141.0.0.0&acceptformat=crx3&x=id%3D\(cwsID)%26installsource%3Dondemand%26uc"
        try check(cws.resolverURL(for: cwsID).absoluteString == resolver, "The resolver URL matches Google's documented shape with prodversion 141.0.0.0")
        let blob = "https://clients2.googleusercontent.com/crx/blobs/AVDNL_abc123/\(cwsID.uppercased())_8_12_42_36.crx"
        client.routes[resolver] = .init(status: 302, headers: ["Location": blob])
        let cwsCandidate = try await cws.candidate(for: cwsID)
        try check(client.userAgent(forRequestTo: "update2/crx")?.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36") == true &&
                  client.userAgent(forRequestTo: "update2/crx")?.contains("Chrome/141.0.0.0") == true, "The resolver request carries a Chrome-like User-Agent")
        try check(cwsCandidate.source == .chromeWebStore && cwsCandidate.upstreamID == cwsID && cwsCandidate.version == "8.12.42.36" &&
                  cwsCandidate.downloadURL?.absoluteString == blob && cwsCandidate.listingURL?.absoluteString == "https://chromewebstore.google.com/detail/\(cwsID)",
                  "The CWS candidate takes its version from the redirect filename before downloading")
        try check(cwsCandidate.name == cwsID && cwsCandidate.publisher.isEmpty && cwsCandidate.expectedSHA256 == nil, "CWS resolution publishes no name, publisher or hash")
        let hop = "https://clients2.google.com/service/update2/crx/hop"
        client.routes[resolver] = .init(status: 302, headers: ["Location": "/service/update2/crx/hop"])
        client.routes[hop] = .init(status: 307, headers: ["Location": blob])
        try check(try await cws.candidate(for: cwsID).downloadURL?.absoluteString == blob, "Relative redirect chains are followed to the package")
        client.routes[hop] = .init(status: 302, headers: ["Location": hop])
        try await rejects("cws-redirect-loop", containing: "too many") { try await cws.candidate(for: cwsID) }
        client.routes[resolver] = .init(status: 204)
        try await rejects("cws-204", containing: "no build") { try await cws.candidate(for: cwsID) }
        let old = ChromeWebStoreSource(client: client, productVersion: "130.0.0.0")
        client.routes[resolver.replacingOccurrences(of: "141.0.0.0", with: "130.0.0.0")] = .init(status: 204)
        try await rejects("cws-204-old-version", containing: "Chrome 130.0.0.0") { try await old.candidate(for: cwsID) }
        client.routes[resolver] = .init(status: 302, headers: ["Location": "http://clients2.googleusercontent.com/x.crx"])
        try await rejects("cws-http-redirect", containing: "HTTPS") { try await cws.candidate(for: cwsID) }
        client.routes[resolver] = .init(status: 500)
        try await rejects("cws-500", containing: "HTTP 500") { try await cws.candidate(for: cwsID) }
        try await rejects("cws-bad-id", containing: "not a Chrome Web Store ID") { try await cws.candidate(for: "nope") }
        try check(ChromeWebStoreSource.version(fromPackageURL: URL(string: blob)!, id: cwsID) == "8.12.42.36" &&
                  ChromeWebStoreSource.version(fromPackageURL: URL(string: "https://x/\(cwsID.uppercased())_1_0.crx")!, id: cwsID.uppercased()) == "1.0" &&
                  ChromeWebStoreSource.version(fromPackageURL: URL(string: "https://x/OTHER_1_0.crx")!, id: cwsID) == nil &&
                  ChromeWebStoreSource.version(fromPackageURL: URL(string: "https://x/\(cwsID.uppercased())_1_a.crx")!, id: cwsID) == nil &&
                  ChromeWebStoreSource.version(fromPackageURL: URL(string: "https://x/\(cwsID.uppercased())_1_0.zip")!, id: cwsID) == nil,
                  "Filename version parsing accepts only <ID>_<digits...>.crx")

        // Unified public search: original miniature records, not vendor code.
        let searchManifest = String(data: try manifest(["manifest_version": 3, "name": "__MSG_title__", "version": "2.4",
            "background": ["service_worker": "worker.js"], "permissions": ["storage", "https://example.com/*"],
            "description": "A bracket ] and a quoted \"word\"", "homepage_url": "https://vendor.example"]), encoding: .utf8)!
        let chromeSearchRow: [Any] = [cwsID, "https://images.example/icon.png", "Fixture Tool", 4.8, 100, "https://images.example/banner.png",
                                     "A useful fixture", "Vendor", NSNull(), searchManifest]
        func chromePage(_ rows: [Any]) throws -> Data {
            let json = String(data: try JSONSerialization.data(withJSONObject: [rows]), encoding: .utf8)!
            return Data("<script>AF_initDataCallback({key: 'ds:1', data:\(json), sideChannel: {}});</script>".utf8)
        }
        let searchHTML = try chromePage([chromeSearchRow, chromeSearchRow, ["invalid", "x", "Fake"]])
        let chromeSearchCandidates = try ChromeWebStoreSource.searchCandidates(fromHTML: searchHTML)
        try check(chromeSearchCandidates.count == 1 && chromeSearchCandidates[0].name == "Fixture Tool" &&
                  chromeSearchCandidates[0].version == "2.4" && chromeSearchCandidates[0].backgroundKind == .serviceWorker &&
                  chromeSearchCandidates[0].iconURL?.host == "images.example", "Chrome search reads display metadata and manifest while removing duplicate IDs")
        try check(chromeSearchCandidates[0].permissions == ["storage"] && chromeSearchCandidates[0].hostPermissions == ["https://example.com/*"] &&
                  chromeSearchCandidates[0].downloadURL == nil && chromeSearchCandidates[0].canInstallInBam,
                  "Chrome search preserves host permissions and defers package resolution until install")
        try check(try ChromeWebStoreSource.searchCandidates(fromHTML: chromePage([])).isEmpty, "A valid empty Chrome result array is an empty search")
        try await rejects("chrome-search-schema", containing: "changed") {
            try ChromeWebStoreSource.searchCandidates(fromHTML: Data("<html>changed layout</html>".utf8))
        }
        try await rejects("chrome-search-generic-page", containing: "changed") {
            try ChromeWebStoreSource.searchCandidates(fromHTML: Data("<script>AF_initDataCallback({key: 'ds:0', data:[[1,0]], sideChannel: {}});</script>".utf8))
        }
        try await rejects("chrome-search-size", containing: "oversized") {
            try ChromeWebStoreSource.searchCandidates(fromHTML: Data(repeating: 32, count: 4 * 1_048_576 + 1))
        }
        try check(ChromeWebStoreSource.searchURL(for: "password & privacy").absoluteString.contains("password%20&%20privacy"), "Chrome search text is encoded as one URL path")

        var safariRecord: [String: Any] = ["trackId": 1569813296, "trackName": "1Password for Safari", "sellerName": "AgileBits Inc.",
            "version": "8.0", "trackViewUrl": "https://apps.apple.com/us/app/1password-for-safari/id1569813296", "description": "A Safari extension.",
            "artworkUrl100": "https://images.example/safari.png"]
        let safariCandidate = SafariAppStoreSource.candidate(from: safariRecord)!
        try check(safariCandidate.source == .safariAppStore && !safariCandidate.canInstallInBam && safariCandidate.downloadURL == nil &&
                  safariCandidate.compatibilityNote?.contains("installed through the App Store") == true, "App Store results without an exact containing-app identity cannot be imported")
        safariRecord["bundleId"] = "com.example.safari-fixture"
        let importableSafari = SafariAppStoreSource.candidate(from: safariRecord)!
        try check(importableSafari.canInstallInBam && importableSafari.applicationBundleIdentifier == "com.example.safari-fixture" && importableSafari.downloadURL == nil,
                  "Safari imports preserve the exact Apple catalog app identity without inventing a package download")
        safariRecord["trackId"] = 1234; safariRecord["trackName"] = "Photo Tool"; safariRecord["description"] = "Edits photos"
        try check(SafariAppStoreSource.candidate(from: safariRecord) == nil, "Ordinary Mac apps are excluded from extension search")
        safariRecord["trackName"] = "Fixture for Safari"; safariRecord["description"] = "A Safari extension"
        safariRecord["trackViewUrl"] = "https://evil.example/app/1234"
        try check(SafariAppStoreSource.candidate(from: safariRecord) == nil, "App Store discovery does not hand off to an unrelated host")
        try check(ExtensionStoreLink(parsing: "https://apps.apple.com/us/app/1password-for-safari/id1569813296?mt=12") == .safariAppStore(id: "1569813296") &&
                  ExtensionStoreLink(parsing: "https://apps.apple.com.evil.example/app/id123") == nil, "Safari store links validate host and numeric identity")

        let query = "fixture"
        let firefoxSearchURL = "https://addons.mozilla.org/api/v5/addons/search/?q=fixture&app=firefox&type=extension&sort=users&page_size=10&lang=en-US"
        client.routes[firefoxSearchURL] = .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["results": [addonJSON]]))
        client.routes[ChromeWebStoreSource.searchURL(for: query).absoluteString] = .init(status: 503)
        client.routes[SafariAppStoreSource.searchURL(for: query).absoluteString] = .init(status: 503)
        let combined = await ExtensionCatalogSearch(client: client, bamVersion: "0.19.0").search(query)
        try check(combined.candidates.count == 1 && combined.candidates[0].source == .amo && combined.notices.count == 2,
                  "Unavailable stores do not hide results returned by the remaining store")
        client.routes[ChromeWebStoreSource.searchURL(for: query).absoluteString] = .init(status: 200, body: searchHTML)
        let partial = await ExtensionCatalogSearch(client: client, bamVersion: "0.19.0").search(query)
        try check(Set(partial.candidates.map(\.source)) == [.amo, .chromeWebStore] && partial.notices.count == 1,
                  "Unified search exposes Chrome and Firefox together while reporting a Safari outage")
        var crosswalkChrome = chromeSearchCandidates[0]; crosswalkChrome.upstreamID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        var crosswalkFirefox = candidate; crosswalkFirefox.upstreamID = "{d634138d-c276-4fc8-924b-40a0ea21d284}"; crosswalkFirefox.publisher = "Different store publisher spelling"
        try check(ExtensionCatalogIdentity(crosswalkFirefox).matches(ExtensionCatalogIdentity(crosswalkChrome)) &&
                  ExtensionCatalogIdentity(crosswalkChrome).matches(ExtensionCatalogIdentity(safariCandidate)),
                  "Inspected product IDs unify 1Password across all three stores despite publisher spelling")
        var impostor = crosswalkChrome; impostor.upstreamID = String(repeating: "b", count: 32)
        impostor.publisher = crosswalkFirefox.publisher; impostor.homepage = crosswalkFirefox.homepage; impostor.name = crosswalkFirefox.name
        try check(!ExtensionCatalogIdentity(impostor).matches(ExtensionCatalogIdentity(crosswalkFirefox)) &&
                  !ExtensionCatalogIdentity(crosswalkFirefox).matches(ExtensionCatalogIdentity(impostor)),
                  "An unknown ID cannot impersonate a known product by copying its name, publisher and homepage")
        let dedup = ExtensionCatalogSearch.combine([partial, partial])
        try check(dedup.candidates.count == partial.candidates.count && dedup.notices.count == 1, "Repeated source results are deduplicated before product grouping")

        // Store order must not bury a direct match behind another store's broad recommendations.
        func named(_ title: String, source: ExtensionCatalogSourceKind, id: String) -> ExtensionBuildCandidate {
            ExtensionBuildCandidate(source: source, upstreamID: id, name: title, publisher: "Fixture", version: "1")
        }
        let relevance = [named("Keeper Password Manager", source: .amo, id: "unrelated"),
                         named("Bitwarden Password Manager", source: .chromeWebStore, id: "chrome"),
                         named("Tools for Bitwarden", source: .amo, id: "phrase"),
                         named("Bitwarden", source: .safariAppStore, id: "exact"),
                         named("Bítwarden — Password Manager", source: .amo, id: "firefox")]
        try check(ExtensionCatalogSearch.ranked(relevance, for: "  BITWARDEN ").compactMap(\.upstreamID) == ["exact", "chrome", "firefox", "phrase", "unrelated"],
                  "Unified results rank normalized exact, prefix and phrase matches across stores while preserving equal-rank API order")
        try check(ExtensionCatalogSearch.ranked(relevance, for: "!!!") == relevance, "An empty normalized query preserves source order")
        // Native acceptance: searching "Dark Reader" listed Firefox's (another publisher) first because the
        // stores' results are combined Firefox-first. At equal relevance an installable build leads, Chrome Web
        // Store before Firefox; relevance still wins over source.
        var firefoxBuild = named("Dark Reader", source: .amo, id: "firefox")
        firefoxBuild.downloadURL = URL(string: "https://addons.mozilla.org/firefox/downloads/file/1/dark_reader-1.xpi")
        let safariApp = named("Dark Reader", source: .safariAppStore, id: "safari")   // no installed app: not installable in Bam
        let darkReader = [safariApp, firefoxBuild, named("Dark Reader", source: .chromeWebStore, id: "chrome"),
                          named("Night Eye", source: .chromeWebStore, id: "other"), named("Dark Reader for Safari", source: .amo, id: "prefix")]
        try check(firefoxBuild.canInstallInBam && !safariApp.canInstallInBam, "Fixture premise: Firefox installable, Safari app not")
        try check(ExtensionCatalogSearch.ranked(darkReader, for: "dark reader").compactMap(\.upstreamID) == ["chrome", "firefox", "safari", "prefix", "other"],
                  "Equal-relevance listings did not lead with Chrome, then Firefox, ahead of an uninstallable Safari app, behind relevance")
        var urlPublisherRow = chromeSearchRow; urlPublisherRow[7] = "https://www.bitwarden.com/download/"
        let urlPublisher = try ChromeWebStoreSource.searchCandidates(fromHTML: chromePage([urlPublisherRow]))[0]
        try check(urlPublisher.publisher == "bitwarden.com" && ChromeWebStoreSource.publisherLabel("  Vendor Inc.  ") == "Vendor Inc.",
                  "URL-shaped Chrome publishers display a clean host without altering named publishers")
        let bitwardenFirefox = named("Bitwarden Password Manager", source: .amo, id: "{446900e4-71c2-419f-a6a7-df9c091e268b}")
        let bitwardenChrome = named("Bitwarden Password Manager", source: .chromeWebStore, id: "nngceckbapebfimnlniiiahkandclblb")
        let bitwardenSafari = named("Bitwarden", source: .safariAppStore, id: "1352778147")
        try check(ExtensionCatalogIdentity(bitwardenFirefox).matches(ExtensionCatalogIdentity(bitwardenChrome)) &&
                  ExtensionCatalogIdentity(bitwardenChrome).matches(ExtensionCatalogIdentity(bitwardenSafari)),
                  "Vendor-linked Bitwarden IDs form one product across Firefox, Chrome and Safari")

        // Identity matching
        let amoIdentity = ExtensionCatalogIdentity(candidate)
        var identityFixture = candidate; identityFixture.upstreamID = "fixture@vendor.example"
        let genericAMOIdentity = ExtensionCatalogIdentity(identityFixture)
        let cwsIdentity = ExtensionCatalogIdentity(chromeWebStoreID: cwsID, publisher: "VIDIQ", homepageHost: "vidiq.com", productName: candidate.name)
        try check(amoIdentity.amoGUID == candidate.upstreamID && amoIdentity.homepageHost == "vidiq.com", "Identity normalizes the homepage host")
        try check(genericAMOIdentity.matches(cwsIdentity) && cwsIdentity.matches(genericAMOIdentity), "Unmapped product name, publisher and homepage match across stores, case-insensitively")
        try check(ExtensionCatalogIdentity(amoGUID: "A@b", publisher: "x").matches(ExtensionCatalogIdentity(amoGUID: "a@B", publisher: "y")), "A shared AMO GUID matches regardless of publisher")
        try check(ExtensionCatalogIdentity(chromeWebStoreID: cwsID, publisher: "x").matches(ExtensionCatalogIdentity(chromeWebStoreID: cwsID, publisher: "")), "A shared CWS ID matches")
        try check(!ExtensionCatalogIdentity(amoGUID: "a", publisher: "x", homepageHost: "x.com").matches(ExtensionCatalogIdentity(chromeWebStoreID: cwsID, publisher: "x", homepageHost: "y.com")),
                  "Same publisher with different hosts does not match")
        try check(!ExtensionCatalogIdentity(publisher: "x", homepageHost: "x.com").matches(ExtensionCatalogIdentity(publisher: "z", homepageHost: "x.com")), "Same host with different publishers does not match")
        try check(!ExtensionCatalogIdentity(publisher: "", homepageHost: "x.com").matches(ExtensionCatalogIdentity(publisher: "", homepageHost: "x.com")), "Empty publishers never match heuristically")
        try check(!ExtensionCatalogIdentity(publisher: "x").matches(ExtensionCatalogIdentity(publisher: "x")), "A missing homepage never matches heuristically")
        try check(!ExtensionCatalogIdentity(amoGUID: "a", publisher: "x").matches(ExtensionCatalogIdentity(amoGUID: "b", publisher: "x")), "Different AMO GUIDs without homepages do not match")
        let merged = amoIdentity.absorbing(cwsIdentity)
        try check(merged.amoGUID == candidate.upstreamID && merged.chromeWebStoreID == cwsID, "Absorbing merges upstream IDs into one product identity")

        // __MSG__ resolution
        let localized = root.appendingPathComponent("localized", isDirectory: true)
        for (path, content) in [
            ("manifest.json", try manifest(["manifest_version": 3, "name": "__MSG_appName__", "description": "__MSG_appDesc__ by __MSG_Vendor__", "version": "2.5.1",
                                            "default_locale": "de", "background": ["service_worker": "sw.js"],
                                            "permissions": ["storage", "scripting"], "host_permissions": ["https://*.youtube.com/*"], "homepage_url": "https://vidiq.com"])),
            ("_locales/de/messages.json", Data(#"{"appDesc": {"message": "Beschreibung"}}"#.utf8)),
            ("_locales/en/messages.json", Data(#"{"appname": {"message": "Resolved Name"}, "appDesc": {"message": "Description"}}"#.utf8)),
            ("_locales/en_US/messages.json", Data(#"{"vendor": {"message": "Vendor"}}"#.utf8))
        ] {
            let url = localized.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }
        let summary = try ChromeWebStoreSource.metadata(from: localized.appendingPathComponent("manifest.json"))
        try check(summary.name == "Resolved Name" && summary.description == "Beschreibung by Vendor",
                  "Messages resolve through default_locale, then en, then en_US, matching keys case-insensitively")
        try check(summary.version == "2.5.1" && summary.manifestVersion == 3 && summary.backgroundKind == .serviceWorker &&
                  summary.permissions == ["storage", "scripting"] && summary.hostPermissions == ["https://*.youtube.com/*"] && summary.homepage?.host == "vidiq.com",
                  "Manifest summary captures version, background kind, permissions and homepage")
        let mv2 = root.appendingPathComponent("mv2", isDirectory: true)
        try fm.createDirectory(at: mv2, withIntermediateDirectories: true)
        try manifest(["manifest_version": 2, "name": "__MSG_missing__", "version": "1", "background": ["scripts": ["bg.js"]], "permissions": ["tabs", "<all_urls>"]])
            .write(to: mv2.appendingPathComponent("manifest.json"))
        let mv2Summary = try ExtensionManifestSummary.read(fromUnpackedPackage: mv2)
        try check(mv2Summary.name == "__MSG_missing__" && mv2Summary.backgroundKind == .scripts && mv2Summary.permissions == ["tabs"] && mv2Summary.hostPermissions == ["<all_urls>"],
                  "Unresolvable messages stay verbatim; MV2 host patterns are split out")
        try check(ExtensionManifestSummary.resolveMessages(in: "plain", packageURL: mv2, defaultLocale: nil) == "plain", "Strings without messages pass through")

        // Fetch pipeline
        let key = try makeKey()
        let packageManifest = try manifest(["manifest_version": 3, "name": "Fetched Fixture", "version": "1.0.0", "background": ["service_worker": "sw.js"], "permissions": ["storage"]])
        let payload = zip([("manifest.json", packageManifest), ("sw.js", Data("self.ok = true;".utf8))])
        let signed = try crx(payload: payload, key: key)
        let fetch = ExtensionPackageFetch(client: client, bamVersion: "0.16.0")
        let crxURL = "https://clients2.googleusercontent.com/crx/blobs/AVDNL_x/\(key.id.uppercased())_1_0_0.crx"
        client.routes[crxURL] = .init(status: 200, body: signed)
        var storeCandidate = ExtensionBuildCandidate(source: .chromeWebStore, upstreamID: key.id, name: key.id, publisher: "", version: "1.0.0", downloadURL: URL(string: crxURL)!)
        let fetched = try await fetch.fetch(storeCandidate, into: root.appendingPathComponent("stage-cws"))
        try check(client.userAgent(forRequestTo: crxURL) == "Bam/0.16.0 (+https://bambrowser.com)", "Package downloads carry the Bam User-Agent, not the Chrome one")
        try check(fetched.format == .crx3 && fetched.provenance == .crx3SignatureVerified(id: key.id) && fetched.crxVerification?.verified == true &&
                  fetched.sha256 == ExtensionPackageDigest.sha256(signed), "A CRX3 from the store verifies and reports its provenance and hash")
        try check(try Data(contentsOf: fetched.packageURL.appendingPathComponent("manifest.json")) == packageManifest &&
                  fetched.packageURL.lastPathComponent == "package" && fm.fileExists(atPath: fetched.archiveURL.path), "The package is unpacked beside the kept archive")
        try check(fetched.candidate.name == "Fetched Fixture" && fetched.candidate.manifestVersion == 3 && fetched.candidate.backgroundKind == .serviceWorker &&
                  fetched.candidate.permissions == ["storage"] && fetched.candidate.version == "1.0.0", "The candidate is enriched from the unpacked manifest")
        storeCandidate.upstreamID = cwsID
        try await rejects("cws-id-mismatch", containing: "not the expected") { try await fetch.fetch(storeCandidate, into: root.appendingPathComponent("stage-mismatch")) }
        try check(!fm.fileExists(atPath: root.appendingPathComponent("stage-mismatch/package").path), "A failed verification leaves no unpacked package")

        // A store build must be a CRX3 signed for exactly its listing ID: a plain ZIP, a missing or
        // malformed ID, or an unsigned payload never reaches unpacking (or the installer).
        let storeZIP = "https://clients2.googleusercontent.com/crx/blobs/AVDNL_z/\(key.id.uppercased())_1_0_0.crx"
        client.routes[storeZIP] = .init(status: 200, body: payload)
        let zipStore = ExtensionBuildCandidate(source: .chromeWebStore, upstreamID: key.id, name: key.id, publisher: "", version: "1.0.0", downloadURL: URL(string: storeZIP)!)
        try await rejects("cws-plain-zip", containing: "plain ZIP") { try await fetch.fetch(zipStore, into: root.appendingPathComponent("stage-cws-zip")) }
        try check(!fm.fileExists(atPath: root.appendingPathComponent("stage-cws-zip/package").path), "A store ZIP was unpacked before rejection")
        for (label, id) in [("missing", nil), ("malformed", "not-an-id"), ("uppercase-out-of-range", String(repeating: "Z", count: 32))] as [(String, String?)] {
            var unnamed = storeCandidate; unnamed.upstreamID = id; unnamed.downloadURL = URL(string: crxURL)!
            try await rejects("cws-id-\(label)", containing: "must name its extension ID") { try await fetch.fetch(unnamed, into: root.appendingPathComponent("stage-cws-\(label)")) }
            try check(!fm.fileExists(atPath: root.appendingPathComponent("stage-cws-\(label)/package").path), "A store build without a valid ID was unpacked (\(label))")
        }
        var uppercaseID = storeCandidate; uppercaseID.upstreamID = key.id.uppercased(); uppercaseID.downloadURL = URL(string: crxURL)!
        let uppercaseFetched = try await fetch.fetch(uppercaseID, into: root.appendingPathComponent("stage-cws-upper"))
        try check(uppercaseFetched.provenance == .crx3SignatureVerified(id: key.id) && uppercaseFetched.candidate.upstreamID == key.id,
                  "A store ID differing only in case did not verify to the canonical lowercase ID")

        let directCRX = "https://downloads.example.com/releases/tool.crx"
        client.routes[directCRX] = .init(status: 200, body: signed)
        let direct = try await fetch.fetch(.direct(URL(string: directCRX)!), into: root.appendingPathComponent("stage-direct-crx"))
        try check(direct.provenance == .crx3SignatureVerified(id: key.id) && direct.candidate.upstreamID == key.id && direct.candidate.name == "Fetched Fixture",
                  "A direct CRX still requires a valid signature and reports the derived ID")
        var tampered = signed
        tampered[tampered.count - 40] ^= 0xFF
        client.routes[directCRX] = .init(status: 200, body: tampered)
        try await rejects("direct-crx-tampered", containing: "signature") { try await fetch.fetch(.direct(URL(string: directCRX)!), into: root.appendingPathComponent("stage-tampered")) }

        let xpiURL = "https://addons.mozilla.org/firefox/downloads/file/1/fixture.xpi"
        client.routes[xpiURL] = .init(status: 200, body: payload)
        var amoCandidate = candidate
        amoCandidate.downloadURL = URL(string: xpiURL)
        amoCandidate.expectedSHA256 = "sha256:" + ExtensionPackageDigest.sha256(payload).uppercased()
        let xpi = try await fetch.fetch(amoCandidate, into: root.appendingPathComponent("stage-xpi"))
        try check(xpi.format == .zip && xpi.provenance == .amoHashMatched && xpi.crxVerification == nil && xpi.sha256 == ExtensionPackageDigest.sha256(payload),
                  "An XPI whose hash matches AMO's record is marked hash-matched")
        try check(xpi.candidate.name == "vidIQ Vision for YouTube" && xpi.candidate.version == "3.146.0" && xpi.candidate.manifestVersion == 3 &&
                  xpi.candidate.permissions == ["storage", "tabs"], "AMO listing fields win over the manifest; unpack-only fields are filled")
        amoCandidate.expectedSHA256 = String(repeating: "0", count: 64)
        try await rejects("amo-hash-mismatch", containing: "does not match") { try await fetch.fetch(amoCandidate, into: root.appendingPathComponent("stage-bad-hash")) }
        try check(!fm.fileExists(atPath: root.appendingPathComponent("stage-bad-hash/package").path), "A hash mismatch stops before unpacking")
        amoCandidate.expectedSHA256 = "sha1:abc"
        try await rejects("amo-hash-malformed", containing: "malformed") { try await fetch.fetch(amoCandidate, into: root.appendingPathComponent("stage-malformed-hash")) }
        amoCandidate.expectedSHA256 = nil
        try check(try await fetch.fetch(amoCandidate, into: root.appendingPathComponent("stage-nohash")).provenance == .unverifiedDirectDownload,
                  "Without a published hash an XPI is only a TLS download")
        let zipURL = "https://example.com/pkg.zip"
        client.routes[zipURL] = .init(status: 200, body: payload)
        try check(try await fetch.fetch(.direct(URL(string: zipURL)!), into: root.appendingPathComponent("stage-zip")).provenance == .unverifiedDirectDownload, "A direct ZIP is unverified")
        client.routes["https://example.com/missing.zip"] = .init(status: 404)
        try await rejects("fetch-404", containing: "HTTP 404") { try await fetch.fetch(.direct(URL(string: "https://example.com/missing.zip")!), into: root.appendingPathComponent("stage-404")) }
        client.routes["https://example.com/text.zip"] = .init(status: 200, body: Data("hello".utf8))
        try await rejects("fetch-not-package", containing: "neither") { try await fetch.fetch(.direct(URL(string: "https://example.com/text.zip")!), into: root.appendingPathComponent("stage-text")) }
        try await rejects("fetch-http", containing: "HTTPS") { try await fetch.fetch(.direct(URL(string: "http://example.com/pkg.zip")!), into: root.appendingPathComponent("stage-http")) }
        try await rejects("fetch-no-url", containing: "no download URL") {
            try await fetch.fetch(ExtensionBuildCandidate(source: .amo, name: "x", publisher: "", version: ""), into: root.appendingPathComponent("stage-nourl"))
        }
        let localFile = root.appendingPathComponent("local.xpi")
        try payload.write(to: localFile)
        let local = try await fetch.fetch(.local(localFile), into: root.appendingPathComponent("stage-local"))
        try check(local.provenance == .local && local.format == .zip && local.candidate.name == "Fetched Fixture", "A local package file is unpacked with local provenance")
        try await rejects("file-url-non-local", containing: "local candidates") { try await fetch.fetch(.direct(localFile), into: root.appendingPathComponent("stage-file-direct")) }
    }
}
