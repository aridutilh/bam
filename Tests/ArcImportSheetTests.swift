import AppKit

/// Offscreen layout checks for the Import from Arc sheet: no window is ordered
/// front and no system input is posted. Long reports must scroll while the
/// Cancel/Import footer stays pinned and fully visible at every allowed size.
@main enum ArcImportSheetTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
            : FileManager.default.currentDirectoryPath + "/Tests/Fixtures/arc/StorableSidebar.json")
        let sheet = ArcImportController()
        let window = sheet.window!
        // A worst-case report: every notice present, many Spaces and profiles.
        var heavy = ArcImport.Report()
        heavy.spaces = (0..<14).map { ArcImport.SpaceReport(title: "Space with a fairly long imported name \($0)", emoji: "🧪", isNew: true,
                                                            keptTabs: 40, folders: 6, todayTabs: 12, favorites: 8, splits: 1) }
        heavy.newProfiles = (0..<5).map { "Imported profile \($0) (Arc)" }
        heavy.alreadyImported = 3; heavy.removedSpaces = 1; heavy.excludedFavorites = 2; heavy.easels = 5; heavy.liveFolders = 2
        heavy.flattenedTodayFolders = 1; heavy.favoriteOverflow = 2; heavy.oversizedSplits = 1; heavy.unattachedProfiles = 4
        heavy.unattachedFavorites = 25; heavy.invalidAddresses = 2; heavy.depthLimited = 1; heavy.missingItems = 1
        heavy.skippedSpaces = 1; heavy.approximatedThemes = 1; heavy.customIcons = 1
        require(heavy.notices.count >= 14, "Worst-case report has many notices")
        sheet.preview = { _, _ in heavy }
        sheet.load(fixture)
        require(sheet.source != nil && sheet.report == heavy, "Fixture loads and previews")

        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        func verify(_ size: NSSize, _ label: String) {
            window.setContentSize(size)
            window.contentView!.layoutSubtreeIfNeeded()
            let content = window.contentView!.bounds
            for button in [sheet.importButton, sheet.cancelButton, sheet.chooseButton] {
                let f = frame(button)
                require(content.contains(f) && f.width >= button.intrinsicContentSize.width - 1, "\(button.title) fully visible at \(label): \(f)")
            }
            let scroll = frame(sheet.bodyScroll)
            require(!scroll.intersects(frame(sheet.importButton)) && scroll.height >= 119, "Body sits above the footer at \(label): \(scroll)")
            let document = sheet.bodyScroll.documentView!
            require(document.frame.height > sheet.bodyScroll.contentView.bounds.height, "Long report scrolls at \(label)")
            require(sheet.notices.frame.maxY <= sheet.body.frame.maxY + 0.5 && sheet.notices.frame.width > 200, "Notices are laid out inside the scrolling body at \(label)")
            let option = sheet.recoverBox.alignmentRect(forFrame: sheet.recoverBox.frame)
            require(option.width <= sheet.body.frame.width + 0.5 && option.minX >= -0.5 && sheet.body.frame.width <= document.frame.width + 0.5,
                    "Long option wraps within the body at \(label): \(sheet.recoverBox.frame) in \(sheet.body.frame) / \(document.frame)")
        }
        verify(NSSize(width: 580, height: 560), "default size")
        verify(ArcImportController.minimumSize, "minimum size")
        verify(NSSize(width: 900, height: 900), "large size")
        require(sheet.importButton.isEnabled, "Import is available for a non-empty report")

        // Busy state while saving, then a truthful failure keeps the sheet open.
        var finish: ((String?) -> Void)?
        sheet.onCommit = { _, _, done in finish = done }
        sheet.importButton.performClick(nil)
        require(sheet.isCommitting && !sheet.importButton.isEnabled && !sheet.cancelButton.isEnabled, "Controls lock while the import saves")
        finish?("Bam couldn’t save the imported layout, so the import was undone and nothing was added.")
        require(!sheet.isCommitting && !sheet.status.isHidden && sheet.status.stringValue.contains("undone") && sheet.cancelButton.isEnabled,
                "Save failure is shown and the sheet stays usable")

        // Unreadable source: clear error, nothing to import.
        sheet.load(URL(fileURLWithPath: "/nonexistent/StorableSidebar.json"))
        require(sheet.source == nil && !sheet.importButton.isEnabled && !sheet.status.isHidden, "Unreadable file reports an error and disables Import")
        print("PASS: \(checks) Arc import sheet layout and state checks")
    }
}
