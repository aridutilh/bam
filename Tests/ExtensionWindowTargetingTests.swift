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

        // tabs.create: WebKit's default (current window, index = its tab count) appends; clamped past the end.
        try check(T.tabCreation(target: .browser, index: 5, windowTabCount: 5) == nil && T.tabCreation(target: .browser, index: 9, windowTabCount: 5) == nil &&
                  T.tabCreation(target: nil, index: 0, windowTabCount: 0) == nil, "An append to the browser window was refused")
        try check(T.tabCreation(target: .browser, index: 0, windowTabCount: 5) == T.indexRefusal && T.tabCreation(target: .browser, index: 4, windowTabCount: 5) == T.indexRefusal,
                  "An insertion before existing tabs was not refused")
        try check(T.tabCreation(target: .singlePage, index: 1, windowTabCount: 1) == T.singlePageTabRefusal &&
                  T.tabCreation(target: .otherProfile, index: 3, windowTabCount: 3) == T.otherProfileRefusal,
                  "A popup or other-profile target was not refused")

        // windows.create: only a single-page popup in a normal or minimized state.
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 1, hasTabs: false) == nil &&
                  T.windowCreation(type: .popup, state: .minimized, urlCount: 0, hasTabs: false) == nil, "A supported popup request was refused")
        try check(T.windowCreation(type: .normal, state: .normal, urlCount: 1, hasTabs: false) == T.normalWindowRefusal &&
                  T.windowCreation(type: .other, state: .normal, urlCount: 1, hasTabs: false) == T.normalWindowRefusal, "A non-popup window was not refused")
        try check(T.windowCreation(type: .popup, state: .maximized, urlCount: 1, hasTabs: false) == T.stateRefusal &&
                  T.windowCreation(type: .popup, state: .fullscreen, urlCount: 1, hasTabs: false) == T.stateRefusal, "Maximized or full-screen popups were not refused")
        try check(T.windowCreation(type: .popup, state: .normal, urlCount: 2, hasTabs: false) == T.multiplePagesRefusal &&
                  T.windowCreation(type: .popup, state: .normal, urlCount: 0, hasTabs: true) == T.multiplePagesRefusal, "A multi-page popup was not refused")

        // Requested bounds: only requested components change; nothing requested means nothing applied.
        let nan = CGFloat.nan, current = CGRect(x: 10, y: 20, width: 300, height: 200)
        try check(T.frame(requested: CGRect(x: nan, y: nan, width: nan, height: nan), current: current) == nil && T.frame(requested: .null, current: current) == nil,
                  "An empty request changed the frame")
        try check(T.frame(requested: CGRect(x: 140, y: 400, width: 420, height: 300), current: current) == CGRect(x: 140, y: 400, width: 420, height: 300),
                  "A full request was not applied as given")
        try check(T.frame(requested: CGRect(x: nan, y: nan, width: 500, height: nan), current: current) == CGRect(x: 10, y: 20, width: 500, height: 200) &&
                  T.frame(requested: CGRect(x: 55, y: nan, width: nan, height: nan), current: current) == CGRect(x: 55, y: 20, width: 300, height: 200),
                  "A partial request changed unrequested components")
        return checks
    }
}
