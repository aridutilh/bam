import AppKit
import WebKit

@MainActor extension FeatureSmokeTest {
    /// Arc Easel reference rows through real controller paths, in a private
    /// session: no web view until the user navigates away; reset retires that
    /// page; Split and reload never create one; a closed Today Easel reopens.
    func runEaselReferences() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"] ?? ProcessInfo.processInfo.environment["ARK_TEST_URL"] ?? ProcessInfo.processInfo.environment["ORBIT_TEST_URL"],
              let url = URLInput.directURL(raw) else { throw Failure.assertion("Easel references require the local fixture URL") }
        let reference = ArcEaselReference.address(for: UUID())
        // Shaped as ArcImport makes it: the name is also the kept row's label.
        let kept = BrowserTab(title: "Fixture Easel", address: reference, space: 0,
                              saved: SavedTabState(kind: .kept, address: reference, customTitle: "Fixture Easel", isUnloaded: true))
        let today = BrowserTab(title: "Today Easel", address: ArcEaselReference.address(for: UUID()), space: 0)
        let home = BrowserTab(title: "Home", address: "orbit://newtab", space: 0)
        let browser = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/bam-unused-easel.json"), ephemeral: true)
        browser.automaticallyShowsVideo = false
        browser.session = BrowserSession(tabs: [kept, today, home], activeID: home.id)
        let fixtureWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        fixtureWindow.isReleasedWhenClosed = false; fixtureWindow.title = "Bam Easel fixture"
        fixtureWindow.contentViewController = browser
        defer { browser.prepareToClose(); fixtureWindow.close() }
        try await establishKeyWindow(fixtureWindow, label: "Easel browser")
        // Transient page feedback (a toast added above everything in webHost, e.g. the Split
        // refusal) is not the page: the content host is the topmost other attached subview.
        func contentHost() -> NSView? { browser.webHost.subviews.last { $0 !== browser.pageFeedback.view } }
        func hostDescription() -> String {
            let top = browser.webHost.subviews.last
            return "content \(contentHost().map { String(describing: type(of: $0)) } ?? "none"), top \(top === browser.pageFeedback.view ? "feedback" : top.map { String(describing: type(of: $0)) } ?? "none")"
        }
        func showsReference() -> Bool { contentHost() is EaselReferenceView }
        func shownName() -> String? { (contentHost() as? EaselReferenceView)?.shownName }
        func name(_ id: UUID) -> String? { browser.session.tabs.first { $0.id == id }?.displayTitle }
        /// The extension host's own tab callbacks (tabs.update → navigateTab, tabs.reload →
        /// reloadTab) on this private controller, aimed at an Easel row: each is refused, and
        /// the row, the visible view, renderers and pending loads are all unchanged.
        func extensionCallbacksRefused(_ id: UUID, _ label: String) throws {
            guard #available(macOS 15.4, *) else { return }
            let host = browser.browserExtensions
            let row = browser.session.tabs.first { $0.id == id }
            let active = browser.session.activeID, visible = contentHost(), shown = shownName()
            let renderers = Set(browser.browsers.keys), pending = browser.pendingLoads
            let navigated = host.navigateTab?(id, url) ?? true
            let reloaded = host.reloadTab?(id, false) ?? true
            let reloadedFromOrigin = host.reloadTab?(id, true) ?? true
            try check(row?.isArcEasel == true && !navigated && !reloaded && !reloadedFromOrigin,
                      "\(label): the extension host's navigateTab and reloadTab are refused")
            let after = browser.session.tabs.first { $0.id == id }
            try check(after?.address == row?.address && after?.title == row?.title && after?.displayTitle == row?.displayTitle && after?.saved == row?.saved,
                      "\(label): the row keeps its reference address and name")
            try check(browser.session.activeID == active && contentHost() === visible && shownName() == shown,
                      "\(label): the visible view is unchanged (\(hostDescription()))")
            try check(browser.browsers[id] == nil && Set(browser.browsers.keys) == renderers && browser.observations[id] == nil
                        && !browser.pendingLoads.contains(id) && browser.pendingLoads.isSubset(of: pending),
                      "\(label): no renderer, pending load or observation is created")
        }

