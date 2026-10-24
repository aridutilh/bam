import Foundation

/// Main-thread callers hand off a value snapshot without encoding it. There is
/// one serial writer per session file; pending snapshots coalesce to the newest.
@MainActor final class SessionWriter {
    typealias Write = @Sendable (BrowserSession, URL) throws -> Void
    var onError: ((Error) -> Void)?
    private let worker: Worker

    init(url: URL, write: @escaping Write = { try SessionFile.save($0, to: $1) }) {
        worker = Worker(url: url, write: write)
        worker.setErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in self?.onError?(error) }
        }
    }

    /// BrowserSession contains value types. Copying it here preserves its COW
    /// arrays/dictionaries; JSON encoding and atomic replacement happen off-main.
    func enqueue(_ snapshot: BrowserSession) { worker.enqueue(snapshot) }

    /// Recheck on MainActor after an async flush, before allowing termination:
    /// UI edits may have submitted a newer snapshot while the caller was waiting.
    var isLatestSnapshotSaved: Bool { worker.isLatestSnapshotSaved }

    /// Wait only for revisions already submitted at entry, without servicing the
    /// main run loop. Returns false on timeout or a failed latest write. A timeout
    /// does not cancel the worker; normal termination may then end the process.
    /// Call after enqueueing the final snapshot, not from the writer closure.
    @discardableResult func flush(timeout: TimeInterval = 2) -> Bool { worker.flush(timeout: timeout) }

    /// For applicationShouldTerminate's terminateLater path: wait off-main while
    /// the app remains responsive. This captures the revision before suspension.
    func flushAsync(timeout: TimeInterval = 2) async -> Bool {
        let worker = worker
        let target = worker.currentRevision()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: worker.flush(timeout: timeout, target: target))
            }
        }
    }

    /// All mutable bookkeeping is condition-protected. Snapshot ownership moves
    /// from pending to the serial worker before it is read by the injected writer.
    private final class Worker: @unchecked Sendable {
        private struct Pending { let revision: UInt64; let snapshot: BrowserSession }
        private let queue = DispatchQueue(label: "com.ari.orbitprototype.session-writer", qos: .utility)
        private let condition = NSCondition()
        private let url: URL
        private let write: Write
        private var errorHandler: (@Sendable (Error) -> Void)?
        private var pending: Pending?
        private var draining = false
        private var submitted: UInt64 = 0
        private var completed: UInt64 = 0
        private var succeeded: UInt64 = 0

        init(url: URL, write: @escaping Write) { self.url = url; self.write = write }
        func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
            condition.lock(); errorHandler = handler; condition.unlock()
        }
        func enqueue(_ snapshot: BrowserSession) {
            condition.lock()
            submitted += 1
            pending = Pending(revision: submitted, snapshot: snapshot)
            let start = !draining
            draining = true
            condition.unlock()
            if start { queue.async { self.drain() } }
        }
        var isLatestSnapshotSaved: Bool {
            condition.lock(); defer { condition.unlock() }; return succeeded >= submitted
        }
        func currentRevision() -> UInt64 {
            condition.lock(); defer { condition.unlock() }; return submitted
        }
        func flush(timeout: TimeInterval, target requested: UInt64? = nil) -> Bool {
            let interval = timeout.isFinite ? max(0, timeout) : 0
            let deadline = Date(timeIntervalSinceNow: interval)
            condition.lock()
            defer { condition.unlock() }
            let target = requested ?? submitted
            while completed < target {
                if !condition.wait(until: deadline) { return completed >= target && succeeded >= target }
            }
            return succeeded >= target
        }
        private func drain() {
            while true {
                condition.lock()
                guard let work = pending else {
                    draining = false
                    condition.unlock()
                    return
                }
                pending = nil
                condition.unlock()
                var failure: Error?
                // Release encoder/data temporaries after each atomic write,
                // rather than retaining them for an entire burst of changes.
                autoreleasepool {
                    do { try write(work.snapshot, url) }
                    catch { failure = error }
                }
                condition.lock()
                completed = work.revision
                if failure == nil { succeeded = work.revision }
                let handler = errorHandler
                condition.broadcast()
                condition.unlock()
                if let failure { handler?(failure) }
            }
        }
    }
}
