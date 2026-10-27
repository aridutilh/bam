import WebKit

/// Trackpad gestures for ordinary pages. Call once where a tab, Peek or Little Bam web view is made.
/// Pinch zooms the page visually (as in Safari), separate from ⌘+/⌘− page zoom. The floating video
/// panel intercepts pinch before WebKit, so it resizes the panel instead of zooming the page.
@MainActor enum BrowserPageGestures {
    static func configure(_ web: WKWebView) {
        web.allowsMagnification = true
        WebsitePreferences.apply(to: web) // Settings › Websites: default zoom, minimum font size (once per page).
    }
    /// Actual Size (⌘0) returns to Settings › Websites' default zoom and also undoes a pinch.
    static func resetZoom(_ web: WKWebView) {
        web.pageZoom = CGFloat(WebsitePreferences.pageZoom)
        if web.magnification != 1 { web.magnification = 1 }
    }
}
