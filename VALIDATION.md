# Validation — Ark 0.3.3

Status: **passed on October 23, 2026**, on Apple Silicon using Swift 6.2.3 in Swift 5 language mode. The final application was built from an isolated copy of the public release files; no Arc installation, private research, or extracted assets were required. All component checks and all five packaged runtime suites exited successfully. Version 0.3.3 changes Space-swipe intent/velocity handling, disables horizontal tab-list elasticity, and adds opt-in local gesture diagnostics. All six component suites and all five packaged runtime suites ran against the v0.3.3 bundle.

Independent agents implemented PiP and Space interaction changes with separate file ownership. A separate reviewer checked cancellation, view ownership, gesture capture, interrupted/queued navigation, resize key routing, and animation completion when a window is hidden. Concrete findings were fixed and covered by regression checks before release. The final review found no remaining blockers.

## Build and component checks

Run `bash build.sh`. The script compiles for the current host architecture with a macOS 14 minimum, locally signs the application, verifies the signature, packages it, and runs these suites.

| Check | Scope | Current public revision |
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

| Fixture | Scope | Current public revision |
|---|---|---|
| `--web-test` | Real WebKit DOM rendering, local navigation, Back and Forward | Passed |
| `--pip-test` | Same-view playback, rounded aspect-fit panel, native playback/seek bounds/volume/mute/resize/Return controls, DOM restoration before reveal, rapid re-float, close/Escape, cancellation and no-video handling | Passed |
| `--interaction-test` | Sidebar layout, toolbar geometry, capture/momentum/interruption routing, native Space buttons, NSEvent phase/window/flipped-coordinate adapter, vertical list geometry/scroll retention at three widths | Passed — 68 checks |
| `--auto-pip-test` | Actual controller departure/return, asynchronous candidates, Split departures, cancellation and existing-player ownership | Passed — 58 checks, including queued single pages, rapid return/Unsplit cleanup, destination focus, and utility-window closing |
| `--feature-test` | Peek, Little Ark, Split, promotion, page lifecycle, downloads, and local Library integration | Passed — 46 checks, including cross-window Find, pushState URL preservation, preview history and exact downloaded payload |

The same 20 pure swipe scenarios were also run against v0.3.2: six failed there and all passed after the recognizer changes. A separate temporary recorder harness passed 15 assertions covering disabled-mode laziness, filtered fields, start/stop/restart, periodic flushing, event/time bounds and safe initialization failure. Its data stayed in a temporary test directory.

Additional standalone fixtures in `Tests/DownloadTests.swift` and `Tests/PreviewTests.swift` exercise download and transient-window behavior. Their presence is not a passing result. They are not all run by `build.sh`.

## Installed-app checks

`/Applications/Ark.app` reports version 0.3.3 (build 7) and passes strict signature verification. All nine existing tab identifiers were preserved after relaunch. The prior Ark 0.3.2 app and session metadata were retained as local backups.

Earlier v0.3.2 native UI checks confirmed a rounded video panel without a title bar, visible native overlay controls, play/pause and a 10-second backward seek. Return to Tab selected the source Space/tab and preserved the paused seven-second position. Collapsing the sidebar showed a dark toolbar with readable controls; reopening restored the sidebar. Those observations used the bundled generated video demo; the corresponding packaged PiP fixtures were rerun for v0.3.3. The accepted crayon artwork and icon packaging remain unchanged from v0.3.1.

A user-provided recording of v0.3.2 showed horizontal movement confined to the tab list while the favorites and Space heading stayed fixed. This establishes native list bounce, not a full Space-page transition cancelling at release. The new build disables that list elasticity. Physical swipe reliability after the changes still requires a new device check; the local diagnostic capture is available for that purpose.

Earlier v0.3.0 native UI checks confirmed the Ark branding, readable sidebar symbols and home page, and new-tab palette dismissal. On one accessible YouTube player, switching to another tab opened the floating video panel, and selecting the source tab returned the same page while playback continued. This is a single-site observation, not universal video compatibility. Session restoration saves URLs and layout; it does not promise to restore media playhead position across an app restart.

## Manual checks still required

- Check repeated Spaces-symbol hover/selection, window detachment and minimum-width controls across display scales.
- Verify physical two-finger swipe reliability after the v0.3.3 changes. v0.3.2 remained unreliable in user testing despite passing its fixtures. Native event fixtures and the recorded list bounce narrow the cause; neither proves the revised physical interaction.
- Check VoiceOver, increased contrast, Reduce Motion, and reduced transparency with the relevant system preferences enabled.
- Try representative HTTPS sites, sign-in/upload/media permissions, error pages, and download cancellation without using personal profiles as fixtures.
- Quit/relaunch and inspect metadata restoration, including invalid or missing records and Split pairs.

## Limits

These checks are not a performance benchmark, a complete website-compatibility suite, a security audit, or proof of identical Arc behavior. A deterministic gesture test does not measure a physical trackpad's timing or haptic feel. Component tests and controller fixtures validate different boundaries; neither substitutes for the other.

PiP uses an Ark-owned floating panel and HTML5-video isolation. Cross-origin embeds, protected players, and arbitrary site-specific media controls are not established as supported. Apple Silicon is the release target; Intel hardware and older macOS releases are unverified. Signing is local/ad-hoc; notarization and secure update delivery are not implemented. See [README.md](README.md) and [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md) for the implemented subsets and remaining work.
