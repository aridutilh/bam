#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP=${BAM_PREVIEW_APP:-"$ROOT/Bam.app"}
MODE=persistent
PREPARE_ONLY=false
for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        --fresh) MODE=fresh ;;
        --prepare-only) PREPARE_ONLY=true ;;
        *) echo 'Usage: bash scripts/preview-draft.sh [--fresh] [--prepare-only]' >&2; exit 1 ;;
    esac
done
if [ ! -x "$APP/Contents/MacOS/BamBrowser" ]; then
    echo 'Build the local draft with bash build.sh first.' >&2
    exit 1
fi
if [ "$MODE" = fresh ]; then
    # Existing disposable previews and test flags keep their old behavior.
    if [ "$PREPARE_ONLY" = true ]; then printf '%s\n' "$APP"; exit 0; fi
    exec "$APP/Contents/MacOS/BamBrowser" --fresh-preview
fi

# Never overwrite a live development bundle, and never stop another preview.
if pgrep -f '[B]am Extension Preview.app/Contents/MacOS/BamBrowser' >/dev/null; then
    echo 'Quit Bam Extension Preview before preparing its next build. Its tabs and extensions will be kept.' >&2
    exit 1
fi
PREVIEW_DIR="$ROOT/.build/preview"
DEST="$PREVIEW_DIR/Bam Extension Preview.app"
STAGING=$(mktemp -d /private/tmp/bam-extension-preview.XXXXXX)
PREVIEW_READY=false
cleanup() {
    if [ "$PREVIEW_READY" != true ] && [ -d "$STAGING/previous-preview.app" ]; then
        # This also handles ditto failing partway through the destination copy.
        # Keep the backup directory if either recovery move fails.
        if [ -e "$DEST" ] && ! mv "$DEST" "$STAGING/failed-preview.app"; then
            echo "The previous preview is preserved at $STAGING/previous-preview.app" >&2
            return
        fi
        if ! mv "$STAGING/previous-preview.app" "$DEST"; then
            echo "The previous preview is preserved at $STAGING/previous-preview.app" >&2
            return
        fi
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
STAGED_APP="$STAGING/Bam Extension Preview.app"
/usr/bin/ditto --norsrc --noextattr "$APP" "$STAGED_APP"
PLIST="$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Bam Extension Preview' -c 'Set :CFBundleDisplayName Bam Extension Preview' \
    -c 'Set :CFBundleIconFile BamPreviewIcon.icns' \
    -c 'Set :CFBundleIdentifier com.ari.bam.extensionpreview' -c 'Set :CFBundleExecutable BamBrowser' "$PLIST"
# The development app should not register as a candidate default web browser.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$PLIST" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.FinderInfo "$STAGED_APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$STAGED_APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
mkdir -p "$PREVIEW_DIR"
if [ -e "$DEST" ]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
    if [ "$EXISTING_ID" != com.ari.bam.extensionpreview ]; then
        echo "Refusing to replace a different app at $DEST" >&2
        exit 1
    fi
    mv "$DEST" "$STAGING/previous-preview.app"
fi
/usr/bin/ditto --norsrc --noextattr "$STAGED_APP" "$DEST"
VERIFIED=false
for ATTEMPT in 1 2 3; do
    /usr/bin/xattr -dr com.apple.FinderInfo "$DEST" 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.ResourceFork "$DEST" 2>/dev/null || true
    if /usr/bin/codesign --verify --strict "$DEST"; then VERIFIED=true; break; fi
    sleep "$ATTEMPT"
done
if [ "$VERIFIED" != true ]; then
    echo 'Preview copy did not pass signature verification; the previous local preview was kept.' >&2
    exit 1
fi
PREVIEW_READY=true
printf 'Prepared %s\n' "$DEST"
if [ "$PREPARE_ONLY" = true ]; then exit 0; fi
# Persist only in this app's preferences/WebKit namespace and BamExtensionPreview.
# No cookies, extension storage, or vault data are copied from any other app.
cleanup
trap - EXIT
exec "$DEST/Contents/MacOS/BamBrowser" --persistent-preview
