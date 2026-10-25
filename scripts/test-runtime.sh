#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP=${BAM_TEST_APP:-${ARK_TEST_APP:-${ORBIT_TEST_APP:-"$ROOT/Bam.app"}}}
# Honor older app bundles supplied through a legacy test-app override too.
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
if [[ "$EXECUTABLE" == */* || ! -x "$APP/Contents/MacOS/$EXECUTABLE" ]]; then
    echo "FAIL: Runtime app has no valid executable: $APP" >&2
    exit 1
fi
RUN_DIR=$(mktemp -d /private/tmp/bam-tests.XXXXXX)
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
export BAM_TEST_URL="http://127.0.0.1:$(cat "$RUN_DIR/port")/index.html"
export ARK_TEST_URL="$BAM_TEST_URL"
export ORBIT_TEST_URL="$BAM_TEST_URL"
for test in --web-test --pip-test --interaction-test --auto-pip-test --feature-test --resource-test --profile-test --extension-test --favicon-test; do
    case "$test" in
        --web-test) marker='PASS: WebKit — ' ;;
        --pip-test) marker='PASS: PiP — ' ;;
        --interaction-test) marker='PASS: Controller interactions — ' ;;
        --auto-pip-test) marker='PASS: Automatic PiP — ' ;;
        --resource-test) marker='PASS: Tab resources — ' ;;
        --profile-test) marker='PASS: Profiles — ' ;;
        --extension-test)
            if python3 -c 'import platform,sys; v=tuple(int(x) for x in platform.mac_ver()[0].split(".")[:2]); sys.exit(0 if v >= (15,4) else 1)'; then
                marker='PASS: Extensions — '
            else
                marker='SKIP: Extensions — macOS 15.4 or later is required'
            fi ;;

        --favicon-test) marker='PASS: Favicons — ' ;;
        --feature-test) marker='PASS: Features — ' ;;
    esac
    log="$RUN_DIR/${test#--}.log"
    if ! "$APP/Contents/MacOS/$EXECUTABLE" "$test" 2>&1 | tee "$log"; then
        echo "FAIL: Runtime $test exited unsuccessfully" >&2
        exit 1
    fi
    # An AppKit lifecycle exit may return zero before the fixture finishes.
    # Require this suite's terminal result, not a preceding subtest's PASS.
    if ! awk -v marker="$marker" '
        index($0, marker) == 1 { passed++ }
        /^FAIL:/ { failed = 1 }
        END { exit !(passed == 1 && !failed) }
    ' "$log"; then
        echo "FAIL: Runtime $test did not emit exactly one successful terminal result" >&2
        exit 1
    fi
done

# Isolated processes/windows: no installed profile or persistent WebKit store.
BUILD_DIR=${BAM_BUILD_DIR:-${ARK_BUILD_DIR:-${ORBIT_BUILD_DIR:-"$ROOT/.build"}}}
log="$RUN_DIR/profile-instance-tests.log"
if ! "$BUILD_DIR/profile-instance-tests" 2>&1 | tee "$log"; then
    echo 'FAIL: Profile activation runtime exited unsuccessfully' >&2
    exit 1
fi
if ! awk '
    /^PASS: Profile activation — / { passed++ }
    /^FAIL:/ { failed = 1 }
    END { exit !(passed == 1 && !failed) }
' "$log"; then
    echo 'FAIL: Profile activation runtime did not emit exactly one successful terminal result' >&2
    exit 1
fi
