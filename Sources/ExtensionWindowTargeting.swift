import CoreGraphics
import Foundation

/// Where an extension may open tabs and windows in Bam, decided before anything is created. Bam never places a tab
/// or window somewhere other than where the extension asked; a request it cannot honor is refused with a reason.
///
/// Bam's windows as extensions see them: the browser window (tabs of this profile; several profiles share it) and
/// Little Bam windows, which hold one page and are reported as `popup`.
///
/// A tab's index in the browser window is its position in Bam's session order among this profile's tabs, across all
/// of the profile's Spaces, with any exposed Peek after them. It is not the grouped sidebar order (Favorites, kept
/// folders, Today), so a tab can sit at a different place in the sidebar than its index suggests.
enum ExtensionWindowTargeting {
    enum Window: Equatable { case browser, singlePage, otherProfile }
    enum RequestedType: Equatable { case normal, popup, other }
    enum RequestedState: Equatable { case normal, minimized, maximized, fullscreen }

    static let normalWindowRefusal = "Bam cannot open a new tabbed browser window for an extension. windows.create can open one page with type 'popup'."
    static let stateRefusal = "Bam cannot open extension windows maximized or full screen."
    static let multiplePagesRefusal = "Bam's extension popups hold one page; pass at most one URL and no tabs."
    static let singlePageTabRefusal = "This window is a single-page popup; Bam cannot add a tab to it."
    static let otherProfileRefusal = "The window is not in this extension's profile."
    /// Only for hosts that cannot place a tab before another (fixture hosts); Bam's browser can.
    static let indexRefusal = "Bam can only add a tab at the end of a window's tabs."
    static let noWindowRefusal = "There is no window to open this tab in."
    static let browserWindowFrameRefusal = "Bam doesn't let extensions move or resize its browser window; popup windows can be moved and resized."
    /// A Peek is shown after the window's tabs; a new tab lands before it, at `landing`.
    static func peekRefusal(landing: Int) -> String {
        "This window shows a Peek after its tabs, so a new tab is added before it, at index \(landing). Pass that index or close the Peek."
    }

    /// `tabs.create`. WebKit resolves an omitted windowId to the current window (nil when there is none) and an omitted
    /// index to that window's tab count, so a default request arrives as "append to the current window". In Bam's
    /// browser window an appended tab lands at `landing`: after this profile's tabs, before any exposed Peek (an index
    /// past the end clamps to it when nothing follows the tabs). An index before `landing` inserts the tab immediately
    /// before the tab now at that index, but only for a host that can place it there (`canInsert`); otherwise it is
    /// refused, never ignored. An index past an exposed Peek is refused with the index that would be honored.
    static func tabCreation(target: Window?, index: Int, landing: Int, windowTabCount: Int, canInsert: Bool = false) -> String? {
        switch target {
        case nil: return noWindowRefusal
        case .singlePage?: return singlePageTabRefusal
        case .otherProfile?: return otherProfileRefusal
        case .browser?:
            if index == landing || (landing == windowTabCount && index > landing) { return nil }
            if index >= 0 && index < landing { return canInsert ? nil : indexRefusal }
            return peekRefusal(landing: landing)
        }
    }
    /// The position of the existing tab the new one goes before, or nil to append. Only meaningful once
    /// `tabCreation` allowed the request.
    static func insertionAnchor(index: Int, landing: Int) -> Int? { index >= 0 && index < landing ? index : nil }
    static func placementRefusal(index: Int) -> String {
        "Bam could not place the new tab at index \(index), so it was not opened."
    }

    /// `windows.create`: nil when Bam can open it as a Little Bam popup. Requested bounds are honoured through
    /// `popupFrame` once the window exists.
    static func windowCreation(type: RequestedType, state: RequestedState, urlCount: Int, hasTabs: Bool) -> String? {
        if type != .popup { return normalWindowRefusal }
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

    /// The frame a Little Bam popup takes for `windows.create` or `windows.update` bounds. `requested` is WebKit's
    /// frame in macOS global coordinates (bottom-left origin); a NaN or non-positive component was not requested and
    /// comes from `current`, and without a requested top the window keeps its top edge. The size is at least `minimum`
    /// and at most the visible frame of the screen the window lands on, and the window stays on that screen.
    static func popupFrame(requested: CGRect, current: CGRect, minimum: CGSize, screens: [CGRect]) -> CGRect {
        func given(_ value: CGFloat) -> CGFloat? { value.isFinite ? value : nil }
        func size(_ value: CGFloat) -> CGFloat? { given(value).flatMap { $0 > 0 ? $0 : nil } }
        let none = requested.isNull
        var width = (none ? nil : size(requested.size.width)) ?? current.width
        var height = (none ? nil : size(requested.size.height)) ?? current.height
        var x = (none ? nil : given(requested.origin.x)) ?? current.minX
        var y = (none ? nil : given(requested.origin.y)) ?? current.maxY - height
        let floorWidth = max(1, minimum.width.isFinite ? minimum.width : 1), floorHeight = max(1, minimum.height.isFinite ? minimum.height : 1)
        width = max(width, floorWidth); height = max(height, floorHeight)
        let usable = screens.filter { $0.width > 0 && $0.height > 0 && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }
        let proposed = CGRect(x: x, y: y, width: width, height: height)
        let center = CGPoint(x: proposed.midX, y: proposed.midY)
        guard let screen = usable.first(where: { $0.contains(center) })
                ?? usable.max(by: { $0.intersection(proposed).area < $1.intersection(proposed).area })
                ?? usable.first else { return proposed }
        width = max(floorWidth, min(width, screen.width)); height = max(floorHeight, min(height, screen.height))
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - width))
        y = min(max(y, screen.minY), max(screen.minY, screen.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
