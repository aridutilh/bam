# Validation — Ark 0.5.0 prerelease

Status: **0.5.0 build 13 automated and installation verification passed; native main-window shortcuts checked**, as of October 23, 2026. `bash build.sh` and `bash scripts/test-runtime.sh` both exited successfully. All six component and five packaged runtime suites emitted their terminal PASS, including 137 browsing-feature checks. All 53 source/resource/test/build inputs byte-match the isolated final copy. Native UI evidence is limited to one main-window page; multi-surface behavior is covered by fixtures.

The previous published release, **0.4.0 build 12**, passed all six component and five packaged runtime suites, strict signature checks and installation verification. Its 50 source/resource/build inputs matched the isolated build copy, and its installed executable matched the tested bundle. One user accepted its quick PiP corner flicks and stronger slow-release attraction. That evidence belongs to build 12 and does not establish the new page commands or broader device/website compatibility.

Independent review covers implementation boundaries, not runtime or physical acceptance. Ark's PiP uses an existing live web view, bounded rendering waits and inert transition snapshots; the source does not claim identical Arc behavior. The new confirmation pill is native and noninteractive. Hard refresh requests origin revalidation and is not an unconditional cache purge.

## Build and component checks

Run `bash build.sh`. The script compiles for the current host architecture with a macOS 14 minimum, locally signs the application, verifies the signature, packages it, and runs these suites.

| Check | Scope | 0.4.0 build 12 baseline | 0.5.0 build 13 |
|---|---|---|---|
| App build and strict signature verification | Swift/AppKit/WebKit/QuartzCore, generated bundle and ZIP | Passed | Passed |
| `Tests/main.swift` | URL/search rules, model repair, tabs, remembered Space selection, session persistence and internal demo route | Passed — 69 checks | Passed — 69 checks |
| `Tests/MotionTests.swift` | Unit-mass spring math, endpoints, critical/overdamping, velocity continuity, cancellation/replacement, cubic easing, original symbol animation profiles | Passed | Passed |
| `Tests/SpaceSwipeTests.swift` | Axis locking, noisy pickup, coalesced-event/release-tail flicks, deliberate reversals, live handoff, edge resistance, phases, cancellation and momentum | Passed — 20 scenarios | Passed — 20 scenarios |
| `Tests/TabSearchTests.swift` | Matching, ranking, Space labels, keyboard selection and activation | Passed — 15 checks | Passed — 15 checks |
| `Tests/FindTests.swift` | Actual WebKit literal find, next/previous wrapping, no-match feedback, cancellation and retargeting | Passed | Passed |
| `Tests/LibraryTests.swift` | Durable visit/closed-tab metadata, search, restoration, clear scopes and malformed-data handling | Passed — 28 checks | Passed — 28 checks |

The public sidebar uses SF Symbols and an original native stack-symbol animation. Spring profiles and controller transitions passed the build 13 rerun. Native symbol appearance was inspected in the installed app. Full manual hover/detachment and accessibility preference coverage remains below. The repository contains no extracted Arc artwork or animation frames.

## Packaged runtime checks

Run `bash scripts/test-runtime.sh` after building. It serves `Tests/Fixtures` on loopback and invokes all five app fixture modes. The fixtures use local pages/media and nonpersistent website stores; no personal browser profile is involved. The runtime harness now requires a successful process exit plus exactly one matching suite-terminal PASS and no FAIL. A preceding positioning subtest PASS is insufficient. Fixture mode disables last-window autoquit, and the automatic PiP fixture has an overall watchdog and explicit activation/presentation preconditions. Its setup helper requests foreground activation and then requires actual app-active and target-key state. It is never called between Return and its assertions, and the retiring-pane focus check can no longer be skipped.

| Fixture | Scope | 0.4.0 build 12 baseline | 0.5.0 build 13 |
|---|---|---|---|
| `--web-test` | Real WebKit DOM rendering, local navigation, Back and Forward | Passed | Passed |
| `--pip-test` | Same-view playback, rounded aspect-fit panel, native playback/seek bounds/volume/mute/resize/Return controls, DOM restoration before reveal, rapid re-float, close/Escape, cancellation and no-video handling | Passed — 70 positioning checks plus actual-media and fresh cover-pattern verification | Passed — 70 positioning checks plus actual-media and fresh cover-pattern verification |
| `--interaction-test` | Sidebar layout, toolbar geometry, capture/momentum/interruption routing, native Space buttons, NSEvent adapter, vertical list geometry/scroll retention, native receiver takeover, event deduplication and vertical/wheel forwarding | Passed — 84 checks | Passed — 84 checks |
| `--auto-pip-test` | Actual controller departure/return, asynchronous candidates, Split departures, cancellation and existing-player ownership | Passed — 85 checks, including explicit Return and mandatory focus checks | Passed — 85 checks, including explicit Return and mandatory focus checks |
| `--feature-test` | Peek, Little Ark, Split, promotion, page lifecycle, downloads, local Library, and focused-page copy/hard refresh with native feedback | Passed — 51 checks | Passed — 137 checks |

