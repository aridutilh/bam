import AppKit
import WebKit

/// A loopback HTTP fixture supplies /file, /slow and /broken. All outputs stay in the supplied test directory.
/// Save-panel decisions are injected; this test never presents or automates a save panel.
@MainActor @main struct DownloadTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do {
            guard CommandLine.arguments.count == 3,
                  let base = URL(string: CommandLine.arguments[1]), base.host == "127.0.0.1" else {
                throw Failure(description: "Supply a loopback fixture URL and output directory")
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited); app.finishLaunching()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
            let output = directory.appendingPathComponent("success-\(UUID().uuidString).bin")
            let success = DownloadCoordinator(destinationChooser: { _, _, reply in reply(output) })
            try start(web, base.appendingPathComponent("file"), success)
            try check(wait(10) { success.snapshots.first?.status == .finished }, "Successful download did not finish: \(success.snapshots.first?.detail ?? "no record")")
            try check(try Data(contentsOf: output) == Data("Orbit local download fixture\n".utf8), "Downloaded contents differed")
            try check(success.activeCount == 0 && success.snapshots.first?.fractionCompleted == 1, "Completed download remained active")

            let collision = DownloadCoordinator(destinationChooser: { _, _, reply in reply(output) })
            try start(web, base.appendingPathComponent("file"), collision)
            try check(wait(5) { collision.snapshots.first?.status == .failed }, "Existing destination was not rejected")
            try check(try Data(contentsOf: output) == Data("Orbit local download fixture\n".utf8), "Existing file was overwritten")

            let cancelled = DownloadCoordinator(destinationChooser: { _, _, reply in reply(nil) })
            try start(web, base.appendingPathComponent("file"), cancelled)
            try check(wait(5) { cancelled.snapshots.first?.status == .cancelled }, "Cancelling destination choice did not cancel")
            try check(cancelled.activeCount == 0, "Cancelled chooser retained an active download")

            let slowOutput = directory.appendingPathComponent("slow-\(UUID().uuidString).bin")
            let slow = DownloadCoordinator(destinationChooser: { _, _, reply in reply(slowOutput) })
            try start(web, base.appendingPathComponent("slow"), slow)
            try check(wait(10) { (slow.snapshots.first?.completedBytes ?? 0) > 0 }, "Progress was not observed")
            try start(web, base.appendingPathComponent("file"), slow)
            try check(wait(5) { slow.snapshots.first?.status == .failed }, "Simultaneous destination collision was not rejected")
            slow.cancelAll()
            try check(slow.activeCount == 0 && slow.snapshots.contains(where: { $0.status == .cancelled }), "Cancel-all did not cancel the active transfer")
            try check(stagingFiles(directory).isEmpty, "Cancellation did not synchronously unlink its staging file")
            try check(wait(5) { stagingFiles(directory).isEmpty }, "Cancelled transfer left its staging file")
            try check(!FileManager.default.fileExists(atPath: slowOutput.path), "Cancelled transfer published an incomplete file")

            var delayedReply: ((URL?) -> Void)?
            let pending = DownloadCoordinator(destinationChooser: { _, _, reply in delayedReply = reply })
            try start(web, base.appendingPathComponent("file"), pending)
            try check(wait(5) { delayedReply != nil }, "Deferred destination chooser was not called")
            pending.cancelAll()
            delayedReply?(directory.appendingPathComponent("must-not-exist.bin"))
            try check(pending.activeCount == 0 && pending.snapshots.first?.status == .cancelled,
                      "Late destination choice revived a cancelled download")
            try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("must-not-exist.bin").path), "Cancelled destination choice wrote a file")

            let brokenOutput = directory.appendingPathComponent("broken-\(UUID().uuidString).bin")
            let broken = DownloadCoordinator(destinationChooser: { _, _, reply in reply(brokenOutput) })
            try start(web, base.appendingPathComponent("broken"), broken)
            try check(wait(10) { broken.snapshots.first?.status == .failed }, "Truncated response did not surface a download failure")
            try check(broken.activeCount == 0 && !FileManager.default.fileExists(atPath: brokenOutput.path), "Failed transfer published an incomplete file")

            // An external file appearing after Save must also remain untouched.
            let staged = directory.appendingPathComponent("atomic-stage-\(UUID().uuidString)")
            let occupied = directory.appendingPathComponent("atomic-existing-\(UUID().uuidString)")
            try Data("incoming".utf8).write(to: staged)
            try Data("keep me".utf8).write(to: occupied)
            var refused = false
            do { try DownloadCoordinator.finishFile(staging: staged, destination: occupied) } catch { refused = true }
            try check(refused && (try Data(contentsOf: occupied)) == Data("keep me".utf8), "Exclusive finalization overwrote an intervening file")
            try check(DownloadCoordinator.safeFilename("../../example.bin") == "example.bin", "Server filename escaped its directory")
            try check(DownloadCoordinator.safeFilename("..") == "Download", "Unsafe filename was not replaced")
            try check(stagingFiles(directory).isEmpty, "A completed or failed transfer left staging data")
            for url in [output, staged, occupied] { try FileManager.default.removeItem(at: url) }
            web.stopLoading()
            print("PASS: real WKDownload contents, progress, chooser cancellation, active cancellation/cleanup, failure reporting, existing/intervening collision protection, safe filenames")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1)
        }
    }
    static func start(_ web: WKWebView, _ url: URL, _ coordinator: DownloadCoordinator) throws {
        var started = false
        web.startDownload(using: URLRequest(url: url)) { download in
            coordinator.start(download: download, suggestedURL: url)
            started = true
        }
        try check(wait(5) { started }, "WKWebView did not create the download")
    }
    static func stagingFiles(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".orbit-") }
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
}
