import Foundation

/// What people see for session data. Display only: no tab, folder, Space or stored identifier changes.
/// Covered surfaces: sidebar row tooltips (builder subtitles), the sidebar address field's tooltip, and the
/// Recently Closed window's address column. Other surfaces are not audited here.
enum SidebarDisplayPolicy {
    /// Bam's own pages (the blank New Tab landing page, the PiP demo, Arc Easel references). The legacy
    /// `orbit://` scheme stays in storage and restore; on the covered surfaces it is never shown as an address.
    static func isInternalAddress(_ address: String) -> Bool { address.lowercased().hasPrefix("orbit://") }
    /// The address as people should see it: empty for Bam's own pages.
    static func visibleAddress(_ address: String) -> String { isInternalAddress(address) ? "" : address }
    /// For lists that name every entry's address (Recently Closed): Bam's own pages by a plain name instead.
    static func readableAddress(_ address: String) -> String {
        guard isInternalAddress(address) else { return address }
        if ArcEaselReference.isReference(address) { return "Arc Easel" }
        switch address.lowercased() {
        case "orbit://newtab": return "New Tab"
        case "orbit://video": return "Picture in Picture demo"
        default: return "Bam page"
        }
    }

    /// An unsaved tab still on the blank New Tab landing page that isn't the selected tab is a placeholder, not a
    /// page in use: Arc lists no row for it. It stays in the session (tab switching, restore, Close All Today);
    /// only its sidebar row is omitted. The selected one stays listed so the current tab is never invisible.
    static func hidesPlaceholder(_ tab: BrowserTab, activeID: UUID?, inSplit: Bool) -> Bool {
        !tab.isSaved && !inSplit && tab.id != activeID && tab.address == "orbit://newtab"
    }

    /// Folders the Arc import created, from the session's recorded provenance only (`arc:<id>` → `folder:<uuid>`).
    /// Nothing is inferred from names, and nothing about a source folder's live status is known or claimed.
    static func arcImportedFolderIDs(_ links: [String: String]?) -> Set<UUID> {
        var result = Set<UUID>()
        for (key, value) in links ?? [:] where key.hasPrefix("arc:") && value.hasPrefix("folder:") {
            if let id = UUID(uuidString: String(value.dropFirst("folder:".count))) { result.insert(id) }
        }
        return result
    }
    static let arcImportedFolderNote = "Imported from Arc as saved links. Bam doesn’t update this folder automatically."

    // MARK: Row titles (display only: the stored title, tooltip and history keep the original)

    /// What a sidebar row shows for a page. A title that is only an address (a page that never named itself, or a
    /// restored or imported row) gives way to the best-known title (`knownTitle`, e.g. from history), then the
    /// site's host; never a raw path. A trailing site-name suffix (" – Vercel", " - YouTube", " | Notion") is
    /// dropped when it names the page's own site, as Yab and Arc do.
    static func rowTitle(_ title: String, address: String, knownTitle: String? = nil) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = displayHost(address)
        var best = trimmed
        if trimmed.isEmpty || looksLikeAddress(trimmed, address: address) {
            let known = knownTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !known.isEmpty, !looksLikeAddress(known, address: address) { best = known }
            else if !host.isEmpty { return host }
            else { return trimmed }
        }
        return host.isEmpty ? best : strippingSiteSuffix(best, host: host)
    }

    /// The host people recognize: no scheme, no "www.", no port. Empty for Bam's own pages and non-web text.
    static func displayHost(_ address: String) -> String {
        guard !isInternalAddress(address), let host = URL(string: address)?.host?.lowercased(), !host.isEmpty else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// True when a "title" is really an address: one word with a dot or slash that is the page's own address (or
    /// its host) written out, or any http(s) URL.
    static func looksLikeAddress(_ title: String, address: String) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        guard text.contains(".") || text.contains("/") else { return false }
        func bare(_ value: String) -> String {
            var value = value.lowercased()
            for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
            if value.hasPrefix("www.") { value.removeFirst(4) }
            return value
        }
        let page = bare(address), written = bare(text)
        guard !page.isEmpty else { return false }
        let host = displayHost(address)
        return page.hasPrefix(written) || written.hasPrefix(page) || (!host.isEmpty && written.hasPrefix(host))
    }

    private static let suffixSeparators = [" – ", " — ", " - ", " | ", " · ", " • ", " / "]
    /// Drops the last " – Site" part of a title when it names the page's own site (by host). The rest must keep at
    /// least two characters; otherwise the title is left whole.
    static func strippingSiteSuffix(_ title: String, host: String) -> String {
        var cut: Range<String.Index>?
        for separator in suffixSeparators {
            if let range = title.range(of: separator, options: .backwards), range.lowerBound > (cut?.lowerBound ?? title.startIndex) {
                cut = range
            }
        }
        guard let cut else { return title }
        let head = title[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
        let tail = title[cut.upperBound...]
        guard head.count >= 2, namesSite(String(tail), host: host) else { return title }
        return head
    }
    /// Whether `name` ("YouTube", "Google Maps", "X", "Dia Browser") is the site at `host`.
    static func namesSite(_ name: String, host: String) -> Bool {
        let squashed = String(name.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !squashed.isEmpty, squashed.count <= 32 else { return false }
        let labels = host.lowercased().split(separator: ".").map(String.init)
        let generic: Set<String> = ["www", "com", "org", "net", "app", "mail", "web", "the"]
        if labels.dropLast().contains(squashed) { return true }
        let joined = labels.dropLast().joined()
        if squashed.count >= 3, joined.contains(squashed) { return true }
        return labels.dropLast().contains { $0.count >= 4 && !generic.contains($0) && squashed.contains($0) }
    }
}
