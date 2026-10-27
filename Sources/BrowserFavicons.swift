import AppKit
import WebKit

@MainActor extension BrowserController {
    /// Called only for rendered rows/tiles. A cache miss queues bounded work;
    /// neither the sidebar model nor command-palette typing waits on the network.
    func favicon(forTabID id: UUID) -> NSImage? {
        guard !isShuttingDown, let tab = session.tabs.first(where: { $0.id == id }),
              tab.chosenSymbol == nil else { return nil }
        let address = tab.isUnloaded ? (tab.saved?.address ?? tab.address) : tab.address
        // An icon carried over from Arc wins while the tab is still on that site.
        if let imported = importedTabIcons.image(for: id, address: address, profile: session.profileID(for: tab)) { return imported }
        guard let url = URL(string: address) else { return nil }
        // Imported tabs never reach their sites for an icon until the user
        // opens them; Bam's own cache may still answer.
        let dormantImport = browsers[id] == nil && importedTabIDs.contains(id)
        return favicons.image(for: url, profileID: session.profileID(for: tab),
                              allowFetch: !dormantImport && faviconNetworkAllowed(for: url))
    }
    /// Tab IDs created by any Arc import (from persisted provenance).
    var importedTabIDs: Set<UUID> {
        let links = session.importLinks ?? [:]
        if let cache = importedTabIDsCache, cache.count == links.count { return cache.ids }
        let ids = Set(links.values.compactMap { $0.hasPrefix("tab:") ? UUID(uuidString: String($0.dropFirst(4))) : nil })
        importedTabIDsCache = (links.count, ids)
        return ids
    }

    func favicon(forSiteURL url: URL, allowFetch: Bool) -> NSImage? {
        guard !isShuttingDown else { return nil }
        return favicons.image(for: url, profileID: commandProfileID,
                              allowFetch: allowFetch && faviconNetworkAllowed(for: url))
    }

    /// Native fixtures may display starter tabs but must not visit their sites.
    /// Real browsing (including a private preview) can load public site icons.
    private func faviconNetworkAllowed(for url: URL) -> Bool {
        guard CommandLine.arguments.contains(where: { OnboardingGate.testArguments.contains($0) }) else { return true }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    func configureFavicons() {
        sidebar.faviconProvider = { [weak self] in self?.favicon(forTabID: $0) }
        // The store is shared with second windows: the main browser owns its one callback and
        // passes each new icon to every window.
        guard primaryBrowser == nil else { return }
        favicons.onChange = { [weak self] _, _ in self?.sessionWindows.forEach { $0.scheduleFaviconRefresh() } }
    }

    private func scheduleFaviconRefresh() {
        guard !isShuttingDown, faviconRefreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.faviconRefreshWork = nil
            guard !self.isShuttingDown else { return }
            // Icon arrival must not rebuild rows, move keyboard selection,
            // save the session or interrupt a Space's in-flight animation.
            self.sidebar.refreshFavicons()
            self.tabSearchResults?.refreshFavicons()
        }
        faviconRefreshWork = work
        DispatchQueue.main.async(execute: work)
    }

    func invalidateFaviconDocument(_ id: UUID) {
        faviconDiscoveryWork.removeValue(forKey: id)?.cancel()
        faviconDocumentGenerations.removeValue(forKey: id)
    }

    func scheduleFaviconDiscovery(in web: WKWebView) {
        guard documentFaviconDiscoveryEnabled, !isShuttingDown, !web.isLoading,
              let id = browsers.first(where: { $0.value === web })?.key else { return }
        faviconDiscoveryWork.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self, weak web] in
            self?.faviconDiscoveryWork.removeValue(forKey: id)
            if let web { self?.discoverFavicon(in: web) }
        }
        faviconDiscoveryWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func discoverFavicon(in web: WKWebView) {
        guard documentFaviconDiscoveryEnabled, !isShuttingDown, !web.isLoading,
              let id = browsers.first(where: { $0.value === web })?.key,
              !pendingLoads.contains(id), tabErrors[id] == nil,
              let tab = session.tabs.first(where: { $0.id == id }),
              let page = web.url, WebsiteFaviconStore.originKey(for: page) != nil,
              faviconNetworkAllowed(for: page) else { return }
        let profile = session.profileID(for: tab), generation = UUID()
        faviconDocumentGenerations[id] = generation
        web.evaluateJavaScript(Self.faviconDiscoveryScript, in: nil,
                               in: WKContentWorld.world(name: "com.ari.bam.favicons.v1")) { [weak self, weak web] result in
            guard let self, let web, !self.isShuttingDown, self.documentFaviconDiscoveryEnabled,
                  self.faviconDocumentGenerations[id] == generation,
                  self.browsers[id] === web, !web.isLoading, web.url == page,
                  let current = self.session.tabs.first(where: { $0.id == id }),
                  self.session.profileID(for: current) == profile, current.address == page.absoluteString,
                  case .success(let value) = result, let result = value as? [String: Any],
                  let address = result["page"] as? String, URL(string: address) == page,
                  let candidates = result["icons"] as? [String] else { return }
            self.favicons.updateCandidates(candidates.prefix(12).compactMap(URL.init(string:)),
                                            for: page, profileID: profile)
        }
    }

    /// Read public icon declarations from the current document in an isolated
    /// world. No page script, cookies or full page contents cross this boundary.
    static let faviconDiscoveryScript = #"""
    (() => {
      const icons = [];
      for (const link of Array.from(document.querySelectorAll('link[rel]')).slice(0, 256)) {
        const rel = (link.getAttribute('rel') || '').toLowerCase().split(/\s+/);
        const regular = rel.includes('icon');
        if (!regular && !rel.includes('apple-touch-icon') && !rel.includes('apple-touch-icon-precomposed')) continue;
        try { if (link.media && !matchMedia(link.media).matches) continue; } catch (_) { continue; }
        const href = (link.getAttribute('href') || '').trim();
        if (!href) continue;
        let url;
        try { url = new URL(href, document.baseURI); } catch (_) { continue; }
        if (!['http:', 'https:', 'data:'].includes(url.protocol) || url.username || url.password) continue;
        if (url.href.length > (url.protocol === 'data:' ? 524288 : 8192)) continue;
        const sizes = (link.getAttribute('sizes') || '').toLowerCase().split(/\s+/);
        const square = sizes.map(s => /^(\d+)x\1$/.exec(s)).filter(Boolean).map(m => Number(m[1]));
        const fit = sizes.includes('any') ? 0 : square.length ? Math.min(...square.map(s => s >= 32 ? s - 32 : 128 + 32 - s)) : 64;
        // WHATWG data URLs can retain literal markup/Unicode alongside %22.
        // Foundation repairs such mixed URLs by escaping the % again. Encode
        // the unsafe characters here while preserving existing escape bytes;
        // the image payload is still decoded exactly once in the native store.
        const address = url.protocol === 'data:'
          ? encodeURI(url.href).replace(/%25([0-9a-f]{2})/gi, '%$1') : url.href;
        icons.push({ url: address, rank: (regular ? 0 : 1024) + fit });
      }
      icons.sort((a, b) => a.rank - b.rank);
      return { page: location.href, icons: Array.from(new Set(icons.map(i => i.url))).slice(0, 12) };
    })()
    """#
}
