import AppKit
import WebKit

/// Auto-archive's clock: a sweep shortly after launch, on wake, and every few minutes.
@MainActor final class TabArchiver {
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    private var launch: DispatchWorkItem?
    fileprivate var sweeping = false
    /// The Archive window, made on first use.
    var archiveWindow: ArchivedTabsController?
    /// When each Little Bam window was last in use (made or focused), by its key in littleWindows.
    var littleBamActive: [UUID: Date] = [:]
    fileprivate var keyObserver: NSObjectProtocol?
    /// Five minutes is plenty against hours-long intervals, and costs nothing between ticks.
    var period: TimeInterval = 300

    func start(_ sweep: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let launch = DispatchWorkItem { MainActor.assumeIsolated { sweep() } }
        self.launch = launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: launch)
        let timer = Timer(timeInterval: period, repeats: true) { _ in MainActor.assumeIsolated { sweep() } }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sweep() }
        }
    }
    func stop() {
        launch?.cancel(); launch = nil
        timer?.invalidate(); timer = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
    }
}

@MainActor extension BrowserController {
    func startTabArchiving() {
        tabArchiver.period = ArchivePreference.sweepPeriod
        tabArchiver.start { [weak self] in
            guard let self else { return }
            self.sweepLittleBams()
            Task { @MainActor in await self.sweepArchive() }
        }
        tabArchiver.keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      let id = self.littleWindows.first(where: { $0.value.window === window })?.key else { return }
                self.tabArchiver.littleBamActive[id] = Date()
            }
        }
    }
    func stopTabArchiving() {
        tabArchiver.stop()
        if let observer = tabArchiver.keyObserver { NotificationCenter.default.removeObserver(observer) }
        tabArchiver.keyObserver = nil
    }

    /// Settings › Links › Archive Little Bams after: a Little Bam window left unused that long closes,
    /// and its page goes to the archive. The window in front is never closed.
    @discardableResult func sweepLittleBams(now: Date = Date()) -> Int {
        let trial = ArchivePreference.defaults == nil ? ArchivePreference.environment["BAM_ARCHIVE_AFTER_SECONDS"].flatMap(TimeInterval.init) : nil
        let after = trial ?? LinkBehavior.littleBamArchive.seconds
        var closed = 0
        tabArchiver.littleBamActive = tabArchiver.littleBamActive.filter { littleWindows[$0.key] != nil }
        for (id, little) in littleWindows {
            if little.window?.isKeyWindow == true { tabArchiver.littleBamActive[id] = now; continue }
            guard let since = tabArchiver.littleBamActive[id] else { tabArchiver.littleBamActive[id] = now; continue }
            guard now.timeIntervalSince(since) >= after else { continue }
            if let web = little.webView, let url = web.url, URLInput.directURL(url.absoluteString) != nil {
                let tab = BrowserTab(title: web.title?.isEmpty == false ? web.title! : (url.host ?? url.absoluteString),
                                     address: url.absoluteString, space: session.space)
                library(for: profileID(of: web) ?? session.currentProfileID).recordClosed(tabs: [tab], split: false, reason: .archived)
            }
            tabArchiver.littleBamActive.removeValue(forKey: id)
            little.close(); closed += 1
        }
        return closed
    }

    /// View Archive…: the current profile's archive, in Bam's Settings look.
    func presentArchive() {
        if tabArchiver.archiveWindow == nil {
            var source = ArchiveWindowSource()
            source.records = { [weak self] in self?.library.closedRecords ?? [] }
            source.favicon = { [weak self] address in
                guard let self, let url = URL(string: address), url.host != nil else { return nil }
                return self.favicon(forSiteURL: url, allowFetch: false)
            }
            source.restore = { [weak self] id in
                guard let self, let callback = self.library.onRestoreClosed, let record = self.library.takeClosed(id: id) else { return false }
                callback(record)
                return true
            }
            source.clear = { [weak self] in self?.library.clearArchive() ?? false }
            source.interval = {
                guard let seconds = ArchivePreference.effectiveSeconds else { return nil }
                // A fresh preview's trial clock names itself; otherwise the choice's own words.
                return seconds == ArchivePreference.interval.seconds ? ArchivePreference.interval.title : "\(Int(seconds)) seconds"
            }
            source.openSettings = { (NSApp.delegate as? AppDelegate)?.presentSettings(section: .general) }
            tabArchiver.archiveWindow = ArchivedTabsController(source: source)
        }
        library.onChange = { [weak self] in self?.tabArchiver.archiveWindow?.reload() }
        tabArchiver.archiveWindow?.present(relativeTo: view.window)
    }

    /// Tabs on screen now count as viewed now.
    func stampViewed(_ ids: [UUID], at now: Date = Date()) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        for index in session.tabs.indices where wanted.contains(session.tabs[index].id) { session.tabs[index].lastViewedAt = now }
    }

    /// Archives the Today tabs that have gone unviewed for Settings' time. Never touches kept tabs or
    /// Favorites, the tab on screen, or a tab playing media, in a call, in Picture in Picture,
    /// downloading or under a Peek. Waits while a Space swipe or a sheet is in progress.
    @discardableResult func sweepArchive(now: Date = Date()) async -> Int {
        guard let after = ArchivePreference.effectiveSeconds, !tabArchiver.sweeping, !isShuttingDown,
              view.window != nil, view.window?.attachedSheet == nil,
              !trackingSwipe, pagingOffset == 0, pagingTarget == nil else { return 0 }
        tabArchiver.sweeping = true
        defer { tabArchiver.sweeping = false }
        // A tab never stamped (from before auto-archive, or restored from the archive) starts its clock now,
        // so upgrading never archives a whole sidebar at once.
        var stamped = false
        for index in session.tabs.indices where session.tabs[index].lastViewedAt == nil {
            session.tabs[index].lastViewedAt = now; stamped = true
        }
        stampViewed(visibleMemberIDs, at: now)
        let policy = TabArchivePolicy()
        // Only tabs already past the time need the (asynchronous) media check.
        let timeDue = Set(policy.due(archiveCandidates(playing: []), now: now, after: after))
        guard !timeDue.isEmpty else { if stamped { save() }; return 0 }
        var playing = Set<UUID>()
        for tab in session.tabs where timeDue.contains(session.split(for: tab.id)?.primaryID ?? tab.id) {
            guard let web = browsers[tab.id] else { continue }
            if await Self.isPlayingMedia(web) { playing.insert(tab.id) }
        }
        // Re-read everything after the wait: the person may have switched tabs or Spaces meanwhile.
        guard !isShuttingDown, view.window?.attachedSheet == nil, !trackingSwipe, pagingOffset == 0, pagingTarget == nil else { return 0 }
        stampViewed(visibleMemberIDs, at: now)
        let due = policy.due(archiveCandidates(playing: playing), now: now, after: after)
        for id in due where session.tabs.contains(where: { $0.id == id }) { close(id, archived: true) }
        if due.isEmpty && stamped { save() }
        return due.count
    }

    func archiveCandidates(playing: Set<UUID>) -> [TabArchivePolicy.Candidate] {
        let visible = Set(visibleMemberIDs)
        let downloading = downloads.activeSourceWebViews.map(ObjectIdentifier.init)
        let pip = pictureInPicture.referencedTabID
        return session.tabs.map { tab in
            let web = browsers[tab.id]
            let split = session.split(for: tab.id)
            return TabArchivePolicy.Candidate(
                id: tab.id, lastViewedAt: tab.lastViewedAt, isSaved: tab.isSaved,
                isVisible: visible.contains(tab.id) || tab.id == session.activeID,
                isPlayingMedia: playing.contains(tab.id),
                isCapturing: web.map { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none } ?? false,
                isPictureInPicture: pip == tab.id,
                isDownloading: web.map { downloading.contains(ObjectIdentifier($0)) } ?? false,
                hasPeek: peeks[tab.id] != nil,
                splitPrimaryID: split?.primaryID)
        }
    }

    private static func isPlayingMedia(_ web: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { state in continuation.resume(returning: state == .playing) }
        }
    }
}
