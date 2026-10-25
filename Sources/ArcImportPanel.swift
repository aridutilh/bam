import AppKit

/// File > Import from Arc…: choose Arc's layout file, preview exactly what
/// will be added, then commit once. Nothing changes until Import is pressed.
@MainActor extension BrowserController {
    @objc func importFromArc(_ sender: Any?) {
        guard !isShuttingDown, !suspendsChromeInteraction, arcImporter == nil,
              let window = view.window, window.attachedSheet == nil else { return }
        cancelPaging(); dismissAddress(); findBar.hide(); pageFeedback.hide()
        let importer = ArcImportController()
        arcImporter = importer
        importer.preview = { [weak self] source, options in
            guard let self else { return ArcImport.Report() }
            return ArcImport.apply(source, to: self.session, options: options).report
        }
        importer.onCommit = { [weak self] source, options, done in
            guard let self else { done("Bam is closing."); return }
            self.commitArcImport(source, options: options, completion: done)
        }
        importer.onDismiss = { [weak self] in
            guard let self else { return }
            self.arcImporter = nil
            self.view.window?.makeFirstResponder(self.commandWebView)
        }
        importer.present(on: window)
        let defaultSource = ArcImport.defaultSourceURL()
        if FileManager.default.isReadableFile(atPath: defaultSource.path) { importer.load(defaultSource) }
    }

    /// Applies the import in one step and reports the real save outcome.
    ///
    /// No imported page is created or loaded: the window lands on a new blank
    /// tab in the first imported Space, and every imported tab stays dormant
    /// until the user selects it. The completion runs only after the session
    /// writer confirms the write. If it fails or times out, exactly the
    /// imported additions are removed again and that undo is itself confirmed
    /// before the message says so.
    func commitArcImport(_ source: ArcImport.Source, options: ArcImport.Options, completion: @escaping (String?) -> Void) {
        cancelPaging(); cancelAutomaticDepartures()
        let previous = session
        let (updated, report) = ArcImport.apply(source, to: session, options: options)
        if let refusal = report.refusal { completion(refusal); return }
        guard !report.isEmpty else { completion(report.emptyReason); return }
        session = updated
        if let first = report.firstSpaceID, session.spaceDefinition(first) != nil {
            session.changeSpace(first)
            session.add()  // A blank page, so nothing imported is instantiated on arrival.
        }
        let imported = session
        showActive(); refreshPaletteResults(); onSpacesChanged?()
        let tabs = report.importedTabs
        let succeed = { [weak self] in
            self?.pageFeedback.show("Imported \(tabs) tab\(tabs == 1 ? "" : "s") from Arc", symbol: "square.and.arrow.down", in: self?.webHost ?? NSView())
            completion(nil)
        }
        guard let writer = sessionWriter, !privateMode else { succeed(); return }
        save()
        Task { @MainActor [weak self] in
            if await writer.flushAsync(timeout: 30) { succeed(); return }
            guard let self else { completion("Bam couldn’t confirm the import was saved."); return }
            // The write failed or is still stuck. Undo only what the import
            // added; the serial writer saves this after any in-flight write.
            let addedIDs = Set(imported.tabs.map(\.id)).subtracting(previous.tabs.map(\.id))
            self.session = ArcImport.undo(imported, over: previous, in: self.session)
            for id in addedIDs { self.discardInstantiatedPage(id) }
            self.showActive(); self.refresh(); self.refreshPaletteResults(); self.onSpacesChanged?()
            self.save()
            if await writer.flushAsync(timeout: 30) {
                completion("Bam couldn’t save the imported layout, so the import was undone and nothing was added. Check free disk space and try again.")
            } else {
                completion("Bam couldn’t save to disk. The import was undone in this window, but Bam can’t confirm your tabs are saved — free up disk space before quitting.")
            }
        }
    }

    /// Drops a page view created for a tab that no longer exists.
    private func discardInstantiatedPage(_ id: UUID) {
        guard let web = browsers.removeValue(forKey: id) else { return }
        observations.removeValue(forKey: id)
        web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading()
        web.removeFromSuperview()
        tabLastUsed.removeValue(forKey: id); pendingLoads.remove(id); tabErrors.removeValue(forKey: id)
    }
}
