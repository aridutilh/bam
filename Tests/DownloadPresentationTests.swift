import Foundation

/// What Bam's download list and grid say about each download, and which actions they offer.
@main struct DownloadPresentationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func main() {
        do { try run(); print("PASS: \(checks) download presentation checks") }
        catch { print("FAIL: Download presentation — \(error)"); exit(1) }
    }
    static func item(_ name: String, _ status: DownloadStatus, detail: String, fraction: Double? = nil, completed: Int64 = 0, total: Int64 = -1,
                     destination: URL? = nil, ended: Date? = nil) -> DownloadSnapshot {
        DownloadSnapshot(id: UUID(), filename: name, sourceURL: URL(string: "https://example.com/\(name)"), destinationURL: destination,
                         status: status, detail: detail, fractionCompleted: fraction, completedBytes: completed, totalBytes: total, endedAt: ended)
    }
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        let file = URL(fileURLWithPath: "/tmp/report.pdf")

        // Unfinished: live progress, Cancel only.
        let active = DownloadPresentation.row(item("report.pdf", .downloading, detail: "1 MB of 4 MB", fraction: 0.257, completed: 1_000_000, total: 4_000_000), now: now)
        try check(active.subtitle == "1 MB of 4 MB · 25%" && active.showsProgress && active.fraction == 0.257, "Progress was not shown: \(active)")
        try check(active.canCancel && !active.canOpen && !active.canReveal && !active.isProblem, "An unfinished download offered the wrong actions")
        let unknown = DownloadPresentation.row(item("stream.bin", .downloading, detail: "3 MB downloaded"), now: now)
        try check(unknown.subtitle == "3 MB downloaded" && unknown.showsProgress && unknown.fraction == nil, "Unknown-length progress was misreported")
        let choosing = DownloadPresentation.row(item("a.zip", .choosingDestination, detail: "Choose where to save"), now: now)
        try check(choosing.subtitle == "Choose where to save" && choosing.canCancel, "Choosing a destination was not cancellable")

        // Finished: size and when, Open and Show in Finder, no Cancel.
        let done = DownloadPresentation.row(item("report.pdf", .finished, detail: "Finished", fraction: 1, completed: 4_000_000, total: 4_000_000,
                                                 destination: file, ended: now.addingTimeInterval(-8 * 60)), now: now, locale: english)
        try check(done.subtitle == "\(ByteCountFormatter.string(fromByteCount: 4_000_000, countStyle: .file)) · 8 minutes ago", "Finished subtitle was \(done.subtitle)")
        try check(done.canOpen && done.canReveal && !done.canCancel && !done.showsProgress && done.fraction == nil, "A finished download offered the wrong actions")
        try check(DownloadPresentation.relativeTime(now.addingTimeInterval(-10), now: now) == "Just now", "A fresh finish was not 'Just now'")
        try check(done.accessibilityLabel.hasPrefix("report.pdf, "), "The accessible name did not lead with the file name")

        // A finished file that has gone missing reads as a problem, not a size.
        let moved = DownloadPresentation.row(item("report.pdf", .finished, detail: "The downloaded file has moved or been removed.", destination: file, ended: now), now: now)
        try check(moved.isProblem && moved.subtitle.contains("moved"), "A moved file was not reported")

        // Failed and cancelled: no file actions.
        let failed = DownloadPresentation.row(item("x.dmg", .failed, detail: "The network connection was lost."), now: now)
        try check(failed.isProblem && failed.subtitle == "The network connection was lost." && !failed.canOpen && !failed.canCancel, "A failure was misreported")
        let cancelled = DownloadPresentation.row(item("x.dmg", .cancelled, detail: "Cancelled", ended: now), now: now)
        try check(cancelled.subtitle == "Cancelled" && !cancelled.isProblem && !cancelled.canOpen && !cancelled.canReveal, "A cancellation was misreported")

        // Compact list: unfinished first, then most recent; the rest is counted for Show All.
        let finished = (0..<6).map { item("f\($0)", .finished, detail: "Finished", destination: file, ended: now) }
        let running = item("live", .downloading, detail: "…")
        let compact = DownloadPresentation.compact(finished + [running])
        try check(compact.shown.first?.filename == "live" && compact.shown.count == DownloadPresentation.compactLimit && compact.more == 2,
                  "Compact ordering or overflow was wrong: \(compact.shown.map(\.filename)) more=\(compact.more)")
        try check(compact.shown.dropFirst().map(\.filename) == ["f0", "f1", "f2", "f3"], "Finished items lost their newest-first order")
        try check(DownloadPresentation.compact([]).shown.isEmpty && DownloadPresentation.compact([]).more == 0, "An empty list was not empty")
        try check(DownloadPresentation.showAllTitle(more: 2) == "Show All (2 more)" && DownloadPresentation.showAllTitle(more: 0) == "Show All", "Show All title was wrong")
    }
}
