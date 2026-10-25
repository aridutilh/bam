import Foundation
import WebKit

/// The pure per-extension site access model. Uses WebKit's public MatchPattern and parses one original fixture
/// manifest with WKWebExtension (no controller, context, window or app).
@main enum ExtensionSiteAccessTests {
    static func main() async throws {
        guard #available(macOS 15.4, *) else { print("SKIP: WKWebExtension needs macOS 15.4"); return }
        try await run()
    }

    @available(macOS 15.4, *) @MainActor static func run() async throws {
        typealias Access = ExtensionSiteAccess
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func site(_ input: String, subdomains: Bool = false) -> Result<String, Access.Refusal> { Access.normalizeSite(input, includeSubdomains: subdomains) }
        func matchesURL(_ pattern: String, _ url: String) -> Bool { (try? WKWebExtension.MatchPattern(string: pattern))?.matches(URL(string: url)!) == true }

        // MARK: Requested vs optional, from a real manifest through the public SDK.
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("bam-site-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Bam site access fixture", "version": "1.0", "description": "Original fixture",
            "host_permissions": ["https://*.docs.example/*"],
            "optional_host_permissions": ["https://optional.example/*"],
            "content_scripts": [["matches": ["*://mail.example/*"], "js": ["content.js"]]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try Data("void 0".utf8).write(to: package.appendingPathComponent("content.js"))
        let parsed = try await WKWebExtension(resourceBaseURL: package)
        let declared = Access.Declarations(parsed)
        require(Set(declared.requested) == ["https://*.docs.example/*", "*://mail.example/*"],
                "Requested = host_permissions + content-script matches (allRequestedMatchPatterns): \(declared.requested)")
        require(declared.optional == ["https://optional.example/*"], "Optional = optional_host_permissions only: \(declared.optional)")

        // MARK: Typed sites → site-level patterns.
        require(site("github.com") == .success("*://github.com/*"), "A bare host covers http and https")
        require(site("  https://GitHub.com/repo?tab=1#x ") == .success("https://github.com/*"), "Scheme kept, host lowercased, path ignored")
        require(site("*.github.com") == .success("*://*.github.com/*") && site("github.com", subdomains: true) == .success("*://*.github.com/*"),
                "Subdomains by wildcard or option")
        require(site("http://localhost:8080/app") == .success("http://localhost/*") && site("localhost:8080") == .success("*://localhost/*"),
                "Ports are dropped (patterns can't name one and match every port)")
        require(matchesURL("http://localhost/*", "http://localhost:8080/app"), "The portless pattern still matches the ported page")
        require(site("127.0.0.1") == .success("*://127.0.0.1/*") && site("http://[::1]:8080") == .success("http://[::1]/*"), "IP literals")
        require(site("bücher.de") == .success("*://xn--bcher-kva.de/*") && matchesURL("*://xn--bcher-kva.de/*", "https://xn--bcher-kva.de/"),
                "International names become the punycode form page URLs carry (a Unicode pattern would never match)")
        for (input, refusal) in [("", Access.Refusal.empty), ("   ", .empty), ("file:///etc/hosts", .unsupportedScheme("file")),
                                 ("chrome://settings", .unsupportedScheme("chrome")), ("ftp://a.example", .unsupportedScheme("ftp")),
                                 ("about:blank", .unsupportedScheme("about")), ("mailto:a@b.example", .unsupportedScheme("mailto")),
                                 ("<all_urls>", .allSites), ("*", .allSites), ("*://*/*", .allSites), ("https://*", .allSites),
                                 ("https://user@github.com", .invalid), ("*.127.0.0.1", .invalid), ("git*hub.com", .invalid), ("https://", .invalid)] {
            require(site(input) == .failure(refusal), "\(input.debugDescription) is refused as \(refusal): \(site(input))")
        }

        // MARK: Only requested sites can be added (narrow, never widen).
        let docs = Access.Declarations(requested: ["https://*.docs.example/*", "*://mail.example/*"], optional: ["https://optional.example/*"])
        require(Access.addSite("api.docs.example", to: .withheld, declarations: docs) == .success(.specific(["https://api.docs.example/*"])),
                "A bare host is narrowed to the scheme the extension requests (https only here)")
        require(Access.addSite("docs.example", to: .withheld, declarations: docs) == .success(.specific(["https://docs.example/*"])),
                "*.host requests cover the host itself")
        require(Access.addSite("mail.example", to: .specific(["https://api.docs.example/*"]), declarations: docs)
                == .success(.specific(["*://mail.example/*", "https://api.docs.example/*"])), "Content-script sites can be listed; the list stays sorted")
        require(Access.addSite("http://api.docs.example", to: .withheld, declarations: docs) == .failure(.notRequested),
                "An explicit scheme the extension doesn't request is refused")
        require(Access.addSite("optional.example", to: .withheld, declarations: docs) == .failure(.notRequested),
                "Optional sites aren't added by the user; the extension asks for them itself")
        require(Access.addSite("elsewhere.example", to: .withheld, declarations: docs) == .failure(.notRequested), "Undeclared sites are refused")
        require(Access.addSite("api.docs.example", to: .allRequested, declarations: docs) == .success(.allRequested), "All requested already includes it")
        let everything = Access.Declarations(requested: ["<all_urls>"])
        require(Access.addSite("anything.example", to: .withheld, declarations: everything) == .success(.specific(["*://anything.example/*"])),
                "<all_urls> requests accept any http(s) site")
        require(Access.removeSite("https://api.docs.example/*", from: .specific(["https://api.docs.example/*"])) == .withheld
                && Access.removeSite("x", from: .allRequested) == .allRequested, "Removing the last site withholds; other modes unchanged")

        // MARK: Grants: optional grants never disappear under a withholding mode.
        let optionalGrant = "https://optional.example/*"
        require(Access.grantedPatterns(.init(mode: .withheld, optionalGrants: [optionalGrant]), declarations: docs) == [optionalGrant],
                "Withheld grants no requested site, and keeps what the user allowed the extension to ask for")
        require(Access.grantedPatterns(.init(mode: .specific(["https://api.docs.example/*"]), optionalGrants: [optionalGrant]), declarations: docs)
                == ["https://api.docs.example/*", optionalGrant], "Specific: exactly the listed sites plus optional grants")
        require(Access.grantedPatterns(.init(mode: .allRequested), declarations: docs) == Set(docs.requested), "All requested: exactly the requests")
        require(Access.grantedPatterns(.init(mode: .specific(["https://elsewhere.example/*"]), optionalGrants: ["https://gone.example/*"]), declarations: docs).isEmpty,
                "Nothing undeclared is ever granted, whatever was stored")
        let before: Set<String> = ["https://*.docs.example/*", "*://mail.example/*", optionalGrant]
        let after = Access.grantedPatterns(.init(mode: .specific(["https://api.docs.example/*"]), optionalGrants: [optionalGrant]), declarations: docs)
        let change = Access.diff(current: before, target: after)
        require(change.grant == ["https://api.docs.example/*"] && change.revoke == ["https://*.docs.example/*", "*://mail.example/*"]
                && !change.revoke.contains(optionalGrant), "Narrowing revokes only the dropped requested sites, never the optional grant")
        require(Access.diff(current: after, target: after) == ([], []), "Re-applying the same choice changes nothing")
        require(Access.providesOneTimeAccess(grantedPermissions: ["activeTab", "storage"]) && !Access.providesOneTimeAccess(grantedPermissions: ["storage"]),
                "One-time access only with activeTab; without it the engine must not call withheld 'On click'")

        // MARK: Legacy records never widen.
        let legacyAll = Access.migrate(granted: docs.requested + [optionalGrant], declarations: docs)
        require(legacyAll == .init(mode: .allRequested, optionalGrants: [optionalGrant]), "Install approval + an optional prompt: all requested, optional kept")
        require(Access.migrate(granted: ["*://mail.example/*"], declarations: docs) == .init(mode: .specific(["*://mail.example/*"])),
                "A partial grant becomes exactly those sites")
        require(Access.migrate(granted: [], declarations: docs) == .init(mode: .withheld), "A revoked record stays without access")
        require(Access.migrate(granted: ["https://api.docs.example/*", "https://gone.example/*"], declarations: docs)
                == .init(mode: .specific(["https://api.docs.example/*"])), "A narrower retained grant stays a site; undeclared grants are dropped")
        require(Access.migrate(granted: [optionalGrant], declarations: docs) == .init(mode: .withheld, optionalGrants: [optionalGrant]),
                "Only an optional grant: requested sites withheld, the optional grant still granted")
        require(Access.migrate(granted: [], declarations: .init(requested: [])) == .init(mode: .allRequested), "Nothing requested: nothing to choose")
        for granted in [[], docs.requested, [optionalGrant], ["*://mail.example/*", optionalGrant], ["https://api.docs.example/*"], ["https://gone.example/*"]] {
            let result = Access.grantedPatterns(Access.migrate(granted: granted, declarations: docs), declarations: docs)
            require(result.isSubset(of: Set(granted)), "Migration never grants more than the record had: \(granted) → \(result)")
        }

        // MARK: Updates never widen.
        let narrowed = Access.Declarations(requested: ["https://api.docs.example/*"], optional: [])
        let state = Access.State(mode: .specific(["*://mail.example/*", "https://api.docs.example/*"]), optionalGrants: [optionalGrant])
        require(Access.updated(state, to: narrowed) == .init(mode: .specific(["https://api.docs.example/*"])),
                "Listed sites the new version no longer requests are dropped, as are optional grants it no longer declares")
        require(Access.updated(.init(mode: .specific(["*://mail.example/*"])), to: narrowed) == .init(mode: .withheld), "No listed site left: withheld")
        let widened = Access.Declarations(requested: docs.requested + ["https://new.example/*"], optional: docs.optional)
        require(Access.updated(.init(mode: .specific(["*://mail.example/*"])), to: widened) == .init(mode: .specific(["*://mail.example/*"])),
                "A wider new version adds nothing to a site list")
        require(Access.updated(.init(mode: .allRequested), to: widened).mode == .allRequested
                && Access.newlyRequested(from: docs, to: widened) == ["https://new.example/*"], "All requested stays; the addition is listed for review")
        require(Access.newlyRequested(from: Access.Declarations(requested: ["<all_urls>"]), to: widened).isEmpty, "Nothing is new under <all_urls>")
        let promoted = Access.Declarations(requested: docs.requested + [optionalGrant], optional: [])
        require(Access.updated(.init(mode: .withheld, optionalGrants: [optionalGrant]), to: promoted).optionalGrants == [optionalGrant],
                "An optional grant the new version now requests is kept (still allowed, not silently revoked)")

        // MARK: Persistence: explicit shape; unknown or malformed modes read back as withheld.
        for value in [Access.State(mode: .withheld), .init(mode: .allRequested, optionalGrants: [optionalGrant]),
                      .init(mode: .specific(["https://api.docs.example/*"]))] {
            let data = try JSONEncoder().encode(value)
            let loaded = try JSONDecoder().decode(Access.State.self, from: data)
            require(loaded == value, "\(value) survives a save and load")
        }
        let shape = String(data: try JSONEncoder().encode(Access.State(mode: .specific(["https://a.example/*"]))), encoding: .utf8) ?? ""
        require(shape.contains("\"mode\":\"specific\"") && shape.contains("\"sites\""), "Stored as {mode, sites, optionalGrants}: \(shape)")
        for json in [#"{"mode":"everything"}"#, #"{"mode":"specific","sites":[]}"#, #"{}"#] {
            let loaded = try JSONDecoder().decode(Access.State.self, from: Data(json.utf8))
            require(loaded.mode == .withheld, "\(json) reads back as withheld, never wider")
        }

        print("PASS: \(checks) extension site access checks")
    }
}
