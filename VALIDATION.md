# Validation — Ark 0.3.4

Status: **automated checks and a limited physical swipe check passed**, on October 23, 2026. Version 0.3.4 (build 8) was built on Apple Silicon using Swift 6.2.3 in Swift 5 language mode from an isolated copy of the publishable source files. No Arc installation, private research, or extracted assets were required. All six component suites and all five packaged runtime suites passed against this bundle. A subsequent physical sample completed eight of eight gentle swipes. This is limited evidence for the scroll-dispatch fix, not a general reliability or Arc-feel claim.

Independent agents implemented and reviewed the changes with separate file ownership. Receiver review checked shared routing, same-event deduplication, cached sidebar pages, horizontal-only forwarding and preserved vertical handling. The new fixture exercises receiver entry points directly; it does not establish that real AppKit trackpad dispatch follows the same path. The separate physical capture and its limits are described below.

## Build and component checks

Run `bash build.sh`. The script compiles for the current host architecture with a macOS 14 minimum, locally signs the application, verifies the signature, packages it, and runs these suites.

| Check | Scope | 0.3.4 |
|---|---|---|
| App build and strict signature verification | Swift/AppKit/WebKit/QuartzCore, generated bundle and ZIP | Passed |
| `Tests/main.swift` | URL/search rules, model repair, tabs, remembered Space selection, session persistence and internal demo route | Passed — 69 checks |
| `Tests/MotionTests.swift` | Unit-mass spring math, endpoints, critical/overdamping, velocity continuity, cancellation/replacement, cubic easing, original symbol animation profiles | Passed |
| `Tests/SpaceSwipeTests.swift` | Axis locking, noisy pickup, coalesced-event/release-tail flicks, deliberate reversals, live handoff, edge resistance, phases, cancellation and momentum | Passed — 20 scenarios |
| `Tests/TabSearchTests.swift` | Matching, ranking, Space labels, keyboard selection and activation | Passed — 15 checks |
| `Tests/FindTests.swift` | Actual WebKit literal find, next/previous wrapping, no-match feedback, cancellation and retargeting | Passed |
| `Tests/LibraryTests.swift` | Durable visit/closed-tab metadata, search, restoration, clear scopes and malformed-data handling | Passed — 28 checks |

The public sidebar uses SF Symbols and an original native stack-symbol animation. Spring profiles and controller transitions passed automated checks. Native symbol appearance was inspected in the installed app. Full manual hover/detachment and accessibility preference coverage remains below. The repository contains no extracted Arc artwork or animation frames.

## Packaged runtime checks

Run `bash scripts/test-runtime.sh` after building. It serves `Tests/Fixtures` on loopback and invokes all five app fixture modes. The fixtures use local pages/media and nonpersistent website stores; no personal browser profile is involved.

| Fixture | Scope | 0.3.4 |
|---|---|---|
| `--web-test` | Real WebKit DOM rendering, local navigation, Back and Forward | Passed |
| `--pip-test` | Same-view playback, rounded aspect-fit panel, native playback/seek bounds/volume/mute/resize/Return controls, DOM restoration before reveal, rapid re-float, close/Escape, cancellation and no-video handling | Passed |
| `--interaction-test` | Sidebar layout, toolbar geometry, capture/momentum/interruption routing, native Space buttons, NSEvent adapter, vertical list geometry/scroll retention, native receiver takeover, event deduplication and vertical/wheel forwarding | Passed — 84 checks |
| `--auto-pip-test` | Actual controller departure/return, asynchronous candidates, Split departures, cancellation and existing-player ownership | Passed — 58 checks, including queued single pages, rapid return/Unsplit cleanup, destination focus, and utility-window closing |
| `--feature-test` | Peek, Little Ark, Split, promotion, page lifecycle, downloads, and local Library integration | Passed — 46 checks, including cross-window Find, pushState URL preservation, preview history and exact downloaded payload |

The 16 added interaction checks reproduce a tiny begin delivered through both monitor and receiver, followed by receiver-only movement and release. They verify exact displacement when an event reaches multiple paths, commit/return behavior, native vertical scrolling on the reused list, mouse-wheel forwarding, and header/dock responder delivery. The fixture uses local NSEvent objects with backing scroll CGEvents; it never posts them to an application or system event queue. Passing this fixture is not a physical dispatch result.

