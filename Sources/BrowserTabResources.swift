import AppKit
import WebKit

extension BrowserController {
    var currentSleepProtectionHost: String? {
        guard let url = activeWebView?.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return url.host?.lowercased()
    }
    @objc func toggleAutomaticTabSleeping(_ sender: Any?) {
        automaticTabSleeping.toggle()
        if !privateMode { UserDefaults.standard.set(automaticTabSleeping, forKey: "AutomaticTabSleeping") }
        if !automaticTabSleeping { sleepTask?.cancel(); sleepPassID = nil }
        else if memoryPressure == .critical { beginAutomaticSleepPass() }
    }
    @objc func toggleSiteKeepAwake(_ sender: Any?) {
        guard let host = currentSleepProtectionHost else { return }
        if keepAwakeHosts.contains(host) { keepAwakeHosts.remove(host) } else { keepAwakeHosts.insert(host) }
        if !privateMode { UserDefaults.standard.set(keepAwakeHosts.sorted(), forKey: "KeepAwakeHosts") }
    }
    func startTabResourceMonitoring() {
        guard memoryPressureSource == nil else { return }
        if !privateMode {
            if UserDefaults.standard.object(forKey: "AutomaticTabSleeping") != nil {
                automaticTabSleeping = UserDefaults.standard.bool(forKey: "AutomaticTabSleeping")
            }
            keepAwakeHosts = Set(UserDefaults.standard.stringArray(forKey: "KeepAwakeHosts") ?? [])
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            self.memoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            if self.memoryPressure == .critical { self.beginAutomaticSleepPass() }
            else { self.sleepTask?.cancel(); self.sleepPassID = nil }
        }
        memoryPressureSource = source; source.resume()
    }
    func stopTabResourceMonitoring() {
        sleepTask?.cancel(); sleepTask = nil; sleepPassID = nil
        memoryPressureSource?.cancel(); memoryPressureSource = nil
    }
    func beginAutomaticSleepPass() {
        guard automaticTabSleeping, !isShuttingDown, sleepPassID == nil else { return }
        let token = UUID(); sleepPassID = token
        sleepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.sleepEligibleTabs { [weak self] in
                guard let self, self.automaticTabSleeping, self.sleepPassID == token else { return .normal }
                return self.memoryPressure
            }
            if self.sleepPassID == token { self.sleepPassID = nil; self.sleepTask = nil }
        }
    }
    func resourceCandidates() -> [TabResourcePolicy.Candidate] {
        let splitIDs = Set((session.splits ?? []).flatMap { [$0.primaryID, $0.secondaryID] })
        let visible = Set(visibleMemberIDs)
        return session.tabs.map { tab in
            let web = browsers[tab.id]
            let address = web?.url?.absoluteString ?? tab.address
            let host = URL(string: address)?.host?.lowercased() ?? ""
            return TabResourcePolicy.Candidate(id: tab.id, address: address, lastUsedAt: tabLastUsed[tab.id],
                isLoaded: web != nil, isVisible: visible.contains(tab.id) || splitIDs.contains(tab.id),
                isPictureInPicture: pictureInPicture.referencedTabID == tab.id,
                isSaved: tab.isSaved, isLoading: web?.isLoading ?? false,
                hasError: tabErrors[tab.id] != nil,
                hasPendingNavigation: pendingLoads.contains(tab.id) || tab.address != address || nonGetDocuments.contains(tab.id),
                hasRetainedPeek: peeks[tab.id] != nil || automaticDepartureQueue.contains(tab.id)
                    || (web.map { $0.superview != nil } ?? false),
                hasHistory: (web?.canGoBack ?? false) || (web?.canGoForward ?? false),
                siteKeepAwake: keepAwakeHosts.contains(host))
        }
    }
    /// Only the pressure provider is injected by the isolated runtime fixture;
    /// the same idle thresholds, probe and final guards run in production.
    @discardableResult func sleepEligibleTabs(pressure: () -> TabResourcePolicy.Pressure) async -> Int {
        var attempted = Set<UUID>(), count = 0
        while !Task.isCancelled, !isShuttingDown, view.window?.attachedSheet == nil, pressure() == .critical {
            let candidates = tabResourcePolicy.candidates(resourceCandidates(), now: ProcessInfo.processInfo.systemUptime,
                pressure: pressure(), hasActiveDownloads: downloads.activeCount > 0)
            guard let candidate = candidates.first(where: { !attempted.contains($0.id) }) else { break }
            attempted.insert(candidate.id)
            guard await sleepCandidate(candidate, pressure: pressure) else { continue }
            count += 1
            // Give WebKit and the pressure source time to observe each release.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return count
    }
    private func sleepCandidate(_ candidate: TabResourcePolicy.Candidate, pressure: () -> TabResourcePolicy.Pressure) async -> Bool {
        guard let web = browsers[candidate.id] else { return false }
        let snapshot = await tabActivityProbe.inspect(web: web, expectedURL: candidate.address)
        guard !Task.isCancelled, !isShuttingDown, view.window?.attachedSheet == nil, browsers[candidate.id] === web,
              let snapshot, web.url?.absoluteString == snapshot.url, !web.isLoading,
              web.cameraCaptureState == .none, web.microphoneCaptureState == .none,
              tabResourcePolicy.permitsSleeping(candidate, among: resourceCandidates(), activity: snapshot.evidence,
                now: ProcessInfo.processInfo.systemUptime, pressure: pressure(), hasActiveDownloads: downloads.activeCount > 0) else { return false }
        releaseSleepingPage(candidate.id, web: web,
            state: TabSleepState(address: snapshot.url, scrollX: snapshot.scrollX, scrollY: snapshot.scrollY))
        return true
    }
    func releaseSleepingPage(_ id: UUID, web: WKWebView, state: TabSleepState) {
        guard browsers[id] === web, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        tabActivityProbe.invalidate(web)
        navigationTokens.removeValue(forKey: id); browserExtensionOrigins.removeValue(forKey: id)
        observations.removeValue(forKey: id); browsers.removeValue(forKey: id); historyTitleFollowUps.removeValue(forKey: id)
        web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading()
        retiringViews.removeValue(forKey: ObjectIdentifier(web)); web.removeFromSuperview()
        pendingLoads.remove(id); pendingHome.remove(id); requestedAddresses.removeValue(forKey: id)
        tabErrors.removeValue(forKey: id); sleepRestores.removeValue(forKey: id); nonGetDocuments.remove(id); pendingNonGetDocuments.removeValue(forKey: id)
        session.tabs[index].address = state.address; session.tabs[index].sleepState = state
        refresh(); scheduleSave()
    }
    func restoreSleepingPage(_ web: WKWebView) {
        guard let id = browsers.first(where: { $0.value === web })?.key,
              let state = sleepRestores.removeValue(forKey: id), web.url?.absoluteString == state.address,
              state.scrollX.isFinite, state.scrollY.isFinite else { return }
        web.evaluateJavaScript("window.scrollTo(\(state.scrollX), \(state.scrollY)); void 0", completionHandler: nil)
        scheduleSave()
    }
}
