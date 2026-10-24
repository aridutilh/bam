import WebKit

/// The trailing token Safari appends to WebKit's default user agent.
///
/// A bare WKWebView identifies itself as "AppleWebKit/605.1.15 (KHTML, like Gecko)"
/// with nothing after it. Streaming sites (Netflix, Spotify, Disney+ and others)
/// read the "Version/… Safari/…" suffix to choose their FairPlay playback path and
/// can refuse playback without it, even though the FairPlay key system itself is
/// available to every WebKit app. Adopting Safari's suffix makes Bam's tabs
/// negotiate DRM exactly as Safari does.
enum SafariUserAgent {
    /// Mirrors the installed Safari's version so the suffix tracks OS updates.
    static let suffix: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let installed = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
        return "Version/\(installed ?? "26.0") Safari/605.1.15"
    }()
}

extension WKWebViewConfiguration {
    /// Apply to every configuration that backs a user-facing page.
    func adoptSafariUserAgent() { applicationNameForUserAgent = SafariUserAgent.suffix }
}
