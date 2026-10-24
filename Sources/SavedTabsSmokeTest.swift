import AppKit
import WebKit

@MainActor extension FeatureSmokeTest {
    /// Real menu/sheet/controller paths in a private session. Local fixture pages
    /// and the bundled original demo clip never read the normal browser profile.
    func runSavedTabs() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BAM_TEST_URL"] ?? ProcessInfo.processInfo.environment["ARK_TEST_URL"] ?? ProcessInfo.processInfo.environment["ORBIT_TEST_URL"],
              let url = URLInput.directURL(raw) else { throw Failure.assertion("Saved tabs require the local fixture URL") }
        let beforeChecks = checks
        let first = BrowserTab(title: "Saved fixture", address: url.absoluteString, space: 0)
        let homes = (0..<3).map { BrowserTab(title: "Home \($0)", address: "orbit://newtab", space: $0) }
        let browser = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/bam-unused-saved-tabs.json"), ephemeral: true)
        browser.automaticallyShowsVideo = false
        browser.session = BrowserSession(tabs: [first] + homes, activeID: first.id)
        let fixtureWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        fixtureWindow.isReleasedWhenClosed = false; fixtureWindow.title = "Bam saved tabs fixture"
        fixtureWindow.contentViewController = browser
        fixtureWindow.setContentSize(NSSize(width: 1120, height: 720))
        defer { browser.prepareToClose(); fixtureWindow.close() }
        try await establishKeyWindow(fixtureWindow, label: "saved tabs browser")
        guard let original = browser.activeWebView else { throw Failure.assertion("Saved tab initial page missing") }
        try await wait("saved tab fixture loaded") { !original.isLoading && original.title == "Orbit Feature Fixture" }
        _ = try await js(original, "window.__bamSavedTabSentinel=41; true")

