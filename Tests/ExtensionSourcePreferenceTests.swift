import Foundation

/// Add Extensions offers the Chrome Web Store build first and Firefox second, unless that build can't run in Bam.
@main struct ExtensionSourcePreferenceTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func main() {
        do { try run(); print("PASS: \(checks) extension source preference checks") }
        catch { print("FAIL: Extension source preference — \(error)"); exit(1) }
    }
    typealias Facts = ExtensionSourcePreference.Facts
    static func best(_ all: [Facts]) -> Facts? {
        all.first { candidate in all.allSatisfy { $0 == candidate || !ExtensionSourcePreference.prefers($0, over: candidate) } }
    }
    static func run() throws {
        let chrome = Facts(source: .chromeWebStore, canInstallInBam: true, failedInBamProbe: false, version: "2.0")
        let firefox = Facts(source: .amo, canInstallInBam: true, failedInBamProbe: false, version: "3.1")
        let safari = Facts(source: .safariAppStore, canInstallInBam: true, failedInBamProbe: false, version: "9.0")
        try check(best([firefox, safari, chrome]) == chrome, "The Chrome Web Store build was not the default")
        try check(best([safari, firefox]) == firefox, "Firefox Add-ons was not second")
        try check(ExtensionSourcePreference.prefers(chrome, over: firefox) && !ExtensionSourcePreference.prefers(firefox, over: chrome),
                  "The preference was not one-directional")
        // Working beats preferred: a build Bam can't install, or one Bam's probe saw fail, never wins.
        let chromeBlocked = Facts(source: .chromeWebStore, canInstallInBam: false, failedInBamProbe: false, version: "2.0")
        try check(best([chromeBlocked, firefox]) == firefox, "An uninstallable Chrome build won")
        let chromeFailed = Facts(source: .chromeWebStore, canInstallInBam: true, failedInBamProbe: true, version: "2.0")
        try check(best([chromeFailed, firefox]) == firefox, "A Chrome build that failed in Bam's probe won")
        // Same source: the newer version.
        let older = Facts(source: .chromeWebStore, canInstallInBam: true, failedInBamProbe: false, version: "1.9.12")
        try check(best([older, chrome]) == chrome && ExtensionSourcePreference.compareVersions("1.10", "1.9") == .orderedDescending,
                  "Versions were compared lexically")
        // Probe notes: failures are recognised, working observations are not.
        try check(ExtensionSourcePreference.isFailureNote("worker stopped at startup") && !ExtensionSourcePreference.isFailureNote("popup renders"),
                  "Probe notes were misread")
    }
}
