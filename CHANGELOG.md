# Changelog

## 0.12.1 — build 27

- Replace repeated extension surface-list reconstruction with one fresh list per window enumeration. Preserve ordering, active selection and live profile/controller/data-store ownership checks; direct tab actions resolve current state.
- Check for playing HTML5 video before taking an automatic-PiP snapshot. Video-free and paused pages skip compositor capture; manual PiP and final playback/cancellation checks retain their existing behavior.
- Add enumeration scaling/ownership regressions and real WebKit snapshot-count checks. Performance measurements are scoped in [the performance notes](docs/tab-performance.md).
- Integrate the fixes on top of 0.12.0, preserving onboarding, command-palette/site-search and Prism/Clear changes. The unrelated local Preview icon draft is excluded.

## 0.12.0 prerelease — build 26

Two parallel draft lines each used the 0.10–0.11 numbers; this merge renumbers them as one release. Both lines' entries follow.

### Onboarding and Space appearances line (formerly 0.10.0–0.11.0, builds 24–25)

- Add two Space appearances beyond the six flat colors: **Prism**, a slowly shifting spectrum (a 24-second curated hue cycle that skips the muddy yellow-green band; static under Reduce Motion), and **Clear**, which turns the window translucent over a behind-window blur so the desktop shows through. Both are picked anywhere colors are — Manage Spaces, the onboarding color step (with a rainbow and a glass swatch) — persist as ordinary colorIndex values, and carry fallback gradients so Space swipes still blend toward them. New Spaces cycle the flat colors only; sanitize repairs out-of-range indices to a flat color, so the appearances apply only by explicit choice.
- Add a first-run onboarding: a full-screen stage window with a popping icon welcome, Space color choice that retints the stage live, first-Space naming with symbol choice, optional Chrome bookmark-bar favorite import, interactive ⌘T/⌘S training, a user-initiated default-browser offer (Return skips; the change takes a deliberate click) and a confetti finale. Keyboard-first, with native minimize/close controls (close skips), Reduce Motion fades and a progress-dot/back cluster kept clear of the menu-bar corner.
- Gate onboarding to true first launches; existing profiles are grandfathered silently, fixtures never see it, and a welcome cut short by quitting returns on the next launch. `--onboarding` forces it anywhere (demo: `bash scripts/preview-onboarding.sh`), and Bam ▸ “Welcome to Bam…” replays it. Finishing updates the first Space and adds chosen favorites as unloaded Favorites within the cap; skipping changes nothing. Browser swipes and chrome menu items stand down while the stage is up.


### Command palette, login profiles and extensions line (formerly 0.10.0–0.11.0, builds 24–25)

- Redesign the command palette as a single translucent card in the system appearance: icon-led input row, separator, and Arc-style single-line results with a full-width accent selection, inline dimmed addresses and trailing Space labels. The forced-light card, heading and shortcut footer are removed.
- Offer Tab-to-search for nineteen sites (YouTube, Google, Google Maps, Gmail, Google Drive, Wikipedia, Amazon, Reddit, GitHub, X, Spotify, Netflix, IMDb, Hacker News, Stack Overflow, ChatGPT, Claude, Perplexity, DuckDuckGo). Typing a site name, domain or alias shows a trailing “Search <Site> ⇥” hint; Tab scopes the palette with a pill, bloom and interior wash in the site’s color, Return searches the site, and Backspace in an empty field removes the pill. Pasted URLs with paths, bare “www” prefixes and multi-word text never trigger the hint.
- Keep typed addresses out of remote autocomplete: URL-shaped text (a scheme, or a dotted single word, including the ⌘L-prefilled current address) never reaches a suggestion endpoint, and a generation counter drops in-flight responses once the query, scope or palette changes.
- Fetch debounced autocomplete suggestions while typing: site-scoped suggestions for engines with a suggestion endpoint, and DuckDuckGo suggestions after tab results otherwise. Suggestions are best-effort over the network and never block typing or submission.
- Local only; publication and installation remain on hold. See [VALIDATION.md](VALIDATION.md).

## Unreleased — 0.10.0 local draft, build 24

