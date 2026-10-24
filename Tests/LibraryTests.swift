import AppKit

@main @MainActor struct LibraryTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: library-tests <scoped temporary directory>\n", stderr); exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("library-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func tab(_ address: String = "https://example.com/a", _ title: String = "Alpha", space: Int = 1, pinned: Bool = false) -> BrowserTab {
            BrowserTab(title: title, address: address, space: space, pinned: pinned)
        }
        let memory = BrowserLibrary(storageURL: nil)
        for bad in ["file:///tmp/test", "ftp://example.com", "orbit://newtab", "javascript:alert(1)", "https://user:secret@example.com/", "https://user@example.com/", "https://%75ser@example.com/", "https:///", "not a URL"] {
            memory.recordVisit(title: "Rejected", address: bad)
        }
        check(memory.history.isEmpty, "Only credential-free HTTP/S URLs enter history")
        memory.recordVisit(title: "  First  ", address: " https://example.com/alpha ")
        let firstID = memory.history[0].id
        memory.recordVisit(title: "Renamed Alpha", address: "https://example.com/alpha")
        check(memory.history.count == 1 && memory.history[0].id == firstID && memory.history[0].title == "Renamed Alpha", "Consecutive visits coalesce and update title")
        memory.recordVisit(title: "Beta", address: "http://example.org/beta")
        memory.recordVisit(title: "Alpha again", address: "https://example.com/alpha")
        check(memory.history.count == 3 && memory.history[0].id != firstID, "Nonconsecutive visits are retained")
        check(memory.searchHistory("ALPHA example.com").count == 2, "Title/URL token search is case insensitive")
        check(memory.searchHistory("beta missing").isEmpty, "All search tokens must match")
        memory.recordVisit(title: "  ", address: "https://empty-title.example/path")
        check(memory.history[0].title == "empty-title.example", "Blank title falls back to host")

        let first = tab("https://example.com/first?q=one#two", "First pane", pinned: true)
        let second = tab("https://example.org/second", "Second pane")
        memory.recordClosed(tabs: [first, second], split: true)
        check(memory.closedRecords.count == 1 && memory.closedRecords[0].tabs == [first, second] && memory.closedRecords[0].split, "Split archive preserves all tab values in order")
        check(memory.searchClosed("SECOND example.org").count == 1, "Archive search finds the second pane")
        for (tabs, split) in [([first, first], true), ([first], true), ([first, second], false), ([], false), ([first, tab(space: 2)], true), ([tab("https://user:password@example.com")], false), ([tab(space: -1)], false)] {
            memory.recordClosed(tabs: tabs, split: split)
        }
        check(memory.closedRecords.count == 1, "Invalid archives cannot corrupt the valid split record")
        let home = tab("orbit://newtab", "Home")
        memory.recordClosed(tabs: [home], split: false)
        check(memory.popClosed()?.tabs == [home], "Closed records reopen last-in first-out")
        check(memory.popClosed()?.tabs == [first, second] && memory.popClosed() == nil, "A split consumes one archive record containing both panes")

        let customFile = root.appendingPathComponent("custom-spaces/library.json")
        let custom = BrowserLibrary(storageURL: customFile)
        let customLeft = tab("https://example.com/custom", "Custom Space", space: 1042)
        let customRight = tab("https://example.org/custom", "Custom second", space: 1042)
        custom.recordClosed(tabs: [customLeft], split: false)
        custom.recordClosed(tabs: [customLeft, customRight], split: true)
        check(custom.closedRecords.count == 2, "New nonnegative Space IDs can archive ordinary and split tabs")
        let customLoaded = BrowserLibrary(storageURL: customFile)
        check(customLoaded.closedRecords.first?.tabs == [customLeft, customRight],
              "Reload preserves stable Space IDs without requiring an existing Space definition")
        check(customLoaded.popClosed()?.tabs == [customLeft, customRight] && customLoaded.popClosed()?.tabs == [customLeft],
              "Restoration supplies the original Space ID for the caller's deleted-Space fallback")
        customLoaded.recordClosed(tabs: [customLeft, tab(space: 1043)], split: true)
        check(customLoaded.closedRecords.isEmpty, "A split still cannot cross two different custom Spaces")

        let file = root.appendingPathComponent("nested/library.json")
        let persisted = BrowserLibrary(storageURL: file)
        persisted.recordVisit(title: "Durable title", address: "https://example.com/durable")
        persisted.recordClosed(tabs: [first, second], split: true)
        check(persisted.lastStorageError == nil && FileManager.default.fileExists(atPath: file.path), "First write creates the metadata directory")
        let loaded = BrowserLibrary(storageURL: file)
        let visit = loaded.history.first, originalVisit = persisted.history.first
        let closure = loaded.closedRecords.first, originalClosure = persisted.closedRecords.first
        print("JSON timestamp roundtrip differences: visit=\(abs(visit!.visitedAt.timeIntervalSince(originalVisit!.visitedAt)))s closure=\(abs(closure!.closedAt.timeIntervalSince(originalClosure!.closedAt)))s")
        check(visit?.id == originalVisit?.id && visit?.title == originalVisit?.title && visit?.address == originalVisit?.address && abs(visit!.visitedAt.timeIntervalSince(originalVisit!.visitedAt)) < 0.000001, "JSON roundtrip retains visit identity/content/time within one microsecond")
        check(closure?.id == originalClosure?.id && closure?.tabs == originalClosure?.tabs && closure?.split == originalClosure?.split && abs(closure!.closedAt.timeIntervalSince(originalClosure!.closedAt)) < 0.000001, "JSON roundtrip retains closure identity/tab properties/time within one microsecond")
        let popped = loaded.popClosed()
        check(popped?.tabs == [first, second] && BrowserLibrary(storageURL: file).closedRecords.isEmpty, "Reopen consumption persists")
        loaded.recordClosed(tabs: [home], split: false)
        let sentinel = root.appendingPathComponent("download-sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        check(loaded.clearHistory(), "History clear succeeds")
        check(loaded.history.isEmpty && loaded.closedRecords.count == 1 && (try? String(contentsOf: sentinel)) == "keep", "History clear preserves archive and unrelated files")
        loaded.recordVisit(title: "Keep visit", address: "https://example.com/keep")
        check(loaded.clearArchive() && loaded.closedRecords.isEmpty && loaded.history.count == 1, "Archive clear preserves history")

        let limit = BrowserLibrary(storageURL: nil)
        for n in 0..<5_003 { limit.recordVisit(title: "Entry \(n)", address: "https://example.com/\(n)") }
        for n in 0..<203 { limit.recordClosed(tabs: [tab("https://example.com/\(n)")], split: false) }
        check(limit.history.count == 5_000 && limit.history.first?.title == "Entry 5002" && limit.history.last?.title == "Entry 3", "History retains the newest 5,000 visits")
        check(limit.closedRecords.count == 200 && limit.closedRecords.last?.tabs[0].address == "https://example.com/3", "Archive retains the newest 200 closures")
        check(limit.storageURL == nil && limit.lastStorageError == nil, "Ephemeral operation needs no storage")

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
        }
        let entry = BrowserHistoryEntry(title: "Valid entry", address: "https://example.com/valid")
        var unsafeEntry = try object(entry); unsafeEntry["id"] = UUID().uuidString; unsafeEntry["address"] = "https://name:pass@example.com"
        let closed = ClosedRecord(tabs: [first, second], split: true)
        var invalidClosed = try object(closed); invalidClosed["id"] = UUID().uuidString; invalidClosed["split"] = false
        let negativeSpace = ClosedRecord(tabs: [tab(space: -1)], split: false)
        let mixedFile = root.appendingPathComponent("mixed.json")
        let mixed: [String: Any] = ["version": 1, "history": [try object(entry), ["broken": true], "wrong shape", unsafeEntry, try object(entry)], "closedRecords": [try object(closed), invalidClosed, try object(negativeSpace), ["broken": true], try object(closed)]]
        try JSONSerialization.data(withJSONObject: mixed).write(to: mixedFile)
        let mixedLoaded = BrowserLibrary(storageURL: mixedFile)
        check(mixedLoaded.history.count == 1 && mixedLoaded.history[0].id == entry.id && mixedLoaded.history[0].address == entry.address && mixedLoaded.closedRecords.count == 1 && mixedLoaded.closedRecords[0].id == closed.id && mixedLoaded.closedRecords[0].tabs == closed.tabs, "Load skips malformed, unsafe and duplicate records independently")
        mixedLoaded.recordVisit(title: "Still writable", address: "https://example.com/after-repair")
        check(mixedLoaded.history.count == 2 && mixedLoaded.lastStorageError == nil, "Partially damaged compatible files remain usable")

        // A fully decodable file must apply the same safety, identity, and size
        // rules as the damaged-record salvage path.
        let typedFile = root.appendingPathComponent("typed.json")
        let typed: [String: Any] = ["version": 1, "history": [try object(entry), unsafeEntry, try object(entry)],
                                  "closedRecords": [try object(closed), invalidClosed, try object(negativeSpace), try object(closed)]]
        try JSONSerialization.data(withJSONObject: typed).write(to: typedFile)
        let typedLoaded = BrowserLibrary(storageURL: typedFile)
        check(typedLoaded.history.map(\.id) == [entry.id] && typedLoaded.closedRecords.map(\.id) == [closed.id],
              "Whole-file decoding still rejects unsafe entries, invalid archives, and duplicate identities")
        var legacy = typed; legacy.removeValue(forKey: "version")
        try JSONSerialization.data(withJSONObject: legacy).write(to: typedFile)
        let legacyLoaded = BrowserLibrary(storageURL: typedFile)
        check(legacyLoaded.history.map(\.id) == [entry.id] && legacyLoaded.closedRecords.map(\.id) == [closed.id],
              "Legacy files without a version retain per-record validation")
        var future = typed; future["version"] = 2
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        try futureBytes.write(to: typedFile)
        let futureLoaded = BrowserLibrary(storageURL: typedFile)
        futureLoaded.recordVisit(title: "Do not replace", address: "https://example.com")
        check(futureLoaded.lastStorageError != nil && futureLoaded.history.isEmpty && (try? Data(contentsOf: typedFile)) == futureBytes,
              "Fully decodable future files cannot bypass format protection")

        for (name, bytes) in [("future.json", Data("{\"version\":2,\"history\":[]}".utf8)), ("broken.json", Data("not JSON".utf8))] {
            let url = root.appendingPathComponent(name); try bytes.write(to: url)
            let guarded = BrowserLibrary(storageURL: url)
            check(guarded.history.isEmpty && guarded.lastStorageError != nil, "Unreadable/unknown whole-file format is reported")
            guarded.recordVisit(title: "Must not overwrite", address: "https://example.com")
            check(guarded.history.isEmpty && (try? Data(contentsOf: url)) == bytes, "Unreadable/unknown original file is preserved on attempted mutation")
        }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocker)
        let failed = BrowserLibrary(storageURL: blocker.appendingPathComponent("library.json"))
        var errors = 0; failed.onStorageError = { _ in errors += 1 }
        failed.recordVisit(title: "Unsaveable", address: "https://example.com")
        check(!failed.flush() && failed.history.count == 1 && !failed.isLatestSnapshotSaved,
              "A failed visit write retains the accepted history as dirty")
        failed.recordClosed(tabs: [home], split: false)
        check(failed.history.count == 1 && failed.closedRecords.isEmpty && errors == 2 && failed.lastStorageError != nil,
              "Explicit write failures roll back archive changes while retaining dirty visits")
        check(mixedLoaded.flush(), "Pending salvaged-library visits finish before fixture cleanup")
        print("PASS: \(checks) library metadata checks")
    }
}
