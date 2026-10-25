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
        func showsReference() -> Bool { browser.webHost.subviews.last is EaselReferenceView }
        func shownName() -> String? { (browser.webHost.subviews.last as? EaselReferenceView)?.shownName }
        func name(_ id: UUID) -> String? { browser.session.tabs.first { $0.id == id }?.displayTitle }

        browser.select(kept.id)
        try check(browser.browsers[kept.id] == nil && showsReference(), "Selecting an Easel shows the native reference view, no web view")
        browser.reload(nil)
        try check(browser.browsers[kept.id] == nil && browser.pendingLoads.isEmpty, "Reload on an Easel creates no renderer and requests nothing")
        let tabsBefore = browser.session.tabs.map(\.id)
        browser.splitWithNewPage(nil)
        try check(browser.session.tabs.map(\.id) == tabsBefore && browser.session.split(for: kept.id) == nil
                    && browser.session.activeID == kept.id && browser.browsers[kept.id] == nil && showsReference(),
                  "Split with New Page on an Easel has no side effects: no new tab, selection or renderer")

        // Navigating away installs the page as the visible host.
        browser.navigate(url.absoluteString)
        guard let page = browser.browsers[kept.id] else { throw Failure.assertion("Navigating from an Easel created no page") }
        try check(browser.webHost.subviews.last === page && !showsReference(), "The new page is the visible host, not hidden behind the reference view")
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
        try check(browser.webHost.subviews.last === extensionPage && !showsReference() && extensionPage !== page,
                  "navigatePane makes the new page the visible host with a fresh view")
        try await wait("page loaded via navigatePane") { !extensionPage.isLoading && extensionPage.url?.absoluteString == url.absoluteString }
        browser.updateMetadata(extensionPage)
        browser.resetSavedTab(kept.id)
        try check(browser.browsers[kept.id] == nil && extensionPage.superview == nil && showsReference()
                    && name(kept.id) == "Fixture Easel" && shownName() == "Fixture Easel",
                  "Reset after navigatePane retires that page and restores the named reference")

        // A Today Easel closes to the archive and reopens as itself.
        browser.select(today.id)
        try check(showsReference() && browser.browsers[today.id] == nil, "Today Easel shows the reference view")
        browser.close(today.id)
        try check(!browser.session.tabs.contains { $0.id == today.id }, "Closing a Today Easel removes the row")
        browser.reopenTab(nil)
        guard let reopened = browser.session.active else { throw Failure.assertion("Reopen selected nothing") }
        try check(reopened.address == today.address && reopened.displayTitle == "Today Easel" && browser.browsers[reopened.id] == nil && showsReference(),
                  "Reopen brings the Easel reference back without a page")
    }
}
