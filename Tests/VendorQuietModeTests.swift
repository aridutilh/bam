import Foundation

/// Pure checks of the vendor probe's quiet-mode policy, and that quiet runs can never become a normal-profile claim under
/// the unchanged strict classifier.
@main enum VendorQuietModeTests {
    nonisolated(unsafe) static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        guard ok else { fputs("FAIL: Vendor quiet mode — \(message)\n", stderr); exit(1) }
        checks += 1
    }
    typealias Q = VendorQuietMode

    static func main() {
        // Flag: off, on, invalid; conflicting operator probe scripts are refused, not ignored.
        check(Q.decide(nil, siteProbe: nil, backgroundProbe: nil) == .off && Q.decide("0", siteProbe: nil, backgroundProbe: nil) == .off, "absent or 0 is off")
        check(Q.decide("1", siteProbe: nil, backgroundProbe: nil) == .on && Q.decide(" 1 ", siteProbe: "", backgroundProbe: "") == .on, "1 is quiet")
        for raw in ["", "true", "yes", "2", "on", "1 1"] {
            if case .invalid = Q.decide(raw, siteProbe: nil, backgroundProbe: nil) {} else { check(false, "'\(raw)' must be refused") }
            checks += 1
        }
        if case .invalid = Q.decide("1", siteProbe: "document.title", backgroundProbe: nil) {} else { check(false, "quiet with a site probe script is refused") }
        checks += 1
        if case .invalid = Q.decide("1", siteProbe: nil, backgroundProbe: "1+1") {} else { check(false, "quiet with a background probe script is refused") }
        checks += 1
        check(Q.decide("0", siteProbe: "document.title", backgroundProbe: "1+1") == .off, "default mode keeps accepting operator probes as today")

        // Plans: default is today's behavior; quiet permits no host-initiated evaluation, action or fallback.
        let normal = Q.plan(quiet: false), quiet = Q.plan(quiet: true)
        check(normal.invokeAction && normal.openFallbackPage && normal.sampleSite && normal.samplePages && normal.backgroundProbe
              && normal.documentModeMeasurement && normal.faviconDocumentDiscovery && normal.automaticTabSleeping && !normal.responderSnapshots,
              "the default plan is unchanged")
        check(!quiet.invokeAction && !quiet.openFallbackPage, "quiet: no action invocation, no options fallback")
        check(!quiet.sampleSite && !quiet.samplePages && !quiet.backgroundProbe && !quiet.documentModeMeasurement, "quiet: no probe evaluation of any page or document")
        check(!quiet.faviconDocumentDiscovery && !quiet.automaticTabSleeping, "quiet: the browser's own automatic evaluations are off")
        check(!quiet.hostEvaluations && normal.hostEvaluations, "quiet permits no host evaluation at all")
        check(quiet.responderSnapshots && Q.maximumResponderSnapshots <= 150, "quiet: bounded native responder snapshots")
        check(!quiet.readPopupGetters && normal.readPopupGetters,
              "quiet never reads the popup factory getters (popupPopover/popupWebView create and load the popup); default still does")

        // Results: default unchanged; quiet never completed, a clean interval is distinct (exit 3), anything else failed.
        check(Q.result(quiet: false, success: true, quietIntervalClean: true) == Q.Result(status: .completed, completed: true, exitCode: 0), "default success")
        check(Q.result(quiet: false, success: false, quietIntervalClean: true) == Q.Result(status: .failed, completed: false, exitCode: 1), "default failure")
        check(Q.result(quiet: true, success: false, quietIntervalClean: true) == Q.Result(status: .quietUnmeasured, completed: false, exitCode: 3),
              "quiet clean interval is quiet-unmeasured, never completed")
        check(Q.result(quiet: true, success: true, quietIntervalClean: true).completed == false, "quiet is never completed, even if success were true")
        check(Q.result(quiet: true, success: false, quietIntervalClean: false) == Q.Result(status: .failed, completed: false, exitCode: 1),
              "quiet with unclean cleanup or an unfinished interval fails")
        check(Q.Status.quietUnmeasured.rawValue == "quiet-unmeasured" && Q.result(quiet: true, success: false, quietIntervalClean: true).exitCode != 0,
              "quiet output can't be mistaken for a completed run")

        // The strict classifier is unchanged: a quiet run measures no document, so it is unmeasured, never normal.
        let verdict = VendorProbeIsolation.verdict(rounds: [], controllerConfigurationPersistent: false, openedStores: [UUID()],
                                                   expectedStore: UUID(), refusedProfiles: [])
        if case .normal = verdict { check(false, "a quiet run must never be classified normal") }
        let store = UUID()
        check(VendorProbeIsolation.verdict(rounds: [], controllerConfigurationPersistent: false, openedStores: [store], expectedStore: store, refusedProfiles: [])
              == .unmeasured("no extension document was measured"), "with no measurement rounds the strict classifier says unmeasured")
        check(Q.quietUnmeasuredText.contains("unmeasured") && !Q.quietUnmeasuredText.lowercased().contains("pass"), "the quiet text claims nothing")

        print("PASS: Vendor quiet mode — \(checks) checks")
    }
}
