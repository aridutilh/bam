import Foundation
import Security

/// A verified, installed Safari WebExtension and the containing app that owns
/// its native handler. This is app metadata, never a Safari/browser profile.
struct SafariExtensionBundle: Codable, Equatable, Sendable {
    let appURL: URL
    let appexURL: URL
    let resourceURL: URL
    let applicationBundleIdentifier: String
    let extensionBundleIdentifier: String
    let teamIdentifier: String
    let applicationCodeHash: String
    let extensionCodeHash: String
    let distribution: SafariExtensionSigningIdentity.Distribution
    let displayName: String
    let version: String
}

struct SafariExtensionSigningIdentity: Equatable, Sendable {
    enum Distribution: String, Codable, Sendable { case appStore, developerID }
    let identifier: String
    let teamIdentifier: String
    let codeHash: String
    let distribution: Distribution
}

struct SafariExtensionImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Inspects installed containing apps and snapshots signed .appex bundles
/// without changing a byte. Callers still perform Bam's permission review.
///
/// WKWebExtension(appExtensionBundle:) preserves the bundle identity; WebKit's
/// default native handler looks it up through NSExtension by bundle identifier.
/// Therefore the original containing app must remain installed. A snapshot is
/// not a way to install, register, purchase or redistribute an App Store app.
struct SafariExtensionImport: Sendable {
    typealias SignatureValidator = @Sendable (URL) throws -> SafariExtensionSigningIdentity
    private let validateSignature: SignatureValidator
    static let maximumBundleBytes = 512 * 1_048_576
    static let maximumBundleEntries = 50_000
    static let maximumMetadataBytes = 1_048_576

    init(signatureValidator: @escaping SignatureValidator = { try SafariExtensionImport.checkSignature(at: $0) }) {
        validateSignature = signatureValidator
    }

