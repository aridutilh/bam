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

    /// `tabs.create`. WebKit resolves an omitted windowId to the current window and an omitted index to that window's
    /// tab count, so a default request arrives as "append to the current window". Inserting at another position is
    /// not supported yet (it needs a session seam that keeps folder/pin identity), so it is refused, not ignored.
    static func tabCreation(target: Window?, index: Int, windowTabCount: Int) -> String? {
        switch target {
        case .singlePage?: return singlePageTabRefusal
        case .otherProfile?: return otherProfileRefusal
        // Chrome clamps an index past the end to the end.
        case .browser?, nil: return index >= windowTabCount ? nil : indexRefusal
        }
    }

    /// `windows.create`: nil when Bam can open it as a Little Bam popup.
    static func windowCreation(type: RequestedType, state: RequestedState, urlCount: Int, hasTabs: Bool) -> String? {
        if type != .popup { return normalWindowRefusal }
        if state == .maximized || state == .fullscreen { return stateRefusal }
        if urlCount > 1 || hasTabs { return multiplePagesRefusal }
        return nil
    }

    /// The frame to apply: WebKit passes requested bounds already in AppKit screen coordinates, with NaN for every
    /// component that was not requested (an unrequested height also leaves the bottom edge unknown). Nil when nothing
    /// was requested.
    static func frame(requested: CGRect, current: CGRect) -> CGRect? {
        let components = [requested.origin.x, requested.origin.y, requested.size.width, requested.size.height]
        guard !requested.isNull, components.contains(where: { $0.isFinite }) else { return nil }
        var result = current
        if requested.size.width.isFinite, requested.size.width > 0 { result.size.width = requested.size.width }
        if requested.size.height.isFinite, requested.size.height > 0 { result.size.height = requested.size.height }
        if requested.origin.x.isFinite { result.origin.x = requested.origin.x }
        if requested.origin.y.isFinite { result.origin.y = requested.origin.y }
        return result
    }
}
