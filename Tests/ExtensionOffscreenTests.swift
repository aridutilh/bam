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

        // A fake host: each document loads until the test finishes it. Discard cancels a
        // pending load immediately, as the web-view host does; `ignoresCancel` models a
        // host whose load outcome still arrives late, to prove generations stay separate.
        final class Load { var waiter: CheckedContinuation<Void, Error>?; var outcome: Result<Void, Error>?; var ignoresCancel = false
            func finish(_ result: Result<Void, Error>) { guard outcome == nil else { return }; outcome = result; let w = waiter; waiter = nil; w?.resume(with: result) } }
        var loads: [ObjectIdentifier: Load] = [:], started: [String] = [], discarded: [String] = []
        var autoFinish = true
        let documents = Documents(start: { owner, url in
            started.append(owner + ":" + url.lastPathComponent)
            let document = FakeDocument(url), load = Load()
            loads[ObjectIdentifier(document)] = load
            if autoFinish { load.outcome = .success(()) }
            return (document, {
                if let outcome = load.outcome { return try outcome.get() }
                try await withCheckedThrowingContinuation { load.waiter = $0 }
            })
        }, discard: { document in
            discarded.append(document.url.lastPathComponent)
            if let load = loads.removeValue(forKey: ObjectIdentifier(document)), !load.ignoresCancel { load.finish(.failure(Failure(description: "cancelled"))) }
        })
        func loadOf(_ owner: String) -> Load? { documents.currentDocument(for: owner).flatMap { loads[ObjectIdentifier($0)] } }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        let page = base.appendingPathComponent("a.html")

        // One document per extension, enforced from the start of loading.
        autoFinish = false
        let first = Task { await message { try await documents.create(owner: "A", url: page) } }
        while loadOf("A")?.waiter == nil { await Task.yield() }
        try check(documents.has("A") && documents.entry(for: "A")?.isLoaded == false, "A loading document was not reported")
        try check(await message { try await documents.create(owner: "A", url: page) } == Documents.alreadyExists,
                  "A concurrent second create did not fail with Chrome's exact message")
        autoFinish = true
        try check(await message { try await documents.create(owner: "B", url: base.appendingPathComponent("b.html")) } == nil && documents.has("B"),
                  "Another extension's document was blocked by the first")
        loadOf("A")?.finish(.success(()))
        try check(await first.value == nil && documents.entry(for: "A")?.isLoaded == true && documents.document(for: "A")?.url == page,
                  "The first create did not finish after loading")
        try check(started == ["A:a.html", "B:b.html"], "A rejected create started a document: \(started)")

        // close: discards exactly that document; a second close reports none.
        try check(await message { try documents.close(owner: "A") } == nil && !documents.has("A") && discarded == ["a.html"], "close did not discard the document")
        try check(await message { try documents.close(owner: "A") } == Documents.noDocument, "Closing a missing document did not fail with Chrome's message")
        try check(documents.has("B"), "Closing one extension's document affected another")

        // A failed load is discarded, leaves no slot, and allows a retry.
        autoFinish = false
        let failing = Task { await message { try await documents.create(owner: "A", url: base.appendingPathComponent("fail.html")) } }
        while loadOf("A")?.waiter == nil { await Task.yield() }
        loadOf("A")?.finish(.failure(Failure(description: "load failed")))
        try check(await failing.value == "load failed" && !documents.has("A") && discarded.last == "fail.html", "A failed load left a slot or a live document")
        autoFinish = true
        try check(await message { try await documents.create(owner: "A", url: page) } == nil && documents.has("A"), "Create after a failed load was refused")
        documents.discard(owner: "A")

        // Close during a stalled load: the document is discarded before close returns, the
        // pending create rejects at once, and its last reference is gone.
        autoFinish = false
        weak var stalled: FakeDocument?
        let stalledCreate = Task { await message { try await documents.create(owner: "A", url: base.appendingPathComponent("stalled.html")) } }
        while loadOf("A")?.waiter == nil { await Task.yield() }
        stalled = documents.currentDocument(for: "A")
        try documents.close(owner: "A")
        try check(discarded.last == "stalled.html" && !documents.has("A") && stalled == nil, "Close during loading did not discard and release the pending document")
        try check(await stalledCreate.value == Documents.closedWhileLoading, "The pending create did not reject after close")

        // Recreate while an old load's outcome is still in flight: the late success must
        // neither promote nor close the replacement.
        let lateCreate = Task { await message { try await documents.create(owner: "A", url: base.appendingPathComponent("old.html")) } }
        while loadOf("A")?.waiter == nil { await Task.yield() }
        let oldLoad = loadOf("A")!; oldLoad.ignoresCancel = true
        documents.discard(owner: "A")
        let replacement = Task { await message { try await documents.create(owner: "A", url: base.appendingPathComponent("new.html")) } }
        while loadOf("A")?.waiter == nil { await Task.yield() }
        oldLoad.finish(.success(()))
        try check(await lateCreate.value == Documents.closedWhileLoading, "A replaced generation's late success was not rejected")
        await settle()
        try check(documents.currentDocument(for: "A")?.url.lastPathComponent == "new.html" && documents.entry(for: "A")?.isLoaded == false,
                  "A late outcome changed the replacement document")
        loadOf("A")?.finish(.success(()))
        try check(await replacement.value == nil && documents.document(for: "A")?.url.lastPathComponent == "new.html", "The replacement did not open")
        documents.discard(owner: "A")

        // Revocation (discard) mid-load behaves like close; so does profile shutdown.
        let revoked = Task { await message { try await documents.create(owner: "A", url: base.appendingPathComponent("revoked.html")) } }
        while loadOf("A")?.waiter == nil { await Task.yield() }
        documents.discard(owner: "A")
        let revokedOutcome = await revoked.value
        try check(!documents.has("A") && discarded.last == "revoked.html" && revokedOutcome == Documents.closedWhileLoading, "Revocation during loading left the document")
        let shutdown = Task { await message { try await documents.create(owner: "E", url: base.appendingPathComponent("shutdown.html")) } }
        while loadOf("E")?.waiter == nil { await Task.yield() }
        documents.discardAll()
        let shutdownOutcome = await shutdown.value
        try check(!documents.has("E") && !documents.has("B") && shutdownOutcome == Documents.closedWhileLoading, "discardAll left a loading or open document")
        autoFinish = true

        // The host losing its document frees the slot; a stale report does not.
        try await documents.create(owner: "A", url: page)
        documents.documentEnded(FakeDocument(page), owner: "A")
        try check(documents.has("A"), "A stale termination report closed the live document")
        documents.documentEnded(documents.document(for: "A")!, owner: "A")
        try check(!documents.has("A"), "Terminated document remained registered")

        // Repeated cycles do not accumulate, and a discarded document is released.
        for _ in 0..<20 { try await documents.create(owner: "C", url: page); try documents.close(owner: "C") }
        try check(!documents.has("C") && loads.isEmpty, "Create/close cycles left documents or loads behind")
        weak var released: FakeDocument?
        do { try await documents.create(owner: "D", url: page); released = documents.document(for: "D"); documents.discard(owner: "D") }
        try check(released == nil, "A discarded document was retained")
        return checks
    }
}
