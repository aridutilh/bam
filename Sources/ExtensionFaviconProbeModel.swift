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
        guard report["seen"] is [String: Any], report["fetch"] is [String: Any], report["img"] is [String: Any] else {
            return (.incomplete, "A required record (worker observations, fetch or image result) is missing.")
        }
        let fetch = report["fetch"] as? [String: Any] ?? [:]
        let workerAnswered = fetch["status"] as? Int == 200 && fetch["probe"] as? String == "worker" && (fetch["body"] as? String)?.contains(marker) == true
        let seenPaths = ((report["seen"] as? [String: Any])?["seen"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let workerSaw = seenPaths.contains("/_favicon/")
        if workerAnswered && workerSaw {
            return (.intercepted, "The worker's fetch listener saw and answered the page's _favicon/ request" + (contextRecordedFaviconError ? ", but WebKit also recorded a context error." : "."))
        }
        if !workerAnswered && !workerSaw {
            return (.notIntercepted, "The worker never saw the _favicon/ request; it reached WebKit's resource lookup" + (contextRecordedFaviconError ? " (context error recorded)." : " (no context error recorded)."))
        }
        return (.incomplete, "Inconsistent records: worker saw _favicon/ = \(workerSaw), worker answer received = \(workerAnswered).")
    }
}
