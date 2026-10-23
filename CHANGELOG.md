# Changelog

## Unreleased

Remaining work is tracked with acceptance criteria in [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md). An inventory item is complete only after its full behavior is verified.

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
