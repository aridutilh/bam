import WebKit

/// Settings › Websites: the zoom every page starts at and the smallest text a page may
/// use. Both apply to each tab's page as it is made, and to open pages when changed.
/// Fresh previews and test fixtures keep them in memory so they never change the
/// real app's choices.
@MainActor enum WebsitePreferences {
    static let pageZoomKey = "DefaultPageZoom"
    static let minimumFontSizeKey = "MinimumFontSize"
    /// Page zoom choices, as Settings offers them.
    static let zoomChoices: [Double] = [0.9, 1, 1.1, 1.25]
    /// Minimum font size choices in points; 0 is off (pages pick their own sizes).
    static let fontChoices: [Double] = [0, 9, 12, 14, 18]

    nonisolated(unsafe) static var defaults: UserDefaults? = ContentBlockingPreference.isDisposableLaunch(CommandLine.arguments) ? nil : .standard
    private static var memoryZoom: Double = 1
    private static var memoryFont: Double = 0

    static var pageZoom: Double {
        get {
            let value = defaults?.object(forKey: pageZoomKey) as? Double ?? memoryZoom
            return zoomChoices.contains(value) ? value : 1
        }
        set {
            guard zoomChoices.contains(newValue) else { return }
            if let defaults { newValue == 1 ? defaults.removeObject(forKey: pageZoomKey) : defaults.set(newValue, forKey: pageZoomKey) }
            else { memoryZoom = newValue }
        }
    }
    static var minimumFontSize: Double {
        get {
            let value = defaults?.object(forKey: minimumFontSizeKey) as? Double ?? memoryFont
            return fontChoices.contains(value) ? value : 0
        }
        set {
            guard fontChoices.contains(newValue) else { return }
            if let defaults { newValue == 0 ? defaults.removeObject(forKey: minimumFontSizeKey) : defaults.set(newValue, forKey: minimumFontSizeKey) }
            else { memoryFont = newValue }
        }
    }

    /// A new tab's page: starts at the default zoom with the minimum font size in force.
    static func apply(to web: WKWebView) {
        web.pageZoom = CGFloat(pageZoom)
        web.configuration.preferences.minimumFontSize = CGFloat(minimumFontSize)
    }
    /// Open pages after a change. A page someone zoomed with ⌘+/⌘− keeps its zoom;
    /// one still at the old default moves to the new one.
    static func update(_ pages: [WKWebView], previousZoom: Double) {
        for web in pages {
            if abs(Double(web.pageZoom) - previousZoom) < 0.001 { web.pageZoom = CGFloat(pageZoom) }
            web.configuration.preferences.minimumFontSize = CGFloat(minimumFontSize)
        }
    }

    static func zoomTitle(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }
    static func fontTitle(_ size: Double) -> String { size == 0 ? "Off" : "\(Int(size)) pt" }

    /// A typed site for the keep-awake list, as the list stores hosts: "https://Mail.Google.com/x" → "mail.google.com".
    nonisolated static func host(fromTyped text: String) -> String? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        if !typed.contains("://") { typed = "https://" + typed }
        guard let host = URL(string: typed)?.host, host.contains(".") || host == "localhost" else { return nil }
        return host
    }
}
