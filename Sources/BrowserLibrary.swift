import AppKit

struct BrowserHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var visitedAt = Date()
    var title: String
    var address: String
}

struct ClosedRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var closedAt = Date()
    var tabs: [BrowserTab]
    var split: Bool
}

/// Metadata only. The caller chooses the file; nil keeps an ephemeral library.
/// No browser profiles, cookies, downloads, or account data are consulted.
@MainActor final class BrowserLibrary {
    private(set) var history: [BrowserHistoryEntry] = []
    private(set) var closedRecords: [ClosedRecord] = []
    private(set) var lastStorageError: String?
    var onOpenURL: ((String) -> Void)?
    var onRestoreClosed: ((ClosedRecord) -> Void)?
    var onStorageError: ((String) -> Void)?
    let storageURL: URL?
    private var loadFailure: String?
    private var historyWindow: BrowserLibraryWindowController?
    private var archiveWindow: BrowserLibraryWindowController?
    private static let historyLimit = 5_000
    private static let closedLimit = 200

    init(storageURL: URL?) { self.storageURL = storageURL; load() }

    func recordVisit(title: String, address: String) {
        guard let url = Self.webURL(address) else { return }
        let address = url.absoluteString
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = commit {
            if history.first?.address == address {
                // Only consecutive visits coalesce; earlier visits stay visible.
                history[0].title = title.isEmpty ? (url.host ?? address) : title
                history[0].visitedAt = Date()
            } else {
                history.insert(BrowserHistoryEntry(title: title.isEmpty ? (url.host ?? address) : title, address: address), at: 0)
                if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
            }
        }
    }

    func recordClosed(tabs: [BrowserTab], split: Bool) {
        let record = ClosedRecord(tabs: tabs, split: split)
        guard Self.validClosed(record) else { return }
        _ = commit {
            closedRecords.insert(record, at: 0)
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
    @discardableResult func clearHistory() -> Bool { commit { history.removeAll() } }
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
        historyWindow?.present(relativeTo: parent)
    }
    func showArchive(relativeTo parent: NSWindow?) {
        if archiveWindow == nil { archiveWindow = BrowserLibraryWindowController(library: self, mode: .archive) }
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
        if let loadFailure { lastStorageError = loadFailure; onStorageError?(loadFailure); return false }
        let oldHistory = history, oldClosed = closedRecords
        change()
        if let storageURL {
            do {
                try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(FileContents(history: history, closedRecords: closedRecords))
                try data.write(to: storageURL, options: .atomic)
            } catch {
                history = oldHistory; closedRecords = oldClosed
                lastStorageError = error.localizedDescription
                onStorageError?(error.localizedDescription)
                return false
            }
        }
        lastStorageError = nil
        historyWindow?.reload(); archiveWindow?.reload()
        return true
    }

    private func load() {
        guard let storageURL else { return }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["version"] as? Int ?? 1) == 1 else {
                let message = "The library file has an unsupported format and was left unchanged."
                lastStorageError = message; loadFailure = message
                return
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            func records<T: Decodable>(_ key: String, as type: T.Type) -> [T] {
                (root[key] as? [Any] ?? []).compactMap { item in
                    guard let object = item as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                    return try? decoder.decode(type, from: data)
                }
            }
            var historyIDs = Set<UUID>()
            history = Array(records("history", as: BrowserHistoryEntry.self).filter { entry in
                entry.visitedAt.timeIntervalSince1970.isFinite && Self.webURL(entry.address) != nil && historyIDs.insert(entry.id).inserted
            }.prefix(Self.historyLimit))
            var closedIDs = Set<UUID>()
            closedRecords = Array(records("closedRecords", as: ClosedRecord.self).filter { record in
                Self.validClosed(record) && closedIDs.insert(record.id).inserted
            }.prefix(Self.closedLimit))
        } catch {
            let message = "The library file could not be read and was left unchanged: " + error.localizedDescription
            lastStorageError = message; loadFailure = message
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
            (0...2).contains(tab.space) && (tab.address == "orbit://newtab" || tab.address == "orbit://video" || webURL(tab.address) != nil)
        }
    }
    private static func queryWords(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
    private static func matches(_ words: [String], text: String) -> Bool { words.allSatisfy { text.localizedCaseInsensitiveContains($0) } }
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
        window.title = mode == .history ? "History — Orbit" : "Recently Closed — Orbit"
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
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
            rows = library.searchClosed(search.stringValue).map { Row(id: $0.id, title: $0.tabs.map(\.title).joined(separator: "\n"), address: $0.tabs.map(\.address).joined(separator: "\n"), date: $0.closedAt) }
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
        alert.informativeText = mode == .history ? "Removes Orbit’s saved visit list. Cookies, downloaded files, and the closed-tab archive are kept." : "Removes the list of tabs available to reopen. Browsing history, open tabs, cookies, and downloaded files are kept."
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