- Add named login profiles to Manage Spaces. Shared-profile Spaces intentionally share website data; separate profiles isolate cookies/local storage, Favorites, history/archive and extensions. Legacy sessions keep the existing Default store.
- Confirm before replacing loaded pages on a cross-profile move or Space reassignment; preserve cancellation, current metadata, Split pairs and source profiles when promoting Peek/Little Bam.
- Add the macOS 15.4+ WebKit extension runtime, per-profile host adapters, local-folder import, permission review/revocation, actions and own-origin setup tabs. Delay first navigation until restored extensions are ready. No Chrome Web Store/CRX/archive installer, updates or native messaging.
- Prepare Manifest V2 background scripts as an explicit UTF-8 page in the private package copy, preserving JavaScript bytes and the original manifest backup.
- Add loopback native tests for real website-data isolation and extension background/content/popup execution, plus a separate bounded vendor probe. Real vendor compatibility remains individually assessed.
- Keep notification compatibility out of the build after its experimental bridge failed inbound-message checks. Dashlane reaches onboarding; 1Password remains blocked, and neither vendor is certified for login/autofill.
- Bind internal Home navigation to the originating main-frame tab so a background profile cannot replace another profile’s active page.
- Final build: all twelve component suites pass; all eight exact-package native suites have passing results across reruns. Intermittent PiP focus and Space-state failures remain documented in VALIDATION.md.
- Keep the draft local; no installation, push, tag or release.

## Earlier local draft — 0.9.0, build 23

- Ask “Are you sure you want to quit Bam?” for application quit requests, including fresh previews. Cancel/Escape keeps the live session; Quit Bam proceeds through the existing asynchronous save barrier. Repeated requests share one pending decision.
- Retain the main window so cancelling last-window termination restores it. Ordinary Little Bam close and PiP Return keep their existing behavior.
- Preserve Retry, Cancel Quit and explicit Quit Without Saving on save failure. Local only; publication and installation remain on hold. See [VALIDATION.md](VALIDATION.md).

## Unreleased — 0.8.1 local draft, build 22

- Match the reference screenshot’s native point scale with 14-point sidebar labels, larger toolbar symbols, 36-point tab rows and four-column Favorites at normal sidebar widths. Narrow sidebars retain an adaptive grid.
- Give short page confirmations a 196 × 46-point footprint, 14-point text and 8-point page-edge insets. Keep Bam’s translucent burst shape, pop animation, bottom-right placement and click-through behavior; compact panes continue fitting the message.
- Preserve saved sidebar widths and native row reuse. Local only; installation and publication remain on hold. Verification is recorded in [VALIDATION.md](VALIDATION.md). All ten component and six native suites passed, followed by a limited native visual check.

## Unreleased — 0.8.0 local draft, build 21

Local only; publication and installation remain on hold. Includes the preceding 0.7.0 Favorites/kept-tabs draft. All ten component and six exact-package native suites passed; all 70 frozen inputs match. Independent reviews and the synthetic benchmark are detailed in [VALIDATION.md](VALIDATION.md) and [the performance report](docs/tab-performance.md).

- Virtualize sidebar rows with native table reuse, preserve per-Space scrolling, update only changed visible row content, and coalesce metadata chrome refreshes.
- Coalesce session snapshots on an ordered background writer. JSON encoding and atomic file replacement leave the main thread; asynchronous quit flush includes edits made while waiting and offers Retry/Cancel if saving fails.
- Add conservative pressure-driven sleeping for ordinary static HTTP(S) pages idle at least ten minutes. Keep the three most recent loaded pages, saved tabs, Split members, PiP, loading/failed pages, history, retained previews, non-GET responses and keep-awake sites protected. Active downloads block a sleep pass.
- Require fresh isolated-world activity evidence; protect forms, editable content, trusted interaction, executable scripts, frames, service workers, media and capture. Missing or stale evidence leaves the page alive.
- Preserve current URL and scroll on sleep; show a distinct sleeping row and reload on selection. Saved-tab Close/Reset still returns to its original saved address. Session format 4 accepts older formats; downgrade is unsupported.
- Defer background GET renderer-crash reloads until selection, and require explicit retry for terminated non-GET responses. Crash recovery cannot preserve already-lost renderer state.

