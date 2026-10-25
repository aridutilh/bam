import AppKit

/// The library → extension history mapping, end to end through a real BrowserLibrary (no WebKit, no app).
@main @MainActor enum LibraryHistoryEventsTests {
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        typealias Events = LibraryHistoryEvents
        var sent: [ExtensionHistory.Change] = []
        let library = BrowserLibrary(storageURL: nil)
        library.onHistoryChange = { change in if let event = Events.change(change, history: library.history) { sent.append(event) } }

        library.recordVisit(title: "Docs", address: "https://docs.example/a")
        let entry = library.history[0]
        require(sent == [.visited(ExtensionHistory.Visit(url: "https://docs.example/a", title: "Docs", visitedAt: entry.visitedAt))],
                "A visit maps to visited with the stored address, title and time unchanged")
        library.recordVisit(title: "Mail", address: "https://mail.example/")
        require(Events.snapshot(library.history).map(\.url) == ["https://mail.example/", "https://docs.example/a"], "Snapshots are newest first")
        sent.removeAll()

        // Trim: a dropped URL that a retained visit still has is not removed; one that's gone entirely is.
        let trimming = BrowserLibrary(storageURL: nil)
        trimming.recordVisit(title: "Oldest", address: "https://keep.example/")          // will be trimmed, but revisited below
        trimming.recordVisit(title: "Gone", address: "https://gone.example/")            // will be trimmed and not retained
        for n in 0..<4_997 { trimming.recordVisit(title: "Fill \(n)", address: "https://fill.example/\(n)") }
        trimming.recordVisit(title: "Keep again", address: "https://keep.example/")      // 5,000 entries, keep.example retained
        var trimEvents: [ExtensionHistory.Change] = []
        trimming.onHistoryChange = { change in if let event = Events.change(change, history: trimming.history) { trimEvents.append(event) } }
        trimming.recordVisit(title: "New 1", address: "https://new.example/1")           // drops the oldest: keep.example (still retained)
        require(trimEvents.count == 1, "A trimmed URL that a retained visit still has sends no removal: \(trimEvents)")
        trimEvents.removeAll()
        trimming.recordVisit(title: "New 2", address: "https://new.example/2")           // drops gone.example (no other visit)
        require(trimEvents.count == 2 && trimEvents[1] == .removed(urls: ["https://gone.example/"]),
                "A URL with no retained visit is removed, after the visit that caused it: \(trimEvents)")
        require(Events.change(.trimmed(addresses: ["https://x.example/", "https://x.example/"]), history: []) == .removed(urls: ["https://x.example/"]),
                "Removed URLs are deduplicated")

        // Clear and failures follow the library: cleared only after a successful commit.
        sent.removeAll()
        require(library.clearHistory() && sent == [.cleared] && Events.snapshot(library.history).isEmpty, "A successful clear maps to cleared")
        struct Refused: Error {}
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let failing = BrowserLibrary(storageURL: dir.appendingPathComponent("history-events-\(UUID().uuidString)/library.json"), write: { _, _ in throw Refused() })
        var failingSent: [ExtensionHistory.Change] = []
        failing.onHistoryChange = { change in if let event = Events.change(change, history: failing.history) { failingSent.append(event) } }
        failing.recordVisit(title: "In memory", address: "https://memory.example/")
        _ = failing.flush()
        require(failingSent.count == 1 && Events.snapshot(failing.history).map(\.url) == ["https://memory.example/"],
                "An accepted visit whose write failed is both an event and in the snapshot (same in-memory history)")
        failingSent.removeAll()
        require(!failing.clearHistory() && failingSent.isEmpty && Events.snapshot(failing.history).count == 1, "A failed clear sends nothing and keeps history")
        // Review of 64404ab: the snapshot reads memory only. An absent library is nil (no load on request).
        let saved = dir.appendingPathComponent("history-snapshot-\(UUID().uuidString)/library.json")
        let writer = BrowserLibrary(storageURL: saved)
        writer.recordVisit(title: "On disk", address: "https://disk.example/")
        require(writer.flush(), "Fixture history saved to disk")
        require(Events.snapshot(of: nil, available: true) == nil, "No library in memory: nil, even though history exists on disk")
        require(Events.snapshot(of: writer, available: false) == nil, "Unavailable (private, closing, switching, unknown profile): nil")
        require(Events.snapshot(of: writer, available: true)?.map(\.url) == ["https://disk.example/"], "A loaded library is read from memory")
        print("PASS: \(checks) library history event checks")
    }
}
