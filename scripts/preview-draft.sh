#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP=${BAM_PREVIEW_APP:-"$ROOT/Bam.app"}
if [ ! -x "$APP/Contents/MacOS/BamBrowser" ]; then
    echo 'Build the local draft with bash build.sh first.' >&2
    exit 1
fi
# The preview uses a fresh in-memory session and nonpersistent website data.
# It neither installs an app nor migrates the normal browser profile.
exec "$APP/Contents/MacOS/BamBrowser" --fresh-preview
