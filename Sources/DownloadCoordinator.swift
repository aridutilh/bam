import AppKit
import WebKit
import Darwin

/// Session-only native downloads. Nothing resumes after Orbit quits.
/// https://developer.apple.com/documentation/webkit/wkdownloaddelegate
@MainActor final class DownloadCoordinator: NSObject, WKDownloadDelegate, NSOpenSavePanelDelegate, NSPopoverDelegate {
    typealias Status = DownloadStatus
    typealias Snapshot = DownloadSnapshot
    typealias DestinationChooser = (String, URL?, @escaping (URL?) -> Void) -> Void
    var onChange: (() -> Void)?
    var snapshots: [Snapshot] { records.map(\.snapshot) }
    var activeCount: Int { records.filter { $0.isActive }.count }

    private var records: [DownloadRecord] = []
    private var active: [ObjectIdentifier: DownloadRecord] = [:]
    private let destinationChooser: DestinationChooser?
    private var destinationQueue: [UUID] = []
    private var panel: NSSavePanel?
    private var panelRecordID: UUID?
    private let thumbnails = DownloadThumbnails()
    private var popover: NSPopover?
    private var popoverList: DownloadsPopoverController?
    private var library: DownloadsLibraryWindowController?
    private var popoverClosedAt: TimeInterval?
    private var terminateObserver: NSObjectProtocol?

