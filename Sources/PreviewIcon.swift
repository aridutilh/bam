import AppKit

/// Development previews share the construction artwork while normal launches
/// retain the production bundle icon. Selecting artwork never changes storage.
@MainActor enum PreviewIcon {
    static func apply(for launch: PreviewProfile, bundle: Bundle = .main) {
        guard launch.mode != .regular,
              let url = bundle.url(forResource: "BamPreviewIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = icon
    }
}
