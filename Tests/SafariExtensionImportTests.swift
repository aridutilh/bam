import Foundation
import CryptoKit

@main struct SafariExtensionImportTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: message) }; checks += 1
    }
    static func rejects(_ message: String, containing text: String? = nil, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch {
            if let text { try check(error.localizedDescription.localizedCaseInsensitiveContains(text), "\(message): unexpected error \(error)") }
            else { checks += 1 }
            return
        }
        throw Failure(description: "\(message): unexpectedly succeeded")
    }
    static func writePlist(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }
    static func writeManifest(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
    static func fixture(at root: URL, name: String) throws -> (app: URL, appex: URL, resources: URL) {
        let app = root.appendingPathComponent(name + ".app", isDirectory: true)
        let appex = app.appendingPathComponent("Contents/PlugIns/Fixture.appex", isDirectory: true)
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try writePlist(["CFBundleIdentifier": "org.example.fixture", "CFBundleName": "Fixture", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"], to: app.appendingPathComponent("Contents/Info.plist"))
        try writePlist(["CFBundleIdentifier": "org.example.fixture.web", "CFBundleName": "Fixture Extension", "CFBundleVersion": "1", "CFBundlePackageType": "XPC!",
                        "NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.web-extension"]], to: appex.appendingPathComponent("Contents/Info.plist"))
        try writeManifest(["manifest_version": 3, "name": "Fixture Safari Extension", "version": "1.0", "permissions": ["storage", "nativeMessaging"]], to: resources.appendingPathComponent("manifest.json"))
        try Data("original fixture resources".utf8).write(to: resources.appendingPathComponent("fixture.txt"))
        return (app, appex, resources)
    }
    /// An explicit test-only verifier lets original fixtures exercise path and
    /// identity policy without accepting ad-hoc code in the production importer.
    static func fixtureSignature(_ url: URL) throws -> SafariExtensionSigningIdentity {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: Any]
        var signedBytes = infoData
        let manifest = url.appendingPathComponent("Contents/Resources/manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) { signedBytes.append(try Data(contentsOf: manifest)) }
        return SafariExtensionSigningIdentity(identifier: info["CFBundleIdentifier"] as! String, teamIdentifier: "FIXTURETEAM",
            codeHash: SHA256.hash(data: signedBytes).map { String(format: "%02x", $0) }.joined(), distribution: .appStore)
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bam-safari-import-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let importer = SafariExtensionImport { try fixtureSignature($0) }
        let original = try fixture(at: root, name: "Original")
        let candidates = try importer.inspect(applicationURL: original.app, expectedApplicationBundleIdentifier: "org.example.fixture")
        try check(candidates.count == 1, "An installed app exposes its Safari WebExtension")
        let candidate = candidates[0]
        try check(candidate.appURL == original.app && candidate.appexURL == original.appex && candidate.resourceURL == original.resources &&
                  candidate.extensionBundleIdentifier == "org.example.fixture.web" && candidate.teamIdentifier == "FIXTURETEAM" &&
                  candidate.displayName == "Fixture Safari Extension" && candidate.version == "1.0", "The descriptor preserves app/native bundle identities and display metadata")
        let encoded = try JSONEncoder().encode(candidate)
        try check(try JSONDecoder().decode(SafariExtensionBundle.self, from: encoded) == candidate, "Signed origin metadata round-trips in the registry")
        let before = try Data(contentsOf: original.resources.appendingPathComponent("manifest.json"))
        let copied = try importer.snapshot(candidate, to: root.appendingPathComponent("Copied.appex"))
        try importer.validateSnapshot(at: copied, original: candidate)
        try check(try Data(contentsOf: copied.appendingPathComponent("Contents/Resources/manifest.json")) == before &&
                  Data(contentsOf: original.resources.appendingPathComponent("manifest.json")) == before, "Snapshot preserves the original and copied manifest byte-for-byte")
        try check(fm.fileExists(atPath: copied.appendingPathComponent("Contents/Info.plist").path), "Snapshot retains the native app-extension bundle structure")

        try rejects("Store identity mismatch", containing: "does not match") { _ = try importer.inspect(applicationURL: original.app, expectedApplicationBundleIdentifier: "org.example.someone-else") }
        let developer = SafariExtensionImport { url in
            let identity = try fixtureSignature(url)
            return SafariExtensionSigningIdentity(identifier: identity.identifier, teamIdentifier: identity.teamIdentifier, codeHash: identity.codeHash, distribution: .developerID)
        }
        try rejects("Store-linked Developer ID app", containing: "Mac App Store copy") { _ = try developer.inspect(applicationURL: original.app, expectedApplicationBundleIdentifier: "org.example.fixture") }
        try check(try developer.inspect(applicationURL: original.app).first?.distribution == .developerID, "Explicit manual import can review a valid Developer ID app")
        let wrongTeam = SafariExtensionImport { url in
            let identity = try fixtureSignature(url)
            return SafariExtensionSigningIdentity(identifier: identity.identifier, teamIdentifier: url.pathExtension == "appex" ? "OTHERTEAM" : identity.teamIdentifier, codeHash: identity.codeHash, distribution: identity.distribution)
        }
        try rejects("Different app and extension signers", containing: "different signing teams") { _ = try wrongTeam.inspect(applicationURL: original.app) }
        let wrongID = SafariExtensionImport { url in
            let identity = try fixtureSignature(url)
            return SafariExtensionSigningIdentity(identifier: "org.example.spoofed", teamIdentifier: identity.teamIdentifier, codeHash: identity.codeHash, distribution: identity.distribution)
        }
        try rejects("Signed bundle identifier mismatch", containing: "signed identity") { _ = try wrongID.inspect(applicationURL: original.app) }
        try rejects("Unsigned code is not trusted by production", containing: "signature") { _ = try SafariExtensionImport().inspect(applicationURL: original.app) }

        try rejects("A snapshot must not overwrite its containing app", containing: "outside") { _ = try importer.snapshot(candidate, to: original.app.appendingPathComponent("Contents/Snapshot.appex")) }
        try rejects("An existing private snapshot is not overwritten", containing: "new private") { _ = try importer.snapshot(candidate, to: copied) }
        try check(try Data(contentsOf: copied.appendingPathComponent("Contents/Resources/manifest.json")) == before, "Rejected replacement leaves the existing snapshot intact")
        let brokenCopy = SafariExtensionImport { url in
            let identity = try fixtureSignature(url)
            return SafariExtensionSigningIdentity(identifier: identity.identifier, teamIdentifier: identity.teamIdentifier,
                codeHash: url.lastPathComponent == "BadCopy.appex" ? "changed" : identity.codeHash, distribution: identity.distribution)
        }
        let badDestination = root.appendingPathComponent("BadCopy.appex")
        try rejects("Copied signature differs", containing: "copied") { _ = try brokenCopy.snapshot(candidate, to: badDestination) }
        try check(!fm.fileExists(atPath: badDestination.path), "A failed copied signature leaves no partial snapshot")

        let noWebExtension = try fixture(at: root, name: "NativeSafari")
        try writePlist(["CFBundleIdentifier": "org.example.fixture.native", "NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.extension"]], to: noWebExtension.appex.appendingPathComponent("Contents/Info.plist"))
        try check(try importer.inspect(applicationURL: noWebExtension.app).isEmpty, "Legacy Safari App Extensions are not misrepresented as WebExtensions")
        let empty = try fixture(at: root, name: "NoExtensions")
        try fm.removeItem(at: empty.app.appendingPathComponent("Contents/PlugIns"))
        try check(try importer.inspect(applicationURL: empty.app).isEmpty, "Apps without PlugIns return no extension choices")

        let symlinkApp = root.appendingPathComponent("Linked.app")
        try fm.createSymbolicLink(at: symlinkApp, withDestinationURL: original.app)
        try rejects("Top-level symbolic app", containing: "symbolic") { _ = try importer.inspect(applicationURL: symlinkApp) }
        let escaped = try fixture(at: root, name: "EscapedResource")
        try fm.createSymbolicLink(at: escaped.resources.appendingPathComponent("outside"), withDestinationURL: root)
        try rejects("A resource link escapes its signed bundle", containing: "escapes") { _ = try importer.inspect(applicationURL: escaped.app) }
        let internalLink = try fixture(at: root, name: "InternalLink")
        try fm.createSymbolicLink(atPath: internalLink.resources.appendingPathComponent("alias.txt").path, withDestinationPath: "fixture.txt")
        try check(try importer.inspect(applicationURL: internalLink.app).count == 1, "An internal bundle-relative resource link is allowed")
        let manifestLink = try fixture(at: root, name: "ManifestLink")
        try fm.removeItem(at: manifestLink.resources.appendingPathComponent("manifest.json"))
        try fm.createSymbolicLink(at: manifestLink.resources.appendingPathComponent("manifest.json"), withDestinationURL: original.resources.appendingPathComponent("manifest.json"))
        try rejects("Manifest symlink", containing: "regular file") { _ = try importer.inspect(applicationURL: manifestLink.app) }
        let structuralLink = try fixture(at: root, name: "StructuralLink")
        try fm.moveItem(at: structuralLink.resources, to: structuralLink.appex.appendingPathComponent("SavedResources"))
        try fm.createSymbolicLink(at: structuralLink.resources, withDestinationURL: structuralLink.appex.appendingPathComponent("SavedResources"))
        try rejects("Structural Resources symlink", containing: "symbolic") { _ = try importer.inspect(applicationURL: structuralLink.app) }
        let metadataLimit = try fixture(at: root, name: "HugeMetadata")
        try Data(repeating: 32, count: SafariExtensionImport.maximumMetadataBytes + 1).write(to: metadataLimit.resources.appendingPathComponent("manifest.json"))
        try rejects("Oversized manifest", containing: "1 MiB") { _ = try importer.inspect(applicationURL: metadataLimit.app) }
        let invalidManifest = try fixture(at: root, name: "InvalidManifest")
        try writeManifest(["manifest_version": 1, "version": "1"], to: invalidManifest.resources.appendingPathComponent("manifest.json"))
        try rejects("Unsupported manifest", containing: "Manifest V2 or V3") { _ = try importer.inspect(applicationURL: invalidManifest.app) }

        try writeManifest(["manifest_version": 3, "name": "Fixture Safari Extension", "version": "2.0"], to: original.resources.appendingPathComponent("manifest.json"))
        try rejects("Updated installed handler invalidates old snapshot", containing: "changed") { try importer.validateSnapshot(at: copied, original: candidate) }
        try check(try Data(contentsOf: copied.appendingPathComponent("Contents/Resources/manifest.json")) == before, "Origin revalidation does not mutate the private snapshot")
        try fm.removeItem(at: original.app)
        try rejects("Removed containing app invalidates snapshot") { try importer.validateSnapshot(at: copied, original: candidate) }
        print("Safari extension import: \(checks) checks passed")
    }
}
