import Foundation
import WebKit

/// WebKit reports every manifest problem in `WKWebExtension.errors`, but only some stop an extension from working.
/// Safari loads an extension whose only problems are entry-level warnings and ignores the bad entry (for example
/// Raindrop.io's empty `commands._execute_action` object, which Chrome accepts); Bam does the same. A broken or
/// unsupported manifest, an archive or signature failure, a missing resource, or any error Bam can't classify still
/// blocks the install.
@available(macOS 15.4, *)
enum ExtensionManifestWarnings {
    static let warningCodes: Set<Int> = [WKWebExtension.Error.invalidManifestEntry.rawValue,
                                         WKWebExtension.Error.invalidDeclarativeNetRequestEntry.rawValue,
                                         WKWebExtension.Error.invalidBackgroundPersistence.rawValue]
    static func isWarning(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == WKWebExtension.errorDomain && warningCodes.contains(ns.code)
    }
    static func blocking(_ errors: [Error]) -> [Error] { errors.filter { !isWarning($0) } }
    static func warnings(_ errors: [Error]) -> [Error] { errors.filter(isWarning) }
    /// Throws for blocking errors; returns a disclosure line for ignored warnings (nil when there are none).
    static func check(_ errors: [Error], failure: (String) -> Error) throws -> String? {
        let blocking = blocking(errors)
        guard blocking.isEmpty else { throw failure(blocking.map(\.localizedDescription).joined(separator: "\n")) }
        let warnings = warnings(errors).map(\.localizedDescription)
        guard !warnings.isEmpty else { return nil }
        return "WebKit ignored part of the manifest, as Safari does: " + warnings.prefix(4).joined(separator: " ")
    }
    static func joinedNote(_ notes: String?...) -> String? {
        let parts = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