Build 13 passed **70 positioning assertions, 84 controller interaction checks, 85 automatic PiP checks and 137 browsing-feature checks**. Page-command fixtures exercise the main page, visible Peek, both Split panes and Little Ark. They check live URL copying, fresh-document navigation, `reloadFromOrigin` dispatch instead of ordinary reload/stop, refresh during a reported load, rejected navigation without a false confirmation, utility-window no-ops, copy-focus preservation, both messages' text fit and click-through behavior. The test pasteboard is separate from the user's clipboard. These checks establish the tested dispatch and document behavior, not a complete cache purge or universal website compatibility.

The build 12 baseline passed 70 positioning, 84 controller interaction, 85 automatic PiP and 51 browsing-feature checks. Its actual-media fixtures included fresh page-cover pixel patterns, rapid re-float, cleanup, minimized Return, Peek dismissal, secondary Split focus and continuing playback. Focus preconditions were established before the tested commands; post-action assertions were unchanged.

Current PiP tuning retains the 450-point/second flick threshold and 0.24-second projected display choice. Fast releases choose a corner in their direction and settle over 0.35–0.55 seconds. Slow releases use a 240-point local magnet, with 8-point corner insets; positions outside capture zones remain free. Build 12's 70 positioning checks covered a 200-point inside case, a roughly 254.6-point outside case and a middle-edge free position 290 points from a corner. These are original Ark choices, not recovered Arc constants. OS momentum is ignored, stale/reversed movement cannot reuse an earlier launch, and Reduce Motion uses immediate endpoints.

The 16 interaction checks added in 0.3.4 reproduce a tiny begin delivered through both monitor and receiver, followed by receiver-only movement and release. They verify exact displacement when an event reaches multiple paths, commit/return behavior, native vertical scrolling on the reused list, mouse-wheel forwarding, and header/dock responder delivery. The fixture uses local NSEvent objects with backing scroll CGEvents; it never posts them to an application or system event queue. Passing this fixture is not a physical dispatch result.

The same 20 pure swipe scenarios were also run against v0.3.2: six failed there and all passed after the recognizer changes. A separate temporary recorder harness passed 15 assertions covering disabled-mode laziness, filtered fields, start/stop/restart, periodic flushing, event/time bounds and safe initialization failure. Its data stayed in a temporary test directory.

Additional standalone fixtures in `Tests/DownloadTests.swift` and `Tests/PreviewTests.swift` exercise download and transient-window behavior. Their presence is not a passing result. They are not all run by `build.sh`.

## Installed-app checks

**Verified installation: version 0.5.0 (build 13) in `/Applications/Ark.app`.** Strict signature verification passed, and its executable SHA-256 matches the tested bundle: `191f6341668fec7238ea1059d5dd08a0b72208c6a78ea1de60998824a29be6d8`. The release ZIP SHA-256 is `e6cd269c603e3bb6ce5ff3623e7ffca9bca84f4638b3957f17b8ddd21810098b`. All 53 source/resource/test/build inputs matched the final isolated copy. All 12 preexisting tab identifiers were retained, with 12 tabs present after installation.

On the installed app's existing GitHub repository page, actual ⇧⌘C displayed the complete “Page copied” pill. Clearing the address palette and pasting confirmed `https://github.com/aridutilh/ark`. Actual ⇧⌘R displayed the complete “Hard refreshing…” pill and reloaded the page; a later screenshot showed the pill dismissed. An initial native check had exposed clipped text; the final build fixes its measured text width and includes text-fit/click-through regressions for both strings on the main page, both Split panes, Peek and Little Ark. The final native visual check covers one page in the main window; those other surfaces are automated evidence. It does not establish unconditional cache eviction or all accessibility preferences.

An assisted static check of installed build 12 showed one actual YouTube video rendering cleanly at the correct aspect ratio in the rounded PiP panel. Native hover controls were visible for Return, play/pause, ±10-second seek, volume and resize; accessibility reported Pause while the video was playing. This verifies that limited rendered state, not physical movement, transition feel or cross-app Return. Separately, the user physically tested build 12 and accepted the quick corner flicks and stronger slow-release pull. That limited feedback accepts the final corner tuning, not build 12’s Return transition, cross-app activation or broader device behavior.

Earlier assisted checks on builds 9 and 11 rendered one actual YouTube player and exercised native controls. Build 9 also received positive bundled movement/Return/transition feedback, while build 11's feedback requested stronger corner attraction. The assisted Return click could itself activate Ark, so it did not independently prove cross-app activation. Build 12's later acceptance is limited to corner movement. Those older observations establish only the tested builds and players; the build 13 page-command check is described separately above.

