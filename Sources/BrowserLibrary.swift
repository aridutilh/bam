import AppKit

struct BrowserHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var visitedAt = Date()
    var title: String
    var address: String
}

struct ClosedRecord: Codable, Identifiable, Equatable {
    /// How a tab reached the archive. Records saved before auto-archive have none (closed by hand).
    enum Reason: String, Codable { case closed, archived }
    var id = UUID()
    var closedAt = Date()
    var tabs: [BrowserTab]
    var split: Bool
    var reason: Reason? = nil
    var wasAutoArchived: Bool { reason == .archived }
}

/// Metadata only. The caller chooses the file; nil keeps an ephemeral library.
/// No browser profiles, cookies, downloads, or account data are consulted.
@MainActor final class BrowserLibrary {
    private(set) var history: [BrowserHistoryEntry] = [] { didSet { realTitles = nil } }
    /// Address → the latest real title history has for it (see `knownTitle(forAddress:)`), built on first use after a change.
    private var realTitles: [String: String]?
    private(set) var closedRecords: [ClosedRecord] = []
    private(set) var lastStorageError: String?
    var onOpenURL: ((String) -> Void)?
    var onRestoreClosed: ((ClosedRecord) -> Void)?
    var onStorageError: ((String) -> Void)?
    /// Any change to history or the archive, for windows other than the built-in ones.
    var onChange: (() -> Void)?
    /// A genuine change to in-memory history, for extension history events. Never sent at startup load.
    enum HistoryChange: Equatable {
        /// `recordVisit` accepted this visit (a new entry or a coalesced revisit, as it now stands). Sent even if
        /// the following asynchronous write later fails: it describes in-memory history, not durability.
        case visited(BrowserHistoryEntry)
        /// The same visit trimmed these entries past the history limit (their addresses, oldest last).
        case trimmed(addresses: [String])
        /// `clearHistory()` committed successfully. A failed clear rolls back and sends nothing.
        case cleared
    }
    var onHistoryChange: ((HistoryChange) -> Void)?
    /// One accepted visit exactly as recorded. A coalesced revisit reuses the entry's id but gets a new
    /// revision, so a token from an earlier visit of that entry no longer matches.
    struct VisitToken: Equatable {
        let id: UUID
        let address: String
        let revision: UInt64
    }
    /// In memory only (never stored): the revision of each entry's latest accepted visit this session.
    /// Entries loaded at startup have none, so no token can match them.
    private var visitRevisions: [UUID: UInt64] = [:]
    private var lastVisitRevision: UInt64 = 0
    var profileName: String?
    let storageURL: URL?
    private var loadFailure: String?
    private let writer: LibraryWriter?
    private var reportedFailureRevision: UInt64?
    private var historyWindow: BrowserLibraryWindowController?
    private var archiveWindow: BrowserLibraryWindowController?
    private static let historyLimit = 5_000
    /// Hand closes and auto-archive share this list; a large sidebar archiving at once must fit.
    static let closedLimit = 1_000

    init(storageURL: URL?, write: @escaping LibraryWriter.Write = { try LibraryWriter.writeFile($0, to: $1) }) {
        self.storageURL = storageURL
        writer = storageURL.map { LibraryWriter(url: $0, write: write) }
        load()
        writer?.setCompletionHandler { [weak self] result in
            Task { @MainActor [weak self] in self?.acceptCompletion(result) }
        }
    }

