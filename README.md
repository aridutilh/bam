# Bam — 0.11.0 local draft

<img src="Resources/BamIcon.png" width="128" alt="Bam’s red burst sticker on a light pink tile">

An open-source macOS browser prototype built with Swift, AppKit, Core Animation, and WebKit. Bam explores a compact sidebar, Spaces, Peek, Split View, and floating video. It is an independent project, not affiliated with Arc, The Browser Company, or Yab, and does not claim feature parity with them.

The original application code is available under the [MIT license](LICENSE). The public source includes no extracted Arc artwork, animation frames, fonts, textures, binaries, or decompiler output. The approved app icon is a textured red burst sticker with a peeled corner on a light matte pink tile; [branding notes](docs/branding.md) record its generation and final refinement prompt. Sidebar controls use macOS SF Symbols, and the Spaces button uses an original native animation.

[Bam v0.6.0 prerelease](https://github.com/aridutilh/bam/releases/tag/v0.6.0) · [Previous Bam v0.5.5](https://github.com/aridutilh/bam/releases/tag/v0.5.5) · [Bam source repository](https://github.com/aridutilh/bam) · [Feature checklist](FEATURE-INVENTORY.md) · [Validation status](VALIDATION.md)

**Local draft: Bam 0.11.0 (build 25), unreleased.** Adds two Space appearances beyond the six flat colors: **Prism**, a slowly shifting spectrum, and **Clear**, a translucent window over a behind-window blur that lets the desktop show through. Both are picked wherever Space colors are (Manage Spaces, onboarding) and persist like any color; invalid persisted indices repair to flat colors so translucency only applies by choice. Also includes the 0.10.0 first-run onboarding: a full-screen stage window that welcomes with the popping burst icon, lets the new user pick their first Space's color (retinting the stage live with the same gradients the browser wears), name it and pick its symbol, optionally import favorites from Chrome's bookmarks bar, actually try ⌘T and ⌘S, offer the macOS default-browser confirmation, and finish with confetti. It is keyboard-first and skippable, honors Reduce Motion, can be minimized or closed (closing skips), appears only on a true first launch (existing profiles are grandfathered silently; fixtures and plain previews never see it), can be forced with `--onboarding` or `bash scripts/preview-onboarding.sh`, and can be replayed from Bam ▸ "Welcome to Bam…". The earlier quit-confirmation, sidebar-proportion, Favorites and performance changes remain included. See [VALIDATION.md](VALIDATION.md) for checks and limits.

**Previous local draft: Bam 0.9.0 (build 23), unreleased.** Adds a native “Are you sure you want to quit Bam?” confirmation to Cmd+Q, the app menu and Dock quit. Cancel/Escape leaves the live session running; accepting Quit waits for the latest session save and retains Retry/Cancel handling if saving fails. Fresh previews confirm too. Cancelling an automatic quit after the last window closes restores the main window. The preceding sidebar-proportion, Favorites and performance changes remain included. See [VALIDATION.md](VALIDATION.md) for checks and limits. Published and installed Bam remains 0.6.0; this draft is not installed or published.

Sleeping starts with ordinary static HTTP(S) documents idle for at least ten minutes and keeps the three most recent loaded pages warm. Saved tabs, Split members, PiP, media/capture, forms, scripts, interaction, history, previews, navigation, errors and unknown activity remain protected. Downloads pause sleeping. View → Keep This Site Awake exempts the exact current hostname; View → Sleep Idle Pages Under Memory Pressure toggles the policy. These preferences apply to the main browser, not Peek/Little Bam.

Sleeping retains a row and its current URL/scroll position. Selecting reloads that URL; it does not reset a kept tab to its saved original address. This first policy intentionally excludes most web applications rather than attempting to serialize arbitrary page state. All ten component and six final-package native suites passed. [Validation](VALIDATION.md) records test coverage and benchmark limits. No draft install, real-profile migration, push, tag or release occurred.

**Latest published prerelease: Bam 0.6.0 (build 19).** Spaces can be created, renamed, recolored, given an icon, reordered and removed through Manage Spaces. Changes are staged until Save; Cancel leaves the session unchanged. Removing a Space requires a destination for its tabs, and a tab row can move its page or whole Split pair to another Space. Space IDs and live tab identities remain stable. All seven component and five final-package runtime suites passed, including 268 feature checks with 61 for editable Spaces. A first runtime attempt exposed a test selector that expected a Split row’s primary title instead of its combined title; the selector was corrected and the final rerun passed. All 56 inputs match. Installation, signature/executable identity and migration checks passed, preserving all 13 existing tabs and session state. Native preview checks covered editing/cancel, creation, arrow reorder, ordered shortcut selection, moving a page and removing the empty test Space. Table-drag reordering, physical swipes and broader accessibility/theme coverage were not manually tested. This release does not add isolated sign-ins, Favorites, folders, tab reordering or import.

**Previous verified release: Bam 0.5.5 (build 18).** Copy and hard-refresh confirmations move to the active page’s bottom-right. The translucent burst card, pop animation, shortcuts, focus preservation and click-through behavior are unchanged. All seven component and five packaged runtime suites passed on the first attempt. Installation and tested-executable/icon identity passed, with all 13 tabs and existing layout/selection state preserved. Actual shortcuts showed both complete bottom-right messages on one main-window page; later dismissal was confirmed. Other page surfaces are covered by automated placement checks; broader themes, accessibility preferences and animation timing were not rechecked.

**Earlier rename: Bam 0.5.4 (build 17).** The rename preserved the legacy profile identifiers and all 13 tabs with their selection/sidebar/Split state. Seven component suites passed; the unchanged ZIP passed all five runtime suites on a second attempt, after an unisolated combined PiP playback/focus failure. Installation, executable/icon identity and native Bam branding checks passed. The persistent Dock pin’s Bam name and app path were verified in its original slot. See [validation](VALIDATION.md) for the failure and verification limits, and the [changelog](CHANGELOG.md) for earlier releases.

## Build and run

Requirements: macOS 14 or later, Xcode Command Line Tools with Swift, and Python 3 for the build helper and local test server.

```sh
bash build.sh
bash scripts/preview-draft.sh
```

The draft preview starts a fresh in-memory session with a nonpersistent website-data store. It does not install the app or migrate the normal profile. Use `BAM_PREVIEW_APP` to select a different locally built bundle.

The build targets the current host architecture by default, locally signs `Bam.app`, creates `Bam-macOS.zip`, and runs the model, motion, swipe, tab-search, find, library, sidebar-symbol rendering, virtualized-sidebar, session-writer and tab-resource suites. `BAM_ARCH` can override the architecture, and `BAM_BUILD_DIR` can override the build directory; the corresponding `ARK_*` and `ORBIT_*` variables remain fallback aliases, in that order. The release target is Apple Silicon; Intel compatibility has not been established. The app is a development build, not a notarized distribution.

No package dependencies are fetched by a normal build. A project-local VFS overlay handles a duplicate Swift module map in some Command Line Tools installations without changing the installed toolchain. No Arc installation, reverse-engineering tools, or private research files are needed.

Run the integrated local fixtures after building:

```sh
bash scripts/test-runtime.sh
```

This starts a loopback fixture server and runs the packaged app's WebKit, manual PiP, native interaction, automatic PiP, feature and tab-resource tests. Tests open native windows. Each run must exit successfully and emit exactly one matching terminal PASS; a subtest PASS or an early zero exit is insufficient. Fixture windows cannot trigger the normal last-window autoquit behavior. **Build 19 passed all seven component and five final-package runtime suites**, including 70 PiP positioning, 162 controller interaction, 85 automatic PiP and 268 feature checks (61 editable Spaces). All 56 source/resource/test/build inputs matched the final tested manifest. The final run followed a fixture-only Split-row selector correction; this was not a first-attempt full pass. [VALIDATION.md](VALIDATION.md) records the results and retains build 17’s unexplained first PiP return failure as historical evidence. These fixtures do not reproduce every device's physical input.

The bundled video is a generated test pattern. To regenerate it, install FFmpeg and run `bash scripts/generate-demo.sh`; FFmpeg is not needed for an ordinary build.

## Browser features in the local draft

- **Browsing and tabs:** URL entry, DuckDuckGo search, navigation history, reload/stop, zoom, titles, context menus, and reopen closed ordinary tabs.
- **Favorites and kept tabs (unreleased):** up to twelve shared Favorite tiles plus per-Space kept rows. Closing unloads a saved page; selecting wakes it. Original addresses and optional custom names/icons persist independently of the live page title and URL. Context menus edit, reset, convert or order saved tabs; removing retention leaves an ordinary tab. Closing a Split handles each member according to its own retention.
- **Sidebar and Spaces:** up to 32 editable Spaces with names, twelve icons, six colors and an explicit order. Manage Spaces stages changes for Save/Cancel; deleting a Space moves its tabs to a chosen destination. Tab-row menus move single pages or whole Split pairs, following the selected page when it moves. Per-Space selection, width/visibility, native resize/collapse and sidebar swiping persist. Footer overflow exposes every Space at narrow widths. The integrated fixture passed 61 editable-Spaces checks; limited native editing checks also passed.
- **Tab search:** ⌘T opens a palette before creating a tab. Type a URL/search or select an existing tab across Spaces using the arrows and Return. Existing-tab results include Space and URL labels; draft Favorite results use “Favorite · All Spaces” and custom saved names participate in search.
- **Peek:** Shift-click a link, or follow a cross-host link from a pinned page, to open a retained overlay. Close it or transfer the same page into a tab, Split View, or Little Bam.
- **Little Bam:** a compact browsing window with address/navigation controls and promotion into the main browser. HTTP(S) URLs delivered by macOS open here. Bam does not automatically make itself the default browser.
- **Split View:** two live pages, draggable divider, per-pane address/navigation controls, focused-pane commands, close-one-pane, and separate-into-tabs. Pair membership is saved.
- **Floating video:** tab/Space departure can move a playing video's existing page into a rounded, borderless panel with native hover controls for play/pause, ±10 seconds, mute/volume, Return to Tab, and resizing. The panel follows the video's aspect ratio. Selecting the source restores it. In the 0.4.0 prerelease, explicit Return also brings Bam forward, restores a minimized source window, dismisses a covering Peek, and focuses the correct Split pane. Hovering and scrolling with two fingers moves the panel. Build 12 directs fast flicks to a corner and attracts slow releases near corners while preserving free placement farther away. Automated checks passed, and one user confirmed the final quick-flick and corner-pull feel on build 12. Build 9 received positive limited feedback on the combined movement/Return/transition check; its assisted Return check alone does not establish cross-app activation. Automatic behavior can be disabled, and manual floating video is available.
- **Page tools:** find in page, full HTTP(S) URL copy, hard refresh, system printing, file-upload selection, and WebKit media permission prompts. Copy and hard refresh show a brief native confirmation pill without taking keyboard focus.
- **Downloads and local Library:** destination selection, progress, cancel, open/reveal, plus a durable visit list and recently closed records. History and recently closed records can be searched and cleared separately. This is not automatic tab archiving.

These are implementation subsets, not a complete browser compatibility claim. See the [working inventory](FEATURE-INVENTORY.md) for explicit acceptance criteria and remaining work.

## Controls

| Action | Control |
|---|---|
| New-tab palette / navigate current page | ⌘T / ⌘L |
| Choose / activate palette result | ↑ / ↓, then Return; Escape cancels |
| Close / reopen tab | ⌘W / ⇧⌘T |
| Peek a link | Shift-click |
| Open link in background / foreground tab | ⌘-click / ⇧⌘-click |
| Open link in Little Bam | ⌥⌘-click |
| Close Peek | Escape, ⌘W, close button or backdrop |
| Promote Peek to tab / Split | ⌘O / ⇧⌘O, or its buttons |
| New Little Bam window | ⌥⌘N while Bam is active |
| Promote / close Little Bam | ⌘O / ⌘W or Escape |
| Split with a new page | ⌥⌘= |
| Close one Split pane | Its × button |
| Separate Split into tabs | View → Separate Split into Tabs |
| Close entire Split group | ⌘W or its sidebar row close button; saved panes unload, ordinary panes close |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Copy current URL | ⇧⌘C — “Page copied” |
| Hard refresh | ⇧⌘R — “Hard refreshing…” |
| Print | ⌘P |
| Downloads / history | ⌘J / ⌘Y |
| Recently closed records | History → Recently Closed |
| Toggle / reset sidebar width | ⌘S / ⇧⌘S; double-click its right edge to reset |
| Resize / collapse | Drag the sidebar's right edge |
| Keep / stop keeping a tab | ⌘D, View menu or tab context menu; a Split row targets its left tab |
| Favorite / remove Favorite | ⇧⌘D, View menu or tab/tile context menu |
| Edit, reset or order a saved tab | Saved-tab context menu |
| Back / forward / reload or stop | ⌘[ / ⌘] / ⌘R |
| Next / previous tab | Control-Tab / Control-Shift-Tab; sidebar order, not MRU |
| Next / previous Space | Sidebar swipe, or ⌥⌘→ / ⌥⌘← |
| Select Space | ⌥⌘1…9 for the first nine in the current order; footer buttons or overflow menu |
| Edit Spaces | Tabs → Manage Spaces, the sidebar Space heading, or its stack button |
| Move tab or Split pair | Tab-row context menu → Move to Space |
| Manual floating video | ⌥⌘P or View → Picture in Picture |
| Automatic floating video setting | View → Automatically Show Playing Videos |
| Video demo | View → Open Video Demo |
| Return and select video tab | PiP Return to Tab button, R, or double-click the video background |
| Close floating panel without changing the selected tab | PiP × button or Escape |
| PiP playback / seek / volume / mute | Space / ← or → (10 seconds) / ↑ or ↓ / M; also native overlay controls |
| Move floating video (0.4.0) | Drag its background, or hover and scroll with two fingers; fast flick toward a corner, move slowly for free placement |
| Resize floating video | Drag its bottom-right grip; Tab to the grip and use arrow keys |
| Zoom | ⌘+ / ⌘− / ⌘0 |


Manage Spaces supports up to 32 entries. Choose a name, one of twelve symbols and one of six colors; drag a table row or use the arrows to reorder. Removing a Space requires another Space to receive its tabs, and the final Space cannot be removed. Save applies the staged plan to the latest tab metadata; Cancel discards it. These are organizational groups sharing one website-data store. Reordering changes navigation order, not the stored identities of Spaces or tabs. The draft uses session format 3, migrating versions 1–2 and treating legacy pinned tabs as kept tabs. Migration is forward-only: older builds do not understand the complete saved-tab state, and releases before 0.6.0 do not understand custom Space IDs. The fresh preview does not migrate the normal profile.

Copy and hard refresh target the page in the key browser window: the visible Peek, focused Split pane, Little Bam page, or main tab. They do nothing while an unrelated utility window or the floating-video panel is key. URL copy preserves the current HTTP(S) address, including its query and fragment.

Hard refresh asks WebKit to revalidate the page with its origin, including while a load is in progress. It does not promise an unconditional cache purge and does not clear cookies or other website data. “Hard refreshing…” confirms that a navigation request started, not that loading succeeded. In 0.5.5, the confirmation card sits at the active page's bottom-right, lets clicks pass through, and replaces itself on repeated commands. It holds briefly before fading and respects Reduce Motion.

## Motion and visual design

Sidebar resizing uses a 228-point preferred width, 164–500-point bounds, and an 82-point collapse threshold. Toggle easing lasts 80 ms with cubic control points `(0.25, 0.46, 0.45, 0.94)`. The original analytical spring driver preserves momentum when retargeted; Space paging uses response `0.30` and damping ratio `0.99`. Response describes the spring, not a fixed animation duration. Visible transitions run with the display's refresh cadence. Sidebar pages retain their rows and scroll positions across transitions; a new swipe takes over at the currently displayed offset. Version 0.5.2 selects the page on an explicit Space request or accepted swipe release, independently of sidebar settling, without the previous page-snapshot fade. Reduce Motion uses immediate endpoints.

Numeric tuning was informed by local behavioral research. The historical `RecoveredMotion.swift` filename does not imply that its Swift implementation is extracted source. Public code draws its own interface and uses system symbols. The Spaces symbol has its own hover tilt and selection pulse, with no copied geometry or animation keyframes. Reduce Motion applies to sidebar, paging, and symbol animations.

Space swipes tolerate small diagonal or vertical pickup noise before locking direction. Release velocity uses an 80 ms motion window; a tiny final packet does not erase the preceding flick. Established vertical scrolling remains available to the tab list. Automated checks cover these decisions; physical device feel requires a separate check.

Physical testing of v0.3.3 lost the follow-up events for all 12 tiny-start swipes in the captured sample. Version 0.3.4 also handles events in the native tab-list and sidebar receivers, requests horizontal responder forwarding, and processes each event object only once. A new physical sample completed all eight gentle swipes, including their movement, release and Space commit. That sample stayed on the monitored path; receiver-only recovery is covered by automated tests. Native vertical scrolling passed its fixture; broader physical vertical-scroll and device testing remain open.

For an intermittent swipe failure, View → Record Space Swipes (60 Seconds) starts a local diagnostic capture at `~/Library/Caches/Ark/space-swipe-diagnostics.jsonl`. It stops after 60 seconds or 5,000 records and replaces the previous trace only when explicitly started again. Capture is off by default. It records gesture values and routing decisions, excluding URLs, titles, tab identifiers, and page content; no trace is uploaded automatically.

The 0.4.0 media transition keeps the same live web view at its destination size. Static page and video snapshots cover the transfer while WebKit restores layout and completes a bounded rendering wait. Only the inert panel snapshot moves or changes size during Return; the live video viewport is not animated. A timeout cleans up stalled handoffs, and Reduce Motion skips the motion. At introduction, the controller suppressed its ordinary Space-content crossfade during this handoff; version 0.5.2 removes that Space-content fade altogether. One YouTube player rendered correctly in assisted checks on builds 9 and 11; build 11’s native Pause control was also checked. Build 9 received positive feedback on the combined movement, Return and transition check. Build 11’s physical feedback still asked for stronger corner attraction, prompting build 12. These are limited observations, not comprehensive device or player coverage. Build 12’s automated and installation checks passed, and the user accepted its corner movement tuning. That feedback does not verify build 12’s Return transition or cross-app activation. See [validation](VALIDATION.md).

Two-finger panel movement follows physical input and ignores the operating system’s inertial tail. Bam uses its own short velocity estimate. Build 12 directs a fast flick to a corner with deceleration. A wider local attraction zone also pulls slow releases toward nearby corners; positions farther away remain free. Automated checks passed, and one user physically confirmed the final quick-flick and stronger corner-pull feel. Other devices, scrolling preferences and display arrangements remain unverified. Release keeps the panel within visible display bounds. The motion was guided by an Arc reference; the implementation and tuning are Bam’s own. Movement and snapping do not activate Bam; explicit Return does. Placement is not saved across sessions, and edge hiding is not implemented.

## Page ownership and limitations

Floating video uses Bam's own `NSPanel` with reversible HTML5-video isolation in the existing `WKWebView`. It is not AVKit/system Picture in Picture. Detection covers accessible HTML5 video and same-origin frames; protected players and inaccessible cross-origin embeds may not work. Automatic behavior follows tab/Space departures, not macOS app occlusion. Manual PiP from Peek or Little Bam first promotes that page into a main tab.

Peek, Split, and Little Bam promotions transfer the existing view rather than intentionally reload it. A retained Peek lasts only for the current session. Split membership persists; divider position and focused side do not. After quitting, URLs and browser metadata restore, but full back/forward stacks, forms, page memory, and scroll state do not.

All Spaces share website cookies; editing Spaces does not create isolated browser profiles. The local draft separates shared Favorites from kept rows and ordinary tabs. It does not add per-Space Favorite collections or profile isolation. Local tab search has no network suggestions, history results, or general command execution. Find reports found/no match rather than an exact count and uses one shared query. Downloads are not resumed across app relaunch. The recently closed archive is metadata restoration, not a saved live page.

Important unfinished areas include isolated profiles, folders, general tab drag/reordering, browser import, automatic archive, broader safe sleeping for web applications, production private browsing, extensions, content blocking, password management, sync, Boosts, settings, and an updater. Force Click, Air Traffic Control rules, a system-wide Little Bam hotkey, and four-pane splits are also outside the current subset. WebKit reuse does not supply those browser-host features automatically.

## Local data

For compatibility with development sessions, the app still stores metadata under `~/Library/Application Support/OrbitPrototype/` and retains its original bundle identifier `com.ari.orbitprototype`. The diagnostic cache remains under `~/Library/Caches/Ark/`; these paths are intentional compatibility choices, not a separate application. Fixture URLs use `BAM_TEST_URL`, with `ARK_TEST_URL` and `ORBIT_TEST_URL` fallbacks; `scripts/test-runtime.sh` exports all three. To test a particular app bundle, use `BAM_TEST_APP` (`ARK_TEST_APP` and `ORBIT_TEST_APP` remain fallbacks). These compatibility names do not require a separate Ark or Orbit installation.

WebKit owns website data. Clearing Bam's visit list or recently closed records does not clear cookies or delete downloaded files. `--fresh-preview` uses ephemeral browsing/session state for development; it is not a complete user-facing private-window feature. Normal certificate verification remains enabled, and ordinary HTTP pages are allowed. Runtime operation does not read or modify Arc's installation or profiles.
