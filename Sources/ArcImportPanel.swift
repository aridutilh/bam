import AppKit

/// File > Import from Arc…: choose Arc's layout file, preview exactly what
/// will be added, then commit once. Nothing changes until Import is pressed.
@MainActor extension BrowserController {
    /// File ▸ Import from Arc… previews Arc's own layout file when it exists.
    @objc func importFromArc(_ sender: Any?) {
        presentArcImport(initialSourceURL: ArcImport.defaultSourceURL())
    }

    /// Opens the import sheet with the real preview/commit/dismiss callbacks.
    /// `initialSourceURL` is read only if readable; nil opens it empty, so a
    /// fixture can `load(_:)` a synthetic file without touching personal data.
    @discardableResult func presentArcImport(initialSourceURL: URL?) -> ArcImportController? {
        guard !isShuttingDown, !suspendsChromeInteraction, arcImporter == nil,
              let window = view.window, window.attachedSheet == nil else { return nil }
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
        if let source = initialSourceURL, FileManager.default.isReadableFile(atPath: source.path) { importer.load(source) }
        return importer
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
        importedTabIDsCache = nil  // Provenance changed; don't rely on its count.
        // Exactly one blank landing tab, so nothing imported is instantiated on arrival.
        if let first = report.firstSpaceID { ArcImport.arrive(at: first, in: &session) }
        let imported = session
        showActive(); refreshPaletteResults(); onSpacesChanged?()
        let tabs = report.importedTabs
        // Captured now: the site and profile each tab was imported with.
        let iconJobs = ArcIconImport.jobs(for: ArcIconImport.addedTabs(before: previous.importLinks, after: imported.importLinks), in: imported)
        let succeed = { [weak self] in
            self?.pageFeedback.show("Imported \(tabs) tab\(tabs == 1 ? "" : "s") from Arc", symbol: "square.and.arrow.down", in: self?.webHost ?? NSView())
            completion(nil)
            // Only after the layout is safely saved: never for previews, cancels or undone imports.
            self?.importArcIcons(iconJobs, layout: source.sourceURL)
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
            self.importedTabIDsCache = nil
            for id in addedIDs { self.teardownPage(id) }
            self.showActive(); self.refresh(); self.refreshPaletteResults(); self.onSpacesChanged?()
            self.save()
            if await writer.flushAsync(timeout: 30) {
                completion("Bam couldn’t save the imported layout, so the import was undone and nothing was added. Check free disk space and try again.")
            } else {
                completion("Bam couldn’t save to disk. The import was undone in this window, but Bam can’t confirm your tabs are saved — free up disk space before quitting.")
            }
        }
    }

    /// Best-effort: reads Arc's cached icons for the tabs this import added,
    /// off the main thread, then shows them in place and keeps a bounded copy
    /// in Bam's support folder (not for disposable sessions). No network, no
    /// page. Missing or invalid icons leave the normal fallback.
    func importArcIcons(_ jobs: [ArcIconImport.IconJob], layout: URL?) {
        guard !jobs.isEmpty, !isShuttingDown, let layout, let directory = ArcIconImport.cacheDirectory(besideLayout: layout) else { return }
        // Successive imports queue behind each other; none cancels another's icons.
        arcIconQueue.onDecoded = { [weak self] jobs, icons in self?.installImportedIcons(jobs, icons) }
        arcIconQueue.enqueue(jobs, directory: directory)
    }
    private func installImportedIcons(_ jobs: [ArcIconImport.IconJob], _ icons: [UUID: CGImage]) {
        guard !isShuttingDown, !icons.isEmpty else { return }
        var persist: [(tab: UUID, profile: UUID, origin: String, image: CGImage)] = []
        for job in jobs {
            // Revalidate against the session now; use the captured site and
            // profile, never the tab's address at completion time.
            guard let image = icons[job.tabID], ArcIconImport.stillValid(job, in: session) else { continue }
            importedTabIcons.install(image, for: job.tabID, origin: job.origin, profile: job.profile)
            persist.append((job.tabID, job.profile, job.origin, image))
        }
        sidebar.refreshFavicons(); tabSearchResults?.refreshFavicons()
        if let disk = importedIconDisk, !persist.isEmpty { importedIconQueue.async { disk.save(persist) } }
    }

    /// At launch: shows imported icons saved earlier for tabs that still exist
    /// in the same login profile; the cache prunes everything else.
    func restoreImportedIcons() {
        guard let disk = importedIconDisk else { return }
        let valid = Dictionary(session.tabs.map { ($0.id, session.profileID(for: $0)) }, uniquingKeysWith: { first, _ in first })
        importedIconQueue.async { [weak self] in
            let restored = disk.restore(validTabs: valid)
            guard !restored.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, !self.isShuttingDown else { return }
                for item in restored { self.importedTabIcons.install(item.image, for: item.tab, origin: item.origin, profile: item.profile) }
                self.sidebar.refreshFavicons(); self.tabSearchResults?.refreshFavicons()
            }
        }
    }
}
