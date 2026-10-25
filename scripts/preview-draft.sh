#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# This is only the build input. Every preview launches the canonical app.
APP=${BAM_PREVIEW_APP:-"$ROOT/Bam.app"}
exec python3 "$ROOT/scripts/preview_install.py" --source "$APP" "$@"
