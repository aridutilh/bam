import Foundation

/// Whether a navigation started by a web page may open an extension's page in the top frame.
///
/// Chrome's rule (which Bam follows): a page can only navigate to an extension resource the extension
/// lists in `web_accessible_resources`. Manifest V2 lists resource patterns open to every site; Manifest V3
/// lists entries of `resources` with the `matches` (site patterns) allowed to reach them. Navigations the
/// extension makes itself (from its own pages) and the ones Bam makes (address field, extension APIs) are
/// not web-initiated and never reach this check.
/// https://developer.chrome.com/docs/extensions/reference/manifest/web-accessible-resources
enum ExtensionNavigationPolicy {
    /// The initiating frame's origin, as WebKit reports it (`WKSecurityOrigin`); nil when unknown or opaque.
    struct Origin: Equatable {
        var scheme: String
        var host: String
        var port: Int?
        init(scheme: String, host: String, port: Int? = nil) {
            self.scheme = scheme.lowercased(); self.host = host.lowercased(); self.port = port.flatMap { $0 == 0 ? nil : $0 }
        }
    }

    /// The target is a page of the extension whose origin started the navigation (it opens its own page).
    static func isSameExtension(target: URL, initiator: Origin?) -> Bool {
        guard let initiator, let scheme = target.scheme?.lowercased(), let host = target.host?.lowercased() else { return false }
        return initiator.scheme == scheme && initiator.host == host
    }

    /// May a page at `initiator` open `target` (an extension page) in the top frame?
    static func allowsWebInitiated(target: URL, initiator: Origin?, manifest: [String: Any]?) -> Bool {
        if isSameExtension(target: target, initiator: initiator) { return true }
        guard let manifest else { return false }
        return isWebAccessible(path: target.path, from: initiator, manifest: manifest)
    }

    /// `path` is the extension URL's path ("/page.html").
    static func isWebAccessible(path: String, from origin: Origin?, manifest: [String: Any]) -> Bool {
        let resource = normalized(path)
        guard !resource.isEmpty, let entries = manifest["web_accessible_resources"] as? [Any] else { return false }
        let version = (manifest["manifest_version"] as? NSNumber)?.intValue ?? 2
        if version < 3 {
            // V2: a flat list of resource patterns, reachable from any page.
            return entries.contains { ($0 as? String).map { resourceMatches(resource, pattern: $0) } ?? false }
        }
        for case let entry as [String: Any] in entries {
            let resources = entry["resources"] as? [String] ?? []
            guard resources.contains(where: { resourceMatches(resource, pattern: $0) }) else { continue }
            let matches = entry["matches"] as? [String] ?? []
            if matches.contains(where: { originMatches(origin, pattern: $0) }) { return true }
        }
        return false
    }

    // MARK: Matching

    private static func normalized(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        var trimmed = Substring(decoded)
        while trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        // Never let "..", "." or empty segments reach a pattern.
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.contains(where: { $0 == ".." || $0 == "." }) else { return "" }
        return segments.joined(separator: "/")
    }

    /// Resource patterns are paths relative to the extension's root; `*` matches any run of characters.
    static func resourceMatches(_ resource: String, pattern raw: String) -> Bool {
        var pattern = Substring(raw.trimmingCharacters(in: .whitespaces))
        while pattern.hasPrefix("/") { pattern = pattern.dropFirst() }
        guard !pattern.isEmpty else { return false }
        return glob(Array(resource.unicodeScalars), Array(String(pattern).unicodeScalars))
    }

    private static func glob(_ text: [Unicode.Scalar], _ pattern: [Unicode.Scalar]) -> Bool {
        var t = 0, p = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] != "*", pattern[p] == text[t] { t += 1; p += 1 }
            else if p < pattern.count, pattern[p] == "*" { star = p; mark = t; p += 1 }
            else if star >= 0 { p = star + 1; mark += 1; t = mark }
            else { return false }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// A match pattern (`<all_urls>`, `*://*/*`, `https://*.example.com/*`) against an origin. Only the
    /// scheme and host count; web_accessible_resources patterns must use the "/*" path.
    static func originMatches(_ origin: Origin?, pattern raw: String) -> Bool {
        let pattern = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let origin, !origin.host.isEmpty else { return false }
        let webSchemes: Set<String> = ["http", "https"]
        if pattern == "<all_urls>" { return webSchemes.contains(origin.scheme) || origin.scheme == "file" }
        guard let schemeEnd = pattern.range(of: "://") else { return false }
        let scheme = String(pattern[..<schemeEnd.lowerBound])
        let rest = pattern[schemeEnd.upperBound...]
        let hostPart = String(rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let schemeOK = scheme == "*" ? webSchemes.contains(origin.scheme) : scheme == origin.scheme
        guard schemeOK else { return false }
        var hostPattern = hostPart, portPattern: String?
        if let colon = hostPart.lastIndex(of: ":"), !hostPart.hasPrefix("[") {
            hostPattern = String(hostPart[..<colon]); portPattern = String(hostPart[hostPart.index(after: colon)...])
        }
        if let portPattern, portPattern != "*" {
            guard let port = Int(portPattern), port == (origin.port ?? defaultPort(origin.scheme)) else { return false }
        }
        if hostPattern == "*" { return true }
        if hostPattern.hasPrefix("*.") {
            let base = String(hostPattern.dropFirst(2))
            return origin.host == base || origin.host.hasSuffix("." + base)
        }
        return origin.host == hostPattern
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme { case "http": return 80; case "https": return 443; default: return nil }
    }
}
