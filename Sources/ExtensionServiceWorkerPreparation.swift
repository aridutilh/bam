import Foundation
import CryptoKit

/// Adds a synchronous compatibility entry point to the app's private MV3 copy.
/// The background remains a service worker: no DOM, HTML conversion, asynchronous
/// import, or lifetime extension. Classic workers retain their registration URL;
/// their source bytes move to a sibling and the private entry becomes a loader.
/// Modules retain their source URL/import.meta.url and use a sibling entry.
enum ExtensionServiceWorkerPreparation {
    static let markerKey = "_bam_service_worker"
    private static let schema = 2
    private static let maximumWorkerBytes = 64 * 1_048_576
    private static let maximumMetadataBytes = 65_536

    private struct Preparation: Codable {
        let schemaVersion: Int
        let original: String
        let entry: String
        let adapter: String
        let source: String
        let originalScriptSHA256: String
        let module: Bool
        let adapterSHA256: String
        let originalManifestSHA256: String
    }

    /// Informational only. An upstream manifest can forge this marker. It must
    /// never authorize native requests, external applications or extra APIs.
    static func isPrepared(manifest: [String: Any]) -> Bool {
        guard let marker = manifest[markerKey] as? [String: Any], marker["schemaVersion"] as? Int == schema,
              let entry = marker["entry"] as? String, let original = marker["original"] as? String,
              let adapter = marker["adapter"] as? String, let source = marker["source"] as? String, !original.isEmpty, !adapter.isEmpty, !source.isEmpty,
              let background = manifest["background"] as? [String: Any], background["service_worker"] as? String == entry,
              (manifest["permissions"] as? [String])?.contains("nativeMessaging") == true else { return false }
        return !entry.isEmpty
    }

