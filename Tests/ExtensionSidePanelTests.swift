import Foundation

/// Side panel state rules from Chrome's sidePanel reference; pure model, no WebKit or UI.
@main struct ExtensionSidePanelTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    typealias Model = ExtensionSidePanelModel
    static func main() {
        do { print("PASS: Extension side panel model — \(try run()) checks") }
        catch { fputs("FAIL: Extension side panel model: \(error)\n", stderr); exit(1) }
    }

    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        func fails(_ expected: Model.Failure, _ work: () throws -> Any) -> Bool {
            do { _ = try work(); return false } catch let failure as Model.Failure { return failure == expected } catch { return false }
        }
        // Window 1 holds tabs 10 and 11; window 2 holds tab 20.
        let windows = [10: 1, 11: 1, 20: 2]
        let windowOf: (Int) -> Int? = { windows[$0] }
        func opened(_ ext: String, _ path: String, _ window: Int, _ tab: Int?) -> Model.Change { .init(kind: .opened, extensionID: ext, path: path, windowId: window, tabId: tab) }
        func closed(_ ext: String, _ path: String, _ window: Int, _ tab: Int?) -> Model.Change { .init(kind: .closed, extensionID: ext, path: path, windowId: window, tabId: tab) }

        var model = Model()
        model.register(extensionID: "A", defaultPath: "panel.html")
        model.register(extensionID: "B", defaultPath: nil)

        // Targets and gestures are required; an extension without a global panel cannot open one by window.
        try check(fails(.needsTarget) { try model.open(extensionID: "A", tabId: nil, windowId: nil, windowOfTab: windowOf, hasGesture: true) }, "open without a target was accepted")
        try check(fails(.needsGesture) { try model.open(extensionID: "A", tabId: 10, windowId: nil, windowOfTab: windowOf, hasGesture: false) }, "open without a gesture was accepted")
        try check(fails(.noGlobalPanel) { try model.open(extensionID: "B", tabId: nil, windowId: 1, windowOfTab: windowOf, hasGesture: true) }, "a window open without a global panel was accepted")
        try check(fails(.tabNotInWindow) { try model.open(extensionID: "A", tabId: 10, windowId: 2, windowOfTab: windowOf, hasGesture: true) }, "a tab/window mismatch was accepted")
        try check(fails(.unknownTab(99)) { try model.open(extensionID: "A", tabId: 99, windowId: nil, windowOfTab: windowOf, hasGesture: true) }, "an unknown tab was accepted")

        // open({tabId}) without tab options opens the global panel: visible in every tab of that window, not in window 2.
        try check(try model.open(extensionID: "A", tabId: 10, windowId: nil, windowOfTab: windowOf, hasGesture: true) == [opened("A", "panel.html", 1, nil)], "global open did not report its window")
        try check(model.visible(windowId: 1, activeTabId: 11) == .init(extensionID: "A", scope: .global(window: 1), path: "panel.html") &&
                  model.visible(windowId: 2, activeTabId: 20) == nil, "the global panel did not follow its window only")
        try check(try model.open(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf, hasGesture: true).isEmpty, "re-opening an open panel was not a no-op")

        // close({tabId}) with only the global panel open rejects (Chrome 145); close({windowId}) closes it; a second close is a no-op.
        try check(fails(.closeGlobalWithTabId(11)) { try model.close(extensionID: "A", tabId: 11, windowId: nil, windowOfTab: windowOf) }, "closing a global panel by tab did not reject")
        try check(try model.close(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf) == [closed("A", "panel.html", 1, nil)] &&
                  model.visible(windowId: 1, activeTabId: 10) == nil, "closing by window did not close the global panel")
        try check(try model.close(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf).isEmpty, "closing a closed panel was not a no-op")

        // Tab-specific panels: setOptions with a tab and path, then open({tabId}) shows it only in that tab.
        try check(try model.setOptions(extensionID: "B", tabId: 11, enabled: nil, path: "b.html").isEmpty &&
                  model.options(extensionID: "B", tabId: 11) == .init(enabled: true, path: "b.html") &&
                  model.options(extensionID: "B", tabId: nil) == .init(enabled: true, path: nil), "tab options did not upsert separately from the defaults")
        try check(try model.open(extensionID: "B", tabId: 11, windowId: nil, windowOfTab: windowOf, hasGesture: true) == [opened("B", "b.html", 1, 11)] &&
                  model.visible(windowId: 1, activeTabId: 11) == .init(extensionID: "B", scope: .tab(11), path: "b.html") &&
                  model.visible(windowId: 1, activeTabId: 10) == nil, "a tab-specific panel was not confined to its tab")
        // The global panel opens beside it: other tabs show the global panel, the tab-specific tab keeps its own.
        _ = try model.open(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf, hasGesture: true)
        try check(model.visible(windowId: 1, activeTabId: 10)?.extensionID == "A" && model.visible(windowId: 1, activeTabId: 11)?.extensionID == "B",
                  "a window open overrode a currently-open tab-specific panel")
        // close({windowId}) leaves tab-specific panels open.
        _ = try model.close(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf)
        try check(model.visible(windowId: 1, activeTabId: 11)?.extensionID == "B", "closing the global panel closed a tab-specific one")
        // open({tabId}) for A's global panel in tab 11 overrides B's tab-specific panel there.
        try check(try model.open(extensionID: "A", tabId: 11, windowId: nil, windowOfTab: windowOf, hasGesture: true) == [closed("B", "b.html", 1, 11), opened("A", "panel.html", 1, nil)] &&
                  model.visible(windowId: 1, activeTabId: 11)?.extensionID == "A", "opening by tab did not override the tab's active panel")
        _ = try model.close(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf)

        // Same path for a tab and the default: separate instances.
        _ = try model.setOptions(extensionID: "A", tabId: 20, enabled: nil, path: "panel.html")
        _ = try model.open(extensionID: "A", tabId: 20, windowId: nil, windowOfTab: windowOf, hasGesture: true)
        _ = try model.open(extensionID: "A", tabId: nil, windowId: 1, windowOfTab: windowOf, hasGesture: true)
        try check(model.openInstances(extensionID: "A") == [.init(scope: .global(window: 1), path: "panel.html", windowId: 1, tabId: nil),
                                                             .init(scope: .tab(20), path: "panel.html", windowId: 2, tabId: 20)],
                  "a tab and the default with the same path did not get separate instances")
        // A path change on an open instance is reported; disabling a tab hides the global panel there and closes its own panel.
        try check(try model.setOptions(extensionID: "A", tabId: nil, enabled: nil, path: "panel2.html") == [.init(kind: .pathChanged, extensionID: "A", path: "panel2.html", windowId: 1, tabId: nil)],
                  "a default path change on an open global panel was not reported")
        _ = try model.setOptions(extensionID: "A", tabId: 10, enabled: false, path: nil)
        try check(model.visible(windowId: 1, activeTabId: 10) == nil && model.visible(windowId: 1, activeTabId: 11)?.path == "panel2.html",
                  "a disabled tab did not hide only its own view of the global panel")
        try check(fails(.disabled) { try model.open(extensionID: "A", tabId: 10, windowId: nil, windowOfTab: windowOf, hasGesture: true) }, "opening in a disabled tab was accepted")
        // Disabling the tab hides its open tab-specific panel without closing it; re-enabling shows it again.
        try check(try model.setOptions(extensionID: "A", tabId: 20, enabled: false, path: nil).isEmpty && model.visible(windowId: 2, activeTabId: 20) == nil &&
                  model.openInstances(extensionID: "A").contains { $0.scope == .tab(20) }, "disabling a tab closed or kept showing its tab-specific panel")
        try check(try model.setOptions(extensionID: "A", tabId: 20, enabled: true, path: nil).isEmpty && model.visible(windowId: 2, activeTabId: 20)?.scope == .tab(20),
                  "re-enabling a tab did not show its open panel again")
        // close() with both IDs is undefined in Chrome's reference: refused explicitly, nothing closes.
        try check(fails(.ambiguousClose) { try model.close(extensionID: "A", tabId: 20, windowId: 2, windowOfTab: windowOf) } &&
                  model.visible(windowId: 2, activeTabId: 20)?.scope == .tab(20), "close with both IDs was not refused")
        try check(fails(.invalidPath) { try model.setOptions(extensionID: "A", tabId: nil, enabled: nil, path: "https://example.com/x.html") } &&
                  fails(.invalidPath) { try model.setOptions(extensionID: "A", tabId: nil, enabled: nil, path: "../x.html") } &&
                  fails(.invalidPath) { try model.setOptions(extensionID: "A", tabId: nil, enabled: nil, path: "//x.html") } &&
                  Model.validPath("/panel.html") == "panel.html" && Model.validPath("?") == nil, "path validation accepted a non-local page")
        // Relative local-page contract: schemes, authority, decoded traversal, backslashes and control characters refused.
        let refused = ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<p>x</p>", "blob:panel", "%2e%2e/panel.html", "%2E%2E/panel.html",
                       "a/%2e%2e/%2e%2e/panel.html", "a%2f..%2fpanel.html", "./panel.html", "a//panel.html", "..\\panel.html", "a\\panel.html",
                       "a%5cpanel.html", "//host/panel.html", "http://user@host/panel.html", "user@host:80/panel.html", " panel.html", "panel.html\n",
                       "pa%00nel.html", "javascript%3Aalert(1)", "%zz.html", "", "/", "#only"]
        let accepted = ["panel.html": "panel.html", "/sub/panel.html": "sub/panel.html", "sub/panel.html?tab=1#top": "sub/panel.html?tab=1#top",
                        "panel%20one.html": "panel%20one.html"]
        try check(refused.allSatisfy { Model.validPath($0) == nil } && accepted.allSatisfy { Model.validPath($0.key) == $0.value },
                  "path contract: accepted \(refused.filter { Model.validPath($0) != nil }); mismatched \(accepted.filter { Model.validPath($0.key) != $0.value }.keys.sorted())")

        // openPanelOnActionClick toggles; without it the action click is not handled.
        var clicks = Model()
        clicks.register(extensionID: "C", defaultPath: "c.html")
        try check(clicks.actionClicked(extensionID: "C", tabId: 10, windowId: 1, windowOfTab: windowOf) == (false, []) ? true : false, "an action click was handled without the behavior")
        clicks.setBehavior(extensionID: "C", openPanelOnActionClick: true); clicks.setBehavior(extensionID: "C", openPanelOnActionClick: nil)
        try check(clicks.behavior(extensionID: "C"), "the behavior upsert lost its value")
        let first = clicks.actionClicked(extensionID: "C", tabId: 10, windowId: 1, windowOfTab: windowOf)
        let second = clicks.actionClicked(extensionID: "C", tabId: 10, windowId: 1, windowOfTab: windowOf)
        try check(first.handled && first.changes == [opened("C", "c.html", 1, nil)] && second.handled && second.changes == [closed("C", "c.html", 1, nil)],
                  "the action click did not toggle the panel")

        // Closing a tab drops its options and panel; unregistering closes everything with events.
        var lifecycle = Model()
        lifecycle.register(extensionID: "D", defaultPath: "d.html")
        _ = try lifecycle.setOptions(extensionID: "D", tabId: 11, enabled: nil, path: "dt.html")
        _ = try lifecycle.open(extensionID: "D", tabId: 11, windowId: nil, windowOfTab: windowOf, hasGesture: true)
        try check(lifecycle.tabClosed(11) == [closed("D", "dt.html", 1, 11)] && lifecycle.options(extensionID: "D", tabId: 11).path == "d.html", "a closed tab kept its panel or options")
        _ = try lifecycle.setOptions(extensionID: "D", tabId: 20, enabled: nil, path: "dt.html")
        _ = try lifecycle.open(extensionID: "D", tabId: 20, windowId: nil, windowOfTab: windowOf, hasGesture: true)
        _ = try lifecycle.open(extensionID: "D", tabId: nil, windowId: 1, windowOfTab: windowOf, hasGesture: true)
        try check(lifecycle.unregister(extensionID: "D") == [closed("D", "d.html", 1, nil), closed("D", "dt.html", 2, 20)] &&
                  lifecycle.openInstances(extensionID: "D").isEmpty && lifecycle.visible(windowId: 1, activeTabId: 10) == nil &&
                  fails(.unknownExtension) { try lifecycle.open(extensionID: "D", tabId: 10, windowId: nil, windowOfTab: windowOf, hasGesture: true) },
                  "unregistering did not close and forget the extension")
        // Disabled defaults hide a global panel even when no active tab is given; re-enabling shows it again.
        var defaultsModel = Model()
        defaultsModel.register(extensionID: "C", defaultPath: "panel.html")
        _ = try defaultsModel.open(extensionID: "C", tabId: nil, windowId: 1, windowOfTab: { _ in nil }, hasGesture: true)
        let shownBefore = defaultsModel.visible(windowId: 1, activeTabId: nil)?.scope == .global(window: 1)
        _ = try defaultsModel.setOptions(extensionID: "C", tabId: nil, enabled: false, path: nil)
        let hidden = defaultsModel.visible(windowId: 1, activeTabId: nil) == nil && defaultsModel.visible(windowId: 1, activeTabId: 10) == nil
        _ = try defaultsModel.setOptions(extensionID: "C", tabId: nil, enabled: true, path: nil)
        try check(shownBefore && hidden && defaultsModel.visible(windowId: 1, activeTabId: nil)?.scope == .global(window: 1),
                  "disabled defaults did not hide the global panel without an active tab, or re-enabling did not show it")
        return checks
    }
}
