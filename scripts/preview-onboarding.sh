#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP=${BAM_PREVIEW_APP:-"$ROOT/Bam.app"}
if [ ! -x "$APP/Contents/MacOS/BamBrowser" ]; then
    echo 'Build the local draft with bash build.sh first.' >&2
    exit 1
fi
# A fresh in-memory session with the first-run welcome forced on, for
# demoing and reviewing onboarding without touching the normal profile.
exec "$APP/Contents/MacOS/BamBrowser" --fresh-preview --onboarding
