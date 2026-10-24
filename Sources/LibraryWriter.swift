import Foundation

/// Only value metadata crosses to the worker. COW arrays are never mutated there.
struct LibrarySnapshot: Codable, @unchecked Sendable {
    var version = 1
    var history: [BrowserHistoryEntry]
    var closedRecords: [ClosedRecord]
}

/// One ordered writer per library. Visits coalesce to one pending snapshot;
/// explicit archive/clear operations wait for their exact atomic replacement.
final class LibraryWriter: @unchecked Sendable {
    typealias Write = @Sendable (LibrarySnapshot, URL) throws -> Void
    struct Completion {
        let revision: UInt64
        let error: Error?
    }
    private struct Work {
        let revision: UInt64
        let snapshot: LibrarySnapshot
    }
    private let queue = DispatchQueue(label: "com.ari.orbitprototype.library-writer", qos: .utility)
    private let condition = NSCondition()
    private let url: URL
    private let write: Write
    private var latest: Work?
    private var pending: Work?
    private var writing: UInt64?
    private var draining = false
    private var submitted: UInt64 = 0
    private var completed: UInt64 = 0
    private var succeeded: UInt64 = 0
    private var lastCompletion: Completion?
    private var completionHandler: (@Sendable (Completion) -> Void)?

    init(url: URL, write: @escaping Write = { try LibraryWriter.writeFile($0, to: $1) }) {
        self.url = url; self.write = write
    }
    static func writeFile(_ snapshot: LibrarySnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
    func setCompletionHandler(_ handler: @escaping @Sendable (Completion) -> Void) {
        condition.lock(); completionHandler = handler; condition.unlock()
    }
    var currentRevision: UInt64 {
        condition.lock(); defer { condition.unlock() }; return submitted
    }
    var isLatestSnapshotSaved: Bool {
        condition.lock(); defer { condition.unlock() }; return succeeded >= submitted
    }
    var currentCompletion: Completion? {
        condition.lock(); defer { condition.unlock() }
        return lastCompletion?.revision == submitted ? lastCompletion : nil
    }

    func enqueue(_ snapshot: LibrarySnapshot) {
        condition.lock()
        submitted += 1
        let work = Work(revision: submitted, snapshot: snapshot)
        latest = work; pending = work
        let start = !draining
        draining = true
        condition.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Called only after an explicit operation failed and memory rolled back.
    /// Keep that desired state dirty for a future visit/flush, without retry loops.
    func stage(_ snapshot: LibrarySnapshot) -> UInt64 {
        condition.lock()
        submitted += 1
        latest = Work(revision: submitted, snapshot: snapshot)
        pending = nil
        let revision = submitted
        condition.unlock()
        return revision
    }

    func writeSynchronously(_ snapshot: LibrarySnapshot) -> Completion {
        condition.lock()
        submitted += 1
        let work = Work(revision: submitted, snapshot: snapshot)
        latest = work
        // The explicit snapshot includes all accepted visits. An older pending
        // visit cannot run afterward and restore something just cleared/popped.
        pending = nil
        condition.unlock()
        // No timeout: rolling back while this write can still succeed would
        // make the in-memory and persisted clear/reopen results disagree.
        return queue.sync { self.perform(work) }
    }

    /// Retry an unsaved latest state once. Failed attempts get a fresh revision
    /// so a flush cannot mistake an earlier failed completion for this attempt.
    func prepareFlush() -> UInt64 {
        condition.lock()
        guard succeeded < submitted, let latest else {
            let target = submitted; condition.unlock(); return target
        }
        if pending?.revision == submitted || writing == submitted {
            let target = submitted; condition.unlock(); return target
        }
        if completed >= submitted { submitted += 1 }
        let work = Work(revision: submitted, snapshot: latest.snapshot)
        self.latest = work; pending = work
        let start = !draining
        draining = true
        condition.unlock()
        if start { queue.async { self.drain() } }
        return work.revision
    }
    func wait(for target: UInt64, timeout: TimeInterval) -> Bool {
        let interval = timeout.isFinite ? max(0, timeout) : 0
        let deadline = Date(timeIntervalSinceNow: interval)
        condition.lock(); defer { condition.unlock() }
        while completed < target {
            if !condition.wait(until: deadline) { return completed >= target && succeeded >= target }
        }
        return succeeded >= target
    }
    private func drain() {
        while true {
            condition.lock()
            guard let work = pending else { draining = false; condition.unlock(); return }
            pending = nil; writing = work.revision
            condition.unlock()
            _ = perform(work)
        }
    }
    private func perform(_ work: Work) -> Completion {
        condition.lock(); writing = work.revision; condition.unlock()
        let failure: Error? = autoreleasepool {
            do { try write(work.snapshot, url); return nil }
            catch { return error }
        }
        let result = Completion(revision: work.revision, error: failure)
        condition.lock()
        completed = max(completed, work.revision)
        if failure == nil { succeeded = max(succeeded, work.revision) }
        if writing == work.revision { writing = nil }
        lastCompletion = result
        let handler = completionHandler
        condition.broadcast(); condition.unlock()
        handler?(result)
        return result
    }
}
