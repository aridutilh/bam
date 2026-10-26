import Foundation

/// Chrome `pinned` requests against Bam's saved-tab state. Pure; no tabs are created.
@main struct ExtensionPinnedPolicyTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension pinned tabs — \(try run()) checks") }
        catch { fputs("FAIL: Extension pinned tabs: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias P = ExtensionPinnedPolicy
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        let page = "https://example.com/a"
        let ordinary = P.Tab(retention: .ordinary, address: page)
        let kept = P.Tab(retention: .kept, address: page, savedAddress: page)
        let favorite = P.Tab(retention: .favorite, address: page, savedAddress: page)

        // tabs.create
        try check(P.creationRefusal(url: URL(string: page)!, pinned: true) == nil && P.creationRefusal(url: URL(string: "http://127.0.0.1:8080/x")!, pinned: true) == nil,
                  "A pinned HTTP(S) page was refused")
        for address in ["webkit-extension://ABC/page.html", "orbit://newtab", "file:///tmp/a.html", "about:blank", "data:text/html,x"] {
            try check(P.creationRefusal(url: URL(string: address)!, pinned: true) == P.addressRefusal, "A pinned non-web page was not refused: \(address)")
            try check(P.creationRefusal(url: URL(string: address)!, pinned: false) == nil, "An unpinned request was judged by the pinned rule: \(address)")
        }

        // pinned: true. Already pinned (kept or Favorite) is a no-op: never demoted, moved or customized away.
        try check(P.update(ordinary, pinned: true) == .keep, "An ordinary web tab did not become kept")
        try check(P.update(kept, pinned: true) == .unchanged, "pinned:true changed a kept tab")
        var customizedKept = kept; customizedKept.inFolder = true; customizedKept.hasCustomTitle = true; customizedKept.isSplitMember = true
        try check(P.update(customizedKept, pinned: true) == .unchanged, "pinned:true touched a kept tab's folder, name or split")
        try check(P.update(favorite, pinned: true) == .unchanged, "pinned:true on a Favorite was not a no-op")
        var splitFavorite = favorite; splitFavorite.isSplitMember = true
        try check(P.update(splitFavorite, pinned: true) == .unchanged, "pinned:true on a split Favorite was not a no-op")
        var splitOrdinary = ordinary; splitOrdinary.isSplitMember = true
        try check(P.update(splitOrdinary, pinned: true) == .refuse(P.splitRefusal), "Pinning one pane of a split was not refused")
        for address in ["webkit-extension://ABC/page.html", "orbit://newtab", "orbit://video"] {
            try check(P.update(P.Tab(retention: .ordinary, address: address), pinned: true) == .refuse(P.addressRefusal), "A non-web tab became kept: \(address)")
        }

        // pinned: false
        try check(P.update(ordinary, pinned: false) == .unchanged, "pinned:false changed an ordinary tab")
        try check(P.update(kept, pinned: false) == .release, "A kept tab with nothing to lose did not become ordinary")
        try check(P.update(favorite, pinned: false) == .refuse(P.favoriteRefusal), "Unpinning a Favorite was not refused")
        var splitKept = kept; splitKept.isSplitMember = true
        try check(P.update(splitKept, pinned: false) == .refuse(P.splitRefusal), "Unpinning one pane of a split was not refused")
        // Each piece of Bam-only state refuses on its own.
        var unloaded = kept; unloaded.isUnloaded = true
        try check(P.update(unloaded, pinned: false) == .refuse(P.unloadedRefusal), "Unpinning a closed kept row would wake it")
        var foldered = kept; foldered.inFolder = true
        try check(P.update(foldered, pinned: false) == .refuse(P.folderRefusal), "Unpinning dropped a folder membership")
        var titled = kept; titled.hasCustomTitle = true
        try check(P.update(titled, pinned: false) == .refuse(P.customizedRefusal), "Unpinning dropped a custom name")
        var symbol = kept; symbol.hasCustomSymbol = true
        try check(P.update(symbol, pinned: false) == .refuse(P.customizedRefusal), "Unpinning dropped a custom icon")
        var moved = kept; moved.address = "https://example.com/b"
        try check(P.update(moved, pinned: false) == .refuse(P.movedRefusal), "Unpinning forgot a kept tab's original page")
        var missingOriginal = kept; missingOriginal.savedAddress = nil
        try check(P.update(missingOriginal, pinned: false) == .refuse(P.movedRefusal), "A kept tab without a recorded original was treated as lossless")
        // Split refusal comes first, so no split pane is judged (or changed) by the per-tab rules.
        var everything = kept; everything.isSplitMember = true; everything.inFolder = true; everything.isUnloaded = true
        try check(P.update(everything, pinned: false) == .refuse(P.splitRefusal), "A split pane was judged before its split refusal")
        return checks
    }
}
