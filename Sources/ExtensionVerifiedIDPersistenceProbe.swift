import AppKit
import WebKit

/// Phase 2 of the verified-ID measurement (`--extension-test --extension-verified-id-phase2 write|read|cleanup
/// [--run <dir>]`): does storage.local keyed by a Chrome-shaped runtime.id (UUID base URL host) survive a real process
/// relaunch, per profile, with a legacy UUID-ID control? Public WebKit API only, no Bam extension manager. Two fresh
/// random persistent controller namespaces (`Configuration(identifier:)`) with explicit non-persistent website stores,
/// so only extension storage persists. Cleanup unloads first, removes every owned data record through
/// `removeData(ofTypes:from:)` and re-queries until empty. Public API cannot delete a namespace's directory; the two
/// namespace identifiers are reported as possibly remaining metadata. Exit 0 complete, 2 incomplete, 3 refused.
@available(macOS 15.4, *)
@MainActor enum ExtensionVerifiedIDPersistenceProbe {
    typealias Manifest = ExtensionVerifiedIDPhase2Manifest
    enum Mode: String { case write, read, cleanup }
    struct Refusal: Error, CustomStringConvertible { let description: String }
    static let budget: TimeInterval = 60
    /// Every persistent extension namespace Bam itself uses: the two defaults plus every profile named by the Bam and
    /// persistent Bam Preview session files (profile and Space profile IDs only) and their Profiles/ folder names.
    /// Read-only; nothing else from those files is kept. An existing session that cannot be read refuses the run.
    static func knownBamNamespaces() throws -> Set<UUID> {
        let fm = FileManager.default
        var known: Set<UUID> = [PreviewProfile.defaultStoreIdentifier, BrowserProfile.defaultID]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["OrbitPrototype", "BamPreview"] {
            let directory = support.appendingPathComponent(name, isDirectory: true)
            let session = directory.appendingPathComponent("session.json")
            if fm.fileExists(atPath: session.path) {
                let values = try? session.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= 64 * 1_048_576,
                      let data = try? Data(contentsOf: session, options: .mappedIfSafe), let ids = Manifest.profileNamespaces(sessionJSON: data) else {
                    throw Refusal(description: "The \(name) session could not be read to exclude its profiles; nothing was done.")
                }
                known.formUnion(ids)
            }
            let profiles = directory.appendingPathComponent("Profiles", isDirectory: true)
            if let names = try? fm.contentsOfDirectory(atPath: profiles.path) { known.formUnion(names.compactMap(UUID.init(uuidString:))) }
        }
        return known
    }

    static func run(mode: Mode, runDirectory: URL?, pageURL: URL) async -> Int32 {
        let released = ExtensionVerifiedIDProbe.Released()
        var output: [String: Any] = ["mode": mode.rawValue, "scope": "phase2: persistent extension storage across processes; website stores non-persistent"]
        var complete = false, refused = false, keepDirectory = true, directory: URL?
        do {
            var excluded = 0
            defer { output["excludedBamNamespaces"] = excluded }
            let (manifest, runDirectory) = try prepare(mode: mode, runDirectory: runDirectory, excludedCount: &excluded)
            directory = runDirectory
            output["run"] = runDirectory.path
            output["namespaces"] = [manifest.controllerA.uuidString, manifest.controllerB.uuidString]
            let deadline = ProcessInfo.processInfo.systemUptime + budget
            switch mode {
            case .write: complete = try await write(manifest, directory: runDirectory, pageURL: pageURL, released: released, deadline: deadline, output: &output)
            case .read:
                complete = try await read(manifest, directory: runDirectory, released: released, deadline: deadline, output: &output)
                keepDirectory = !complete
            case .cleanup:
                complete = try await cleanupOnly(manifest, directory: runDirectory, released: released, output: &output)
                keepDirectory = !complete
            }
        } catch let refusal as Refusal {
            refused = true; output["refused"] = refusal.description
        } catch {
            output["failure"] = String(describing: error)
        }
        // Release before touching the run directory; an unreleased run keeps it.
        let releaseDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !released.pending.isEmpty && ProcessInfo.processInfo.systemUptime < releaseDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        output["notReleased"] = released.pending
        if !released.pending.isEmpty { complete = false; keepDirectory = true }
        if let directory, !keepDirectory, mode != .write { try? FileManager.default.removeItem(at: directory) }
        output["runDirectoryKept"] = directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        output["namespaceMetadata"] = "Public WebKit API cannot delete a persistent controller namespace; its directory may remain (identifiers above)."
        let json = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("EXTENSION_VERIFIED_ID_PHASE2 \(json)")
        print("MEASUREMENT \(refused ? "refused" : complete ? "complete" : "incomplete") (\(mode.rawValue))"); fflush(stdout)
        return refused ? 3 : complete ? 0 : 2
    }

