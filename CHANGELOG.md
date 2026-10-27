# Changelog

## Unreleased

- Change Tab Icon… (Tabs menu and command bar) now works on every tab, not only kept ones: pick an icon and a name, and they stay with the tab if you keep it later.
- New tab actions, as in Arc: Duplicate (with its back/forward history), Rename… (leave it empty to go back to the page title), Mute / Unmute for a tab playing sound and Close Tabs Below. They're in the Tabs menu and the command bar.
- Point at a link and its address shows in a small capsule at the page's bottom-left corner, as in Arc.
- Fixed: after switching or editing Spaces, typing the letter "e" could open the Emoji & Symbols palette instead of typing. Shortcuts Settings no longer lists or rewrites the hidden menu items macOS adds on its own.
- Settings › Websites' page zoom and minimum font size now also apply in Peek and Little Bam (and minimum font size in Reading Mode), and a Peek or Little Bam page moved into a tab keeps its zoom. Site controls offer Reset only when the page is away from your default zoom.
- The command palette shows each command's current shortcut after you change or remove it in Settings › Shortcuts.
- ⌃⇥ now goes to the tab you used last, not the next one down. Keep holding ⌃ and press ⇥ again to bring up your five most recent tabs with page previews; release ⌃ to go there, ⌃⇧⇥ to step back, Esc to stay put.
- ⌘1 to ⌘8 jump to that tab in the sidebar, Favorites first, and ⌘9 jumps to the last tab (Tabs › Go to Tab).
- New tabs open at the top of Today. Links you open in a new tab land right below the page they came from, in the order you opened them, and closing one takes you to its neighbor from the same page, then back to that page.
- ⌘Z reopens the last closed tab when you're not typing, and closed tabs come back where they were instead of at the bottom.
- Bam now blocks ads and trackers on its own, on by default. It uses uBlock Origin's standard lists (EasyList, EasyPrivacy and more), refreshed weekly in the background, and stops requests before they're made. Turn it off for one site in the site controls, or everywhere in Settings › Privacy. If a page keeps failing to load, Bam offers "Allow Ads Here".
- Private windows: File › New Private Window (⇧⌘N) opens a dark window with a "Private" label and one set of tabs. It keeps no history, the command bar shows nothing you visited elsewhere, extensions stay off, and its cookies, logins and site data are wiped when you close it. It is never saved or reopened after a relaunch. ⌘W on its last tab closes it.
- Menu commands and shortcuts now act on the window in front, so ⌘T, ⌘L, ⌘W and the rest work in a private window as they do in the main one.
- Extensions from the Chrome Web Store and Firefox Add-ons now get Safari's extension address (safari-web-extension://), so services that already work with Safari extensions answer them. Raindrop.io's popup, blank before, now shows its sign-in. Extensions you already installed keep their address and their data.
- Raindrop.io, SponsorBlock, Calendly, Wappalyzer and Adblock Plus now install. Bam skips small manifest mistakes the way Safari does, reads script paths like "/js/app.js" the way Chrome does, and accepts larger extensions (up to 30,000 files and 512 MB unpacked).
- Todoist and Adblock Plus now start: Bam leaves out network-rule headers WebKit can't change instead of failing the whole update, and supplies the Chrome constants (like webRequest.ResourceType) extensions read at startup.
- Bam now blocks ads and trackers on its own, on by default. It uses uBlock Origin's standard lists (EasyList, EasyPrivacy and more), refreshed weekly in the background, and stops requests before they're made. Turn it off for one site in the site controls, or everywhere in Settings › General › Privacy. If a page keeps failing to load, Bam offers "Allow Ads Here".
- Copy Link (⇧⌘C) now copies a clean address: tracking tags like utm_, fbclid, gclid and YouTube or Spotify share codes are removed, and everything the page needs is kept. The confirmation says "Link copied".
- Copy Markdown Link (⌥⇧⌘C) copies [Title](address), and pastes as the page's title as a live link in Mail, Notes and Slack.
- Reading Mode (⌥⌘R): the article alone in one clean column over the page, opening at the paragraph you were reading. Choose text size (⌘+ / ⌘-), serif or sans, and a Light, Sepia, Dark or matching theme. ⌘F finds words in the article, and Esc or ⌥⌘R returns to the page exactly as you left it.
- Hide Elements (⇧⌘H): point at a cookie banner, ad or sidebar and click to make it crumble away. ⌘Z brings back the last, Esc finishes. What you hide stays hidden on that site from the first frame of every page; View › Restore Hidden Elements on This Site brings it all back.
- A new Develop menu: Show Web Inspector (⌥⌘I), Show JavaScript Console (⌥⌘J) and Inspect Element (⌥⌘C). Pages are also inspectable from Safari's Develop menu, and right-clicking a page offers Inspect Element.
- Peek has a new opening: the link you clicked turns into a dark pill, then a card springs out of it while the page behind dims slightly (the sidebar stays as it is). Close, Open in Tab, Split View and Little Bam sit beside the card as round buttons, and the address field shows the Peek's site while it's open. Closing shrinks the card back into the link; ⌘O grows it into the tab; ⇧⌘C copies its link.
- A Peek no longer flashes dark while its page loads: it shows the page behind's color until the new page draws.
- Little Bam has a simpler frame: a bar in its Space's color with one field for the login profile, the site, extensions and Copy Link, the Open in Space control beside it, and the page right below. It zooms out of the middle when it opens and shrinks away when it closes. Back, Forward and Reload stay on ⌘[, ⌘] and ⌘R.
- Floating video can be tucked away: throw or drag it past the left or right edge of the screen and it hides behind the edge with a blurred sliver and a chevron showing, while the sound plays on. Point at the sliver to pull it out a little; click it, press Return or use two fingers to bring it back.
- Floating video now flies out of its place in the page when it starts, and on close it is drawn back into the page before fading.
- Dragging floating video with the mouse now glides it to a corner (or the corner it was thrown toward) when you let go.
- A redesigned ⌘T/⌘L search box: a dark or light card washed with your Space's color, roomy rows written "Title — address", the selected row filled with the Space's color, and "Switch to Tab →" on open tabs. It appears instantly.
- It finishes addresses as you type ("git" → github.com, highlighted), and the site's icon replaces the magnifier. Press → or Tab to take it, Delete to drop it.
- Pages you visited before show up with your open tabs, without listing a page twice.
- An empty ⌘T lists your most recent tabs, the previous one first, so ⌘T then Return jumps back. ⌘L lists the current page first, with Copy Link at the end.
- Typing a sum like 12*(3+4) shows the answer first. Return copies it.
- Quick aliases open a fresh document, meeting or spreadsheet in a new tab: type "doc", "meet" or "sheet" (docs.new, meet.new, sheets.new and more).
- New keys in the search box: ⌘Return opens in a background tab, ⇧⌘Return in a new tab, ⇧⌘C copies the selected result's link, ⌘K shows actions for it (Open in Split View, Copy Link, Close Tab…), and Esc steps back before it closes.
- The search box finds the new page tools by name: Copy Link, Copy Markdown Link, Reading Mode, Hide Elements, Restore Hidden Elements, Web Inspector, JavaScript Console and Inspect Element.
- Search box fixes: address completion keeps a site's port and http (typing "localh" now finishes to localhost:3000), and pasted text is never completed. Typing a site's name such as "figma" or "notion" and pressing Return goes to the site instead of creating a new file. The selected row stays readable on yellow and green Spaces, sums like "0x10" or "1,5+1" no longer show a wrong answer, and typing stays quick with a full history.
- Settings is reorganized into General, Appearance, Websites, Privacy, Search, Spaces, Shortcuts, Extensions and About, with denser rows that are quicker to scan.
- A search field at the top of Settings (⌘F) finds any setting by name, and any command by name or keys (try "zoom" or "⇧⌘C"). Return jumps to the first result and highlights it.
- Every command in the menu bar can now have its own shortcut, not just seven. Settings › Shortcuts lists them by menu with a filter for names or keys. Pick a key another command already uses and Bam offers to move it. Each command can be reset to its default or left without a shortcut. Shortcuts you changed before carry over.
- Settings › Websites sets the zoom every page starts at (90%, 100%, 110% or 125%; ⌘0 returns to it) and a minimum font size for small text. It also lists the sites you keep awake, so you can add one by typing its address or remove one.
- Settings › Appearance shows each Space's color next to the light and dark theme, so you can recolor a Space without opening it.
- Settings › Privacy lists the sites where you've allowed ads, so you can block them there again.
- The window's close, minimize and zoom buttons now sit on the same line as the sidebar, back, forward and reload buttons, as in Arc.
- Tabs that never got a real title (often restored or imported ones) show the page's last known title, or its site name, instead of a long raw address. Titles also drop a trailing site name like "– Vercel" or "- YouTube".
- Sidebar rows follow Arc's sizes and spacing: 14-point titles, 16-point icons, the address and Favorites at Arc's heights, and long titles ending in "…" just before the close button.
- Every tab shows its close button when you point at it, the selected one included. Kept tabs that are open show a minus that puts the page to sleep and keeps the row; once it's asleep, the minus turns into a cross that removes the row (Reopen Closed Tab brings it back).
- The address at the top of the sidebar reads a little quieter, and a long address fades out at its end.
- The footer shows each Space as its emoji, the current one in color and the others in gray, spaced like Arc's and closing up when there are many.
- Tabs fade softly as they scroll under the Space name and above the footer, and a thin line sits over the footer while more tabs continue below.
- Reload and Stop swap with a quick scale.
- Auto-archive, as in Arc: Today tabs you haven't looked at for 12 hours close on their own and go to the archive. Choose 12 hours, 24 hours, 7 days, 30 days or Never in Settings › General. Kept tabs and Favorites are never archived, and neither are tabs playing media, in a call, in Picture in Picture, downloading or under a Peek. A Split is archived only when both sides are due. Bam checks at launch, on wake and every few minutes, and tabs from before this update start their clock when you upgrade.
- The archive has its own window (History › View Archive…, or "Archived Tabs" in the command bar). It lists tabs you closed and tabs Bam archived, grouped by day, with search, an "Archived" mark on the ones Bam closed, Restore on every row, and Clear Archive.

