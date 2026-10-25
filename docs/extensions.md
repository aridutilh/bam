# Login profiles and extensions

Bam hosts WebExtensions through WebKit’s extension engine (macOS 15.4 or later). This document records what the host provides, how packages reach it, what Bam adds on top of WebKit, and exactly which vendor behaviour has been observed. None of it establishes general Chrome, Firefox or Safari extension compatibility; every claim below names the package and the probe it comes from.

## Profiles

Manage Spaces assigns each Space a named login profile. Spaces assigned to the same profile share cookies, website storage, Favorites, history/recently closed pages, and extensions. Separate profiles use separate persistent WebKit data stores and extension controllers. The legacy Default profile retains the existing default website-data store; nothing copies authenticated pages or cookies into a new profile.

A same-profile move keeps the loaded page intact. A cross-profile move or reassignment asks before reloading affected pages. Cancel leaves the live pages alone and keeps the editor’s staged changes available. Accept uses a new renderer in the destination profile; unsaved edits and playback do not carry over. Peek, Little Bam, Split pairs, extension-created tabs and archive restoration retain their source profile. Profile deletion, import of browser cookies, and a user-facing private-window mode are not included.

The intended first setup is **Personal: Dashlane** and **Solo: Dashlane + 1Password**. These remain desired installations, not completed account setups. A fresh profile starts signed out; account login belongs to the user through the extension/site UI.

## Getting an extension into Bam

Extensions → Manage Extensions offers three ways in. All of them end in the same reviewed import: the package is copied privately, size- and entry-capped, prepared if it is Manifest V2, and its permissions and website access are shown before anything is enabled.

**Add from Store or Link** opens the extension library. Paste a Chrome Web Store listing, a Firefox Add-ons listing, or a direct `.xpi`, `.crx` or `.zip` link, or type a name to search Firefox Add-ons (the only public catalog with a search API). Each product appears once with every build Bam knows about; the detail area shows publisher, source, listing link, requested permissions and websites, and the reason Bam recommends one build over another. The user can pick a different build before installing. A Chrome Web Store link resolves through Google’s update service with a current Chrome product version, because listings such as 1Password only answer for Chrome 140 or later.

Downloaded packages are verified before they are unpacked: a Firefox Add-ons build must match the SHA-256 that Mozilla publishes for that file; a Chrome Web Store build must be a CRX3 whose every RSA publisher proof verifies and whose derived ID matches the listing. Direct links are fetched over HTTPS only and are marked as unverified in the manager. The manager row of every store-installed extension shows its source, publisher and how it was verified. These checks establish that the bytes are the ones the store published; they do not vouch for the publisher.

**Check for Update** asks the installed build’s own source for a newer version and, after confirmation, replaces the package in place. The extension keeps its identifier, so WebKit storage, grants and profile assignment survive; the update goes through the same permission review before it is enabled, and the previous package is restored if the new one fails to load. Bam never switches an installed extension from one store’s build to another’s: storage formats differ between a vendor’s Firefox and Chrome builds, so the other build is offered as a separate install instead.

**Import Folder…** installs an unpacked folder, as before. Folder imports are trusted executable code with no publisher verification.

An extension is installed and enabled in one profile. To use the same package in another profile, install it separately there. Enable/disable/remove and permission revocation are available. Previously injected page code cannot be removed in place; Bam offers to reload affected pages, with Later as the safe default.

### Choosing a build

A product may exist as a Firefox build (HTML background page, MV2 or MV3 with `background.scripts`) and a Chrome build (MV3 service worker). WebKit runs both, but Bam’s compatibility layer below can only reach HTML background pages, so where an extension needs the layer the resolver prefers the Firefox build and says so. Observations from Bam’s own probes are shown as dated notes next to the recommendation; they are evidence for the ordering, never a promise. For vidIQ, Dashlane and 1Password the recommended builds are the Firefox ones.

## What the host provides

WebKit supplies background/content scripts, extension storage, actions/popups, native context-menu actions and own-origin pages. Bam adds profile-filtered tab/window adapters, cold-start navigation gating, window creation/removal/state for `windows.create` (opened as a Little Bam window), tab zoom, page-locale detection for `tabs.detectLanguage`, and tab snapshots for `tabs.captureVisibleTab` on pages the extension may access. Extension pages send the same Safari user-agent suffix as tabs, so an extension that fetches a site from its background (vidIQ reads YouTube pages this way) receives the same documents a tab would.

Native messaging to desktop applications is unavailable and is shown as such in the review. Bookmarks, history, identity and sessions namespaces are masked.

### Compatibility layer

WebKit on macOS 27 lacks several namespaces that Firefox and Chrome builds call unconditionally: `notifications`, `idle`, `privacy`, `management`, `downloads`, `commands`, `storage.managed`, plus members such as `runtime.getBrowserInfo`, `runtime.onSuspend`, `runtime.requestUpdateCheck`, `webNavigation.onCreatedNavigationTarget` and `action.getUserSettings`. For an extension whose manifest requests one of the bridged permissions, Bam installs a document-start script in that extension’s own origin (HTML background page, popup and options pages). The script defines only what is absent, keeps callback and promise styles, and talks to the host through an authenticated message handler.

What the layer does: notifications are delivered through macOS User Notifications when Bam runs as an app bundle, with click, button and dismiss events routed back; `idle.queryState` reads the system event source; `privacy` settings answer as read-only and not controllable; `management` describes the extension itself; `downloads.download` goes through Bam’s download coordinator; `commands.getAll` reads the manifest; `storage.managed` is empty and read-only; `getBrowserInfo` identifies Bam. Everything else in those namespaces rejects or is a no-op. The permission review lists the bridged permissions under “Provided by Bam’s compatibility layer (limited)”, and the manager row repeats them.

