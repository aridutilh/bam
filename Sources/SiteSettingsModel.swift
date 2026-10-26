import Foundation

/// What the site-settings popover knows about the current page. Every value comes from
/// something Bam already has; nothing here is a placeholder for a missing backend.
struct SiteSettingsContext: Equatable {
    enum Connection: Equatable {
        /// HTTPS with only secure content; `certificate` is the leaf's subject summary when WebKit has it.
        case secure(certificate: String?)
        /// HTTPS that loaded some insecure content.
        case mixed
        /// Plain HTTP.
        case notSecure
        /// Files, extension pages and other non-web pages.
        case local
    }
    enum ExtensionAccess: Equatable { case allowed, withheld, notRequested }
    struct ExtensionItem: Equatable {
        let id: UUID
        let name: String
        let access: ExtensionAccess
    }

    var url: URL?
    var connection: Connection
    var pageZoom: Double = 1
    /// nil where it doesn't apply (no host, or a private window that can't keep it).
    var keepsAwake: Bool? = nil
    var extensions: [ExtensionItem] = []
}

/// The popover's text and which of its controls apply, free of AppKit so it can be tested.
enum SiteSettingsModel {
    static func title(_ context: SiteSettingsContext) -> String {
        guard let url = context.url else { return "This page" }
        if let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.isFileURL ? url.lastPathComponent : "This page"
    }

    static func security(_ context: SiteSettingsContext) -> (headline: String, detail: String?, symbol: String, warning: Bool) {
        switch context.connection {
        case .secure(let certificate):
            return ("Connection is secure", certificate.map { "Certificate issued to \($0)" }, "lock.fill", false)
        case .mixed:
            return ("Parts of this page aren’t secure", "Some images or other content loaded without encryption.", "lock.trianglebadge.exclamationmark", true)
        case .notSecure:
            return ("Connection isn’t secure", "Don’t enter passwords or payment details on this site.", "lock.open.fill", true)
        case .local:
            return ("Page on this Mac", nil, "doc.fill", false)
        }
    }

    /// Bam's page zoom as a percentage, and whether Reset has anything to undo.
    static func zoom(_ context: SiteSettingsContext) -> (label: String, canReset: Bool, canZoomIn: Bool, canZoomOut: Bool) {
        let zoom = context.pageZoom.isFinite ? context.pageZoom : 1
        let percent = Int((zoom * 100).rounded())
        // Same limits as View › Zoom In / Zoom Out.
        return ("\(percent)%", percent != 100, zoom < 2.999, zoom > 0.401)
    }

    static func accessText(_ access: SiteSettingsContext.ExtensionAccess) -> String {
        switch access {
        case .allowed: return "Can read and change this site"
        case .withheld: return "Not allowed on this site"
        case .notRequested: return "Doesn’t use this site"
        }
    }

    /// Extensions that matter here first (allowed, then withheld), each group by name.
    static func extensions(_ context: SiteSettingsContext) -> [SiteSettingsContext.ExtensionItem] {
        func rank(_ access: SiteSettingsContext.ExtensionAccess) -> Int {
            switch access { case .allowed: return 0; case .withheld: return 1; case .notRequested: return 2 }
        }
        return context.extensions.sorted {
            rank($0.access) != rank($1.access) ? rank($0.access) < rank($1.access)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Height of the scrolling extension list: every row when they fit in `available` (the screen
    /// space left after the popover's fixed parts), otherwise what fits, never under `minimumRows`.
    static func extensionListHeight(rows: Int, rowHeight: CGFloat, spacing: CGFloat, available: CGFloat, minimumRows: Int = 2) -> CGFloat {
        guard rows > 0, rowHeight > 0 else { return 0 }
        let full = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * max(0, spacing)
        let floor = CGFloat(min(rows, max(1, minimumRows))) * rowHeight + CGFloat(min(rows, max(1, minimumRows)) - 1) * max(0, spacing)
        let room = available.isFinite ? available : full
        return min(full, max(floor, room))
    }

    static func connection(url: URL?, onlySecureContent: Bool, certificate: String?) -> SiteSettingsContext.Connection {
        switch url?.scheme?.lowercased() {
        case "https": return onlySecureContent ? .secure(certificate: certificate) : .mixed
        case "http": return .notSecure
        default: return .local
        }
    }
}
