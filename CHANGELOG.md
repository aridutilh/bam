# Changelog

## Unreleased

Remaining work is tracked with acceptance criteria in [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md). An inventory item is complete only after its full behavior is verified.

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
