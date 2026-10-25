import CoreGraphics
import Foundation

/// Where an extension may open tabs and windows in Bam, decided before anything is created. Bam never places a tab
/// or window somewhere other than where the extension asked; a request it cannot honor is refused with a reason.
///
/// Bam's windows as extensions see them: the browser window (tabs of this profile; several profiles share it) and
/// Little Bam windows, which hold one page and are reported as `popup`.
enum ExtensionWindowTargeting {
    enum Window: Equatable { case browser, singlePage, otherProfile }
    enum RequestedType: Equatable { case normal, popup, other }
    enum RequestedState: Equatable { case normal, minimized, maximized, fullscreen }

    static let normalWindowRefusal = "Bam cannot open a new tabbed browser window for an extension. windows.create can open one page with type 'popup'."
    static let stateRefusal = "Bam cannot open extension windows maximized or full screen."
    static let multiplePagesRefusal = "Bam's extension popups hold one page; pass at most one URL and no tabs."
    static let singlePageTabRefusal = "This window is a single-page popup; Bam cannot add a tab to it."
    static let otherProfileRefusal = "The window is not in this extension's profile."
    static let indexRefusal = "Bam can only add a tab at the end of a window's tabs."
    static let noWindowRefusal = "There is no window to open this tab in."
    static let boundsRefusal = "Bam cannot place extension popups at requested bounds yet; omit left, top, width and height."
    /// A Peek is shown after the window's tabs; a new tab lands before it, at `landing`.
    static func peekRefusal(landing: Int) -> String {
        "This window shows a Peek after its tabs, so a new tab is added before it, at index \(landing). Pass that index or close the Peek."
    }

    /// `tabs.create`. WebKit resolves an omitted windowId to the current window (nil when there is none) and an omitted
    /// index to that window's tab count, so a default request arrives as "append to the current window". In Bam's
    /// browser window a new tab lands at `landing`: after this profile's tabs, before any exposed Peek. Only that
    /// position is honored (an index past the end clamps to it when nothing follows the tabs); inserting elsewhere
    /// needs a session seam that keeps folder/pin identity, so it is refused, not ignored.
    static func tabCreation(target: Window?, index: Int, landing: Int, windowTabCount: Int) -> String? {
        switch target {
        case nil: return noWindowRefusal
        case .singlePage?: return singlePageTabRefusal
        case .otherProfile?: return otherProfileRefusal
        case .browser?:
            if index == landing || (landing == windowTabCount && index > landing) { return nil }
            return index < landing ? indexRefusal : peekRefusal(landing: landing)
        }
    }

    /// `windows.create`: nil when Bam can open it as a Little Bam popup. Requested bounds are refused until a real
    /// Little Bam round trip is proven (its minimum content size and placement may differ from the request).
    static func windowCreation(type: RequestedType, state: RequestedState, urlCount: Int, hasTabs: Bool, requestsBounds: Bool) -> String? {
        if type != .popup { return normalWindowRefusal }
        if requestsBounds { return boundsRefusal }
        if state == .maximized || state == .fullscreen { return stateRefusal }
        if urlCount > 1 || hasTabs { return multiplePagesRefusal }
        return nil
    }

    /// WebKit passes requested bounds with NaN for every component that was not requested. Only detectable requests can
    /// be refused: WebKit flips `top` using the requested height, so `top` without `height` arrives as NaN and is
    /// indistinguishable from no request (that popup opens at Little Bam's normal placement).
    static func requestsBounds(_ frame: CGRect) -> Bool {
        !frame.isNull && [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].contains { $0.isFinite }
    }
}
