#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP=${ARK_TEST_APP:-"$ROOT/Ark.app"}
RUN_DIR=$(mktemp -d /private/tmp/ark-tests.XXXXXX)
SERVER_PID=''
cleanup() { if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$RUN_DIR"; }
trap cleanup EXIT
python3 - "$ROOT/Tests/Fixtures" "$RUN_DIR/port" <<'PY' &
import http.server, pathlib, sys, functools
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for attempt in {1..50}; do [ -s "$RUN_DIR/port" ] && break; sleep 0.1; done
export ORBIT_TEST_URL="http://127.0.0.1:$(cat "$RUN_DIR/port")/index.html"
for test in --web-test --pip-test --interaction-test --auto-pip-test --feature-test; do
    "$APP/Contents/MacOS/ArkBrowser" "$test"
done
