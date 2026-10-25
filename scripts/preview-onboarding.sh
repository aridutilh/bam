#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# The canonical preview uses a disposable session for welcome-screen reviews.
exec bash "$ROOT/scripts/preview-draft.sh" --fresh --onboarding "$@"
