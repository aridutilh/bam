import CoreGraphics
import Foundation

/// Tab/window targeting decisions: honored or refused, never redirected. Pure; no windows are created.
@main struct ExtensionWindowTargetingTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension window targeting — \(try run()) checks") }
        catch { fputs("FAIL: Extension window targeting: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias T = ExtensionWindowTargeting
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }

        // tabs.create: the tab lands after this profile's tabs (landing); only that position is honored.
        try check(T.tabCreation(target: .browser, index: 5, landing: 5, windowTabCount: 5) == nil && T.tabCreation(target: .browser, index: 9, landing: 5, windowTabCount: 5) == nil,
                  "An append to the browser window was refused")
        try check(T.tabCreation(target: .browser, index: 0, landing: 5, windowTabCount: 5) == T.indexRefusal && T.tabCreation(target: .browser, index: 4, landing: 5, windowTabCount: 5) == T.indexRefusal,
                  "An insertion before existing tabs was not refused by a host that cannot place it")
        // A host that can place tabs honors an insertion before the tab now at that index, Peek or not.
        try check(T.tabCreation(target: .browser, index: 0, landing: 5, windowTabCount: 5, canInsert: true) == nil &&
                  T.tabCreation(target: .browser, index: 4, landing: 5, windowTabCount: 6, canInsert: true) == nil &&
                  T.insertionAnchor(index: 0, landing: 5) == 0 && T.insertionAnchor(index: 4, landing: 5) == 4,
                  "An insertion was refused or anchored to the wrong tab")
        try check(T.insertionAnchor(index: 5, landing: 5) == nil && T.insertionAnchor(index: 9, landing: 5) == nil && T.insertionAnchor(index: -1, landing: 5) == nil,
                  "An append or invalid index was treated as an insertion")
        // Insertion support never loosens the other refusals.
        try check(T.tabCreation(target: .browser, index: 6, landing: 5, windowTabCount: 6, canInsert: true) == T.peekRefusal(landing: 5) &&
                  T.tabCreation(target: .singlePage, index: 0, landing: 1, windowTabCount: 1, canInsert: true) == T.singlePageTabRefusal &&
                  T.tabCreation(target: .otherProfile, index: 0, landing: 3, windowTabCount: 3, canInsert: true) == T.otherProfileRefusal &&
                  T.tabCreation(target: nil, index: 0, landing: 0, windowTabCount: 0, canInsert: true) == T.noWindowRefusal,
                  "Insertion support loosened a Peek, popup, other-profile or missing-window refusal")
        // With a Peek exposed after 5 tabs (6 in WebKit's count): the default end index would be wrong, so it is refused
        // with the honest index; that index itself is honored.
        try check(T.tabCreation(target: .browser, index: 6, landing: 5, windowTabCount: 6) == T.peekRefusal(landing: 5) &&
                  T.tabCreation(target: .browser, index: 9, landing: 5, windowTabCount: 6) == T.peekRefusal(landing: 5) &&
                  T.tabCreation(target: .browser, index: 5, landing: 5, windowTabCount: 6) == nil, "An append past an exposed Peek was not refused or its landing index was refused")
        try check(T.tabCreation(target: nil, index: 0, landing: 0, windowTabCount: 0) == T.noWindowRefusal &&
                  T.tabCreation(target: .singlePage, index: 1, landing: 1, windowTabCount: 1) == T.singlePageTabRefusal &&
                  T.tabCreation(target: .otherProfile, index: 3, landing: 3, windowTabCount: 3) == T.otherProfileRefusal,
                  "A missing, popup or other-profile target was not refused")

        // windows.create: only a single-page popup, normal or minimized, without requested bounds.
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 1, hasTabs: false) == nil &&
                  T.windowCreation(type: .popup, state: .minimized, urlCount: 0, hasTabs: false) == nil, "A supported popup request was refused")
        try check(T.windowCreation(type: .normal, state: .normal, urlCount: 1, hasTabs: false) == T.normalWindowRefusal &&
                  T.windowCreation(type: .other, state: .normal, urlCount: 1, hasTabs: false) == T.normalWindowRefusal, "A non-popup window was not refused")
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 1, hasTabs: false) == nil, "A popup with bounds is no longer refused; popupFrame places it")
        try check(T.windowCreation(type: .popup, state: .maximized, urlCount: 1, hasTabs: false) == T.stateRefusal &&
                  T.windowCreation(type: .popup, state: .fullscreen, urlCount: 1, hasTabs: false) == T.stateRefusal, "Maximized or full-screen popups were not refused")
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 2, hasTabs: false) == T.multiplePagesRefusal &&
                  T.windowCreation(type: .popup, state: .normal, urlCount: 0, hasTabs: true) == T.multiplePagesRefusal, "A multi-page popup was not refused")
        let nan = CGFloat.nan
        // popupFrame: WebKit's macOS frame (bottom-left origin), NaN where not requested.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875), side = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let current = CGRect(x: 600, y: 400, width: 360, height: 240), minimum = CGSize(width: 320, height: 180)
        try check(T.popupFrame(requested: CGRect(x: 220, y: 375, width: 420, height: 300), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 220, y: 375, width: 420, height: 300), "A popup that fits did not get exactly its requested frame")
        try check(T.popupFrame(requested: CGRect(x: nan, y: nan, width: 500, height: nan), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 600, y: 400, width: 500, height: 240), "A width-only request did not keep the other values")
        try check(T.popupFrame(requested: CGRect(x: nan, y: nan, width: nan, height: 300), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 600, y: 340, width: 360, height: 300), "A height-only request did not keep the window's top edge")
        // The top edge holds while the size settles (review hold): WebKit converted any requested top with the requested height.
        try check(T.popupFrame(requested: CGRect(x: nan, y: nan, width: nan, height: 50), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 600, y: 460, width: 360, height: 180), "A height-only request below the minimum moved the top edge")
        try check(T.popupFrame(requested: CGRect(x: 220, y: 650, width: 100, height: 50), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 220, y: 520, width: 320, height: 180), "An explicit top with a small size moved when raised to the minimum")
        try check(T.popupFrame(requested: CGRect(x: nan, y: nan, width: nan, height: 2000), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 600, y: 0, width: 360, height: 875), "An oversized height-only request was not limited to the screen")
        try check(T.popupFrame(requested: CGRect(x: 220, y: -1000, width: 420, height: 2000), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 220, y: 0, width: 420, height: 875), "An oversized request with a top was not limited to the screen")
        try check(T.popupFrame(requested: CGRect(x: 220, y: 300, width: 420, height: 300), current: current, minimum: CGSize(width: 520, height: 360), screens: [screen])
                  == CGRect(x: 220, y: 240, width: 520, height: 360), "Little Bam's real minimum did not apply with the top kept")
        try check(T.popupFrame(requested: CGRect(x: 1300, y: 800, width: 400, height: 300), current: current, minimum: minimum, screens: [screen])
                  == CGRect(x: 1040, y: 575, width: 400, height: 300), "A popup reaching past the screen edge was not kept on screen")
        try check(T.popupFrame(requested: CGRect(x: 0, y: 0, width: 5000, height: 4000), current: current, minimum: minimum, screens: [screen])
                  == screen, "An oversized popup was not limited to the screen")
        try check(T.popupFrame(requested: CGRect(x: 2000, y: 300, width: 600, height: 400), current: current, minimum: minimum, screens: [screen, side])
                  == CGRect(x: 2000, y: 300, width: 600, height: 400), "A popup requested on a second screen was moved off it")
        try check(T.popupFrame(requested: .null, current: current, minimum: minimum, screens: [screen]) == current
                  && T.popupFrame(requested: CGRect(x: nan, y: nan, width: -5, height: 0), current: current, minimum: minimum, screens: [screen]) == current,
                  "A null or non-positive request changed the window")
        try check(!T.requestsBounds(CGRect(x: nan, y: nan, width: nan, height: nan)) && !T.requestsBounds(.null) &&
                  T.requestsBounds(CGRect(x: nan, y: nan, width: 420, height: nan)) && T.requestsBounds(CGRect(x: 10, y: nan, width: nan, height: nan)),
                  "Requested bounds were misdetected")
        return checks
    }
}