Earlier v0.3.2 native UI checks confirmed a rounded video panel without a title bar, visible native overlay controls, play/pause and a 10-second backward seek. Return to Tab selected the source Space/tab and preserved the paused seven-second position. Collapsing the sidebar showed a dark toolbar with readable controls; reopening restored the sidebar. Those observations used the bundled generated video demo; the corresponding packaged PiP fixtures passed again for v0.3.4. The accepted crayon artwork and icon packaging remain unchanged from v0.3.1.

A physical recording of v0.3.2 showed movement confined to the tab list while the favorites and Space heading stayed fixed. Version 0.3.3 disabled that native list bounce, but physical swipe testing still failed. Diagnostic capture showed tiny initial `.began` packets reaching the local monitor without their subsequent movement or release packets; immediately claimed starts received complete sequences. This matches AppKit's documented local-monitor blind spot during nested event tracking and exposes a boundary the earlier direct-adapter fixtures did not cover.

Version 0.3.4 handles scroll events in the tab-list and sidebar receivers, requests horizontal forwarding through the responder chain, and deduplicates the same NSEvent across delivery paths. In the earlier v0.3.3 capture, all 12 tiny starts lacked subsequent movement and release events. In the new physical sample, all eight gentle starts (initial horizontal deltas of ±1 or −4 points) received movement and release events and produced eight Space commits. This verifies that the observed tiny-start failure did not recur in that sample.

All original events in the new capture were recorded through the local monitor; 22 later deliveries to the tab-list or sidebar receivers were deduplicated. This is consistent with horizontal forwarding keeping the gesture on the monitored path. It does not physically demonstrate receiver-only recovery, which remains an automated fixture result. Native vertical and mouse-wheel behavior passed that fixture; broader physical vertical scrolling, other devices, extended use and subjective feel remain unverified.

Earlier v0.3.0 native UI checks confirmed the Ark branding, readable sidebar symbols and home page, and new-tab palette dismissal. On one accessible YouTube player, switching to another tab opened the floating video panel, and selecting the source tab returned the same page while playback continued. This is a single-site observation, not universal video compatibility. Session restoration saves URLs and layout; it does not promise to restore media playhead position across an app restart.

## Manual checks still required

- Extend the installed main-window shortcut check to actual keyboard/menu use in Peek, both Split panes and Little Ark, including rapid repeated commands and switching hosts during a fade. Their routing, text fit, click-through and copy-focus behavior passed automated fixtures; broader manual behavior and the PiP-window no-op remain to be checked.
- Extend hard-refresh checks to failed-navigation retry, cacheable responses and representative websites. The source requests origin revalidation; current fixtures do not establish complete cache eviction.
- Verify build 12 PiP entry and return with actual playing video for blank, clipped or enlarged stale frames; verify playback continuity, rapid reversal and Reduce Motion. Bounded waits and snapshots in source do not prove a clean visual result.
- Repeat explicit Return on build 12 while another application is active and while the browser is hidden/minimized; build 9’s bundled user feedback is limited and the assisted click alone cannot isolate callback activation. Confirm source Space/tab, retained Peek dismissal, secondary Split focus and source media continuity; silent restore and Close/Escape must not activate Ark.
- Extend build 12’s accepted quick-flick and corner-pull sample: check both axes with both scrolling preferences, movement over native controls, momentum suppression, free placement farther from corners, pointer drag, resize interruption, other devices and multiple displays. One user’s acceptance and the 70 passing local positioning assertions do not establish these broader cases.
- Check repeated Spaces-symbol hover/selection, window detachment and minimum-width controls across display scales.
- Extend the eight-swipe physical sample with longer sessions, other trackpads/settings, deliberate direction changes and ordinary vertical scrolling. Automated vertical checks passed; broad physical reliability and subjective feel are not established.
- Check VoiceOver, increased contrast, Reduce Motion, and reduced transparency with the relevant system preferences enabled.
- Try representative HTTPS sites, sign-in/upload/media permissions, error pages, and download cancellation without using personal profiles as fixtures.
- Quit/relaunch and inspect metadata restoration, including invalid or missing records and Split pairs.

## Limits

These checks are not a performance benchmark, a complete website-compatibility suite, a security audit, or proof of identical Arc behavior. A deterministic gesture test does not measure a physical trackpad's timing or haptic feel. Component tests and controller fixtures validate different boundaries; neither substitutes for the other.

PiP uses an Ark-owned floating panel and HTML5-video isolation. Cross-origin embeds, protected players, and arbitrary site-specific media controls are not established as supported. Apple Silicon is the release target; Intel hardware and older macOS releases are unverified. Signing is local/ad-hoc; notarization and secure update delivery are not implemented. See [README.md](README.md) and [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md) for the implemented subsets and remaining work.
