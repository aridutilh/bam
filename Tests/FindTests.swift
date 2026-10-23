import AppKit
import WebKit

/// Exercises WebKit's actual find implementation using in-memory HTML and hidden windows.
/// Does not synthesize events, open external pages, or use a persistent website data store.
@MainActor @main struct FindTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
            window.contentView = host
            let first = makeWeb(in: host)
            let second = makeWeb(in: host)
            first.loadHTMLString("<!doctype html><title>Find first</title><p>Alpha [needle] omega</p>", baseURL: nil)
            second.loadHTMLString("<!doctype html><title>Find second</title><p>Beta lives here</p>", baseURL: nil)
            try check(wait(10) { first.title == "Find first" && second.title == "Find second" && !first.isLoading && !second.isLoading }, "Fixture pages did not load")
            let find = FindBarCoordinator()
            find.show(in: host, web: first)
            try check(find.isVisible && find.view.superview === host, "Find overlay was not attached")
            try check(find.view.hitTest(NSPoint(x: 5, y: 5)) == nil, "Find overlay blocked page clicks outside its bar")
            find.searchText = "aLPHa"
            try check(wait(5) { find.matchFound == true }, "Default search was not case-insensitive")
            try check(find.statusText == "Match", "Found-result feedback was missing")
            // There is only one Alpha; continued forward and backward requests must wrap.
            for _ in 0..<3 {
                find.findNext()
                try check(wait(5) { find.matchFound == true }, "Forward search failed to wrap")
            }
            for _ in 0..<3 {
                find.findNext(backwards: true)
                try check(wait(5) { find.matchFound == true }, "Backward search failed to wrap")
            }
            find.searchText = "[needle]"
            try check(wait(5) { find.matchFound == true }, "Literal punctuation was not found")
            find.searchText = "absent token"
            try check(wait(5) { find.matchFound == false }, "Missing text did not return no-match")
            try check(find.statusText == "No matches", "No-match feedback was missing")
            // Switch immediately, before the first page's native completion can arrive.
            find.searchText = "Alpha"
            find.retarget(web: second)
            try check(wait(5) { find.matchFound == false }, "Tab switch used the previous page's result")
            pump(0.15)
            try check(find.matchFound == false && find.searchText == "Alpha", "Stale completion overwrote the new page's result or query")
            find.searchText = "BETA"
            try check(wait(5) { find.matchFound == true }, "Retargeted page was not searched")
            find.retarget(web: nil)
            try check(find.matchFound == nil && find.statusText == "No page", "Nil target retained a stale result")
            find.retarget(web: first)
            find.searchText = "Alpha"
            find.searchText = "missing after replacement"
            try check(wait(5) { find.matchFound == false }, "Replaced query used an older completion")
            find.searchText = "Alpha"
            find.hide()
            pump(0.15)
            try check(!find.isVisible && find.view.superview == nil && find.matchFound == nil, "Hidden bar accepted a late result")
            try check(window.firstResponder === first, "Closing find did not return focus to the current page")
            find.show(in: host, web: first)
            try check(find.searchText == "Alpha" && wait(5) { find.matchFound == true }, "Reopening find lost its query")
            find.hide()
            find.retarget(web: second)
            find.show(in: host, web: second)
            try check(wait(5) { find.matchFound == false }, "Reopening after a hidden retarget did not search the new page")
            find.searchText = ""
            try check(find.matchFound == nil && find.statusText == "Find in page", "Empty query retained result feedback")
            find.hide()
            first.stopLoading(); second.stopLoading(); window.close()
            print("PASS: native WebKit case-insensitive/literal find, forward/backward wrapping, no-match feedback, target/query replacement, hide/focus/reopen, overlay hit testing")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func makeWeb(in host: NSView) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: host.bounds, configuration: configuration)
        host.addSubview(web)
        return web
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
    static func pump(_ seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
