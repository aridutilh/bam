import Foundation

/// Opt-in original fixture for the vendor probe's real-extension bookmarks acceptance (for example Vimium's
/// bookmark completer). `BAM_VENDOR_SEED_BOOKMARKS=1` seeds dormant saved items into the probe's own,
/// already task-owned normal profile before any view loads. Off by default: every existing probe is
/// unchanged. Fixture only, no product behavior: nothing is opened, granted or read from disk.
enum BookmarkVendorSeed {
    static let flag = "BAM_VENDOR_SEED_BOOKMARKS"
    static let alphaTitle = "Bam bookmark alpha"
    static let betaTitle = "Bam bookmark beta"
    static let folderTitle = "Bam bookmark folder"
    static let nestedTitle = "Bam bookmark nested"
    static let todayTitle = "Bam bookmark today control"

    enum Decision: Equatable {
        case off
        /// Seed with URLs under this origin (scheme, literal loopback host, port).
        case seed(origin: URL)
        /// Requested but not allowed; the probe stops before changing anything.
        case refused(String)
    }

    /// Decided before any controller, session or view exists. Only "1" enables; anything else set is refused.
    static func decide(flag value: String?, isNormalMode: Bool, site: String?) -> Decision {
        guard let value, !value.isEmpty else { return .off }
        guard value == "1" else { return .refused("\(flag) must be 1 when set") }
        guard isNormalMode else { return .refused("\(flag) needs the canonical normal disposable probe (BAM_VENDOR_PROFILE=normal)") }
        guard let origin = loopbackOrigin(site) else {
            return .refused("\(flag) needs BAM_VENDOR_SITE on a literal loopback http URL (127.0.0.1 or [::1])")
        }
        return .seed(origin: origin)
    }

    /// http only, literal 127.0.0.1 or ::1 (not a name that could resolve elsewhere), no user info.
    static func loopbackOrigin(_ raw: String?) -> URL? {
        guard let raw, let components = URLComponents(string: raw), components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), host == "127.0.0.1" || host == "::1" || host == "[::1]" else { return nil }
        // Built from the validated parts only (no path, query or fragment from the site URL).
        let literal = host == "127.0.0.1" ? host : "[::1]"
        return URL(string: "http://\(literal)\(components.port.map { ":\($0)" } ?? "")/")
    }

    /// Original pages under Tests/Fixtures (the probe's loopback fixture server root), one per seeded item.
    static let fixturePaths = ["alpha": "bookmarks/alpha.html", "beta": "bookmarks/beta.html", "today": "bookmarks/today.html"]

    struct Seeded: Equatable {
        /// Role → ID, for the report (no other values).
        var ids: [String: UUID]
        /// Exactly the two bookmark pages' addresses (Favorite alpha, kept beta). The probe allows an extension to
        /// open these, and only these, besides its own pages, while the seed is on. The Today control isn't included.
        var destinations: [String]
        /// Saved items an extension's bookmarks should list (Favorite + kept page).
        var bookmarkPages: Int { destinations.count }
        var itemCount: Int { ids.count }
    }

    /// Adds, in `space` of `profileID`: a Favorite (alpha), a kept folder holding a nested folder that holds a
    /// kept page (beta), and one ordinary Today tab (control, not saved). All dormant; the selection is kept.
    @discardableResult static func seed(into session: inout BrowserSession, profileID: UUID, space: Int, origin: URL) -> Seeded {
        func address(_ role: String) -> String { destination(role, origin: origin) }
        let alpha = BrowserTab(title: alphaTitle, address: address("alpha"), space: space,
                               saved: SavedTabState(kind: .favorite, address: address("alpha"), isUnloaded: true, profileID: profileID))
        let folder = BrowserFolder(name: folderTitle, space: space)
        let nested = BrowserFolder(name: nestedTitle, space: space, parentID: folder.id)
        let beta = BrowserTab(title: betaTitle, address: address("beta"), space: space,
                              saved: SavedTabState(kind: .kept, address: address("beta"), isUnloaded: true), folderID: nested.id)
        let today = BrowserTab(title: todayTitle, address: address("today"), space: space)
        let selection = session.activeID
        session.tabs += [alpha, beta, today]
        session.folders += [folder, nested]
        session.activeID = selection
        return Seeded(ids: ["favorite_alpha": alpha.id, "folder": folder.id, "nested_folder": nested.id, "kept_beta": beta.id, "today_control": today.id],
                      destinations: [alpha.address, beta.address])
    }

    /// The fixture page for a seeded role on the run's origin.
    static func destination(_ role: String, origin: URL) -> String {
        origin.appendingPathComponent(fixturePaths[role] ?? "bookmarks/\(role).html").absoluteString
    }

    /// The probe's extra navigation allowance while the seed is on: exactly one of the seeded bookmark pages,
    /// compared as the full address string (scheme, host, port, path; no query or fragment). Anything else,
    /// including the Today control, other paths on the same origin and other hosts, stays blocked.
    static func allowsSeededNavigation(_ url: URL, destinations: Set<String>) -> Bool {
        !destinations.isEmpty && destinations.contains(url.absoluteString)
    }
}
