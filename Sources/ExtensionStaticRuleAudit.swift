import Foundation

/// Read-only audit of an installed package's declared static declarativeNetRequest rulesets for rule shapes this
/// WebKit may not enforce as written. It never changes vendor files, the enabled set or any rule; it only produces
/// counts per ruleset ID (no rule text or URLs) for disclosure. Computed once per extension version and audit format.
struct ExtensionStaticRuleAudit: Codable, Equatable {
    /// Bump when what is counted or how the note reads changes, so existing installs are re-audited once.
    static let currentFormat = 1
    /// Resource types WebKit's declarativeNetRequest knows; excluding all of them leaves an empty list in WebKit.
    static let webkitResourceTypes: Set<String> = ["font", "image", "main_frame", "media", "other", "ping", "script", "stylesheet",
                                                    "sub_frame", "websocket", "xmlhttprequest"]
    static let maximumRulesets = 100
    static let maximumRulesetBytes = 32 * 1_048_576
    static let maximumTotalBytes = 128 * 1_048_576

    struct Ruleset: Codable, Equatable {
        let id: String
        /// The manifest's `enabled` flag: the default only. The extension can change its enabled rulesets at run time.
        let enabledByDefault: Bool
        /// Rules with requestMethods or excludedRequestMethods.
        let methodRules: Int
        /// Rules whose excludedResourceTypes covers every type WebKit knows.
        let excludesAllTypesRules: Int
    }

    var format: Int
    /// The installed extension version this audit describes.
    var extensionVersion: String
    /// Only rulesets with findings, in manifest order.
    var rulesets: [Ruleset]
    /// Declared rulesets that could not be audited (missing, unsafe path, oversized or not a JSON rule array).
    var unreadable: [String]

    func isCurrent(for version: String) -> Bool { format == Self.currentFormat && extensionVersion == version }

    /// User-facing disclosure, or nil when nothing needs saying.
    var note: String? {
        let method = rulesets.reduce(0) { $0 + $1.methodRules }, excluded = rulesets.reduce(0) { $0 + $1.excludesAllTypesRules }
        var parts: [String] = []
        if method > 0 || excluded > 0 {
            var shapes: [String] = []
            if method > 0 { shapes.append("\(method) use request-method conditions") }
            if excluded > 0 { shapes.append("\(excluded) exclude every resource type this browser supports") }
            let names = rulesets.prefix(8).map { "\($0.id) (\($0.enabledByDefault ? "on" : "off") by default)" }
            let more = rulesets.count > 8 ? " and \(rulesets.count - 8) more" : ""
            parts.append("Static network rules: of the rules in this extension's declared rulesets, \(shapes.joined(separator: " and ")); "
                + "this version of WebKit may not enforce these as written. Bam leaves them unchanged. "
                + "Rulesets: \(names.joined(separator: ", "))\(more). The extension can turn rulesets on or off, so the rules in use may differ.")
        }
        if !unreadable.isEmpty {
            let names = unreadable.prefix(8).joined(separator: ", "), more = unreadable.count > 8 ? " and \(unreadable.count - 8) more" : ""
            parts.append("Bam could not check static ruleset\(unreadable.count == 1 ? "" : "s") \(names)\(more).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Reads the package's own manifest (bounded) and audits it; safe to run off the main actor.
    static func audit(package: URL, version: String) -> ExtensionStaticRuleAudit {
        let empty = ExtensionStaticRuleAudit(format: currentFormat, extensionVersion: version, rulesets: [], unreadable: [])
        guard let url = file("manifest.json", in: package), let data = read(url, limit: 1_048_576),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return empty }
        return audit(package: package, manifest: manifest, version: version)
    }

    /// `totalLimit` bounds the bytes read across all rulesets, including files that then fail to parse.
    static func audit(package: URL, manifest: [String: Any], version: String, totalLimit: Int = maximumTotalBytes) -> ExtensionStaticRuleAudit {
        var result = ExtensionStaticRuleAudit(format: currentFormat, extensionVersion: version, rulesets: [], unreadable: [])
        let resources = (manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [Any] ?? []
        var total = 0
        for (offset, entry) in resources.enumerated() {
            let declared = entry as? [String: Any] ?? [:]
            let id = (declared["id"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? "#\(offset + 1)"
            guard offset < maximumRulesets else { result.unreadable.append(id); continue }
            guard let path = declared["path"] as? String, let file = file(path, in: package),
                  let data = read(file, limit: min(maximumRulesetBytes, totalLimit - total)) else { result.unreadable.append(id); continue }
            // Charged before parsing, so malformed files spend the aggregate budget too.
            total += data.count
            guard let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else { result.unreadable.append(id); continue }
            var method = 0, excluded = 0
            for case let rule as [String: Any] in rules {
                guard let condition = rule["condition"] as? [String: Any] else { continue }
                if (condition["requestMethods"] as? [Any])?.isEmpty == false || (condition["excludedRequestMethods"] as? [Any])?.isEmpty == false { method += 1 }
                if let types = condition["excludedResourceTypes"] as? [Any], webkitResourceTypes.isSubset(of: Set(types.compactMap { $0 as? String })) { excluded += 1 }
            }
            if method > 0 || excluded > 0 {
                result.rulesets.append(Ruleset(id: id, enabledByDefault: declared["enabled"] as? Bool == true, methodRules: method, excludesAllTypesRules: excluded))
            }
        }
        return result
    }

    /// A package-relative file: no scheme, traversal, backslash or empty segment; inside the package after
    /// resolving links; a regular file that is not itself a symbolic link.
    static func file(_ raw: String, in package: URL) -> URL? {
        let path = raw.hasPrefix("/") && !raw.hasPrefix("//") ? String(raw.dropFirst()) : raw
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains(":"),
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let root = package.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = package.appendingPathComponent(path)
        guard candidate.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return candidate
    }

    private static func read(_ url: URL, limit: Int) -> Data? {
        guard limit > 0, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}
