import Foundation

/// Something the browser can do, found by typing its name into the command
/// palette: Settings, History, Manage Spaces… The action is a responder-chain
/// selector name so the catalog stays free of AppKit and the controller, the
/// app delegate, or a Little Bam window can each answer the ones they own.
struct PaletteCommand: Equatable {
    let id: String
    let title: String
    let detail: String
    let keywords: [String]
    let symbol: String
    /// Display-only key equivalent, e.g. "⌘,"; nil shows a plain Command badge.
    let shortcut: String?
    let action: String
}

/// A catalog hit. Leading matches outrank the "Open or search" row: the typed
/// text names the command outright, so Return should run it.
struct PaletteCommandMatch: Equatable {
    let command: PaletteCommand
    let leading: Bool
}

enum PaletteCommandCatalog {
    static let commands: [PaletteCommand] = [
        PaletteCommand(id: "settings", title: "Settings", detail: "Search engine, playback, Spaces and more",
                       keywords: ["preferences", "options", "prefs", "config", "configure", "bam settings", "browser settings"],
                       symbol: "slider.horizontal.3", shortcut: "⌘,", action: "showSettings:"),
        PaletteCommand(id: "manage-spaces", title: "Manage Spaces", detail: "Reorder, remove and assign login profiles",
                       keywords: ["spaces", "workspaces", "profiles", "login profiles"],
                       symbol: "square.stack.3d.up", shortcut: nil, action: "manageSpaces:"),
        PaletteCommand(id: "history", title: "History", detail: "Pages you visited in this profile",
                       keywords: ["visited", "recent pages"],
                       symbol: "clock.arrow.circlepath", shortcut: "⌘Y", action: "showHistory:"),
        PaletteCommand(id: "downloads", title: "Downloads", detail: "Files Bam saved for you",
                       keywords: ["files", "saved files"],
                       symbol: "arrow.down.circle", shortcut: "⌘J", action: "showDownloads:"),
        PaletteCommand(id: "recently-closed", title: "Recently Closed", detail: "Reopen tabs you closed",
                       keywords: ["archive", "closed tabs", "reopen"],
                       symbol: "arrow.uturn.backward", shortcut: nil, action: "showArchive:"),
        PaletteCommand(id: "extensions", title: "Extensions", detail: "Install and manage local extensions",
                       keywords: ["addons", "add-ons", "plugins", "manage extensions"],
                       symbol: "puzzlepiece.extension", shortcut: nil, action: "manageExtensions:"),
        PaletteCommand(id: "little-window", title: "New Little Bam Window", detail: "A small floating page",
                       keywords: ["little window", "popup", "floating window", "new window"],
                       symbol: "macwindow", shortcut: "⌥⌘N", action: "newLittleOrbit:"),
        PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", detail: "Show or hide the tab sidebar",
                       keywords: ["sidebar", "hide sidebar", "show sidebar"],
                       symbol: "sidebar.left", shortcut: "⌘S", action: "toggleSidebar:"),
        PaletteCommand(id: "find", title: "Find in Page", detail: "Search the text of this page",
                       keywords: ["find", "search page", "search in page"],
                       symbol: "doc.text.magnifyingglass", shortcut: "⌘F", action: "findInPage:"),
        PaletteCommand(id: "pip", title: "Picture in Picture", detail: "Float the playing video",
                       keywords: ["pip", "video", "floating video"],
                       symbol: "pip", shortcut: "⌥⌘P", action: "togglePictureInPicture:"),
        PaletteCommand(id: "print", title: "Print Page", detail: "Print or save this page as PDF",
                       keywords: ["print", "pdf"],
                       symbol: "printer", shortcut: "⌘P", action: "printPage:"),
        PaletteCommand(id: "welcome", title: "Welcome to Bam", detail: "Replay the first-run tour",
                       keywords: ["onboarding", "tour", "tutorial", "welcome", "getting started"],
                       symbol: "sparkles", shortcut: nil, action: "showWelcome:"),
        PaletteCommand(id: "about", title: "About Bam", detail: "Version and credits",
                       keywords: ["version", "about", "credits"],
                       symbol: "info.circle", shortcut: nil, action: "showAbout:")
    ]

    /// Ranks: 0 — the whole query starts a title or keyword ("sett" → Settings);
    /// 1 — it starts a later word ("spaces" → Manage Spaces); 2 — every typed
    /// token starts some word ("bam about"). Only rank 0 with three or more
    /// characters leads, so "se" or "hi" never hijacks Return from a web search.
    static func matches(_ raw: String, limit: Int = 3) -> [PaletteCommandMatch] {
        let query = normalized(raw)
        guard query.count >= 2, limit > 0 else { return [] }
        let tokens = query.split(separator: " ").map(String.init)
        return commands.enumerated().compactMap { index, command -> (PaletteCommandMatch, Int, Int)? in
            let names = [command.title.lowercased()] + command.keywords.map { $0.lowercased() }
            let words = names.flatMap { $0.split(separator: " ").map(String.init) }
            let rank: Int
            if names.contains(where: { $0.hasPrefix(query) }) { rank = 0 }
            else if words.contains(where: { $0.hasPrefix(query) }) { rank = 1 }
            else if tokens.count > 1, tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) { rank = 2 }
            else { return nil }
            return (PaletteCommandMatch(command: command, leading: rank == 0 && query.count >= 3), rank, index)
        }.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.2 < rhs.2 }
        .prefix(limit).map { $0.0 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
