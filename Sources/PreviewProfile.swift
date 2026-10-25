import Foundation

/// The development app has its own bundle, preferences, session and WebKit stores.
/// A launch flag alone must never make the release app persist a preview session.
struct PreviewProfile {
    static let bundleIdentifier = "com.ari.bam.extensionpreview"
    static let defaultStoreIdentifier = UUID(uuidString: "6C811B15-1181-4DA2-9184-09EF50B9F902")!
    private static let legacyDefaultIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    enum Mode: Equatable { case regular, fresh, persistent }
    struct InvalidLaunch: LocalizedError {
        let errorDescription: String?
    }

    let mode: Mode
    var isEphemeral: Bool { mode == .fresh }
    var isPersistentPreview: Bool { mode == .persistent }
    var supportDirectoryName: String { isPersistentPreview ? "BamExtensionPreview" : "OrbitPrototype" }
    var windowTitle: String { isPersistentPreview ? "Bam Extension Preview" : "Bam" }
    var windowAutosaveName: String { isPersistentPreview ? "BamExtensionPreviewWindow" : "OrbitPrototypeWindow" }

    init(arguments: [String], bundleIdentifier: String?) throws {
        let persistentRequested = arguments.contains("--persistent-preview")
        let freshRequested = arguments.contains("--fresh-preview")
        guard !persistentRequested || !freshRequested else {
            throw InvalidLaunch(errorDescription: "Choose either --persistent-preview or --fresh-preview.")
        }
        guard !persistentRequested || bundleIdentifier == Self.bundleIdentifier else {
            throw InvalidLaunch(errorDescription: "Persistent previews require the separate Bam Extension Preview app. Run bash scripts/preview-draft.sh to prepare it.")
        }
        // A direct launch of the dedicated bundle is also isolated, even when
        // its wrapper was bypassed and no command-line flag was supplied.
        mode = freshRequested ? .fresh : bundleIdentifier == Self.bundleIdentifier ? .persistent : .regular
    }

    func persistentIdentifier(for profileID: UUID) -> UUID? {
        guard profileID == Self.legacyDefaultIdentifier else { return profileID }
        return isPersistentPreview ? Self.defaultStoreIdentifier : nil
    }

    static func persistentIdentifier(for profileID: UUID) -> UUID? {
        // App validates the launch before constructing any controller/store.
        // Standalone tests have neither preview flag nor bundle identity.
        let launch = try? PreviewProfile(arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
        return launch?.persistentIdentifier(for: profileID)
    }
}