## 0.25.1 build 51 — Quit dialog and sidebar scroll bar polish

- The quit dialog is lighter and tidier: a cleaner heading, flat buttons, clearer Esc and Return keys, and everything lined up on one edge.
- The sidebar's scroll bar is thinner and sits in the gap beside the page, as in Arc, so it no longer covers tab titles or close buttons. It shows while you scroll and fades away, and pointing at the sidebar's edge to resize it no longer brings it up.

## 0.25.0 build 49 — Extension pop-out windows

- Extensions can open their own pop-out window at the size and position they ask for, and move or resize it later. It stays on screen and never gets smaller than Bam's small-window minimum.
- An extension's pop-out can show the extension's own pages. For example, Dark Reader's CSS editor now opens in its own window.
- Extensions that look for Chrome's app or devtools windows now get an empty answer instead of an error.
- Extensions still can't move or resize Bam's main browser window, or open new tabbed windows.

## 0.24.0 build 48 — Search, sidebar and everyday surfaces

- A wider, steadier search box that also finds browser actions, like Add Extensions, New Space or Import from Arc.
- A tidier sidebar that runs to its edge, with richer Space menus, folders that animate open and closed, and smoother tab dragging, including into Favorites.
- Downloads open as a compact list from the sidebar (⌘J), with progress, Open, Show in Finder and Cancel. Show All opens a thumbnail library.
- A redesigned quit dialog, with "Quit, and don't ask again" (Settings turns asking back on).
- Pinch to zoom webpages (⌘0 resets), and pinch to resize floating video.
- Site controls in the address field: connection, zoom, Keep This Site Awake, and which extensions can use the site.
- Extension search shows the Chrome Web Store build first, then Firefox. Safari extensions stay available.
- A guided setup: a short tour, an optional Arc import you preview first, and an optional password manager to find in Add Extensions.
- Not included: physical-gesture certification, emoji or gradient themes, new extension tab or window support, password-vault sign-in, or importing passwords or other browsers. See VALIDATION.md.

