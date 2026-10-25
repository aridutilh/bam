import Foundation

/// Phase 2 manifest guards: nothing is acted on unless the manifest is this run's, in its task-owned directory, with
/// fresh distinct random namespaces that are not Bam's own.
@main struct ExtensionVerifiedIDPhase2ManifestTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Verified-ID phase 2 manifest — \(try run()) checks") }
        catch { fputs("FAIL: Verified-ID phase 2 manifest: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias M = ExtensionVerifiedIDPhase2Manifest
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        let probe = "abcdefghijklmnopabcdefghijklmnop"
        let temporary = FileManager.default.temporaryDirectory
        let root = M.taskRoot(temporaryDirectory: temporary)
        let forbidden: Set<UUID> = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, UUID(uuidString: "D3E83D79-9B31-4C32-83CD-3A6C06BDF593")!]
        let manifest = M.fresh(probeID: probe)
        let directory = root.appendingPathComponent(manifest.runID.uuidString.lowercased(), isDirectory: true)
        try check(manifest.refusal(directory: directory, root: root, forbidden: forbidden) == nil, "A fresh manifest in its own directory was refused")
        try check(M.isVersion4(manifest.controllerA) && M.isVersion4(manifest.controllerB) && manifest.controllerA != manifest.controllerB, "Fresh namespaces were not distinct v4 UUIDs")
        var wrongMarker = manifest; wrongMarker.marker = "other"
        try check(wrongMarker.refusal(directory: directory, root: root, forbidden: forbidden) != nil, "A foreign marker was accepted")
        try check(manifest.refusal(directory: temporary.appendingPathComponent(manifest.runID.uuidString.lowercased()), root: root, forbidden: forbidden) != nil &&
                  manifest.refusal(directory: root.appendingPathComponent(UUID().uuidString.lowercased()), root: root, forbidden: forbidden) != nil &&
                  manifest.refusal(directory: root.appendingPathComponent("x/../" + manifest.runID.uuidString.lowercased()).deletingLastPathComponent(), root: root, forbidden: forbidden) != nil,
                  "A directory outside the task root or not named for the run was accepted")
        var bamNamespace = manifest; bamNamespace.controllerB = UUID(uuidString: "D3E83D79-9B31-4C32-83CD-3A6C06BDF593")!
        var legacyDefault = manifest; legacyDefault.controllerA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var same = manifest; same.controllerB = manifest.controllerA
        try check([bamNamespace, legacyDefault, same].allSatisfy { $0.refusal(directory: directory, root: root, forbidden: forbidden) != nil },
                  "Bam's own, non-random or repeated controller namespaces were accepted")
        var badProbe = manifest; badProbe.probeID = "not-a-chrome-id"
        var badLegacy = manifest; badLegacy.legacyID = "ABC"
        var hostClash = manifest; hostClash.hostB = manifest.hostA
        try check([badProbe, badLegacy, hostClash].allSatisfy { $0.refusal(directory: directory, root: root, forbidden: forbidden) != nil },
                  "A malformed probe ID, legacy ID or repeated host was accepted")
        let encoded = try JSONEncoder().encode(manifest)
        try check(try JSONDecoder().decode(M.self, from: encoded) == manifest && manifest.expectedA.hasPrefix("A-") && manifest.ownedIdentifiers == [probe, manifest.legacyID],
                  "The manifest did not round-trip or its owned identifiers were wrong")
        return checks
    }
}
