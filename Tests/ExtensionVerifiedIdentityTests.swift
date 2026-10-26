import AppKit
import Foundation
import WebKit

/// New-install-only verified Chrome identity: who qualifies, what WebKit receives, and that records, authorization and
/// notifications stay per installation and profile. In-process, non-persistent controllers and stores, no web views.
@main @MainActor enum ExtensionVerifiedIdentityTests {
    struct Failure: Error { let message: String }
    static func main() async {
        guard #available(macOS 15.4, *) else { print("SKIP: Verified identity requires macOS 15.4"); return }
        do { print("PASS: Extension verified identity — \(try await run()) checks") }
        catch { fputs("FAIL: Extension verified identity: \((error as? Failure)?.message ?? "\(error)")\n", stderr); exit(1) }
    }
    @available(macOS 15.4, *)
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }
        _ = NSApplication.shared
        let storeID = "abcdefghijklmnopabcdefghijklmnop"
        func catalog(_ source: ExtensionCatalogSourceKind, upstream: String?, verified: String?) -> ExtensionCatalogRecord {
            ExtensionCatalogRecord(source: source, upstreamID: upstream, listingURL: nil, downloadURL: nil, publisher: "Fixture", version: "1.0", sha256: "",
                                   provenance: "test fixture: verification asserted by the test, not performed", verifiedChromeExtensionID: verified, installedAt: Date())
        }

        // Eligibility: only a Chrome Web Store install whose verified ID equals its listing ID, in Chrome's alphabet.
        typealias B = BrowserExtensions
        try check(B.verifiedRuntimeIdentifier(for: catalog(.chromeWebStore, upstream: storeID, verified: storeID)) == storeID, "A verified store install did not qualify")
        try check(B.verifiedRuntimeIdentifier(for: nil) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.chromeWebStore, upstream: storeID, verified: nil)) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.chromeWebStore, upstream: "ponmlkjihgfedcbaponmlkjihgfedcba", verified: storeID)) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.amo, upstream: storeID, verified: storeID)) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.directPackage, upstream: storeID, verified: storeID)) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.local, upstream: storeID, verified: storeID)) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.chromeWebStore, upstream: storeID.uppercased(), verified: storeID.uppercased())) == nil &&
                  B.verifiedRuntimeIdentifier(for: catalog(.chromeWebStore, upstream: "abcdefghijklmnopqrstuvwxyzabcdef", verified: "abcdefghijklmnopqrstuvwxyzabcdef")) == nil,
                  "An unverified, mismatched, non-store or non-Chrome-alphabet ID qualified")

        // Older registries have no field: they keep the installation UUID. The field round-trips once set.
        let legacy = BrowserExtensionRecord(id: UUID(), profileID: UUID(), name: "Old", version: "1", packageName: "package")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "runtimeIdentifier")
        let decoded = try JSONDecoder().decode(BrowserExtensionRecord.self, from: JSONSerialization.data(withJSONObject: json))
        var verifiedRecord = legacy; verifiedRecord.runtimeIdentifier = storeID
        try check(decoded.runtimeIdentifier == nil && decoded.contextIdentifier == legacy.id.uuidString.lowercased() &&
                  (try JSONDecoder().decode(BrowserExtensionRecord.self, from: JSONEncoder().encode(verifiedRecord))).contextIdentifier == storeID,
                  "A legacy record gained an identifier, or a verified one did not round-trip")
        try check(ExtensionManagement.details(verifiedRecord)?.contains("Chrome Web Store ID \(storeID)") == true && ExtensionManagement.details(legacy) == nil,
                  "The verified identity was not disclosed, or a legacy record claimed one")

        // Installs: a tiny original package, two profiles, non-persistent controllers and stores.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-verified-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Identity fixture", "version": "1.0", "description": "Original", "permissions": ["notifications"]]).write(to: package.appendingPathComponent("manifest.json"))
        let host = BrowserExtensions(storageURL: root.appendingPathComponent("Extensions", isDirectory: true), controllerStorage: .nonPersistent)
        defer { host.shutdown() }
        host.permissionPrompt = { _ in true }
        let profileA = UUID(), profileB = UUID()
        var configurations: [UUID: WKWebViewConfiguration] = [:]
        for profile in [profileA, profileB] {
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            host.configure(configuration, profileID: profile); await host.ready(profileID: profile)
            configurations[profile] = configuration
        }
        let verified = catalog(.chromeWebStore, upstream: storeID, verified: storeID)
        let idA = try await host.importPackage(at: package, profileID: profileA, catalog: verified)
        var duplicateRefused = false
        do { _ = try await host.importPackage(at: package, profileID: profileA, catalog: verified) } catch { duplicateRefused = "\(error)".contains("already installed") || error.localizedDescription.contains("already installed") }
        let idB = try await host.importPackage(at: package, profileID: profileB, catalog: verified)
        let idFolder = try await host.importPackage(at: package, profileID: profileA)
        try check(duplicateRefused && host.items(profileID: profileA).count == 2, "A second verified install in the same profile was not refused")
        guard let contextA = host.context(for: idA), let contextB = host.context(for: idB), let contextFolder = host.context(for: idFolder) else {
            throw Failure(message: "Fixture contexts did not load: \(host.errors)")
        }
        try check(contextA.uniqueIdentifier == storeID && contextB.uniqueIdentifier == storeID && contextFolder.uniqueIdentifier == idFolder.uuidString.lowercased(),
                  "WebKit did not receive the verified ID, or a folder import did not keep its UUID")
        try check(contextA.baseURL.host == idA.uuidString.lowercased() && contextB.baseURL.host == idB.uuidString.lowercased() &&
                  B.recordID(of: contextA) == idA && B.recordID(of: contextB) == idB, "Base URLs did not keep each installation's UUID host")
        // Authorization is by the exact loaded context in the record's own profile, never by the shared runtime.id.
        try check(host.ownedRecordIndex(for: contextA).map { host.records[$0].id } == idA && host.ownedRecordIndex(for: contextB).map { host.records[$0].id } == idB,
                  "A loaded context did not map to its own record")
        let runtimeA = configurations[profileA]?.webExtensionController?.delegate as? BrowserExtensionRuntime
        let runtimeB = configurations[profileB]?.webExtensionController?.delegate as? BrowserExtensionRuntime
        try check(runtimeA?.ownedRecord(for: contextA)?.id == idA && runtimeA?.ownedRecord(for: contextB) == nil && runtimeB?.ownedRecord(for: contextA) == nil,
                  "One profile's runtime authorized another profile's context")
        let unloaded = WKWebExtensionContext(for: contextA.webExtension)
        unloaded.uniqueIdentifier = storeID; unloaded.baseURL = contextA.baseURL
        try check(host.ownedRecordIndex(for: unloaded) == nil && runtimeA?.ownedRecord(for: unloaded) == nil, "A look-alike context object was authorized")
        // Notification identifiers are per installation even though both profiles share runtime.id.
        try check(ExtensionCompatibilityBridge.notificationIdentifier(context: contextA, id: "n") != ExtensionCompatibilityBridge.notificationIdentifier(context: contextB, id: "n"),
                  "Two profiles with the same runtime ID produced the same notification identifier")
        // A replacement install (same store ID, same profile, new installation) never receives the old install's
        // notification responses: ownership is bound to the posting installation and withdrawn at teardown.
        guard let bridgeA = runtimeA?.compatibility else { throw Failure(message: "Profile A has no compatibility bridge") }
        bridgeA.postNotification = { _, _, _, _, _ in nil }
        let posted = await bridgeA.receiveNativeMessage(["kind": "request", "method": "notifications.create", "params": ["id": "n1", "title": "t", "message": "m"]], context: contextA)
        let oldIdentifier = ExtensionCompatibilityBridge.notificationIdentifier(context: contextA, id: "n1")
        try check(posted.1 == nil && bridgeA.routedOwner(for: oldIdentifier) == storeID, "The original install's notification was not owned by it: \(String(describing: posted.1))")
        try await host.remove(id: idA)
        let idA2 = try await host.importPackage(at: package, profileID: profileA, catalog: verified)
        guard let contextA2 = host.context(for: idA2) else { throw Failure(message: "The replacement install did not load") }
        try check(contextA2.uniqueIdentifier == storeID && contextA2.baseURL.host == idA2.uuidString.lowercased() && idA2 != idA,
                  "The replacement did not reuse the store ID under a new installation")
        try check(bridgeA.routedOwner(for: oldIdentifier) == nil, "An old installation's notification would route to its replacement")
        _ = await bridgeA.receiveNativeMessage(["kind": "request", "method": "notifications.create", "params": ["id": "n1", "title": "t", "message": "m"]], context: contextA2)
        let newIdentifier = ExtensionCompatibilityBridge.notificationIdentifier(context: contextA2, id: "n1")
        try check(newIdentifier != oldIdentifier && bridgeA.routedOwner(for: newIdentifier) == storeID && bridgeA.routedOwner(for: oldIdentifier) == nil,
                  "The replacement's own notification did not route to it, or the old one regained a route")
        return checks
    }
}
