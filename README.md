# Bam 💥

<img src="Resources/BamIcon.png" width="128" alt="Bam's red burst sticker on a light pink tile">

A small, fast, slightly obsessive macOS browser prototype. Native Swift + AppKit + WebKit, hand-tuned springs, zero Electron.

Bam explores the things that make sidebar browsers feel good: a compact sidebar with **Spaces**, a **Peek** overlay for glancing at links, **Split View**, a pocket-sized **Little Bam** window, and a **floating video panel** you can flick into a corner. It's an independent open-source experiment — not affiliated with Arc, The Browser Company, or Yab, and not claiming feature parity with any of them. Think of it as a love letter written in its own handwriting.

**Latest download:** [v0.12.1 prerelease](https://github.com/aridutilh/bam/releases/tag/v0.12.1) · [all releases](https://github.com/aridutilh/bam/releases) · [changelog](CHANGELOG.md)

**Released: Bam 0.12.1 (build 27).** This version includes Favorites, kept tabs, performance improvements, login profiles, a local extension host, the redesigned command palette with Tab-to-search, a full-screen first-run onboarding (replay it from Bam ▸ "Welcome to Bam…", or demo with `bash scripts/preview-onboarding.sh`), and two new Space appearances: **Prism**, a slowly shifting spectrum, and **Clear**, a translucent window that lets your desktop show through. See [CHANGELOG.md](CHANGELOG.md) and [VALIDATION.md](VALIDATION.md).

This patch reduces extension tab/window enumeration work and skips automatic-PiP page snapshots when no video is playing. See the [performance notes](docs/tab-performance.md) for measurements and limits.

## Try it

You'll need macOS 14+, the Xcode Command Line Tools (with Swift), and Python 3.

```sh
bash build.sh
bash scripts/preview-draft.sh
```

That builds for your machine, locally signs the app, and runs the component test suites on the way out. The preview uses a fresh in-memory session and temporary website data, leaving your normal profile alone. It's a development build — not notarized, tuned for Apple Silicon — so expect macOS to give you a look the first time you open it.

## What's in the box

- **Spaces** — up to 32 of them, each with a name, an icon, and a color. Create, reorder, recolor, and delete them in Manage Spaces; changes stage until you hit Save, and deleting a Space asks where its tabs should live next. Swipe the sidebar to glide between them.
- **Favorites and kept tabs** — up to twelve Favorite tiles per profile, shared across its Spaces, plus kept rows within each Space. Closing a saved page unloads it; selecting it wakes it. Names, icons, and original addresses stay saved, with edit, reset, and ordering controls in the context menu.
- **Login profiles** — assign the same profile to Spaces that should share logins, or separate profiles to keep website data, Favorites, history, and extensions apart. Existing Spaces keep the Default profile. Moving loaded pages between profiles asks before reloading them.
- **Local extensions** — Extensions → Manage Extensions imports unpacked extension folders with permission review. Runtime support needs macOS 15.4+. This is an experimental WebKit host: [extension notes](docs/extensions.md) describe what works and what does not.
- **A lighter browser** — sidebar rows are reused and chrome updates are coalesced; session files save on a background writer. Under critical memory pressure, ordinary static pages idle for ten minutes can sleep while the three most recently used loaded pages stay warm. Saved tabs, Splits, video, forms, scripts, and uncertain activity stay protected. See the [tab performance notes](docs/tab-performance.md) for the policy and its limits.
- **Tab search** — ⌘T opens a palette *before* making a tab. Type a URL or search, or jump to a tab you already have open in any Space. Fewer duplicate tabs, more smugness.
- **Peek** 👀 — shift-click a link to open it in an overlay without leaving your page. Like it? Promote it to a tab, a Split pane, or Little Bam. Done? Escape and it's gone.
- **Split View** — two live pages side by side with a draggable divider and per-pane controls. The pair sticks together in the sidebar and survives restarts.
- **Little Bam** — a compact companion window with its own address bar. When macOS hands Bam a link to open, it lands here instead of blowing up your main window; promote one with ⌘O when it earns the big screen. (Bam never makes itself your default browser behind your back.)
- **Floating video** — leave a tab while a video is playing and the video keeps playing in a rounded floating panel with hover controls. Flick it hard and it glides to a corner; drag it gently and it stays where you put it. Hit Return-to-Tab and Bam takes you back to the source. (This is Bam's own panel doing reversible HTML5-video tricks, not system Picture-in-Picture — protected players may refuse to come along.)
- **The usual suspects** — find in page, reopen closed tab, downloads, searchable history, hard refresh, printing, zoom, a little confirmation pill that tells you your ⇧⌘C actually copied the URL, and a confirmation before quitting.

Every one of those is a working subset, not a finished browser feature — the [feature inventory](FEATURE-INVENTORY.md) tracks exact acceptance criteria and what's left.

## Shortcuts you'll actually use

| | |
|---|---|
| ⌘T / ⌘L | Tab palette / edit current URL |
| Shift-click | Peek a link |
| ⌘O | Promote Peek or Little Bam to a tab |
| ⌥⌘= | Split with a new page |
| ⌥⌘N | New Little Bam window |
| ⌥⌘→ / ⌥⌘← | Next / previous Space (or swipe the sidebar) |
| ⌥⌘1…9 | Jump to a Space |
| ⌘S | Toggle the sidebar |
| ⌥⌘P | Float the current video |
| ⇧⌘C / ⇧⌘R | Copy URL / hard refresh |

<details>
<summary>The full list, for completionists</summary>

| Action | Control |
|---|---|
| Choose / activate palette result | ↑ / ↓, then Return; Escape cancels |
| Close / reopen tab | ⌘W / ⇧⌘T |
| Open link in background / foreground tab | ⌘-click / ⇧⌘-click |
| Open link in Little Bam | ⌥⌘-click |
| Close Peek | Escape, ⌘W, close button, or backdrop |
| Promote Peek to tab / Split | ⌘O / ⇧⌘O, or its buttons |
| Promote / close Little Bam | ⌘O / ⌘W or Escape |
| Close one Split pane | Its × button |
| Separate Split into tabs | View → Separate Split into Tabs |
| Close entire Split group | ⌘W or its sidebar row close button |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Print | ⌘P |
| Downloads / history | ⌘J / ⌘Y |
| Recently closed | History → Recently Closed |
| Reset sidebar width | ⇧⌘S, or double-click its right edge |
| Resize / collapse sidebar | Drag its right edge |
| Keep / stop keeping a tab | ⌘D or tab context menu |
| Favorite / remove Favorite | ⇧⌘D or tab context menu |
| Sleep idle pages / keep this site awake | View menu |
| Back / forward / reload or stop | ⌘[ / ⌘] / ⌘R |
| Next / previous tab | Control-Tab / Control-Shift-Tab (sidebar order) |
| Edit Spaces | Tabs → Manage Spaces, or the sidebar Space heading |
| Move tab or Split pair to a Space | Tab-row context menu → Move to Space |
| Automatic floating video on/off | View → Automatically Show Playing Videos |
| Return to the video's tab | PiP Return button, R, or double-click the panel |
| Close the panel, keep your tab | PiP × button or Escape |
| PiP playback / seek / volume / mute | Space / ← → (10s) / ↑ ↓ / M, plus hover controls |
| Move the panel | Drag it, or hover and two-finger scroll; fast flicks seek corners |
| Resize the panel | Drag its bottom-right grip (Tab + arrows works too) |
| Zoom | ⌘+ / ⌘− / ⌘0 |

</details>

## Honesty corner 🪞

Bam is a prototype, and it says so with its chest:

- **Profiles share deliberately.** Spaces assigned to the same profile share website data; use separate profiles for separate sign-ins.
- **Extension compatibility is limited.** Dashlane Firefox reaches its welcome screen; login and autofill remain unverified. 1Password is unsupported because required APIs are missing, and notification support is excluded. There is no Chrome Web Store integration or universal extension compatibility.
- **No** built-in content blocking, password manager, sync, general settings UI, browser import, user-facing private-browsing mode, or auto-updater.
- Relaunching restores your tabs and layout, but not scroll positions, form contents, or back/forward stacks. Sleeping a page during a session retains its URL and scroll position; waking reloads the page.
- Session migration is forward-only; older builds do not understand all of the saved-tab and profile metadata.
- Downloads don't resume after relaunch, and "recently closed" restores metadata, not a frozen live page.
- Intel Macs are unverified territory; the release target is Apple Silicon.

The [feature inventory](FEATURE-INVENTORY.md) has the full to-do list, and [VALIDATION.md](VALIDATION.md) records exactly what's been tested, how, and what hasn't.

## Nerd notes 🔬

- **Testing:** `bash scripts/test-runtime.sh` spins up a local fixture server and runs the packaged app through WebKit, PiP, native-interaction, and feature suites — hundreds of checks, real windows opening on your screen. Don't panic; that's the test.
- **Motion:** the sidebar and Space paging run on an analytical spring driver that preserves momentum when retargeted, and everything respects Reduce Motion. If a swipe ever misbehaves, View → Record Space Swipes captures a 60-second local-only diagnostic trace (gesture data only — no URLs, titles, or page content, and nothing uploaded).
- **Legacy paths, on purpose:** the bundle identifier is still `com.ari.orbitprototype`, app data lives in `~/Library/Application Support/OrbitPrototype/`, and the diagnostic cache in `~/Library/Caches/Ark/`. Bam grew out of earlier prototypes named Orbit and Ark, and keeping the old names means your tabs survive every rename. One day there'll be a tested migration; until then, the fossils stay.
- **Build knobs:** `BAM_ARCH` overrides the target architecture and `BAM_BUILD_DIR` the build directory. No package dependencies are fetched by a normal build.

## License & provenance

The original application code is [MIT licensed](LICENSE). The public source contains no extracted Arc artwork, animation frames, fonts, textures, binaries, or decompiler output — the interface is drawn from scratch with macOS SF Symbols, the motion tuning is Bam's own, and the burst-sticker icon is original (see the [branding notes](docs/branding.md) for its story).

Built with care, springs, and an unreasonable number of runtime checks. 💥
