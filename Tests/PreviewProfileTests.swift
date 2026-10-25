import Foundation

@main struct PreviewProfileTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(description: message) }; checks += 1
        }
        func rejects(_ arguments: [String], _ identifier: String?) throws {
            do { _ = try PreviewProfile(arguments: arguments, bundleIdentifier: identifier) }
            catch { checks += 1; return }
            throw Failure(description: "Unsafe preview launch was accepted: \(arguments), \(identifier ?? "nil")")
        }
        let originalDefault = BrowserProfile.defaultID
        let namedProfile = UUID()
        let normal = try PreviewProfile(arguments: [], bundleIdentifier: "com.ari.orbitprototype")
        try check(normal.mode == .regular && !normal.isEphemeral && normal.supportDirectoryName == "OrbitPrototype", "Release storage changed")
        try check(normal.persistentIdentifier(for: originalDefault) == nil && normal.persistentIdentifier(for: namedProfile) == namedProfile, "Release WebKit identities changed")

        for identifier: String? in [nil, "com.ari.orbitprototype", "com.ari.bam.proportionspreview", "com.ari.bam.extensionpreview"] {
            try rejects(["--persistent-preview"], identifier)
            let fresh = try PreviewProfile(arguments: ["--fresh-preview"], bundleIdentifier: identifier)
            try check(fresh.mode == .fresh && fresh.isEphemeral && !fresh.isPersistentPreview, "Fresh preview stopped being disposable")
        }
        try rejects([], "com.ari.bam.proportionspreview")
        try rejects([], "com.ari.bam.extensionpreview")
        try rejects(["--fresh-preview", "--persistent-preview"], PreviewProfile.bundleIdentifier)
        let persistent = try PreviewProfile(arguments: ["--persistent-preview"], bundleIdentifier: PreviewProfile.bundleIdentifier)
        let relaunched = try PreviewProfile(arguments: [], bundleIdentifier: PreviewProfile.bundleIdentifier)
        try check(persistent.mode == .persistent && !persistent.isEphemeral && persistent.supportDirectoryName == "BamPreview", "Persistent preview is not isolated")
        try check(PreviewProfile.bundleIdentifier == "com.ari.bam.preview" && persistent.windowTitle == "Bam Preview", "Canonical preview identity drifted")
        try check(PreviewProfile.defaultStoreIdentifier != UUID(uuidString: "6C811B15-1181-4DA2-9184-09EF50B9F902"), "Canonical preview reuses an obsolete preview store")
        try check(relaunched.mode == .persistent && relaunched.supportDirectoryName == persistent.supportDirectoryName, "Direct bundle launch could open the release session")
        try check(persistent.persistentIdentifier(for: originalDefault) == PreviewProfile.defaultStoreIdentifier &&
                  relaunched.persistentIdentifier(for: originalDefault) == PreviewProfile.defaultStoreIdentifier, "Preview Default store identity changed between launches")
        try check(PreviewProfile.defaultStoreIdentifier != originalDefault && PreviewProfile.defaultStoreIdentifier != UUID(uuidString: "00000000-0000-0000-0000-000000000000"), "Preview uses a reserved WebKit identifier")
        try check(persistent.persistentIdentifier(for: namedProfile) == namedProfile, "Named profiles lost their stable identity")
        try check(persistent.windowTitle != normal.windowTitle && persistent.windowAutosaveName != normal.windowAutosaveName, "Preview appearance state is not separate")
        let freshInDedicatedBundle = try PreviewProfile(arguments: ["--fresh-preview"], bundleIdentifier: PreviewProfile.bundleIdentifier)
        try check(freshInDedicatedBundle.isEphemeral && !freshInDedicatedBundle.isPersistentPreview, "Fresh mode cannot be requested from the development bundle")
        print("PASS: Preview profiles — \(checks) checks")
    }
}
