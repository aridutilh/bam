import AppKit
import WebKit

/// Run against a local HTTP fixture containing an input with id="entry".
/// Creates hidden windows only; no event synthesis or external websites.
@MainActor @main struct PreviewTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do {
            guard CommandLine.arguments.count >= 2, let url = URL(string: CommandLine.arguments[1]) else {
                throw Failure(description: "Supply the local HTTP fixture URL")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0,y: 0,width: 1000,height: 700))
            window.contentView = host
            let store = WKWebsiteDataStore.nonPersistent()
            let peek = PeekCoordinator()
            var dismissals = 0
            peek.onDismiss = { dismissals += 1 }
            try check(peek.present(url: url, in: host, websiteDataStore: store), "Peek rejected HTTP fixture")
            guard let original = peek.webView else { throw Failure(description: "Peek has no web view") }
            try check(wait(10) { original.title == "Preview lifecycle fixture" && !original.isLoading }, "Peek failed to load fixture")
            _ = try js(original, "window.__orbitCounter = 41; document.getElementById('entry').value = 'kept'; document.cookie='orbit_preview=shared; path=/'; window.__orbitCounter")
            peek.setVisible(false)
            try check(try js(original, "alert('hidden preview'); 'returned'") as? String == "returned", "Hidden preview dialog did not return")
            try check(window.attachedSheet == nil, "Hidden preview opened a page dialog")
            peek.setVisible(true)
            try check(peek.webView === original, "Hiding Peek replaced its web view")
            if CommandLine.arguments.count > 2, let downloadBase = URL(string: CommandLine.arguments[2]) {
                var downloads = 0
                peek.onDownload = { download in downloads += 1; download.cancel(nil) }
                original.load(URLRequest(url: downloadBase.appendingPathComponent("htmlattachment")))
                try check(wait(5) { downloads == 1 }, "Peek did not forward an attachment response download")
                try check(peek.isPresented && peek.webView === original, "Attachment download dismissed or replaced Peek")
                _ = try js(original, "var a=document.createElement('a'); a.href='\(downloadBase.appendingPathComponent("file").absoluteString)'; a.download='local.bin'; document.body.appendChild(a); a.click(); 'triggered'")
                try check(wait(5) { downloads == 2 }, "Peek did not forward a download navigation action")
                try check(peek.isPresented && peek.webView === original, "Action download dismissed or replaced Peek")
            }
            var promoted: WKWebView?
            peek.onPromote = { promoted = $0 }
            peek.promoteToTab()
            try check(promoted === original && !peek.isPresented && dismissals == 1, "Peek promotion did not detach the original view once")
            try check(original.navigationDelegate == nil && original.uiDelegate == nil, "Peek left its delegates installed after transfer")
            try check(try js(original, "window.__orbitCounter + ':' + document.getElementById('entry').value") as? String == "41:kept", "Promotion lost page state")
            let little = LittleBamController(websiteDataStore: store)
            little.adopt(webView: original)
            try check(little.webView === original, "Little Orbit recreated the adopted web view")
            if CommandLine.arguments.count > 2, let downloadBase = URL(string: CommandLine.arguments[2]) {
                var downloads = 0
                little.onDownload = { download in downloads += 1; download.cancel(nil) }
                try check(little.open(url: downloadBase.appendingPathComponent("unsupported")), "Little Orbit rejected local download URL")
                try check(wait(5) { downloads == 1 }, "Little Orbit did not forward unsupported MIME download")
                try check(little.webView === original, "Little Orbit download replaced its web view")
            }
            var littleCloseCount = 0
            var returned: WKWebView?
            little.onClose = { littleCloseCount += 1 }
            little.onPromote = { returned = $0 }
            little.promoteToOrbit()
            try check(returned === original && littleCloseCount == 1, "Little Orbit did not promote and close exactly once")
            try check(try js(original, "window.__orbitCounter + ':' + document.getElementById('entry').value") as? String == "41:kept", "Little Orbit promotion lost page state")
            little.close()
            try check(littleCloseCount == 1, "Repeated close repeated lifecycle callback")
            let second = PeekCoordinator()
            try check(second.present(url: url, in: host, websiteDataStore: store), "Second Peek rejected fixture")
            guard let cookieWeb = second.webView else { throw Failure(description: "Missing second Peek") }
            try check(wait(10) { cookieWeb.title == "Preview lifecycle fixture" && !cookieWeb.isLoading }, "Second Peek failed to load")
            try check((try js(cookieWeb, "document.cookie") as? String)?.contains("orbit_preview=shared") == true, "Shared website data store lost cookie")
            var splitWeb: WKWebView?
            second.onSplit = { splitWeb = $0 }
            second.setVisible(false)
            let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 200,height: 24))
            host.addSubview(field); window.makeFirstResponder(field)
            let focused = window.firstResponder
            second.openInSplitView()
            try check(window.firstResponder === focused, "Closing hidden Peek stole focus")
            try check(splitWeb === cookieWeb, "Split promotion recreated the page")
            try check(!PreviewURLPolicy.allows(URL(string:"javascript:alert(1)")!), "JavaScript URL allowed")
            try check(!PreviewURLPolicy.allows(URL(string:"file:///tmp/private")!), "File URL allowed")
            try check(!PreviewURLPolicy.allows(URL(string:"https://user:pass@example.com")!), "Credential URL allowed")
            try check(PreviewURLPolicy.resolveAddress("javascript:alert(1)") == nil, "Address field accepted external scheme")
            try check(PreviewURLPolicy.resolveAddress("example.com:8080/path")?.absoluteString == "https://example.com:8080/path", "Bare host and port were rejected")
            try check(PreviewURLPolicy.resolveAddress("mailto:alice@example.com") == nil, "Mail URL was treated as a web address")
            peek.dismiss(); second.dismiss(); window.close()
            original.stopLoading(); cookieWeb.stopLoading()
            print("PASS: Peek hide/reveal; same-view tab/split/Little Orbit promotion; DOM state; shared cookie; lifecycle cleanup; URL policy; optional native attachment/action/unsupported downloads")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
    static func js(_ web: WKWebView, _ script: String) throws -> Any? {
        var complete = false
        var value: Any?
        var error: Error?
        web.evaluateJavaScript(script) { result, failure in value = result; error = failure; complete = true }
        guard wait(5, until: { complete }) else { throw Failure(description: "JavaScript evaluation timed out") }
        if let error { throw error }
        return value
    }
}
