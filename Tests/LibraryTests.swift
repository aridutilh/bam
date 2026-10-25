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

        // A closed (Today/unkept) Arc Easel reference can be reopened, and survives a restart.
        let easelFile = root.appendingPathComponent("easel/library.json")
        let easelLibrary = BrowserLibrary(storageURL: easelFile)
        let easel = tab(ArcEaselReference.address(for: UUID()), "Canvas from Arc")
        easelLibrary.recordClosed(tabs: [easel], split: false)
        check(easelLibrary.closedRecords.first?.tabs == [easel], "A closed Easel reference is archived for reopening")
        check(BrowserLibrary(storageURL: easelFile).popClosed()?.tabs == [easel], "Its archive survives restart and reopens unchanged")
        easelLibrary.recordClosed(tabs: [tab("orbit://arc-easel/not-a-uuid", "Bad")], split: false)
        check(easelLibrary.closedRecords.count == 1, "Malformed reference addresses are still refused")

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

        // Genuine history-change events (extension history seam).
        var events: [BrowserLibrary.HistoryChange] = []
        let eventful = BrowserLibrary(storageURL: nil)
        eventful.onHistoryChange = { events.append($0) }
        eventful.recordVisit(title: "One", address: "https://events.example/one")
        guard case .visited(let firstVisit)? = events.first, events.count == 1 else { check(false, "An accepted visit sends exactly one event"); return }
        check(firstVisit == eventful.history[0] && firstVisit.address == "https://events.example/one", "The event carries the entry as it now stands")
        events.removeAll()
        eventful.recordVisit(title: "One again", address: "https://events.example/one")
        check(events == [.visited(eventful.history[0])] && eventful.history.count == 1 && eventful.history[0].id == firstVisit.id
              && eventful.history[0].title == "One again", "A coalesced revisit is still a visit, with the updated entry")
        events.removeAll()
        eventful.recordVisit(title: "Nope", address: "orbit://newtab")
        eventful.recordVisit(title: "Nope", address: "https://user:pw@events.example/")
        check(events.isEmpty, "Rejected visits send nothing")
        // Trimming past 5,000: the visit, then the trimmed addresses.
        let trimming = BrowserLibrary(storageURL: nil)
        for n in 0..<5_000 { trimming.recordVisit(title: "T\(n)", address: "https://trim.example/\(n % 2 == 0 ? "even" : "odd\(n)")") }
        var trimEvents: [BrowserLibrary.HistoryChange] = []
        trimming.onHistoryChange = { trimEvents.append($0) }
        let oldest = trimming.history.last!.address
        trimming.recordVisit(title: "Newest", address: "https://trim.example/newest")
        check(trimEvents.count == 2 && trimEvents[0] == .visited(trimming.history[0]) && trimEvents[1] == .trimmed(addresses: [oldest])
              && trimming.history.count == 5_000, "A visit past the limit sends the visit, then exactly the trimmed address")
        trimEvents.removeAll()
        trimming.recordVisit(title: "Newest again", address: "https://trim.example/newest")
        check(trimEvents.count == 1, "A coalesced revisit trims nothing")
        // Clearing: only after a successful commit.
        events.removeAll()
        check(eventful.clearHistory() && events == [.cleared] && eventful.history.isEmpty, "A successful clear sends cleared, after the commit")
        // Storage failures: an accepted visit is still a visit (no durability claim); a failed clear rolls back silently.
        struct WriteRefused: Error {}
        let failingFile = root.appendingPathComponent("failing/library.json")
        let failing = BrowserLibrary(storageURL: failingFile, write: { _, _ in throw WriteRefused() })
        var failingEvents: [BrowserLibrary.HistoryChange] = []
        failing.onHistoryChange = { failingEvents.append($0) }
        failing.recordVisit(title: "Kept in memory", address: "https://failing.example/a")
        _ = failing.flush()
        check(failingEvents == [.visited(failing.history[0])] && failing.history.count == 1 && failing.lastStorageError != nil,
              "A visit accepted in memory sends visited even though its write failed")
        failingEvents.removeAll()
        check(!failing.clearHistory() && failingEvents.isEmpty && failing.history.count == 1, "A failed clear rolls back and sends nothing")
        // Startup load sends nothing; an unwritable (future-version) library sends nothing either.
        let loadedFile = root.appendingPathComponent("events/library.json")
        let seeding = BrowserLibrary(storageURL: loadedFile)
        seeding.recordVisit(title: "Saved", address: "https://saved.example/")
        check(seeding.flush(), "Fixture library saved")
        var loadEvents: [BrowserLibrary.HistoryChange] = []
        let reloaded = BrowserLibrary(storageURL: loadedFile)
        reloaded.onHistoryChange = { loadEvents.append($0) }
        check(reloaded.history.count == 1 && loadEvents.isEmpty, "Loading history at startup sends nothing")
        let futureFile = root.appendingPathComponent("future-events/library.json")
        try FileManager.default.createDirectory(at: futureFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 99, "history": [], "closedRecords": []]).write(to: futureFile)
        let futureLibrary = BrowserLibrary(storageURL: futureFile)
        var futureEvents: [BrowserLibrary.HistoryChange] = []
        futureLibrary.onHistoryChange = { futureEvents.append($0) }
        futureLibrary.recordVisit(title: "Refused", address: "https://future.example/")
        check(!futureLibrary.clearHistory() && futureEvents.isEmpty, "When the library can't be changed, nothing is sent")
        check(futureLibrary.recordVisit(title: "Refused", address: "https://future.example/") == nil, "A refused visit has no token")

        // Late document titles (history-title-approval.md): only the recorded visit's title changes.
        final class Writes: @unchecked Sendable {
            private let lock = NSLock(); private var value = 0
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
            func add() { lock.lock(); value += 1; lock.unlock() }
        }
        let writes = Writes()
        let titledFile = root.appendingPathComponent("titles/library.json")
        let titled = BrowserLibrary(storageURL: titledFile, write: { snapshot, url in writes.add(); try LibraryWriter.writeFile(snapshot, to: url) })
        var titleEvents: [BrowserLibrary.HistoryChange] = []
        titled.onHistoryChange = { titleEvents.append($0) }
        check(titled.recordVisit(title: "", address: "orbit://newtab") == nil, "A rejected visit has no token")
        let beta = titled.recordVisit(title: "", address: "http://127.0.0.1:9/bookmarks/beta.html")!
        check(titled.history[0].title == "127.0.0.1", "Empty title at didFinish: the host stands in (the observed defect)")
        let betaBefore = titled.history[0]
        let other = titled.recordVisit(title: "Other", address: "https://other.example/")!
        check(titled.flush(), "Fixture visits saved")
        titleEvents.removeAll()
        let writesBefore = writes.count
        check(titled.updateVisitTitle("Bam bookmark beta", for: beta), "The late title corrects the recorded visit")
        let betaAfter = titled.history[1]
        check(betaAfter.id == betaBefore.id && betaAfter.visitedAt == betaBefore.visitedAt && betaAfter.address == betaBefore.address
              && betaAfter.title == "Bam bookmark beta" && titled.history.count == 2 && titled.history[0].id == other.id
              && titled.history[0].title == "Other", "Only that entry's title changes: same id, time, order and count; the newer entry is untouched")
        check(titleEvents.isEmpty, "A title correction sends no event (no new visit)")
        check(titled.flush() && writes.count == writesBefore + 1, "The correction is one ordered write")
        let reread = BrowserLibrary(storageURL: titledFile)
        check(reread.history.map(\.title) == ["Other", "Bam bookmark beta"] && abs(reread.history[1].visitedAt.timeIntervalSince(betaBefore.visitedAt)) < 0.002,
              "The corrected title is saved with the original visit time (stored to the millisecond)")
        check(reread.recordVisit(title: "x", address: "https://reread.example/") != nil && !reread.updateVisitTitle("Stolen", for: beta),
              "A token from another library instance (or a startup-loaded entry) never matches")
        // Rejected corrections change and write nothing.
        let quiet = writes.count
        check(!titled.updateVisitTitle("Bam bookmark beta", for: beta), "An unchanged title is refused")
        check(!titled.updateVisitTitle("   ", for: beta) && !titled.updateVisitTitle("", for: beta), "An empty title is refused")
        let wrongAddress = BrowserLibrary.VisitToken(id: beta.id, address: "http://127.0.0.1:9/bookmarks/alpha.html", revision: beta.revision)
        check(!titled.updateVisitTitle("Wrong", for: wrongAddress), "Another address is refused even with the right id and revision")
        check(titled.flush() && writes.count == quiet && titled.history[1].title == "Bam bookmark beta", "Refused corrections write nothing")
        // A coalesced revisit reuses the id: the earlier visit's late title must not overwrite the newer visit.
        let revisitFirst = titled.recordVisit(title: "", address: "https://same.example/page")!
        let revisitSecond = titled.recordVisit(title: "Newer visit", address: "https://same.example/page")!
        check(revisitFirst.id == revisitSecond.id && revisitFirst.revision != revisitSecond.revision, "A coalesced revisit keeps the id with a new revision")
        check(!titled.updateVisitTitle("Older document", for: revisitFirst) && titled.history[0].title == "Newer visit",
              "The earlier visit's late title is stale after the coalesced revisit")
        check(titled.updateVisitTitle("Newer document", for: revisitSecond) && titled.history[0].title == "Newer document", "The newest visit's title applies")
        // Trimmed and cleared visits.
        let trimTitles = BrowserLibrary(storageURL: nil)
        let oldestToken = trimTitles.recordVisit(title: "", address: "https://oldest.example/")!
        for n in 0..<5_000 { trimTitles.recordVisit(title: "F\(n)", address: "https://fill.example/\(n)") }
        check(!trimTitles.updateVisitTitle("Late", for: oldestToken) && !trimTitles.history.contains { $0.title == "Late" }, "A trimmed visit can't be retitled")
        let survivor = trimTitles.recordVisit(title: "", address: "https://survivor.example/")!
        check(trimTitles.clearHistory() && !trimTitles.updateVisitTitle("Late", for: survivor) && trimTitles.history.isEmpty, "A cleared visit can't be retitled")
        let failingTitles = BrowserLibrary(storageURL: root.appendingPathComponent("failing-titles/library.json"), write: { _, _ in throw WriteRefused() })
        let kept = failingTitles.recordVisit(title: "", address: "https://kept.example/")!
        check(!failingTitles.clearHistory() && failingTitles.updateVisitTitle("Still here", for: kept) && failingTitles.history[0].title == "Still here",
              "A failed clear keeps the visit retitlable; a failing write keeps the in-memory title")

        // The per-view follow-up: current document and profile only; only accepted changes use the budget.
        let profile = UUID(), elsewhere = UUID()
        let follow = BrowserLibrary(storageURL: nil)
        let page = URL(string: "http://127.0.0.1:9/passwords/plain.html")!
        var followUp = HistoryTitleFollowUp(profileID: profile, visit: follow.recordVisit(title: "", address: page.absoluteString)!)
        check(followUp.candidate(url: page, title: "Bam plain login comparison", profileID: profile) == "Bam plain login comparison", "Same document and profile: offered")
        check(followUp.candidate(url: URL(string: page.absoluteString + "#x"), title: "T", profileID: profile) == nil
              && followUp.candidate(url: URL(string: "http://127.0.0.1:9/bookmarks/beta.html"), title: "T", profileID: profile) == nil,
              "A fragment change or another document is skipped (an old title delivered after a new navigation can't land)")
        check(followUp.candidate(url: page, title: "T", profileID: elsewhere) == nil && followUp.candidate(url: page, title: "T", profileID: nil) == nil,
              "Another or unknown profile is skipped")
        check(!followUp.apply(url: page, title: "", profileID: profile, library: follow) && !followUp.apply(url: page, title: nil, profileID: profile, library: follow)
              && !followUp.apply(url: page, title: "T", profileID: profile, library: nil) && followUp.updates == 0, "Empty, missing or no library: budget untouched")
        check(followUp.apply(url: page, title: "Bam plain login comparison", profileID: profile, library: follow) && followUp.updates == 1
              && follow.history[0].title == "Bam plain login comparison", "An accepted change counts once")
        for _ in 0..<10 { _ = followUp.apply(url: page, title: "Bam plain login comparison", profileID: profile, library: follow) }
        check(followUp.updates == 1, "Repeated unchanged observations don't use the budget")
        for n in 2...5 { check(followUp.apply(url: page, title: "Title \(n)", profileID: profile, library: follow), "Change \(n) accepted") }
        check(followUp.isSpent && !followUp.apply(url: page, title: "Title 6", profileID: profile, library: follow) && follow.history[0].title == "Title 5",
              "After five accepted changes nothing more is written")
        // Two tabs, same URL: the coalesced revisit invalidates the first tab's follow-up.
        let shared = URL(string: "https://shared.example/")!
        var firstTab = HistoryTitleFollowUp(profileID: profile, visit: follow.recordVisit(title: "", address: shared.absoluteString)!)
        var secondTab = HistoryTitleFollowUp(profileID: profile, visit: follow.recordVisit(title: "Second", address: shared.absoluteString)!)
        check(!firstTab.apply(url: shared, title: "First tab's old title", profileID: profile, library: follow) && firstTab.updates == 0
              && follow.history[0].title == "Second", "The earlier tab's late title doesn't overwrite the newer visit, and costs nothing")
        check(secondTab.apply(url: shared, title: "Second document", profileID: profile, library: follow) && follow.history[0].title == "Second document",
              "The newer tab's title applies")
        print("PASS: \(checks) library metadata checks")
    }
}
