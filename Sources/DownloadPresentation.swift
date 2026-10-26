import Foundation

enum DownloadStatus: String { case choosingDestination, downloading, finished, cancelled, failed }

/// One download as the surfaces see it: a value copied from the coordinator's record.
struct DownloadSnapshot {
    let id: UUID
    let filename: String
    let sourceURL: URL?
    let destinationURL: URL?
    let status: DownloadStatus
    let detail: String
    let fractionCompleted: Double?
    let completedBytes: Int64
    let totalBytes: Int64
    var startedAt = Date()
    var endedAt: Date? = nil
    /// The finished file's identity when Bam saved it (`DownloadFileIdentity`), so a later file at the same path is not mistaken for it.
    var fileIdentity: String? = nil
    var isActive: Bool { status == .choosingDestination || status == .downloading }
}

/// Identifies one file on disk: inode, creation and modification times, and size. A file
/// deleted or moved and another saved at the same path gets a different identity.
enum DownloadFileIdentity {
    static func of(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        return "\(inode):\(created):\(modified):\(size)"
    }
}

/// What a download row or tile shows and which actions it offers.
struct DownloadRowPresentation: Equatable {
    let title: String
    let subtitle: String
    let isProblem: Bool
    let showsProgress: Bool
    let fraction: Double?
    let canCancel: Bool
    let canOpen: Bool
    let canReveal: Bool
    var accessibilityLabel: String { "\(title), \(subtitle)" }
}

/// Text and ordering for Bam's download surfaces, free of AppKit so it can be tested.
enum DownloadPresentation {
    /// Rows in the compact list before "Show All" takes over.
    static let compactLimit = 5
    static let emptyTitle = "No downloads yet"
    static let emptyDetail = "Files you download appear here. Closing Bam cancels unfinished downloads."
    /// The coordinator's detail for a cleanly finished file; anything else is a problem worth showing.
    static let finishedDetail = "Finished"

    static func row(_ item: DownloadSnapshot, now: Date, locale: Locale = .current) -> DownloadRowPresentation {
        let subtitle: String
        var problem = false
        switch item.status {
        case .choosingDestination:
            subtitle = item.detail
        case .downloading:
            if let fraction = item.fractionCompleted { subtitle = "\(item.detail) · \(Int((fraction * 100).rounded(.down)))%" }
            else { subtitle = item.detail }
        case .finished:
            if item.detail == finishedDetail {
                subtitle = [size(item), item.endedAt.map { relativeTime($0, now: now, locale: locale) }]
                    .compactMap { $0 }.joined(separator: " · ")
            } else { subtitle = item.detail; problem = true }
        case .cancelled:
            subtitle = "Cancelled"
        case .failed:
            subtitle = item.detail; problem = true
        }
        let finished = item.status == .finished
        return DownloadRowPresentation(title: item.filename, subtitle: subtitle.isEmpty ? "Finished" : subtitle, isProblem: problem,
                                       showsProgress: item.isActive, fraction: item.isActive ? item.fractionCompleted : nil,
                                       canCancel: item.isActive, canOpen: finished && item.destinationURL != nil,
                                       canReveal: finished && item.destinationURL != nil)
    }

    /// The compact list: unfinished downloads first, then the most recent; `more` counts the rest.
    /// Input is newest first, as the coordinator keeps it.
    static func compact(_ items: [DownloadSnapshot], limit: Int = compactLimit) -> (shown: [DownloadSnapshot], more: Int) {
        let ordered = items.filter(\.isActive) + items.filter { !$0.isActive }
        return (Array(ordered.prefix(limit)), max(0, ordered.count - limit))
    }

    static func size(_ item: DownloadSnapshot) -> String? {
        let bytes = item.totalBytes > 0 ? item.totalBytes : item.completedBytes
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }

    static func relativeTime(_ date: Date, now: Date, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 45 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Plain-language count for the "Show All" control.
    static func showAllTitle(more: Int) -> String { more > 0 ? "Show All (\(more) more)" : "Show All" }
}