        browser.select(kept.id)
        try check(browser.browsers[kept.id] == nil && showsReference(), "Selecting an Easel shows the native reference view, no web view")
        // The initially active home tab's own first load can still be pending here (it waits
        // for extension readiness), so compare against a snapshot rather than an empty set:
        // reload must add no pending load anywhere and no renderer at all.
        let rendererIDs = Set(browser.browsers.keys), pendingBefore = browser.pendingLoads
        browser.reload(nil)
        try check(browser.browsers[kept.id] == nil && !browser.pendingLoads.contains(kept.id)
                    && browser.pendingLoads.isSubset(of: pendingBefore) && Set(browser.browsers.keys) == rendererIDs,
                  "Reload on an Easel creates no renderer and requests nothing")
        let tabsBefore = browser.session.tabs.map(\.id), renderersBeforeSplit = Set(browser.browsers.keys)
        browser.splitWithNewPage(nil)
        let tabsAfter = browser.session.tabs.map(\.id)
        try check(tabsAfter == tabsBefore, "Split with New Page on an Easel adds no tab (\(tabsBefore.count) → \(tabsAfter.count))")
        try check(browser.session.split(for: kept.id) == nil && browser.session.activeID == kept.id,
                  "Split with New Page on an Easel makes no Split and keeps the selection (active is Easel: \(browser.session.activeID == kept.id))")
        try check(browser.browsers[kept.id] == nil && Set(browser.browsers.keys) == renderersBeforeSplit,
                  "Split with New Page on an Easel creates no renderer (\(renderersBeforeSplit.count) → \(browser.browsers.count))")
        try check(showsReference() && shownName() == "Fixture Easel" && contentHost()?.isHidden == false,
                  "The Easel's reference view stays attached and visible beneath any feedback (\(hostDescription()))")
        try check(browser.pageFeedback.view.superview === browser.webHost && !browser.pageFeedback.view.isHidden
                    && browser.pageFeedback.message == "Easels can’t be in a Split",
                  "The refusal is explained with transient feedback (\(browser.pageFeedback.message ?? "none"); \(hostDescription()))")
        try extensionCallbacksRefused(kept.id, "Active kept Easel")

        // Navigating away installs the page as the visible host.
        browser.navigate(url.absoluteString)
        guard let page = browser.browsers[kept.id] else { throw Failure.assertion("Navigating from an Easel created no page") }
        try check(contentHost() === page && !showsReference(),
                  "The new page is the visible host, not hidden behind the reference view (\(hostDescription()))")
        try await wait("page loaded after leaving the Easel") { !page.isLoading && page.url?.absoluteString == url.absoluteString }
        browser.updateMetadata(page)
        try check(browser.session.tabs.first { $0.id == kept.id }?.title == "Orbit Feature Fixture" && name(kept.id) == "Fixture Easel",
                  "The page's own title does not replace the Easel's name on its kept row")
        // Resetting the kept row returns to the reference and retires the page.
        browser.resetSavedTab(kept.id)
        try check(browser.session.tabs.first { $0.id == kept.id }?.address == reference, "Reset returns the row to its Easel reference")
        try check(browser.browsers[kept.id] == nil && browser.observations[kept.id] == nil && page.navigationDelegate == nil
                    && page.superview == nil && showsReference(),
                  "Reset retires the cached page and shows the reference view again")
        try check(name(kept.id) == "Fixture Easel" && shownName() == "Fixture Easel", "After reset the row and the view show the Easel's name")

        // The extension path (tabs.update → navigatePane) also shows its page.
        browser.navigatePane(kept.id, address: url.absoluteString)
        guard let extensionPage = browser.browsers[kept.id] else { throw Failure.assertion("navigatePane from an Easel created no page") }
        try check(contentHost() === extensionPage && !showsReference() && extensionPage !== page,
                  "navigatePane makes the new page the visible host with a fresh view (\(hostDescription()))")
        try await wait("page loaded via navigatePane") { !extensionPage.isLoading && extensionPage.url?.absoluteString == url.absoluteString }
        browser.updateMetadata(extensionPage)
        browser.resetSavedTab(kept.id)
        try check(browser.browsers[kept.id] == nil && extensionPage.superview == nil && showsReference()
                    && name(kept.id) == "Fixture Easel" && shownName() == "Fixture Easel",
                  "Reset after navigatePane retires that page and restores the named reference")
        try extensionCallbacksRefused(kept.id, "Kept Easel after reset")

        // A Today Easel closes to the archive and reopens as itself.
        browser.select(today.id)
        try check(showsReference() && browser.browsers[today.id] == nil, "Today Easel shows the reference view")
        try extensionCallbacksRefused(today.id, "Active Today Easel")
        try extensionCallbacksRefused(kept.id, "Inactive kept Easel")
        browser.close(today.id)
        try check(!browser.session.tabs.contains { $0.id == today.id }, "Closing a Today Easel removes the row")
        browser.reopenTab(nil)
        guard let reopened = browser.session.active else { throw Failure.assertion("Reopen selected nothing") }
        try check(reopened.address == today.address && reopened.displayTitle == "Today Easel" && browser.browsers[reopened.id] == nil && showsReference(),
                  "Reopen brings the Easel reference back without a page")
        try extensionCallbacksRefused(reopened.id, "Reopened Today Easel")

        // Control: the same callback loads an ordinary tab that has no page yet, so the refusals
        // above come from the Easel guard rather than an unwired callback.
        if #available(macOS 15.4, *) {
            let host = browser.browserExtensions
            let control = BrowserTab(title: "Control", address: url.absoluteString, space: 0)
            browser.session.tabs.append(control)
            try check(browser.browsers[control.id] == nil && host.reloadTab?(control.id, false) == true && browser.browsers[control.id] != nil,
                      "Control: the extension host's reloadTab creates and reloads a page for an ordinary tab")
        }
    }
}
