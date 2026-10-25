import Foundation

/// Read-only `bookmarks.getTree` for one login profile, built from Bam's saved items. Pure: no AppKit, no session.
///
/// Input contract (the integration fills it; see `Builder`):
/// - Only the extension's own login profile: that profile's Favorites, then that profile's Spaces in sidebar order.
/// - Each Space lists its kept section's root children in sidebar order; folders are referenced by ID and defined once
///   in `folders` with their own ordered children. Nothing is recursive, so collection is a bounded worklist.
/// - Pages carry the address the user kept (`saved.address`), never the page a tab has since navigated to, and the
///   title Bam shows (custom title, else tab title). Today tabs, other profiles, Easel references and anything not
///   saved are not supplied. A kept Split is supplied as `.split(primary, secondary)` with both tabs' own IDs.
/// - Collect through `Builder`: it stops accepting once `maximumInputItems` is reached and the result is then nil,
///   so a huge or corrupt session is never collected in full.
enum ExtensionBookmarkTree {
    static let maximumInputItems = 10_000
    static let maximumNodes = 10_000
    static let maximumDepth = 32

    struct Page: Equatable, Sendable {
        let id: UUID
        let title: String
        /// The kept (saved) address.
        let address: String
        init(id: UUID, title: String, address: String) { self.id = id; self.title = title; self.address = address }
    }
    enum Child: Equatable, Sendable {
        case folder(UUID)
        case page(Page)
        /// A kept Split: both pages, primary first.
        case split(primary: Page, secondary: Page)
    }
    struct Space: Equatable, Sendable {
        let id: Int
        let name: String
        let children: [Child]
    }
    struct Folder: Equatable, Sendable {
        let id: UUID
        let name: String
        let children: [Child]
    }
    struct Input: Equatable, Sendable {
        var favorites: [Page] = []
        var spaces: [Space] = []
        var folders: [Folder] = []
    }

    /// Bounded collector for the integration. Every add returns false once the budget is spent; stop traversing then.
    struct Builder {
        private(set) var input = Input()
        private(set) var items = 0
        private(set) var exceeded = false
        init() {}
        /// Spends one item for the container plus its children's weight; counting stops at the remaining budget.
        private mutating func spend(_ children: [Child]?) -> Bool {
            guard !exceeded, items < maximumInputItems,
                  let weight = children.map({ ExtensionBookmarkTree.weight($0, limit: maximumInputItems - items - 1) }) ?? 0 else { exceeded = true; return false }
            items += 1 + weight; return true
        }
        @discardableResult mutating func addFavorite(_ page: Page) -> Bool {
            guard spend(nil) else { return false }
            input.favorites.append(page); return true
        }
        @discardableResult mutating func addSpace(id: Int, name: String, children: [Child]) -> Bool {
            guard spend(children) else { return false }
            input.spaces.append(Space(id: id, name: name, children: children)); return true
        }
        @discardableResult mutating func addFolder(id: UUID, name: String, children: [Child]) -> Bool {
            guard spend(children) else { return false }
            input.folders.append(Folder(id: id, name: name, children: children)); return true
        }
        /// Nil when the budget was exceeded: the caller must not return a partial tree.
        var result: Input? { exceeded ? nil : input }
    }

    struct Failure: Error, Equatable, CustomStringConvertible { let description: String }
    static let tooLarge = Failure(description: "These bookmarks are too large or too deeply nested for Bam to provide.")
    static let inconsistent = Failure(description: "Bam's saved items could not be read consistently; try again.")

