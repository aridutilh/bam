import Foundation
import WebKit

/// Parses real manifests with WebKit (no windows or extension processes) and checks which problems block an install.
@main @MainActor enum ExtensionManifestWarningTestsMain {
    static func main() async {
        guard #available(macOS 15.4, *) else { print("extension manifest warning tests skipped (macOS 15.4+)"); return }
        await ExtensionManifestWarningTests.main()
    }
}

@available(macOS 15.4, *) @MainActor enum ExtensionManifestWarningTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!); exit(1) }
    }
    static func parse(_ manifest: [String: Any], files: [String: String] = [:]) async throws -> WKWebExtension {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bam-manifest-warning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for (name, body) in files { try body.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return try await WKWebExtension(resourceBaseURL: folder)
    }
    static func failure(_ text: String) -> Error { NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    static func main() async {
        do {
            let base: [String: Any] = ["manifest_version": 3, "name": "Fixture", "version": "1.0", "description": "Fixture",
                                       "background": ["service_worker": "bg.js"], "action": ["default_title": "Fixture"]]
            // Raindrop.io 7.x ships `"_execute_action": {}`: Chrome accepts it; WebKit reports an invalid entry.
            var raindrop = base
            raindrop["commands"] = ["_execute_action": [String: Any](), "save_page": ["suggested_key": ["default": "Ctrl+Shift+S"], "description": "Save"]]
            let warned = try await parse(raindrop, files: ["bg.js": ""])
            expect(!warned.errors.isEmpty, "WebKit still reports the empty command (if this fails, WebKit fixed it and the fixture needs a new warning)")
            expect(ExtensionManifestWarnings.blocking(warned.errors).isEmpty, "an empty command entry must not block the install")
            let note = try ExtensionManifestWarnings.check(warned.errors, failure: failure)
            expect(note?.hasPrefix("WebKit ignored part of the manifest") == true, "ignored warnings are disclosed")

            // A clean manifest: no errors, no note.
            let clean = try await parse(base, files: ["bg.js": ""])
            expect(try ExtensionManifestWarnings.check(clean.errors, failure: failure) == nil, "a clean manifest has no note")

            // Blocking: a missing background resource or unsupported manifest version is never downgraded.
            let missing = try await parse(base)
            if !missing.errors.isEmpty {
                expect(!ExtensionManifestWarnings.blocking(missing.errors).isEmpty || missing.errors.allSatisfy(ExtensionManifestWarnings.isWarning),
                       "missing resources are classified")
            }
            for code in [WKWebExtension.Error.unknown, .resourceNotFound, .invalidResourceCodeSignature, .invalidManifest, .unsupportedManifestVersion, .invalidArchive] {
                let error = NSError(domain: WKWebExtension.errorDomain, code: code.rawValue)
                expect(!ExtensionManifestWarnings.isWarning(error), "code \(code.rawValue) blocks")
                var threw = false
                do { _ = try ExtensionManifestWarnings.check([error], failure: failure) } catch { threw = true }
                expect(threw, "code \(code.rawValue) throws")
            }
            for code in [WKWebExtension.Error.invalidManifestEntry, .invalidDeclarativeNetRequestEntry, .invalidBackgroundPersistence] {
                expect(ExtensionManifestWarnings.isWarning(NSError(domain: WKWebExtension.errorDomain, code: code.rawValue)), "code \(code.rawValue) warns")
            }
            // Same code from another domain is not a WebKit warning.
            expect(!ExtensionManifestWarnings.isWarning(NSError(domain: "Other", code: WKWebExtension.Error.invalidManifestEntry.rawValue)), "foreign domain blocks")
            // A mix: one blocking error wins.
            var threw = false
            do { _ = try ExtensionManifestWarnings.check([NSError(domain: WKWebExtension.errorDomain, code: WKWebExtension.Error.invalidManifestEntry.rawValue),
                                                          NSError(domain: WKWebExtension.errorDomain, code: WKWebExtension.Error.invalidManifest.rawValue)], failure: failure) } catch { threw = true }
            expect(threw, "a blocking error in a mix still throws")
            expect(ExtensionManifestWarnings.joinedNote(nil, "", "a", nil, "b") == "a\nb", "notes join")
            expect(ExtensionManifestWarnings.joinedNote(nil, nil) == nil, "empty notes are nil")
            print("extension manifest warning tests passed (\(checks) checks)")
        } catch { FileHandle.standardError.write("FAIL: \(error)\n".data(using: .utf8)!); exit(1) }
    }
}
