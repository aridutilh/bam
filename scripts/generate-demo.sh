#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Original deterministic test pattern; no third-party video or audio.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=960x600:rate=30' -t 20 -an -c:v libx264 -preset veryfast -crf 25 -pix_fmt yuv420p -movflags +faststart "$ROOT/Resources/PiPDemo.mp4"
