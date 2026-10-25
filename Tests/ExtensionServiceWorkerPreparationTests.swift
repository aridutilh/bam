import Foundation
import JavaScriptCore

@main struct ExtensionServiceWorkerPreparationTests {
    static var checks = 0
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }; checks += 1
    }
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure(description: "Usage: worker-preparation-tests <scoped temporary directory>") }
            try run(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("Extension service-worker preparation: \(checks) checks passed")
        } catch { fputs("FAIL: Extension service-worker preparation: \(error)\n", stderr); exit(1) }
    }
    static func run(_ parent: URL) throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("worker-preparation-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let adapter = "globalThis.order = ['adapter']; globalThis.compatibilityReady = true;\n"
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func manifest(worker: Any = "lib/worker.js", type: Any? = nil, permissions: Any = ["storage"], version: Int = 3) throws -> Data {
            var background: [String: Any] = ["service_worker": worker, "custom": ["keep": true]]
            if let type { background["type"] = type }
            return try json(["manifest_version": version, "name": "Worker fixture", "version": "1.0", "background": background,
                             "permissions": permissions, "optional_permissions": ["notifications"], "host_permissions": ["https://example.com/*"],
                             "content_security_policy": ["extension_pages": "script-src 'self'; object-src 'self'"]])
        }
        func package(_ name: String, _ bytes: Data, scripts: [String: String] = [:]) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try bytes.write(to: url.appendingPathComponent("manifest.json"))
            var files = ["lib/worker.js": "if (!globalThis.compatibilityReady) throw Error('shim missing'); order.push('original'); globalThis.workerPath = location.pathname; importScripts('helper.js');\n",
                         "lib/helper.js": "order.push('helper'); globalThis.nonASCII = 'naïve ☕';\n"]
            files.merge(scripts) { _, new in new }
            for (path, source) in files { try Data(source.utf8).write(to: url.appendingPathComponent(path)) }
            return url
        }
        func object(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
        func prepare(_ url: URL, backup: URL? = nil, source: String? = nil) throws -> String? {
            try ExtensionServiceWorkerPreparation.prepare(package: url, originalManifestURL: backup ?? root.appendingPathComponent(url.lastPathComponent + "-original.json"), adapterSource: source ?? adapter)
        }
        func snapshot(_ url: URL) throws -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isRegularFile == true { result[String(file.path.dropFirst(url.path.count + 1))] = try Data(contentsOf: file) }
            }
            return result
        }

        let classicOriginal = try manifest()
        let classic = try package("classic", classicOriginal)
        let originals = try snapshot(classic)
        let backup = root.appendingPathComponent("classic-original.json")
        let note = try prepare(classic)
        let result = try object(classic.appendingPathComponent("manifest.json"))
        let background = result["background"] as! [String: Any], marker = result[ExtensionServiceWorkerPreparation.markerKey] as! [String: Any]
        let entry = background["service_worker"] as! String, shim = marker["adapter"] as! String
        try check(note?.contains("external native apps remain unavailable") == true && note?.contains("keeps its original entry URL") == true, "Disclosure states transport and worker URL limits")
        try check(ExtensionServiceWorkerPreparation.isPrepared(manifest: result), "Prepared marker describes the selected worker")
        try check(entry == "lib/worker.js" && shim.hasPrefix("lib/"), "Classic registration URL is preserved and its adapter is a sibling")
        try check(background["page"] == nil && background["scripts"] == nil && background["type"] == nil, "Classic background remains a classic service worker")
        try check((background["custom"] as? [String: Bool])?["keep"] == true, "Unrelated background settings survive")
        try check(result["permissions"] as? [String] == ["storage", "nativeMessaging"], "Internal transport is requested explicitly")
        try check(result["optional_permissions"] as? [String] == ["notifications"] && result["host_permissions"] as? [String] == ["https://example.com/*"], "Optional and site permissions remain unchanged")
        try check((result["content_security_policy"] as? [String: String])?["extension_pages"] == "script-src 'self'; object-src 'self'", "Preparation does not weaken CSP")
        try check(try Data(contentsOf: backup) == classicOriginal, "Backup preserves original manifest bytes")
        let savedSource = marker["source"] as! String
        try check(try savedSource.hasPrefix("lib/__bam_worker_original_") && Data(contentsOf: classic.appendingPathComponent(savedSource)) == originals["lib/worker.js"], "Relocated classic source remains byte-exact beside its original entry")
        for (path, bytes) in originals where path != "manifest.json" && path != "lib/worker.js" { try check(try Data(contentsOf: classic.appendingPathComponent(path)) == bytes, "Other scripts remain byte-exact: \(path)") }
        let first = try snapshot(classic), metadata = backup.appendingPathExtension("worker-preparation.json")
        let metadataBytes = try Data(contentsOf: metadata)
        try check(try prepare(classic) == nil && snapshot(classic) == first && Data(contentsOf: metadata) == metadataBytes, "Verified repeat is a byte-exact no-op")

        // Execute the generated classic entry with the real package's nested
        // importScripts calls. Relative loads must still target the original dir.
        let context = JSContext()!
        context.setObject(["pathname": "/" + entry], forKeyedSubscript: "location" as NSString)
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "JavaScript failed" }
        let entryURL = classic.appendingPathComponent(entry)
        let load: @convention(block) (String) -> Void = { relative in
            do {
                let url = URL(string: relative, relativeTo: entryURL)!.absoluteURL
                let text = try String(contentsOf: url, encoding: .utf8)
                context.evaluateScript(text, withSourceURL: url)
            } catch { failure = error.localizedDescription }
        }
        context.setObject(load, forKeyedSubscript: "loadFixtureScript" as NSString)
        context.evaluateScript("globalThis.importScripts = (...paths) => { for (const path of paths) loadFixtureScript(path); };")
        context.evaluateScript(try String(contentsOf: entryURL, encoding: .utf8), withSourceURL: entryURL)
        try check(failure == nil, "Prepared classic worker executes: \(failure ?? "")")
        try check(context.evaluateScript("JSON.stringify(order)")?.toString() == "[\"adapter\",\"original\",\"helper\"]", "Shim runs before original entry and nested relative imports")
        try check(context.evaluateScript("nonASCII")?.toString() == "naïve ☕", "Original script encoding survives wrapper loading")
        try check(context.evaluateScript("workerPath")?.toString() == "/lib/worker.js", "Original code observes its original worker pathname")

        let moduleOriginal = try manifest(worker: "lib/entry%20%E2%98%95.js", type: "module", permissions: ["nativeMessaging", "storage"])
        let module = try package("module", moduleOriginal, scripts: ["lib/entry ☕.js": "import './dependency.js'; export const originalURL = import.meta.url;\n", "lib/dependency.js": "globalThis.dependency = globalThis.compatibilityReady;\n"])
        _ = try prepare(module)
        let moduleManifest = try object(module.appendingPathComponent("manifest.json")), moduleBG = moduleManifest["background"] as! [String: Any]
        let moduleEntry = moduleBG["service_worker"] as! String
        let moduleText = try String(contentsOf: module.appendingPathComponent(moduleEntry), encoding: .utf8)
        let imports = moduleText.split(separator: "\n").filter { $0.hasPrefix("import ") }
        try check(moduleBG["type"] as? String == "module" && imports.count == 2, "Module type and synchronous static import entry are preserved")
        try check(imports[0].contains("__bam_worker_adapter_") && imports[1].contains("entry%20%E2%98%95.js"), "Module shim dependency precedes original encoded path")
        try check(!moduleText.contains("import(") && !moduleText.contains("importScripts") && !moduleText.contains("await"), "Module wrapper does not introduce unsupported dynamic imports or delayed registration")
        try check(moduleManifest["permissions"] as? [String] == ["nativeMessaging", "storage"], "Existing transport permission is not duplicated")
        try check(try Data(contentsOf: module.appendingPathComponent("lib/entry ☕.js")) == Data("import './dependency.js'; export const originalURL = import.meta.url;\n".utf8), "Original module and import.meta.url source are unchanged")

        let encodedBytes = try manifest(worker: "lib/entry%20%E2%98%95.js")
        let encoded = try package("encoded-classic", encodedBytes, scripts: ["lib/entry ☕.js": "globalThis.encodedFixture = true;\n"])
        _ = try prepare(encoded)
        let encodedManifest = try object(encoded.appendingPathComponent("manifest.json"))
        try check((encodedManifest["background"] as? [String: Any])?["service_worker"] as? String == "lib/entry%20%E2%98%95.js", "Classic encoded worker registration path remains exact")
        try check(try prepare(encoded) == nil, "Classic encoded path validates on repeated preparation")
        let moduleSnapshot = try snapshot(module)
        try check(try prepare(module) == nil && snapshot(module) == moduleSnapshot, "Module preparation remains an exact no-op on repeat")

        // An earlier content-script adaptation may have saved the actual original.
        let combined = try package("combined", classicOriginal)
        let combinedBackup = root.appendingPathComponent("combined-original.json")
        try classicOriginal.write(to: combinedBackup)
        var modified = try object(combined.appendingPathComponent("manifest.json")); modified["description"] = "A prior disclosed adaptation"
        try json(modified).write(to: combined.appendingPathComponent("manifest.json"))
        _ = try prepare(combined)
        try check(try Data(contentsOf: combinedBackup) == classicOriginal, "Existing original manifest provenance is preserved")

        for (name, bytes) in [("mv2", try manifest(version: 2)), ("page", try json(["manifest_version": 3, "background": ["page": "background.html"]])), ("none", try json(["manifest_version": 3]))] {
            let url = try package(name, bytes), before = try snapshot(url)
            try check(try prepare(url) == nil && snapshot(url) == before, "Other background types are untouched: \(name)")
            try check(!fm.fileExists(atPath: root.appendingPathComponent(name + "-original.json").path), "No backup created for untouched background: \(name)")
        }
        func reject(_ name: String, bytes: Data? = nil, backupLocation: ((URL) -> URL)? = nil, source: String? = nil, setup: ((URL) throws -> Void)? = nil) throws {
            let url = try package("reject-" + name, bytes ?? classicOriginal)
            try setup?(url)
            let before = try snapshot(url)
            var rejected = false
            do { _ = try prepare(url, backup: backupLocation?(url), source: source) } catch { rejected = true }
            try check(rejected && snapshot(url) == before, "Invalid input is rejected without package mutations: \(name)")
        }
        for (index, path) in ["../outside.js", "/lib/worker.js", "https://example.com/a.js", "lib\\worker.js", "lib//worker.js", "lib/./worker.js", "lib/%2e%2e/a.js", "lib%2fworker.js", "lib/worker.js?x", "lib/worker.js#x", "lib/bad%ZZ.js", ""].enumerated() {
            try reject("path-\(index)", bytes: manifest(worker: path))
        }
        try reject("missing", bytes: manifest(worker: "missing.js"))
        try reject("wrong-worker", bytes: manifest(worker: 42))
        try reject("wrong-permissions", bytes: manifest(permissions: "storage"))
        try reject("wrong-type", bytes: manifest(type: "future"))
        try reject("wrong-background", bytes: json(["manifest_version": 3, "background": "worker"]))
        try reject("empty-adapter", source: "")
        try reject("large-adapter", source: String(repeating: "x", count: ExtensionPackagePreparation.maximumManifestBytes + 1))
        try reject("inside-backup", backupLocation: { $0.appendingPathComponent("original.json") })
        try reject("worker-symlink", setup: { url in
            try fm.removeItem(at: url.appendingPathComponent("lib/worker.js"))
            try fm.createSymbolicLink(at: url.appendingPathComponent("lib/worker.js"), withDestinationURL: url.appendingPathComponent("lib/helper.js"))
        })
        try reject("directory-symlink", bytes: manifest(worker: "alias/worker.js"), setup: { url in
            try fm.createSymbolicLink(at: url.appendingPathComponent("alias"), withDestinationURL: url.appendingPathComponent("lib"))
        })
        try reject("forged-marker", bytes: json(["manifest_version": 3, "background": ["service_worker": "lib/worker.js"], ExtensionServiceWorkerPreparation.markerKey: ["schemaVersion": 1]]))
        try reject("backup-symlink", backupLocation: { url in
            let link = root.appendingPathComponent("symlink-original.json")
            try! fm.createSymbolicLink(at: link, withDestinationURL: url.appendingPathComponent("manifest.json")); return link
        })
        try reject("unrelated-backup", backupLocation: { _ in
            let other = root.appendingPathComponent("unrelated-original.json"); try! Data("{}".utf8).write(to: other); return other
        })
        let sourceTamper = try package("source-tamper", classicOriginal)
        _ = try prepare(sourceTamper)
        let sourceManifest = try object(sourceTamper.appendingPathComponent("manifest.json"))
        let sourcePath = (sourceManifest[ExtensionServiceWorkerPreparation.markerKey] as! [String: Any])["source"] as! String
        try Data("// changed vendor source".utf8).write(to: sourceTamper.appendingPathComponent(sourcePath))
        var rejectedSourceTamper = false
        do { _ = try prepare(sourceTamper) } catch { rejectedSourceTamper = true }
        try check(rejectedSourceTamper, "A modified relocated vendor source fails its recorded SHA256")
        let beforeAltered = try snapshot(classic)
        var rejectedSource = false
        do { _ = try prepare(classic, source: adapter + "// changed\n") } catch { rejectedSource = true }
        try check(rejectedSource && snapshot(classic) == beforeAltered, "A changed adapter cannot silently trust stale preparation metadata")
        try Data("// tampered wrapper\n".utf8).write(to: classic.appendingPathComponent(entry))
        let tampered = try snapshot(classic)
        var rejectedTamper = false
        do { _ = try prepare(classic) } catch { rejectedTamper = true }
        try check(rejectedTamper && snapshot(classic) == tampered, "A modified prepared wrapper is rejected without overwriting evidence")
    }
}