The same 20 pure swipe scenarios were also run against v0.3.2: six failed there and all passed after the recognizer changes. A separate temporary recorder harness passed 15 assertions covering disabled-mode laziness, filtered fields, start/stop/restart, periodic flushing, event/time bounds and safe initialization failure. Its data stayed in a temporary test directory.

Additional standalone fixtures in `Tests/DownloadTests.swift` and `Tests/PreviewTests.swift` exercise download and transient-window behavior. Their presence is not a passing result. They are not all run by `build.sh`.

## Installed-app checks

Version 0.3.4 (build 8) is installed in `/Applications/Ark.app` and passes strict signature verification. It relaunched with every preexisting tab identifier retained. The prior app and session metadata are backed up locally. The limited physical swipe result is recorded below.

Earlier v0.3.2 native UI checks confirmed a rounded video panel without a title bar, visible native overlay controls, play/pause and a 10-second backward seek. Return to Tab selected the source Space/tab and preserved the paused seven-second position. Collapsing the sidebar showed a dark toolbar with readable controls; reopening restored the sidebar. Those observations used the bundled generated video demo; the corresponding packaged PiP fixtures passed again for v0.3.4. The accepted crayon artwork and icon packaging remain unchanged from v0.3.1.

A physical recording of v0.3.2 showed movement confined to the tab list while the favorites and Space heading stayed fixed. Version 0.3.3 disabled that native list bounce, but physical swipe testing still failed. Diagnostic capture showed tiny initial `.began` packets reaching the local monitor without their subsequent movement or release packets; immediately claimed starts received complete sequences. This matches AppKit's documented local-monitor blind spot during nested event tracking and exposes a boundary the earlier direct-adapter fixtures did not cover.

Version 0.3.4 handles scroll events in the tab-list and sidebar receivers, requests horizontal forwarding through the responder chain, and deduplicates the same NSEvent across delivery paths. In the earlier v0.3.3 capture, all 12 tiny starts lacked subsequent movement and release events. In the new physical sample, all eight gentle starts (initial horizontal deltas of ±1 or −4 points) received movement and release events and produced eight Space commits. This verifies that the observed tiny-start failure did not recur in that sample.

All original events in the new capture were recorded through the local monitor; 22 later deliveries to the tab-list or sidebar receivers were deduplicated. This is consistent with horizontal forwarding keeping the gesture on the monitored path. It does not physically demonstrate receiver-only recovery, which remains an automated fixture result. Native vertical and mouse-wheel behavior passed that fixture; broader physical vertical scrolling, other devices, extended use and subjective feel remain unverified.

Earlier v0.3.0 native UI checks confirmed the Ark branding, readable sidebar symbols and home page, and new-tab palette dismissal. On one accessible YouTube player, switching to another tab opened the floating video panel, and selecting the source tab returned the same page while playback continued. This is a single-site observation, not universal video compatibility. Session restoration saves URLs and layout; it does not promise to restore media playhead position across an app restart.

## Manual checks still required

- Check repeated Spaces-symbol hover/selection, window detachment and minimum-width controls across display scales.
- Extend the eight-swipe physical sample with longer sessions, other trackpads/settings, deliberate direction changes and ordinary vertical scrolling. Automated vertical checks passed; broad physical reliability and subjective feel are not established.
- Check VoiceOver, increased contrast, Reduce Motion, and reduced transparency with the relevant system preferences enabled.
- Try representative HTTPS sites, sign-in/upload/media permissions, error pages, and download cancellation without using personal profiles as fixtures.
- Quit/relaunch and inspect metadata restoration, including invalid or missing records and Split pairs.

## Limits

These checks are not a performance benchmark, a complete website-compatibility suite, a security audit, or proof of identical Arc behavior. A deterministic gesture test does not measure a physical trackpad's timing or haptic feel. Component tests and controller fixtures validate different boundaries; neither substitutes for the other.

PiP uses an Ark-owned floating panel and HTML5-video isolation. Cross-origin embeds, protected players, and arbitrary site-specific media controls are not established as supported. Apple Silicon is the release target; Intel hardware and older macOS releases are unverified. Signing is local/ad-hoc; notarization and secure update delivery are not implemented. See [README.md](README.md) and [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md) for the implemented subsets and remaining work.
