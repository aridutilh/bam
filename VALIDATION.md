# Validation — Ark 0.3.1

Status: **passed on October 23, 2026**, on Apple Silicon using Swift 6.2.3 in Swift 5 language mode. The final application was built from an isolated copy containing only Git-tracked/staged public files; no Arc installation, private research, or extracted assets were required. All component checks and all five packaged runtime suites exited successfully. Version 0.3.1 adds the generated crayon icon, home-page mark, and icon packaging; the Swift runtime source is unchanged from v0.3.0. All six component suites and all five packaged runtime suites were rerun against the v0.3.1 bundle.

Independent agents reviewed PiP lifecycle/focus, command routing/preview ownership, and the public-file boundary. Their concrete findings were fixed and exercised by regression checks before release. A separate review checked the v0.3.1 artwork, packaging, version metadata, provenance, and public-file boundary.

## Build and component checks

Run `bash build.sh`. The script compiles for the current host architecture with a macOS 14 minimum, locally signs the application, verifies the signature, packages it, and runs these suites.

| Check | Scope | Current public revision |
|---|---|---|
| App build and strict signature verification | Swift/AppKit/WebKit/QuartzCore, generated bundle and ZIP | Passed |
| `Tests/main.swift` | URL/search rules, model repair, tabs, remembered Space selection, session persistence and internal demo route | Passed — 69 checks |
| `Tests/MotionTests.swift` | Unit-mass spring math, endpoints, critical/overdamping, velocity continuity, cancellation/replacement, cubic easing, original symbol animation profiles | Passed |
| `Tests/SpaceSwipeTests.swift` | Axis locking, gesture offsets, velocity/distance decisions, edge resistance, cancellation and momentum suppression | Passed |
| `Tests/TabSearchTests.swift` | Matching, ranking, Space labels, keyboard selection and activation | Passed — 15 checks |
| `Tests/FindTests.swift` | Actual WebKit literal find, next/previous wrapping, no-match feedback, cancellation and retargeting | Passed |
| `Tests/LibraryTests.swift` | Durable visit/closed-tab metadata, search, restoration, clear scopes and malformed-data handling | Passed — 28 checks |

The public sidebar uses SF Symbols and an original native stack-symbol animation. Spring profiles and controller transitions passed automated checks. Native symbol appearance was inspected in the installed app. Full manual hover/detachment and accessibility preference coverage remains below. The repository contains no extracted Arc artwork or animation frames.

## Packaged runtime checks

Run `bash scripts/test-runtime.sh` after building. It serves `Tests/Fixtures` on loopback and invokes all five app fixture modes. The fixtures use local pages/media and nonpersistent website stores; no personal browser profile is involved.

| Fixture | Scope | Current public revision |
|---|---|---|
| `--web-test` | Real WebKit DOM rendering, local navigation, Back and Forward | Passed |
| `--pip-test` | Same-view video playback, panel isolation, close/Escape return, pending cancellation and no-video handling | Passed |
| `--interaction-test` | Sidebar layout, resize/collapse/reset, Space navigation, and interrupted transitions | Passed — 17 checks |
| `--auto-pip-test` | Actual controller departure/return, asynchronous candidates, Split departures, cancellation and existing-player ownership | Passed — 58 checks, including queued single pages, rapid return/Unsplit cleanup, destination focus, and utility-window closing |
| `--feature-test` | Peek, Little Ark, Split, promotion, page lifecycle, downloads, and local Library integration | Passed — 46 checks, including cross-window Find, pushState URL preservation, preview history and exact downloaded payload |

Additional standalone fixtures in `Tests/DownloadTests.swift` and `Tests/PreviewTests.swift` exercise download and transient-window behavior. Their presence is not a passing result. They are not all run by `build.sh`.

## Installed-app checks

`/Applications/Ark.app` reports version 0.3.1 (build 4) and passes strict signature verification. All nine existing tab identifiers were preserved on relaunch. The prior Ark 0.3.0 app was retained as a local backup. The installed About panel and home-page footer were visually inspected and show the accepted rough crayon artwork. The icon package contains ten standard macOS representations generated from the committed 1254 × 1254 master PNG, with its alpha channel preserved.

Earlier v0.3.0 native UI checks confirmed the Ark branding, readable sidebar symbols and home page, and new-tab palette dismissal. On one accessible YouTube player, switching to another tab opened the floating video panel, and selecting the source tab returned the same page while playback continued. This is a single-site observation, not universal video compatibility. Session restoration saves URLs and layout; it does not promise to restore media playhead position across an app restart.

## Manual checks still required

- Check repeated Spaces-symbol hover/selection, window detachment and minimum-width controls across display scales.
- Exercise real trackpad gestures, interrupted swipes, haptic feedback and repeated sidebar toggles.
- Check VoiceOver, increased contrast, Reduce Motion, and reduced transparency with the relevant system preferences enabled.
- Try representative HTTPS sites, sign-in/upload/media permissions, error pages, and download cancellation without using personal profiles as fixtures.
- Quit/relaunch and inspect metadata restoration, including invalid or missing records and Split pairs.

## Limits

These checks are not a performance benchmark, a complete website-compatibility suite, a security audit, or proof of identical Arc behavior. A deterministic gesture test does not measure a physical trackpad's timing or haptic feel. Component tests and controller fixtures validate different boundaries; neither substitutes for the other.

PiP uses an Ark-owned floating panel and HTML5-video isolation. Cross-origin embeds, protected players, and arbitrary site-specific media controls are not established as supported. Apple Silicon is the release target; Intel hardware and older macOS releases are unverified. Signing is local/ad-hoc; notarization and secure update delivery are not implemented. See [README.md](README.md) and [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md) for the implemented subsets and remaining work.