## 0.23.0 build 47 — Chrome compatibility

- Assign the verified Chrome Web Store ID to new store installs through the public native runtime API. Keep legacy installs, folder imports, unverified packages and Safari bundles on their existing installation IDs. Resource origins remain per-installation UUIDs.
- Resolve host authorization through exact loaded contexts and their profiles, and refuse duplicate verified runtime IDs within a profile.
- Scope notifications to their posting installation so old responses cannot reach a later reinstall with the same publisher ID.
- Disclose the verified ID in Manage Extensions. The identity checkpoint passed the full build and all eleven native suites. Session Buddy now exposes its Open controls and passes ordinary same-window save/restore.
- Map Chrome pinned-tab creation to real Bam kept tabs, with background selection preserved. Support lossless kept/ordinary updates, and refuse changes that would discard a Favorite, folder placement, customized saved metadata or Split membership. Native extension checks (460) and real Session Buddy kept-page restoration passed; multiwindow restoration remains incomplete.
- Add per-extension Site Access in Manage Extensions: withheld, specific requested sites, or all requested sites, never beyond what the extension requests. Install approves all requested sites; Enable keeps the stored choice; a canceled install's first approval still covers every requested site; an update asks only about new sites and declining cancels it. Changes are saved before they apply; a failed save changes nothing.
- A restart's release barrier also waits for a popup WebKit prepared and asked Bam to present, even when Bam declined to show it.
- An extension worker without Bam's native transport (after Revoke Permissions) keeps its top-level event listeners instead of failing to load. Its compatibility calls are still refused, and Bam's bridged events (idle, notifications, history, window bounds) aren't delivered while the transport is absent; WebKit's own messaging such as `runtime.onMessage` still works.
- Restart an extension when its website access is withdrawn (Site Access, Revoke Permissions, the extension's own `permissions.remove`, or a time-limited grant ending, noticed about a second after it expires). WebKit otherwise kept earlier content scripts and extension-page network access in running pages. The restart uses a fresh context with the same identity (storage is kept in persistent profiles only; private and other non-persistent stores reset) and reopens Bam tabs showing the extension's own pages. If it can't restart, Bam turns it off with "Enable it again"; if it can't even be stopped, Bam turns it off and asks you to quit and reopen Bam. If the reduced access can't be saved, Bam still restarts it without that access and says the change may be undone at the next launch. The fresh context loads only after the extension's old pages have closed (two-phase); if they don't close in time, Bam turns the extension off rather than keep that access; Enable brings it back once those pages are gone. If Bam also couldn't save that it's off, it is off only for now and may load again at the next launch. The fresh context loads only after the old extension pages Bam can track have closed; pages it can't track (outside Bam, or WebKit-internal) can keep earlier access.
- Chrome-style explicit consent: WebKit's implicit URL requests (tab and window reads, scripting, cookies, captures, failed CORS loads) are answered without a review, grant or denial. `permissions.request` keeps its review; only declined items the user saw are denied; answers made stale by a newer change (Revoke, a Site Access change or change-back, an update, a reload) are ignored. WebKit doesn't enforce Chrome's user-gesture rule for `permissions.request`.
- Give extensions holding `tabs` the tab address and title in `tabs.query/get/getCurrent`, populated windows, `tabs.onCreated`/`onUpdated` and `url`/`title` query filters, without site access. Supplementing is bounded, never repeats the extension's call and leaves WebKit's errors unchanged; tabs in several Little Bam windows, non-web pages and over-long values stay blank.
- Record no denial for refusals the user never saw.
- Validation at this draft: component suites pass. The full native Extensions suite passed at `4ed2f83` (818 checks), including explicit-consent withdrawal with no added delay, site access 158, tab metadata 58, the renderer fixture and worker revocation. On the final candidate, real Session Buddy (save, close and restore; This window Copy and Paste; all without site access) and Dark Reader (styling withdrawn after Site Access and Reload Pages, still enabled, clean cleanup) passed bounded checks; Session Buddy's browser-level Paste into a new window isn't supported. The full integrated build and all eleven native suites passed at `4ed2f83`; see VALIDATION.md.

## 0.22.1 build 46 — Arc import, folders and sidebar corrections

- Balance Favorites across rows and draw their artwork at 16 points on whole device pixels, avoiding enlargement of imported 32-pixel icons on Retina displays.
- Reconcile sidebar hover with the actual pointer after Space switches, row reuse, scrolling and key-window changes.
- Separate pointer and keyboard focus for folder rows; use original filled open/closed folder drawings and quieter disclosure controls.
- Simplify the footer around Downloads, Spaces and New Tab while keeping Space management, History, Recently Closed and Picture in Picture reachable.
- Hide inactive unsaved blank-tab placeholders from the sidebar without deleting session data; suppress legacy internal URLs in sidebar copy. Imported folders explain that they contain saved links rather than automatic updates.
- Release candidate verified at `8422e1f`: full build, native Interactions 173 and Features 371; Favicons 85 and Arc import 155 passed on the same production behavior at `b11ccba`. Manual footer, grid and folder-focus checks passed; see VALIDATION.md for scope and limitations.

## Development history included in 0.22.1

The following 0.22.0 and overnight extension entries record intermediate checkpoints. Their pending notes are historical; current results and remaining limitations are in VALIDATION.md.

### 0.22.0 build 45 — folders, Arc import, sidebar look

- Verified integration checkpoint `66cdd71`: full component build and all eleven native suites passed in canonical Bam Preview, including Features 369, Extensions 393 and Arc import 155. This supersedes earlier pending-runtime notes for changes included in that checkpoint: native cookie-event interception works, Easel references remain renderer-free, and icons/themes survive real relaunches. The isolated normal-profile probe also ran with explicit non-private flags and confirmed removal of its own store after its controllers and pages were released. Manual themed light/dark, rename/recolor, Space-return, recessed Favorite selection, monograms and narrow-title fade checks passed. No release or production-app replacement.

- Add folders to each Space's kept section: create (including around a tab), rename, nest up to 12 levels, collapse, reorder, move between folders and Spaces, and ungroup in place. A collapsed folder still shows the selected tab; Splits move as one row. Folder metadata is additive to session format 5 and damaged records repair without losing tabs.
- Add File ▸ Import from Arc… (also in Settings ▸ General). Bam reads Arc's `StorableSidebar.json` read-only, previews Spaces, folders, kept and Today tabs, per-profile Favorites, Splits and every limitation, then imports in one step. Imported pages stay asleep until opened; the window lands on a blank tab. Repeat imports add only new Arc items and keep local edits and removals. If saving fails, the import is undone and the outcome reported truthfully. Layout only: no passwords, cookies, history or extensions.
- Bring the sidebar closer to Arc and Yab: a lifted translucent address field with the extension control inside it, an extension row only when extensions are installed, three-column Favorites tiles, a quiet Space heading, emoji Space icons, outline-free selected rows, a softer page frame, readable indentation for deep folders and folder rows that slide open (not under Reduce Motion). Saved tabs that haven't been opened yet, including every imported row, read at full contrast (only memory-slept pages are quieted); each folder level gets its own indent (steps become small for very deep folders at the narrowest width); and folders show a disclosure chevron. In light appearance, Favorite tiles are recessed washes and the address field is softer, so the selected tab or tile is the one bright card; dark surfaces are unchanged. Pages without an icon yet show a letter mark — the first letter, number or emoji of the title, or of the site's name — on a soft disc tinted with the Space (neutral on shared Favorites) instead of the same globe everywhere; custom symbols and favicons still win. Folders recede to the tabs' weight: medium titles, outline folder glyphs in the main text color in both states, and chevrons that stay visible but quiet until the folder is hovered or focused. Long titles fade out softly at the end of the row instead of ending in "…"; when the close button appears on hover the text doesn't move — only the fade slides back to clear the button. The full title stays in the tooltip and for VoiceOver.
- Arc Space themes come over: each themed Space keeps Arc's light and dark colors, its two-color window gradient and its accent, eased only as far as needed for readable text and visible icons. The nearest flat Space color stays as the fallback (Spaces without a theme, unreadable themes, older sessions); picking another color, Prism or Clear replaces the theme. Spaces imported earlier get their theme on the next import unless their color was changed. Arc's grain, noise and vibrancy aren't reproduced.
- Arc Easels come over as labeled reference rows in their exact folder and position, with their names. Selecting one explains that its canvas stays in Arc; Bam doesn't import canvases or guess links to them.
- Imported Arc tabs show the icons Arc had cached for them, read from Arc's icon cache next to its layout file after the import is saved, and keep them after relaunch in a small private cache in Bam's support folder (memory only in disposable previews). An icon stays with its tab's imported site and login profile. Imported tabs don't fetch icons from their sites until opened.
- Drag sidebar rows: reorder kept and Today tabs and folders, drop on a folder to file a row inside it, drag a kept tab into Today to unkeep it, or drop a tab or folder on a footer Space icon to move it there (asking first when that reloads pages in another login profile). Drop lines and folder highlights appear only where the move is allowed; folders now open on mouse-up so they can be dragged.
- Add an Appearance preference (System, Light, Dark; System by default) in View ▸ Appearance and Settings ▸ General. Bam no longer forces dark: the browser window, Little Bam, Settings, onboarding, Peek, Space creation and the blank tab follow it, with a light look of pale per-Space washes, dark text and a lifted white selected tab. Dark mode looks as before. Picture in Picture stays dark.
- Canonical Preview validation now includes the full eleven-suite `4237403` checkpoint and the later `1551775` targeted runs (Extensions 418, Arc import 155), plus manual selected-Space import/repeat, repaired long-path header, folder drag and appearance checks. Successful-import undo, full VoiceOver and physical hover-motion coverage are not claimed; see `VALIDATION.md` for exact revisions and limits.

## Unreleased extension-compatibility draft (branch work, after 0.21.3)

- Read-only `history.search` with genuine `onVisited`/`onVisitRemoved` for extensions declaring `history` with an explicit grant (no add/delete/getVisits): the login profile's in-memory history, schema-validated query, documented subset matching, full-SHA-256 IDs, no invented counts, 4 MiB reply bound. History 13, compatibility 77; library hook (Arc owner) and canonical fixture pending.
- Read-only `bookmarks.getTree` for extensions declaring `bookmarks` with an explicit grant (no mutation methods or events): the extension's login profile's Favorites and Spaces with their kept tabs and folders, kept addresses, no Today/other profiles/Easels, bounded; refused when ungranted or private; installs reviewed earlier stay ungranted until re-review. Bookmark tree 16, compatibility 75; integration snapshot (Arc owner) and canonical fixture pending.
- Extension tab/window targeting is honored or refused before anything opens: Little Bam windows report `popup` (integration patch pending); `windows.create` refuses non-popup, maximized, full-screen and bounded requests; `tabs.create` refuses popup, other-profile or missing targets, insertions before existing tabs, and an end index that would count an exposed Peek. Targeting 10; canonical checks written (**not yet run**).
- Manage Extensions: the static-rule warning follows any error or message in a scrollable, accessible details area; affected rows are marked.
- Disclose static declarativeNetRequest rules WebKit may not enforce as written (request-method conditions; exclusions of every supported resource type): counts per declared ruleset ID with its default state, no rule text; vendor files and enabled rulesets unchanged. Audited once per version off the main thread at load (installs, reviewed updates, earlier installs), bounded reads, stored separately and replaced. Static audit 10; canonical DNR fixture install/relaunch checks written (**not yet run**).
- Refuse dynamic/session declarativeNetRequest updates that add a rule with a request-method condition (`requestMethods`/`excludedRequestMethods`): canonical runs (1f837bb, 483c54f) with compiled sentinels and server counts showed get-only and excluded-post rules blocking POST and post-only rules never matching. Same refusal forms as the excluded-types guard; static rulesets unchanged. Compatibility 73; canonical refusal assertions written (**not yet run**).
- Add a working `windows.onBoundsChanged` (WebKit lacks it; Session Buddy's worker startup failed on it, confirmed from its own logs). Committed moves/resizes of a profile's exposed windows signal that profile's extensions; payloads are WebKit's own `windows.getAll` windows whose bounds changed, with serialized baseline/signals. Engine event preserved. Compatibility 71; canonical shared-window and cross-profile fixture written (**not yet run**); Session Buddy action re-probe pending.
- Side-panel model (unexposed): local relative path contract (schemes, authority, decoded traversal, backslashes refused); disabled defaults hide a global panel without an active tab.
- Refuse dynamic/session declarativeNetRequest updates that add a rule excluding every resource type WebKit supports; WebKit turns such a rule into one that matches every request (measured: it blocked an XHR). Promise form rejects; callback form throws synchronously, since Bam cannot set `runtime.lastError`. Valid calls pass through unchanged; static rulesets untouched; method conditions not guarded yet. Compatibility 64; canonical assertions written (**not yet run**).
- Remove Bam's ineffective `runtime.lastError` shadowing for its shimmed APIs. WebKit's `runtime.lastError` is a native attribute Bam cannot set (measured `null` in pages and workers), so a failed shimmed call in callback form logs the error and calls back with no arguments; the promise form rejects with the message. Compatibility tests now assert no fake `lastError` is defined (61).
- Evidence: unmodified uBlock Origin Lite 2026.1021.1354 blocks requests matching its static rules in Bam once WebKit has applied them (root canonical repeated-round probe on a loopback page: all three targets blocked from round 2, control unaffected), after a startup gap of about 3–6 s in which requests pass. This is scoped loopback evidence, not a claim for all sites or rule types.
- Fix the cookie-change adapter natively: WebKit's `cookies.onChanged` attribute cannot be replaced by a defined property, so listeners reached WebKit's argument-less event (canonical diagnostics). Bam now overrides the listener methods on WebKit's own event object. Component checks model that precedence (61); native re-run pending. `runtime.lastError` exposure for shimmed callback failures is now measured instead of claimed.
- Add `runtime.onUpdateAvailable` (an event that never fires: Bam updates are user-initiated, reviewed and applied directly; there is no pending update and no background updater). Proton Pass 1.42.0's worker registered a listener unconditionally at startup and stopped with “undefined is not an object (evaluating 'r_.runtime.onUpdateAvailable.addListener')”, leaving its popup and settings blank in root's probe. Every other event Proton registers unguarded exists in WebKit. Compatibility checks pass (61); the canonical worker fixture registers the listener at start (**not yet run**); Proton is not yet re-probed.
- Deliver Chrome-shaped `cookies.onChanged` details. WebKit invokes these listeners with no argument (webkit.org/b/267514); Grammarly 14.1341.0's sign-in cookie watch threw “Cannot destructure property 'cookie' from null or undefined value” in root's probe. Bam diffs `cookies.getAll({})` snapshots on WebKit's own trigger and reports `{removed, cookie, cause}` with an inferred cause; real engine details pass through. Compatibility checks pass (52); a canonical worker fixture sets and deletes a loopback cookie in one profile (**not yet run**). Grammarly's signed-in behavior is not tested.
- Runtime status: root's canonical run at integration `d5b98b5` passed the extension suite (379) including this branch's fixtures through `scripting.ExecutionWorld`; entries below marked “not yet run” for those items are now verified there. With the `ExecutionWorld` fix, a signed-out Bitwarden 2026.10.0 probe no longer reports its autofill-injection error; only its intentional native-host refusals remain. Vault, account and real-credential behavior are untested. The uBlock Origin Lite path fix awaits the next batch.
- Accept a service-worker path with one leading `/` (root-relative, as Chrome does). uBlock Origin Lite 2026.1021 declares `/js/background.js` and failed Bam's preparation with “unsafe or non-local path”. Only that single slash is removed; `//`, `..`, schemes, queries, encoded separators and symlinks are still refused, and prepared paths are package-relative. Worker preparation passes 108 checks; on a copy of the official uBOL package, all three preparation steps now succeed and verify on repeat (file operations only). uBOL's runtime behavior is not yet probed.
- Supply `chrome.scripting.ExecutionWorld` (`ISOLATED`, `MAIN`) where WebKit's `scripting` lacks the enum. The canonical Bitwarden probe showed `executeScript` succeeding in every option shape, including Bitwarden's own, while `chrome.scripting.ExecutionWorld.ISOLATED` threw before injection. Compatibility checks pass (45); the canonical fixture now injects a packaged file with Bitwarden's options from both the prepared worker and an extension page (**not yet run**). Bitwarden autofill itself is not yet re-probed.
- Supply `requestIdleCallback`/`cancelIdleCallback` (only when WebKit lacks both, measured absent on macOS 27.0.1) in extension pages and the extension's isolated content-script world, for Proton Pass and uBlock Origin Lite scripts that call them unguarded. Not in workers (Chrome has none there) and never in a website's own world. Existing installs pick up the new content adapter through the byte-exact refresh, which now also recognizes the previous select-picker adapter. Idle semantics 9, content preparation 53 and compatibility 42 checks pass; the canonical-Preview assertions (content world, extension page, untouched website world, ordering/deadline/cancel, workers unchanged) are written but **not yet run**.
- Security: a Chrome Web Store build is now installed only as a CRX3 whose verified publisher key derives exactly the listing's extension ID. A plain ZIP from the store download, or a store candidate without a valid ID, is refused before unpacking and never reaches review or import (previously such a ZIP was accepted as an unverified direct download). Direct-link ZIP/XPI installs keep their disclosed unverified behavior. Catalog 113 and enumeration 90 checks pass; the installer check fails against the previous code.
- Add `fontSettings.getFontList` for extensions that declare `fontSettings` (Dark Reader's font picker reads it): the installed font families with localized names, through the reviewed compatibility bridge. Other `fontSettings` calls reject, because Bam has no font settings for an extension to read or change. Compatibility checks pass (40); the canonical-Preview worker check is written but **not yet run**, and Dark Reader has not been run.
- Refresh Bam's own service-worker adapter in installs prepared by an earlier Bam, so existing installs receive worker fixes such as the disposal symbols and `offscreen` without reinstalling. The adapter is rewritten only when every recorded preparation hash still verifies and the installed adapter is byte-exact to Bam's record (or already the new adapter after an interrupted refresh). Vendor scripts, manifest, grants and storage are unchanged, and a package that does not verify loads exactly as before. Worker-preparation suite: 91 checks (upgrade, no-op, interrupted-refresh repair, edited adapter/vendor script/backup/loader, symbolic link, other schema, classic and module). The canonical-Preview relaunch fixture (aged adapter, no-review relaunch, refreshed version visible in the worker, storage/grants/vendor bytes kept) is **not yet run**.
- Expose `tabs.detectLanguage`, which Bam had hidden even though its tab adapter and documentation claimed it. Dashlane asks for it (callback form, behind a feature check). The answer is the page’s recognizable text, else its `<html lang>`/`<meta http-equiv="content-language">`, else `und`, never the user’s own locale. Unlike Chrome, Bam samples the page (from an isolated world), so it needs access to that tab — a host grant or the tab’s `activeTab` grant — and discards a sample if the tab, document or access changed meanwhile. `tabs.captureVisibleTab` now also honors a tab’s `activeTab` grant (it checked only global grants before). Component checks pass; the canonical-Preview fixture check (callback, promise, missing-tab error) is written but **not yet run**.
- Define `Symbol.dispose`/`Symbol.asyncDispose` (only when absent, never replacing the engine's, as registry symbols shared by every same-origin extension realm) in extension pages and prepared service workers. Bitwarden's SDK client uses TypeScript `using` and wasm-bindgen dispose methods in its background (12 sites) and popup (17), which fail without them. JavaScriptCore component checks pass; worker and page fixture checks in the canonical Preview are written but **not yet run**, and Bitwarden itself has not been run.
- Review fix for `offscreen`: a document still loading is now owned by its slot, so `closeDocument`, revocation, disable and shutdown stop it immediately (its `createDocument` rejects) and a recreated document cannot be closed or replaced by the earlier load's late outcome. Docs now state the differences from Chrome (full extension APIs in the page, reasons validated but not enforced, no `AUDIO_PLAYBACK` auto-close). Offscreen state checks rise to 29 with deterministic stalled-load close/recreate/revoke cases; a canonical-Preview fixture stalls a real load on a silent loopback listener and checks close, no further replies, web-view release, recreate and revoke mid-load (**not yet run**).
- Add `offscreen` for extensions that declare it (Bitwarden, Proton Pass, uBlock Origin Lite and Claude reference it): one hidden extension page per extension in the same profile, with Chrome's argument checks and exact error messages, closed on close/revoke/disable/update/shutdown or a crashed web process. `runtime.getContexts` reports it. (An earlier note here said callback-form failures of Bam's shimmed APIs set `runtime.lastError`; native measurement showed WebKit's `runtime.lastError` cannot be set by Bam, so they log the error and call back without arguments.) Component checks pass (offscreen state 25, compatibility 36); the canonical-Preview worker fixture (create, worker↔page message, second-create refusal, getContexts, close, web-view release, five cycles, revocation, disable, profile separation) is written but **not yet run**. No vendor extension has been run with it.

## 0.21.3 unreleased draft — build 44

- Preserve early and late external URL-open requests in duplicate launches through an acknowledged, retryable handoff to the owning profile. Deduplicate transport retries without suppressing intentional repeated opens.
- Keep a handed-off URL's Little Bam key and in front: the owner now activates before opening the URL, and tags each duplicate launch's messages with a launch ID so that launch's late or retried focus-only messages cannot bring the main window back over Little Bam. Separate later launches still focus the main window.
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
