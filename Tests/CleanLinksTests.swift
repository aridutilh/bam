import Foundation

/// Copy Link drops tracking parameters and keeps everything a page needs.
@main struct CleanLinksTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    nonisolated(unsafe) static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
        checks += 1
    }
    static func clean(_ text: String) -> String { CleanLinks.clean(URL(string: text)!).absoluteString }
    static func main() {
        do { try run(); print("PASS: \(checks) clean link checks") }
        catch { print("FAIL: Clean links — \(error)"); exit(1) }
    }
    static func run() throws {
        // Campaign and click IDs go; nothing else changes.
        try check(clean("https://example.com/a?utm_source=x&utm_medium=y&utm_campaign=z") == "https://example.com/a",
                  "utm_ parameters stayed: \(clean("https://example.com/a?utm_source=x&utm_medium=y&utm_campaign=z"))")
        try check(clean("https://example.com/a?id=7&fbclid=abc&page=2#top") == "https://example.com/a?id=7&page=2#top",
                  "Functional parameters, their order or the fragment were lost")
        try check(clean("https://shop.example/p?gclid=1&gbraid=2&wbraid=3&msclkid=4&mc_eid=5&mc_cid=6&igshid=7&_hsenc=8&mkt_tok=9")
                  == "https://shop.example/p", "Click IDs stayed")
        try check(clean("https://example.com/?UTM_Source=news") == "https://example.com/", "Parameter names are not case-insensitive")
        try check(clean("https://example.com/?pk_campaign=a&mtm_kwd=b&q=keep") == "https://example.com/?q=keep", "Matomo/Piwik prefixes stayed")
        try check(clean("https://shop.example/item?pk_id=5&pk_source=n") == "https://shop.example/item?pk_id=5",
                  "A page's own pk_ key was stripped: \(clean("https://shop.example/item?pk_id=5&pk_source=n"))")
        // A clean address comes back exactly as it was, encoding included.
        let tidy = "https://example.com/search?q=caf%C3%A9%20au%20lait&lang=fr"
        try check(clean(tidy) == tidy, "A clean URL changed: \(clean(tidy))")
        try check(clean("https://example.com/search?q=a%20b&utm_source=x") == "https://example.com/search?q=a%20b", "Encoding was rewritten")
        try check(clean("https://example.com/") == "https://example.com/", "A bare URL changed")

        // Short share names only on the sites that use them for tracking.
        try check(clean("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc123&t=42") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42",
                  "YouTube kept si or lost the video/timestamp")
        try check(clean("https://youtu.be/dQw4w9WgXcQ?si=abc&feature=shared") == "https://youtu.be/dQw4w9WgXcQ", "youtu.be kept share params")
        try check(clean("https://open.spotify.com/track/123?si=abcdef") == "https://open.spotify.com/track/123", "Spotify kept si")
        try check(clean("https://x.com/user/status/1?s=20&t=abcd") == "https://x.com/user/status/1", "X kept s/t")
        try check(clean("https://twitter.com/user/status/1?ref_src=twsrc%5Etfw") == "https://twitter.com/user/status/1", "ref_src stayed")
        try check(clean("https://example.com/page?si=1&s=2&t=3&feature=4") == "https://example.com/page?si=1&s=2&t=3&feature=4",
                  "Site-specific names were stripped from an unrelated site")
        try check(clean("https://www.linkedin.com/posts/x?trk=public_post&lipi=abc") == "https://www.linkedin.com/posts/x", "LinkedIn kept trk/lipi")
        try check(clean("https://www.amazon.com/dp/B0?pd_rd_w=1&pf_rd_p=2&ref_=3&th=1") == "https://www.amazon.com/dp/B0?th=1",
                  "Amazon kept pd_rd_/pf_rd_/ref_ or lost the variant")
        // Functional look-alikes stay: GitHub's ref is a branch, Google's q is the search.
        try check(clean("https://github.com/a/b/blob/main/x?ref=feature-branch") == "https://github.com/a/b/blob/main/x?ref=feature-branch",
                  "A generic ref parameter was stripped")
        try check(clean("https://www.google.com/search?q=bam+browser&utm_source=x") == "https://www.google.com/search?q=bam+browser",
                  "A search query was damaged")
        try check(clean("http://localhost:3000/cb?code=abc&state=1") == "http://localhost:3000/cb?code=abc&state=1", "OAuth params were stripped")

        // Markdown: [Title](address), safe to paste.
        let page = URL(string: "https://example.com/a")!
        try check(CleanLinks.markdown(title: "Hello world", url: page) == "[Hello world](https://example.com/a)", "Plain Markdown link was wrong")
        try check(CleanLinks.markdown(title: "  Line\n one [draft] \\ two ", url: page) == "[Line one \\[draft\\] \\\\ two](https://example.com/a)",
                  "Title was not folded/escaped: \(CleanLinks.markdown(title: "  Line\n one [draft] \\ two ", url: page))")
        let wiki = URL(string: "https://en.wikipedia.org/wiki/Bam_(disambiguation)")!
        try check(CleanLinks.markdown(title: "Bam", url: wiki) == "[Bam](https://en.wikipedia.org/wiki/Bam_%28disambiguation%29)",
                  "Parentheses could end the link early")
        try check(CleanLinks.markdown(title: nil, url: URL(string: "https://www.example.com/docs/intro")!) == "[example.com/docs/intro](https://www.example.com/docs/intro)",
                  "Untitled page was not named by host and path")
        try check(CleanLinks.markdown(title: "", url: URL(string: "https://example.com/")!) == "[example.com](https://example.com/)", "Untitled root fallback")
        try check(CleanLinks.html(title: "A <b> & \"c\"", url: URL(string: "https://e.com/?a=1&b=2")!)
                  == "<a href=\"https://e.com/?a=1&amp;b=2\">A &lt;b&gt; &amp; &quot;c&quot;</a>", "HTML link was not escaped")
    }
}
