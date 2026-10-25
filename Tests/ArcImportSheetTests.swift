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
            require(abs(content.width - size.width) < 0.5 && abs(content.height - size.height) < 0.5,
                    "The sheet actually reaches \(label) (long labels wrap, never hold it wider): \(content.size)")
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

        // Per-Space selection, with the real importer behind the preview.
        let picker = ArcImportController()
        let pickerWindow = picker.window!
        picker.preview = { source, options in ArcImport.apply(source, to: BrowserSession.fresh(), options: options).report }
        picker.load(fixture)
        guard let source = picker.source else { fatalError("Fixture must load for selection checks") }
        let ids = source.spaces.map(\.id)
        let full = ArcImport.apply(source, to: BrowserSession.fresh(), options: ArcImport.Options()).report
        require(ids.count == 3 && picker.spaceBoxes.count == 3 && ids.allSatisfy { picker.spaceBoxes[$0]?.state == .on },
                "Every Arc Space gets a checkbox, all selected by default")
        require(picker.options.spaceIDs == nil && picker.report == full, "All selected previews exactly the full import")
        let work = picker.spaceBoxes[ids[0]]!
        require(work.title.hasSuffix("Work") && (work.accessibilityLabel() ?? "").hasPrefix("\(work.title): ") && (work.accessibilityLabel() ?? "").contains("kept"),
                "A Space row reads as one accessible checkbox: its name, then what it adds")
        // Keyboard: toggling keeps focus on the same checkbox (rows aren't rebuilt).
        pickerWindow.makeFirstResponder(work)
        work.performClick(nil)
        require(pickerWindow.firstResponder === work && picker.spaceBoxes[ids[0]] === work && work.state == .off, "Toggling keeps keyboard focus on that checkbox")
        require(picker.options.spaceIDs == Set(ids.dropFirst()) && picker.report?.spaces.contains { $0.sourceSpaceID == ids[0] } == false
                && (work.accessibilityLabel() ?? "").hasSuffix("Not imported") && picker.importButton.isEnabled,
                "Leaving a Space out recomputes the preview without it; the rest still import")
        require((picker.report?.importedTabs ?? 0) < full.importedTabs && picker.report?.excludedFavorites == 0,
                "Its tabs are no longer counted; its profile's Favorites follow the other selected Space on that profile")
        // Today/Favorites options keep their meaning with a partial selection.
        picker.todayBox.performClick(nil)
        require(picker.options.includeToday == false && picker.options.spaceIDs == Set(ids.dropFirst())
                && picker.report == ArcImport.apply(source, to: .fresh(), options: picker.options).report,
                "Options combine with the selection")
        picker.todayBox.performClick(nil)
        // No Space selected: explicit feedback, Import disabled — unless other-profile Favorites add something.
        for id in ids.dropFirst() { picker.spaceBoxes[id]!.performClick(nil) }
        require(picker.selectedSpaceCount == 0 && picker.report?.isEmpty == true && !picker.importButton.isEnabled,
                "With nothing selected and nothing else to add, Import is disabled")
        let unattached = picker.report?.unattachedProfiles ?? 0
        require(unattached > 0 && !picker.recoverBox.isHidden, "The fixture's unused Arc profile keeps its recovery option visible")
        require((picker.report?.excludedFavorites ?? 0) > 0, "Favorites of profiles whose Spaces are all left out are reported, not orphaned")
        let headline = (picker.body.arrangedSubviews.first as? NSStackView)?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        require(headline.first == "No Spaces selected" && headline.dropFirst().first?.contains("other Arc profiles") == true,
                "Empty selection says so plainly and points to the other-profile option")
        picker.recoverBox.performClick(nil)
        require(picker.selectedSpaceCount == 0 && picker.report?.isEmpty == false && picker.importButton.isEnabled
                && picker.report?.spaces.allSatisfy { $0.sourceSpaceID == nil } == true,
                "Zero Spaces plus other-profile Favorites is a valid import (enabled from the actual plan)")
        picker.recoverBox.performClick(nil)
        // Reloading the same file keeps deliberate exclusions; a different file never inherits stale ones.
        picker.spaceBoxes[ids[1]]!.performClick(nil)
        picker.load(fixture)
        require(picker.excludedSpaceIDs == [ids[0], ids[2]] && picker.spaceBoxes[ids[1]]?.state == .on && picker.spaceBoxes[ids[0]]?.state == .off,
                "Reloading the same layout keeps the user's choices")
        let workDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let otherFile = workDir.appendingPathComponent("other-layout.json")
        var text = try! String(contentsOf: fixture, encoding: .utf8)
        for (index, id) in ids.enumerated() { text = text.replacingOccurrences(of: id, with: "00000000-0000-4000-8000-0000000009\(String(format: "%02d", index))") }
        for (old, long) in [("\"Work\"", "\"A Space with a very long imported name that must wrap or truncate nicely\""),
                            ("\"Home\"", "\"Another long Space name from a different Arc layout file\"")] {
            text = text.replacingOccurrences(of: "\"title\" : \(old)", with: "\"title\" : \(long)")
        }
        try! text.write(to: otherFile, atomically: true, encoding: .utf8)
        picker.load(otherFile)
        require(picker.source != nil && picker.excludedSpaceIDs.isEmpty && picker.options.spaceIDs == nil
                && picker.spaceBoxes.count == 3 && picker.spaceBoxes.values.allSatisfy { $0.state == .on },
                "A different layout starts with every Space selected; stale IDs never suppress it")
        // Long Space names stay inside the scrolling body at every size, footer pinned.
        for size in [ArcImportController.minimumSize, NSSize(width: 580, height: 560)] {
            pickerWindow.setContentSize(size); pickerWindow.contentView!.layoutSubtreeIfNeeded()
            let body = picker.body.convert(picker.body.bounds, to: nil)
            let content = pickerWindow.contentView!.bounds
            require(abs(content.width - size.width) < 0.5 && body.maxX <= content.maxX, "The sheet reaches \(size) and the body fits it: \(body) in \(content)")
            for box in picker.spaceBoxes.values {
                let f = box.superview!.convert(box.alignmentRect(forFrame: box.frame), to: nil)
                require(f.minX >= body.minX - 0.5 && f.maxX <= body.maxX + 0.5, "Space rows stay within the body at \(size): \(f) in \(body)")
            }
            require(pickerWindow.contentView!.bounds.contains(picker.importButton.convert(picker.importButton.bounds, to: nil)),
                    "Import stays visible with Space rows at \(size)")
        }
        // Header with a long layout path (native 0636 finding): Choose File… stays
        // fully visible at its natural width; the path truncates before it.
        var longDir = workDir
        for part in ["a-deliberately-long-folder-name-for-the-header-test", "another-nested-folder", "fixtures-theme-visual-copy"] {
            longDir.appendPathComponent(part, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: longDir, withIntermediateDirectories: true)
        let longPath = longDir.appendingPathComponent("StorableSidebar.json")
        try? FileManager.default.removeItem(at: longPath)
        try! FileManager.default.copyItem(at: fixture, to: longPath)
        let header = ArcImportController()
        header.preview = { source, options in ArcImport.apply(source, to: BrowserSession.fresh(), options: options).report }
        let headerWindow = header.window!
        // Native order: the sheet is laid out at its default size first, then the layout file loads.
        headerWindow.contentView!.layoutSubtreeIfNeeded()
        header.load(longPath)
        for size in [NSSize(width: 580, height: 560), ArcImportController.minimumSize, NSSize(width: 580, height: 560), NSSize(width: 900, height: 700)] {
            if headerWindow.contentView!.bounds.size != size { headerWindow.setContentSize(size) }
            headerWindow.contentView!.layoutSubtreeIfNeeded()
            let content = headerWindow.contentView!.bounds
            let row = header.chooseButton.superview!, headerStack = row.superview!
            let headerFrame = headerStack.convert(headerStack.bounds, to: nil), rowFrame = row.convert(row.bounds, to: nil)
            let button = header.chooseButton.superview!.convert(header.chooseButton.alignmentRect(forFrame: header.chooseButton.frame), to: nil)
            let path = header.sourceLabel.superview!.convert(header.sourceLabel.alignmentRect(forFrame: header.sourceLabel.frame), to: nil)
            require(abs(content.width - size.width) < 0.5, "Header test runs at \(size)")
            require(content.contains(button) && button.maxX <= headerFrame.maxX + 0.5 && button.maxX <= rowFrame.maxX + 0.5
                    && button.width >= header.chooseButton.intrinsicContentSize.width - 1,
                    "Choose File… is fully visible at its natural width at \(size): \(button) in header \(headerFrame)")
            require(path.minX >= headerFrame.minX - 0.5 && path.maxX <= button.minX - 9.5 && path.width > 40,
                    "The path ends before the button with a gap, inside the header, at \(size): path \(path) button \(button)")
            if size.width <= 580 {
                require(path.width < header.sourceLabel.intrinsicContentSize.width - 1 && header.sourceLabel.lineBreakMode == .byTruncatingMiddle,
                        "A long path truncates in the middle rather than pushing the button out at \(size)")
            }
        }

        // Commit carries the selection.
        var committed: ArcImport.Options?
        picker.onCommit = { _, options, done in committed = options; done(nil) }
        let longBox = picker.spaceBoxes.values.first { $0.title.contains("very long") }!
        longBox.performClick(nil)
        picker.importButton.performClick(nil)
        let longID = String(longBox.identifier!.rawValue.dropFirst("arc-space-".count))
        require(committed?.spaceIDs?.contains(longID) == false && committed?.spaceIDs?.count == 2, "Import commits exactly the selected Spaces")
        print("PASS: \(checks) Arc import sheet layout and state checks")
    }
}
