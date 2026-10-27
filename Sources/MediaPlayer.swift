import AppKit
import WebKit

/// Watches one page's "making sound" state (WebKit's KVO-compliant `_isPlayingAudio`, the signal Safari's tab
/// speaker uses). Guarded: a WebKit without it simply never reports sound.
final class PageAudioObserver: NSObject {
    private weak var web: WKWebView?
    private let onChange: () -> Void
    private static let key = "_isPlayingAudio"
    init?(_ web: WKWebView, onChange: @escaping () -> Void) {
        guard web.responds(to: NSSelectorFromString(Self.key)) else { return nil }
        self.web = web; self.onChange = onChange
        super.init()
        web.addObserver(self, forKeyPath: Self.key, options: [.new], context: nil)
    }
    func invalidate() { web?.removeObserver(self, forKeyPath: Self.key); web = nil }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [onChange] in onChange() }
    }
}

/// Arc's sidebar player: while a tab you can't see plays (or was paused from the player), a small card above the
/// footer offers play/pause, previous/next (when the page has them) and mute; clicking it goes to the tab. It steps
/// aside while that tab's video floats in Picture in Picture, and while the tab itself is on screen.
@MainActor extension BrowserController {
    func watchAudio(of web: WKWebView, id: UUID) {
        audioObservers.removeValue(forKey: id)?.invalidate()
        audioObservers[id] = PageAudioObserver(web) { [weak self] in self?.audioStateChanged(id) }
    }
    func stopWatchingAudio(_ id: UUID) {
        audioObservers.removeValue(forKey: id)?.invalidate()
        if mediaTabID == id { mediaTabID = nil; mediaPausedFromPlayer = false; refreshMediaPlayer() }
    }

