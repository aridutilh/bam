# Bam 💥

<img src="Resources/BamIcon.png" width="128" alt="Bam's red burst sticker on a light pink tile">

A small, fast macOS browser built natively with Swift, AppKit and WebKit. No Electron.

[Website](https://bambrowser.com) · [Download](https://github.com/aridutilh/bam/releases) · [Changelog](CHANGELOG.md)

An independent open-source experiment, not affiliated with Arc, The Browser Company or Yab, and not claiming parity with them.

## Highlights

- **Spaces** with their own name, icon and color, plus Favorites, kept tabs and folders.
- **Peek** opens a link over your page; **Split View** shows two pages side by side.
- **Little Bam**, a compact window for links from other apps.
- **Floating video** that keeps playing when you leave its tab.
- **Login profiles** keep sign-ins, history and extensions apart.
- **Import from Arc** brings over your sidebar layout, with a preview first.
- **Extensions** from the Chrome Web Store, Firefox Add-ons and Safari, with per-site access.

## Requirements and limits

- macOS 14 or later on Apple Silicon. Extensions need macOS 15.4 or later.
- Releases are prereleases: ad-hoc signed, not notarized, and without an auto-updater.
- Extension compatibility is partial and varies by extension; see the [extension notes](docs/extensions.md).
- There's no built-in content blocker, password manager or sync. Arc import covers the layout only, not passwords, cookies or history.

See the [feature inventory](FEATURE-INVENTORY.md) for what's left and [VALIDATION.md](VALIDATION.md) for what was tested.

## Build from source

You need the Xcode Command Line Tools (with Swift) and Python 3.

```sh
bash build.sh                    # build, sign locally and run the component tests
bash scripts/preview-draft.sh    # install and open Bam Preview
bash scripts/test-runtime.sh     # native test suites (opens real windows)
```

Test builds go only to **/Applications/Bam Preview.app**, which has its own profile. Quit it before installing a new build; the scripts never stop it or touch /Applications/Bam.app. Never launch the `Bam.app` that `build.sh` produces: it's only the installer's input. Add `--fresh` to `preview-draft.sh` for a disposable session.

## License

The original code is [MIT licensed](LICENSE). It contains no extracted Arc artwork, fonts or decompiled code; the icon is original (see the [branding notes](docs/branding.md)).
