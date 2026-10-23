# Changelog

## Unreleased

Remaining work is tracked with acceptance criteria in [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md). An inventory item is complete only after its full behavior is verified.

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
