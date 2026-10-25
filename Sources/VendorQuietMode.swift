import Foundation

/// Pure policy for the vendor probe's opt-in quiet mode (`BAM_VENDOR_QUIET=1`): the same install, grants, cleanup and
/// canonical identity, but no host-initiated JavaScript evaluation of any page or extension document, no action
/// invocation and no options-page fallback, so a person's own real input can be observed without probe interference.
/// Quiet mode measures nothing about the profile: it never reports `completed` (no normal-profile or compatibility
/// claim), only a distinct `quiet-unmeasured` status when the interval finished and cleanup was clean.
enum VendorQuietMode {
    static let flag = "BAM_VENDOR_QUIET"

    enum Decision: Equatable { case off, on, invalid(String) }
    /// Absent or `0` keeps today's default; `1` is quiet; anything else is refused. Quiet refuses operator-supplied probe
    /// scripts outright rather than silently ignoring them, since both evaluate JavaScript.
    static func decide(_ raw: String?, siteProbe: String?, backgroundProbe: String?) -> Decision {
        guard let raw else { return .off }
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "0": return .off
        case "1":
            if siteProbe?.isEmpty == false || backgroundProbe?.isEmpty == false {
                return .invalid("\(flag)=1 cannot run BAM_VENDOR_SITE_PROBE or BAM_VENDOR_BG_PROBE (both evaluate JavaScript); unset them")
            }
            return .on
        default: return .invalid("\(flag) must be 1 (quiet) or 0/absent (default)")
        }
    }

    /// What the probe may do during the run. Default mode is exactly today's behavior.
    struct Plan: Equatable {
        var invokeAction: Bool
        var openFallbackPage: Bool
        var sampleSite: Bool
        var samplePages: Bool
        var backgroundProbe: Bool
        var documentModeMeasurement: Bool
        /// When false, the probe turns the browser's own document favicon discovery off before any page load.
        var faviconDocumentDiscovery: Bool
        /// When false, the probe turns automatic tab sleeping (and its page activity inspection) off before any load.
        var automaticTabSleeping: Bool
        var responderSnapshots: Bool
        /// `WKWebExtension.Action.popupPopover` / `popupWebView` are factory getters: reading either creates the popup
        /// web view and loads it (WebKit WebExtensionActionCocoa). Quiet never reads them; `presentsPopup` is metadata only.
        var readPopupGetters: Bool
        /// Any host-initiated page or extension-document evaluation the plan permits.
        var hostEvaluations: Bool { sampleSite || samplePages || backgroundProbe || documentModeMeasurement || faviconDocumentDiscovery || automaticTabSleeping }
    }
    static func plan(quiet: Bool) -> Plan {
        quiet
            ? Plan(invokeAction: false, openFallbackPage: false, sampleSite: false, samplePages: false, backgroundProbe: false,
                   documentModeMeasurement: false, faviconDocumentDiscovery: false, automaticTabSleeping: false, responderSnapshots: true,
                   readPopupGetters: false)
            : Plan(invokeAction: true, openFallbackPage: true, sampleSite: true, samplePages: true, backgroundProbe: true,
                   documentModeMeasurement: true, faviconDocumentDiscovery: true, automaticTabSleeping: true, responderSnapshots: false,
                   readPopupGetters: true)
    }

    enum Status: String { case completed, quietUnmeasured = "quiet-unmeasured", failed }
    struct Result: Equatable { let status: Status; let completed: Bool; let exitCode: Int32 }
    /// Default mode: exactly the existing rule (`success` already includes the strict normal-profile verdict and cleanup):
    /// completed with exit 0, otherwise failed with exit 1. Quiet mode: never completed. A finished interval with clean
    /// cleanup is `quiet-unmeasured` with exit 3; anything else failed with exit 1.
    static func result(quiet: Bool, success: Bool, quietIntervalClean: Bool) -> Result {
        guard quiet else { return success ? Result(status: .completed, completed: true, exitCode: 0) : Result(status: .failed, completed: false, exitCode: 1) }
        return quietIntervalClean ? Result(status: .quietUnmeasured, completed: false, exitCode: 3) : Result(status: .failed, completed: false, exitCode: 1)
    }
    static let quietUnmeasuredText = "quiet mode: no host JavaScript evaluation, action invocation or options fallback; normal-profile semantics and compatibility unmeasured"
    /// Native-only snapshots (key window, first-responder class): bounded, no page or personal text.
    static let maximumResponderSnapshots = 150
    static let responderSnapshotSeconds: TimeInterval = 1
}