    /// The optional chooser is a test seam; ordinary callers receive NSSavePanel.
    init(destinationChooser: DestinationChooser? = nil) {
        self.destinationChooser = destinationChooser
        super.init()
        thumbnails.onUpdate = { [weak self] in self?.refreshSurfaces() }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        }
    }

    /// Call synchronously from either WKNavigationDelegate didBecome-download callback.
    func start(download: WKDownload, suggestedURL: URL? = nil) {
        let key = ObjectIdentifier(download)
        guard active[key] == nil else { return }
        let record = DownloadRecord(download: download, sourceURL: download.originalRequest?.url ?? suggestedURL)
        records.insert(record, at: 0)
        active[key] = record
        download.delegate = self
        let progress = download.progress
        for keyPath in [\Progress.completedUnitCount, \Progress.totalUnitCount] {
            record.observations.append(progress.observe(keyPath, options: [.new]) { [weak self, weak record] _, _ in
                DispatchQueue.main.async {
                    guard let self, let record, record.isActive else { return }
                    self.updateProgress(record)
                }
            })
        }
        changed()
    }

    /// ⌘J and the sidebar's Downloads button: the compact list, anchored to that button.
    func showWindow(relativeTo parent: NSWindow? = nil) { show(from: nil, in: parent) }

    /// Shows the compact list above `anchor`, or above the sidebar's Downloads button found in
    /// `parent`, or at the window's bottom-left. Without a visible window, opens the full library.
    func show(from anchor: NSView?, in parent: NSWindow?) {
        guard let window = anchor?.window ?? parent, window.isVisible, !window.isMiniaturized, let content = window.contentView else {
            showLibrary(relativeTo: parent); return
        }
        let clickTypes: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]
        let fromClick = NSApp.currentEvent.map { clickTypes.contains($0.type) } ?? false
        switch DownloadPresentation.toggle(isShown: popover?.isShown == true,
                                           secondsSinceClose: popoverClosedAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                                           fromClick: fromClick) {
        case .close: popover?.performClose(nil); return
        case .stayClosed: popoverClosedAt = nil; return
        case .open: break
        }
        let list = DownloadsPopoverController(actions: surfaceActions(), thumbnails: thumbnails)
        list.update(snapshots, now: Date())
        let surface = NSPopover()
        surface.behavior = .transient
        surface.animates = !BamTheme.reduceMotion
        surface.hasFullSizeContent = true
        surface.contentViewController = list
        surface.delegate = self
        surface.contentSize = list.preferredContentSize
        popover = surface; popoverList = list
        if let button = anchor ?? Self.sidebarDownloadsButton(in: content) {
            surface.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else {
            let y = content.isFlipped ? content.bounds.height - 40 : 12
            surface.show(relativeTo: NSRect(x: 14, y: y, width: 28, height: 28), of: content, preferredEdge: .maxY)
        }
    }

    /// Every download as a thumbnail grid in its own window.
    func showLibrary(relativeTo parent: NSWindow? = nil) {
        popover?.performClose(nil)
        let library = self.library ?? DownloadsLibraryWindowController(actions: surfaceActions(), thumbnails: thumbnails)
        self.library = library
        library.update(snapshots, now: Date())
        library.present(over: parent)
    }

    /// The sidebar's leading Downloads button, when it is on screen.
    static func sidebarDownloadsButton(in root: NSView) -> NSView? {
        if root.identifier?.rawValue == "sidebar-downloads", !root.isHiddenOrHasHiddenAncestor, !root.visibleRect.isEmpty { return root }
        for child in root.subviews { if let found = sidebarDownloadsButton(in: child) { return found } }
        return nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popoverClosedAt = ProcessInfo.processInfo.systemUptime
    }

    private func surfaceActions() -> DownloadActions {
        DownloadActions(cancel: { [weak self] in self?.cancel(id: $0) },
                        open: { [weak self] in self?.openFile(id: $0, reveal: false) },
                        reveal: { [weak self] in self?.openFile(id: $0, reveal: true) },
                        showAll: { [weak self] in
                            guard let self else { return }
                            let parent = self.popover?.contentViewController?.view.window?.parent ?? NSApp.mainWindow
                            self.showLibrary(relativeTo: parent)
                        })
    }

    func cancelAll() {
        for record in records where record.isActive { cancel(id: record.id) }
    }

    func cancel(id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.isActive else { return }
        record.status = .cancelled
        record.detail = "Cancelled"
        let decision = record.destinationDecision
        record.destinationDecision = nil
        destinationQueue.removeAll { $0 == id }
        if panelRecordID == id { panel?.cancel(nil) }
        decision?(nil)
        let download = record.download
        let staging = record.stagingURL
        // Unlink our uniquely named file now: application termination need not wait
        // for WebKit's cancellation callback. An open descriptor can finish closing
        // without leaving a named partial file in the destination folder.
        removeStagingFile(record)
        releaseDownload(record)
        download?.cancel { [weak self, weak record] _ in
            // A pending WebKit write may have created the path after cancellation.
            if let staging { try? FileManager.default.removeItem(at: staging) }
            if let self, let record { self.endSecurityScope(record) }
        }
        if download == nil { endSecurityScope(record) }
        changed()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let record = active[ObjectIdentifier(download)], record.isActive else { completionHandler(nil); return }
        record.filename = Self.safeFilename(suggestedFilename)
        record.destinationDecision = completionHandler
        record.detail = "Choose where to save"
        changed()
        if let destinationChooser {
            destinationChooser(record.filename, record.sourceURL) { [weak self, weak record] url in
                guard let self, let record else { return }
                self.acceptDestination(url, for: record)
            }
        } else {
            destinationQueue.append(record.id)
            presentNextSavePanel()
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let record = active[ObjectIdentifier(download)], record.isActive,
              let staging = record.stagingURL, let destination = record.destinationURL else { return }
        updateProgress(record)
        do {
            // Exclusive atomic rename: an intervening file can never be overwritten.
            try Self.finishFile(staging: staging, destination: destination)
            record.stagingURL = nil
            record.fileIdentity = DownloadFileIdentity.of(destination)
            record.status = .finished
            record.detail = "Finished"
            record.fraction = 1
        } catch {
            record.status = .failed
            record.detail = "Could not save: \(error.localizedDescription)"
            removeStagingFile(record)
        }
        releaseDownload(record)
        endSecurityScope(record)
        changed()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let record = active[ObjectIdentifier(download)], record.isActive else { return }
        record.status = .failed
        record.detail = error.localizedDescription
        let decision = record.destinationDecision
        record.destinationDecision = nil
        decision?(nil)
        destinationQueue.removeAll { $0 == record.id }
        if panelRecordID == record.id { panel?.cancel(nil) }
        removeStagingFile(record)
        releaseDownload(record)
        endSecurityScope(record)
        changed()
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        let scheme = request.url?.scheme?.lowercased()
        decisionHandler(scheme == "http" || scheme == "https" ? .allow : .cancel)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        _ = try validatedDestination(url)
    }

    private func acceptDestination(_ url: URL?, for record: DownloadRecord) {
        guard record.isActive, let decision = record.destinationDecision else { return }
        record.destinationDecision = nil
        guard let url else {
            record.status = .cancelled; record.detail = "Cancelled"
            decision(nil)
            releaseDownload(record)
            changed()
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { record.scopedURL = url }
        do {
            let destination = try validatedDestination(url)
            record.destinationURL = destination
            record.filename = destination.lastPathComponent
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".orbit-\(UUID().uuidString).download")
            record.stagingURL = staging
            record.status = .downloading
            record.detail = "Downloading…"
            decision(staging)
            updateProgress(record)
        } catch {
            record.status = .failed
            record.detail = error.localizedDescription
            decision(nil)
            releaseDownload(record)
            endSecurityScope(record)
        }
        changed()
    }

    private func validatedDestination(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw DownloadError("Choose a local file destination.") }
        let fileManager = FileManager.default
        let normalized = url.standardizedFileURL
        if fileManager.fileExists(atPath: normalized.path) || (try? fileManager.attributesOfItem(atPath: normalized.path)) != nil {
            throw DownloadError("A file already exists there. Choose a different name; Bam does not replace downloads.")
        }
        let parent = normalized.deletingLastPathComponent().resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              fileManager.isWritableFile(atPath: parent.path) else { throw DownloadError("The destination folder is unavailable or not writable.") }
        let canonical = parent.appendingPathComponent(normalized.lastPathComponent)
        guard !records.contains(where: { $0.isActive && $0.destinationURL == canonical }) else {
            throw DownloadError("Another download is already using that name. Choose a different name.")
        }
        return canonical
    }

    private func presentNextSavePanel() {
        guard panel == nil else { return }
        while !destinationQueue.isEmpty {
            let id = destinationQueue.removeFirst()
            guard let record = records.first(where: { $0.id == id }), record.isActive, record.destinationDecision != nil else { continue }
            let save = NSSavePanel()
            panel = save; panelRecordID = id
            save.title = "Save Download"
            save.prompt = "Save"
            save.message = "Choose a new filename. Existing files will not be replaced."
            save.nameFieldStringValue = record.filename
            save.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            save.canCreateDirectories = true
            save.isExtensionHidden = false
            save.delegate = self
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak record, weak save] response in
                guard let self else { return }
                self.panel = nil; self.panelRecordID = nil
                if let record { self.acceptDestination(response == .OK ? save?.url : nil, for: record) }
                self.presentNextSavePanel()
            }
            if let parent = record.download?.webView?.window, parent.isVisible, parent.attachedSheet == nil {
                save.beginSheetModal(for: parent, completionHandler: completion)
            } else {
                save.begin(completionHandler: completion)
            }
            return
        }
    }

    private func releaseDownload(_ record: DownloadRecord) {
        record.observations.removeAll()
        if let download = record.download {
            active.removeValue(forKey: ObjectIdentifier(download))
            download.delegate = nil
        }
        record.download = nil
    }
    private func endSecurityScope(_ record: DownloadRecord) {
        record.scopedURL?.stopAccessingSecurityScopedResource()
        record.scopedURL = nil
    }
    private func removeStagingFile(_ record: DownloadRecord) {
        if let staging = record.stagingURL { try? FileManager.default.removeItem(at: staging) }
        record.stagingURL = nil
    }
    private func updateProgress(_ record: DownloadRecord) {
        guard let progress = record.download?.progress else { return }
        record.completedBytes = max(0, progress.completedUnitCount)
        record.totalBytes = progress.totalUnitCount
        record.fraction = progress.totalUnitCount > 0 ? max(0, min(1, progress.fractionCompleted)) : nil
        if record.status == .downloading {
            let received = ByteCountFormatter.string(fromByteCount: record.completedBytes, countStyle: .file)
            if record.totalBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file)
                record.detail = "\(received) of \(total)"
            } else { record.detail = "\(received) downloaded" }
        }
        changed()
    }
    private func changed() { refreshSurfaces(); onChange?() }

    private func refreshSurfaces() {
        let items = snapshots, now = Date()
        if popover?.isShown == true, let popoverList {
            popoverList.update(items, now: now)
            popover?.contentSize = popoverList.preferredContentSize
        }
        if library?.window?.isVisible == true { library?.update(items, now: now) }
    }

    private func openFile(id: UUID, reveal: Bool) {
        guard let record = records.first(where: { $0.id == id }), record.status == .finished,
              let url = record.destinationURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            record.detail = "The downloaded file has moved or been removed."
            changed(); return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if !NSWorkspace.shared.open(url) { record.detail = "No application could open this file."; changed() }
    }

    static func safeFilename(_ suggested: String) -> String {
        let component = (suggested as NSString).lastPathComponent
        let clean = String(component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in clean {
            if result.utf8.count + String(character).utf8.count > 180 { break }
            result.append(character)
        }
        return result.isEmpty || result == "." || result == ".." ? "Download" : result
    }

    static func finishFile(staging: URL, destination: URL) throws {
        let result = staging.path.withCString { source in
            destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
        }
        if result != 0 {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }
}

@MainActor private final class DownloadRecord {
    let id = UUID()
    var download: WKDownload?
    let sourceURL: URL?
    var filename = "Download"
    var detail = "Preparing download…"
    var destinationURL: URL?
    var stagingURL: URL?
    var scopedURL: URL?
    var destinationDecision: ((URL?) -> Void)?
    var observations: [NSKeyValueObservation] = []
    var fraction: Double?
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = -1
    let startedAt = Date()
    var endedAt: Date?
    var fileIdentity: String?
    var status = DownloadCoordinator.Status.choosingDestination {
        didSet { if !isActive, endedAt == nil { endedAt = Date() } }
    }
    var isActive: Bool { status == .choosingDestination || status == .downloading }
    init(download: WKDownload, sourceURL: URL?) { self.download = download; self.sourceURL = sourceURL }
    var snapshot: DownloadCoordinator.Snapshot {
        .init(id: id, filename: filename, sourceURL: sourceURL, destinationURL: destinationURL,
              status: status, detail: detail, fractionCompleted: fraction, completedBytes: completedBytes, totalBytes: totalBytes,
              startedAt: startedAt, endedAt: endedAt, fileIdentity: fileIdentity)
    }
}

private struct DownloadError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