    private func audioStateChanged(_ id: UUID) {
        guard !isShuttingDown else { return }
        if isTabPlayingAudio(id) {
            // The most recent tab to start playing owns the player.
            mediaTabID = id; mediaPausedFromPlayer = false
        } else if mediaTabID == id, !mediaPausedFromPlayer {
            // Paused in the page (or ended): Arc keeps the player while the page still holds paused media.
            browsers[id]?.requestMediaPlaybackState { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.mediaTabID == id, !self.isTabPlayingAudio(id) else { return }
                    if state == .none { self.mediaTabID = nil }
                    self.refreshMediaPlayer()
                }
            }
        }
        // Rows show a speaker while their page plays.
        scheduleChromeRefresh()
        refreshMediaPlayer()
    }

    /// Recomputes the player from the current tab, PiP and audio state.
    func refreshMediaPlayer() {
        guard let id = mediaTabID, let tab = session.tabs.first(where: { $0.id == id }), browsers[id] != nil else {
            sidebar.setMediaPlayer(nil); return
        }
        // Steps aside while the tab is on screen or its video floats.
        let hidden = visibleMemberIDs.contains(id) || pictureInPicture.activeTabID == id
        guard !hidden else { sidebar.setMediaPlayer(nil); return }
        let playing = isTabPlayingAudio(id) && !mediaPausedFromPlayer
        let controls = mediaControls[id] ?? (previous: false, next: false)
        sidebar.setMediaPlayer(SidebarMediaState(tabID: id, title: tab.displayTitle, isPlaying: playing,
                                                 isMuted: isTabMuted(id), canPrevious: controls.previous, canNext: controls.next))
        probeMediaControls(id)
    }

    func connectMediaPlayer() {
        sidebar.onMediaPlayPause = { [weak self] in self?.toggleMediaPlayback() }
        sidebar.onMediaMute = { [weak self] in
            guard let self, let id = self.mediaTabID else { return }
            self.setTab(id, muted: !self.isTabMuted(id)); self.refreshMediaPlayer()
        }
        sidebar.onMediaSelect = { [weak self] in
            guard let self, let id = self.mediaTabID else { return }
            self.select(id)
        }
        sidebar.onMediaPrevious = { [weak self] in self?.pressMediaControl(next: false) }
        sidebar.onMediaNext = { [weak self] in self?.pressMediaControl(next: true) }
    }

    /// Pause suspends the page's media (WebKit's public suspend/resume), so play resumes exactly where it was;
    /// media the page paused itself is played again from the page.
    func toggleMediaPlayback() {
        guard let id = mediaTabID, let web = browsers[id] else { return }
        if isTabPlayingAudio(id) && !mediaPausedFromPlayer {
            mediaPausedFromPlayer = true
            web.setAllMediaPlaybackSuspended(true) { }
            refreshMediaPlayer()
        } else {
            mediaPausedFromPlayer = false
            web.setAllMediaPlaybackSuspended(false) { [weak self, weak web] in
                MainActor.assumeIsolated {
                    guard let self, let web else { return }
                    // Paused by the page itself: ask the page's paused media to play again.
                    web.evaluateJavaScript(Self.resumeMediaScript, in: nil, in: .defaultClient) { _ in }
                    self.refreshMediaPlayer()
                }
            }
            refreshMediaPlayer()
        }
    }

    /// Previous/next: the page's own controls (YouTube, Spotify, SoundCloud and players that label them).
    private func pressMediaControl(next: Bool) {
        guard let id = mediaTabID, let web = browsers[id] else { return }
        web.evaluateJavaScript(Self.controlScript(next: next, press: true), in: nil, in: .defaultClient) { _ in }
    }
    private func probeMediaControls(_ id: UUID) {
        guard let web = browsers[id] else { return }
        web.evaluateJavaScript(Self.probeScript, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case .success(let value) = result, let flags = value as? [String: Any] else { return }
                let found = (previous: (flags["previous"] as? Bool) ?? false, next: (flags["next"] as? Bool) ?? false)
                if self.mediaControls[id].map({ $0 != found }) ?? true {
                    self.mediaControls[id] = found
                    if self.mediaTabID == id { self.refreshMediaPlayer() }
                }
            }
        }
    }

    private static let previousSelectors = [".ytp-prev-button", "[data-testid=\"control-button-skip-back\"]", ".skipControl__previous",
                                            "button[aria-label=\"Previous\"]", "button[aria-label=\"Previous track\"]", "button[title=\"Previous\"]"]
    private static let nextSelectors = [".ytp-next-button", "[data-testid=\"control-button-skip-forward\"]", ".skipControl__next",
                                        "button[aria-label=\"Next\"]", "button[aria-label=\"Next track\"]", "button[title=\"Next\"]"]
    private static func selectorList(_ list: [String]) -> String {
        "[" + list.map { "'" + $0.replacingOccurrences(of: "'", with: "\\'") + "'" }.joined(separator: ",") + "]"
    }
    private static func controlScript(next: Bool, press: Bool) -> String {
        """
        (() => { for (const s of \(selectorList(next ? nextSelectors : previousSelectors))) {
            const el = document.querySelector(s);
            if (el && el.offsetParent !== null && !el.disabled && el.getAttribute('aria-disabled') !== 'true') { \(press ? "el.click();" : "") return true; }
        } return false; })()
        """
    }
    static let probeScript = """
        (() => { const find = (list) => list.some(s => { const el = document.querySelector(s);
            return !!el && el.offsetParent !== null && !el.disabled && el.getAttribute('aria-disabled') !== 'true'; });
          return {previous: find(\(selectorList(previousSelectors))), next: find(\(selectorList(nextSelectors)))}; })()
        """
    static let resumeMediaScript = """
        (() => { const media = [...document.querySelectorAll('video, audio')].filter(m => m.paused && !m.ended && m.currentTime > 0);
          media.sort((a, b) => b.currentTime - a.currentTime); if (media[0]) { media[0].play().catch(() => {}); return true; } return false; })()
        """
}