Verification and measured limits are recorded in [VALIDATION.md](VALIDATION.md).

## Unreleased — 0.7.0 local draft, build 20

This is a local-only draft. Published and installed Bam remains 0.6.0; no draft install, real-profile migration, push, tag or release occurred. All seven component and five final-draft runtime suites passed, including 192 model and 325 feature checks (57 saved tabs and 61 editable Spaces); all 59 inputs match. A fixture-only correction moved the demo-video decoded-frame wait until after playback started, followed by a complete rebuild/rerun. Native fresh-preview checks verified Favorite creation, name/Heart editing by keyboard, cross-Space sharing, retained unload/reopen and conversion to a kept row. Physical trackpad behavior, a full twelve-tile grid and a broader accessibility matrix were not manually checked. See [VALIDATION.md](VALIDATION.md) for detailed evidence. `bash scripts/preview-draft.sh` opens the fresh nonpersistent preview; publication remains on hold for user approval.

- Separate up to twelve global Favorites from per-Space kept tabs. Shared tiles stay fixed while Space rows page.
- Retain saved tabs when closed: unload the live page, restore its original saved address, and keep its identity and optional name/icon. Selecting wakes it; Reset returns a live saved tab to its original page.
- Add saved-tab editing and earlier/later order controls. Favorite selection preserves the current Space; converting a Favorite to an ordinary or kept tab places it in the current Space. Favorites cannot join Split View or move between Spaces.
- Preserve each Split member's retention on close, remove ordinary members, and dissolve the group. Split-row keep actions explicitly name the left tab; the toolbar pin icon follows the focused pane and its command. Search uses custom saved names and labels Favorites as shared across Spaces.
- Migrate session versions 1–2 to format 3, interpreting old `pinned: true` as kept. Validate metadata, cap Favorites, and repair unloaded selections without deleting saved records. This is not a downgrade-compatible format.

Remaining work is tracked with acceptance criteria in [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md). An inventory item is complete only after its full behavior is verified.

## 0.6.0 prerelease — build 19

All seven component and five final-package runtime suites passed: model 120, motion, symbols 63, swipe 22 scenarios, search 20, Find, library 32; WebKit, PiP with 70 positioning checks, 162 controller interactions, 85 automatic PiP and 268 feature checks including 61 editable Spaces. The first runtime attempt stopped at a fixture selector that expected a primary-only Split title; the selector was corrected to match the intentional combined title, preserving the menu/action checks. No product change was needed, and the rebuilt final package passed the full rerun. All 56 inputs matched. Installation, strict signature, tested-executable identity and unchanged approved icon passed. Session-format-2 migration preserved all 13 existing tabs and their saved state. Native preview checks verified readable sheet layout, edit/cancel, creation, arrow reorder, ordered shortcut selection, moving a page and removing the empty test Space. Manual table drag, physical swipes and broader accessibility/theme checks remain unperformed.

- Add Manage Spaces through the Tabs menu, sidebar heading and stack button, with staged Save/Cancel, names, twelve symbols, six colors and a 32-Space limit.
- Reorder Spaces by table drag or arrows. Footer buttons/overflow, sidebar swipes and ⌥⌘1…9 follow the saved order.
- Remove a Space by moving its tabs to a chosen destination. Move a tab or whole Split pair from its row menu; moving the selected page follows it without replacing its tab identity.
- Persist stable integer Space IDs, explicit order and a never-reused allocation counter in session format 2. Migrate legacy Studio/Life/Explore sessions while retaining tabs, Split groups, remembered selection and sidebar preferences.
- Keep all Spaces in the existing shared website-data store. This adds no isolated profiles, true Favorites, folders, tab reordering or browser import.

## 0.5.5 prerelease — build 18

All seven component and five exact-package runtime suites passed on the first attempt, including 207 feature, 162 interaction, 85 automatic PiP and 70 positioning checks. All 54 inputs matched the tested manifest. Installation, strict signature and tested-executable/approved-icon identity passed; all 13 tabs and existing selection/sidebar/Split state were retained. Actual copy and hard-refresh shortcuts showed complete, readable bottom-right cards on one main-window page, and later dismissal was confirmed. Other surfaces have automated coverage; broader themes, preferences and frame-by-frame animation timing were not rechecked.

