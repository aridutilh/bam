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
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 1, hasTabs: false, requestsBounds: false) == nil &&
                  T.windowCreation(type: .popup, state: .minimized, urlCount: 0, hasTabs: false, requestsBounds: false) == nil, "A supported popup request was refused")
        try check(T.windowCreation(type: .normal, state: .normal, urlCount: 1, hasTabs: false, requestsBounds: false) == T.normalWindowRefusal &&
                  T.windowCreation(type: .other, state: .normal, urlCount: 1, hasTabs: false, requestsBounds: false) == T.normalWindowRefusal, "A non-popup window was not refused")
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 1, hasTabs: false, requestsBounds: true) == T.boundsRefusal, "Requested bounds were not refused")
        try check(T.windowCreation(type: .popup, state: .maximized, urlCount: 1, hasTabs: false, requestsBounds: false) == T.stateRefusal &&
                  T.windowCreation(type: .popup, state: .fullscreen, urlCount: 1, hasTabs: false, requestsBounds: false) == T.stateRefusal, "Maximized or full-screen popups were not refused")
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 2, hasTabs: false, requestsBounds: false) == T.multiplePagesRefusal &&
                  T.windowCreation(type: .popup, state: .normal, urlCount: 0, hasTabs: true, requestsBounds: false) == T.multiplePagesRefusal, "A multi-page popup was not refused")
        let nan = CGFloat.nan
        try check(!T.requestsBounds(CGRect(x: nan, y: nan, width: nan, height: nan)) && !T.requestsBounds(.null) &&
                  T.requestsBounds(CGRect(x: nan, y: nan, width: 420, height: nan)) && T.requestsBounds(CGRect(x: 10, y: nan, width: nan, height: nan)),
                  "Requested bounds were misdetected")
        return checks
    }
}
