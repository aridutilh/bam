#!/bin/bash
set -euo pipefail

# Package the authored master PNG; this script does not draw or add artwork.
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
INPUT="$ROOT/Resources/ArkIcon.png"
OUTPUT="$ROOT/Resources/ArkIcon.icns"

fail() { printf 'generate-icon: %s\n' "$*" >&2; exit 1; }
[ -f "$INPUT" ] || fail "Missing Resources/ArkIcon.png. Add a square PNG of at least 1024 × 1024 pixels first."
[ -x /usr/bin/sips ] && [ -x /usr/bin/iconutil ] || fail "macOS sips and iconutil are required."

if ! METADATA=$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight -g hasAlpha "$INPUT"); then
    fail "Cannot read Resources/ArkIcon.png."
fi
FORMAT=$(printf '%s\n' "$METADATA" | awk '$1 == "format:" {print $2}')
WIDTH=$(printf '%s\n' "$METADATA" | awk '$1 == "pixelWidth:" {print $2}')
HEIGHT=$(printf '%s\n' "$METADATA" | awk '$1 == "pixelHeight:" {print $2}')
ALPHA=$(printf '%s\n' "$METADATA" | awk '$1 == "hasAlpha:" {print $2}')
[ "$FORMAT" = png ] || fail "Resources/ArkIcon.png must be a PNG image."
[[ "$WIDTH" =~ ^[1-9][0-9]*$ && "$HEIGHT" =~ ^[1-9][0-9]*$ ]] || fail "Cannot determine PNG dimensions."
(( WIDTH == HEIGHT && WIDTH >= 1024 )) || fail "Master PNG must be square and at least 1024 × 1024 pixels (found ${WIDTH} × ${HEIGHT})."
[ "$ALPHA" = yes ] || fail "Master PNG must include an alpha channel for transparent icon corners."

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ark-icon.XXXXXX")
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ICONSET="$WORK_DIR/ArkIcon.iconset"
mkdir -p "$ICONSET"

# All ten standard iconset representations, each resampled from the master.
# This preserves alpha and avoids accumulating downsampling artifacts.
for POINTS in 16 32 128 256 512; do
    for SCALE in 1 2; do
        PIXELS=$((POINTS * SCALE))
        SUFFIX=''
        if [ "$SCALE" -eq 2 ]; then SUFFIX='@2x'; fi
        TARGET="$ICONSET/icon_${POINTS}x${POINTS}${SUFFIX}.png"
        if ! /usr/bin/sips -s format png -z "$PIXELS" "$PIXELS" "$INPUT" --out "$TARGET" >/dev/null; then
            fail "Could not generate ${PIXELS}-pixel icon representation."
        fi
    done
done

if ! /usr/bin/iconutil --convert icns --output "$WORK_DIR/ArkIcon.icns" "$ICONSET"; then
    fail "iconutil could not package the generated iconset. In a restricted automation sandbox, retry with normal macOS process/file access: sandbox restrictions can produce a misleading Invalid Iconset error."
fi
[ -s "$WORK_DIR/ArkIcon.icns" ] || fail "iconutil produced an empty icon file."
mv -f -- "$WORK_DIR/ArkIcon.icns" "$OUTPUT"
printf 'Generated %s from a %s × %s PNG (10 standard representations).\n' "$OUTPUT" "$WIDTH" "$HEIGHT"
