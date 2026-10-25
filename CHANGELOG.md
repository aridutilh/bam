# Changelog

## Unreleased extension-compatibility draft (branch work, after 0.21.3)

- Supply `chrome.scripting.ExecutionWorld` (`ISOLATED`, `MAIN`) where WebKit's `scripting` lacks the enum. The canonical Bitwarden probe showed `executeScript` succeeding in every option shape, including Bitwarden's own, while `chrome.scripting.ExecutionWorld.ISOLATED` threw before injection. Compatibility checks pass (45); the canonical fixture now injects a packaged file with Bitwarden's options from both the prepared worker and an extension page (**not yet run**). Bitwarden autofill itself is not yet re-probed.
- Supply `requestIdleCallback`/`cancelIdleCallback` (only when WebKit lacks both, measured absent on macOS 27.0.1) in extension pages and the extension's isolated content-script world, for Proton Pass and uBlock Origin Lite scripts that call them unguarded. Not in workers (Chrome has none there) and never in a website's own world. Existing installs pick up the new content adapter through the byte-exact refresh, which now also recognizes the previous select-picker adapter. Idle semantics 9, content preparation 53 and compatibility 42 checks pass; the canonical-Preview assertions (content world, extension page, untouched website world, ordering/deadline/cancel, workers unchanged) are written but **not yet run**.
- Security: a Chrome Web Store build is now installed only as a CRX3 whose verified publisher key derives exactly the listing's extension ID. A plain ZIP from the store download, or a store candidate without a valid ID, is refused before unpacking and never reaches review or import (previously such a ZIP was accepted as an unverified direct download). Direct-link ZIP/XPI installs keep their disclosed unverified behavior. Catalog 113 and enumeration 90 checks pass; the installer check fails against the previous code.
- Add `fontSettings.getFontList` for extensions that declare `fontSettings` (Dark Reader's font picker reads it): the installed font families with localized names, through the reviewed compatibility bridge. Other `fontSettings` calls reject, because Bam has no font settings for an extension to read or change. Compatibility checks pass (40); the canonical-Preview worker check is written but **not yet run**, and Dark Reader has not been run.
- Refresh Bam's own service-worker adapter in installs prepared by an earlier Bam, so existing installs receive worker fixes such as the disposal symbols and `offscreen` without reinstalling. The adapter is rewritten only when every recorded preparation hash still verifies and the installed adapter is byte-exact to Bam's record (or already the new adapter after an interrupted refresh). Vendor scripts, manifest, grants and storage are unchanged, and a package that does not verify loads exactly as before. Worker-preparation suite: 91 checks (upgrade, no-op, interrupted-refresh repair, edited adapter/vendor script/backup/loader, symbolic link, other schema, classic and module). The canonical-Preview relaunch fixture (aged adapter, no-review relaunch, refreshed version visible in the worker, storage/grants/vendor bytes kept) is **not yet run**.
- Expose `tabs.detectLanguage`, which Bam had hidden even though its tab adapter and documentation claimed it. Dashlane asks for it (callback form, behind a feature check). The answer is the page’s recognizable text, else its `<html lang>`/`<meta http-equiv="content-language">`, else `und`, never the user’s own locale. Unlike Chrome, Bam samples the page (from an isolated world), so it needs access to that tab — a host grant or the tab’s `activeTab` grant — and discards a sample if the tab, document or access changed meanwhile. `tabs.captureVisibleTab` now also honors a tab’s `activeTab` grant (it checked only global grants before). Component checks pass; the canonical-Preview fixture check (callback, promise, missing-tab error) is written but **not yet run**.
- Define `Symbol.dispose`/`Symbol.asyncDispose` (only when absent, never replacing the engine's, as registry symbols shared by every same-origin extension realm) in extension pages and prepared service workers. Bitwarden's SDK client uses TypeScript `using` and wasm-bindgen dispose methods in its background (12 sites) and popup (17), which fail without them. JavaScriptCore component checks pass; worker and page fixture checks in the canonical Preview are written but **not yet run**, and Bitwarden itself has not been run.
- Review fix for `offscreen`: a document still loading is now owned by its slot, so `closeDocument`, revocation, disable and shutdown stop it immediately (its `createDocument` rejects) and a recreated document cannot be closed or replaced by the earlier load's late outcome. Docs now state the differences from Chrome (full extension APIs in the page, reasons validated but not enforced, no `AUDIO_PLAYBACK` auto-close). Offscreen state checks rise to 29 with deterministic stalled-load close/recreate/revoke cases; a canonical-Preview fixture stalls a real load on a silent loopback listener and checks close, no further replies, web-view release, recreate and revoke mid-load (**not yet run**).
- Add `offscreen` for extensions that declare it (Bitwarden, Proton Pass, uBlock Origin Lite and Claude reference it): one hidden extension page per extension in the same profile, with Chrome's argument checks and exact error messages, closed on close/revoke/disable/update/shutdown or a crashed web process. `runtime.getContexts` reports it. Callback-form failures in Bam's shimmed APIs now set `runtime.lastError` during the callback. Component checks pass (offscreen state 25, compatibility 36); the canonical-Preview worker fixture (create, worker↔page message, second-create refusal, getContexts, close, web-view release, five cycles, revocation, disable, profile separation) is written but **not yet run**. No vendor extension has been run with it.

## 0.21.3 unreleased draft — build 44

- Preserve early and late external URL-open requests in duplicate launches through an acknowledged, retryable handoff to the owning profile. Deduplicate transport retries without suppressing intentional repeated opens.
- Consolidate all branch testing into `/Applications/Bam Preview.app`, with `com.ari.bam.preview` and the stable `BamPreview` data namespace. Safely replace older preview bundles, refuse live/unrelated/symlink destinations, serialize installers and roll back failures. Preserve legacy preview data without importing it; never replace the installed Bam through these scripts.

- Restore original Bam construction artwork from the unshipped preview draft. Fresh previews and the isolated persistent preview use it; normal builds retain the production icon. Generate both ICNS packages at build time from authored PNG masters.
- Take an exclusive `flock` on each persistent profile’s `instance.lock` before opening session or WebKit state. Duplicate launches request focus from that profile’s owner, restoring hidden/minimized windows, and exit. Fresh previews and fixtures do not lock. I/O failures stop startup with an explanatory error instead of proceeding unguarded.
- Retain ownership through quit confirmation, cancellation and store teardown; process exit or death releases the lock without deleting its inode. Older Bam versions do not cooperate with this lock and must be quit before using the same profile.
- Unreleased draft prepared for review and merge. Installation follows review and merge; no tag or GitHub Release is part of this update. Validation is recorded in `VALIDATION.md`.

## 0.21.2 — build 43

- Hide the window's close, minimize and zoom buttons together with the sidebar, as Arc does: they fade out over the last 80 points of the collapse, so a collapsed sidebar leaves the page alone in the window, and they return as the sidebar slides back in.
- Retire the “A little space” start page. An empty tab is now a plain dark surface titled “New tab” (the address bar still reads “Search or enter URL”), and the History ▸ Home command (⇧⌘H) that navigated to it is gone. Existing tabs on that page keep working and simply show the blank surface.

- Preserve the native namespace receiver for detached `action.setIcon` / `browserAction.setIcon` calls inside an extension's own documents. Dashlane extracts this method; WebKit silently ignored that call and left the loading icon in place. Bam now lets the extension supply its orange/teal state without reading or guessing vault state.
- Verify the real vendor icon is orange in a signed-out probe and teal in the authenticated persistent preview; the optimized preview also fills both dummy values correctly.
- Keep prepared worker adapter bytes unchanged. Add focused API-shape and rendered toolbar-state checks; 26 component checks and 310 supported-path native checks pass. Missing iframe request events are reported separately and excluded from passed counts.

The earlier draft sections below are also included in 0.21.2; they were not separate published releases.

## 0.21.1 draft — build 42

- Add pointing-hand cursors to enabled sidebar buttons and selectable tab rows, including cursor invalidation when a control becomes disabled. Webpage cursor behavior remains under investigation.

- Normalize unavailable select-picker overlay styles only inside isolated extension content-script worlds, using native `select:open` state. This addresses Dashlane mistaking a closed page dropdown for an open overlay and dismissing its inline panel; genuinely open pickers remain detectable.
- Refresh only Bam’s recognized, byte-exact legacy content-script adapter in existing private packages. Vendor scripts, MAIN-world scripts and signed Safari resources remain unchanged.
- Record signed-in Dashlane popup search, manual creation of an invented login and inline filling on a control page without the dropdown. Picker compatibility passes 38 checks and content preparation/migration passes 51. Signed-in recreated standard/dynamic forms fill both dummy values exactly; full-page vault copy/paste also passes. Fresh-load classification and iframe injection remain open issues.

## 0.21.0 draft — build 41

- Add a separate, profile-scoped desktop connection review for the verified Chrome Web Store build of 1Password. Authenticate the official installed BrowserSupport helper and app, pin the reviewed host, bound message/connection queues, and close helpers on revoke, disable, update or shutdown. This transport is fixture-tested; real 1Password pairing and Touch ID remain unverified and require an Apple-signed Bam build plus vendor trust.
- Offer same-version publisher reverification for older 1Password installations while preserving their identity and storage. This does not automatically grant desktop access.
- Add **Refresh from Installed App** for Safari extensions, expose interrupted loads as needing recovery, and preserve identity/storage through refresh, cancellation and rollback.
- Clear compatibility diagnostics on unload/shutdown, bound individual messages, and add repeated real popup/bridge-release checks plus app memory phase observations.
- Add dummy login forms for the separate signed-in password/autofill pass. User account unlock and real vendor Safari testing remain pending.

## 0.20.1 draft — build 40

- Display SVG website favicons, including percent-escaped and base64 data URLs and public SVG files. Preserve existing URL escapes when bridging page declarations into native code. This fixes the missing disco-ball favicon on aridutilh.com.
- Rasterize SVG through a disposable WebKit image context with scripts and external resources disabled, bounded input/output, cancellation and timeout. Keep profile-scoped PNG caching and immediate replacement of cached misses.
- Add component and native sidebar/palette regression coverage using the actual inline emoji shape, plus malformed input, dimension limits and script isolation.

## 0.20.0 draft — build 39

- Fix empty extension popups on reopening: track the displayed popover and preserve the new web view when WebKit reuses an action. Add repeated dismissal/reopen checks with rendered HTML and background messaging.
- Extend Bam’s disclosed compatibility layer to classic and module service workers, including native requests and notification/idle events. Preserve classic worker URLs, module import URLs and original source bytes; check current profile, context and permission grants on every native operation. External native apps remain unavailable.
- Add Safari WebExtension import from an installed, verified Mac App Store containing app. Review permissions in Bam, keep the signed bundle intact, revalidate it on load and refresh it after app updates. New acquisitions still open Apple’s App Store; legacy Safari extension formats and native companion features remain unsupported.
- Adapt packaged WebAssembly streaming when WebKit supplies the wrong MIME type, retaining native compilation and CSP checks. Retain the managed-storage namespace wrapper so worker initialization does not lose its added members.
- Add original native worker and Safari fixtures plus component coverage for preparation, signature/snapshot checks, grants, events, Wasm and lifecycle behavior. Vendor account workflows still require separate validation.

## 0.19.1 draft — build 38

- Give the extension store selector and its opened choices Bam’s card surfaces, type, red selection and focus styling. Support keyboard selection, with Escape and outside-click dismissal leaving the current choice unchanged.
- Add more space around extension icons and store badges, with wider row insets and taller results.

## 0.19.0 draft — build 37

- Search Chrome Web Store, Firefox Add-ons and Safari Mac App Store sources inside one Bam extension library, with product icons, store marks, publisher, recommended source and permissions/details on demand. Exact known-product store identities combine Dashlane, 1Password, vidIQ and Bitwarden; unrelated products are kept separate. Individual source failures are shown without discarding successful results. Safari apps are App Store handoffs, and known-blocked Chrome Dashlane/1Password builds direct users to Firefox.
- Show enabled extensions below the main address bar with their own icons, labels and badges. Clicking opens the real WebKit action popup; the Extensions menu retains overflow and access with the sidebar collapsed. Actions follow the current tab/profile and close on context changes.
- Repeated Add/Enable reuses the installed build in that profile. Search is debounced and cancelable; closing the library cancels uncommitted installation work. Canceling an update review preserves the old running package, permissions and identity.
- Prepare a separate persistent Bam Extension Preview with its own bundle ID, preferences, session and WebKit stores, so development installs and sign-ins survive relaunch. Existing fresh previews remain disposable; no profile or vault data are migrated.

## 0.18.0 draft — build 36

- Add an extension library (Manage Extensions ▸ Add from Store or Link): paste a Chrome Web Store, Firefox Add-ons or direct package link, or search Firefox Add-ons by name. Each product is listed once with every build Bam knows about, its publisher, source, permissions and the reason Bam recommends a build; a different build can be picked. Packages are verified before unpacking (Mozilla’s published SHA-256 for Firefox Add-ons files; every RSA publisher proof and the derived ID for Chrome Web Store CRX3 files; direct links are marked unverified), then go through the existing permission review. The manager shows source, publisher and verification per extension.
- Add Check for Update: asks the installed build’s own source for a newer version and replaces the package in place after confirmation, keeping the extension’s identifier, storage and grants. Bam never switches an extension between stores.
- Add a compatibility layer for extension pages (HTML background, popup and options): `notifications` (macOS User Notifications with click/button/dismiss events), `idle`, read-only `privacy`, self-only `management`, `downloads` through Bam’s download coordinator, `commands`, empty `storage.managed`, and missing members of `runtime`, `webNavigation` and `action`. Installed only for extensions whose manifest requires those permissions (optional ones stay undefined until granted) and disclosed in the review as “Provided by Bam’s compatibility layer (limited)”. WebKit’s namespace wrappers are weakly cached, so the layer holds them; this made 1Password’s startup deterministic.
- Prepend a disclosed messaging adapter to isolated-world content scripts in the private package copy: WebKit never answers callback-style `runtime.sendMessage` from content scripts, which vidIQ, Dashlane and 1Password all use; the adapter routes those calls through the promise form. Extension JavaScript is unchanged and the original manifest is preserved.
- Implement `windows.create`/`remove`/`update` (as Little Bam windows), `tabs.detectLanguage`, `tabs.captureVisibleTab`, tab zoom and history navigation for extensions, and send the Safari user-agent suffix from extension pages so background fetches of sites match tabs (vidIQ now renders its YouTube overlay).
- Report page loads to extensions: `tabs.onUpdated` now fires with `status: "complete"` when a tab finishes loading (and `"loading"` when a navigation starts, including stops and failures), not only when its URL changes. Dashlane’s sign-in security check waited for that event, never asked the page for its Turnstile token, and showed “Something went wrong”.
- Vendor probes on fresh private profiles without sign-in: Dashlane injects into a loopback login form, vidIQ renders on a YouTube watch page, 1Password initializes and opens its welcome page. Sign-in, unlock and autofill remain untested; see [extension notes](docs/extensions.md).

## 0.17.0 prerelease — build 35

- Make the Keyboard section of Settings ▸ General editable: each keycap is a recorder. Click it, press a chord, and the menu item takes that key equivalent at once (New Tab, Open Location, Toggle Sidebar, Next and Previous Space, Keep/Unkeep Tab, Settings). Escape keeps the old chord, Delete restores the default, a chord another command already owns is refused with a red flash, and a “Reset all” pill returns every command to its default. Custom chords persist in UserDefaults; fresh previews never save them.
- Rebuild Settings ▸ Spaces as a list and one editor: a card lists every Space with its tile, name and a Current badge, and the editor below it shows the picked Space’s name field, labelled Color and Icon rows (with the colour’s name) and a “Switch to it” pill for a Space that is not on screen, instead of a full swatch-and-icon card per Space.
- Lay the Settings rail entries out by hand so the symbol sits inset from the picked pill instead of touching its left edge (it was clipped on every tab).
- Spell the About button “Welcome to Bam” in full, and drop the ellipsis from “Manage Spaces” in the Spaces footer.
- Recording a chord that a fixed menu item already wears (Quit, Close Tab, Go to Space 1…) is refused like one another remappable command owns; bare arrow and Page keys cannot be recorded (only F1–F35 may go bare); shifted chords keep the unshifted key. The welcome tour’s keycaps, the sidebar tooltips, Little Bam’s address hint and the palette badges all show the live chords.
- Fold in the code review of the onboarding restyle: the colour step keeps its glow when a swatch is clicked, the name field’s editor is no longer inset twice, its red hairline follows focus rather than the first typed character, the hello icon’s shadow follows the appearance, one headline helper serves the hello and finale titles, and dead accent parameters and state are gone.

- Restyle the first-run welcome in bambrowser.com’s look: the stage is Bam’s paper (pink, plum in dark mode, following the system) with a soft glow in the chosen Space colour and two faint bursts in the corners; headlines in Bricolage Grotesque (“The browser that goes Bam.” with a red “Bam.”), body in Instrument Sans; red lip-and-face pills, paper keycaps on a hard lip, ink-ringed colour swatches, red-washed picked icons, a “NEW!” sticker over the icon, and burst-shaped confetti on the finale. The step flow, keyboard handling, Chrome import, default-browser handoff and the `--onboarding` gate are unchanged.

## 0.16.0 prerelease — build 34

- Redress Settings and every secondary panel in bambrowser.com’s own look: matte pink paper in light mode and plum in dark (following the system appearance like the site), white cards with a hairline and soft shadow, sticker-red toggles, chips, pill buttons that sit on a deep-red lip, keycaps with a bottom edge, and the site’s version sticker on About. Manage Spaces, Extensions, Downloads and History/Recently Closed share the same paper, pills and red-wash table selection.
- Bundle the site’s typefaces, Bricolage Grotesque (display) and Instrument Sans (text), under the SIL Open Font License; Bam registers them for its own process at launch and falls back to the system fonts if they are missing.
- Rebuild Little Bam’s chrome: a translucent bar the traffic lights share, a login-profile chip, back/forward/reload, the site name in the middle (click or ⌘L to edit the full address), an Extensions button that pops this page’s extension actions, Copy Link (⇧⌘C), and an **Open in <Space>** button with ⌘O plus a menu that opens the page in any other Space. A Space on the same login takes the page itself; a Space on another login loads the address fresh there.
- Rename the compact window’s type to `LittleBamController`; the product name was already Little Bam.
- Give the page the whole window when the sidebar is away. The card’s margin, corner and border fade out continuously over the last 80 points of collapse, and the old strip with the address, sidebar toggle and keep button no longer appears; ⌘S or the View menu brings the sidebar back and ⌘L still opens the address palette.
- Open bambrowser.com in a single tab on the very first launch of an installed Bam, instead of the three-Space demo session with “A little space” tabs. The demo session remains the offline fixture for fresh previews and tests, and an existing session file is loaded unchanged.

## 0.15.2 prerelease — build 33

- Send Safari's user-agent suffix ("Version/<installed Safari> Safari/605.1.15") from tabs, Peek and Little Bam. A bare WKWebView already exposes FairPlay, but streaming sites such as Netflix, Spotify and Disney+ read the Safari token to choose their FairPlay playback path and can refuse playback without it. The suffix mirrors the installed Safari's version so it tracks macOS updates; Widevine and PlayReady remain unavailable, as in Safari.

## 0.15.1 prerelease — build 32

- Retain the published 0.15.0 Settings, default search engine and command-palette features.
- Reuse validated normalized tab-search fields and avoid sorting an empty query.
- Decode normal history files once, move visit encoding/atomic writes to a coalescing background writer, and wait for session plus history saves during quit. Explicit clear/archive operations retain synchronous durable results.
- Cache revision-bound extension tab topology and adapter arrays while checking live ownership on every access; Peek and Little Bam keep the uncached path.
- Resolve an extension backup's existing parent before validating its location, so macOS temporary-directory aliases cannot bypass the requirement to keep the backup outside the package.
- Preserve an already attached page or Split host during repeated presentation, including PiP callbacks, while still installing a replacement renderer under the same tab ID.
- Add a reproducible local renderer/cadence fixture and report the measured gains and remaining Arc/Yab gaps in [performance round 2](docs/performance-round2.md). The release preserves the existing background-page and tab-sleeping policies.

## 0.15.0 prerelease — build 31

- Add a Bam-styled Settings window (Bam ▸ Settings…, ⌘,): a Space-tinted stage with a section rail and translucent cards, built from the onboarding ink, pills and washes instead of Aqua controls. General holds playback and memory toggles plus a keyboard card; Search picks the default engine; Spaces edits each Space’s name, color and icon in place and links to Manage Spaces; Extensions lists the current profile’s extensions; About replaces the system About panel with version, welcome replay and links.
- Add a default search engine (DuckDuckGo, Google or Perplexity). Plain typed text goes to the chosen engine with the same single encoding; palette suggestions follow it. Persisted outside fresh previews.
- Let the command palette run browser commands by name: Settings, Manage Spaces, History, Downloads, Recently Closed, Extensions, New Little Bam Window, Toggle Sidebar, Find in Page, Picture in Picture, Print and Welcome. A typed command name (three or more characters) leads the results; looser matches trail the tabs so “se” or “hi” never hijacks a web search. Commands run through the responder chain once the palette closes.
- Dress Manage Spaces and the Extensions manager in the same wash, serif headings, ink labels and pill buttons; controls, names and fixtures are unchanged. ⌘W and Escape close the Settings window instead of a tab.
- Merged on top of the 0.14.0 favicon release and shipped as the v0.15.0 prerelease. See [VALIDATION.md](VALIDATION.md).

## 0.14.0 — Website favicons

- Display full-color website favicons in sidebar tab rows, Favorite tiles, existing-tab search results and site-scoped searches. Cached typed URLs show their icon without contacting an unsubmitted address.
- Discover declared page icons, including CDN-hosted images, with an origin `/favicon.ico` fallback. Load and decode asynchronously, cap concurrent requests and memory/disk storage, and isolate caches by login profile. Private previews use memory only; icon requests send no browser cookies or credentials.
- Refresh existing native rows in place, preserving search selection, custom saved symbols, Split glyphs and sidebar virtualization. Missing or unsupported images retain the native fallback.
- Include the separately committed Default-profile startup correction developed as local 0.13.2.


## 0.13.2 local startup fix, build 29 — included in 0.14.0

- Use WebKit’s default persistent extension configuration for Bam’s Default login profile. The existing internal Default ID is a reserved WebKit UUID value and crashes the identifier-based configuration initializer during ordinary startup. Preserve saved profile IDs, website data stores, cookies and tab sessions. Private and named-profile configurations retain their existing behavior.
- Add regression coverage for persistent Default configuration, alongside named and private profiles. This correction was verified as a local build; it is included in 0.14.0 rather than published under a separate tag.

## 0.13.1 — build 28

- Replace repeated extension surface-list reconstruction with one fresh list per window enumeration. Preserve ordering, active selection and live profile/controller/data-store ownership checks; direct tab actions resolve current state.
- Check for playing HTML5 video before taking an automatic-PiP snapshot. Video-free and paused pages skip compositor capture; manual PiP and final playback/cancellation checks retain their existing behavior.
- Add enumeration scaling/ownership regressions and real WebKit snapshot-count checks. Performance measurements are scoped in [the performance notes](docs/tab-performance.md).
- Integrate the fixes on top of 0.13.0, preserving overscroll Space creation, onboarding, command-palette/site-search and Prism/Clear changes. The unrelated local Preview icon draft is excluded.

## 0.13.0 prerelease — build 27

- Create Spaces the Arc way: overscrolling past the last Space fills a circled plus; completing the pull and releasing opens a sidebar creation panel with a native stacked-cards illustration, name field, profile picker and theme swatches that live-preview the Space gradient. Create switches to the new Space; Escape, Cancel or any Space change dismisses without creating.
- A partial pull springs back without creating, cancellation abandons even a completed pull, overscroll on the leading edge or a middle Space never offers creation, and reduced motion skips the pop animations.
- The new Prism and Clear appearances join the six flat colors in the creation panel's theme swatches; new Spaces still default to cycling the flat colors.
- Shipped as the v0.13.0 prerelease. See [VALIDATION.md](VALIDATION.md).

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
