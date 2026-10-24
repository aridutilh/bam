import Foundation
import CryptoKit

@main struct ExtensionPackagePreparationTests {
    static var checks = 0
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
        checks += 1
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CheckFailure(description: "Usage: extension-package-tests <scoped temporary directory>")
            }
            try run(in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("Extension package preparation: \(checks) checks passed")
        } catch {
            fputs("FAIL: Extension package preparation: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(in parent: URL) throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("extension-package-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func manifest(_ scripts: Any = ["background.js"], version: Int = 2,
                      additions: [String: Any] = [:]) throws -> Data {
            var background: [String: Any] = ["scripts": scripts, "persistent": true]
            additions.forEach { background[$0.key] = $0.value }
            return try JSONSerialization.data(withJSONObject: [
                "manifest_version": version, "name": "UTF-8 fixture café", "version": "1.0",
                "permissions": ["storage"], "background": background
            ], options: [.prettyPrinted, .sortedKeys])
        }
        func package(_ name: String, bytes: Data? = nil) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try (bytes ?? manifest()).write(to: url.appendingPathComponent("manifest.json"))
            try Data("const café = '日本語'; globalThis.fixture = café;\n".utf8).write(to: url.appendingPathComponent("background.js"))
            return url
        }
        func object(_ url: URL) throws -> [String: Any] {
            guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CheckFailure(description: "Expected a JSON object")
            }
            return result
        }
        func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        func reject(_ name: String, bytes: Data? = nil, setup: ((URL) throws -> Void)? = nil,
                    backup: ((URL) throws -> URL)? = nil) throws {
            let url = try package(name, bytes: bytes)
            try setup?(url)
            let file = url.appendingPathComponent("manifest.json")
            let before = try Data(contentsOf: file)
            let paths = try fm.contentsOfDirectory(atPath: url.path).sorted()
            let destination = try backup?(url) ?? root.appendingPathComponent(name + "-original.json")
            var rejected = false
            do { _ = try ExtensionPackagePreparation.prepare(package: url, originalManifestURL: destination) }
            catch { rejected = true }
            try check(rejected, "\(name): invalid preparation must fail")
            try check(try Data(contentsOf: file) == before && fm.contentsOfDirectory(atPath: url.path).sorted() == paths,
                      "\(name): failed preparation must leave the package manifest and entries unchanged")
        }

        // Work on a copied package exactly as the importer does, preserving the
        // selected source and the extension's actual non-ASCII JavaScript bytes.
        let scripts = ["background.js", "lib/second.js", "background.js"]
        let source = try package("source", bytes: manifest(scripts, additions: ["persistent": false, "custom": ["preserve": true]]))
        try fm.createDirectory(at: source.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("const 日本語 = 'é'; globalThis.second = 日本語;\n".utf8).write(to: source.appendingPathComponent("lib/second.js"))
        let unrelated = "__bam_utf8_background_existing.html"
        try Data("unrelated content".utf8).write(to: source.appendingPathComponent(unrelated))
        let originalManifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let originalHashes = try scripts.map { try hash(source.appendingPathComponent($0)) }
        let copy = root.appendingPathComponent("private-copy")
        try fm.copyItem(at: source, to: copy)
        let backup = root.appendingPathComponent("original-manifest.json")
        let note = try ExtensionPackagePreparation.prepare(package: copy, originalManifestURL: backup)
        try check(note?.contains("UTF-8") == true, "Adaptation returns an explicit compatibility note")
        try check(try Data(contentsOf: backup) == originalManifest, "Backup preserves original manifest bytes exactly")
        try check(try Data(contentsOf: source.appendingPathComponent("manifest.json")) == originalManifest,
                  "The user-selected source manifest stays unchanged")
        let result = try object(copy.appendingPathComponent("manifest.json"))
        let background = result["background"] as! [String: Any]
        let generatedName = background["page"] as! String
        try check(background["scripts"] == nil && generatedName != unrelated, "The manifest uses a distinct generated background page")
        try check(background["persistent"] as? Bool == false &&
                  (background["custom"] as? [String: Bool])?["preserve"] == true,
                  "Other background properties remain intact")
        try check(result["name"] as? String == "UTF-8 fixture café" && result["permissions"] as? [String] == ["storage"],
                  "Unrelated manifest fields survive preparation")
        let html = try String(contentsOf: copy.appendingPathComponent(generatedName), encoding: .utf8)
        let tags = scripts.map { "<script src=\"\($0)\"></script>" }.joined(separator: "\n")
        try check(html.contains(tags), "Script order and deliberate repeated scripts are preserved")
        try check(html.range(of: "<meta charset=\"utf-8\">")!.lowerBound < html.range(of: "<script")!.lowerBound,
                  "UTF-8 is declared before external scripts")
        try check(try scripts.map { try hash(copy.appendingPathComponent($0)) } == originalHashes &&
                  scripts.map { try hash(source.appendingPathComponent($0)) } == originalHashes,
                  "Every source and copied JavaScript SHA-256 remains unchanged")
        try check(try String(contentsOf: copy.appendingPathComponent(unrelated), encoding: .utf8) == "unrelated content",
                  "An existing similarly named page is never replaced")
        let preparedManifest = try Data(contentsOf: copy.appendingPathComponent("manifest.json"))
        let again = try ExtensionPackagePreparation.prepare(package: copy, originalManifestURL: backup)
        try check(again == nil && Data(contentsOf: copy.appendingPathComponent("manifest.json")) == preparedManifest &&
                  Data(contentsOf: backup) == originalManifest, "Repeating preparation is a byte-preserving no-op")

        let specialPath = "lib/a&b'\"<>.js"
        let escaped = try package("escaped", bytes: manifest(["background.js", specialPath, "space%20name.js"], additions: ["type": "module"]))
        try fm.createDirectory(at: escaped.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("export const label = '✓';".utf8).write(to: escaped.appendingPathComponent(specialPath))
        try Data("export const count = 2;".utf8).write(to: escaped.appendingPathComponent("space name.js"))
        _ = try ExtensionPackagePreparation.prepare(package: escaped, originalManifestURL: root.appendingPathComponent("escaped-backup.json"))
        let escapedBG = try object(escaped.appendingPathComponent("manifest.json"))["background"] as! [String: Any]
        let escapedHTML = try String(contentsOf: escaped.appendingPathComponent(escapedBG["page"] as! String), encoding: .utf8)
        try check(escapedHTML.contains("src=\"lib/a&amp;b&#39;&quot;&lt;&gt;.js\""),
                  "HTML attribute metacharacters cannot alter the generated document")
        try check(escapedHTML.contains("src=\"space%20name.js\"") && escapedHTML.components(separatedBy: "type=\"module\"").count == 4,
                  "Encoded local filenames and module script semantics are retained")

        for (name, bytes) in [
            ("mv3", try manifest(version: 3)),
            ("worker", Data(#"{"manifest_version":3,"background":{"service_worker":"background.js"}}"#.utf8)),
            ("page", Data(#"{"manifest_version":2,"background":{"page":"existing.html","persistent":false}}"#.utf8)),
            ("no-background", Data(#"{"manifest_version":2,"name":"No background"}"#.utf8))
        ] {
            let url = try package(name, bytes: bytes)
            let destination = root.appendingPathComponent(name + "-backup.json")
            let response = try ExtensionPackagePreparation.prepare(package: url, originalManifestURL: destination)
            try check(response == nil && Data(contentsOf: url.appendingPathComponent("manifest.json")) == bytes &&
                      !fm.fileExists(atPath: destination.path), "\(name): other background formats remain byte-exact")
        }

        for (index, path) in ["../outside.js", "lib/../background.js", "/background.js", "//host/a.js",
                              "https://example.com/a.js", "data:text/javascript,alert(1)", "a\\b.js",
                              "background.js?query", "background.js#fragment", "%2e%2e/outside.js",
                              "lib%2fbackground.js", "%5cbackground.js", "lib//background.js",
                              "./background.js", "background.js\n", "bad%ZZ.js", ""].enumerated() {
            try reject("unsafe-\(index)", bytes: manifest([path]))
        }
        try reject("missing", bytes: manifest(["background.js", "missing.js"]))
        try reject("directory", bytes: manifest(["lib"]), setup: { try fm.createDirectory(at: $0.appendingPathComponent("lib"), withIntermediateDirectories: true) })
        try reject("symlink-file", bytes: manifest(["link.js"]), setup: {
            try fm.createSymbolicLink(at: $0.appendingPathComponent("link.js"), withDestinationURL: $0.appendingPathComponent("background.js"))
        })
        try reject("symlink-parent", bytes: manifest(["link/background.js"]), setup: {
            try fm.createSymbolicLink(at: $0.appendingPathComponent("link"), withDestinationURL: $0)
        })
        try reject("wrong-list", bytes: manifest("background.js"))
        try reject("mixed-list", bytes: manifest(["background.js", 42] as [Any]))
        try reject("empty-list", bytes: manifest([] as [String]))
        try reject("bad-background", bytes: Data(#"{"manifest_version":2,"background":"scripts"}"#.utf8))
        try reject("bad-json", bytes: Data("{ invalid".utf8))
        try reject("array-json", bytes: Data("[]".utf8))
        try reject("oversized", bytes: Data(repeating: 32, count: 1_048_577))
        try reject("inside-backup", backup: { $0.appendingPathComponent("original-manifest.json") })
        let occupied = root.appendingPathComponent("occupied-backup.json")
        try Data("leave this file".utf8).write(to: occupied)
        try reject("occupied-backup", backup: { _ in occupied })
        try check(try String(contentsOf: occupied, encoding: .utf8) == "leave this file", "Existing backup destinations are not overwritten")
        try reject("aliased-inside-backup", setup: {
            try fm.createSymbolicLink(at: root.appendingPathComponent("package-alias"), withDestinationURL: $0)
        }, backup: { _ in root.appendingPathComponent("package-alias/original-manifest.json") })

        // A nonexistent backup leaf and an existing package can retain different
        // spellings of macOS's system temporary-directory alias. Both directions
        // must reject an inside backup without changing any package contents.
        let aliasName = "bam-preparation-alias-" + UUID().uuidString
        let aliasRoot = URL(fileURLWithPath: "/private/tmp/" + aliasName, isDirectory: true)
        try fm.createDirectory(at: aliasRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: aliasRoot) }
        for (index, prefixes) in [("/private/tmp/", "/tmp/"), ("/tmp/", "/private/tmp/")].enumerated() {
            let suffix = aliasName + "/case-\(index)"
            let packageURL = URL(fileURLWithPath: prefixes.0 + suffix, isDirectory: true)
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let manifestURL = packageURL.appendingPathComponent("manifest.json")
            let bytes = try manifest()
            try bytes.write(to: manifestURL)
            try Data("globalThis.aliasFixture = true;".utf8).write(to: packageURL.appendingPathComponent("background.js"))
            let entries = try fm.contentsOfDirectory(atPath: packageURL.path).sorted()
            let inside = URL(fileURLWithPath: prefixes.1 + suffix + "/original-manifest.json")
            var rejected = false
            do { _ = try ExtensionPackagePreparation.prepare(package: packageURL, originalManifestURL: inside) }
            catch { rejected = true }
            try check(rejected, "System temporary aliases must not bypass inside-backup rejection (\(index))")
            try check(try Data(contentsOf: manifestURL) == bytes && fm.contentsOfDirectory(atPath: packageURL.path).sorted() == entries,
                      "Alias rejection must leave the original manifest and package entries unchanged (\(index))")
            let outside = URL(fileURLWithPath: prefixes.1 + aliasName + "/outside-\(index).json")
            let response = try ExtensionPackagePreparation.prepare(package: packageURL, originalManifestURL: outside)
            try check(response != nil && Data(contentsOf: outside) == bytes,
                      "A new external sibling backup through an alias must remain supported (\(index))")
        }

        // The size limit is inclusive, not an approximate character-count limit.
        var exact = try manifest()
        exact.append(Data(repeating: 32, count: 1_048_576 - exact.count))
        let bounded = try package("exact-limit", bytes: exact)
        let boundedBackup = root.appendingPathComponent("exact-limit-original.json")
        _ = try ExtensionPackagePreparation.prepare(package: bounded, originalManifestURL: boundedBackup)
        try check(try Data(contentsOf: boundedBackup) == exact, "Exactly 1 MiB is accepted and backed up without normalization")
    }
}
