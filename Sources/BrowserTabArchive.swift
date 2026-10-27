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
    /// Wall and awake time at the last check this run (nil until the first), for `ArchiveClock`.
    var clock: (wall: Date, uptime: TimeInterval)?
    /// Today tabs at the last check, so a tab that turns up later (let go from kept, restored, moved in) starts fresh.
    var knownToday: Set<UUID>?

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
        // A private window keeps nothing: no archive, no view times.
        guard !isPrivateWindow else { return }
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

    /// Moves every view time past the time that didn't count (Mac asleep, Bam quit, clock changed), and starts
    /// the clock for tabs that just became Today tabs. Runs at every sweep, archiving on or off.
    func tickArchiveClock(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let shift = tabArchiver.clock.map { ArchiveClock.shift(lastWall: $0.wall, lastUptime: $0.uptime, now: now, uptime: uptime) }
            ?? ArchiveClock.shift(lastTick: ArchivePreference.clockTick, now: now)
        tabArchiver.clock = (now, uptime)
        ArchivePreference.clockTick = now
        var changed = false
        if shift != 0 {
            for index in session.tabs.indices {
                guard let viewed = session.tabs[index].lastViewedAt else { continue }
                session.tabs[index].lastViewedAt = ArchiveClock.moved(viewed, by: shift, now: now); changed = true
            }
        }
        let today = Set(session.tabs.lazy.filter { !$0.isSaved }.map(\.id))
        if let known = tabArchiver.knownToday {
            let arrived = today.subtracting(known)
            if !arrived.isEmpty { stampViewed(Array(arrived), at: now); changed = true }
        }
        tabArchiver.knownToday = today
        if changed { save() }
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

    /// At most this many tabs (or Splits) per sweep; the rest go five minutes later. Bounds the main-thread work.
    static let archiveBatchLimit = 100

    /// Archives the Today tabs that have gone unviewed for Settings' time (counting only time Bam was open on
    /// an awake Mac). Never touches kept tabs or Favorites, the tab on screen, or a tab playing media, in a call,
    /// in Picture in Picture, downloading, under a Peek or holding typed text. Waits while a Space swipe or a
    /// sheet is in progress. A tab closes only once its archive record is saved.
    @discardableResult func sweepArchive(now: Date = Date()) async -> Int {
        guard !isPrivateWindow, !tabArchiver.sweeping, !isShuttingDown else { return 0 }
        tickArchiveClock(now: now)
        guard let after = ArchivePreference.effectiveSeconds,
              view.window != nil, view.window?.attachedSheet == nil,
              !trackingSwipe, pagingOffset == 0, pagingTarget == nil else { return 0 }
        tabArchiver.sweeping = true
        defer { tabArchiver.sweeping = false }
        // A tab never stamped (from before auto-archive) starts its clock now, so upgrading never archives
        // a whole sidebar at once.
        var stamped = false
        for index in session.tabs.indices where session.tabs[index].lastViewedAt == nil {
            session.tabs[index].lastViewedAt = now; stamped = true
        }
        stampViewed(visibleMemberIDs, at: now)
        let policy = TabArchivePolicy()
        // Only tabs already past the time need the (asynchronous) page checks.
        let timeDue = Set(policy.due(archiveCandidates(staying: []), now: now, after: after).prefix(Self.archiveBatchLimit))
        guard !timeDue.isEmpty else { if stamped { save() }; return 0 }
        var staying = Set<UUID>()
        for tab in session.tabs where timeDue.contains(session.split(for: tab.id)?.primaryID ?? tab.id) {
            guard let web = browsers[tab.id] else { continue }
            if await Self.pageWantsToStay(web) { staying.insert(tab.id) }
            if isShuttingDown { return 0 }
        }
        // Re-read everything after the wait: the person may have switched tabs or Spaces meanwhile.
        guard !isShuttingDown, view.window?.attachedSheet == nil, !trackingSwipe, pagingOffset == 0, pagingTarget == nil else { return 0 }
        stampViewed(visibleMemberIDs, at: now)
        let due = policy.due(archiveCandidates(staying: staying), now: now, after: after).filter(timeDue.contains)
        let archived = archiveTabs(due)
        if archived == 0 && stamped { save() }
        return archived
    }

    /// Closes these tabs (Splits by their first tab) into their profiles' archives: one write per profile, and
    /// only the tabs whose records were saved. Blank tabs just go. One sidebar update for the lot.
    @discardableResult func archiveTabs(_ ids: [UUID], at date: Date = Date()) -> Int {
        var groups: [(id: UUID, members: [UUID], tabs: [BrowserTab])] = []
        for id in ids {
            let group = session.split(for: id)
            guard group == nil || group?.primaryID == id else { continue }
            let members = group.map { [$0.primaryID, $0.secondaryID] } ?? [id]
            let tabs = members.compactMap { member in session.tabs.first { $0.id == member } }
            guard tabs.count == members.count, !tabs.contains(where: \.isSaved) else { continue }
            groups.append((id, members, tabs))
        }
        var closing: [(id: UUID, members: [UUID])] = groups.filter { $0.tabs.allSatisfy(\.isHome) }.map { ($0.id, $0.members) }
        let worth = groups.filter { !$0.tabs.allSatisfy(\.isHome) && BrowserLibrary.canArchive($0.tabs) }
        for profileID in Set(worth.map { session.profileID(for: $0.tabs[0]) }) {
            let mine = worth.filter { session.profileID(for: $0.tabs[0]) == profileID }
            // Nothing closes unless its record reached the archive (and disk, for a saved profile).
            if library(for: profileID).recordArchived(mine.map(\.tabs), at: date) { closing += mine.map { ($0.id, $0.members) } }
        }
        guard !closing.isEmpty else { return 0 }
        if closing.contains(where: { $0.members.contains(where: automaticDepartureQueue.contains) }) { cancelAutomaticDepartures() }
        for (id, members) in closing {
            let group = session.split(for: id)
            _ = session.close(id)
            if let group, let split = splitCoordinators.removeValue(forKey: group.primaryID) {
                split.detach(); split.view.removeFromSuperview()
                retiringViews.removeValue(forKey: ObjectIdentifier(split.view))
            }
            for member in members { teardownPage(member) }
            tabArchiver.knownToday?.subtract(members)
        }
        showActive(); save()
        return closing.count
    }

    /// `staying`: tabs whose page asked to stay (playing media or holding typed text).
    func archiveCandidates(staying: Set<UUID>) -> [TabArchivePolicy.Candidate] {
        let visible = Set(visibleMemberIDs)
        let downloading = downloads.activeSourceWebViews.map(ObjectIdentifier.init)
        let pip = pictureInPicture.referencedTabID
        return session.tabs.map { tab in
            let web = browsers[tab.id]
            let split = session.split(for: tab.id)
            return TabArchivePolicy.Candidate(
                id: tab.id, lastViewedAt: tab.lastViewedAt, isSaved: tab.isSaved,
                isVisible: visible.contains(tab.id) || tab.id == session.activeID,
                isPlayingMedia: staying.contains(tab.id),
                isCapturing: web.map { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none } ?? false,
                isPictureInPicture: pip == tab.id,
                isDownloading: web.map { downloading.contains(ObjectIdentifier($0)) } ?? false,
                hasPeek: peeks[tab.id] != nil,
                isRestorable: tab.isHome || BrowserLibrary.canArchive([tab]),
                splitPrimaryID: split?.primaryID)
        }
    }

    /// Text in a textarea that the page didn't start with (a comment, message or post being written).
    private static let typedTextProbe = """
    (() => { try { for (const e of document.querySelectorAll('textarea')) {
      if (!e.disabled && !e.readOnly && e.value.trim() !== '' && e.value !== e.defaultValue) return true;
    } } catch (_) {} return false; })()
    """

    /// Whether a page is playing media or holds typed text. A page that doesn't answer within three seconds
    /// (a hung or busy web process) stays too, and never stalls the sweep.
    private static func pageWantsToStay(_ web: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            final class Once { var done = false }
            let once = Once()
            let finish: (Bool) -> Void = { value in
                guard !once.done else { return }
                once.done = true; continuation.resume(returning: value)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(true) }
            web.requestMediaPlaybackState { state in
                if state == .playing { finish(true); return }
                web.evaluateJavaScript(typedTextProbe, in: nil, in: .defaultClient) { result in
                    if case .success(let value) = result { finish((value as? Bool) == true) } else { finish(false) }
                }
            }
        }
    }
}