    // MARK: Manifest

    private static func prepare(mode: Mode, runDirectory: URL?, excludedCount: inout Int) throws -> (Manifest, URL) {
        let fm = FileManager.default, root = Manifest.taskRoot()
        // Applied in every mode, before any controller exists.
        let forbidden = try knownBamNamespaces()
        excludedCount = forbidden.count
        if mode == .write {
            guard runDirectory == nil else { throw Refusal(description: "write creates its own run directory; --run is not accepted") }
            let manifest = Manifest.fresh(probeID: ExtensionVerifiedIDProbe.probeID)
            let directory = root.appendingPathComponent(manifest.runID.uuidString.lowercased(), isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let reason = manifest.refusal(directory: directory, root: root, forbidden: forbidden, probeID: ExtensionVerifiedIDProbe.probeID) { throw Refusal(description: reason) }
            try save(manifest, in: directory)
            return (manifest, directory)
        }
        guard let directory = runDirectory else { throw Refusal(description: "\(mode.rawValue) needs --run <directory>") }
        let file = directory.appendingPathComponent("manifest.json")
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true, (values?.fileSize ?? .max) <= 16_384,
              let data = try? Data(contentsOf: file), let manifest = try? JSONDecoder.phase2.decode(Manifest.self, from: data) else {
            throw Refusal(description: "No readable task-owned manifest in the run directory.")
        }
        if let reason = manifest.refusal(directory: directory, root: root, forbidden: forbidden, probeID: ExtensionVerifiedIDProbe.probeID) { throw Refusal(description: reason) }
        if mode == .read, !manifest.written { throw Refusal(description: "write did not complete for this run; use cleanup.") }
        return (manifest, directory)
    }
    private static func save(_ manifest: Manifest, in directory: URL) throws {
        try JSONEncoder.phase2.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    // MARK: Controllers, contexts, pages

    private final class Session {
        var controllers: [(String, WKWebExtensionController, WKWebsiteDataStore)] = []
        var contexts: [(WKWebExtensionController, WKWebExtensionContext)] = []
        var views: [WKWebView] = []
        func unloadAll() {
            for view in views { view.stopLoading() }
            views.removeAll()
            for (controller, context) in contexts where context.isLoaded { try? controller.unload(context) }
            contexts.removeAll()
        }
    }
    private static func controller(_ name: String, _ namespace: UUID, session: Session, released: ExtensionVerifiedIDProbe.Released) -> WKWebExtensionController {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebExtensionController.Configuration(identifier: namespace)
        configuration.defaultWebsiteDataStore = store
        configuration.webViewConfiguration.websiteDataStore = store
        let made = WKWebExtensionController(configuration: configuration)
        session.controllers.append((name, made, store))
        released.track("controller \(name)", made); released.track("website store \(name)", store)
        return made
    }
    private static func load(_ controller: WKWebExtensionController, id: String, host: UUID, package: URL, name: String, session: Session,
                             released: ExtensionVerifiedIDProbe.Released, deadline: TimeInterval) async throws -> WKWebExtensionContext {
        guard let ext = try await ExtensionVerifiedIDProbe.bounded(10, by: deadline, "\(name) package", { try? await WKWebExtension(resourceBaseURL: package) }) else {
            throw ExtensionVerifiedIDProbe.Failure(description: "\(name): the package could not be read")
        }
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "webkit-extension://\(host.uuidString.lowercased())/")!
        context.grantedPermissions = [.storage: .distantFuture]
        try controller.load(context)
        session.contexts.append((controller, context)); released.track("context \(name)", context)
        _ = try await ExtensionVerifiedIDProbe.bounded(10, by: deadline, "\(name) worker start") {
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in context.loadBackgroundContent { _ in done.resume(returning: true) } }
        }
        return context
    }
    private static func page(_ context: WKWebExtensionContext, store: WKWebsiteDataStore, name: String, session: Session,
                             released: ExtensionVerifiedIDProbe.Released, deadline: TimeInterval) async throws -> (WKWebView, [String: Any]) {
        guard let configuration = context.webViewConfiguration else { throw ExtensionVerifiedIDProbe.Failure(description: "\(name): no page configuration") }
        configuration.websiteDataStore = store
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        session.views.append(view); released.track("page \(name)", view)
        view.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        return (view, try await ExtensionVerifiedIDProbe.poll(view, key: "bamIdentity", name: name, deadline: deadline))
    }
    /// {ok: true, wrote, value} or {ok: false, stage, error}; "(absent)" is a valid value.
    private static func storage(_ view: WKWebView, set value: String?, name: String, deadline: TimeInterval) async throws -> [String: Any] {
        let write = value.map { "await api.storage.local.set({probe: \(ExtensionCompatibilityBridge.json($0))}); wrote = true;" } ?? ""
        let script = """
            const api = globalThis.browser || globalThis.chrome; let wrote = false;
            try { \(write) const got = await api.storage.local.get('probe');
                  return {ok: true, wrote, value: got.probe === undefined ? '(absent)' : String(got.probe)}; }
            catch (error) { return {ok: false, stage: 'script', error: String(error && error.message || error)}; }
            """
        let answer: [String: Any]? = try await ExtensionVerifiedIDProbe.bounded(5, by: deadline, "\(name) storage") { [weak view] in
            guard let view else { return ["ok": false, "stage": "transport", "error": "page released"] }
            do { return try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? ["ok": false, "stage": "transport", "error": "non-object reply"] }
            catch { return ["ok": false, "stage": "transport", "error": String(describing: error)] }
        }
        return answer ?? ["ok": false, "stage": "transport", "error": "no reply"]
    }
    private static func records(_ controller: WKWebExtensionController, deadline: TimeInterval, name: String) async throws -> [WKWebExtension.DataRecord] {
        guard let found = try await ExtensionVerifiedIDProbe.bounded(10, by: deadline, "\(name) data records", { await controller.dataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes) }) else {
            throw ExtensionVerifiedIDProbe.Failure(description: "\(name): data records unavailable")
        }
        return found
    }
    private static func describe(_ records: [WKWebExtension.DataRecord]) -> [[String: Any]] {
        records.map { ["id": $0.uniqueIdentifier, "types": $0.containedDataTypes.map(\.rawValue).sorted(), "bytes": $0.totalSizeInBytes,
                       "errors": $0.errors.map(\.localizedDescription)] }
    }
    private static func ok(_ result: [String: Any], equals expected: String) -> Bool { result["ok"] as? Bool == true && result["value"] as? String == expected }
    /// The namespace holds exactly the records this run's write created (no more, no fewer).
    private static func identifiers(_ records: [WKWebExtension.DataRecord]) -> Set<String> { Set(records.map(\.uniqueIdentifier)) }
    static func expectedRecords(_ manifest: Manifest) -> (a: Set<String>, b: Set<String>) { ([manifest.probeID, manifest.legacyID], [manifest.probeID]) }

    // MARK: Modes

    private static func write(_ manifest: Manifest, directory: URL, pageURL: URL, released: ExtensionVerifiedIDProbe.Released, deadline: TimeInterval,
                              output: inout [String: Any]) async throws -> Bool {
        let package = directory.appendingPathComponent("package", isDirectory: true)
        try ExtensionVerifiedIDProbe.writePackage(package, pageURL: pageURL)
        let session = Session()
        defer { session.unloadAll(); session.controllers.removeAll() }
        let a = controller("A", manifest.controllerA, session: session, released: released), b = controller("B", manifest.controllerB, session: session, released: released)
        // Fresh namespaces only: refuse before writing anything if either already holds data.
        let before = (try await records(a, deadline: deadline, name: "A"), try await records(b, deadline: deadline, name: "B"))
        guard before.0.isEmpty && before.1.isEmpty else {
            output["preexisting"] = ["A": describe(before.0), "B": describe(before.1)]
            throw Refusal(description: "A controller namespace already holds extension data; nothing was written.")
        }
        let storeA = session.controllers[0].2, storeB = session.controllers[1].2
        let contextA = try await load(a, id: manifest.probeID, host: manifest.hostA, package: package, name: "A", session: session, released: released, deadline: deadline)
        let contextL = try await load(a, id: manifest.legacyID, host: manifest.hostL, package: package, name: "L", session: session, released: released, deadline: deadline)
        let contextB = try await load(b, id: manifest.probeID, host: manifest.hostB, package: package, name: "B", session: session, released: released, deadline: deadline)
        let (pageA, _) = try await page(contextA, store: storeA, name: "A", session: session, released: released, deadline: deadline)
        let (pageL, _) = try await page(contextL, store: storeA, name: "L", session: session, released: released, deadline: deadline)
        let (pageB, _) = try await page(contextB, store: storeB, name: "B", session: session, released: released, deadline: deadline)
        let writes = ["A": try await storage(pageA, set: manifest.expectedA, name: "A", deadline: deadline),
                      "L": try await storage(pageL, set: manifest.expectedL, name: "L", deadline: deadline),
                      "B": try await storage(pageB, set: manifest.expectedB, name: "B", deadline: deadline)]
        output["writes"] = writes
        session.unloadAll()
        let after = (try await records(a, deadline: deadline, name: "A"), try await records(b, deadline: deadline, name: "B"))
        output["recordsAfterWrite"] = ["A": describe(after.0), "B": describe(after.1)]
        let expected = expectedRecords(manifest)
        let complete = ok(writes["A"]!, equals: manifest.expectedA) && ok(writes["L"]!, equals: manifest.expectedL) && ok(writes["B"]!, equals: manifest.expectedB)
            && identifiers(after.0) == expected.a && identifiers(after.1) == expected.b
        if complete { var done = manifest; done.written = true; try save(done, in: directory) }
        return complete
    }

    private static func read(_ manifest: Manifest, directory: URL, released: ExtensionVerifiedIDProbe.Released, deadline: TimeInterval,
                             output: inout [String: Any]) async throws -> Bool {
        let package = directory.appendingPathComponent("package", isDirectory: true)
        let session = Session()
        defer { session.unloadAll(); session.controllers.removeAll() }
        let a = controller("A", manifest.controllerA, session: session, released: released), b = controller("B", manifest.controllerB, session: session, released: released)
        let storeA = session.controllers[0].2, storeB = session.controllers[1].2
        // Ownership: only a namespace holding exactly this run's records may be loaded into. A Bam profile's namespace
        // (with other extensions, or empty) is refused before any context is created.
        let start = (try await records(a, deadline: deadline, name: "A"), try await records(b, deadline: deadline, name: "B"))
        output["recordsAtStart"] = ["A": describe(start.0), "B": describe(start.1)]
        let expected = expectedRecords(manifest)
        guard identifiers(start.0) == expected.a, identifiers(start.1) == expected.b else {
            throw Refusal(description: "The namespaces do not hold exactly this run's records; nothing was loaded. Use cleanup if the run stopped early.")
        }
        var reads: [String: Any] = [:], pageReport: [String: Any]?
        do {
            let contextA = try await load(a, id: manifest.probeID, host: manifest.hostA, package: package, name: "A", session: session, released: released, deadline: deadline)
            let contextL = try await load(a, id: manifest.legacyID, host: manifest.hostL, package: package, name: "L", session: session, released: released, deadline: deadline)
            let contextB = try await load(b, id: manifest.probeID, host: manifest.hostB, package: package, name: "B", session: session, released: released, deadline: deadline)
            let (pageA, reportA) = try await page(contextA, store: storeA, name: "A", session: session, released: released, deadline: deadline)
            pageReport = reportA
            let (pageL, _) = try await page(contextL, store: storeA, name: "L", session: session, released: released, deadline: deadline)
            let (pageB, _) = try await page(contextB, store: storeB, name: "B", session: session, released: released, deadline: deadline)
            reads["A"] = try await storage(pageA, set: nil, name: "A", deadline: deadline)
            reads["L"] = try await storage(pageL, set: nil, name: "L", deadline: deadline)
            reads["B"] = try await storage(pageB, set: nil, name: "B", deadline: deadline)
            // Same ID under a new base URL host after relaunch: does storage follow the ID?
            pageA.stopLoading(); try a.unload(contextA)
            let contextA2 = try await load(a, id: manifest.probeID, host: UUID(), package: package, name: "A new host", session: session, released: released, deadline: deadline)
            let (pageA2, _) = try await page(contextA2, store: storeA, name: "A new host", session: session, released: released, deadline: deadline)
            reads["A new host"] = try await storage(pageA2, set: nil, name: "A new host", deadline: deadline)
        } catch {
            output["readFailure"] = String(describing: error)
        }
        output["reads"] = reads
        output["expected"] = ["A": manifest.expectedA, "B": manifest.expectedB, "L": manifest.expectedL]
        output["pageA"] = pageReport ?? NSNull()
        session.unloadAll()
        let cleaned = try await cleanup(manifest, package: package, session: session, released: released, output: &output)
        // Valid transport for every read is required; a value that did not survive is a legitimate measurement.
        let transportOK = ["A", "L", "B", "A new host"].allSatisfy { ((reads[$0] as? [String: Any])?["ok"] as? Bool) == true }
        // Terminal: a reply/message or an explicit error (a semantic negative). Missing, malformed or timed out is not.
        let messaging = ["callbackSelf", "portById"].allSatisfy { key in
            guard let entry = pageReport?[key] as? [String: Any], !entry.isEmpty, entry["timeout"] == nil else { return false }
            if entry["error"] is String { return true }
            return key == "callbackSelf" ? entry.keys.contains("reply") : entry["id"] != nil
        }
        output["messagingTerminal"] = messaging
        return transportOK && messaging && output["readFailure"] == nil && cleaned
    }

    private static func cleanupOnly(_ manifest: Manifest, directory: URL, released: ExtensionVerifiedIDProbe.Released, output: inout [String: Any]) async throws -> Bool {
        let session = Session()
        defer { session.unloadAll(); session.controllers.removeAll() }
        _ = controller("A", manifest.controllerA, session: session, released: released); _ = controller("B", manifest.controllerB, session: session, released: released)
        return try await cleanup(manifest, package: directory.appendingPathComponent("package", isDirectory: true), session: session, released: released, output: &output)
    }

    /// Cleanup contract (public API reality, upstream WebKit WebExtensionControllerCocoa.mm): getDataRecords lists every
    /// per-extension storage directory with no size filter, and removeData clears the stored data but keeps the
    /// directory, recording failures on the data record (`errors`). So owned zero-byte records legitimately remain.
    /// Clean therefore means, per owned namespace: only this run's records; removeData without record errors; every
    /// owned context that had data reloads with no storage.local (and storage.sync) keys; after unloading again, a
    /// second removal and re-query leave only owned, zero-byte, error-free records. Contexts are unloaded on entry.
    private static func cleanup(_ manifest: Manifest, package: URL, session: Session, released: ExtensionVerifiedIDProbe.Released,
                                output: inout [String: Any]) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        session.unloadAll()
        var report: [String: Any] = [:], clean = true
        let hosts: [String: [String: UUID]] = ["A": [manifest.probeID: manifest.hostA, manifest.legacyID: manifest.hostL], "B": [manifest.probeID: manifest.hostB]]
        func remove(_ found: [WKWebExtension.DataRecord], from controller: WKWebExtensionController, name: String) async throws {
            _ = try await ExtensionVerifiedIDProbe.bounded(10, by: deadline, "\(name) remove data") {
                await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: found); return true
            }
        }
        for (name, controller, store) in session.controllers {
            var entry: [String: Any] = [:]
            let found = try await records(controller, deadline: deadline, name: name)
            entry["before"] = describe(found)
            let foreign = found.filter { !manifest.ownedIdentifiers.contains($0.uniqueIdentifier) }
            guard foreign.isEmpty else { entry["foreign"] = describe(foreign); entry["clean"] = false; report[name] = entry; clean = false; continue }
            guard !found.isEmpty else { entry["nothingToRemove"] = true; entry["clean"] = true; report[name] = entry; continue }
            // 1. Remove; WebKit attaches any removal failure to the record itself.
            try await remove(found, from: controller, name: name)
            let firstErrors = found.flatMap(\.errors).map(\.localizedDescription)
            entry["removalErrors"] = firstErrors
            entry["afterRemoval"] = describe(try await records(controller, deadline: deadline, name: "\(name) after removal"))
            // 2. Value proof: each owned context that had data reloads and must hold no keys. Only those identifiers, so a
            //    partial run's namespace gains no new metadata.
            var proofs: [String: Any] = [:], proofsEmpty = true
            for id in found.map(\.uniqueIdentifier) {
                guard let host = hosts[name]?[id] else { proofs[id] = ["ok": false, "error": "no recorded host"]; proofsEmpty = false; continue }
                do {
                    let context = try await load(controller, id: id, host: host, package: package, name: "\(name) proof", session: session, released: released, deadline: deadline)
                    let (view, _) = try await page(context, store: store, name: "\(name) proof", session: session, released: released, deadline: deadline)
                    let keys = try await storedKeys(view, name: "\(name) proof", deadline: deadline)
                    proofs[id] = keys
                    let local = keys["local"] as? [String], sync = keys["sync"]
                    if keys["ok"] as? Bool != true || local?.isEmpty != true || !((sync as? [String])?.isEmpty == true || sync as? String == "unavailable") { proofsEmpty = false }
                } catch { proofs[id] = ["ok": false, "error": String(describing: error)]; proofsEmpty = false }
            }
            session.unloadAll()
            entry["valueProof"] = proofs
            // 3. Reloading may recreate metadata: remove again, then re-query.
            let second = try await records(controller, deadline: deadline, name: "\(name) second")
            let secondForeign = second.filter { !manifest.ownedIdentifiers.contains($0.uniqueIdentifier) }
            if secondForeign.isEmpty && !second.isEmpty { try await remove(second, from: controller, name: "\(name) second") }
            let secondErrors = second.flatMap(\.errors).map(\.localizedDescription)
            entry["secondRemovalErrors"] = secondErrors
            let final = try await records(controller, deadline: deadline, name: "\(name) final")
            entry["final"] = describe(final)
            let finalOK = final.allSatisfy { manifest.ownedIdentifiers.contains($0.uniqueIdentifier) && $0.totalSizeInBytes == 0 && $0.errors.isEmpty }
            let ok = firstErrors.isEmpty && proofsEmpty && secondForeign.isEmpty && secondErrors.isEmpty && finalOK
            entry["clean"] = ok
            if !ok { clean = false }
            report[name] = entry
        }
        output["cleanup"] = report
        output["cleanupProvedEmpty"] = clean
        output["metadataRetained"] = "Owned zero-byte data records may remain: WebKit lists every per-extension storage directory as a record and removeData keeps the directory; public API has no directory removal. Stored values were proved empty by reloading each owned context."
        return clean
    }
    /// {ok: true, local: [keys], sync: [keys] | "unavailable"} or {ok: false, stage, error}.
    private static func storedKeys(_ view: WKWebView, name: String, deadline: TimeInterval) async throws -> [String: Any] {
        let script = """
            const api = globalThis.browser || globalThis.chrome;
            try {
              const local = Object.keys(await api.storage.local.get(null));
              const sync = api.storage.sync ? Object.keys(await api.storage.sync.get(null)) : 'unavailable';
              return {ok: true, local, sync};
            } catch (error) { return {ok: false, stage: 'script', error: String(error && error.message || error)}; }
            """
        let answer: [String: Any]? = try await ExtensionVerifiedIDProbe.bounded(5, by: deadline, "\(name) keys") { [weak view] in
            guard let view else { return ["ok": false, "stage": "transport", "error": "page released"] }
            do { return try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? ["ok": false, "stage": "transport", "error": "non-object reply"] }
            catch { return ["ok": false, "stage": "transport", "error": String(describing: error)] }
        }
        return answer ?? ["ok": false, "stage": "transport", "error": "no reply"]
    }
}

private extension JSONEncoder {
    static var phase2: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}
private extension JSONDecoder {
    static var phase2: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
