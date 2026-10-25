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
    static let legacyAdapterSource = """
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

    /// The adapter Bam writes now: idle callbacks (absent in WebKit's isolated worlds), the
    /// select-picker state fix, then callback-style messaging.
    static let adapterSource = ExtensionIdleCallbackCompatibility.source + "\n" + ExtensionSelectPickerCompatibility.source + "\n" + legacyAdapterSource
    /// Every earlier adapter Bam wrote, byte for byte. Only these are ever replaced.
    static let previousAdapterSources = [legacyAdapterSource, ExtensionSelectPickerCompatibility.source + "\n" + legacyAdapterSource]

    /// Updates only byte-exact, previously generated Bam adapters. Vendor files,
    /// the manifest, permissions and signed Safari bundles are not rewritten.
    /// Validate all candidates before writing, and exclude any MAIN-world reference.
    @discardableResult
    static func refreshBamAdapters(package: URL) throws -> Int {
        guard package.isFileURL else { throw ExtensionPackagePreparation.failure("Extension preparation requires a local file URL.") }
        let package = package.standardizedFileURL
        let packageValues = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageValues.isDirectory == true, packageValues.isSymbolicLink != true else {
            throw ExtensionPackagePreparation.failure("The extension package must be a regular directory.")
        }
        func readBounded(_ url: URL, limit: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw ExtensionPackagePreparation.failure("The extension adapter input exceeds its size limit.") }
            return data
        }
        let manifestURL = package.appendingPathComponent("manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= ExtensionPackagePreparation.maximumManifestBytes else {
            throw ExtensionPackagePreparation.failure("The extension manifest must be a regular file no larger than 1 MiB.")
        }
        guard let manifest = try JSONSerialization.jsonObject(with: readBounded(manifestURL, limit: ExtensionPackagePreparation.maximumManifestBytes)) as? [String: Any] else {
            throw ExtensionPackagePreparation.failure("The extension manifest must be a JSON object.")
        }
        guard let rawEntries = manifest["content_scripts"] else { return 0 }
        guard let entries = rawEntries as? [[String: Any]] else {
            throw ExtensionPackagePreparation.failure("content_scripts must be an array of objects.")
        }
        var isolated = Set<String>(), main = Set<String>()
        for entry in entries {
            guard let raw = entry["js"] else { continue }
            guard let scripts = raw as? [String] else {
                throw ExtensionPackagePreparation.failure("Content script js lists must be arrays of local paths.")
            }
            if (entry["world"] as? String)?.uppercased() == "MAIN" { main.formUnion(scripts) }
            else { isolated.formUnion(scripts) }
        }
        let mainLocations = Set(main.compactMap { $0.removingPercentEncoding }.map {
            package.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let previous = previousAdapterSources.map { Data($0.utf8) }
        let longest = previous.map(\.count).max() ?? 0
        var replacements: [URL] = []
        for path in isolated.subtracting(main).sorted() {
            let prefix = "__bam_messaging_", suffix = ".js"
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { continue }
            let identifier = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            guard let uuid = UUID(uuidString: identifier), identifier == uuid.uuidString.lowercased() else { continue }
            try ExtensionPackagePreparation.validateScript(path, in: package, kind: "Bam adapter")
            let url = package.appendingPathComponent(path)
            guard !mainLocations.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) else { continue }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, previous.contains(where: { $0.count == size }) else { continue }
            if previous.contains(try readBounded(url, limit: longest)) { replacements.append(url) }
        }
        for url in replacements { try Data(adapterSource.utf8).write(to: url, options: .atomic) }
        return replacements.count
    }

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
        return "Added a messaging adapter before \(adapted.count) content script list\(adapted.count == 1 ? "" : "s") so callback-style runtime.sendMessage is answered and missing WebKit select-picker styles use the native open state. Extension scripts are unchanged."
    }
}