WebKit’s namespace wrappers turned out to be weakly cached: members grafted onto `webNavigation` or `runtime` disappeared once nothing in the page referenced the wrapper, which made 1Password’s startup pass or fail from one launch to the next. The layer now holds each namespace object it extends and re-applies members for a while after load; two consecutive probes then started 1Password identically.

The layer cannot reach Manifest V3 service workers, so Chrome-store builds that depend on these APIs are not helped. It is not a Chrome compatibility promise: it stands in for the APIs above and nothing else.

### Manifest V2 UTF-8 preparation

For a Manifest V2 package using background.scripts, the importer creates an explicit UTF-8 HTML background page in its private copy and replaces that scripts declaration with background.page. It retains the same external scripts in the same order, including module semantics and other background properties. Every JavaScript file remains byte-identical. The selected source folder stays untouched, and the original manifest is saved byte-for-byte outside the copied package as original-manifest.json. The import review and manager disclose the compatibility preparation. The helper accepts a manifest of at most 1 MiB, validates local relative script paths and regular files, rejects traversal/URLs/query fragments/symlinks, escapes HTML attributes, and chooses a unique generated filename. See WebKit’s [generated background page](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtension.cpp) and [extension resource responses](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionURLSchemeHandlerCocoa.mm).

## Verified observations and remaining work

Component suites: package preparation 87, archive 71, catalog 83 (programmatic fixtures and a fake transport, no network). Native extension suite: 92 checks, including an original MV2 fixture that requests `notifications` and `idle`, exercises the shimmed namespaces in callback and promise style from a real background page, and confirms that an MV3 fixture without bridged permissions receives nothing. The catalog layer was also exercised once against the real services during development: vidIQ resolved and fetched from Firefox Add-ons with a matching hash, and from the Chrome Web Store as a CRX3 with two verified RSA proofs and a matching ID.

The vendor probe (`--vendor-extension-probe`) loads one unpacked package into a fresh private profile with no account, no vault and no sign-in, opens a loopback login fixture or a public page, and reports context errors, the layer’s state and what the extension injected. A completed probe is an observation, not certification. Observed on 2026-10-24 with the Firefox builds:

| Package | Observation |
| --- | --- |
| Dashlane 6.2643.0 (Firefox, MV2) | Background runs with the layer providing `idle`, `privacy` and `downloads`. The welcome popup and options page render. On the loopback login form, Dashlane injected eleven of its own elements (its field icons). Remaining console noise: WebKit serves `.wasm` without the `application/wasm` type, so Dashlane falls back to ArrayBuffer instantiation. |
| vidIQ Vision for YouTube 3.227.0 (Firefox, MV3 with background.scripts) | Zero context errors; popup renders with Login and Sign up. On a YouTube watch page the content scripts injected 157 of vidIQ’s elements, its overlay. This needed the Safari user-agent suffix on extension pages; without it vidIQ’s background received different YouTube documents and rendered nothing. Signed-out requests to vidIQ’s API return 401 as expected. |
| 1Password 8.12.41.1 (Firefox, MV2) | Startup previously stopped at `chrome.notifications`, then at `chrome.webNavigation.onCreatedNavigationTarget`. With the layer holding WebKit’s namespaces, two consecutive probes initialized the background and opened the extension’s welcome page (“Welcome to 1Password! Before you get started, we need to set up a few permissions…”). Content scripts are injected into the login fixture; 1Password shows field controls only once an account is signed in. Remaining console errors are 1Password’s own logging of unavailable native messaging and a context-menu update. |

The Chrome Web Store builds of the same products (Dashlane 6.2643.0, vidIQ 3.233.0, 1Password 8.12.42.36) are MV3 service workers. Bam installs and verifies them, but the compatibility layer cannot reach a service worker, so Dashlane and 1Password from the Chrome Web Store stop where WebKit’s own API coverage ends. The library recommends the Firefox builds for all three.

**Not yet verified, and requiring Ari:** signing in to Dashlane, 1Password or vidIQ on an isolated profile, unlocking, autofill, saving a login, passkeys, and notification banners in a signed build. The welcome and permissions flows are reached; everything past the sign-in button needs an account. 1Password’s desktop-app integration has signing requirements this ad-hoc-signed prototype does not meet; its browser-only mode is the path to test.

**Known gaps:** no search of the Chrome Web Store (reach it by link); no automatic update checks (Check for Update is manual); no `.wasm` MIME correction (WebKit scheme handler); no Manifest V3 service-worker shims; no AI-assisted custom-extension builder yet. Package hashes and provenance are recorded in [VALIDATION.md](../VALIDATION.md). Vendor packages, instrumented copies and raw probe logs stay outside this repository.

Sources: [Apple WKWebExtension](https://developer.apple.com/documentation/webkit/wkwebextension), [Apple extension contexts](https://developer.apple.com/documentation/webkit/wkwebextensioncontext), [Mozilla Add-ons API](https://mozilla.github.io/addons-server/topics/api/addons.html), [CRX3 format](https://chromium.googlesource.com/chromium/src/+/main/components/crx_file/crx3.proto), [1Password additional browsers](https://support.1password.com/additional-browsers/), [1Password browser-only workaround](https://support.1password.com/local-app-database-error/), [Dashlane browser support](https://support.dashlane.com/hc/en-us/articles/115005432325-Dashlane-in-your-browser).
