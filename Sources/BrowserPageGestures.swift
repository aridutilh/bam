import WebKit

/// Trackpad gestures for ordinary pages. Call once where a tab, Peek or Little Bam web view is made.
/// Pinch zooms the page visually (as in Safari), separate from ⌘+/⌘− page zoom. The floating video
/// panel intercepts pinch before WebKit, so it resizes the panel instead of zooming the page.
@MainActor enum BrowserPageGestures {
    static func configure(_ web: WKWebView) {
        web.allowsMagnification = true
    }
    /// Actual Size (⌘0) should also undo a pinch.
    static func resetZoom(_ web: WKWebView) {
        web.pageZoom = 1
        if web.magnification != 1 { web.magnification = 1 }
    }
}
