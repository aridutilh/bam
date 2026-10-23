# Ark 0.3.1

<img src="Resources/ArkIcon.png" width="128" alt="Ark’s crayon-drawn icon">

An open-source macOS browser prototype built with Swift, AppKit, Core Animation, and WebKit. Ark explores a compact sidebar, Spaces, Peek, Split View, and floating video. It is an independent project, not affiliated with Arc, The Browser Company, or Yab, and does not claim feature parity with them.

The original application code is available under the [MIT license](LICENSE). The public source includes no extracted Arc artwork, animation frames, fonts, textures, binaries, or decompiler output. The app icon is a crayon-drawn reinterpretation of Arc’s mark; [branding notes](docs/branding.md) record its source and generation prompt. Sidebar controls use macOS SF Symbols, and the Spaces button uses an original native animation.

[Download v0.3.1](https://github.com/aridutilh/ark/releases/tag/v0.3.1) · [Source repository](https://github.com/aridutilh/ark) · [Feature checklist](FEATURE-INVENTORY.md) · [Validation status](VALIDATION.md)

## Build and run

Requirements: macOS 14 or later, Xcode Command Line Tools with Swift, and Python 3 for the build helper and local test server.

```sh
bash build.sh
open Ark.app
```

The build targets the current host architecture by default, locally signs `Ark.app`, creates `Ark-macOS.zip`, and runs the model, motion, swipe, tab-search, find, and library suites. `ARK_ARCH` can override the architecture, and `ARK_BUILD_DIR` can override the build directory. The release target is Apple Silicon; Intel compatibility has not been established. The app is a development build, not a notarized distribution.

No package dependencies are fetched by a normal build. A project-local VFS overlay handles a duplicate Swift module map in some Command Line Tools installations without changing the installed toolchain. No Arc installation, reverse-engineering tools, or private research files are needed.

Run the integrated local fixtures after building:

```sh
bash scripts/test-runtime.sh
```

This starts a loopback fixture server and runs the packaged app's WebKit, manual PiP, native interaction, automatic PiP, and feature tests. Tests open native windows. The script manages its temporary server and files. [VALIDATION.md](VALIDATION.md) distinguishes available checks from actual results for this revision; all six build/component suites and all five packaged runtime suites passed again for v0.3.1 (11 suites total). The icon build also generated all ten standard macOS representations and passed strict code-signature verification. The installed About panel and home-page mark were also visually checked.

The bundled video is a generated test pattern. To regenerate it, install FFmpeg and run `bash scripts/generate-demo.sh`; FFmpeg is not needed for an ordinary build.

## Implemented browser features

- **Browsing and tabs:** URL entry, DuckDuckGo search, navigation history, reload/stop, zoom, titles, pin/unpin, context menus, and reopen closed tabs.
- **Sidebar and Spaces:** three fixed Spaces, remembered selection, persistent width/visibility, native resize/collapse, and horizontal swiping over the sidebar. The header and bottom controls stay fixed while tab collections follow the gesture.
- **Tab search:** ⌘T opens a palette before creating a tab. Type a URL/search or select an existing tab across Spaces using the arrows and Return. Existing-tab results include Space and URL labels.
- **Peek:** Shift-click a link, or follow a cross-host link from a pinned page, to open a retained overlay. Close it or transfer the same page into a tab, Split View, or Little Ark.
- **Little Ark:** a compact browsing window with address/navigation controls and promotion into the main browser. HTTP(S) URLs delivered by macOS open here. Ark does not automatically make itself the default browser.
- **Split View:** two live pages, draggable divider, per-pane address/navigation controls, focused-pane commands, close-one-pane, and separate-into-tabs. Pair membership is saved.
- **Floating video:** tab/Space departure can move a playing video's existing page into a floating panel. Returning to its source restores it; automatic behavior can be disabled. Manual floating video is also available.
- **Page tools:** find in page, full URL copy, system printing, file-upload selection, and WebKit media permission prompts.
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
| Open link in Little Ark | ⌥⌘-click |
| Close Peek | Escape, ⌘W, close button or backdrop |
| Promote Peek to tab / Split | ⌘O / ⇧⌘O, or its buttons |
| New Little Ark window | ⌥⌘N while Ark is active |
| Promote / close Little Ark | ⌘O / ⌘W or Escape |
| Split with a new page | ⌥⌘= |
| Close one Split pane | Its × button |
| Separate Split into tabs | View → Separate Split into Tabs |
| Close entire Split group | ⌘W or its sidebar row close button |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Copy current URL / print | ⇧⌘C / ⌘P |
| Downloads / history | ⌘J / ⌘Y |
| Recently closed records | History → Recently Closed |
| Toggle / reset sidebar width | ⌘S / ⇧⌘S; double-click its right edge to reset |
| Resize / collapse | Drag the sidebar's right edge |
| Pin / unpin | ⌘D or tab context menu |
| Back / forward / reload or stop | ⌘[ / ⌘] / ⌘R |
| Next / previous tab | Control-Tab / Control-Shift-Tab; sidebar order, not MRU |
| Next / previous Space | Sidebar swipe, or ⌥⌘→ / ⌥⌘← |
| Select Space | ⌥⌘1 / 2 / 3, or bottom buttons |
| Manual floating video | ⌥⌘P or View → Picture in Picture |
| Automatic floating video setting | View → Automatically Show Playing Videos |
| Video demo | View → Open Video Demo |
| Return floating video | Select source tab, Return Video, close panel, or Escape in panel |
| Zoom | ⌘+ / ⌘− / ⌘0 |

## Motion and visual design

Sidebar resizing uses a 228-point preferred width, 164–500-point bounds, and an 82-point collapse threshold. Toggle easing lasts 80 ms with cubic control points `(0.25, 0.46, 0.45, 0.94)`. The original analytical spring driver preserves momentum when retargeted; Space paging uses response `0.30` and damping ratio `0.99`. Response describes the spring, not a fixed animation duration.

Numeric tuning was informed by local behavioral research. The historical `RecoveredMotion.swift` filename does not imply that its Swift implementation is extracted source. Public code draws its own interface and uses system symbols. The Spaces symbol has its own hover tilt and selection pulse, with no copied geometry or animation keyframes. Reduce Motion applies to sidebar, paging, and symbol animations.

## Page ownership and limitations

Floating video uses Ark's own `NSPanel` with reversible HTML5-video isolation in the existing `WKWebView`. It is not AVKit/system Picture in Picture. Detection covers accessible HTML5 video and same-origin frames; protected players and inaccessible cross-origin embeds may not work. Automatic behavior follows tab/Space departures, not macOS app occlusion. Manual PiP from Peek or Little Ark first promotes that page into a main tab.

Peek, Split, and Little Ark promotions transfer the existing view rather than intentionally reload it. A retained Peek lasts only for the current session. Split membership persists; divider position and focused side do not. After quitting, URLs and browser metadata restore, but full back/forward stacks, forms, page memory, and scroll state do not.

The three Spaces share website cookies. Top tiles mirror visible tabs rather than a distinct Favorites collection; closing a pinned row removes it. Local tab search has no network suggestions, history results, or general command execution. Find reports found/no match rather than an exact count and uses one shared query. Downloads are not resumed across app relaunch. The recently closed archive is metadata restoration, not a saved live page.

Important unfinished areas include editable Spaces/profiles, true Favorites and kept-tab semantics, folders/reordering, automatic archive/sleep, production private browsing, extensions, content blocking, password management, sync, Boosts, settings, and an updater. Force Click, Air Traffic Control rules, a system-wide Little Ark hotkey, and four-pane splits are also outside the current subset. WebKit reuse does not supply those browser-host features automatically.

## Local data

For compatibility with development sessions, the app still stores metadata under `~/Library/Application Support/OrbitPrototype/` and retains its original bundle identifier. The test server variable is likewise still named `ORBIT_TEST_URL`; `scripts/test-runtime.sh` sets it automatically. These legacy names do not require a separate Orbit installation.

WebKit owns website data. Clearing Ark's visit list or recently closed records does not clear cookies or delete downloaded files. `--fresh-preview` uses ephemeral browsing/session state for development; it is not a complete user-facing private-window feature. Normal certificate verification remains enabled, and ordinary HTTP pages are allowed. Runtime operation does not read or modify Arc's installation or profiles.
