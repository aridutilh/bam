import AppKit
import WebKit

/// Uses disposable per-profile stores and a loopback fixture only. This checks
/// real cookie/storage isolation and view ownership, not real account logins.
@MainActor final class ProfileSmokeTest {
    private var controller: BrowserController!
    private var window: NSWindow!
    private var checks = 0
    private var watchdog: Timer?
    private var runner: Task<Void, Never>?
    private var finished = false
    private var fixtureURL: URL!
    private var workProfile: UUID!
    private var workSpace = 0
    private var sharedSpace = 0
    private var confirmationCount = 0
    private var disposableStoreID: UUID?
    private var disposableRegistry: WebsiteProfileStore?
    private var disposableWeb: WKWebView?
    enum Failure: Error { case assertion(String) }

    func start() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(false, "Overall fixture timeout") }
        }
        runner = Task { @MainActor in
            do {
                try await run()
                finish(true, "\(checks) checks: shared/separate cookie and localStorage stores, profile-scoped Favorites, same-profile continuity, cancelled/accepted profile changes, preview promotion, Split moves, archive/session metadata and same-process disposable named-store continuity")
            } catch { finish(false, String(describing: error)) }
        }
    }
    private func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }; checks += 1
    }
    private func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { checks += 1; return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.assertion("Timeout: \(message)")
    }
    private func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
    private func quoted(_ value: String) throws -> String {
        let array = String(data: try JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }
    private func ready(_ web: WKWebView, _ label: String, at expectedURL: URL? = nil) async throws {
        let expected = expectedURL ?? fixtureURL!
        try await wait(label) { !web.isLoading && web.title == "Bam Profile Fixture" && web.url?.absoluteString == expected.absoluteString }
    }
    private func account(_ web: WKWebView) async throws -> [String: String] {
        guard let result = try await js(web, "profileFixture.snapshot()") as? [String: String] else {
            throw Failure.assertion("Profile fixture did not return its account snapshot")
        }
        return result
    }
    private func write(_ value: String, to web: WKWebView) async throws {
        _ = try await js(web, "profileFixture.writeAccount(\(quoted(value))); true")
    }
    private func markDraft(_ value: String, in web: WKWebView) async throws {
        _ = try await js(web, "document.querySelector('#draft').value=\(quoted(value)); window.profileMemorySentinel=\(quoted(value)); true")
    }
    private func hasAccount(_ web: WKWebView, _ expected: String) async throws -> Bool {
        let snapshot = try await account(web)
        return snapshot["cookie"] == expected && snapshot["storage"] == expected
    }
    private func profile(of web: WKWebView) -> UUID? {
        controller.profileStores.profileID(for: web.configuration.websiteDataStore)
    }
    private func setConfirmation(_ accepted: Bool) {
        controller.confirmProfileChange = { [weak self] _ in
            self?.confirmationCount += 1
            return accepted
        }
    }

    private func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BAM_TEST_URL"] ?? env["ARK_TEST_URL"] ?? env["ORBIT_TEST_URL"],
              let base = URLInput.directURL(raw), ["127.0.0.1", "localhost", "::1"].contains(base.host ?? "") else {
            throw Failure.assertion("Set BAM_TEST_URL to the isolated loopback fixture server")
        }
        fixtureURL = base.deletingLastPathComponent().appendingPathComponent("profile.html")
        let initial = BrowserTab(title: "Profile A", address: fixtureURL.absoluteString, space: 0)
        var session = BrowserSession(tabs: [initial], activeID: initial.id,
                                     spaces: [BrowserSpace(id: 0, name: "Personal", symbol: "house", colorIndex: 0)])
        guard let profile = session.createProfile(name: "Work"),
              let work = session.createSpace(name: "Work", symbol: "briefcase", colorIndex: 1, profileID: profile),
              let shared = session.createSpace(name: "Personal shared", symbol: "book", colorIndex: 2, profileID: BrowserProfile.defaultID) else {
            throw Failure.assertion("Could not construct profile fixture metadata")
        }
        workProfile = profile; workSpace = work; sharedSpace = shared
        let sibling = BrowserTab(title: "Profile A sibling", address: fixtureURL.absoluteString, space: 0)
        let separate = BrowserTab(title: "Profile B", address: fixtureURL.absoluteString, space: work)
        let sharedTab = BrowserTab(title: "Profile A other Space", address: fixtureURL.absoluteString, space: shared)
        session.tabs += [sibling, separate, sharedTab]
        controller = BrowserController(sessionURL: URL(fileURLWithPath: "/private/tmp/bam-profile-unused-\(UUID()).json"), ephemeral: true)
        controller.automaticallyShowsVideo = false; controller.automaticTabSleeping = false
        controller.session = session; setConfirmation(false)
        let personalStore = controller.profileStores.store(for: BrowserProfile.defaultID)
        let workStore = controller.profileStores.store(for: profile)
        try check(!personalStore.isPersistent && !workStore.isPersistent, "Fixture must never use persistent account stores")
        try check(personalStore !== workStore, "Different profiles must have different data stores")
        try check(controller.profileStores.store(for: profile) === workStore, "One profile must reuse its canonical data store")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Bam — isolated profile fixture"; window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let original = controller.browsers[initial.id]!
        try await ready(original, "initial profile document")
        try await write("personal-account", to: original)
        controller.select(sibling.id)
        let siblingWeb = controller.browsers[sibling.id]!
        try await ready(siblingWeb, "same-profile sibling")
        try check(try await hasAccount(siblingWeb, "personal-account"), "Same-profile tabs failed to share cookies and localStorage")
        controller.select(separate.id)
        let separateWeb = controller.browsers[separate.id]!
        try await ready(separateWeb, "separate-profile document")
        try check(try await hasAccount(separateWeb, ""), "A new profile inherited another profile's cookie/storage")
        try await write("work-account", to: separateWeb)
        try check(try await hasAccount(original, "personal-account"), "Writing Work account mutated Personal account")
        controller.select(sharedTab.id)
        let sharedWeb = controller.browsers[sharedTab.id]!
        try await ready(sharedWeb, "shared profile in another Space")
        try check(try await hasAccount(sharedWeb, "personal-account"), "Spaces sharing one profile did not share login storage")

        // A background page must never route an internal navigation through the
        // active page, especially when the two pages use different login stores.
        controller.select(separate.id)
        try await markDraft("active-work-stays", in: separateWeb)
        let activeOrigin = try await js(separateWeb, "performance.timeOrigin") as? Double
        let internalSource = BrowserTab(title: "Background internal navigation", address: fixtureURL.absoluteString, space: shared)
        controller.session.tabs.append(internalSource)
        let internalWeb = controller.webView(for: internalSource)
        try await ready(internalWeb, "background internal-navigation source")
        _ = try await js(internalWeb, "location.href='orbit://newtab'; true")
        try await wait("source-bound internal navigation") {
            !internalWeb.isLoading && internalWeb.url?.lastPathComponent == "Home.html"
        }
        try check(controller.session.activeID == separate.id && controller.session.currentProfileID == profile,
                  "Background internal navigation changed active profile or selection")
        let activeOriginAfter = try await js(separateWeb, "performance.timeOrigin") as? Double
        try check(controller.browsers[separate.id] === separateWeb && separateWeb.url == fixtureURL && activeOriginAfter == activeOrigin,
                  "Background internal navigation replaced another profile's active document")
        let activeState = try await account(separateWeb)
        try check(activeState["draft"] == "active-work-stays" && activeState["memory"] == "active-work-stays" &&
                  activeState["cookie"] == "work-account", "Background internal navigation lost active account or unsaved state")
        try check(self.profile(of: internalWeb) == BrowserProfile.defaultID,
                  "Internal navigation changed the source page's profile")
        controller.close(internalSource.id)

        controller.select(sibling.id); controller.favoriteTab(sibling.id)
        try check(controller.session.favorites(in: BrowserProfile.defaultID).contains { $0.id == sibling.id }, "Favorite did not bind to its origin profile")
        controller.select(separate.id)
        try check(!controller.session.visibleTabs.contains { $0.id == sibling.id }, "Personal Favorite leaked into Work sidebar")
        controller.select(sharedTab.id)
        try check(controller.session.visibleTabs.contains { $0.id == sibling.id }, "Personal Favorite disappeared from a Space sharing its profile")
        controller.select(separate.id); controller.select(sibling.id)
        try check(controller.session.currentProfileID == BrowserProfile.defaultID && controller.browsers[sibling.id] === siblingWeb, "Selecting a saved Favorite must retain its profile and web view")

        controller.select(initial.id); try await markDraft("unsaved-personal", in: original)
        let beforeSame = confirmationCount
        try check(controller.moveTab(initial.id, toSpace: shared), "Same-profile move failed")
        try check(confirmationCount == beforeSame && controller.browsers[initial.id] === original, "Same-profile move prompted or replaced the live view")
        let sameDraft = try await account(original)
        try check(sameDraft["draft"] == "unsaved-personal" && sameDraft["memory"] == "unsaved-personal", "Same-profile move lost live form/heap state")
        let beforeRejected = controller.session
        setConfirmation(false)
        try check(!controller.moveTab(initial.id, toSpace: work), "Rejected cross-profile move was accepted")
        try check(controller.session.tabs == beforeRejected.tabs && controller.session.space == beforeRejected.space && controller.browsers[initial.id] === original, "Cancel changed Space membership, selection or live view")
        let confirmedURL = URL(string: fixtureURL.absoluteString + "?confirmation=latest")!
        // A native modal confirmation runs a nested event loop. Delegate title
        // and URL updates can arrive after the edit proposal was prepared.
        controller.confirmProfileChange = { [weak self] _ in
            guard let self else { return false }
            self.confirmationCount += 1
            if let index = self.controller.session.tabs.firstIndex(where: { $0.id == sibling.id }) {
                self.controller.session.tabs[index].title = "Latest unrelated title"
            }
            if let index = self.controller.session.tabs.firstIndex(where: { $0.id == initial.id }) {
                self.controller.session.tabs[index].address = confirmedURL.absoluteString
            }
            return true
        }
        try check(controller.moveTab(initial.id, toSpace: work), "Accepted cross-profile move failed")
        try check(controller.session.tabs.first(where: { $0.id == sibling.id })?.title == "Latest unrelated title", "Confirmation overwrote an unrelated page's latest title")
        try check(controller.session.tabs.first(where: { $0.id == initial.id })?.address == confirmedURL.absoluteString, "Confirmation overwrote the moved page's latest URL")
        let moved = controller.browsers[initial.id]!
        try check(moved !== original && self.profile(of: moved) == profile, "Cross-profile move transplanted the old account view")
        try await ready(moved, "fresh destination-profile view", at: confirmedURL)
        let movedState = try await account(moved)
        try check(movedState["cookie"] == "work-account" && movedState["storage"] == "work-account", "Moved tab did not use destination account storage")
        try check(movedState["draft"] == "" && movedState["memory"] == "", "Cross-profile reload transplanted old form or heap state")

        controller.select(sharedTab.id); try await markDraft("space-draft", in: sharedWeb)
        let newlyLoaded = BrowserTab(title: "Unloaded before confirmation", address: fixtureURL.absoluteString, space: shared)
        controller.session.tabs.append(newlyLoaded)
        var reassigned = controller.session
        try check(reassigned.updateSpace(id: shared, name: "Reassigned", symbol: "book", colorIndex: 2, profileID: profile), "Could not prepare profile reassignment")
        setConfirmation(false)
        try check(!controller.applyProfileAwareSession(reassigned) && controller.browsers[sharedTab.id] === sharedWeb && controller.session.spaceDefinition(shared)?.profileID == BrowserProfile.defaultID, "Cancelled Space reassignment altered its live account")
        controller.confirmProfileChange = { [weak self] _ in
            guard let self else { return false }
            self.confirmationCount += 1
            _ = self.controller.webView(for: newlyLoaded)
            return true
        }
        try check(!controller.applyProfileAwareSession(reassigned), "Confirmation discarded a newly loaded page outside the approved set")
        guard let arrivedWeb = controller.browsers[newlyLoaded.id] else { throw Failure.assertion("Late page was not created during the confirmation hook") }
        try check(controller.session.spaceDefinition(shared)?.profileID == BrowserProfile.defaultID && controller.browsers[sharedTab.id] === sharedWeb, "Expanded confirmation scope partially changed the old profile")
        try await ready(arrivedWeb, "page loaded during profile confirmation")
        let arrivedAccount = try await hasAccount(arrivedWeb, "personal-account")
        try check(self.profile(of: arrivedWeb) == BrowserProfile.defaultID && arrivedAccount, "Unapproved late page lost its original account")
        setConfirmation(true)
        try check(controller.applyProfileAwareSession(reassigned), "Accepted Space reassignment failed")
        let reassignedWeb = controller.browsers[sharedTab.id]!
        try check(reassignedWeb !== sharedWeb && self.profile(of: reassignedWeb) == profile, "Space reassignment reused the previous profile's WKWebView")
        try await ready(reassignedWeb, "reassigned Space document")
        try check(try await hasAccount(reassignedWeb, "work-account"), "Reassigned Space did not use selected account")
        var renamed = controller.session
        try check(renamed.renameProfile(id: profile, name: "Work renamed"), "Profile rename rejected")
        let beforeRename = confirmationCount
        try check(controller.applyProfileAwareSession(renamed) && confirmationCount == beforeRename && controller.browsers[sharedTab.id] === reassignedWeb, "Renaming a profile changed account identity or reloaded its pages")

        try await backgroundProfileTab(whileSelected: separate.id)
        try await previewPromotion(owner: sibling.id, destination: separate.id)
        try await splitAndArchive(destinationProfile: profile)
        let data = try JSONEncoder().encode(controller.session)
        var restored = try JSONDecoder().decode(BrowserSession.self, from: data); restored.sanitize()
        try check(restored.profiles == controller.session.profiles && restored.spaces == controller.session.spaces, "Profile names/IDs/Space assignments did not survive session encoding")
        try check(restored.favorites(in: BrowserProfile.defaultID).contains { $0.id == sibling.id }, "Favorite's explicit profile did not survive session encoding")
        try check(controller.profileStores.store(for: profile) === workStore, "Metadata changes replaced a profile's canonical store")
        try check(confirmationCount >= 4, "Cross-profile test paths did not exercise the real confirmation boundary")
        try await disposableNamedStoreContinuity()
    }

    private func backgroundProfileTab(whileSelected destination: UUID) async throws {
        controller.select(destination)
        let previousSpace = controller.session.space
        guard let id = controller.openProfileTab(fixtureURL, profileID: BrowserProfile.defaultID, active: false),
              let web = controller.browsers[id] else { throw Failure.assertion("Source-profile background tab was not created") }
        try check(controller.session.activeID == destination && controller.session.space == previousSpace, "Background profile tab changed the visible destination")
        try check(self.profile(of: web) == BrowserProfile.defaultID, "Background source link inherited the other visible profile")
        try await ready(web, "source-profile background tab")
        try check(try await hasAccount(web, "personal-account"), "Background source-profile link opened with the wrong cookies/storage")
        controller.close(id)
        try check(controller.session.activeID == destination && controller.session.space == previousSpace, "Closing background profile tab changed visible selection")
    }

    private func previewPromotion(owner: UUID, destination: UUID) async throws {
        controller.select(owner); controller.openPeek(fixtureURL)
        guard let peek = controller.peeks[owner], let preview = peek.webView else { throw Failure.assertion("Personal Peek was not created") }
        try await ready(preview, "Personal Peek")
        try check(self.profile(of: preview) == BrowserProfile.defaultID, "Peek inherited the wrong profile")
        try check(try await hasAccount(preview, "personal-account"), "Peek did not share its source profile's cookie/storage")
        try await markDraft("preview-draft", in: preview)
        peek.openInLittleOrbit()
        guard let little = controller.littleWindows.values.first(where: { $0.webView === preview }) else { throw Failure.assertion("Peek did not move into Little Bam") }
        try check(little.webView === preview && self.profile(of: preview) == BrowserProfile.defaultID, "Little Bam replaced or relabeled the adopted profile")
        controller.select(destination)
        try check(controller.session.currentProfileID == workProfile, "Promotion precondition: main window did not switch to Work")
        // The key Little window still belongs to Personal while the main model
        // belongs to Work. A new Little must inherit the command's origin.
        NSApp.activate(ignoringOtherApps: true)
        try await wait("profile fixture app active before New Little command") { NSApp.isActive }
        little.window?.makeKeyAndOrderFront(nil)
        try await wait("origin Little window key") { little.window?.isKeyWindow == true }
        let existingWindows = Set(controller.littleWindows.keys)
        controller.newLittleOrbit(nil)
        guard let spawned = controller.littleWindows.first(where: { !existingWindows.contains($0.key) })?.value,
              let spawnedWeb = spawned.webView else { throw Failure.assertion("New Little command did not create a window") }
        try check(self.profile(of: spawnedWeb) == BrowserProfile.defaultID && controller.session.currentProfileID == workProfile, "New Little used the main window's different account")
        try check(spawned.open(url: fixtureURL), "New Little rejected the loopback fixture")
        try await ready(spawnedWeb, "new Little from original profile")
        try check(try await hasAccount(spawnedWeb, "personal-account"), "New Little lost the key Little window's account context")
        spawned.close()
        little.promoteToOrbit()
        let promoted = controller.session.activeID
        try check(controller.browsers[promoted] === preview && controller.session.currentProfileID == BrowserProfile.defaultID, "Promotion into another active profile failed to preserve origin profile/view")
        let retained = try await account(preview)
        try check(retained["draft"] == "preview-draft" && retained["memory"] == "preview-draft" && retained["cookie"] == "personal-account", "Preview promotion lost its live state or used the wrong account")
        try check(controller.peeks[owner] == nil && !controller.littleWindows.values.contains { $0 === little }, "Promoted preview retained an obsolete host")
    }

    private func splitAndArchive(destinationProfile: UUID) async throws {
        let leftID = controller.session.activeID
        let left = controller.browsers[leftID]!
        controller.splitWithNewPage(nil)
        guard let split = controller.session.split(for: leftID) else { throw Failure.assertion("Could not create profile Split") }
        controller.navigatePane(split.secondaryID, address: fixtureURL.absoluteString)
        let right = controller.browsers[split.secondaryID]!
        try await ready(right, "Split right profile document")
        try check(self.profile(of: right) == BrowserProfile.defaultID, "New Split pane did not use the owner's profile")
        var withSharedSpace = controller.session
        guard let destination = withSharedSpace.createSpace(name: "Same-profile move", symbol: "globe", colorIndex: 3, profileID: BrowserProfile.defaultID) else { throw Failure.assertion("Could not create same-profile Split destination") }
        try check(controller.applyProfileAwareSession(withSharedSpace), "Could not apply unchanged-profile Space addition")
        let beforeSame = confirmationCount
        try check(controller.moveTab(leftID, toSpace: destination), "Same-profile Split move failed")
        try check(confirmationCount == beforeSame && controller.browsers[leftID] === left && controller.browsers[split.secondaryID] === right, "Same-profile Split move replaced panes or prompted")
        setConfirmation(false)
        try check(!controller.moveTab(leftID, toSpace: workSpace) && controller.browsers[leftID] === left && controller.browsers[split.secondaryID] === right, "Rejected cross-profile Split move altered either pane")
        setConfirmation(true)
        try check(controller.moveTab(leftID, toSpace: workSpace), "Accepted cross-profile Split move failed")
        guard let newLeft = controller.browsers[leftID], let newRight = controller.browsers[split.secondaryID] else { throw Failure.assertion("Moved Split lost a pane") }
        try check(newLeft !== left && newRight !== right && self.profile(of: newLeft) == destinationProfile && self.profile(of: newRight) == destinationProfile, "Cross-profile Split move transplanted an old-profile pane")
        try await ready(newLeft, "moved Split left"); try await ready(newRight, "moved Split right")
        let leftAccount = try await hasAccount(newLeft, "work-account"), rightAccount = try await hasAccount(newRight, "work-account")
        try check(leftAccount && rightAccount, "Moved Split panes do not both use destination account")
        controller.close(leftID)
        let archive = controller.library(for: destinationProfile)
        guard let record = archive.popClosed() else { throw Failure.assertion("Closed Split did not enter origin-profile archive") }
        try check(record.split && record.tabs.count == 2, "Profile archive lost Split metadata")
        // Reassign the former Space after closing. Reopen must still follow the
        // archive's profile, not whichever account now occupies that Space ID.
        var rebound = controller.session
        try check(rebound.updateSpace(id: workSpace, name: "Former Work", symbol: "briefcase", colorIndex: 1, profileID: BrowserProfile.defaultID), "Could not prepare archive destination reassignment")
        try check(controller.applyProfileAwareSession(rebound), "Could not reassign former archive Space")
        controller.changeSpace(0)
        guard let reopen = archive.onRestoreClosed else { throw Failure.assertion("Profile archive has no restore callback") }
        reopen(record)
        guard let reopened = controller.session.split(for: controller.session.activeID),
              let reopenedLeft = controller.browsers[reopened.primaryID], let reopenedRight = controller.browsers[reopened.secondaryID] else { throw Failure.assertion("Profile archive did not restore its Split") }
        try check(controller.session.currentProfileID == destinationProfile && controller.session.space == sharedSpace, "Archive reopened in the reassigned Space's wrong profile")
        try check(self.profile(of: reopenedLeft) == destinationProfile && self.profile(of: reopenedRight) == destinationProfile, "Restored Split opened with wrong website stores")
        try await ready(reopenedLeft, "restored profile Split left"); try await ready(reopenedRight, "restored profile Split right")
        try check(try await hasAccount(reopenedLeft, "work-account"), "Archive restoration lost origin account context")
    }

    /// This stays within one process. It checks reconstruction by stable store
    /// ID, not process-relaunch persistence or a forced on-disk flush.
    private func disposableNamedStoreContinuity() async throws {
        let identifier = UUID()
        try check(identifier != BrowserProfile.defaultID, "Disposable store must never use the default account identifier")
        disposableStoreID = identifier
        print("PROFILE_TEST_DISPOSABLE_STORE=\(identifier.uuidString)"); fflush(stdout)
        // Keep each phase in its own async scope so temporary configuration,
        // cookie-store and website-store references end before reconstruction.
        let firstReleased = try await exerciseDisposableStore(identifier, writing: true)
        try await wait("first named-store view and store released", firstReleased)
        let replacementReleased = try await exerciseDisposableStore(identifier, writing: false)
        try await wait("replacement named-store view and store released", replacementReleased)
        try await removeDisposableStore(identifier)
        disposableStoreID = nil
        checks += 1 // Public removal succeeded for exactly our generated ID.
    }
    private func exerciseDisposableStore(_ identifier: UUID, writing: Bool) async throws -> () -> Bool {
        disposableRegistry = WebsiteProfileStore(ephemeral: false)
        disposableWeb = makeDisposableView(identifier)
        let released = { [weak web = disposableWeb, weak store = disposableWeb!.configuration.websiteDataStore] in
            web == nil && store == nil
        }
        defer { releaseDisposableViews() }
        try check(disposableWeb!.configuration.websiteDataStore.isPersistent && disposableWeb!.configuration.websiteDataStore.identifier == identifier, "Named profile did not receive its requested persistent store ID")
        disposableWeb!.load(URLRequest(url: fixtureURL))
        try await ready(disposableWeb!, writing ? "first disposable named-store document" : "replacement disposable named-store document")
        if writing {
            try check(try await hasAccount(disposableWeb!, ""), "Fresh randomly named store unexpectedly contained this test account")
            _ = try await js(disposableWeb!, "profileFixture.writeAccount('disposable-persistent-account', true); true")
            let cookies = await disposableWeb!.configuration.websiteDataStore.httpCookieStore.allCookies()
            try check(cookies.contains { $0.name == "bam_profile_account" && $0.value == "disposable-persistent-account" && $0.expiresDate != nil }, "Disposable named-store cookie was not persistent")
        } else {
            try check(try await hasAccount(disposableWeb!, "disposable-persistent-account"), "Reconstructing the named store lost its cookie/localStorage")
        }
        return released
    }
    private func removeDisposableStore(_ identifier: UUID) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: ()) }
                    }
                }
                print("PROFILE_TEST_DISPOSABLE_STORE_REMOVED=\(identifier.uuidString)"); fflush(stdout)
                return
            } catch {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw error }
                // WKWebView disposal is synchronous, but its network-session
                // teardown crosses a process boundary. Retry only our exact ID.
                attempt += 1
                let delay = min(1.0, 0.2 * Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    private func makeDisposableView(_ identifier: UUID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = disposableRegistry!.store(for: identifier)
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }
    private func releaseDisposableViews() {
        disposableWeb?.stopLoading(); disposableWeb?.removeFromSuperview()
        disposableWeb = nil; disposableRegistry = nil
    }
    private func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }; finished = true; watchdog?.invalidate(); watchdog = nil
        runner?.cancel(); runner = nil
        controller?.prepareToClose(); window?.orderOut(nil)
        releaseDisposableViews()
        guard let identifier = disposableStoreID else { reportAndExit(success, message); return }
        // Even an assertion/overall timeout cleans up only this run's generated
        // store. A bounded cleanup failure fails the suite rather than hiding it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in
            Task { @MainActor in self.reportAndExit(false, message + "; disposable-store cleanup timed out: " + identifier.uuidString) }
        }
        Task { @MainActor in
            // Let the cancelled runner unwind any in-flight WebKit arguments.
            try? await Task.sleep(nanoseconds: 100_000_000)
            do {
                try await removeDisposableStore(identifier)
                disposableStoreID = nil; watchdog?.invalidate(); watchdog = nil
                reportAndExit(success, message)
            } catch {
                watchdog?.invalidate(); watchdog = nil
                reportAndExit(false, message + "; disposable-store cleanup failed for " + identifier.uuidString + ": " + error.localizedDescription)
            }
        }
    }
    private func reportAndExit(_ success: Bool, _ message: String) {
        print("\(success ? "PASS: Profiles — " : "FAIL: Profiles — ")\(message)")
        fflush(stdout); exit(success ? 0 : 1)
    }
}
