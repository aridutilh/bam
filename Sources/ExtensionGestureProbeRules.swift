import Foundation

/// Pure rules for the extension gesture probe (`--extension-test --extension-gesture-probe`): configuration,
/// loopback scoping and the install-review decision. Foundation only, so they are testable without an app.
enum ExtensionGestureProbeRules {
    /// The real-click wait; `BAM_GESTURE_CLICK_SECONDS` can only shorten it.
    static let maximumClickSeconds: TimeInterval = 40
    static let marker = "bam-gesture-probe"

    enum ToolbarMode: String { case button, real, off }

    static func clickSeconds(_ raw: String?) -> TimeInterval {
        guard let raw, let value = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else { return maximumClickSeconds }
        return min(value, maximumClickSeconds)
    }
    /// Absent means `button`; anything unknown is refused (nil).
    static func toolbarMode(_ raw: String?) -> ToolbarMode? {
        guard let raw else { return .button }
        return ToolbarMode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    static func isLoopback(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && loopbackHosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
    }
    /// Content-script match patterns for exactly the fixture page's scheme and host (any port, as match patterns allow).
    static func matchPatterns(for page: URL) -> [String] {
        guard isLoopback(page), let scheme = page.scheme?.lowercased(), let host = page.host?.lowercased() else { return [] }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return ["\(scheme)://\(bracketed)/*"]
    }
    /// The fixture page with only the probe marker as its query.
    static func probeURL(_ page: URL) -> URL? {
        guard isLoopback(page), var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: marker, value: "1")]
        components.fragment = nil
        return components.url
    }
    /// Bam's MV3 worker preparation adds its internal `nativeMessaging` transport to the private copy; the install
    /// review lists it as unsupported, and approving the review never grants it (that transport is a separate grant).
    static let toleratedUnsupported: Set<String> = ["nativeMessaging"]
    /// The install review may only ask for the loopback content-script websites: no API permissions, nothing
    /// unsupported except Bam's own worker transport. Every optional review is refused.
    static func allowsInstall(permissions: [String], unsupported: [String], websites: [String], isOptional: Bool) -> Bool {
        guard !isOptional, permissions.isEmpty, Set(unsupported).isSubset(of: toleratedUnsupported), !websites.isEmpty else { return false }
        return websites.allSatisfy { pattern in
            guard let url = URL(string: pattern) else { return false }
            return isLoopback(url) && url.port == nil && url.path == "/*" && url.query == nil
        }
    }
}
