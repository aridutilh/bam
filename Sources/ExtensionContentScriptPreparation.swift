import Foundation

/// Prepends a small messaging adapter to each isolated-world content script list
/// in the app's private package copy. WebKit never invokes the callback of
/// `runtime.sendMessage(extensionId, message, callback)` from a content script
/// while the promise form answers; vidIQ, Dashlane and 1Password all use the
/// callback form. The adapter converts callback calls to the promise form and
/// keeps the runtime wrapper referenced so the patch survives WebKit's weak
/// wrapper cache. Extension JavaScript is never changed; the original manifest is
/// preserved next to the package when no earlier step saved it.
enum ExtensionContentScriptPreparation {
    static let adapterSource = """
    // Bam compatibility: callback-style runtime.sendMessage from content scripts.
    (() => {
      const held = [];
      const adapt = (runtime) => {
        if (!runtime || typeof runtime.sendMessage !== "function" || runtime.__bamMessaging) return;
        const native = runtime.sendMessage.bind(runtime);
        held.push(runtime, native);
        const sendMessage = function (...args) {
          if (typeof args[args.length - 1] !== "function") return native(...args);
          const callback = args.pop();
          let result;
          try { result = native(...args); } catch (error) { callback(); return; }
          if (result && typeof result.then === "function") { result.then((value) => callback(value), () => callback()); return; }
          callback(result);
        };
        try { Object.defineProperty(runtime, "sendMessage", { value: sendMessage, writable: true, configurable: true }); } catch (error) { runtime.sendMessage = sendMessage; }
        try { Object.defineProperty(runtime, "__bamMessaging", { value: true, configurable: true }); } catch (error) {}
      };
      const chromeRuntime = globalThis.chrome && globalThis.chrome.runtime;
      const browserRuntime = globalThis.browser && globalThis.browser.runtime;
      adapt(chromeRuntime);
      if (browserRuntime && browserRuntime !== chromeRuntime) adapt(browserRuntime);
      try { Object.defineProperty(globalThis, "__bamMessagingHeld", { value: held, configurable: true }); } catch (error) {}
    })();
    """

    /// Returns a disclosure note when the manifest was adapted, nil when there was
    /// nothing to adapt. Validation finishes before any file changes.
    @discardableResult
    static func prepare(package: URL, originalManifestURL: URL) throws -> String? {
        let fm = FileManager.default
        guard package.isFileURL, originalManifestURL.isFileURL else { throw ExtensionPackagePreparation.failure("Extension preparation requires local file URLs.") }
        let package = package.standardizedFileURL
        let manifestURL = package.appendingPathComponent("manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= ExtensionPackagePreparation.maximumManifestBytes else {
            throw ExtensionPackagePreparation.failure("The extension manifest must be a regular file no larger than 1 MiB.")
        }
        let current = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: current) as? [String: Any] else { throw ExtensionPackagePreparation.failure("The extension manifest must be a JSON object.") }
        guard let rawEntries = manifest["content_scripts"] else { return nil }
        guard let entries = rawEntries as? [Any] else { throw ExtensionPackagePreparation.failure("content_scripts must be an array.") }
        var adapted: [Int] = []
        var rewritten: [Any] = []
        for (index, rawEntry) in entries.enumerated() {
            guard let entry = rawEntry as? [String: Any] else { throw ExtensionPackagePreparation.failure("Each content_scripts entry must be an object.") }
            rewritten.append(entry)
            guard let rawScripts = entry["js"] else { continue }
            guard let scripts = rawScripts as? [String] else { throw ExtensionPackagePreparation.failure("Content script js lists must be arrays of local paths.") }
            if scripts.isEmpty || (entry["world"] as? String)?.uppercased() == "MAIN" { continue }
            for script in scripts { try ExtensionPackagePreparation.validateScript(script, in: package, kind: "content") }
            adapted.append(index)
        }
        guard !adapted.isEmpty else { return nil }

        var adapterName: String
        var adapterURL: URL
        repeat {
            adapterName = "__bam_messaging_" + UUID().uuidString.lowercased() + ".js"
            adapterURL = package.appendingPathComponent(adapterName)
        } while fm.fileExists(atPath: adapterURL.path)
        for index in adapted {
            var entry = rewritten[index] as! [String: Any]
            entry["js"] = [adapterName] + (entry["js"] as! [String])
            rewritten[index] = entry
        }
        manifest["content_scripts"] = rewritten
        let replacement = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        // An earlier preparation step may already hold the byte-exact original;
        // otherwise this manifest is the original and is saved outside the package.
        let backup = originalManifestURL.standardizedFileURL
        if !fm.fileExists(atPath: backup.path) {
            let canonicalPackage = package.resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalBackup = backup.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(backup.lastPathComponent).path
            guard canonicalBackup != canonicalPackage, !canonicalBackup.hasPrefix(canonicalPackage + "/") else {
                throw ExtensionPackagePreparation.failure("The original manifest backup must be a new file outside the package.")
            }
            try current.write(to: backup, options: .atomic)
        }
        do {
            try Data(adapterSource.utf8).write(to: adapterURL, options: .atomic)
            try replacement.write(to: manifestURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: adapterURL)
            throw error
        }
        return "Added a messaging adapter before \(adapted.count) content script list\(adapted.count == 1 ? "" : "s") so callback-style runtime.sendMessage is answered. Extension scripts are unchanged."
    }
}
