import Foundation

/// Classifies the `_favicon/` service-worker routing measurement. Measurement only: it says which mechanism was
/// observed, never that Bam supports Chrome's favicon API.
enum ExtensionFaviconProbeModel {
    /// The worker's deterministic answer, distinguishable from any packaged file or WebKit failure.
    static let marker = "bam-probe-favicon-7d2c"
    static let controlBody = "bam-probe-control-packaged"

    enum Outcome: String, Equatable {
        /// The worker's fetch listener answered the page's own-origin `_favicon/` request.
        case intercepted
        /// Every required record completed, and the request reached WebKit's resource lookup instead.
        case notIntercepted
        /// A required step is missing (no ready acknowledgement, no page report, control failed): no conclusion.
        case incomplete
    }

    /// `report` is the page's JSON report; `contextRecordedFaviconError` is whether WebKit recorded its
    /// "Unable to find _favicon/" error on the probe's context during the measurement.
    static func classify(_ report: [String: Any]?, contextRecordedFaviconError: Bool) -> (Outcome, String) {
        guard let report else { return (.incomplete, "No page report arrived.") }
        guard (report["ready"] as? [String: Any])?["ready"] as? Bool == true else {
            return (.incomplete, "The worker never acknowledged that its fetch listener was installed.")
        }
        let control = report["control"] as? [String: Any]
        guard control?["status"] as? Int == 200, control?["body"] as? String == controlBody else {
            return (.incomplete, "The ordinary packaged control resource did not load, so the page's loading was not established.")
        }
        // Every record must be terminal: the worker's list of seen requests (not an error), a finished fetch (status or
        // error) and a finished image (load or error; a timeout or empty record is not a result).
        guard let seenRecords = (report["seen"] as? [String: Any])?["seen"] as? [[String: Any]] else {
            return (.incomplete, "The worker did not return its list of observed requests.")
        }
        guard let fetch = report["fetch"] as? [String: Any], fetch["status"] is Int || fetch["error"] is String else {
            return (.incomplete, "The page's fetch did not reach a terminal outcome.")
        }
        guard let image = report["img"] as? [String: Any], image["loaded"] as? Bool == true || image["error"] as? Bool == true else {
            return (.incomplete, "The image did not reach a terminal load or error (timeout or missing record).")
        }
        let workerAnswered = fetch["status"] as? Int == 200 && fetch["probe"] as? String == "worker" && (fetch["body"] as? String)?.contains(marker) == true
        let workerSaw = seenRecords.contains { $0["path"] as? String == "/_favicon/" }
        if workerAnswered && workerSaw {
            return (.intercepted, "The worker's fetch listener saw and answered the page's _favicon/ request" + (contextRecordedFaviconError ? ", but WebKit also recorded a context error." : "."))
        }
        if !workerAnswered && !workerSaw {
            // Only the absence of a worker hit is established; WebKit's own lookup is claimed only when its error was seen.
            return (.notIntercepted, contextRecordedFaviconError
                ? "The worker never saw the _favicon/ request, and WebKit recorded its _favicon resource-lookup error."
                : "The worker never saw the _favicon/ request; how WebKit handled it was not observed (no matching context error).")
        }
        return (.incomplete, "Inconsistent records: worker saw _favicon/ = \(workerSaw), worker answer received = \(workerAnswered).")
    }
}
