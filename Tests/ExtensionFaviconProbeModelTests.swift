import Foundation

/// The favicon routing probe's classification: intercepted, not intercepted (complete negative), or incomplete.
@main struct ExtensionFaviconProbeModelTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension favicon probe model — \(try run()) checks") }
        catch { fputs("FAIL: Extension favicon probe model: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias M = ExtensionFaviconProbeModel
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        let ready: [String: Any] = ["ready": true, "listener": true], control: [String: Any] = ["status": 200, "body": M.controlBody]
        func report(fetch: [String: Any], seen: [String]) -> [String: Any] {
            ["ready": ready, "control": control, "fetch": fetch, "img": ["loaded": true], "seen": ["seen": seen.map { ["path": $0] }]]
        }
        let answered: [String: Any] = ["status": 200, "probe": "worker", "body": "<svg><desc>\(M.marker)</desc></svg>"]
        try check(M.classify(report(fetch: answered, seen: ["/control.txt", "/_favicon/"]), contextRecordedFaviconError: false).0 == .intercepted, "A worker answer was not classified as intercepted")
        let failed: [String: Any] = ["error": "TypeError: Load failed"]
        try check(M.classify(report(fetch: failed, seen: []), contextRecordedFaviconError: true).0 == .notIntercepted, "A complete native failure was not a negative")
        try check(M.classify(nil, contextRecordedFaviconError: false).0 == .incomplete, "A missing report was not incomplete")
        var notReady = report(fetch: failed, seen: []); notReady["ready"] = ["error": "no receiver"]
        try check(M.classify(notReady, contextRecordedFaviconError: true).0 == .incomplete, "A missing ready acknowledgement was treated as negative")
        var badControl = report(fetch: failed, seen: []); badControl["control"] = ["status": 404, "body": ""]
        try check(M.classify(badControl, contextRecordedFaviconError: true).0 == .incomplete, "A failed control was treated as a result")
        var missingImage = report(fetch: answered, seen: ["/_favicon/"]); missingImage.removeValue(forKey: "img")
        try check(M.classify(missingImage, contextRecordedFaviconError: false).0 == .incomplete, "A missing image record was not incomplete")
        try check(M.classify(report(fetch: answered, seen: []), contextRecordedFaviconError: false).0 == .incomplete &&
                  M.classify(report(fetch: ["status": 200, "body": "packaged file"], seen: ["/_favicon/"]), contextRecordedFaviconError: false).0 == .incomplete,
                  "Inconsistent worker records were not incomplete (a packaged fallback must not count as interception)")
        // Records must be terminal and valid: a worker error, an image timeout or empty record, an empty fetch are incomplete.
        var workerError = report(fetch: failed, seen: []); workerError["seen"] = ["error": "Could not establish connection"]
        var imageTimeout = report(fetch: failed, seen: []); imageTimeout["img"] = ["timeout": true]
        var imageEmpty = report(fetch: failed, seen: []); imageEmpty["img"] = [String: Any]()
        var fetchEmpty = report(fetch: [:], seen: [])
        fetchEmpty["fetch"] = [String: Any]()
        try check([workerError, imageTimeout, imageEmpty, fetchEmpty].allSatisfy { M.classify($0, contextRecordedFaviconError: true).0 == .incomplete },
                  "A worker error, image timeout/empty record or empty fetch counted as a result")
        var imageError = report(fetch: failed, seen: []); imageError["img"] = ["error": true]
        try check(M.classify(imageError, contextRecordedFaviconError: true).0 == .notIntercepted, "A terminal image error with complete records was not a negative")
        // The negative claims WebKit's own lookup only when its matching error was observed.
        let withError = M.classify(report(fetch: failed, seen: []), contextRecordedFaviconError: true).1
        let withoutError = M.classify(report(fetch: failed, seen: []), contextRecordedFaviconError: false)
        try check(withError.contains("resource-lookup error") && withoutError.0 == .notIntercepted && withoutError.1.contains("not observed") && !withoutError.1.contains("resource-lookup"),
                  "The negative overclaimed WebKit's resource lookup: \(withoutError.1)")
        return checks
    }
}
