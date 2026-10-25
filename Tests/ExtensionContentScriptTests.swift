import Foundation
import JavaScriptCore

@main struct ExtensionContentScriptTests {
    static var checks = 0
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
        checks += 1
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw CheckFailure(description: "Usage: extension-messaging-tests <scoped temporary directory>") }
            try run(in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("Extension content-script preparation: \(checks) checks passed")
        } catch {
            fputs("FAIL: Extension content-script preparation: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(in parent: URL) throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("extension-messaging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func manifest(_ contentScripts: Any?, version: Int = 3, background: [String: Any]? = nil) throws -> Data {
            var object: [String: Any] = ["manifest_version": version, "name": "Messaging fixture", "version": "1.0", "permissions": ["storage"]]
            if let contentScripts { object["content_scripts"] = contentScripts }
            if let background { object["background"] = background }
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
        func package(_ name: String, _ bytes: Data, scripts: [String] = ["content.js", "lib/helper.js", "main.js"]) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try bytes.write(to: url.appendingPathComponent("manifest.json"))
            for script in scripts { try Data("globalThis['\(script)'] = 'naïve ☕';\n".utf8).write(to: url.appendingPathComponent(script)) }
            return url
        }
        func object(_ url: URL) throws -> [String: Any] {
            guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw CheckFailure(description: "Expected a JSON object") }
            return result
        }
        func entries(_ url: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: url.path).sorted() }
        func scriptLists(_ url: URL) throws -> [[String]] {
            (try object(url.appendingPathComponent("manifest.json"))["content_scripts"] as? [[String: Any]] ?? []).map { $0["js"] as? [String] ?? [] }
        }

        // A typical MV3 package: one MAIN-world entry (left alone), two isolated entries, one css-only entry.
        let typical = try manifest([
            ["matches": ["https://www.youtube.com/*"], "js": ["main.js"], "run_at": "document_start", "world": "MAIN"],
            ["matches": ["https://www.youtube.com/*"], "js": ["lib/helper.js", "content.js"], "run_at": "document_idle"],
            ["matches": ["https://example.com/*"], "css": ["style.css"]],
            ["matches": ["https://example.org/*"], "js": ["content.js"], "world": "ISOLATED"],
        ])
        let typicalURL = try package("typical", typical)
        let before = try entries(typicalURL)
        let scriptBytes = try Data(contentsOf: typicalURL.appendingPathComponent("content.js"))
        let backup = root.appendingPathComponent("typical-original.json")
        let note = try ExtensionContentScriptPreparation.prepare(package: typicalURL, originalManifestURL: backup)
        try check(note?.contains("2 content script lists") == true, "Disclosure names the adapted lists: \(note ?? "nil")")
        let lists = try scriptLists(typicalURL)
        try check(lists.count == 4 && lists[0] == ["main.js"] && lists[2].isEmpty, "MAIN-world and css-only entries are untouched: \(lists)")
        try check(lists[1].count == 3 && lists[1][0].hasPrefix("__bam_messaging_") && Array(lists[1].dropFirst()) == ["lib/helper.js", "content.js"], "Adapter is prepended, order kept: \(lists[1])")
        try check(lists[3].count == 2 && lists[3][0] == lists[1][0], "One adapter file serves every adapted list: \(lists[3])")
        let adapterName = lists[1][0]
        let after = try entries(typicalURL)
        try check(after == (before + [adapterName]).sorted(), "Exactly one file was added at the package root: \(after)")
        try check(try Data(contentsOf: typicalURL.appendingPathComponent("content.js")) == scriptBytes, "Extension scripts are byte-identical")
        try check(try Data(contentsOf: backup) == typical, "The original manifest is saved byte-for-byte outside the package")
        let adapterText = try String(contentsOf: typicalURL.appendingPathComponent(adapterName), encoding: .utf8)
        try check(adapterText == ExtensionContentScriptPreparation.adapterSource, "The adapter file carries the known source")
        let manifestObject = try object(typicalURL.appendingPathComponent("manifest.json"))
        try check((manifestObject["content_scripts"] as? [[String: Any]])?[1]["run_at"] as? String == "document_idle" && manifestObject["permissions"] as? [String] == ["storage"], "Other manifest keys survive the rewrite")

        // Existing installs update only exact Bam-owned legacy bytes, once per file.
        let adapterURL = typicalURL.appendingPathComponent(adapterName)
        let preparedManifest = try Data(contentsOf: typicalURL.appendingPathComponent("manifest.json"))
        let legacy = Data(ExtensionContentScriptPreparation.legacyAdapterSource.utf8)
        try legacy.write(to: adapterURL)
        try check(try ExtensionContentScriptPreparation.refreshBamAdapters(package: typicalURL) == 1, "A shared legacy adapter is migrated once")
        try check(try Data(contentsOf: adapterURL) == Data(ExtensionContentScriptPreparation.adapterSource.utf8), "Migration installs the known current adapter")
        try check(try ExtensionContentScriptPreparation.refreshBamAdapters(package: typicalURL) == 0, "Current adapters are not rewritten")
        try check(try Data(contentsOf: typicalURL.appendingPathComponent("manifest.json")) == preparedManifest && Data(contentsOf: backup) == typical && Data(contentsOf: typicalURL.appendingPathComponent("content.js")) == scriptBytes, "Migration preserves manifest, original backup and vendor source")
        let modifiedAdapter = Data((ExtensionContentScriptPreparation.legacyAdapterSource + "/* user edit */").utf8)
        try modifiedAdapter.write(to: adapterURL)
        try check(try ExtensionContentScriptPreparation.refreshBamAdapters(package: typicalURL) == 0 && Data(contentsOf: adapterURL) == modifiedAdapter, "Unrecognized generated-looking files are left intact")
        try legacy.write(to: adapterURL)
        var sharedMain = manifestObject
        var sharedEntries = sharedMain["content_scripts"] as! [[String: Any]]
        sharedEntries[0]["js"] = ["./" + adapterName]
        sharedMain["content_scripts"] = sharedEntries
        try JSONSerialization.data(withJSONObject: sharedMain).write(to: typicalURL.appendingPathComponent("manifest.json"))
        try check(try ExtensionContentScriptPreparation.refreshBamAdapters(package: typicalURL) == 0 && Data(contentsOf: adapterURL) == legacy, "A MAIN-world alias prevents migration of the shared adapter")
        try preparedManifest.write(to: typicalURL.appendingPathComponent("manifest.json"))
        try fm.removeItem(at: adapterURL)
        try fm.createSymbolicLink(at: adapterURL, withDestinationURL: typicalURL.appendingPathComponent("content.js"))
        var unsafeRejected = false
        do { _ = try ExtensionContentScriptPreparation.refreshBamAdapters(package: typicalURL) } catch { unsafeRejected = true }
        try check(unsafeRejected && Data(contentsOf: typicalURL.appendingPathComponent("content.js")) == scriptBytes, "A generated-name symlink is refused without touching its target")
        try fm.removeItem(at: adapterURL)
        try Data(ExtensionContentScriptPreparation.adapterSource.utf8).write(to: adapterURL)

        let linkedPackage = root.appendingPathComponent("linked-package")
        try fm.createSymbolicLink(at: linkedPackage, withDestinationURL: typicalURL)
        var rootLinkRejected = false
        do { _ = try ExtensionContentScriptPreparation.refreshBamAdapters(package: linkedPackage) } catch { rootLinkRejected = true }
        try check(rootLinkRejected, "A symlink package root is refused before migration")

        // Running again after an earlier step saved the original must not overwrite that backup.
        let repeated = try ExtensionContentScriptPreparation.prepare(package: typicalURL, originalManifestURL: backup)
        try check(repeated != nil && Data(contentsOf: backup) == typical, "An existing original-manifest backup is preserved")

        // Nothing to adapt: no content scripts, empty lists, or MAIN world only.
        let untouched: [(String, Any?)] = [("none", nil), ("empty", []), ("main-only", [["matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN"]]), ("css-only", [["matches": ["<all_urls>"], "css": ["a.css"]]])]
        for (name, value) in untouched {
            let bytes = try manifest(value)
            let url = try package("nothing-" + name, bytes)
            let unchangedBackup = root.appendingPathComponent("nothing-\(name).json")
            let result = try ExtensionContentScriptPreparation.prepare(package: url, originalManifestURL: unchangedBackup)
            try check(result == nil && Data(contentsOf: url.appendingPathComponent("manifest.json")) == bytes && !fm.fileExists(atPath: unchangedBackup.path) && entries(url) == entries(url).filter { !$0.hasPrefix("__bam") },
                      "Packages without adaptable content scripts are left alone (\(name))")
        }

        // Validation failures leave the package untouched: unsafe paths, missing files, symlinks, malformed shapes, inside backups.
        func reject(_ name: String, _ contentScripts: Any, setup: ((URL) throws -> Void)? = nil, backup: ((URL) -> URL)? = nil) throws {
            let bytes = try manifest(contentScripts)
            let url = try package("reject-" + name, bytes)
            try setup?(url)
            let listing = try entries(url)
            var rejected = false
            do { _ = try ExtensionContentScriptPreparation.prepare(package: url, originalManifestURL: backup?(url) ?? root.appendingPathComponent("reject-\(name).json")) } catch { rejected = true }
            try check(rejected, "Rejected: \(name)")
            try check(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == bytes && entries(url) == listing && !fm.fileExists(atPath: root.appendingPathComponent("reject-\(name).json").path),
                      "Rejection leaves manifest, entries and backup untouched: \(name)")
        }
        try reject("traversal", [["matches": ["<all_urls>"], "js": ["../content.js"]]])
        try reject("absolute", [["matches": ["<all_urls>"], "js": ["/etc/hosts"]]])
        try reject("url", [["matches": ["<all_urls>"], "js": ["https://example.com/x.js"]]])
        try reject("missing", [["matches": ["<all_urls>"], "js": ["absent.js"]]])
        try reject("directory", [["matches": ["<all_urls>"], "js": ["lib"]]])
        try reject("symlink", [["matches": ["<all_urls>"], "js": ["link.js"]]]) { url in
            try fm.createSymbolicLink(at: url.appendingPathComponent("link.js"), withDestinationURL: url.appendingPathComponent("content.js"))
        }
        try reject("not-array", ["js": ["content.js"]])
        try reject("entry-not-object", ["content.js"])
        try reject("js-not-strings", [["matches": ["<all_urls>"], "js": [1, 2]]])
        try reject("second-entry-bad", [["matches": ["<all_urls>"], "js": ["content.js"]], ["matches": ["<all_urls>"], "js": ["../x.js"]]])
        try reject("inside-backup", [["matches": ["<all_urls>"], "js": ["content.js"]]], backup: { $0.appendingPathComponent("original-manifest.json") })

        // Combined with the MV2 background preparation, the saved original stays the true original.
        let mv2 = try manifest([["matches": ["<all_urls>"], "js": ["content.js"]]], version: 2, background: ["scripts": ["main.js"], "persistent": false])
        let mv2URL = try package("mv2", mv2)
        let mv2Backup = root.appendingPathComponent("mv2-original.json")
        let backgroundNote = try ExtensionPackagePreparation.prepare(package: mv2URL, originalManifestURL: mv2Backup)
        let messagingNote = try ExtensionContentScriptPreparation.prepare(package: mv2URL, originalManifestURL: mv2Backup)
        let combined = try object(mv2URL.appendingPathComponent("manifest.json"))
        try check(backgroundNote != nil && messagingNote != nil && Data(contentsOf: mv2Backup) == mv2, "Both preparations run and the original backup is the pre-preparation manifest")
        try check((combined["background"] as? [String: Any])?["page"] is String && (try scriptLists(mv2URL))[0].count == 2, "Background page and content adapter coexist in the prepared manifest")

        // The adapter itself: callback forms are answered through the promise form, promise forms pass through,
        // the native wrapper is held, and failures still call back.
        guard let context = JSContext() else { throw CheckFailure(description: "JavaScriptCore unavailable") }
        context.exceptionHandler = { _, exception in fputs("JS exception: \(exception?.toString() ?? "?")\n", stderr) }
        context.evaluateScript("""
        var calls = [];
        var runtime = { id: "ext", sendMessage: function (...args) { calls.push(args); if (args[1] && args[1].fail) return Promise.reject(new Error("no")); if (args[0] && args[0].sync) return "sync"; return Promise.resolve({ echoed: args }); } };
        globalThis.chrome = { runtime: runtime }; globalThis.browser = { runtime: runtime };
        var out = {};
        """)
        context.evaluateScript(ExtensionContentScriptPreparation.adapterSource)
        context.evaluateScript("""
        chrome.runtime.sendMessage("ext", { hello: 1 }, (r) => { out.threeArg = r; });
        chrome.runtime.sendMessage({ hello: 2 }, (r) => { out.twoArg = r; });
        chrome.runtime.sendMessage("ext", { fail: true }, (r) => { out.failed = r === undefined; });
        chrome.runtime.sendMessage({ sync: true }, (r) => { out.sync = r; });
        out.promise = chrome.runtime.sendMessage({ promise: true });
        out.heldCount = (globalThis.__bamMessagingHeld || []).length;
        out.sameFunction = chrome.runtime.sendMessage === browser.runtime.sendMessage;
        out.callbackReachedNative = calls.filter(a => a.some(x => typeof x === "function")).length;
        """)
        // JavaScriptCore drains microtasks when evaluation returns; one more evaluation observes them.
        let results = context.evaluateScript("JSON.stringify({ three: out.threeArg && out.threeArg.echoed.length, threeID: out.threeArg && out.threeArg.echoed[0], two: out.twoArg && out.twoArg.echoed.length, failed: out.failed, sync: out.sync, promise: typeof (out.promise && out.promise.then), held: out.heldCount, same: out.sameFunction, nativeSawCallback: out.callbackReachedNative })")
        let decoded = try JSONSerialization.jsonObject(with: Data((results?.toString() ?? "{}").utf8)) as? [String: Any] ?? [:]
        try check(decoded["three"] as? Int == 2 && decoded["threeID"] as? String == "ext", "Three-argument callback form is answered with the extension ID kept: \(decoded)")
        try check(decoded["two"] as? Int == 1, "Two-argument callback form is answered: \(decoded)")
        try check(decoded["failed"] as? Bool == true && decoded["sync"] as? String == "sync", "Rejections and synchronous results still reach the callback: \(decoded)")
        try check(decoded["promise"] as? String == "function" && decoded["nativeSawCallback"] as? Int == 0, "Promise form passes through and the native API never sees a callback: \(decoded)")
        try check(decoded["held"] as? Int == 2 && decoded["same"] as? Bool == true, "The runtime wrapper is held and adapted once: \(decoded)")
    }
}