- Move copy and hard-refresh confirmation cards to the bottom-right of the active page, including the focused Split pane, Peek and Little Bam.
- Keep the translucent burst style, pop animation, messages, shortcuts, focus preservation and click-through behavior unchanged.
- Revise placement regressions for page surfaces, compact hosts, flipped/unflipped coordinates and resizing. This patch adds no link-hover URL display.

## 0.5.4 prerelease — build 17

All seven component suites passed. The unchanged release ZIP passed all five runtime suites on a second attempt; the first stopped at a combined PiP return playback/focus assertion whose cause remains unisolated. Installation, strict signature and exact tested executable/icon identity passed. All 13 tabs, active page/Space, sidebar and Split state were retained, and native main-window/menu/About checks confirmed Bam 0.5.4 build 17. Native Dock preferences verified one Bam pin at `/Applications/Bam.app` in the same slot, with other items unchanged; Dock pixels were not captured. Releases below retain their historical Ark identity and evidence.

- Rename the public application to Bam, package `Bam.app` with executable `BamBrowser`, and move the public repository to [aridutilh/bam](https://github.com/aridutilh/bam).
- Use the approved generated red burst sticker with a peeled corner on a light matte pink tile as `Resources/BamIcon.png`.
- Preserve bundle identifier `com.ari.orbitprototype`, profile directory `OrbitPrototype`, and the legacy `Ark` diagnostic cache path. Keep `ARK_ARCH`/`ARK_BUILD_DIR` as aliases for the new `BAM_ARCH`/`BAM_BUILD_DIR` overrides.

## 0.5.3 prerelease — build 16

Build 16 passed all seven component and five packaged runtime suites, including 207 feature checks (previously 137). New coverage checks top-right placement, compact-host text fit and confirmation lifecycle across replacement, cancellation and host changes. All 54 tracked source/resource/test/build inputs matched the isolated copy. Installation, strict signature and tested-executable identity passed; all 12 tabs and the original selection state were preserved. Actual copy/refresh shortcuts on one bright page showed complete, readable top-right cards, and later dismissal was confirmed. Broader themes, accessibility preferences and frame-by-frame pop timing were not visually measured. Earlier release evidence below remains historical.

- Restyle page-command feedback as a translucent native card with a subtle pointed comic-burst outline and a brief pop animation.
- Anchor the card at the top-right of the active page, including an individual Split pane, Peek or Little Ark.
- Preserve the existing confirmation text, shortcuts, click-through behavior, focus and accessibility announcements.

## 0.5.2 prerelease — build 15

Build 15 passed all seven component and five packaged runtime suites, including 162 controller interaction checks (previously 84). All 54 tracked source/resource/test/build inputs matched the isolated copy. New checks cover early warm-page attachment, cold navigation requests, retained document state, rapid requests/reversals, committed release and preview cancellation, and Split destinations. The installed app passed strict signature and tested-executable identity checks; all 12 tabs were retained and the original Space/selection was restored. Actual Space buttons reached the correct pages in two main-window Spaces, first on cold selection and then warmed. Post-fix presentation timing and physical trackpad behavior were not measured. Earlier release evidence below remains historical.

- Select the destination page on an explicit Space request or committed gesture release, while the sidebar spring finishes independently. Rejected gestures keep the current page.
- Remove the queued Space request and old-page snapshot fade. Retain cached WebKit views and their page state while handling rapid requests and reversals.
- Target the visible delay between sidebar movement and page selection; this does not promise instantaneous network loads or Arc speed parity.

## 0.5.1 prerelease — build 14

Build 14 passed all seven component and five packaged runtime suites, including 63 symbol-rendering checks at 1×/2×. All 55 source/resource/test/build inputs matched the isolated final copy; installation, strict signature and executable identity passed, and all 12 existing tab identifiers were retained. Native inspection in two main-window Spaces confirmed round ellipsis dots and the tint/proportions of favorite, toolbar and footer symbols. This is a limited static appearance check, not broader display or physical-animation coverage. The 0.5.0 results below remain historical evidence.

- Keep sidebar SF Symbols at their natural aspect ratio, so wide glyphs such as the ellipsis do not stretch into vertical bars.
- Apply color through native SF Symbol configuration instead of tinting an intermediate bitmap. Preserve disabled opacity and existing hover, focus and click behavior.
- Add a real 1×/2× symbol pixel regression suite to the build.

## 0.5.0 prerelease — build 13

Build 13 passed all six component and five packaged runtime suites, including 137 browsing-feature checks. The installed app passed strict signature and executable-identity checks; all 53 source/resource/test/build inputs matched the final isolated copy, and all 12 existing tabs were retained. Actual shortcuts on one installed main-window page confirmed full pill text, the copied URL, refresh and later pill dismissal. Multi-surface behavior is automated coverage; broader manual/accessibility checks remain open.

- Show “Page copied” after ⇧⌘C successfully copies the current full HTTP(S) URL, preserving query and fragment.
- Add ⇧⌘R Hard Refresh. Request WebKit origin revalidation even while loading, with a “Hard refreshing…” confirmation when navigation starts. This is not an unconditional cache purge or website-data reset.
- Route both commands to the key window's visible Peek, focused Split pane, Little Ark page, or main tab. An unrelated utility window or floating-video panel cannot act on a background page.
- Use one brief, click-through native pill near the page's top center. Repeated commands replace its message and restart its timer; fading is cancellable, keyboard focus stays unchanged, and accessibility announcements and Reduce Motion are supported.

## 0.4.0 prerelease — build 12

Build 12 passed all six component and five packaged runtime suites, installation, strict signature, executable identity and all 50 source/resource/build input comparisons; all 12 existing tab identifiers were retained. One user physically confirmed build 12’s quick corner flicks and stronger slow-release pull feel right. This is limited acceptance of the corner tuning; build 12 cross-app Return, transition feel and broader device coverage remain unverified. Build 11’s assisted YouTube check confirmed rounded rendering and native Pause, but physical feedback requested stronger corner attraction. Build 12 addresses that feedback with directed corner flicks and stronger local attraction while retaining slow free placement farther away; the user accepted the final corner strength. No Arc parity is claimed.

- Cover the existing web view during PiP entry and return until a bounded WebKit rendering wait completes. Animate an inert panel snapshot into the restored page instead of resizing live video, with cancellation, timeout cleanup and Reduce Motion support. Suppress the competing Space-content crossfade during this handoff.
- Make explicit Return reveal the source tab and Space, dismiss its retained Peek, restore a hidden or minimized browser window, activate Ark, and focus the correct Split pane. Silent restoration and Close/Escape do not request app activation.
- Move floating video by hovering and scrolling with two fingers, including over native controls. Build 12 sends fast flicks to a corner in their direction with deceleration. Expand the local corner magnet to 240 points so slow releases near corners also settle sooner; positions farther away remain free. Keep targets 8 points inside visible screen bounds. This independently implemented tuning follows the reference’s behavior rather than recovered constants.
- Normalize physical movement direction, ignore OS momentum, and cancel stale movement on reversal, resize, return or close. Fit release targets to visible display bounds.
- Retain actual-media rendering, cancellation, minimized Return, Peek and Split focus coverage. Build 12 passed 70 positioning, 84 controller interaction, 85 automatic PiP and 51 browsing-feature checks.
- Require exactly one suite-specific terminal PASS and a successful process exit in the runtime harness. Prevent fixture window closure from ending a test early, and add bounded watchdog/precondition handling without weakening Return assertions. Explicit foreground activation is confined to fixture setup; the post-Return checks receive no corrective activation.

## 0.3.4 — 2026-10-23

- Handle Space swipes in the native tab-list and sidebar scroll receivers as well as the local event monitor. Request horizontal responder forwarding and deduplicate repeated delivery of the same event object, while preserving native vertical and mouse-wheel scrolling.
- Address a dispatch gap observed during v0.3.3 physical testing: tiny initial movements reached the monitor, but later movement/release packets did not; gestures claimed immediately did receive their follow-ups. Earlier direct-adapter fixtures did not cover this delivery gap.
- Add 16 native receiver regression checks, bringing the controller interaction suite to 84. All six component suites and five packaged runtime suites passed for build 8.
- Keep diagnostic capture bounded and opt-in; include the receiver source and duplicate-delivery decision without recording page or tab data.
- Complete a limited physical check: eight of eight gentle swipes delivered movement/release events and committed a Space, compared with missing follow-ups for all 12 tiny starts in the earlier v0.3.3 sample. The new sample stayed on the monitored path; receiver-only recovery is an automated-test result. Other devices, broader vertical scrolling and subjective feel remain unverified.

## 0.3.3 — 2026-10-23

- Keep a Space swipe eligible through small vertical or diagonal pickup noise while preserving established vertical scrolling.
- Disable horizontal elasticity in the vertical tab list, removing the sideways row bounce that could be mistaken for a cancelled Space transition.
- Measure release velocity over a short time window, making short flicks consistent across coalesced events and small release-tail packets. Preserve deliberate reverse-flick cancellation.
- Exercise the actual native event adapter with local NSEvent fixtures, including window association, phase precedence, and flipped sidebar coordinates.
- Add an explicit, bounded local Space-swipe recording command for physical-device troubleshooting. Recording is disabled by default, stops after 60 seconds or 5,000 records, and excludes URLs, titles, tab identifiers and page content.

## 0.3.2 — 2026-10-23

- Replace the PiP title bar with a rounded video panel sized to the video's aspect ratio. Add native hover controls for Return to Tab, play/pause, ±10 seconds, mute, volume, and resizing, with keyboard access.
- Restore the page's original DOM layout before fading it back in, and guard immediate re-float transitions so stale callbacks cannot reveal the wrong state.
- Fix sidebar swipes that end as momentum begins, support precise unphased trackpad streams, and retain gesture capture when the pointer leaves the sidebar.
- Preserve in-progress Space positions and release velocity, promote existing sidebar pages at completion, and honor the latest rapid button/keyboard request. Drive visible animation updates from the display refresh and briefly crossfade single-page content where a snapshot is available.
- Replace the collapsed toolbar's hard-coded white background with readable dark chrome and resize its occupied height continuously during sidebar collapse.
- Extend native fixtures to exercise PiP controls, actual Space buttons, gesture routing, cancellation, and interrupted animation paths.

## 0.3.1 — 2026-10-23

- Add the colorful, crayon-drawn Ark app icon, inspired by a child drawing Arc’s mark from memory, with deliberately crooked geometry.
- Package standard macOS icon sizes for Finder, the Dock and the About panel; use the same artwork on the home page and in the README.
- Add the master PNG, generation prompt, provenance and reproducible native icon packaging script.

## 0.3.0 — 2026-10-23

First public Ark source release, continuing the local Orbit prototype.

- Rename visible app branding to Ark while retaining the previous profile identifier and storage location for existing tabs and website data.
- Publish the original Swift/AppKit/WebKit code under MIT, replace extracted artwork with system symbols and original native animation, and ship an original video fixture.
- Automatically float an accessible playing HTML5 video when leaving its tab or Space and return the same live page when revisiting it. Preserve manual PiP precedence, cancellation and multi-pane discovery.
- Add per-tab Peeks, Little Ark windows, same-page promotion and persistent two-pane Split View.
- Add cross-Space tab search with deferred tab creation, Find in Page, current-URL copying and focused-page command routing.
- Add managed downloads, durable local history, recently closed tabs, grouped Split restoration, file upload prompts and website media permission prompts.
- Correct keyboard focus during asynchronous video discovery, utility-window closing, preview visit history and current-URL preservation during promotion.
- Add independent review, model/component checks and integrated native runtime fixtures. See VALIDATION.md for the exact tested scope.

Known limits include shared cookies across the three fixed Spaces, no extension host or sync, limited video detection, two-pane splits only, and incomplete Arc/Yab parity. Builds are locally signed development applications, not notarized releases.