    var isLatestSnapshotSaved: Bool { writer?.isLatestSnapshotSaved ?? true }
    @discardableResult func flush(timeout: TimeInterval = 2) -> Bool {
        guard let writer else { return true }
        let target = writer.prepareFlush()
        let result = writer.wait(for: target, timeout: timeout)
        if let completion = writer.currentCompletion { acceptCompletion(completion) }
        return result
    }
    func flushAsync(timeout: TimeInterval = 2) async -> Bool {
        guard let writer else { return true }
        let target = writer.prepareFlush()
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: writer.wait(for: target, timeout: timeout))
            }
        }
        if let completion = writer.currentCompletion { acceptCompletion(completion) }
        return result
    }
    private var snapshot: LibrarySnapshot { LibrarySnapshot(history: history, closedRecords: closedRecords) }
    private func acceptCompletion(_ result: LibraryWriter.Completion) {
        // Queued callbacks cannot clear a newer error or report a superseded
        // failure. They never mutate history or roll back later user changes.
        guard writer?.currentRevision == result.revision else { return }
        if let error = result.error {
            lastStorageError = error.localizedDescription
            if reportedFailureRevision != result.revision {
                reportedFailureRevision = result.revision
                onStorageError?(error.localizedDescription)
            }
        } else { lastStorageError = nil; reportedFailureRevision = nil }
    }
    private func canMutate() -> Bool {
        guard let loadFailure else { return true }
        lastStorageError = loadFailure; onStorageError?(loadFailure); return false
    }
    private func reloadWindows() { historyWindow?.reload(); archiveWindow?.reload(); onChange?() }

    /// False for a private window's library: visits are never recorded, not even in memory.
    var recordsHistory = true
    /// The latest title history recorded for `address` that is a real title, not the address written out. One
    /// dictionary lookup per sidebar row; the index is rebuilt at most once per history change.
    func knownTitle(forAddress address: String) -> String? {
        if realTitles == nil {
            var index: [String: String] = [:]
            for entry in history where index[entry.address] == nil && !entry.title.isEmpty
                && !SidebarDisplayPolicy.looksLikeAddress(entry.title, address: entry.address) {
                index[entry.address] = entry.title
            }
            realTitles = index
        }
        return realTitles?[address]
    }

    @discardableResult func recordVisit(title: String, address: String) -> VisitToken? {
        guard recordsHistory, let url = Self.webURL(address) else { return nil }
        let address = url.absoluteString
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canMutate() else { return nil }
        var trimmed: [String] = []
        if history.first?.address == address {
            // Only consecutive visits coalesce; earlier visits stay visible.
            history[0].title = title.isEmpty ? (url.host ?? address) : title
            history[0].visitedAt = Date()
        } else {
            history.insert(BrowserHistoryEntry(title: title.isEmpty ? (url.host ?? address) : title, address: address), at: 0)
            if history.count > Self.historyLimit {
                trimmed = history[Self.historyLimit...].map(\.address)
                for entry in history[Self.historyLimit...] { visitRevisions.removeValue(forKey: entry.id) }
                history.removeLast(history.count - Self.historyLimit)
            }
        }
        // Encoding and disk replacement happen on the ordered worker. Keep an
        // accepted visit in memory if storage fails, and retry on a visit/flush.
        writer?.enqueue(snapshot)
        reloadWindows()
        // Accepted into in-memory history (as search sees it); the write's outcome is not implied.
        lastVisitRevision += 1
        visitRevisions[history[0].id] = lastVisitRevision
        let token = VisitToken(id: history[0].id, address: address, revision: lastVisitRevision)
        onHistoryChange?(.visited(history[0]))
        if !trimmed.isEmpty { onHistoryChange?(.trimmed(addresses: trimmed)) }
        return token
    }

    /// The recorded document's title arrived after its visit. Changes only that entry's title: same id,
    /// visitedAt and position; no event, no new visit. The save is the same ordered write a visit uses.
    /// False, with nothing changed or written, when the token is stale (a later coalesced revisit, a trim,
    /// a clear), the address differs, the title is empty or unchanged, or the library can't be changed.
    @discardableResult func updateVisitTitle(_ title: String, for token: VisitToken) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, visitRevisions[token.id] == token.revision,
              let index = history.firstIndex(where: { $0.id == token.id }), history[index].address == token.address,
              history[index].title != title, canMutate() else { return false }
        history[index].title = title
        writer?.enqueue(snapshot)
        reloadWindows()
        return true
    }

    func recordClosed(tabs: [BrowserTab], split: Bool, reason: ClosedRecord.Reason? = nil) {
        let record = ClosedRecord(tabs: tabs, split: split, reason: reason)
        guard Self.validClosed(record) else { return }
        _ = commit {
            closedRecords.insert(record, at: 0)
            if closedRecords.count > Self.closedLimit { closedRecords.removeLast(closedRecords.count - Self.closedLimit) }
        }
    }

    /// Whether the archive can hold these tabs (one, or a Split's two). Auto-archive leaves the rest open.
    static func canArchive(_ tabs: [BrowserTab]) -> Bool { validClosed(ClosedRecord(tabs: tabs, split: tabs.count == 2)) }

    /// Auto-archive's tabs (each one tab or a Split), oldest first, in one write. False when nothing could be
    /// saved (unreadable library, disk error, or an invalid group), so the caller keeps every tab open.
    func recordArchived(_ groups: [[BrowserTab]], at date: Date = Date()) -> Bool {
        let records = groups.map { ClosedRecord(closedAt: date, tabs: $0, split: $0.count == 2, reason: .archived) }
        guard !records.isEmpty, records.allSatisfy(Self.validClosed) else { return false }
        return commit {
            for record in records { closedRecords.insert(record, at: 0) }
            if closedRecords.count > Self.closedLimit { closedRecords.removeLast(closedRecords.count - Self.closedLimit) }
        }
    }

    func popClosed() -> ClosedRecord? {
        guard let first = closedRecords.first else { return nil }
        return takeClosed(id: first.id)
    }

    /// Shared by Reopen Closed Tab and the archive's selected-record action.
    func takeClosed(id: UUID) -> ClosedRecord? {
        guard let index = closedRecords.firstIndex(where: { $0.id == id }) else { return nil }
        let record = closedRecords[index]
        return commit { closedRecords.remove(at: index) } ? record : nil
    }

    // Low-level mutations; the native window's Clear buttons confirm first.
    @discardableResult func clearHistory() -> Bool {
        guard commit({ history.removeAll() }) else { return false }
        visitRevisions.removeAll()
        onHistoryChange?(.cleared)
        return true
    }
    @discardableResult func clearArchive() -> Bool { commit { closedRecords.removeAll() } }

    func searchHistory(_ query: String) -> [BrowserHistoryEntry] {
        let words = Self.queryWords(query)
        return history.filter { Self.matches(words, text: $0.title + " " + $0.address) }
    }
    func searchClosed(_ query: String) -> [ClosedRecord] {
        let words = Self.queryWords(query)
        return closedRecords.filter { Self.matches(words, text: $0.tabs.map { $0.title + " " + $0.address }.joined(separator: " ")) }
    }

    func showHistory(relativeTo parent: NSWindow?) {
        if historyWindow == nil { historyWindow = BrowserLibraryWindowController(library: self, mode: .history) }
        historyWindow?.window?.title = "History — \(profileName ?? "Bam")"
        historyWindow?.present(relativeTo: parent)
    }
    func showArchive(relativeTo parent: NSWindow?) {
        if archiveWindow == nil { archiveWindow = BrowserLibraryWindowController(library: self, mode: .archive) }
        archiveWindow?.window?.title = "Recently Closed — \(profileName ?? "Bam")"
        archiveWindow?.present(relativeTo: parent)
    }

    private struct FileContents: Codable {
        var version = 1
        var history: [BrowserHistoryEntry]
        var closedRecords: [ClosedRecord]
    }

    /// Writes a complete replacement atomically. Failed writes roll back the
    /// in-memory mutation so reopening/clearing cannot claim unpersisted success.
    private func commit(_ change: () -> Void) -> Bool {
        // A future/corrupt file must not be replaced by an empty older snapshot.
        guard canMutate() else { return false }
        let oldHistory = history, oldClosed = closedRecords
        change()
        if let writer {
            let result = writer.writeSynchronously(snapshot)
            if result.error != nil {
                history = oldHistory; closedRecords = oldClosed
                let restoredRevision = writer.stage(snapshot)
                acceptCompletion(LibraryWriter.Completion(revision: restoredRevision, error: result.error))
                return false
            }
        }
        lastStorageError = nil; reportedFailureRevision = nil
        reloadWindows()
        return true
    }

    private func load() {
        guard let storageURL else { return }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            // Our normal file can be decoded in one pass. Keep the per-record
            // salvage path for partially damaged compatible files below.
            if let contents = try? decoder.decode(FileContents.self, from: data), contents.version == 1 {
                acceptLoaded(history: contents.history, closedRecords: contents.closedRecords)
                return
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["version"] as? Int ?? 1) == 1 else {
                let message = "The library file has an unsupported format and was left unchanged."
                lastStorageError = message; loadFailure = message
                return
            }
            func records<T: Decodable>(_ key: String, as type: T.Type) -> [T] {
                (root[key] as? [Any] ?? []).compactMap { item in
                    guard let object = item as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                    return try? decoder.decode(type, from: data)
                }
            }
            acceptLoaded(history: records("history", as: BrowserHistoryEntry.self),
                         closedRecords: records("closedRecords", as: ClosedRecord.self))
        } catch {
            let message = "The library file could not be read and was left unchanged: " + error.localizedDescription
            lastStorageError = message; loadFailure = message
        }
    }

    private func acceptLoaded(history entries: [BrowserHistoryEntry], closedRecords records: [ClosedRecord]) {
        var historyIDs = Set<UUID>()
        history = []; visitRevisions.removeAll()
        for entry in entries {
            guard entry.visitedAt.timeIntervalSince1970.isFinite, Self.webURL(entry.address) != nil,
                  historyIDs.insert(entry.id).inserted else { continue }
            history.append(entry)
            if history.count == Self.historyLimit { break }
        }
        var closedIDs = Set<UUID>()
        closedRecords = []
        for record in records {
            guard Self.validClosed(record), closedIDs.insert(record.id).inserted else { continue }
            closedRecords.append(record)
            if closedRecords.count == Self.closedLimit { break }
        }
    }

    private static func webURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func validClosed(_ record: ClosedRecord) -> Bool {
        guard record.closedAt.timeIntervalSince1970.isFinite,
              record.tabs.count == (record.split ? 2 : 1),
              Set(record.tabs.map(\.id)).count == record.tabs.count else { return false }
        if record.split, record.tabs[0].space != record.tabs[1].space { return false }
        return record.tabs.allSatisfy { tab in
            tab.space >= 0 && (tab.address == "orbit://newtab" || tab.address == "orbit://video" || webURL(tab.address) != nil
                                || ArcEaselReference.isReference(tab.address))
        }
    }
    private static func queryWords(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
    private static func matches(_ words: [String], text: String) -> Bool { words.allSatisfy { text.localizedCaseInsensitiveContains($0) } }
}

