import Foundation

/// Pure checks of the gesture probe's rules: configuration, loopback scoping and the install-review decision.
@main enum ExtensionGestureProbeRulesTests {
    nonisolated(unsafe) static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        guard ok else { fputs("FAIL: Extension gesture probe rules — \(message)\n", stderr); exit(1) }
        checks += 1
    }
    typealias R = ExtensionGestureProbeRules

    static func main() {
        // Click wait: default 40 s, may only be shortened, junk ignored.
        check(R.clickSeconds(nil) == 40 && R.clickSeconds("abc") == 40 && R.clickSeconds("0") == 40 && R.clickSeconds("-3") == 40,
              "missing, junk, zero and negative waits keep the default")
        check(R.clickSeconds("12") == 12 && R.clickSeconds(" 5.5 ") == 5.5, "a shorter wait is honoured")
        check(R.clickSeconds("90") == 40 && R.clickSeconds("inf") == 40, "a wait can't exceed 40 s")

        // Toolbar mode.
        check(R.toolbarMode(nil) == .button && R.toolbarMode("REAL") == .real && R.toolbarMode(" off ") == .off, "known toolbar modes")
        check(R.toolbarMode("pointer") == nil && R.toolbarMode("") == nil, "unknown toolbar modes are refused")

        // Loopback only.
        let page = URL(string: "http://127.0.0.1:8123/fixture/extension-test.html?x=1#frag")!
        check(R.isLoopback(page) && R.isLoopback(URL(string: "https://localhost/a")!) && R.isLoopback(URL(string: "http://[::1]:9/")!),
              "loopback pages are accepted")
        check(!R.isLoopback(URL(string: "http://example.com/")!) && !R.isLoopback(URL(string: "http://user:pw@127.0.0.1/")!)
              && !R.isLoopback(URL(string: "file:///tmp/x.html")!) && !R.isLoopback(URL(string: "http://127.0.0.2/")!),
              "non-loopback, credentialed, file and other 127/8 hosts are refused")
        check(R.matchPatterns(for: page) == ["http://127.0.0.1/*"], "match pattern is the page's scheme and host, any port")
        check(R.matchPatterns(for: URL(string: "http://[::1]:9/x")!) == ["http://[::1]/*"], "IPv6 loopback is bracketed")
        check(R.matchPatterns(for: URL(string: "https://example.com/")!).isEmpty, "no pattern for a non-loopback page")
        let probe = R.probeURL(page)
        check(probe?.absoluteString == "http://127.0.0.1:8123/fixture/extension-test.html?bam-gesture-probe=1",
              "probe URL keeps the page and port, with only the marker query and no fragment")
        check(R.probeURL(URL(string: "https://example.com/")!) == nil, "no probe URL off loopback")

        // Install review: loopback websites only, no API permissions, only Bam's own worker transport tolerated.
        let site = ["http://127.0.0.1/*"]
        check(R.allowsInstall(permissions: [], unsupported: [], websites: site, isOptional: false), "plain loopback install review approved")
        check(R.allowsInstall(permissions: [], unsupported: ["nativeMessaging"], websites: site, isOptional: false),
              "Bam's internal worker transport listed as unsupported is tolerated (never granted by the review)")
        check(!R.allowsInstall(permissions: ["alarms"], unsupported: [], websites: site, isOptional: false), "any API permission is refused")
        check(!R.allowsInstall(permissions: [], unsupported: ["sidePanel"], websites: site, isOptional: false), "other unsupported entries are refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: site, isOptional: true), "every optional review is refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: [], isOptional: false), "a review without the loopback site is refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: site + ["https://example.com/*"], isOptional: false),
              "any non-loopback website is refused")
        check(!R.allowsInstall(permissions: [], unsupported: [], websites: ["<all_urls>"], isOptional: false)
              && !R.allowsInstall(permissions: [], unsupported: [], websites: ["*://*/*"], isOptional: false)
              && !R.allowsInstall(permissions: [], unsupported: [], websites: ["http://127.0.0.1/private/*"], isOptional: false),
              "broad or path-narrowed patterns are refused")

        print("PASS: Extension gesture probe rules — \(checks) checks")
    }
}
