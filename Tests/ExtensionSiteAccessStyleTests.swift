import AppKit
import WebKit

/// The Site Access sheet themed exactly as App.swift themes it (BamSheetStyle, like the extension manager). Offscreen:
/// the window is never ordered front.
@main enum ExtensionSiteAccessStyleTests {
    static func main() {
        _ = NSApplication.shared
        guard #available(macOS 15.4, *) else { print("SKIP: needs macOS 15.4"); return }
        MainActor.assumeIsolated { run() }
    }

    @available(macOS 15.4, *) @MainActor static func run() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        typealias Panel = ExtensionSiteAccessPanel
        // Exactly App.swift's assignments.
        Panel.dress = { BamSheetStyle.dress(window: $0, root: $1) }
        Panel.restyle = { BamSheetStyle.restyle($0) }
        Panel.restyleCell = { $0.font = BamType.sans(12.5); $0.textColor = BamTheme.ink }
        Panel.rowView = { BamTableRowView() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        let declarations = ExtensionSiteAccess.Declarations(requested: ["https://*.docs.example/*", "*://mail.example/*"], optional: ["https://optional.example/*"])
        let snapshot = Panel.Snapshot(extensionID: UUID(), profileID: UUID(), revision: 1, extensionName: "Docs Helper", profileName: "Work",
                                      state: .specific(["https://api.docs.example/*"], optionalGrants: ["https://optional.example/*"]),
                                      declarations: declarations, oneTimeAccess: false, message: "A problem to show.")
        let panel = Panel(snapshot: snapshot)
        let content = panel.window!.contentView!
        content.layoutSubtreeIfNeeded(); panel.detailScroll.documentView?.layoutSubtreeIfNeeded()

        require(descendants(content).contains { $0 is BamSurfaceView } && panel.window?.titlebarAppearsTransparent == true,
                "The sheet has Bam's paper surface and transparent titlebar, like Manage Extensions")
        for button in [panel.doneButton, panel.addButton, panel.removeButton, panel.pendingButton] {
            require(!button.isBordered && (button.layer?.cornerRadius ?? 0) > 0 && (button.layer?.borderWidth ?? 0) > 0,
                    "\(button.title) is a Bam pill button, not a stock bezel")
        }
        require(panel.modeMenu.bezelStyle == .texturedRounded, "The mode menu uses the themed pop-up style")
        require(!panel.siteField.isBezeled && (panel.siteField.layer?.borderWidth ?? 0) > 0 && (panel.siteField.layer?.cornerRadius ?? 0) == 8,
                "The site field is Bam's rounded field")
        require(panel.subdomainsBox.isKind(of: NSSwitch.self) && !(panel.subdomainsBox.superview is NSButton), "Subdomains is a switch, untouched by pill styling")
        let siteListScroll = panel.sitesTable.enclosingScrollView!
        require((siteListScroll.layer?.cornerRadius ?? 0) == 14 && siteListScroll.borderType == .noBorder, "The site list is a Bam card")
        require((panel.detailScroll.layer?.cornerRadius ?? 0) == 0 && !(panel.detailScroll.superview?.subviews.contains { String(describing: type(of: $0)).contains("CardBacking") } ?? false),
                "The details region itself stays a plain scroll, not one big card")
        let heading = descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Site Access" }
        require(heading?.font == BamType.display(24, weight: .heavy), "The heading uses Bam's display type, as Manage Extensions does")
        require(panel.modeHelp.textColor == BamTheme.muted && panel.feedbackLabel.textColor == .systemRed,
                "Secondary text is Bam's muted ink; a problem stays red after theming")
        // Rows.
        let cell = panel.tableView(panel.sitesTable, viewFor: nil, row: 0) as? NSTextField
        require(cell?.font == BamType.sans(12.5) && cell?.textColor == BamTheme.ink && panel.tableView(panel.sitesTable, rowViewForRow: 0) is BamTableRowView,
                "Site rows use Bam's row view and cell type")
        // Themed layout still keeps every control inside the window and Done in the footer.
        let done = panel.doneButton.convert(panel.doneButton.bounds, to: content)
        require(content.bounds.contains(done), "Done stays inside the themed window: \(done)")
        for control in [panel.modeMenu, panel.siteField, panel.addButton] as [NSView] {
            let frame = control.convert(control.bounds, to: content)
            require(frame.width > 0 && frame.maxX <= content.bounds.maxX + 0.5 && frame.minX >= -0.5, "\(type(of: control)) fits the width: \(frame)")
        }
        print("PASS: \(checks) extension site access style checks")
    }
}
