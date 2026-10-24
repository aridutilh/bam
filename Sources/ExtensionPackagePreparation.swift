import Foundation

/// Prepares the app's private package copy without changing extension JavaScript.
/// WebKit's generated MV2 background page omits a charset; an explicit UTF-8 page
/// preserves non-ASCII JavaScript identifiers in scripts loaded from that page.
enum ExtensionPackagePreparation {
    private static let maximumManifestBytes = 1_048_576

    @discardableResult
    static func prepare(package: URL, originalManifestURL: URL) throws -> String? {
        let fm = FileManager.default
        guard package.isFileURL, originalManifestURL.isFileURL else {
            throw failure("Extension preparation requires local file URLs.")
        }
        let package = package.standardizedFileURL
        let packageValues = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageValues.isDirectory == true, packageValues.isSymbolicLink != true else {
            throw failure("Choose an unpacked extension folder.")
        }
        let manifestURL = package.appendingPathComponent("manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumManifestBytes else {
            throw failure("The extension manifest must be a regular file no larger than 1 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: manifestURL)
        defer { try? handle.close() }
        let original = try handle.read(upToCount: maximumManifestBytes + 1) ?? Data()
        guard original.count <= maximumManifestBytes else {
            throw failure("The extension manifest exceeds 1 MiB.")
        }
        guard var manifest = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw failure("The extension manifest must be a JSON object.")
        }
        guard manifest["manifest_version"] as? Int == 2 else { return nil }
        guard let rawBackground = manifest["background"] else { return nil }
        guard var background = rawBackground as? [String: Any] else {
            throw failure("The extension background declaration must be an object.")
        }
        guard let rawScripts = background["scripts"] else { return nil }
        guard let scripts = rawScripts as? [String], !scripts.isEmpty else {
            throw failure("Background scripts must be a nonempty array of local paths.")
        }

        // Validate every entry before producing any files. Never follow a script
        // symlink, even when it currently points back into the copied package.
        for script in scripts { try validateScript(script, in: package) }
        let canonicalPackage = package.resolvingSymlinksInPath().standardizedFileURL.path
        let backup = originalManifestURL.standardizedFileURL
        let backupParent = backup.deletingLastPathComponent()
        let parentValues = try backupParent.resourceValues(forKeys: [.isDirectoryKey])
        // Resolve the existing parent, not the missing leaf: Foundation can
        // otherwise preserve /private/tmp for one path and use /tmp for the other.
        let canonicalBackup = backupParent.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(backup.lastPathComponent).path
        guard parentValues.isDirectory == true,
              canonicalBackup != canonicalPackage,
              !canonicalBackup.hasPrefix(canonicalPackage + "/"),
              !fm.fileExists(atPath: backup.path),
              (try? backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw failure("The original manifest backup must be a new file outside the package.")
        }

        var pageName: String
        var pageURL: URL
        repeat {
            pageName = "__bam_utf8_background_" + UUID().uuidString.lowercased() + ".html"
            pageURL = package.appendingPathComponent(pageName)
        } while fm.fileExists(atPath: pageURL.path)

        let module = background["type"] as? String == "module" ? " type=\"module\"" : ""
        let tags = scripts.map { "<script\(module) src=\"\(escapeAttribute($0))\"></script>" }.joined(separator: "\n")
        let html = Data(("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body>\n" + tags + "\n</body></html>\n").utf8)
        background.removeValue(forKey: "scripts")
        background["page"] = pageName
        manifest["background"] = background
        let replacement = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        // The manifest is the final atomic commit. Failure before that point leaves
        // the original manifest intact; the byte-exact backup remains available.
        try original.write(to: backup, options: .atomic)
        do {
            try html.write(to: pageURL, options: .atomic)
            try replacement.write(to: manifestURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: pageURL)
            throw error
        }
        return "Prepared an explicit UTF-8 background page for Manifest V2. Extension scripts are unchanged; the original manifest is preserved."
    }

    private static func validateScript(_ path: String, in package: URL) throws {
        func isSafe(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 4_096 &&
            !value.hasPrefix("/") && !value.contains("\\") &&
            !value.contains(":") && !value.contains("?") && !value.contains("#") &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
        guard isSafe(path), let decoded = path.removingPercentEncoding, isSafe(decoded),
              !path.lowercased().contains("%2f"), !path.lowercased().contains("%5c") else {
            throw failure("A background script has an unsafe or non-local path.")
        }
        var location = package
        let components = decoded.split(separator: "/")
        for (index, component) in components.enumerated() {
            location.appendPathComponent(String(component))
            let values = try location.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  index == components.count - 1 ? values.isRegularFile == true : values.isDirectory == true else {
                throw failure("Background scripts must be regular files inside the extension package.")
            }
        }
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path
        guard location.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
            throw failure("A background script escapes the extension package.")
        }
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Bam.ExtensionPackagePreparation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
