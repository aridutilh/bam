import AppKit

@main @MainActor enum LibraryWriterTests {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LibrarySnapshot] = []
        private var finished = 0
        private var wroteOnMain = false
        let blocked: Set<Int>
        let failures: Set<Int>
        let release = DispatchSemaphore(value: 0)
        init(blocked: Set<Int> = [], failures: Set<Int> = []) { self.blocked = blocked; self.failures = failures }
        var snapshots: [LibrarySnapshot] { lock.lock(); defer { lock.unlock() }; return values }
        var completed: Int { lock.lock(); defer { lock.unlock() }; return finished }
        var usedMain: Bool { lock.lock(); defer { lock.unlock() }; return wroteOnMain }
        func write(_ snapshot: LibrarySnapshot, _ url: URL) throws {
            lock.lock()
            values.append(snapshot)
            let call = values.count, blocks = blocked.contains(call), fails = failures.contains(call)
            wroteOnMain = wroteOnMain || Thread.isMainThread
            lock.unlock()
            defer { lock.lock(); finished += 1; lock.unlock() }
            if blocks, release.wait(timeout: .now() + 5) != .success { throw Failure(message: "Blocked fixture timed out") }
            if fails { throw Failure(message: "Injected write failure \(call)") }
            try LibraryWriter.writeFile(snapshot, to: url)
        }
    }
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }; checks += 1
    }
    static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "Fixture condition timed out") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Expected a private fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("library-writer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name + ".json") }
        func visit(_ library: BrowserLibrary, _ index: Int) { library.recordVisit(title: "Visit \(index)", address: "https://example.invalid/\(index)") }
        func stored(_ url: URL) throws -> LibrarySnapshot {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: url))
        }
        let tab = BrowserTab(title: "Closed tab", address: "https://example.invalid/closed", space: 0)

        // A blocked disk worker must not block visit ingestion or the main actor.
        let coalescing = Writes(blocked: [1])
        let coalescedFile = file("coalesced")
        let coalesced = BrowserLibrary(storageURL: coalescedFile, write: { try coalescing.write($0, $1) })
        visit(coalesced, 0)
        try await until { coalescing.snapshots.count == 1 }
        for index in 1...20 { visit(coalesced, index) }
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        try await until { heartbeat }
        try check(coalesced.history.count == 21 && !coalesced.isLatestSnapshotSaved && coalescing.snapshots.count == 1,
                  "Blocked storage must leave the main actor responsive with accepted visits in memory")
        try check(!coalesced.flush(timeout: 0.001) && coalesced.history.count == 21,
                  "A bounded flush timeout must not roll back accepted visits")
        coalescing.release.signal()
        try check(await coalesced.flushAsync() && coalesced.isLatestSnapshotSaved, "Flush saves the latest coalesced snapshot")
        try check(coalescing.snapshots.count == 2 && coalescing.snapshots.last?.history.count == 21,
                  "A burst retains only the in-flight and latest pending snapshots")
        try check(!coalescing.usedMain && (try stored(coalescedFile)).history.first?.title == "Visit 20",
                  "Visit encoding/replacement runs off-main and persists newest order")

        // Accepted visits survive an async failure and explicit flush retries them.
        let failing = Writes(failures: [1])
        let retryFile = file("retry")
        let retry = BrowserLibrary(storageURL: retryFile, write: { try failing.write($0, $1) })
        var retryErrors = 0; retry.onStorageError = { _ in retryErrors += 1 }
        visit(retry, 1)
        try await until { retry.lastStorageError != nil }
        try check(retry.history.count == 1 && !retry.isLatestSnapshotSaved && retryErrors == 1,
                  "Async failure retains dirty visits and reports the current failure once")
        try check(await retry.flushAsync() && retry.isLatestSnapshotSaved && retry.lastStorageError == nil,
                  "Explicit flush retries a failed snapshot and clears its error only after success")
        try check((try stored(retryFile)).history.count == 1 && failing.snapshots.count == 2,
                  "Retry persists the original accepted visit without duplication")

        let supersededWrites = Writes(blocked: [1], failures: [1])
        let superseded = BrowserLibrary(storageURL: file("superseded"), write: { try supersededWrites.write($0, $1) })
        var staleErrors = 0; superseded.onStorageError = { _ in staleErrors += 1 }
        visit(superseded, 1)
        try await until { supersededWrites.snapshots.count == 1 }
        visit(superseded, 2)
        supersededWrites.release.signal()
        try check(await superseded.flushAsync() && superseded.history.count == 2 && staleErrors == 0,
                  "A superseded failure cannot report/revert over a newer accepted visit")

        let newVisitWrites = Writes(failures: [1])
        let newVisit = BrowserLibrary(storageURL: file("new-visit-retry"), write: { try newVisitWrites.write($0, $1) })
        visit(newVisit, 1)
        try await until { newVisit.lastStorageError != nil }
        visit(newVisit, 2)
        try check(await newVisit.flushAsync() && newVisit.lastStorageError == nil && newVisit.history.count == 2,
                  "A later visit retries the current dirty history including the failed visit")

        // Clear waits for the actual write after any older async write. Its
        // success must never be followed by an old visit restoring the history.
        let orderedWrites = Writes(blocked: [1])
        let orderedFile = file("ordered")
        let ordered = BrowserLibrary(storageURL: orderedFile, write: { try orderedWrites.write($0, $1) })
        visit(ordered, 1)
        try await until { orderedWrites.snapshots.count == 1 }
        visit(ordered, 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { orderedWrites.release.signal() }
        try check(ordered.clearHistory() && ordered.history.isEmpty && ordered.isLatestSnapshotSaved,
                  "Clear waits for its exact ordered durable result")
        try check((try stored(orderedFile)).history.isEmpty && orderedWrites.snapshots.count == 2,
                  "Clear supersedes queued older visits and cannot be resurrected by them")
        ordered.recordClosed(tabs: [tab], split: false)
        visit(ordered, 3)
        try check(ordered.takeClosed(id: ordered.closedRecords[0].id)?.tabs == [tab]
                    && (try stored(orderedFile)).closedRecords.isEmpty && (try stored(orderedFile)).history.count == 1,
                  "Reopen consumption is durable and includes earlier accepted visits")
        ordered.recordClosed(tabs: [tab], split: false)
        visit(ordered, 4)
        try check(ordered.clearArchive() && (try stored(orderedFile)).closedRecords.isEmpty,
                  "Archive clear is ordered with pending visit snapshots")

        // An explicit failure keeps the previous contract, and retry writes the
        // restored state rather than replaying the failed clear/consume command.
        let rollbackWrites = Writes(failures: [2])
        let rollbackFile = file("rollback")
        let rollback = BrowserLibrary(storageURL: rollbackFile, write: { try rollbackWrites.write($0, $1) })
        visit(rollback, 1)
        try check(await rollback.flushAsync(), "Rollback fixture seed persists")
        try check(!rollback.clearHistory() && rollback.history.count == 1 && !rollback.isLatestSnapshotSaved,
                  "Failed synchronous clear rolls memory back only after the write failed")
        try check(await rollback.flushAsync() && (try stored(rollbackFile)).history.count == 1,
                  "Flush retries the restored snapshot, never the rejected clear")
        let popWrites = Writes(failures: [2])
        let popFile = file("pop-rollback")
        let pop = BrowserLibrary(storageURL: popFile, write: { try popWrites.write($0, $1) })
        pop.recordClosed(tabs: [tab], split: false)
        try check(pop.popClosed() == nil && pop.closedRecords.count == 1, "Failed archive consume returns nil and restores the record")
        try check(await pop.flushAsync() && (try stored(popFile)).closedRecords.count == 1,
                  "Retry cannot consume a record whose earlier reopen failed")

        let reentrantWrites = Writes(failures: [2])
        let reentrantFile = file("reentrant")
        let reentrant = BrowserLibrary(storageURL: reentrantFile, write: { try reentrantWrites.write($0, $1) })
        visit(reentrant, 1)
        try check(await reentrant.flushAsync(), "Reentrant fixture seed persists")
        reentrant.onStorageError = { _ in visit(reentrant, 2) }
        try check(!reentrant.clearHistory() && reentrant.history.count == 2,
                  "A failed clear restores history before an error handler adds a newer visit")
        try await until { reentrant.isLatestSnapshotSaved }
        reentrant.onStorageError = nil
        try check(await reentrant.flushAsync() && (try stored(reentrantFile)).history.map(\.title) == ["Visit 2", "Visit 1"],
                  "Rollback staging cannot discard or overwrite an error handler's newer visit")

        // A quit barrier can complete its captured revision while a new visit
        // is still writing. The caller must observe that latest state is dirty.
        let revisions = Writes(blocked: [1, 2])
        let revisionFile = file("revisions")
        let revisionLibrary = BrowserLibrary(storageURL: revisionFile, write: { try revisions.write($0, $1) })
        visit(revisionLibrary, 1)
        try await until { revisions.snapshots.count == 1 }
        var flushStarted = false
        let firstFlush = Task { @MainActor in
            flushStarted = true
            return await revisionLibrary.flushAsync()
        }
        try await until { flushStarted }
        visit(revisionLibrary, 2)
        revisions.release.signal()
        try await until { revisions.snapshots.count == 2 }
        try check(await firstFlush.value && !revisionLibrary.isLatestSnapshotSaved,
                  "An older quit barrier cannot claim a newer in-flight visit is saved")
        revisions.release.signal()
        try check(await revisionLibrary.flushAsync() && revisionLibrary.isLatestSnapshotSaved
                    && (try stored(revisionFile)).history.count == 2, "A repeated quit barrier saves the final accepted revision")

        let ephemeralWrites = Writes()
        let ephemeral = BrowserLibrary(storageURL: nil, write: { try ephemeralWrites.write($0, $1) })
        visit(ephemeral, 1); ephemeral.recordClosed(tabs: [tab], split: false)
        try check(await ephemeral.flushAsync() && ephemeral.flush() && ephemeral.isLatestSnapshotSaved && ephemeralWrites.snapshots.isEmpty,
                  "Ephemeral libraries never create or call a disk writer")
        let corruptFile = file("future"); let future = Data(#"{"version":99,"history":[]}"#.utf8)
        try future.write(to: corruptFile)
        let protected = BrowserLibrary(storageURL: corruptFile)
        visit(protected, 1); protected.recordClosed(tabs: [tab], split: false)
        _ = await protected.flushAsync()
        try check(protected.history.isEmpty && protected.closedRecords.isEmpty && (try Data(contentsOf: corruptFile)) == future,
                  "Unsupported files reject all mutations and flush never overwrites them")
        print("PASS: \(checks) library writer ordering, retry and responsiveness checks")
    }
}
