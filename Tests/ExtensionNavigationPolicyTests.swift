import Foundation

/// Which extension pages a website may open in the top frame (Chrome's web_accessible_resources rule).
@main struct ExtensionNavigationPolicyTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func main() {
        do { try run(); print("PASS: \(checks) extension navigation policy checks") }
        catch { print("FAIL: Extension navigation policy — \(error)"); exit(1) }
    }
    typealias P = ExtensionNavigationPolicy
    static func run() throws {
        let page = URL(string: "webkit-extension://4f2a9c11-0000-0000-0000-000000000001/options.html")!
        let shared = URL(string: "webkit-extension://4f2a9c11-0000-0000-0000-000000000001/public/viewer.html")!
        let site = P.Origin(scheme: "https", host: "news.example.com")
        let other = P.Origin(scheme: "https", host: "evil.test")

        // No manifest entry: nothing is reachable from a website.
        try check(!P.allowsWebInitiated(target: page, initiator: site, manifest: ["manifest_version": 3]), "page opened without web_accessible_resources")
        try check(!P.allowsWebInitiated(target: page, initiator: site, manifest: nil), "page opened without a manifest")

        // The extension opening its own page is always fine.
        let own = P.Origin(scheme: "webkit-extension", host: "4f2a9c11-0000-0000-0000-000000000001")
        try check(P.allowsWebInitiated(target: page, initiator: own, manifest: nil), "extension could not open its own page")
        try check(!P.allowsWebInitiated(target: page, initiator: P.Origin(scheme: "webkit-extension", host: "another"), manifest: nil),
                  "a different extension opened the page")
        try check(!P.allowsWebInitiated(target: page, initiator: P.Origin(scheme: "safari-web-extension", host: own.host), manifest: nil),
                  "a different scheme with the same host counted as the same extension")

        // Manifest V3: resources + matches.
        let v3: [String: Any] = ["manifest_version": 3, "web_accessible_resources": [
            ["resources": ["public/*", "icon.png"], "matches": ["https://*.example.com/*"]],
            ["resources": ["everyone.html"], "matches": ["<all_urls>"]],
            ["resources": ["ext-only.html"], "extension_ids": ["*"]]
        ]]
        try check(P.allowsWebInitiated(target: shared, initiator: site, manifest: v3), "shared resource refused for a matching site")
        try check(!P.allowsWebInitiated(target: shared, initiator: other, manifest: v3), "shared resource opened for a site outside matches")
        try check(!P.allowsWebInitiated(target: page, initiator: site, manifest: v3), "unlisted options page opened from a matching site")
        try check(P.isWebAccessible(path: "/everyone.html", from: other, manifest: v3), "<all_urls> resource refused")
        try check(!P.isWebAccessible(path: "/everyone.html", from: nil, manifest: v3), "opaque origin matched <all_urls>")
        try check(!P.isWebAccessible(path: "/ext-only.html", from: site, manifest: v3), "extension_ids-only resource opened for a website")
        try check(P.isWebAccessible(path: "/icon.png", from: P.Origin(scheme: "https", host: "example.com"), manifest: v3),
                  "*.example.com did not include example.com itself")
        try check(!P.isWebAccessible(path: "/icon.png", from: P.Origin(scheme: "http", host: "example.com"), manifest: v3),
                  "https-only pattern matched http")
        try check(!P.isWebAccessible(path: "/icon.png", from: P.Origin(scheme: "https", host: "notexample.com"), manifest: v3),
                  "suffix without a dot matched *.example.com")

        // Paths can't climb out of a shared folder.
        try check(!P.isWebAccessible(path: "/public/../options.html", from: site, manifest: v3), "'..' escaped the shared folder")
        try check(!P.isWebAccessible(path: "/public/%2E%2E/options.html", from: site, manifest: v3), "encoded '..' escaped the shared folder")
        try check(P.isWebAccessible(path: "//public//viewer.html", from: site, manifest: v3), "extra slashes broke a legitimate path")

        // Manifest V2: a flat list, open to every site.
        let v2: [String: Any] = ["manifest_version": 2, "web_accessible_resources": ["pages/*.html", "/img/logo.png"]]
        try check(P.isWebAccessible(path: "/pages/a.html", from: other, manifest: v2), "V2 shared page refused")
        try check(P.isWebAccessible(path: "/img/logo.png", from: other, manifest: v2), "V2 leading-slash pattern refused")
        try check(!P.isWebAccessible(path: "/options.html", from: other, manifest: v2), "V2 unlisted page opened")

        // Match patterns.
        try check(P.originMatches(P.Origin(scheme: "http", host: "a.b"), pattern: "*://*/*"), "*://*/* missed http")
        try check(!P.originMatches(P.Origin(scheme: "ftp", host: "a.b"), pattern: "*://*/*"), "*://*/* matched ftp")
        try check(P.originMatches(P.Origin(scheme: "https", host: "x.test", port: 8443), pattern: "https://x.test:8443/*"), "explicit port refused")
        try check(!P.originMatches(P.Origin(scheme: "https", host: "x.test", port: 8443), pattern: "https://x.test:443/*"), "wrong port matched")
        try check(P.originMatches(P.Origin(scheme: "https", host: "x.test"), pattern: "https://x.test:443/*"), "default port not applied")
        try check(P.resourceMatches("a/b/c.js", pattern: "a/*"), "* did not span folders")
        try check(!P.resourceMatches("b/a.js", pattern: "a/*"), "pattern matched a different folder")
    }
}
