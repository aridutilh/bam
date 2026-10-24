# Validation — Ark 0.4.0 prerelease

Status: **0.4.0 build 12 automated and installation verification passed; physical verification pending**, as of October 23, 2026. All six component and five packaged runtime suites passed, and the strict runtime script exited successfully with each suite’s terminal PASS. All 50 source/resource/build inputs match the final isolated copy, and the installed executable matches the tested bundle. Build 12 directs fast flicks to corners and expands the slow-release magnet to 240 points while preserving free placement farther away.

Build 11 passed all six component and five packaged runtime suites, strict signature verification, installation and executable identity checks; all 50 source/resource/build inputs matched its isolated copy. Its physical feedback still requested stronger corner attraction, prompting build 12. Tables below distinguish build 11’s baseline from the completed build 12 automated results.

The previous published release is **0.3.4 (build 8)**. It was built on Apple Silicon using Swift 6.2.3 in Swift 5 language mode from an isolated copy of the publishable source files. All six component suites and all five packaged runtime suites passed for that bundle. Its limited physical sample completed eight of eight gentle Space swipes; this is evidence for that scroll-dispatch fix, not a result for the new PiP interactions or a general reliability/Arc-feel claim.

Independent source review covered explicit Return and Split focus, movement phases and cancellation, bounded entry waits, restoration cleanup if a web view disappears, and pending snap cancellation before the inert panel animates. Source review is not a passing runtime result. The prerelease keeps the live web view at its final size, uses static covers during a bounded render wait, and animates only an inert panel snapshot. It does not claim identical Arc behavior.

## Build and component checks

Run `bash build.sh`. The script compiles for the current host architecture with a macOS 14 minimum, locally signs the application, verifies the signature, packages it, and runs these suites.

| Check | Scope | 0.4.0 build 11 baseline | 0.4.0 build 12 |
|---|---|---|---|
| App build and strict signature verification | Swift/AppKit/WebKit/QuartzCore, generated bundle and ZIP | Passed | Passed |
| `Tests/main.swift` | URL/search rules, model repair, tabs, remembered Space selection, session persistence and internal demo route | Passed — 69 checks | Passed — 69 checks |
| `Tests/MotionTests.swift` | Unit-mass spring math, endpoints, critical/overdamping, velocity continuity, cancellation/replacement, cubic easing, original symbol animation profiles | Passed | Passed |
| `Tests/SpaceSwipeTests.swift` | Axis locking, noisy pickup, coalesced-event/release-tail flicks, deliberate reversals, live handoff, edge resistance, phases, cancellation and momentum | Passed — 20 scenarios | Passed — 20 scenarios |
| `Tests/TabSearchTests.swift` | Matching, ranking, Space labels, keyboard selection and activation | Passed — 15 checks | Passed — 15 checks |
| `Tests/FindTests.swift` | Actual WebKit literal find, next/previous wrapping, no-match feedback, cancellation and retargeting | Passed | Passed |
| `Tests/LibraryTests.swift` | Durable visit/closed-tab metadata, search, restoration, clear scopes and malformed-data handling | Passed — 28 checks | Passed — 28 checks |

The public sidebar uses SF Symbols and an original native stack-symbol animation. Spring profiles and controller transitions passed the build 12 rerun. Native symbol appearance was inspected in the installed app. Full manual hover/detachment and accessibility preference coverage remains below. The repository contains no extracted Arc artwork or animation frames.

## Packaged runtime checks

Run `bash scripts/test-runtime.sh` after building. It serves `Tests/Fixtures` on loopback and invokes all five app fixture modes. The fixtures use local pages/media and nonpersistent website stores; no personal browser profile is involved. The runtime harness now requires a successful process exit plus exactly one matching suite-terminal PASS and no FAIL. A preceding positioning subtest PASS is insufficient. Fixture mode disables last-window autoquit, and the automatic PiP fixture has an overall watchdog and explicit activation/presentation preconditions. Its setup helper requests foreground activation and then requires actual app-active and target-key state. It is never called between Return and its assertions, and the retiring-pane focus check can no longer be skipped.