extension BrowserLibrary {
    /// The app installs Bam's paper and pill styling here; this file also
    /// builds alone in its component suites, where the styling kit is absent.
    @MainActor static var dress: ((NSWindow?, NSView) -> Void)?
    @MainActor static var rowView: (() -> NSTableRowView)?
}

@MainActor private final class BrowserLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Mode { case history, archive }
    private struct Row {
        var id: UUID
        var title: String
        var address: String
        var date: Date
    }
    private weak var library: BrowserLibrary?
    private let mode: Mode
    private let search = NSSearchField()
    private let table = BrowserLibraryTableView()
    private let openButton = NSButton()
    private let clearButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private let formatter: DateFormatter = {
        let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .short; return value
    }()

    init(library: BrowserLibrary, mode: Mode) {
        self.library = library; self.mode = mode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = mode == .history ? "History — Bam" : "Recently Closed — Bam"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 360)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 540))
        window.contentView = root
        window.setContentSize(NSSize(width: 820, height: 540))
        search.placeholderString = mode == .history ? "Search history by title or address" : "Search closed tabs by title or address"
        search.setAccessibilityLabel(mode == .history ? "Search browsing history" : "Search recently closed tabs")
        search.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 38
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(openSelected)
        table.activate = { [weak self] in self?.openSelected() }
        table.setAccessibilityLabel(mode == .history ? "Browsing history" : "Recently closed tabs")
        for (id, title, width) in [("title", "Title", 230.0), ("address", "Address", 380.0), ("date", mode == .history ? "Visited" : "Closed", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = id == "date" ? 120 : 100
            table.addTableColumn(column)
        }
        scroll.documentView = table
        openButton.title = mode == .history ? "Open" : "Restore"
        openButton.bezelStyle = .rounded; openButton.target = self; openButton.action = #selector(openSelected)
        clearButton.title = mode == .history ? "Clear History…" : "Clear Archive…"
        clearButton.bezelStyle = .rounded; clearButton.target = self; clearButton.action = #selector(confirmClear)
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center; countLabel.lineBreakMode = .byTruncatingTail
        for item in [search, scroll, openButton, clearButton, countLabel] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), search.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), scroll.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -12),
            openButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), openButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16), openButton.widthAnchor.constraint(equalToConstant: 90),
            clearButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), clearButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 12), countLabel.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -12), countLabel.centerYAnchor.constraint(equalTo: openButton.centerYAnchor)
        ])
        BrowserLibrary.dress?(window, root)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { BrowserLibrary.rowView?() }

    func present(relativeTo parent: NSWindow?) {
        reload()
        if let window, !window.isVisible {
            if let parent {
                let frame = NSRect(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2, width: window.frame.width, height: window.frame.height)
                window.setFrame(window.constrainFrameRect(frame, to: parent.screen), display: false)
            } else { window.center() }
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(search)
    }

    func reload() {
        guard let library else { return }
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        if mode == .history {
            rows = library.searchHistory(search.stringValue).map { Row(id: $0.id, title: $0.title, address: $0.address, date: $0.visitedAt) }
        } else {
            // Display only: restore takes the stored record by id, with its addresses unchanged.
            rows = library.searchClosed(search.stringValue).map { Row(id: $0.id, title: $0.tabs.map(\.title).joined(separator: "\n"),
                address: $0.tabs.map { SidebarDisplayPolicy.readableAddress($0.address) }.joined(separator: "\n"), date: $0.closedAt) }
        }
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        let total = mode == .history ? library.history.count : library.closedRecords.count
        countLabel.stringValue = "\(rows.count) of \(total) · \(library.storageURL == nil ? "This session only" : "Stored on this Mac")"
        clearButton.isEnabled = total > 0
        openButton.isEnabled = rows.indices.contains(table.selectedRow)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView(); cell.identifier = identifier
            let field = NSTextField(labelWithString: ""); field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .systemFont(ofSize: identifier.rawValue == "address" ? 11 : 12)
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = mode == .archive && identifier.rawValue != "date" ? 2 : 1
            if identifier.rawValue == "address" || identifier.rawValue == "date" { field.textColor = .secondaryLabelColor }
            cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }()
        let value = rows[row]
        cell.textField?.stringValue = identifier.rawValue == "title" ? value.title : identifier.rawValue == "address" ? value.address : formatter.string(from: value.date)
        cell.toolTip = cell.textField?.stringValue
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { openButton.isEnabled = rows.indices.contains(table.selectedRow) }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        return false
    }
    @objc private func openSelected() {
        guard let library, rows.indices.contains(table.selectedRow) else { return }
        let row = rows[table.selectedRow]
        if mode == .history {
            guard let callback = library.onOpenURL else { return }
            window?.orderOut(nil); callback(row.address)
        } else {
            guard let callback = library.onRestoreClosed else { return }
            guard let record = library.takeClosed(id: row.id) else { showStorageError(); return }
            window?.orderOut(nil); callback(record)
        }
    }
    @objc private func confirmClear() {
        guard let window, let library else { return }
        let alert = NSAlert()
        alert.messageText = mode == .history ? "Clear browsing history?" : "Clear recently closed tabs?"
        alert.informativeText = mode == .history ? "Removes Bam’s saved visit list. Cookies, downloaded files, and the closed-tab archive are kept." : "Removes the list of tabs available to reopen. Browsing history, open tabs, cookies, and downloaded files are kept."
        alert.addButton(withTitle: mode == .history ? "Clear History" : "Clear Archive")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak library] response in
            guard response == .alertFirstButtonReturn, let self, let library else { return }
            let success = self.mode == .history ? library.clearHistory() : library.clearArchive()
            if !success { self.showStorageError() }
        }
    }
    private func showStorageError() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "The library could not be saved"
        alert.informativeText = library?.lastStorageError ?? "Please try again."
        alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }
}

@MainActor private final class BrowserLibraryTableView: NSTableView {
    var activate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activate?(); return }
        super.keyDown(with: event)
    }
}
