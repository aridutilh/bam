import Foundation

/// bookmarks.getTree model: Chrome-shaped, truthful positions, stable IDs, bounded, consistent or refused.
@main struct ExtensionBookmarkTreeTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("PASS: Extension bookmark tree — \(try run()) checks") }
        catch { fputs("FAIL: Extension bookmark tree: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        typealias T = ExtensionBookmarkTree
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; checks += 1 }
        func page(_ title: String, _ address: String) -> T.Page { T.Page(id: UUID(), title: title, address: address) }
        func nodes(_ node: [String: Any]) -> [[String: Any]] { node["children"] as? [[String: Any]] ?? [] }
        func walk(_ node: [String: Any], _ visit: ([String: Any], [String: Any]?) -> Void, parent: [String: Any]? = nil) {
            visit(node, parent); for child in nodes(node) { walk(child, visit, parent: node) }
        }

        let favorite = page("Mail", "https://mail.example/inbox"), orbit = page("New tab", "orbit://newtab")
        let easel = page("Board", "orbit://arc-easel/3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        let docs = page("Docs", "https://docs.example/"), nested = page("Spec", "http://spec.example/a?b=1")
        let primary = page("Left", "https://left.example/"), secondary = page("Right", "https://right.example/")
        let file = page("Local", "file:///Users/someone/notes.txt")
        let outer = UUID(), inner = UUID(), empty = UUID()
        var builder = T.Builder()
        builder.addFavorite(favorite); builder.addFavorite(orbit)
        builder.addSpace(id: 4, name: "Studio", children: [.page(easel), .folder(outer), .page(docs), .split(primary: primary, secondary: secondary), .page(file)])
        builder.addSpace(id: 9, name: "Life", children: [.folder(empty)])
        builder.addFolder(id: inner, name: "Inner", children: [.page(nested)])
        builder.addFolder(id: outer, name: "Outer", children: [.folder(inner)])
        builder.addFolder(id: empty, name: "Empty", children: [])
        guard let input = builder.result, case .success(let root) = T.tree(input) else { throw Failure(description: "A consistent input was refused") }

        // Shape: root "0" → Favorites, then Spaces in order; folders nest; non-web pages omitted with contiguous indices.
        let top = nodes(root)
        try check(root["id"] as? String == "0" && top.map { $0["id"] as? String } == ["favorites", "space-4", "space-9"] &&
                  top.map { $0["title"] as? String } == ["Favorites", "Studio", "Life"], "Top-level folders or order were wrong: \(top.map { $0["id"] ?? "" })")
        try check(nodes(top[0]).map { $0["title"] as? String } == ["Mail"] && nodes(top[0])[0]["url"] as? String == favorite.address,
                  "Favorites were wrong or a non-web favorite was kept")
        let studio = nodes(top[1])
        try check(studio.map { $0["title"] as? String } == ["Outer", "Docs", "Left", "Right"] && studio.map { $0["index"] as? Int } == [0, 1, 2, 3],
                  "Space order, split pages, omission of Easel/file pages or contiguous indices were wrong: \(studio.map { $0["title"] ?? "" })")
        try check(studio[2]["id"] as? String == primary.id.uuidString && studio[3]["id"] as? String == secondary.id.uuidString,
                  "Split pages did not keep their own stable IDs")
        let outerNode = studio[0], innerNode = nodes(outerNode).first ?? [:]
        try check(outerNode["id"] as? String == outer.uuidString && innerNode["id"] as? String == inner.uuidString &&
                  nodes(innerNode).first?["url"] as? String == nested.address && nodes(innerNode).first?["parentId"] as? String == inner.uuidString,
                  "Nested folders lost their IDs, contents or parent")
        try check(nodes(top[2]).first?["title"] as? String == "Empty" && (nodes(top[2]).first?["children"] as? [Any])?.isEmpty == true, "An empty folder was dropped")

        // Every parentId/index matches the real parent position; IDs are unique; pages have no children; no dates.
        var ids: [String] = [], consistent = true
        walk(root) { node, parent in
            ids.append(node["id"] as? String ?? "?")
            if node["dateAdded"] != nil || node["dateGroupModified"] != nil { consistent = false }
            if node["url"] != nil && node["children"] != nil { consistent = false }
            if let parent { let siblings = nodes(parent)
                if node["parentId"] as? String != parent["id"] as? String || (node["index"] as? Int).map({ siblings.indices.contains($0) && siblings[$0]["id"] as? String == node["id"] as? String }) != true { consistent = false } }
        }
        try check(consistent && Set(ids).count == ids.count, "parentId/index were inconsistent, IDs repeated, or dates were invented")
        // Stable across rebuilds.
        if case .success(let again) = T.tree(input) { var second: [String] = []; walk(again) { node, _ in second.append(node["id"] as? String ?? "?") }
            try check(second == ids, "IDs changed between identical rebuilds") }
        try check(T.tree(T.Input()).map { nodes($0).map { $0["id"] as? String } } == .success(["favorites"]) as Result<[String?], T.Failure>,
                  "An empty profile did not produce just an empty Favorites folder")

        // Inconsistent input is refused, never repaired: duplicate/missing/cyclic folders, repeated pages or Spaces.
        func refused(_ input: T.Input, _ expected: T.Failure) -> Bool { if case .failure(let failure) = T.tree(input) { return failure == expected }; return false }
        let a = UUID(), b = UUID()
        try check(refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: [.folder(a)])], folders: [T.Folder(id: a, name: "A", children: [.folder(b)]), T.Folder(id: b, name: "B", children: [.folder(a)])]), T.inconsistent),
                  "A folder cycle was not refused")
        try check(refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: [.folder(a), .folder(a)])], folders: [T.Folder(id: a, name: "A", children: [])]), T.inconsistent) &&
                  refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: [])], folders: [T.Folder(id: a, name: "A", children: []), T.Folder(id: a, name: "A2", children: [])]), T.inconsistent) &&
                  refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: [.folder(b)])]), T.inconsistent),
                  "A repeated, doubly defined or missing folder was not refused")
        try check(refused(T.Input(favorites: [docs], spaces: [T.Space(id: 1, name: "S", children: [.page(docs)])]), T.inconsistent) &&
                  refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: [.split(primary: docs, secondary: docs)])]), T.inconsistent) &&
                  refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: []), T.Space(id: 1, name: "S2", children: [])]), T.inconsistent),
                  "A repeated page (including inside a split) or Space was not refused")

        // Bounds: depth and output size refuse; the builder stops collecting once its input budget is spent.
        var chain: [T.Folder] = [], ids33 = (0..<33).map { _ in UUID() }
        for (offset, id) in ids33.enumerated() { chain.append(T.Folder(id: id, name: "L\(offset)", children: offset + 1 < ids33.count ? [.folder(ids33[offset + 1])] : [])) }
        try check(refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: [.folder(ids33[0])])], folders: chain), T.tooLarge), "Nesting beyond the depth limit was not refused")
        ids33.removeLast(2); chain = []
        for (offset, id) in ids33.enumerated() { chain.append(T.Folder(id: id, name: "L\(offset)", children: offset + 1 < ids33.count ? [.folder(ids33[offset + 1])] : [])) }
        if case .failure = T.tree(T.Input(spaces: [T.Space(id: 1, name: "S", children: [.folder(ids33[0])])], folders: chain)) { throw Failure(description: "Nesting within the depth limit was refused") }
        checks += 1
        let many = (0..<T.maximumNodes).map { _ in T.Page(id: UUID(), title: "p", address: "https://many.example/") }
        try check(refused(T.Input(spaces: [T.Space(id: 1, name: "S", children: many.map { .page($0) })]), T.tooLarge), "Output beyond the node limit was not refused")
        var budget = T.Builder(), accepted = 0
        for item in many + many.prefix(5) { if budget.addFavorite(item) { accepted += 1 } else { break } }
        try check(accepted == T.maximumInputItems && budget.result == nil && !budget.addSpace(id: 1, name: "S", children: []),
                  "The builder kept collecting past its budget or still produced a partial input")
        return checks
    }
}