        @MainActor func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        @MainActor func tab(_ id: UUID) throws -> BrowserTab {
            guard let result = browser.session.tabs.first(where: { $0.id == id }) else { throw Failure.assertion("Saved tab identity disappeared: \(id)") }
            return result
        }
        @MainActor func sidebarView(_ id: UUID, favorite: Bool = false) throws -> NSView {
            browser.view.layoutSubtreeIfNeeded()
            let identifier = "\(favorite ? "favorite" : "tab-row")-\(id.uuidString)"
            guard let result = descendants(browser.sidebar).first(where: { $0.identifier?.rawValue == identifier }) else {
                throw Failure.assertion("Missing actual sidebar item: \(identifier)")
            }
            return result
        }
        @MainActor func menuItem(_ title: String, id: UUID, favorite: Bool = false) throws -> NSMenuItem {
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: fixtureWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
                  let item = try sidebarView(id, favorite: favorite).menu(for: event)?.items.first(where: { $0.title == title }) else {
                throw Failure.assertion("Missing saved tab context action: \(title)")
            }
            return item
        }
        @MainActor func invoke(_ title: String, id: UUID, favorite: Bool = false) throws {
            let item = try menuItem(title, id: id, favorite: favorite)
            guard item.isEnabled, let action = item.action else { throw Failure.assertion("Disabled saved tab context action: \(title)") }
            try check(NSApp.sendAction(action, to: item.target, from: item), "Native saved tab action did not dispatch: \(title)")
        }
        @MainActor func editorButton(_ title: String, in editor: SavedTabEditorController) throws -> NSButton {
            guard let content = editor.window?.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw Failure.assertion("Missing saved editor native button: \(title)")
            }
            return button
        }
        @MainActor func waitJS(_ label: String, web: WKWebView, source: String) async throws {
            for _ in 0..<100 {
                if (try await js(web, source)) as? Bool == true { checks += 1; return }
                await pause()
            }
            throw Failure.assertion("Timed out: \(label)")
        }

        try invoke("Keep Tab", id: first.id)
        try check(try tab(first.id).saved?.address == url.absoluteString && tab(first.id).saved?.kind == .kept,
                  "Keep Tab failed to capture the original destination")
        let originalDocumentRetained = (try await js(original, "window.__bamSavedTabSentinel===41")) as? Bool == true
        try check(browser.browsers[first.id] === original && originalDocumentRetained,
                  "Keeping a tab replaced or reloaded its live page")
        try invoke("Edit Saved Tab…", id: first.id)
        try await wait("saved tab editor attached") { browser.savedTabEditor?.window === fixtureWindow.attachedSheet }
        guard let cancelled = browser.savedTabEditor else { throw Failure.assertion("Saved editor missing") }
        cancelled.nameField.stringValue = "Discard this label"
        try editorButton("Cancel", in: cancelled).performClick(nil)
        try await wait("saved tab editor cancelled") { browser.savedTabEditor == nil && fixtureWindow.attachedSheet == nil }
        try check(try tab(first.id).saved?.customTitle == nil && tab(first.id).saved?.address == url.absoluteString,
                  "Cancel changed the saved label or destination")
        try invoke("Edit Saved Tab…", id: first.id)
        try await wait("saved tab editor reopened") { browser.savedTabEditor?.window === fixtureWindow.attachedSheet }
        guard let editor = browser.savedTabEditor, let symbolIndex = BrowserSpace.symbols.firstIndex(of: "book") else {
            throw Failure.assertion("Saved editor icon fixture unavailable")
        }
        editor.nameField.stringValue = "Kept research"; editor.iconPicker.selectItem(at: symbolIndex + 1)
        try editorButton("Save Changes", in: editor).performClick(nil)
        try await wait("saved tab editor saved") { browser.savedTabEditor == nil && fixtureWindow.attachedSheet == nil }
        try check(try tab(first.id).displayTitle == "Kept research" && tab(first.id).symbol == "book",
                  "Saving the native editor lost its custom title or icon")
        let navigated = try await js(original, "history.pushState(null,'','?bam_saved_navigation=1'); document.title='Live destination'; location.href") as! String
        browser.updateMetadata(original)
        try check(try tab(first.id).address == navigated && tab(first.id).saved?.address == url.absoluteString
                    && tab(first.id).displayTitle == "Kept research", "Live metadata replaced the saved URL or custom label")
        let archiveCount = browser.library.closedRecords.count
        try invoke("Unload Tab", id: first.id)
        try check(try tab(first.id).isUnloaded && tab(first.id).address == url.absoluteString && browser.session.activeID != first.id,
                  "Unload did not retain/reset the kept identity and select another awake page")
        try check(browser.browsers[first.id] == nil && browser.observations[first.id] == nil
                    && original.navigationDelegate == nil && original.uiDelegate == nil
                    && !browser.pendingLoads.contains(first.id) && browser.requestedAddresses[first.id] == nil,
                  "Unload retained the old WebKit view, callbacks or load state")
        browser.updateMetadata(original)
        try check(try tab(first.id).address == url.absoluteString && browser.library.closedRecords.count == archiveCount,
                  "A stale view changed the sleeping tab or unloading added an archive duplicate")
        let countBeforeReopen = browser.session.tabs.count
        browser.openAddress(newTab: true, empty: true)
        browser.addressField?.stringValue = "Kept research"; browser.refreshPaletteResults()
        browser.tabSearchResults?.moveSelection(delta: 1); browser.submitAddress(nil)
        guard let reopened = browser.browsers[first.id] else { throw Failure.assertion("Search did not reopen the saved identity") }
        try check(browser.session.activeID == first.id && browser.session.tabs.count == countBeforeReopen && reopened !== original,
                  "Search reopening duplicated the tab or reused its unloaded WebKit view")
        try await wait("saved original page reopened") { !reopened.isLoading && !browser.pendingLoads.contains(first.id) && reopened.url?.absoluteString == url.absoluteString }
        try check(try !tab(first.id).isUnloaded && tab(first.id).displayTitle == "Kept research" && tab(first.id).symbol == "book",
                  "Search wake lost saved metadata")
        try check((try await js(reopened, "typeof window.__bamSavedTabSentinel==='undefined'")) as? Bool == true,
                  "Unloading failed to discard the previous document")
        _ = try await js(reopened, "window.__bamSavedTabSentinel=77; history.pushState(null,'','?bam_saved_reset=1'); true")
        browser.updateMetadata(reopened)
        try invoke("Reset to Saved Page", id: first.id)
        try await wait("saved page reset settled") { !reopened.isLoading && !browser.pendingLoads.contains(first.id) && reopened.url?.absoluteString == url.absoluteString }
        let resetDocumentFresh = (try await js(reopened, "typeof window.__bamSavedTabSentinel==='undefined'")) as? Bool == true
        try check(browser.browsers[first.id] === reopened && resetDocumentFresh,
                  "Reset failed to navigate the existing view to a fresh saved document")
        try check(try tab(first.id).displayTitle == "Kept research" && tab(first.id).saved?.address == url.absoluteString,
                  "Reset discarded the custom title or original destination")

        try invoke("Add to Favorites", id: first.id)
        try check(try tab(first.id).isFavorite && browser.session.favoriteTabs.map(\.id) == [first.id],
                  "Native Favorite action failed to retain the existing saved identity")
        browser.changeSpace(2); browser.cancelPaging(); browser.view.layoutSubtreeIfNeeded()
        let allViews = descendants(browser.sidebar)
        try check(allViews.filter { $0.identifier?.rawValue == "favorite-\(first.id.uuidString)" }.count == 1
                    && !allViews.contains { $0.identifier?.rawValue == "tab-row-\(first.id.uuidString)" },
                  "A global Favorite was duplicated in paged rows or missing from the fixed grid")
        guard let favoriteButton = try sidebarView(first.id, favorite: true) as? NSButton else { throw Failure.assertion("Favorite tile is not a native button") }
        favoriteButton.performClick(nil)
        try check(browser.session.activeID == first.id && browser.session.space == 2 && browser.browsers[first.id] === reopened,
                  "Favorite click changed Space or replaced its shared live page")
        let beforeSplitAttempt = browser.session.tabs.count
        browser.splitWithNewPage(nil)
        try check(browser.session.tabs.count == beforeSplitAttempt && browser.session.split(for: first.id) == nil
                    && !browser.moveTab(first.id, toSpace: 1), "Favorite Split/move rejection created a stray tab or changed scope")
        browser.favoriteTab(homes[2].id)
        try invoke("Move Earlier", id: homes[2].id, favorite: true)
        try check(browser.session.favoriteTabs.map(\.id) == [homes[2].id, first.id]
                    && (try !menuItem("Move Earlier", id: homes[2].id, favorite: true).isEnabled),
                  "Native Favorite reorder failed or enabled movement beyond the first tile")
        try invoke("Unload Favorite", id: first.id, favorite: true)
        try check(try tab(first.id).isUnloaded && browser.browsers[first.id] == nil
                    && (try !menuItem("Unload Favorite", id: first.id, favorite: true).isEnabled),
                  "Favorite unload removed its tile or left a repeated unload action enabled")
        guard let sleepingButton = try sidebarView(first.id, favorite: true) as? NSButton else { throw Failure.assertion("Sleeping Favorite tile missing") }
        sleepingButton.performClick(nil)
        guard let favoriteReopened = browser.browsers[first.id] else { throw Failure.assertion("Sleeping Favorite did not reopen") }
        try check(browser.session.space == 2 && browser.session.activeID == first.id && favoriteReopened !== reopened,
                  "Sleeping Favorite activation lost its identity/current Space or reused a discarded view")
        try await wait("Favorite original page reopened") { !favoriteReopened.isLoading && !browser.pendingLoads.contains(first.id) }

        // A mixed Split unloads the kept member, deletes only its ordinary peer,
        // and archives only the peer. Both actual WebKit views must be released.
        let kept = BrowserTab(title: "Kept split", address: url.absoluteString, space: 2, pinned: true)
        let ordinary = BrowserTab(title: "Ordinary split", address: url.absoluteString, space: 2)
        browser.session.tabs += [kept, ordinary]
        try check(browser.session.makeSplit(primary: kept.id, secondary: ordinary.id), "Saved Split fixture rejected")
        browser.showActive()
        guard let left = browser.browsers[kept.id], let right = browser.browsers[ordinary.id] else { throw Failure.assertion("Saved Split did not attach both panes") }
        try await wait("saved Split pages loaded") { !left.isLoading && !right.isLoading && !browser.pendingLoads.contains(kept.id) && !browser.pendingLoads.contains(ordinary.id) }
        guard let split = browser.splitCoordinators[kept.id] else { throw Failure.assertion("Saved Split coordinator missing") }
        fixtureWindow.makeFirstResponder(right); split.setFocusedSide(.right)
        try check(browser.focusedTabID == ordinary.id, "Focus did not move to the ordinary pane")
        browser.togglePin(nil)
        try check(try tab(ordinary.id).isSaved && tab(kept.id).isSaved,
                  "Pin command failed to keep the focused secondary pane")
        browser.togglePin(nil)
        try check(try !tab(ordinary.id).isSaved && tab(kept.id).isSaved,
                  "Unkeep command modified the other Split pane")
        fixtureWindow.makeFirstResponder(left); split.setFocusedSide(.left)
        try check(browser.focusedTabID == kept.id, "Focus did not return to the kept pane")
        try invoke("Close Split", id: kept.id)
        try check(try tab(kept.id).isUnloaded && !browser.session.tabs.contains(where: { $0.id == ordinary.id })
                    && browser.session.split(for: kept.id) == nil, "Closing mixed Split lost the kept identity or retained its ordinary peer/group")
        try check(browser.browsers[kept.id] == nil && browser.browsers[ordinary.id] == nil
                    && left.superview == nil && right.superview == nil, "Mixed Split close retained a closed pane")
        try check(browser.library.closedRecords.count == archiveCount + 1
                    && browser.library.closedRecords.first?.tabs.map(\.id) == [ordinary.id]
                    && browser.library.closedRecords.first?.split == false,
                  "Mixed Split archive duplicated the kept member or retained a dangling Split")

        // Deleting all old Spaces must not attempt to move a global Favorite
        // through the ordinary-tab API, which correctly rejects Favorites.
        let chainTabs = [BrowserTab(title: "Global", address: url.absoluteString, space: 1,
                                   saved: SavedTabState(kind: .favorite, address: url.absoluteString)),
                         BrowserTab(title: "Local", address: "orbit://newtab", space: 0)]
        let chain = BrowserSession(tabs: chainTabs, activeID: chainTabs[0].id, space: 2)
        let plan = SpaceEditPlan(originalIDs: Set([0, 1, 2]), spaces: [
            BrowserSpace(id: -1, name: "New Home", symbol: "book", colorIndex: 0)
        ], removalDestinations: [0: 1, 1: 2, 2: -1])
        guard let remapped = plan.applying(to: chain) else { throw Failure.assertion("Favorite blocked a valid all-old-Spaces replacement") }
        try check(Set(remapped.tabs.map(\.id)) == Set(chainTabs.map(\.id))
                    && remapped.favoriteTabs.map(\.id) == [chainTabs[0].id]
                    && remapped.tabs.allSatisfy { remapped.spaceIDs.contains($0.space) },
                  "Space replacement lost or invalidated a global Favorite")

        // Retain the old view explicitly so a lost reference cannot make this
        // pass accidentally: closing a floating kept video must actually pause it.
        let videoID = browser.session.add(address: "orbit://video")
        browser.pinTab(videoID); browser.showActive()
        guard let video = browser.browsers[videoID] else { throw Failure.assertion("Saved video fixture missing") }
        try await wait("saved video page loaded") { !video.isLoading && !browser.pendingLoads.contains(videoID) }
        // preload=metadata need not decode a frame until playback is requested.
        try await waitJS("saved video metadata ready", web: video, source: "!!document.querySelector('video') && document.querySelector('video').readyState>=1")
        _ = try await js(video, "const v=document.querySelector('video'); v.muted=true; v.play(); true")
        try await waitJS("saved video playing with a decoded frame", web: video, source: "!document.querySelector('video').paused && document.querySelector('video').readyState>=2")
        browser.togglePictureInPicture(nil)
        try await wait("saved video floats") { browser.pictureInPicture.activeTabID == videoID && browser.pictureInPicture.presentationReady }
        browser.close(videoID)
        try check(try tab(videoID).isUnloaded && browser.browsers[videoID] == nil
                    && browser.pictureInPicture.referencedTabID == nil && browser.session.activeID != videoID,
                  "PiP close reentrantly resurrected the unloaded saved view")
        try await waitJS("unloaded floating video pauses", web: video, source: "document.querySelector('video').paused")
        try await wait("closed PiP transfer cleaned up") { !browser.pictureInPicture.isRestoring(video) }
        try check(browser.browsers[videoID] == nil && video.superview == nil && browser.library.closedRecords.count == archiveCount + 1,
                  "Asynchronous PiP cleanup reattached or archived a sleeping saved tab")
        print("Saved tabs: \(checks - beforeChecks) checks passed")
    }
}
