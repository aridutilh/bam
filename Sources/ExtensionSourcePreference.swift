import Foundation

/// Which build of one product Bam offers first. The Chrome Web Store is the default and
/// Firefox Add-ons the alternative; a build Bam can't install, or one Bam's own probes saw
/// fail, never wins over one that works. Safari App Store builds stay available, last.
enum ExtensionSourcePreference {
    struct Facts: Equatable {
        let source: ExtensionCatalogSourceKind
        let canInstallInBam: Bool
        /// A dated Bam probe saw this build fail to start or reach its UI.
        let failedInBamProbe: Bool
        let version: String
    }

    static func order(_ source: ExtensionCatalogSourceKind) -> Int { source.preferenceOrder }

    static func prefers(_ a: Facts, over b: Facts) -> Bool {
        if a.canInstallInBam != b.canInstallInBam { return a.canInstallInBam }
        if a.failedInBamProbe != b.failedInBamProbe { return !a.failedInBamProbe }
        if order(a.source) != order(b.source) { return order(a.source) < order(b.source) }
        return compareVersions(a.version, b.version) == .orderedDescending
    }

    /// A probe note that records failure, as opposed to a working observation.
    static func isFailureNote(_ note: String) -> Bool {
        note.contains("cannot receive") || note.contains("not reached") || note.contains("stopped at")
    }

    /// Dotted numeric comparison; non-numeric parts compare lexically after numbers.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map(String.init), pb = b.split(separator: ".").map(String.init)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0", y = i < pb.count ? pb[i] : "0"
            if let nx = Int(x), let ny = Int(y) { if nx != ny { return nx < ny ? .orderedAscending : .orderedDescending } }
            else if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
