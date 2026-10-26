import Foundation

/// The site-settings popover's text and controls, derived only from real page and browser state.
@main struct SiteSettingsModelTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func main() {
        do { try run(); print("PASS: \(checks) site settings checks") }
        catch { print("FAIL: Site settings — \(error)"); exit(1) }
    }
    static func run() throws {
        let https = URL(string: "https://www.example.com/path?q=1")!
        // Connection, from scheme, mixed content and the certificate WebKit reports.
        try check(SiteSettingsModel.connection(url: https, onlySecureContent: true, certificate: "example.com") == .secure(certificate: "example.com"),
                  "HTTPS with only secure content was not secure")
        try check(SiteSettingsModel.connection(url: https, onlySecureContent: false, certificate: nil) == .mixed, "Mixed content was not flagged")
        try check(SiteSettingsModel.connection(url: URL(string: "http://example.com")!, onlySecureContent: false, certificate: nil) == .notSecure,
                  "HTTP was not flagged")
        try check(SiteSettingsModel.connection(url: URL(fileURLWithPath: "/tmp/a.html"), onlySecureContent: false, certificate: nil) == .local
                  && SiteSettingsModel.connection(url: nil, onlySecureContent: false, certificate: nil) == .local, "Local pages were misclassified")
        let secure = SiteSettingsContext(url: https, connection: .secure(certificate: "example.com"))
        try check(SiteSettingsModel.title(secure) == "example.com", "The title kept www. or lost the host")
        let lock = SiteSettingsModel.security(secure)
        try check(lock.headline == "Connection is secure" && lock.detail == "Certificate issued to example.com" && !lock.warning, "Secure text was wrong")
        try check(SiteSettingsModel.security(SiteSettingsContext(url: https, connection: .secure(certificate: nil))).detail == nil,
                  "A certificate line was shown without a certificate")
        try check(SiteSettingsModel.security(SiteSettingsContext(url: nil, connection: .notSecure)).warning
                  && SiteSettingsModel.security(SiteSettingsContext(url: nil, connection: .mixed)).warning, "Insecure pages were not warned about")

        // Zoom: percentage, Reset only when changed, View › Zoom's 40–300% limits.
        var zoomed = secure; zoomed.pageZoom = 1.1
        let z = SiteSettingsModel.zoom(zoomed)
        try check(z.label == "110%" && z.canReset && z.canZoomIn && z.canZoomOut, "110% zoom was misreported: \(z)")
        try check(!SiteSettingsModel.zoom(secure).canReset, "Reset was offered at 100%")
        zoomed.pageZoom = 3; try check(!SiteSettingsModel.zoom(zoomed).canZoomIn, "Zoom In was offered at the maximum")
        zoomed.pageZoom = 0.4; try check(!SiteSettingsModel.zoom(zoomed).canZoomOut, "Zoom Out was offered at the minimum")

        // Extensions: those with access first, then withheld, then the rest, each by name.
        var withExtensions = secure
        withExtensions.extensions = [.init(id: UUID(), name: "zeta", access: .notRequested), .init(id: UUID(), name: "Beta", access: .withheld),
                                     .init(id: UUID(), name: "alpha", access: .withheld), .init(id: UUID(), name: "Gamma", access: .allowed)]
        try check(SiteSettingsModel.extensions(withExtensions).map(\.name) == ["Gamma", "alpha", "Beta", "zeta"], "Extension order was wrong")
        try check(SiteSettingsModel.accessText(.allowed) == "Can read and change this site"
                  && SiteSettingsModel.accessText(.withheld) == "Not allowed on this site", "Access text was wrong")
    }
}
