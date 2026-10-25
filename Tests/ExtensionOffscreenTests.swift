import Foundation

/// Offscreen-document rules and lifecycle with a fake loader: no web views or profiles.
@main @MainActor enum ExtensionOffscreenTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class FakeDocument { let url: URL; init(_ url: URL) { self.url = url } }
    typealias Documents = ExtensionOffscreenDocuments<FakeDocument>

    static func main() async {
        do { print("PASS: Extension offscreen — \(try await run()) checks") }
        catch { fputs("FAIL: Extension offscreen: \(error)\n", stderr); exit(1) }
    }

    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        func message(_ work: () async throws -> Void) async -> String? {
            do { try await work(); return nil } catch { return String(describing: error) }
        }
        let base = URL(string: "webkit-extension://4f1c0a5e-0000-4000-8000-000000000001/")!

        // Parameters: own pages only, known reasons, a justification.
        try check(try Documents.validate(url: "offscreen/index.html", reasons: ["CLIPBOARD"], justification: "copy", baseURL: base).absoluteString
                  == base.absoluteString + "offscreen/index.html", "Relative offscreen path did not resolve inside the extension")
        try check(try Documents.validate(url: base.absoluteString + "doc.html?x=1", reasons: ["WORKERS", "BLOBS"], justification: "x", baseURL: base).query == "x=1",
                  "Absolute own URL was not accepted")
        for (url, reasons, justification) in [("https://example.com/x.html", ["CLIPBOARD"], "x"), ("webkit-extension://other/x.html", ["CLIPBOARD"], "x"),
                                              ("//other/x.html", ["CLIPBOARD"], "x"), ("x.html", [], "x"), ("x.html", ["KEEP_ALIVE"], "x"), ("x.html", ["CLIPBOARD"], "  ")] {
            try check((try? Documents.validate(url: url, reasons: reasons, justification: justification, baseURL: base)) == nil,
                      "Invalid offscreen parameters were accepted: \(url) \(reasons) \(justification.debugDescription)")
        }

        // One document per extension, enforced from the start of loading.
        var loads: [String] = [], discarded: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdNextLoad = false, failNextLoad = false
        let documents = Documents(load: { owner, url in
            loads.append(owner)
            if holdNextLoad { holdNextLoad = false; await withCheckedContinuation { gate = $0 } }
            if failNextLoad { failNextLoad = false; throw Failure(description: "load failed") }
            return FakeDocument(url)
        }, discard: { discarded.append($0.url.lastPathComponent) })
        let page = base.appendingPathComponent("a.html")
        holdNextLoad = true
        let first = Task { await message { try await documents.create(owner: "A", url: page) } }
        while gate == nil { await Task.yield() }
        try check(documents.has("A") && documents.entry(for: "A")?.isLoaded == false, "A loading document was not reported")
        try check(await message { try await documents.create(owner: "A", url: page) } == Documents.alreadyExists,
                  "A concurrent second create did not fail with Chrome's exact message")
        try check(await message { try await documents.create(owner: "B", url: base.appendingPathComponent("b.html")) } == nil && documents.has("B"),
                  "Another extension's document was blocked by the first")
        gate?.resume(); gate = nil
        try check(await first.value == nil && documents.entry(for: "A")?.isLoaded == true && documents.document(for: "A")?.url == page,
                  "The first create did not finish after loading")
        try check(loads == ["A", "B"], "A rejected create still loaded a document: \(loads)")

        // close: discards exactly that document; a second close reports none.
        try check(await message { try documents.close(owner: "A") } == nil && !documents.has("A") && discarded == ["a.html"], "close did not discard the document")
        try check(await message { try documents.close(owner: "A") } == Documents.noDocument, "Closing a missing document did not fail with Chrome's message")
        try check(documents.has("B"), "Closing one extension's document affected another")

        // A failed load leaves no document behind and allows a retry.
        failNextLoad = true
        try check(await message { try await documents.create(owner: "A", url: page) } == "load failed" && !documents.has("A"), "A failed load left a slot behind")
        try check(await message { try await documents.create(owner: "A", url: page) } == nil && documents.has("A"), "Create after a failed load was refused")

        // Disable/revoke during loading: the late document is discarded and creation fails.
        documents.discard(owner: "A")
        holdNextLoad = true
        let interrupted = Task { await message { try await documents.create(owner: "A", url: base.appendingPathComponent("late.html")) } }
        while gate == nil { await Task.yield() }
        documents.discard(owner: "A")
        try check(!documents.has("A"), "Discard during loading kept the slot")
        gate?.resume(); gate = nil
        try check(await interrupted.value == Documents.closedWhileLoading && discarded.last == "late.html" && !documents.has("A"),
                  "A document finishing after discard was kept")

        // The host losing its document frees the slot; a stale report does not.
        try await documents.create(owner: "A", url: page)
        let stale = FakeDocument(page)
        documents.documentEnded(stale, owner: "A")
        try check(documents.has("A"), "A stale termination report closed the live document")
        documents.documentEnded(documents.document(for: "A")!, owner: "A")
        try check(!documents.has("A"), "Terminated document remained registered")

        // Profile shutdown discards everything; repeated cycles do not accumulate.
        for cycle in 0..<20 { try await documents.create(owner: "C", url: page); try documents.close(owner: "C"); _ = cycle }
        try check(!documents.has("C"), "Create/close cycles left a document")
        try await documents.create(owner: "A", url: page)
        documents.discardAll()
        try check(!documents.has("A") && !documents.has("B"), "discardAll left documents open")
        weak var released: FakeDocument?
        do { try await documents.create(owner: "D", url: page); released = documents.document(for: "D"); documents.discard(owner: "D") }
        try check(released == nil, "A discarded document was retained")
        return checks
    }
}