| Fixture | Scope | 0.4.0 build 11 baseline | 0.4.0 build 12 |
|---|---|---|---|
| `--web-test` | Real WebKit DOM rendering, local navigation, Back and Forward | Passed | Passed |
| `--pip-test` | Same-view playback, rounded aspect-fit panel, native playback/seek bounds/volume/mute/resize/Return controls, DOM restoration before reveal, rapid re-float, close/Escape, cancellation and no-video handling | Passed — 57 positioning checks plus actual-media and fresh cover-pattern verification | Passed — 70 positioning checks plus actual-media and fresh cover-pattern verification |
| `--interaction-test` | Sidebar layout, toolbar geometry, capture/momentum/interruption routing, native Space buttons, NSEvent adapter, vertical list geometry/scroll retention, native receiver takeover, event deduplication and vertical/wheel forwarding | Passed — 84 checks | Passed — 84 checks |
| `--auto-pip-test` | Actual controller departure/return, asynchronous candidates, Split departures, cancellation and existing-player ownership | Passed — 85 checks, including explicit Return and mandatory focus checks | Passed — 85 checks, including explicit Return and mandatory focus checks |
| `--feature-test` | Peek, Little Ark, Split, promotion, page lifecycle, downloads, and local Library integration | Passed — 46 checks | Passed — 51 checks |

Build 12 passed **70 positioning assertions, 84 controller interaction checks, 85 automatic PiP checks and 51 browsing-feature checks**. The automatic fixture includes lifecycle/precondition checks and mandatory focus assertions. These are local fixture events, not physical trackpad input.

Build 12 also passed actual-media checks with a strict black/white fresh-page-cover pattern, rapid re-float and cleanup, minimized Return, retained Peek dismissal, secondary Split focus and continuing playback. The feature fixture explicitly establishes each window’s focus before Find commands; its match and destination-host assertions are unchanged.

Build 11 used a 450-point/second flick threshold, 0.24-second velocity projection, 0.35–0.55-second deceleration, a 140-point local corner magnet and an 8-point inset. The user still found its corner attraction too weak. Build 12 changes fast releases to choose a directed corner, expands the slow-release local magnet to 240 points and retains the 8-point inset. Slow placements outside that local radius remain free. Its 70-assertion positioning suite includes a 200-point inside case, a roughly 254.6-point outside case and a middle-edge free position 290 points from a corner; all passed in the final run. The final snapshot also contains the reviewed feature-fixture focus setup correction, with post-Find assertions unchanged. This is original Ark behavior guided by an Arc reference, not recovered Arc constants. OS momentum is ignored; stale or reversed physical motion must not reuse an earlier launch. Reduce Motion uses the endpoint without animation.

The 16 interaction checks added in 0.3.4 reproduce a tiny begin delivered through both monitor and receiver, followed by receiver-only movement and release. They verify exact displacement when an event reaches multiple paths, commit/return behavior, native vertical scrolling on the reused list, mouse-wheel forwarding, and header/dock responder delivery. The fixture uses local NSEvent objects with backing scroll CGEvents; it never posts them to an application or system event queue. Passing this fixture is not a physical dispatch result.

The same 20 pure swipe scenarios were also run against v0.3.2: six failed there and all passed after the recognizer changes. A separate temporary recorder harness passed 15 assertions covering disabled-mode laziness, filtered fields, start/stop/restart, periodic flushing, event/time bounds and safe initialization failure. Its data stayed in a temporary test directory.

Additional standalone fixtures in `Tests/DownloadTests.swift` and `Tests/PreviewTests.swift` exercise download and transient-window behavior. Their presence is not a passing result. They are not all run by `build.sh`.

## Installed-app checks

**Verified installation: version 0.4.0 (build 12) in `/Applications/Ark.app`.** Strict signature verification passed, and its executable SHA-256 matches the tested bundle: `7b3fa8783677aebbee3ed8af87871ac7a16105ecb6040a3d0477fe9c8f5c96fc`. All 50 source/resource/build inputs match the final isolated copy. All 12 preexisting tab identifiers were retained, with 12 tabs present after installation.

An assisted static check of installed build 12 showed one actual YouTube video rendering cleanly at the correct aspect ratio in the rounded PiP panel. Native hover controls were visible for Return, play/pause, ±10-second seek, volume and resize; accessibility reported Pause while the video was playing. This verifies that limited rendered state, not physical movement, transition feel or cross-app Return. Build 12 physical feedback remains pending.

An earlier build 9 computer-assisted native UI check used one actual YouTube player. Manual PiP displayed the video at the correct aspect ratio in a rounded panel with native controls. Finder was brought to the foreground, then the assisted Return click reached the actual source page and playback continued. The click mechanism may activate Ark itself, so this does **not** independently prove that the Return callback activates Ark from another app. Automatic departure was not visually established by this assisted check; its evidence is the packaged runtime fixtures.

An assisted build 11 check used an actual YouTube player and confirmed rounded rendering plus the native Pause control. It did not test cross-app Return. The user physically tried build 11 and still requested stronger corner attraction. That feedback prompted build 12’s directed fast flicks; it is not acceptance of the previous tuning, and build 12 physical confirmation is pending.

