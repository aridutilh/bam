import AppKit

@main enum PreviewIconTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let bundle = Bundle(path: CommandLine.arguments[1])!
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let regular = NSImage(contentsOf: bundle.url(forResource: "BamIcon", withExtension: "icns")!)!
        let preview = NSImage(contentsOf: bundle.url(forResource: "BamPreviewIcon", withExtension: "icns")!)!
        require(regular.tiffRepresentation != preview.tiffRepresentation, "Icons must be visibly distinct assets")
        // AppKit normalizes an icon's representations when accepting it.
        app.applicationIconImage = preview
        let expectedPreview = app.applicationIconImage.tiffRepresentation
        app.applicationIconImage = regular
        let expectedRegular = app.applicationIconImage.tiffRepresentation
        require(expectedRegular != expectedPreview, "AppKit must accept the distinct artwork")
        PreviewIcon.apply(for: try PreviewProfile(arguments: [], bundleIdentifier: "com.ari.orbitprototype"), bundle: bundle)
        require(app.applicationIconImage.tiffRepresentation == expectedRegular, "Normal launch retains production icon")
        for (arguments, identifier) in [(["--fresh-preview"], "com.ari.orbitprototype"), ([], PreviewProfile.bundleIdentifier), (["--persistent-preview"], PreviewProfile.bundleIdentifier)] {
            app.applicationIconImage = regular
            PreviewIcon.apply(for: try PreviewProfile(arguments: arguments, bundleIdentifier: identifier), bundle: bundle)
            require(app.applicationIconImage.tiffRepresentation == expectedPreview, "Preview must display construction icon")
        }
        require(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "BamIcon.icns", "Normal bundle declares production icon")
        print("PASS: Preview icons — normal, fresh, persistent and direct draft launch selection; bundle artwork is distinct")
    }
}
