import AppKit
import Foundation

/// The extension manager shows a selected extension's full disclosure (static-rule warning first) in a scrollable,
/// accessible view, and marks affected rows. Records come from a temporary registry; nothing is loaded or shown.
@main @MainActor enum ExtensionManagementDisclosureTests {
    struct Failure: Error { let message: String }
    static func main() {
        guard #available(macOS 15.4, *) else { print("SKIP: Extension management requires macOS 15.4"); return }
        do { print("PASS: Extension management disclosure — \(try run()) checks") }
        catch { fputs("FAIL: Extension management disclosure: \((error as? Failure)?.message ?? "\(error)")\n", stderr); exit(1) }
    }
    @available(macOS 15.4, *)
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(message: message) }; checks += 1 }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bam-management-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID(), audited = UUID(), legacy = UUID()
        let audit = ExtensionStaticRuleAudit(format: ExtensionStaticRuleAudit.currentFormat, extensionVersion: "3.0",
            rulesets: (1...12).map { .init(id: "ruleset\($0)", enabledByDefault: $0 % 2 == 0, methodRules: $0, excludesAllTypesRules: 0) }, unreadable: ["broken"])
        let preparation = Array(repeating: "Prepared Bam's compatibility adapter for this package without changing extension scripts.", count: 6).joined(separator: " ")
        let records = [
            BrowserExtensionRecord(id: audited, profileID: profile, name: "Audited", version: "3.0", packageName: "package", compatibilityNote: preparation, staticRuleAudit: audit),
            BrowserExtensionRecord(id: legacy, profileID: profile, name: "Earlier install", version: "1.0", packageName: "package")]
        var registry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as! [[String: Any]]
        registry[1].removeValue(forKey: "staticRuleAudit")   // as written by a Bam without the audit
        try JSONSerialization.data(withJSONObject: registry).write(to: root.appendingPathComponent("registry.json"))

        let host = BrowserExtensions(storageURL: root)
        defer { host.shutdown() }
        try check(host.records.count == 2 && host.records.first { $0.id == legacy }?.staticRuleAudit == nil, "Registry records did not restore, or an older record gained an audit")
        let manager = ExtensionManagement(host: host)
        manager.load(profileID: profile)
        guard let row = manager.items(for: audited) else { throw Failure(message: "The audited extension is not listed") }
        manager.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        manager.refresh()
        let shown = manager.status.string, note = audit.note ?? "missing"
        try check(shown.hasPrefix(note) && shown.contains(preparation) && shown.range(of: note)!.lowerBound < shown.range(of: preparation)!.lowerBound,
                  "The details were incomplete or the static-rule warning was not first: \(shown.prefix(200))")
        manager.status.layoutManager?.ensureLayout(for: manager.status.textContainer!)
        let used = manager.status.layoutManager?.usedRect(for: manager.status.textContainer!).height ?? 0
        try check(manager.statusScroll.documentView === manager.status && manager.statusScroll.hasVerticalScroller &&
                  used > manager.statusScroll.contentSize.height && manager.status.frame.height >= used,
                  "Long details were not scrollable in full: text \(used) pt, visible \(manager.statusScroll.contentSize.height) pt, view \(manager.status.frame.height) pt")
        try check(!manager.status.isEditable && manager.status.isSelectable && manager.status.acceptsFirstResponder &&
                  manager.status.accessibilityLabel() == "Selected extension status and compatibility details",
                  "The details view is not read-only, selectable, focusable and labelled")
        // A persistent extension error (WebKit context errors arrive through setError) leads, and the full warning
        // still follows it in the same scrollable area.
        host.setError(NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture context error that stays until fixed."]), for: audited)
        manager.refresh()
        let withError = manager.status.string
        try check(withError.hasPrefix("Fixture context error that stays until fixed.") && withError.contains(note) && withError.contains(preparation),
                  "A persistent error hid the disclosure: \(withError.prefix(200))")
        // Refreshes keep the reader's place; a different text or selection starts at the top.
        func offset() -> CGFloat { manager.statusScroll.contentView.bounds.origin.y }
        func scrollDown() {
            manager.statusScroll.contentView.scroll(to: NSPoint(x: 0, y: 30)); manager.statusScroll.reflectScrolledClipView(manager.statusScroll.contentView)
        }
        scrollDown()
        let scrolled = offset()
        manager.refresh(); manager.refresh()
        try check(scrolled == 30 && offset() == 30 && manager.status.string == withError, "A refresh with unchanged details moved the scroll position: \(scrolled) → \(offset())")
        host.setError(NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "A different context error."]), for: audited)
        manager.refresh()
        try check(offset() == 0 && manager.status.string.hasPrefix("A different context error."), "Changed details did not start at the top: \(offset())")
        scrollDown()
        if let other = manager.items(for: legacy) { manager.table.selectRowIndexes(IndexSet(integer: other), byExtendingSelection: false) }
        manager.refresh()
        try check(offset() == 0, "A different selection kept the previous scroll position: \(offset())")
        func rowText(_ id: UUID) -> String {
            guard let index = manager.items(for: id), let cell = manager.tableView(manager.table, viewFor: nil, row: index),
                  let label = cell.subviews.first as? NSTextField else { return "" }
            return label.accessibilityLabel() ?? ""
        }
        try check(rowText(audited).contains("Network rules: see details") && !rowText(legacy).contains("Network rules"),
                  "The row marker was missing for the audited install or shown for the earlier one: \(rowText(audited)) | \(rowText(legacy))")
        // A capability Bam now provides for a declared permission, never reviewed: listed as not granted, first.
        var earlier = BrowserExtensionRecord(id: UUID(), profileID: profile, name: "Earlier", version: "1", packageName: "package")
        earlier.compatibility = ["bookmarks", "history", "idle"]; earlier.compatibilityGrants = ["idle": .distantFuture, "history": .distantPast]
        let earlierDetails = ExtensionManagement.details(earlier) ?? ""
        try check(earlierDetails.hasPrefix("Not granted: bookmarks (read-only") && earlierDetails.contains("history (read-only: search this profile's history") &&
                  !earlierDetails.contains("idle") && earlierDetails.contains("Disable and enable the extension to review"),
                  "An ungranted bookmarks capability was not disclosed, or a granted one was listed: \(earlierDetails)")
        earlier.compatibilityGrants?["bookmarks"] = .distantFuture; earlier.compatibilityGrants?["history"] = .distantFuture
        try check(ExtensionManagement.details(earlier) == nil, "A fully granted install still showed a not-granted note")
        // The tabs permission, in plain words: addresses and titles, not page content. Names and grants are unchanged.
        let tabsReview = BrowserExtensionPermissionReview(name: "Tab Helper", profileName: "Work", permissions: ["storage", "tabs"], websites: [],
                                                          unsupported: [], isOptional: false)
        let reviewText = ExtensionManagement.reviewDetails(tabsReview)
        try check(reviewText.contains("Browser capabilities:\nstorage, tabs\n" + ExtensionManagement.tabsDisclosure)
                  && ExtensionManagement.tabsDisclosure.contains("addresses and titles") && ExtensionManagement.tabsDisclosure.contains("alone doesn’t let it read or change"),
                  "The review lists tabs, then explains it sees addresses and titles but not page content: \(reviewText)")
        let plainReview = BrowserExtensionPermissionReview(name: "Store", profileName: "Work", permissions: ["storage"], websites: ["https://a.example/*"],
                                                           unsupported: [], isOptional: true)
        try check(!ExtensionManagement.reviewDetails(plainReview).contains("Tabs:") && ExtensionManagement.reviewDetails(plainReview).contains("Websites:\nhttps://a.example/*"),
                  "Without tabs there is no tabs note, and the rest of the review is as before")
        earlier.permissions["tabs"] = .distantFuture
        try check(ExtensionManagement.details(earlier)?.contains(ExtensionManagement.tabsDisclosure) == true, "A granted tabs permission is explained in the details")
        earlier.permissions["tabs"] = .distantPast
        try check(ExtensionManagement.details(earlier) == nil, "An expired tabs grant isn't described as held")
        return checks
    }
}