    /// The expected identifier comes from Apple's lookup API, not an app name.
    /// In that store-linked path only Mac App Store signatures are accepted;
    /// manually selected Developer ID apps can use the unbound import path.
    func inspect(applicationURL: URL, expectedApplicationBundleIdentifier: String? = nil) throws -> [SafariExtensionBundle] {
        let app = try directory(applicationURL, suffix: "app")
        let contents = try childDirectory("Contents", of: app)
        let appInfo = try propertyList(contents.appendingPathComponent("Info.plist"))
        guard let appID = appInfo["CFBundleIdentifier"] as? String, !appID.isEmpty else {
            throw failure("The selected app has no bundle identifier.")
        }
        if let expected = expectedApplicationBundleIdentifier, appID != expected {
            throw failure("This app does not match the selected App Store listing.")
        }
        let appSignature = try validateSignature(app)
        try match(appSignature, identifier: appID)
        if expectedApplicationBundleIdentifier != nil, appSignature.distribution != .appStore {
            throw failure("Choose the Mac App Store copy of this app to match its store listing.")
        }
        let pluginURL = contents.appendingPathComponent("PlugIns", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pluginURL.path) else { return [] }
        let plugins = try childDirectory("PlugIns", of: contents)
        var candidates: [SafariExtensionBundle] = []
        let children = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard children.count <= 256 else { throw failure("The app contains too many extension bundles to inspect safely.") }
        for child in children where child.pathExtension.lowercased() == "appex" {
            let appex = try directory(child, suffix: "appex")
            let extensionContents = try childDirectory("Contents", of: appex)
            let info = try propertyList(extensionContents.appendingPathComponent("Info.plist"))
            let settings = info["NSExtension"] as? [String: Any]
            guard settings?["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension" else { continue }
            guard let extensionID = info["CFBundleIdentifier"] as? String, !extensionID.isEmpty else {
                throw failure("A Safari extension in this app has no bundle identifier.")
            }
            let resources = try childDirectory("Resources", of: extensionContents)
            let data = try metadata(resources.appendingPathComponent("manifest.json"))
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let manifestVersion = manifest["manifest_version"] as? Int, [2, 3].contains(manifestVersion),
                  let version = manifest["version"] as? String, !version.isEmpty else {
                throw failure("The Safari extension must contain a valid Manifest V2 or V3 WebExtension.")
            }
            try validateTree(appex)
            let signature = try validateSignature(appex)
            try match(signature, identifier: extensionID)
            guard signature.teamIdentifier == appSignature.teamIdentifier else {
                throw failure("The Safari extension and its containing app have different signing teams.")
            }
            let manifestName = manifest["name"] as? String
            let displayName = manifestName.flatMap { $0.contains("__MSG_") ? nil : $0 }
                ?? info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? extensionID
            candidates.append(SafariExtensionBundle(appURL: app, appexURL: appex, resourceURL: resources,
                applicationBundleIdentifier: appID, extensionBundleIdentifier: extensionID, teamIdentifier: signature.teamIdentifier,
                applicationCodeHash: appSignature.codeHash, extensionCodeHash: signature.codeHash, distribution: appSignature.distribution,
                displayName: displayName, version: version))
        }
        return candidates
    }

    /// Revalidate the installed app before each load. Updating/removing its
    /// native handler must not silently pair with an old private web snapshot.
    @discardableResult func validate(_ candidate: SafariExtensionBundle) throws -> SafariExtensionBundle {
        let current = try inspect(applicationURL: candidate.appURL,
            expectedApplicationBundleIdentifier: candidate.distribution == .appStore ? candidate.applicationBundleIdentifier : nil)
        guard let match = current.first(where: { $0.extensionBundleIdentifier == candidate.extensionBundleIdentifier }), match == candidate else {
            throw failure("The installed Safari app changed or was removed. Add its extension again to review the current version.")
        }
        return match
    }

    /// Copies the whole signed bundle, including its handler executable, but
    /// never executes it. The destination must be a new .appex under Bam storage.
    /// Load it with WKWebExtension(appExtensionBundle:), not resourceBaseURL.
    @discardableResult func snapshot(_ candidate: SafariExtensionBundle, to destination: URL) throws -> URL {
        _ = try validate(candidate)
        guard destination.isFileURL, destination.pathExtension.lowercased() == "appex",
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw failure("Choose a new private .appex destination for the Safari extension.")
        }
        let parent = try directory(destination.deletingLastPathComponent())
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        guard !isWithin(target, candidate.appURL), !isWithin(candidate.appURL, target) else {
            throw failure("Bam's private extension copy must be outside the installed app.")
        }
        do {
            try FileManager.default.copyItem(at: candidate.appexURL, to: target)
            try validateTree(target)
            let signature = try validateSignature(target)
            try match(signature, identifier: candidate.extensionBundleIdentifier)
            guard signature.teamIdentifier == candidate.teamIdentifier, signature.codeHash == candidate.extensionCodeHash else {
                throw failure("The copied Safari extension no longer matches its verified signature.")
            }
            _ = try validate(candidate)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Validate an existing private snapshot as well as its still-installed
    /// original. No permissions or code are run by this check.
    func validateSnapshot(at snapshot: URL, original: SafariExtensionBundle) throws {
        _ = try validate(original)
        let bundle = try directory(snapshot, suffix: "appex")
        try validateTree(bundle)
        let signature = try validateSignature(bundle)
        try match(signature, identifier: original.extensionBundleIdentifier)
        guard signature.teamIdentifier == original.teamIdentifier, signature.codeHash == original.extensionCodeHash else {
            throw failure("The Safari extension copy no longer matches the installed app.")
        }
    }

    private func match(_ signature: SafariExtensionSigningIdentity, identifier: String) throws {
        guard signature.identifier == identifier, !signature.teamIdentifier.isEmpty, !signature.codeHash.isEmpty else {
            throw failure("The app's signed identity does not match its bundle metadata.")
        }
    }
    private func directory(_ url: URL, suffix: String? = nil) throws -> URL {
        guard url.isFileURL, suffix == nil || url.pathExtension.lowercased() == suffix else { throw failure("Choose a local \(suffix ?? "folder") bundle.") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure("Extension bundles and their structural folders cannot be symbolic links.") }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func childDirectory(_ name: String, of parent: URL) throws -> URL {
        let child = try directory(parent.appendingPathComponent(name, isDirectory: true))
        guard isWithin(child, parent) else { throw failure("An extension folder escapes its containing bundle.") }
        return child
    }
    private func metadata(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumMetadataBytes else { throw failure("Extension metadata must be a regular file smaller than 1 MiB.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumMetadataBytes + 1) ?? Data()
        guard data.count <= Self.maximumMetadataBytes else { throw failure("Extension metadata exceeds the 1 MiB limit.") }
        return data
    }
    private func propertyList(_ url: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: metadata(url), format: nil) as? [String: Any] else { throw failure("The app contains invalid bundle metadata.") }
        return value
    }
    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        let path = child.standardizedFileURL.path, base = parent.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }
    private func validateTree(_ bundle: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys, errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("The Safari extension bundle could not be inspected.") }
        var count = 0, bytes = 0
        for case let file as URL in walker {
            count += 1
            guard count <= Self.maximumBundleEntries else { throw failure("The Safari extension contains too many files.") }
            let value = try file.resourceValues(forKeys: Set(keys))
            if value.isSymbolicLink == true {
                guard isWithin(file.resolvingSymlinksInPath(), bundle) else { throw failure("A Safari extension symbolic link escapes its bundle.") }
            } else if value.isRegularFile == true {
                bytes += value.fileSize ?? 0
                guard bytes <= Self.maximumBundleBytes else { throw failure("The Safari extension exceeds the 512 MiB import limit.") }
            } else if value.isDirectory != true { throw failure("The Safari extension contains a non-regular file.") }
        }
        if let enumerationError { throw enumerationError }
    }
    private func failure(_ message: String) -> SafariExtensionImportError { SafariExtensionImportError(message: message) }

    /// Static validation checks code, resources, nested code and every CPU slice.
    /// A valid ad-hoc signature is insufficient: the signer must chain to Apple
    /// as Mac App Store distribution or Developer ID (TN3127/TN2206).
    static func checkSignature(at url: URL) throws -> SafariExtensionSigningIdentity {
        func fail(_ message: String) -> SafariExtensionImportError { SafariExtensionImportError(message: message) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw fail("The selected app has no readable code signature.") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        func satisfies(_ expression: String) -> Bool {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
            return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        }
        let distribution: SafariExtensionSigningIdentity.Distribution
        if satisfies("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists") { distribution = .appStore }
        else if satisfies("anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists") { distribution = .developerID }
        else { throw fail("The app's signature could not be verified as Mac App Store or Developer ID code. Install an intact copy from its publisher before adding it to Bam.") }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let hash = info[kSecCodeInfoUnique as String] as? Data else { throw fail("The app's signing identity is incomplete.") }
        return SafariExtensionSigningIdentity(identifier: identifier, teamIdentifier: team,
            codeHash: hash.map { String(format: "%02x", $0) }.joined(), distribution: distribution)
    }
}
