import Foundation

/// Exercises quit decisions without NSApplication, windows, or a user profile.
@main @MainActor struct QuitCoordinatorTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class WriteTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []
        private var mainThreadWrite = false
        @discardableResult func append(_ title: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            titles.append(title); mainThreadWrite = mainThreadWrite || Thread.isMainThread
            return titles.count
        }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return titles }
        var wroteOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadWrite }
    }
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func wait(_ message: String, timeout: TimeInterval = 2, _ condition: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            // A condition may consume a semaphore token; evaluate it once.
            if condition() { checks += 1; return }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        try check(condition(), message)
    }
    static func session(_ title: String) -> BrowserSession {
        let tab = BrowserTab(title: title, address: "https://example.invalid/quit-fixture", space: 0)
        return BrowserSession(tabs: [tab], activeID: tab.id, lastSelectedTabIDsBySpace: [0: tab.id])
    }
    static func main() {
        let base = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("quit-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try cancelAndReentrantConfirmation()
            try acceptedQuitWaitsForOrderedWrites(directory)
            try failedWriteCanRetry(directory)
            try failedQuitCanCancelAndRestart()
            try failedWriteCanBeExplicitlyAbandoned(directory)
            print("PASS: \(checks) quit-coordinator cancellation, duplicate-request, ordered-save and recovery checks")
        } catch {
            FileHandle.standardError.write(Data("FAIL: quit coordinator — \(error)\n".utf8))
            exit(1)
        }
    }
    static func cancelAndReentrantConfirmation() throws {
        let coordinator = QuitCoordinator()
        var confirmations = 0, saves = 0, failures = 0, duplicateCallbacks = 0
        var replies: [Bool] = []
        var resetBeforeReply = false
        coordinator.request(confirmation: {
            confirmations += 1
            // A modal confirmation can reenter AppKit and receive another Quit.
            coordinator.request(confirmation: { duplicateCallbacks += 1; return true },
                                save: { duplicateCallbacks += 1; return true },
                                saveFailure: { duplicateCallbacks += 1; return .quitWithoutSaving },
                                reply: { _ in duplicateCallbacks += 1 })
            return false
        }, save: { saves += 1; return true },
           saveFailure: { failures += 1; return .quitWithoutSaving },
           reply: { value in resetBeforeReply = !coordinator.isPending; replies.append(value) })
        try check(coordinator.isPending, "Request did not claim the gate before scheduling confirmation")
        try wait("Cancelled confirmation never replied") { replies.count == 1 }
        try check(replies == [false] && confirmations == 1, "Cancel did not produce one negative reply")
        try check(saves == 0 && failures == 0, "Cancel reached saving or save-error UI")
        try check(duplicateCallbacks == 0, "Reentrant confirmation started a second quit flow")
        try check(resetBeforeReply && !coordinator.isPending, "Cancel did not reset the gate before its reply")
        coordinator.request(confirmation: { confirmations += 1; return false },
                            save: { saves += 1; return true },
                            saveFailure: { failures += 1; return .retry },
                            reply: { replies.append($0) })
        try wait("A new quit request was blocked after cancellation") { replies.count == 2 }
        try check(replies == [false, false] && confirmations == 2 && saves == 0 && failures == 0,
                  "A second cancelled quit changed the save behavior")
    }
    static func acceptedQuitWaitsForOrderedWrites(_ directory: URL) throws {
        let target = directory.appendingPathComponent("ordered.json")
        let oldEntered = DispatchSemaphore(value: 0), oldRelease = DispatchSemaphore(value: 0)
        let latestEntered = DispatchSemaphore(value: 0), latestRelease = DispatchSemaphore(value: 0)
        defer { oldRelease.signal(); latestRelease.signal() }
        let trace = WriteTrace()
        let writer = SessionWriter(url: target) { snapshot, url in
            trace.append(snapshot.tabs[0].title)
            let entered = snapshot.tabs[0].title == "older" ? oldEntered : latestEntered
            let release = snapshot.tabs[0].title == "older" ? oldRelease : latestRelease
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw Failure(description: "Ordered-writer fixture gate timed out")
            }
            try SessionFile.save(snapshot, to: url)
        }
        let older = session("older")
        var latest = older
        latest.tabs[0].title = "latest"; latest.sidebarWidth = 314
        latest.spaces[0].name = "Latest Space"
        writer.enqueue(older)
        try wait("The older write did not enter its worker gate") { oldEntered.wait(timeout: .now()) == .success }
        let coordinator = QuitCoordinator()
        var saves = 0, failures = 0, duplicateCallbacks = 0
        var replies: [Bool] = []
        var durableAtReply = false, mainPulse = false
        coordinator.request(confirmation: { true }, save: {
            saves += 1
            writer.enqueue(latest)
            return await writer.flushAsync(timeout: 3)
        }, saveFailure: { failures += 1; return .cancel }, reply: {
            durableAtReply = writer.isLatestSnapshotSaved && SessionFile.load(target).tabs[0].title == "latest"
            replies.append($0)
        })
        try wait("Accepted quit did not enter the asynchronous save") { saves == 1 }
        Task { @MainActor in mainPulse = true }
        try wait("The save wait blocked the main actor") { mainPulse }
        coordinator.request(confirmation: { duplicateCallbacks += 1; return true },
                            save: { duplicateCallbacks += 1; return true },
                            saveFailure: { duplicateCallbacks += 1; return .cancel },
                            reply: { _ in duplicateCallbacks += 1 })
        try check(coordinator.isPending && replies.isEmpty && !writer.isLatestSnapshotSaved,
                  "Quit completed while the older write was blocked")
        try check(!FileManager.default.fileExists(atPath: target.path), "Blocked write unexpectedly produced a file")
        oldRelease.signal()
        try wait("Latest snapshot did not follow the older write") { latestEntered.wait(timeout: .now()) == .success }
        try check(SessionFile.load(target).tabs[0].title == "older", "Writes did not retain serial order")
        try check(replies.isEmpty && coordinator.isPending, "Quit used the older snapshot as its save barrier")
        latestRelease.signal()
        try wait("Quit did not reply after the latest snapshot became durable") { replies.count == 1 }
        let saved = SessionFile.load(target)
        try check(replies == [true] && durableAtReply, "Positive quit reply preceded persistence")
        try check(saved.activeID == latest.activeID && saved.tabs[0].title == "latest"
                  && saved.sidebarWidth == 314 && saved.spaces[0].name == "Latest Space",
                  "The final file lost tab identity or latest metadata")
        try check(trace.values == ["older", "latest"] && !trace.wroteOnMain, "Writes were duplicated, reordered, or performed on main")
        try check(saves == 1 && failures == 0 && duplicateCallbacks == 0, "A pending duplicate started another quit flow")
        try check(coordinator.isPending, "Accepted termination reopened its gate before app exit")
        coordinator.request(confirmation: { duplicateCallbacks += 1; return true },
                            save: { duplicateCallbacks += 1; return true },
                            saveFailure: { duplicateCallbacks += 1; return .cancel },
                            reply: { _ in duplicateCallbacks += 1 })
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        try check(replies.count == 1 && duplicateCallbacks == 0, "A second request replied again after accepted termination")
    }
    static func failedWriteCanRetry(_ directory: URL) throws {
        let target = directory.appendingPathComponent("retry.json")
        try SessionFile.save(session("previous"), to: target)
        let trace = WriteTrace()
        let writer = SessionWriter(url: target) { snapshot, url in
            if trace.append(snapshot.tabs[0].title) == 1 { throw Failure(description: "Injected first-write failure") }
            try SessionFile.save(snapshot, to: url)
        }
        let coordinator = QuitCoordinator()
        var confirmations = 0, saves = 0, failures = 0, duplicateCallbacks = 0
        var sawRecoverableFailure = false, durableAtReply = false
        var replies: [Bool] = []
        coordinator.request(confirmation: { confirmations += 1; return true }, save: {
            saves += 1; writer.enqueue(session("retried"))
            return await writer.flushAsync(timeout: 2)
        }, saveFailure: {
            failures += 1
            sawRecoverableFailure = coordinator.isPending && replies.isEmpty && !writer.isLatestSnapshotSaved
                && SessionFile.load(target).tabs[0].title == "previous"
            coordinator.request(confirmation: { duplicateCallbacks += 1; return true },
                                save: { duplicateCallbacks += 1; return true },
                                saveFailure: { duplicateCallbacks += 1; return .cancel },
                                reply: { _ in duplicateCallbacks += 1 })
            return .retry
        }, reply: {
            durableAtReply = writer.isLatestSnapshotSaved && SessionFile.load(target).tabs[0].title == "retried"
            replies.append($0)
        })
        try wait("Retry did not complete after the real writer recovered") { replies.count == 1 }
        try check(sawRecoverableFailure, "Failed persistence did not remain recoverable before Retry")
        try check(confirmations == 1 && saves == 2 && failures == 1, "Retry repeated confirmation or skipped/repeated saving")
        try check(replies == [true] && durableAtReply, "Retry replied before the recovered snapshot reached disk")
        try check(trace.values == ["retried", "retried"] && !trace.wroteOnMain, "Retry bypassed the serial background writer")
        try check(duplicateCallbacks == 0, "The error dialog allowed a duplicate quit flow")
    }
    static func failedQuitCanCancelAndRestart() throws {
        let coordinator = QuitCoordinator()
        var saves = 0, failurePrompts = 0
        var replies: [Bool] = []
        var resetBeforeReply = false
        coordinator.request(confirmation: { true }, save: { saves += 1; return false },
                            saveFailure: { failurePrompts += 1; return .cancel },
                            reply: { resetBeforeReply = !coordinator.isPending; replies.append($0) })
        try wait("Cancel Quit after save failure did not reply") { replies.count == 1 }
        try check(replies == [false] && saves == 1 && failurePrompts == 1 && resetBeforeReply,
                  "Save-error cancellation was treated as accepted termination")
        coordinator.request(confirmation: { true }, save: { saves += 1; return true },
                            saveFailure: { failurePrompts += 1; return .quitWithoutSaving },
                            reply: { replies.append($0) })
        try wait("A new quit could not proceed after save-error cancellation") { replies.count == 2 }
        try check(replies == [false, true] && saves == 2 && failurePrompts == 1,
                  "The cancelled error flow poisoned a later successful quit")
    }
    static func failedWriteCanBeExplicitlyAbandoned(_ directory: URL) throws {
        let target = directory.appendingPathComponent("abandoned.json")
        try SessionFile.save(session("last-durable"), to: target)
        let writer = SessionWriter(url: target) { _, _ in throw Failure(description: "Injected persistent failure") }
        let coordinator = QuitCoordinator()
        var saves = 0, failures = 0, explicitChoiceWasNeeded = false
        var replies: [Bool] = []
        coordinator.request(confirmation: { true }, save: {
            saves += 1; writer.enqueue(session("not-saved"))
            return await writer.flushAsync(timeout: 2)
        }, saveFailure: {
            failures += 1
            explicitChoiceWasNeeded = replies.isEmpty && !writer.isLatestSnapshotSaved && coordinator.isPending
            return .quitWithoutSaving
        }, reply: { replies.append($0) })
        try wait("Explicit Quit Without Saving did not finish") { replies.count == 1 }
        try check(explicitChoiceWasNeeded && replies == [true] && saves == 1 && failures == 1,
                  "Quit skipped the explicit unsaved-changes choice")
        try check(!writer.isLatestSnapshotSaved && SessionFile.load(target).tabs[0].title == "last-durable",
                  "Abandoning a failed write falsely reported the latest state as saved")
    }
}
