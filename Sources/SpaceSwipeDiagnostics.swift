import Foundation

/// Opt-in, bounded input diagnostics. This recorder never reads browser data.
/// `t` is seconds since recording began; `n` is a zero-based sequence number.
@MainActor final class SpaceSwipeDiagnostics {
    static let shared = SpaceSwipeDiagnostics()

    let outputURL: URL
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var lastError: String?

    private let writer = SpaceSwipeDiagnosticWriter()
    private let maximumDuration: TimeInterval
    private let maximumEvents: Int
    private let flushInterval: TimeInterval
    private var recordingID: UUID?
    private var latestID: UUID?
    private var startTime: TimeInterval = 0
    private var count = 0
    private var buffer = Data()
    private var flushTimer: Timer?
    private var stopTimer: Timer?

    private static let allowedKeys: Set<String> = [
        "kind", "phase", "momentum", "precise", "insideSidebar", "browserWindow",
        "eventWindowPresent", "rawPhase", "rawMomentumPhase", "deltaX", "deltaY",
        "pointX", "pointY", "space", "beforeSpace", "offset", "beforeOffset",
        "tracking", "beforeTracking", "consumed", "route", "didLock", "finished",
        "target", "releaseVelocity", "animationRunning", "sidebarWidth",
        "sidebarVisible", "overlay", "ignored", "rejected", "axis", "totalX",
        "totalY", "velocityX"
    ]
    private static let enumKeys: Set<String> = [
        "kind", "phase", "momentum", "route", "overlay", "ignored", "rejected", "axis"
    ]

    /// Directory and shorter limits can be injected by an isolated test harness.
    /// Callers cannot increase the production event, duration, or flush bounds.
    init(directory: URL? = nil, maximumDuration: TimeInterval = 60,
         maximumEvents: Int = 5_000, flushInterval: TimeInterval = 0.5) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        let folder = directory ?? caches.appendingPathComponent("Ark", isDirectory: true)
        outputURL = folder.appendingPathComponent("space-swipe-diagnostics.jsonl", isDirectory: false)
        self.maximumDuration = maximumDuration.isFinite ? min(60, max(0.01, maximumDuration)) : 60
        self.maximumEvents = min(5_000, max(1, maximumEvents))
        self.flushInterval = flushInterval.isFinite ? min(1, max(0.01, flushInterval)) : 0.5
    }

    /// Opens/truncates only the known diagnostic file, asynchronously. Capture
    /// starts after the writer confirms initialization; inspect lastError if it fails.
    func start() {
        stop()
        let id = UUID()
        recordingID = id; latestID = id
        isStarting = true; lastError = nil
        count = 0; buffer = Data()
        writer.open(outputURL, id: id, ready: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == id else { return }
                self.isStarting = false; self.isRecording = true
                self.startTime = ProcessInfo.processInfo.systemUptime
                let flush = Timer(timeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.recordingID == id else { return }
                        if ProcessInfo.processInfo.systemUptime - self.startTime >= self.maximumDuration { self.stop() }
                        else { self.flush(id: id) }
                    }
                }
                let deadline = Timer(timeInterval: self.maximumDuration, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.recordingID == id else { return }; self.stop()
                    }
                }
                self.flushTimer = flush; self.stopTimer = deadline
                RunLoop.main.add(flush, forMode: .common)
                RunLoop.main.add(deadline, forMode: .common)
                // A valid, idle recording is distinguishable from a failed open.
                // This marker counts toward the same hard 5,000-record ceiling.
                self.record(["kind": "started"])
            }
        }, failed: { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.latestID == id else { return }
                self.lastError = message
                if self.recordingID == id { self.stop() }
            }
        })
    }

    /// The autoclosure prevents payload allocation when disabled. Only known
    /// scalar diagnostic fields survive; no URLs, text, UUIDs or nested objects.
    func record(_ fields: @autoclosure () -> [String: Any]) {
        guard isRecording, let id = recordingID else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        guard elapsed >= 0, elapsed < maximumDuration, count < maximumEvents else { stop(); return }
        var event: [String: Any] = ["t": elapsed, "n": count]
        for (key, value) in fields() where Self.allowedKeys.contains(key) {
            if let number = value as? NSNumber, number.doubleValue.isFinite {
                event[key] = number
            } else if Self.enumKeys.contains(key), let token = value as? String, Self.isEnumToken(token) {
                event[key] = token
            }
        }
        guard event.count > 2,
              let line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              line.count <= 4_096 else { return }
        buffer.append(line); buffer.append(0x0A)
        count += 1
        if count == maximumEvents { stop() }
        // The small batch threshold also bounds memory during long tracking loops.
        else if buffer.count >= 64 * 1_024 { flush(id: id) }
    }

    /// Schedules the final batch and close in order; no disk work runs here.
    /// The file may finish flushing shortly after this method returns.
    func stop() {
        flushTimer?.invalidate(); flushTimer = nil
        stopTimer?.invalidate(); stopTimer = nil
        isRecording = false; isStarting = false
        guard let id = recordingID else { return }
        flush(id: id)
        recordingID = nil
        writer.close(id: id)
    }

    private func flush(id: UUID) {
        guard recordingID == id, !buffer.isEmpty else { return }
        let data = buffer
        buffer = Data()
        writer.append(data, id: id)
    }

    private static func isEnumToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard !bytes.isEmpty, bytes.count <= 48, UUID(uuidString: token) == nil,
              let first = bytes.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    deinit { flushTimer?.invalidate(); stopTimer?.invalidate() }
}

/// All file state is confined to this serial queue. UUIDs below are internal
/// cancellation tokens and are never serialized into the diagnostic file.
private final class SpaceSwipeDiagnosticWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Ark.SpaceSwipeDiagnostics.writer", qos: .utility)
    private var handle: FileHandle?
    private var activeID: UUID?
    private var failure: (@Sendable (String) -> Void)?

    func open(_ url: URL, id: UUID, ready: @escaping @Sendable () -> Void,
              failed: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            // start/stop/start may be queued before the first open completes.
            // FIFO ordering and token checks keep old batches out of the new file.
            try? handle?.close()
            handle = nil; activeID = id; failure = failed
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: url.path) {
                    let type = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                    guard type == .typeRegular else {
                        throw DiagnosticFileError(message: "The diagnostic path is not a regular file.")
                    }
                } else if !manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
                    throw DiagnosticFileError(message: "Could not create the diagnostic file.")
                }
                let opened = try FileHandle(forWritingTo: url)
                handle = opened
                try opened.truncate(atOffset: 0)
                ready()
            } catch { fail(error) }
        }
    }

    func append(_ data: Data, id: UUID) {
        queue.async { [self] in
            guard activeID == id, let handle else { return }
            do { try handle.write(contentsOf: data) }
            catch { fail(error) }
        }
    }

    func close(id: UUID) {
        queue.async { [self] in
            guard activeID == id else { return }
            do { try handle?.synchronize(); try handle?.close() }
            catch { fail(error); return }
            handle = nil; activeID = nil; failure = nil
        }
    }

    private func fail(_ error: Error) {
        let callback = failure
        try? handle?.close()
        handle = nil; activeID = nil; failure = nil
        callback?("Space swipe recording stopped: \(error.localizedDescription)")
    }

    private struct DiagnosticFileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
