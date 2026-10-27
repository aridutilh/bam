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
        PaletteCommand(id: "recently-closed", title: "Archived Tabs", detail: "Tabs you closed or Bam archived, to restore",
                       keywords: ["archive", "recently closed", "closed tabs", "reopen", "view archive"],
                       symbol: "arrow.uturn.backward", shortcut: nil, action: "showArchive:"),
        PaletteCommand(id: "extensions", title: "Manage Extensions", detail: "Turn extensions on or off, site access and updates",
                       keywords: ["extensions", "addons", "add-ons", "plugins"],
                       symbol: "puzzlepiece.extension", shortcut: nil, action: "manageExtensions:"),
        PaletteCommand(id: "add-extension", title: "Add Extension", detail: "Browse and install an extension",
                       keywords: ["install extension", "extension library", "chrome extension", "get extensions"],
                       symbol: "plus.app", shortcut: nil, action: "showExtensionLibrary:"),
        PaletteCommand(id: "new-tab", title: "New Tab", detail: "Open a page in a new tab",
                       keywords: ["open tab"],
                       symbol: "plus", shortcut: nil, action: "newTab:"),
        PaletteCommand(id: "reopen-tab", title: "Reopen Closed Tab", detail: "Bring back the tab you closed last",
                       keywords: ["undo close", "restore tab"],
                       symbol: "arrow.uturn.backward.circle", shortcut: "⇧⌘T", action: "reopenTab:"),
        PaletteCommand(id: "new-space", title: "New Space", detail: "Create a Space with its own color and tabs",
                       keywords: ["create space", "add space", "workspace"],
                       symbol: "plus.square.on.square", shortcut: nil, action: "newSpace:"),
        PaletteCommand(id: "next-space", title: "Next Space", detail: "Switch to the Space on the right",
                       keywords: ["switch space"],
                       symbol: "chevron.right.square", shortcut: nil, action: "nextSpace:"),
        PaletteCommand(id: "previous-space", title: "Previous Space", detail: "Switch to the Space on the left",
                       keywords: ["switch space"],
                       symbol: "chevron.left.square", shortcut: nil, action: "previousSpace:"),
        PaletteCommand(id: "new-folder", title: "New Folder", detail: "Group kept tabs in this Space",
                       keywords: ["create folder", "group tabs"],
                       symbol: "folder.badge.plus", shortcut: nil, action: "newFolder:"),
        PaletteCommand(id: "import-arc", title: "Import from Arc", detail: "Bring over Spaces, Favorites and kept tabs",
                       keywords: ["arc import", "migrate", "move from arc"],
                       symbol: "square.and.arrow.down", shortcut: nil, action: "importFromArc:"),
        PaletteCommand(id: "copy-url", title: "Copy URL", detail: "Copy this page's address",
                       keywords: ["copy link", "copy address", "share link", "clean link"],
                       symbol: "link", shortcut: "⇧⌘C", action: "copyCurrentURL:"),
        PaletteCommand(id: "duplicate-tab", title: "Duplicate Tab", detail: "Open a copy of this tab just below it",
                       keywords: ["duplicate", "copy tab", "clone tab"],
                       symbol: "plus.square.on.square", shortcut: nil, action: "duplicateTab:"),
        PaletteCommand(id: "rename-tab", title: "Rename Tab", detail: "Give this tab its own name",
                       keywords: ["rename", "tab name", "title"],
                       symbol: "pencil", shortcut: nil, action: "renameTab:"),
        PaletteCommand(id: "change-tab-icon", title: "Change Tab Icon", detail: "Pick an icon (and name) for this tab",
                       keywords: ["icon", "change icon", "tab icon", "symbol", "edit tab"],
                       symbol: "face.smiling", shortcut: nil, action: "changeTabIcon:"),
        PaletteCommand(id: "mute-tab", title: "Mute or Unmute Tab", detail: "Silence this tab's sound, or bring it back",
                       keywords: ["mute", "unmute", "sound", "audio", "silence"],
                       symbol: "speaker.slash", shortcut: nil, action: "toggleMuteTab:"),
        PaletteCommand(id: "close-tabs-below", title: "Close Tabs Below", detail: "Close the Today tabs under this one",
                       keywords: ["close below", "archive tabs below", "close tabs"],
                       symbol: "xmark.square", shortcut: nil, action: "closeTabsBelow:"),
        PaletteCommand(id: "copy-markdown-link", title: "Copy URL as Markdown", detail: "Copy [Title](address) for this page",
                       keywords: ["copy markdown link", "markdown", "copy markdown", "md link", "copy title"],
                       symbol: "link.badge.plus", shortcut: "⌥⇧⌘C", action: "copyMarkdownLink:"),
        PaletteCommand(id: "reading-mode", title: "Reading Mode", detail: "The article alone in one clean column",
                       keywords: ["reader", "reader mode", "read", "article"],
                       symbol: "book", shortcut: "⌥⌘R", action: "toggleReadingMode:"),
        PaletteCommand(id: "hide-elements", title: "Hide Elements", detail: "Click banners, ads or sidebars to hide them on this site",
                       keywords: ["hide", "remove element", "zap", "block element", "cookie banner"],
                       symbol: "eye.slash", shortcut: "⇧⌘H", action: "hideElements:"),
        PaletteCommand(id: "restore-hidden", title: "Restore Hidden Elements", detail: "Bring back what you hid on this site",
                       keywords: ["unhide", "show hidden", "restore elements"],
                       symbol: "eye", shortcut: nil, action: "restoreHiddenElements:"),
        PaletteCommand(id: "web-inspector", title: "Developer Tools", detail: "Inspect this page's HTML, CSS and network",
                       keywords: ["show web inspector", "web inspector", "devtools", "developer tools", "inspector", "inspect"],
                       symbol: "hammer", shortcut: "⌥⌘I", action: "showWebInspector:"),
        PaletteCommand(id: "js-console", title: "JavaScript Console", detail: "Logs and a console for this page",
                       keywords: ["console", "javascript", "js", "devtools"],
                       symbol: "terminal", shortcut: "⌥⌘J", action: "showJavaScriptConsole:"),
        PaletteCommand(id: "inspect-element", title: "Inspect Elements", detail: "Pick something on the page to inspect",
                       keywords: ["inspect element", "inspect", "element picker", "devtools"],
                       symbol: "cursorarrow.rays", shortcut: "⌥⌘C", action: "inspectElement:"),
        PaletteCommand(id: "split-view", title: "Split View", detail: "Open a new page beside this one",
                       keywords: ["split", "side by side"],
                       symbol: "rectangle.split.2x1", shortcut: "⌃⇧=", action: "splitWithNewPage:"),
        PaletteCommand(id: "appearance-dark", title: "Dark Appearance", detail: "Use dark chrome everywhere",
                       keywords: ["dark mode", "theme", "night"],
                       symbol: "moon", shortcut: nil, action: "useDarkAppearance:"),
        PaletteCommand(id: "appearance-light", title: "Light Appearance", detail: "Use light chrome everywhere",
                       keywords: ["light mode", "theme", "day"],
                       symbol: "sun.max", shortcut: nil, action: "useLightAppearance:"),
        PaletteCommand(id: "appearance-system", title: "System Appearance", detail: "Follow macOS light or dark",
                       keywords: ["auto appearance", "theme", "match system"],
                       symbol: "circle.lefthalf.filled", shortcut: nil, action: "useSystemAppearance:"),
        PaletteCommand(id: "zoom-in", title: "Zoom In", detail: "Make this site's text and images bigger",
                       keywords: ["bigger", "larger text"],
                       symbol: "plus.magnifyingglass", shortcut: "⌘+", action: "zoomIn:"),
        PaletteCommand(id: "zoom-out", title: "Zoom Out", detail: "Make this site's text and images smaller",
                       keywords: ["smaller", "smaller text"],
                       symbol: "minus.magnifyingglass", shortcut: "⌘−", action: "zoomOut:"),
        PaletteCommand(id: "actual-size", title: "Actual Size", detail: "Reset this site's zoom",
                       keywords: ["reset zoom", "zoom reset"],
                       symbol: "1.magnifyingglass", shortcut: "⌘0", action: "actualSize:"),
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
                       symbol: "info.circle", shortcut: nil, action: "showAbout:"),
        PaletteCommand(id: "capture", title: "Capture", detail: "Click a block or drag an area of the page to copy a picture of it",
                       keywords: ["screenshot", "capture", "snapshot", "screen shot"],
                       symbol: "camera.viewfinder", shortcut: "⇧⌘2", action: "capturePage:"),
        PaletteCommand(id: "capture-full-page", title: "Capture Full Page", detail: "A picture of the whole page, top to bottom",
                       keywords: ["full page screenshot", "whole page", "long screenshot", "scrolling screenshot"],
                       symbol: "doc.viewfinder", shortcut: nil, action: "captureFullPage:"),
    ]

    /// Ranks: 0 — the whole query starts a title or keyword ("sett" → Settings);
    /// 1 — it starts a later word ("spaces" → Manage Spaces); 2 — every typed
    /// token starts some word ("bam about"). Only a title prefix of three or
    /// more characters leads: "settings" runs Settings on Return, while a
    /// keyword hit like "pdf" or "video" stays below the web-search row.
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
            let leading = query.count >= 3 && command.title.lowercased().hasPrefix(query)
            return (PaletteCommandMatch(command: command, leading: leading), rank, index)
        }.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.2 < rhs.2 }
        .prefix(limit).map { $0.0 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
