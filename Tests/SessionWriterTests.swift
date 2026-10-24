import Foundation

/// No app/windows/profile access. Writes only inside a unique fixture directory.
@main @MainActor struct SessionWriterTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var mainThreadWrites = 0
        func record(_ value: String) {
            lock.lock(); entries.append(value)
            if Thread.isMainThread { mainThreadWrites += 1 }
            lock.unlock()
        }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
        var wroteOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadWrites != 0 }
    }
    final class WeakWriter { weak var value: SessionWriter?; init(_ writer: SessionWriter?) { value = writer } }
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(description: message) }
    }
    static func session(_ title: String) -> BrowserSession {
        let tab = BrowserTab(title: title, address: "https://example.invalid/\(title)", space: 0)
        return BrowserSession(tabs: [tab], activeID: tab.id, lastSelectedTabIDsBySpace: [0: tab.id])
    }
    static func awaitCallback(_ condition: () -> Bool, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        return condition()
    }
    static func main() {
        let base = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("session-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try coalescingSnapshotAndBoundedFlush(directory)
            try failureAndRecovery(directory)
            try shutdownLatestSnapshot(directory)
            try asyncFlushKeepsMainResponsive(directory)
            try lifecycleAndIdle(directory)
            print("PASS: \(checks) session-writer ordering, coalescing, snapshot, failure and flush checks")
        } catch {
            FileHandle.standardError.write(Data("FAIL: session writer — \(error)\n".utf8)); exit(1)
        }
    }
    static func coalescingSnapshotAndBoundedFlush(_ directory: URL) throws {
        let target = directory.appendingPathComponent("coalesced.json")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let trace = Trace()
        let writer = SessionWriter(url: target) { snapshot, url in
            trace.record(snapshot.tabs[0].title)
            if snapshot.tabs[0].title == "first" || snapshot.tabs[0].title == "after-flush" {
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw Failure(description: "Test gate timed out") }
            }
            try SessionFile.save(snapshot, to: url)
        }
        writer.enqueue(session("first"))
        try check(entered.wait(timeout: .now() + 2) == .success, "First write never started off-main")
        try check(!writer.isLatestSnapshotSaved, "In-flight snapshot was reported saved")
        defer { release.signal() }
        writer.enqueue(session("discarded"))
        var latest = session("latest")
        let expectedID = latest.activeID
        writer.enqueue(latest)
        // Mutate every nested value collection after enqueue to exercise COW.
        latest.tabs[0].title = "mutated-after-enqueue"
        latest.spaces[0].name = "Changed"
        latest.lastSelectedTabIDsBySpace?[0] = UUID()
        let began = Date()
        try check(!writer.flush(timeout: 0.03), "Blocked flush incorrectly claimed success")
        try check(Date().timeIntervalSince(began) < 0.5, "Bounded flush waited indefinitely")
        try check(trace.values == ["first"], "Enqueue serialized or started a parallel write")
        release.signal()
        try check(writer.flush(timeout: 2), "Latest pending snapshot was not flushed")
        try check(trace.values == ["first", "latest"], "Pending snapshots did not coalesce in order")
        try check(!trace.wroteOnMain, "Encoding/write closure ran on the main thread")
        let saved = SessionFile.load(target)
        try check(saved.tabs[0].title == "latest" && saved.activeID == expectedID, "Later mutation or old write replaced the latest snapshot")
        try check(saved.spaces[0].name == "Studio" && saved.lastSelectedTabIDsBySpace?[0] == expectedID,
                  "Nested COW metadata changed after enqueue")
        try check(writer.flush(timeout: 0), "Completed flush should not need another wait")
        try check(writer.isLatestSnapshotSaved, "Successful latest write was not reported saved")
        writer.enqueue(session("after-flush"))
        try check(entered.wait(timeout: .now() + 2) == .success, "New revision did not begin after an earlier flush")
        try check(!writer.isLatestSnapshotSaved, "A previous successful flush hid a newer pending revision")
        release.signal()
        try check(writer.flush(timeout: 2) && writer.isLatestSnapshotSaved, "New revision did not become durable")
    }
    static func failureAndRecovery(_ directory: URL) throws {
        let target = directory.appendingPathComponent("recovery.json")
        try SessionFile.save(session("original"), to: target)
        let trace = Trace()
        let writer = SessionWriter(url: target) { snapshot, url in
            trace.record(snapshot.tabs[0].title)
            if snapshot.tabs[0].title == "failure" { throw Failure(description: "Injected write failure") }
            try SessionFile.save(snapshot, to: url)
        }
        var failures = 0
        var callbackOnMain = false
        var callbackDescription = ""
        writer.onError = { error in
            failures += 1; callbackOnMain = Thread.isMainThread
            callbackDescription = String(describing: error)
        }
        writer.enqueue(session("failure"))
        try check(!writer.flush(timeout: 2), "Failed write was reported as durable")
        try check(!writer.isLatestSnapshotSaved, "Failed latest snapshot was reported saved")
        try check(awaitCallback { failures == 1 }, "Failure callback was not delivered")
        try check(callbackOnMain && callbackDescription.contains("Injected write failure"), "Failure did not report its original error on main")
        try check(SessionFile.load(target).tabs[0].title == "original", "Failed injected write destroyed the existing file")
        writer.enqueue(session("recovered"))
        try check(writer.flush(timeout: 2), "Later enqueue did not recover after failure")
        try check(SessionFile.load(target).tabs[0].title == "recovered", "Recovery wrote the wrong state")
        try check(trace.values == ["failure", "recovered"] && !trace.wroteOnMain, "Error path broke serial/off-main ordering")
        try check(failures == 1, "Successful recovery reported another failure")
    }
    static func shutdownLatestSnapshot(_ directory: URL) throws {
        let target = directory.appendingPathComponent("shutdown.json")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let trace = Trace()
        let writer = SessionWriter(url: target) { snapshot, url in
            trace.record(snapshot.tabs[0].title)
            if snapshot.tabs[0].title == "inflight" {
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw Failure(description: "Shutdown gate timed out") }
            }
            try SessionFile.save(snapshot, to: url)
        }
        writer.enqueue(session("inflight"))
        try check(entered.wait(timeout: .now() + 2) == .success, "Shutdown write never started")
        defer { release.signal() }
        for index in 0..<50 { writer.enqueue(session("pending-\(index)")) }
        writer.enqueue(session("shutdown-final"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { release.signal() }
        // Synchronous main-thread flush must not need a main-queue callback to
        // advance the serial worker, even while a prior write is still blocked.
        try check(writer.flush(timeout: 2), "Shutdown flush deadlocked or missed its final revision")
        try check(trace.values == ["inflight", "shutdown-final"], "Shutdown did not retain only the final pending snapshot")
        try check(SessionFile.load(target).tabs[0].title == "shutdown-final", "Shutdown returned before final atomic replacement")
        try check(!trace.wroteOnMain, "Shutdown moved encoding onto the main thread")
    }
    static func asyncFlushKeepsMainResponsive(_ directory: URL) throws {
        let target = directory.appendingPathComponent("async.json")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writer = SessionWriter(url: target) { snapshot, url in
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else { throw Failure(description: "Async gate timed out") }
            try SessionFile.save(snapshot, to: url)
        }
        writer.enqueue(session("async-final"))
        try check(entered.wait(timeout: .now() + 2) == .success, "Async write never started")
        defer { release.signal() }
        var result: Bool?
        var mainPulse = false
        Task { @MainActor in result = await writer.flushAsync(timeout: 1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            mainPulse = true; release.signal()
        }
        try check(awaitCallback({ result != nil }, timeout: 2), "Async flush never resumed its caller")
        try check(mainPulse && result == true, "Async flush blocked the main queue needed to release the writer")
        try check(SessionFile.load(target).tabs[0].title == "async-final", "Async flush completed before its snapshot reached disk")
    }
    static func lifecycleAndIdle(_ directory: URL) throws {
        let target = directory.appendingPathComponent("idle.json")
        var writer: SessionWriter? = SessionWriter(url: target)
        let weakWriter = WeakWriter(writer)
        try check(writer!.flush(timeout: 0), "Unused writer should flush immediately")
        try check(writer!.isLatestSnapshotSaved, "Unused writer should have no unsaved revision")
        try check(!FileManager.default.fileExists(atPath: target.path), "Unused writer performed filesystem work")
        writer!.enqueue(session("retained-until-flush"))
        try check(writer!.flush(timeout: 2), "Default SessionFile writer failed")
        writer = nil
        try check(weakWriter.value == nil, "Worker callback retained the public writer")
        try check(SessionFile.load(target).tabs[0].title == "retained-until-flush", "Default writer did not persist the submitted value")
    }
}