Earlier, the same user gave positive bundled feedback on build 9’s hover/free-placement/corner, Return-from-another-app and transition-feel check, also asking for earlier corner attraction. This was limited feedback, not separate measurements of every item or exhaustive player/device coverage. The earlier Space-swipe sample below belongs to 0.3.4.

Earlier v0.3.2 native UI checks confirmed a rounded video panel without a title bar, visible native overlay controls, play/pause and a 10-second backward seek. Return to Tab selected the source Space/tab and preserved the paused seven-second position. Collapsing the sidebar showed a dark toolbar with readable controls; reopening restored the sidebar. Those observations used the bundled generated video demo; the corresponding packaged PiP fixtures passed again for v0.3.4. The accepted crayon artwork and icon packaging remain unchanged from v0.3.1.

A physical recording of v0.3.2 showed movement confined to the tab list while the favorites and Space heading stayed fixed. Version 0.3.3 disabled that native list bounce, but physical swipe testing still failed. Diagnostic capture showed tiny initial `.began` packets reaching the local monitor without their subsequent movement or release packets; immediately claimed starts received complete sequences. This matches AppKit's documented local-monitor blind spot during nested event tracking and exposes a boundary the earlier direct-adapter fixtures did not cover.

Version 0.3.4 handles scroll events in the tab-list and sidebar receivers, requests horizontal forwarding through the responder chain, and deduplicates the same NSEvent across delivery paths. In the earlier v0.3.3 capture, all 12 tiny starts lacked subsequent movement and release events. In the new physical sample, all eight gentle starts (initial horizontal deltas of ±1 or −4 points) received movement and release events and produced eight Space commits. This verifies that the observed tiny-start failure did not recur in that sample.

All original events in the new capture were recorded through the local monitor; 22 later deliveries to the tab-list or sidebar receivers were deduplicated. This is consistent with horizontal forwarding keeping the gesture on the monitored path. It does not physically demonstrate receiver-only recovery, which remains an automated fixture result. Native vertical and mouse-wheel behavior passed that fixture; broader physical vertical scrolling, other devices, extended use and subjective feel remain unverified.

Earlier v0.3.0 native UI checks confirmed the Ark branding, readable sidebar symbols and home page, and new-tab palette dismissal. On one accessible YouTube player, switching to another tab opened the floating video panel, and selecting the source tab returned the same page while playback continued. This is a single-site observation, not universal video compatibility. Session restoration saves URLs and layout; it does not promise to restore media playhead position across an app restart.

## Manual checks still required

- Verify build 12 PiP entry and return with actual playing video for blank, clipped or enlarged stale frames; verify playback continuity, rapid reversal and Reduce Motion. Bounded waits and snapshots in source do not prove a clean visual result.
- Repeat explicit Return on build 12 while another application is active and while the browser is hidden/minimized; build 9’s bundled user feedback is limited and the assisted click alone cannot isolate callback activation. Confirm source Space/tab, retained Peek dismissal, secondary Split focus and source media continuity; silent restore and Close/Escape must not activate Ark.
- Physically move PiP by hovering over its background and controls with two fingers. Check both axes with both scrolling preferences, momentum suppression, free placement, near-corner magnets, pointer drag, resize interruption and multiple displays. Build 12’s 70 passing local positioning assertions are not physical input. Check its directed fast flicks and slow free placement.
- Check repeated Spaces-symbol hover/selection, window detachment and minimum-width controls across display scales.
- Extend the eight-swipe physical sample with longer sessions, other trackpads/settings, deliberate direction changes and ordinary vertical scrolling. Automated vertical checks passed; broad physical reliability and subjective feel are not established.
- Check VoiceOver, increased contrast, Reduce Motion, and reduced transparency with the relevant system preferences enabled.
- Try representative HTTPS sites, sign-in/upload/media permissions, error pages, and download cancellation without using personal profiles as fixtures.
- Quit/relaunch and inspect metadata restoration, including invalid or missing records and Split pairs.

## Limits

These checks are not a performance benchmark, a complete website-compatibility suite, a security audit, or proof of identical Arc behavior. A deterministic gesture test does not measure a physical trackpad's timing or haptic feel. Component tests and controller fixtures validate different boundaries; neither substitutes for the other.

PiP uses an Ark-owned floating panel and HTML5-video isolation. Cross-origin embeds, protected players, and arbitrary site-specific media controls are not established as supported. Apple Silicon is the release target; Intel hardware and older macOS releases are unverified. Signing is local/ad-hoc; notarization and secure update delivery are not implemented. See [README.md](README.md) and [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md) for the implemented subsets and remaining work.
