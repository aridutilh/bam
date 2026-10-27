import AppKit
import WebKit

/// Web Inspector for page web views.
///
/// Public API: `isInspectable` (macOS 13.3+) lists the page in Safari's Develop
/// menu and lets WebKit attach its inspector. WebKit has no public call that
/// opens that inspector from the app itself, so the Develop menu's commands use
/// WebKit's long-standing `_inspector` object (`_WKInspector`: `show`,
/// `showConsole`, `toggleElementSelection`). Every private selector is checked
/// with `responds(to:)` first; if a future WebKit drops one, the command
/// quietly does nothing instead of crashing. All of it lives in this file.
@MainActor enum PageInspector {
    /// Turned on for every page Bam shows: Safari ▸ Develop can attach, and the
    /// page's own right-click menu gains Inspect Element.
    static func enable(_ web: WKWebView) {
        if #available(macOS 13.3, *), !web.isInspectable { web.isInspectable = true }
        let preferences = web.configuration.preferences
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
    }

    static var isAvailable: Bool {
        WKWebView.instancesRespond(to: NSSelectorFromString("_inspector"))
    }

    /// Opens the inspector for this page (Elements), or brings it forward.
    @discardableResult static func show(_ web: WKWebView) -> Bool { perform("show", on: web) }
    /// Opens the inspector straight to its Console.
    @discardableResult static func showConsole(_ web: WKWebView) -> Bool {
        perform("showConsole", on: web) || perform("show", on: web)
    }
    /// The inspector's element picker: the next click on the page selects that element.
    @discardableResult static func inspectElement(_ web: WKWebView) -> Bool {
        guard let inspector = inspector(of: web) else { return false }
        let pick = NSSelectorFromString("toggleElementSelection")
        guard inspector.responds(to: pick) else { return false }
        if inspector.responds(to: NSSelectorFromString("show")) { _ = inspector.perform(NSSelectorFromString("show")) }
        _ = inspector.perform(pick)
        return true
    }

    private static func inspector(of web: WKWebView) -> NSObject? {
        enable(web)
        let getter = NSSelectorFromString("_inspector")
        guard web.responds(to: getter) else { return nil }
        return web.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    private static func perform(_ name: String, on web: WKWebView) -> Bool {
        guard let inspector = inspector(of: web) else { return false }
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return false }
        _ = inspector.perform(selector)
        return true
    }
}
