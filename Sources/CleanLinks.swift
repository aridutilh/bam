import Foundation

/// Copy-ready links: the page's address without the tracking parameters that
/// ride along on shared links, and the same link as Markdown. Pure Foundation,
/// so the rules are tested on their own (Tests/CleanLinksTests.swift).
enum CleanLinks {
    /// Names that only ever identify a campaign, ad click or share, on any site.
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "igsh", "mc_eid", "mc_cid", "mkt_tok", "_openstat", "ref_src", "ref_url",
        "s_cid", "wickedid", "rb_clickid", "srsltid", "_gl", "_ga", "_hsenc", "_hsmi", "__hssc", "__hstc",
        "__hsfp", "hsctatracking", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "ncid", "sc_cid",
        "epik", "_kx", "irclickid", "ocid",
        // Matomo/Piwik campaign names. Not a pk_ prefix: pk_id, pk_slug… are often a page's own key.
        "pk_campaign", "pk_cpn", "pk_kwd", "pk_keyword", "pk_source", "pk_medium", "pk_content", "pk_cid", "pk_group", "pk_vid"
    ]
    /// Name prefixes for campaign families (utm_source, mtm_kwd, hsa_acc…).
    static let trackingPrefixes = ["utm_", "mtm_", "hsa_"]
    /// Share parameters that are tracking only on these sites; elsewhere the
    /// same short names (si, s, t, feature) can be the page's own.
    static let siteTracking: [(hosts: [String], names: Set<String>, prefixes: [String])] = [
        (["youtube.com", "youtu.be", "youtube-nocookie.com"], ["si", "feature", "pp"], []),
        (["spotify.com"], ["si", "nd", "dlsi"], []),
        (["x.com", "twitter.com"], ["s", "t"], []),
        (["instagram.com"], ["img_index"], []),
        (["linkedin.com"], ["trk", "trackingid", "lipi", "licu", "midtoken", "midsig", "trkemail"], []),
        (["tiktok.com"], ["_r", "_t", "is_from_webapp", "sender_device", "share_app_id", "share_link_id",
                          "social_sharing", "u_code", "tt_from", "user_id", "sec_user_id"], []),
        (["reddit.com"], ["share_id", "rdt", "correlation_id", "ref_campaign", "ref_source"], []),
        (["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.ca", "amazon.co.jp", "amazon.es", "amazon.it"],
         ["_encoding", "content-id", "qid", "sr", "crid", "sprefix", "dib", "dib_tag", "psc", "linkcode", "tag",
          "linkid", "camp", "creative", "creativeasin", "ascsubtag"], ["pd_rd_", "pf_rd_", "ref_"]),
        (["medium.com"], ["source", "sk"], []),
        (["substack.com"], ["r", "triedredirect", "publication_id", "post_id", "isfreemail"], []),
    ]

    /// The address without tracking parameters. Everything else — the path,
    /// the remaining parameters in their order and spelling, the fragment —
    /// is kept exactly; a URL with nothing to remove comes back unchanged.
    static func clean(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.percentEncodedQueryItems, !items.isEmpty else { return url }
        let host = (parts.host ?? "").lowercased()
        let local = siteTracking.filter { rule in rule.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
        let kept = items.filter { item in
            let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
            if trackingNames.contains(name) || trackingPrefixes.contains(where: name.hasPrefix) { return false }
            for rule in local where rule.names.contains(name) || rule.prefixes.contains(where: name.hasPrefix) { return false }
            return true
        }
        guard kept.count != items.count else { return url }
        parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }

    /// "[Title](address)", safe to paste into any Markdown: brackets in the
    /// title are escaped, whitespace is folded, and the address cannot end the
    /// link early. A page without a title is named by its host and path.
    static func markdown(title: String?, url: URL) -> String {
        "[\(escapedTitle(title, url: url))](\(markdownAddress(url)))"
    }

    /// The link as rich text, so Mail, Notes, Slack and Docs paste the title as a live link.
    static func html(title: String?, url: URL) -> String {
        let text = displayTitle(title, url: url)
        return "<a href=\"\(escapeHTML(url.absoluteString))\">\(escapeHTML(text))</a>"
    }

    static func displayTitle(_ title: String?, url: URL) -> String {
        let folded = (title ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if !folded.isEmpty { return folded }
        let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        let path = url.path == "/" ? "" : url.path
        let fallback = host + path
        return fallback.isEmpty ? url.absoluteString : fallback
    }

    private static func escapedTitle(_ title: String?, url: URL) -> String {
        var out = ""
        for character in displayTitle(title, url: url) {
            if "\\[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func markdownAddress(_ url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