    /// Returns nil for other background types or an exactly verified repeat.
    /// The external sidecar establishes preparation identity; the manifest marker
    /// alone is never trusted to skip validation or wrapping.
    @discardableResult
    static func prepare(package: URL, originalManifestURL: URL, adapterSource: String) throws -> String? {
        let fm = FileManager.default
        guard package.isFileURL, originalManifestURL.isFileURL else { throw failure("Worker preparation requires local file URLs.") }
        let package = package.standardizedFileURL
        let packageValues = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageValues.isDirectory == true, packageValues.isSymbolicLink != true else { throw failure("Choose an unpacked extension folder.") }
        let manifestURL = package.appendingPathComponent("manifest.json")
        let current = try readRegular(manifestURL, limit: ExtensionPackagePreparation.maximumManifestBytes)
        guard var manifest = try JSONSerialization.jsonObject(with: current) as? [String: Any] else { throw failure("The extension manifest must be a JSON object.") }
        guard manifest["manifest_version"] as? Int == 3 else { return nil }
        guard let rawBackground = manifest["background"] else { return nil }
        guard var background = rawBackground as? [String: Any] else { throw failure("The extension background declaration must be an object.") }
        guard let rawWorker = background["service_worker"] else { return nil }
        guard let worker = rawWorker as? String else { throw failure("The service worker must be a local script path.") }
        let type = background["type"] as? String
        guard background["type"] == nil || type == "classic" || type == "module" else { throw failure("The service worker type must be classic or module.") }
        let module = type == "module"
        try ExtensionPackagePreparation.validateScript(worker, in: package, kind: "service worker")
        let adapterBytes = Data(adapterSource.utf8)
        guard !adapterBytes.isEmpty, adapterBytes.count <= ExtensionPackagePreparation.maximumManifestBytes else { throw failure("The worker compatibility adapter must contain at most 1 MiB of JavaScript.") }
        let backup = originalManifestURL.standardizedFileURL
        let metadata = backup.appendingPathExtension("worker-preparation.json")
        try validateExternal(backup, package: package)
        try validateExternal(metadata, package: package)
        let adapterHash = digest(adapterBytes)

        if fm.fileExists(atPath: metadata.path) {
            let record = try JSONDecoder().decode(Preparation.self, from: readRegular(metadata, limit: maximumMetadataBytes))
            let originalBytes = try readRegular(backup, limit: ExtensionPackagePreparation.maximumManifestBytes)
            guard record.schemaVersion == schema, record.entry == worker, record.module == module,
                  record.adapterSHA256 == adapterHash, record.originalManifestSHA256 == digest(originalBytes), isPrepared(manifest: manifest),
                  (manifest[markerKey] as? [String: Any])?["original"] as? String == record.original,
                  (manifest[markerKey] as? [String: Any])?["adapter"] as? String == record.adapter,
                  (manifest[markerKey] as? [String: Any])?["source"] as? String == record.source else {
                throw failure("The worker preparation metadata does not match this package or adapter. Use the original extension package.")
            }
            for path in [record.source, record.adapter] { try ExtensionPackagePreparation.validateScript(path, in: package, kind: "service worker") }
            guard directory(record.original) == directory(record.entry), directory(record.original) == directory(record.adapter),
                  directory(record.original) == directory(record.source),
                  module ? record.source == record.original && record.entry != record.original : record.entry == record.original && record.source != record.original,
                  digest(try readRegular(file(record.source, package: package), limit: maximumWorkerBytes)) == record.originalScriptSHA256,
                  try readRegular(file(record.adapter, package: package), limit: ExtensionPackagePreparation.maximumManifestBytes) == adapterBytes,
                  try readRegular(file(record.entry, package: package), limit: maximumMetadataBytes) == Data(wrapper(original: record.source, adapter: record.adapter, module: module).utf8) else {
                throw failure("The prepared worker scripts have changed. Use the original extension package.")
            }
            return nil
        }
        guard manifest[markerKey] == nil else { throw failure("This package has unverified Bam worker metadata. Use the original extension package.") }
        var permissions: [String]
        if let rawPermissions = manifest["permissions"] {
            guard let list = rawPermissions as? [String] else { throw failure("Extension permissions must be an array of strings.") }
            permissions = list
        } else { permissions = [] }
        if !permissions.contains("nativeMessaging") { permissions.append("nativeMessaging") }

        let originalBytes: Data
        if fm.fileExists(atPath: backup.path) {
            originalBytes = try readRegular(backup, limit: ExtensionPackagePreparation.maximumManifestBytes)
            guard let original = try JSONSerialization.jsonObject(with: originalBytes) as? [String: Any],
                  original["manifest_version"] as? Int == 3,
                  (original["background"] as? [String: Any])?["service_worker"] as? String == worker else {
                throw failure("The original manifest backup belongs to a different service worker.")
            }
        } else { originalBytes = current }
        let workerBytes = try readRegular(file(worker, package: package), limit: maximumWorkerBytes)
        let prefix = directory(worker)
        var entry: String, adapter: String, source: String
        repeat {
            let identifier = UUID().uuidString.lowercased()
            entry = module ? prefix + "__bam_worker_" + identifier + ".js" : worker
            source = module ? worker : prefix + "__bam_worker_original_" + identifier + ".js"
            adapter = prefix + "__bam_worker_adapter_" + identifier + ".js"
        } while (module && fm.fileExists(atPath: file(entry, package: package).path)) ||
            (!module && fm.fileExists(atPath: file(source, package: package).path)) || fm.fileExists(atPath: file(adapter, package: package).path)
        let record = Preparation(schemaVersion: schema, original: worker, entry: entry, adapter: adapter, source: source, originalScriptSHA256: digest(workerBytes), module: module,
                                 adapterSHA256: adapterHash, originalManifestSHA256: digest(originalBytes))
        background["service_worker"] = entry
        manifest["background"] = background; manifest["permissions"] = permissions
        manifest[markerKey] = ["schemaVersion": schema, "original": worker, "entry": entry, "adapter": adapter, "source": source]
        let replacement = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        guard replacement.count <= ExtensionPackagePreparation.maximumManifestBytes else { throw failure("The prepared manifest exceeds 1 MiB.") }
        let metadataBytes = try JSONEncoder().encode(record)
        if !fm.fileExists(atPath: backup.path) { try originalBytes.write(to: backup, options: .atomic) }
        var replacedClassicEntry = false
        do {
            if !module { try workerBytes.write(to: file(source, package: package), options: .atomic) }
            try adapterBytes.write(to: file(adapter, package: package), options: .atomic)
            try metadataBytes.write(to: metadata, options: .atomic)
            try Data(wrapper(original: source, adapter: adapter, module: module).utf8).write(to: file(entry, package: package), options: .atomic)
            replacedClassicEntry = !module
            // Final commit; a failure restores the classic entry from its saved bytes.
            try replacement.write(to: manifestURL, options: .atomic)
        } catch {
            if replacedClassicEntry {
                do { try workerBytes.write(to: file(worker, package: package), options: .atomic) }
                catch { throw failure("Worker preparation could not restore its entry. The byte-exact original is preserved at \(source).") }
            }
            try? fm.removeItem(at: file(adapter, package: package))
            try? fm.removeItem(at: file(module ? entry : source, package: package))
            try? fm.removeItem(at: metadata)
            throw error
        }
        let detail = module
            ? "The module entry URL changes within its original directory; original module source URLs and import.meta.url are preserved."
            : "The classic worker keeps its original entry URL. Its private entry is replaced by a loader, with the byte-exact original script preserved beside it."
        return "Prepared a compatibility entry for the Manifest V3 service worker; worker type is unchanged. \(detail) The compatibility layer uses Bam’s internal nativeMessaging transport. External desktop access requires separate approval and currently supports only the verified Chrome build of 1Password. The original manifest is preserved."
    }

    private static func wrapper(original: String, adapter: String, module: Bool) -> String {
        // JSON literals quote paths safely, including quotes and Unicode. The
        // original URL-encoded basename is retained for URL resolution by WebKit.
        let shim = literal("./" + String(adapter.split(separator: "/").last!))
        let source = literal("./" + String(original.split(separator: "/").last!))
        if module { return "// Bam compatibility entry; original module is unchanged.\nimport \(shim);\nimport \(source);\n" }
        return "// Bam compatibility entry; original classic script is unchanged.\nimportScripts(\(shim), \(source));\n"
    }
    private static func literal(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
    private static func directory(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }
    private static func file(_ path: String, package: URL) -> URL { package.appendingPathComponent(path.removingPercentEncoding!) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func readRegular(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else { throw failure("Worker preparation requires bounded regular files without symbolic links.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw failure("A worker preparation file exceeds its size limit.") }
        return bytes
    }
    private static func validateExternal(_ url: URL, package: URL) throws {
        let parent = url.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let root = package.resolvingSymlinksInPath().path
        let canonical = parent.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        guard values.isDirectory == true, values.isSymbolicLink != true, canonical != root, !canonical.hasPrefix(root + "/"),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw failure("Worker provenance files must be outside the package and must not be symbolic links.")
        }
    }
    private static func failure(_ message: String) -> NSError { ExtensionPackagePreparation.failure(message) }
}