    /// Items a child list supplies (a split is two pages), or nil as soon as it exceeds `limit`; never scans past it.
    static func weight(_ children: [Child], limit: Int) -> Int? {
        var total = 0
        for child in children {
            if case .split = child { total += 2 } else { total += 1 }
            if total > limit { return nil }
        }
        return total
    }
    /// Everything supplied counts, including unreachable folders and pages that will be dropped as non-web.
    static func preflight(_ input: Input) -> Failure? {
        var supplied = input.favorites.count + input.spaces.count + input.folders.count
        guard supplied <= maximumInputItems else { return tooLarge }
        for space in input.spaces {
            guard let weight = weight(space.children, limit: maximumInputItems - supplied) else { return tooLarge }
            supplied += weight
        }
        for folder in input.folders {
            guard let weight = weight(folder.children, limit: maximumInputItems - supplied) else { return tooLarge }
            supplied += weight
        }
        return nil
    }

    /// Chrome-shaped nodes: `getTree()` resolves to `[root]`. IDs: root "0", "favorites", "space-<id>", then Bam's
    /// own folder and tab UUIDs. `index`/`parentId` are positions after omitting non-web pages. No dates are set.
    static func tree(_ input: Input) -> Result<[String: Any], Failure> {
        if let failure = preflight(input) { return .failure(failure) }
        var folders: [UUID: Folder] = [:]
        for folder in input.folders {
            guard folders[folder.id] == nil else { return .failure(inconsistent) }
            folders[folder.id] = folder
        }
        // One ID space for folders and pages: a page may not reuse a folder's UUID, in either order.
        var usedIDs = Set<UUID>(), nodes = 1
        var failure: Failure?

        func page(_ page: Page, parent: String, index: Int) -> [String: Any]? {
            guard failure == nil else { return nil }
            guard folders[page.id] == nil, usedIDs.insert(page.id).inserted else { failure = inconsistent; return nil }
            guard isWeb(page.address) else { return nil }
            nodes += 1
            guard nodes <= maximumNodes else { failure = tooLarge; return nil }
            return ["id": page.id.uuidString, "parentId": parent, "index": index, "title": page.title, "url": page.address]
        }
        // Iterative over folder references is unnecessary at depth <= 32: recursion depth is checked first.
        func children(_ list: [Child], parent: String, depth: Int) -> [[String: Any]] {
            var result: [[String: Any]] = []
            for child in list {
                guard failure == nil else { return [] }
                switch child {
                case .page(let item):
                    if let node = page(item, parent: parent, index: result.count) { result.append(node) }
                case .split(let primary, let secondary):
                    for item in [primary, secondary] { if let node = page(item, parent: parent, index: result.count) { result.append(node) } }
                case .folder(let id):
                    guard let folder = folders[id], usedIDs.insert(id).inserted else { failure = inconsistent; return [] }
                    guard depth + 1 <= maximumDepth else { failure = tooLarge; return [] }
                    nodes += 1
                    guard nodes <= maximumNodes else { failure = tooLarge; return [] }
                    let key = id.uuidString
                    let nested = children(folder.children, parent: key, depth: depth + 1)
                    result.append(["id": key, "parentId": parent, "index": result.count, "title": folder.name, "children": nested])
                }
            }
            return result
        }

        var top: [[String: Any]] = []
        nodes += 1
        var favorites: [[String: Any]] = []
        for item in input.favorites { if let node = page(item, parent: "favorites", index: favorites.count) { favorites.append(node) } }
        top.append(["id": "favorites", "parentId": "0", "index": 0, "title": "Favorites", "children": favorites])
        var spaceIDs = Set<Int>()
        for space in input.spaces {
            guard failure == nil else { break }
            guard spaceIDs.insert(space.id).inserted else { return .failure(inconsistent) }
            nodes += 1
            guard nodes <= maximumNodes else { return .failure(tooLarge) }
            let key = "space-\(space.id)"
            let nested = children(space.children, parent: key, depth: 1)
            top.append(["id": key, "parentId": "0", "index": top.count, "title": space.name, "children": nested])
        }
        if let failure { return .failure(failure) }
        return .success(["id": "0", "title": "", "children": top])
    }

    /// Only ordinary web pages are bookmarks here: http(s) with a host. Easel references, orbit:// pages, extension
    /// pages and anything else are omitted.
    static func isWeb(_ address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
