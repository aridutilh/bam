# Login profiles and local extensions

This is a local 0.10.0 development milestone. It is not installed or published. The final optimized build passes twelve component suites; exact-package native tests pass 98 profile checks and 84 extension checks. Broader intermittent regression failures are recorded in VALIDATION.md. These results do not establish general Chrome or Safari extension compatibility.

## Profiles

Manage Spaces assigns each Space a named login profile. Spaces assigned to the same profile share cookies, website storage, Favorites, history/recently closed pages, and extensions. Separate profiles use separate persistent WebKit data stores and extension controllers. The legacy Default profile retains the existing default website-data store; nothing copies authenticated pages or cookies into a new profile.

A same-profile move keeps the loaded page intact. A cross-profile move or reassignment asks before reloading affected pages. Cancel leaves the live pages alone and keeps the editor’s staged changes available. Accept uses a new renderer in the destination profile; unsaved edits and playback do not carry over. Peek, Little Bam, Split pairs, extension-created tabs and archive restoration retain their source profile. Profile deletion, import of browser cookies, and a user-facing private-window mode are not included.

The intended first setup is **Personal: Dashlane** and **Solo: Dashlane + 1Password**. These remain desired installations, not completed account setups. A fresh profile starts signed out; account login belongs to the user through the extension/site UI.

## Extension host

On macOS 15.4 or later, Extensions → Manage Extensions imports an unpacked extension folder with a manifest.json. Bam copies the selected package, rejects symbolic links and special files, checks the source and private copy against a 100 MB / 10,000-entry limit, and asks before granting supported permissions and website access. Archive/ZIP/CRX files and browser stores are not accepted. Imported folders are trusted executable code; the host does not claim publisher-signature verification.

An extension is installed and enabled in one profile. To use the same package in another profile, import it separately there. Its extension storage, grants, contexts, tabs and website-data store remain separate. Enable/disable/remove and permission revocation are available. Previously injected page code cannot be removed in place; Bam offers to reload affected pages, with Later as the safe default.

The host provides WebKit’s background/content scripts, extension storage, actions/popups, native context-menu actions and own-origin pages, with profile-filtered tab/window adapters. First navigation waits for restored extension contexts. Unsupported browser APIs remain explicitly unavailable. Notifications, native messaging, desktop password-manager integration, automatic package updates, store installation, and broad Chrome API parity are not supplied. A parsed manifest or visible popup does not establish autofill, save, unlock or passkey compatibility.

### Manifest V2 UTF-8 preparation

For a Manifest V2 package using background.scripts, the importer creates an explicit UTF-8 HTML background page in its private copy and replaces that scripts declaration with background.page. It retains the same external scripts in the same order, including module semantics and other background properties. Every JavaScript file remains byte-identical. The selected source folder stays untouched, and the original manifest is saved byte-for-byte outside the copied package as original-manifest.json. The import review and manager disclose the compatibility preparation.

The helper accepts a manifest of at most 1 MiB, validates local relative script paths and regular files, rejects traversal/URLs/query fragments/symlinks, escapes HTML attributes, and chooses a unique generated filename. Validation finishes before mutation; the replacement manifest is the final atomic write. Existing background pages and Manifest V3 workers are unchanged.

This addresses the observed text-decoding failure in WebKit’s generated MV2 background document. It is a disclosed manifest adaptation, not an unmodified package execution claim. See WebKit’s [generated background page](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtension.cpp) and [extension resource responses](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionURLSchemeHandlerCocoa.mm).

### Deferred notification compatibility

Notifications remain unavailable in this draft. An experimental HTML-background bridge advanced 1Password startup but did not pass its inbound-message regression checks. It has been removed from the application and kept only as private local research. A successful outbound API probe was insufficient to establish working extension event delivery; no system notification permission or banner delivery was tested.

## Verified observations and remaining work

The model suite passes 295 checks, and the package-preparation suite passes 81 checks. The exact final package passes 98 profile checks and 84 extension checks, including 22 checks of public document-start injection and temporary namespace-property mutation in an original HTML background page. That capability probe does not implement notifications or prove service-worker injection.

Original bundled extensions exercise real WebKit execution against loopback pages without vendor accounts. Coverage includes permission cancellation, enable/revoke/disable/remove, background/content/storage messaging and ports, context-menu dispatch, popup and own-origin page execution, per-profile isolation, stale tab references, delayed navigation cancellation/adoption, and renderer changes. The profile fixture covers shared/separate cookies and localStorage, Favorite scope, same-profile page identity, cancelled/accepted changes, previews, Split moves, archive metadata and same-process recreation of one disposable named store.

An isolated native preview verified creating/renaming Personal and Solo profiles, cancelling staged edits, cancelling the reload confirmation with Escape, and accepting/saving/reopening profile assignments. Cancellation initially displayed misleading failure text; the neutral “Changes haven’t been applied.” correction has passed full source typechecking but the exact replacement text was not manually rechecked.

The bounded vendor probe observed these specific packages:

| Package | Observation |
| --- | --- |
| Dashlane Firefox 6.2640.1, MV2 | Before preparation, background scripts failed with character-decoding syntax errors. An explicit UTF-8 control reached the welcome screen. The official source folder then passed through the production importer’s generic preparation and displayed the welcome popup with Log in/Create an account and the options page, with zero context errors during the approximately 19-second observation. |
| Dashlane Chromium 6.2643.0, MV3 | Manifest parsed, but background/port initialization reported runtime.connect without listeners. No successful welcome workflow was established. |
| 1Password Firefox 8.12.41.1, MV2 | The final draft lacks chrome.notifications.onClicked, so startup remains blocked. An excluded experimental notification bridge exposed a further missing chrome.webNavigation.onCreatedNavigationTarget event. The app page was blank in both probes; 1Password is not usable in this draft. |

These are initialization observations, not compatibility certification. No vendor sign-in, vault access, unlock, sync, autofill, password save, passkey or desktop integration was tested. Package hashes and provenance are recorded in [VALIDATION.md](../VALIDATION.md). Vendor packages and raw research remain outside this repository.

The --vendor-extension-probe diagnostic accepts an explicitly supplied unpacked package via BAM_VENDOR_EXTENSION and uses a fresh private profile. It blocks remote tab creation through its adapter during observation; that restriction is not a production compatibility defect. It is not an offline sandbox: extension network requests and direct page navigation can still occur.

1Password documents a browser-only path independent of desktop integration, but its desktop integration for additional browsers has signing/trust requirements that this locally ad-hoc-signed prototype does not meet. Dashlane’s named-browser support does not guarantee compatibility with a generic WebKit host.

Sources: [Apple WKWebExtension](https://developer.apple.com/documentation/webkit/wkwebextension), [Apple extension contexts](https://developer.apple.com/documentation/webkit/wkwebextensioncontext), [1Password additional browsers](https://support.1password.com/additional-browsers/), [1Password browser-only workaround](https://support.1password.com/local-app-database-error/), [Dashlane browser support](https://support.dashlane.com/hc/en-us/articles/115005432325-Dashlane-in-your-browser).
