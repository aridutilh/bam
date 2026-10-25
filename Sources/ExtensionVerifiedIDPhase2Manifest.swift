import Foundation

/// Task-owned manifest for the verified-ID phase 2 probe (persistent, across processes). Written only by `write`;
/// `read` and `cleanup` act only on what it names, after these checks. Pure: no WebKit, no file access here.
struct ExtensionVerifiedIDPhase2Manifest: Codable, Equatable {
    static let markerValue = "bam-verified-id-phase2"
    var marker: String
    var runID: UUID
    var createdAt: Date
    /// Fresh random namespaces for `WKWebExtensionController.Configuration(identifier:)`, created by this run.
    var controllerA: UUID
    var controllerB: UUID
    /// Synthetic Chrome-shaped runtime.id (never a real publisher's), and a legacy UUID runtime.id control.
    var probeID: String
    var legacyID: String
    var hostA: UUID
    var hostB: UUID
    var hostL: UUID
    /// Set by `write` once every value was written and read back.
    var written: Bool

    var expectedA: String { "A-\(runID.uuidString.lowercased())" }
    var expectedB: String { "B-\(runID.uuidString.lowercased())" }
    var expectedL: String { "L-\(runID.uuidString.lowercased())" }
    var ownedIdentifiers: Set<String> { [probeID, legacyID] }

    static func fresh(probeID: String, now: Date = Date()) -> Self {
        Self(marker: markerValue, runID: UUID(), createdAt: now, controllerA: UUID(), controllerB: UUID(), probeID: probeID,
             legacyID: UUID().uuidString.lowercased(), hostA: UUID(), hostB: UUID(), hostL: UUID(), written: false)
    }

    /// The only place run directories may live.
    static func taskRoot(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent("bam-verified-id-phase2", isDirectory: true)
    }

    /// nil when the manifest may be acted on from `directory`; otherwise the refusal reason.
    func refusal(directory: URL, root: URL, forbidden: Set<UUID>) -> String? {
        guard marker == Self.markerValue else { return "The manifest is not a verified-ID phase 2 manifest." }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard directoryPath.hasPrefix(rootPath + "/"), directory.lastPathComponent == runID.uuidString.lowercased() else {
            return "The run directory is not this run's task-owned directory."
        }
        let controllers = [controllerA, controllerB]
        guard controllers[0] != controllers[1], controllers.allSatisfy(Self.isVersion4) else { return "The controller namespaces are not two distinct random UUIDs." }
        guard forbidden.isDisjoint(with: controllers) else { return "A controller namespace is one of Bam's own profile namespaces." }
        let hosts = [hostA, hostB, hostL]
        guard Set(hosts).count == 3, Set(hosts).isDisjoint(with: controllers) else { return "The base URL hosts are not distinct." }
        guard probeID.count == 32, probeID.unicodeScalars.allSatisfy({ ("a"..."p").contains(Character($0)) }) else { return "The probe ID is not Chrome-shaped." }
        guard let legacy = UUID(uuidString: legacyID), legacy.uuidString.lowercased() == legacyID, !forbidden.contains(legacy) else {
            return "The legacy control ID is not a lowercase UUID."
        }
        return nil
    }

    static func isVersion4(_ uuid: UUID) -> Bool {
        let bytes = uuid.uuid
        return bytes.6 >> 4 == 4 && (bytes.8 & 0xC0) == 0x80
    }
}
