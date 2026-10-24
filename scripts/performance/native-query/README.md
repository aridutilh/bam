# Native extension query experiment

This original fixture measures `browser.tabs.query` promise completion through Bam's actual `BrowserController` and public `WKWebExtension` host. It creates disposable private browser state. It does not read, import, close or modify ordinary browser profiles or tabs.

`QueryMain.swift` and the four files in `fixture/` are byte-identical to the uninstrumented experiment used for the recorded pilots and balanced runs. `experiment.json` pins their SHA-256 hashes and baseline commit `8dec99c87f77436eefc50f0615abbf3855186e83`. The portable driver replaces startup only; it compiles all other actual production Swift files unchanged. The separate private callback-count diagnostic is ready for investigation, but is not included in this package or eligible as timing evidence.

## Build frozen inputs

Use macOS, Python 3, Git, and a Swift/macOS SDK with `WKWebExtension` support. Running the fixture requires macOS 15.4 or later. A build consumes CPU; finish builds before any measurements.

From the repository root:

```sh
# Default: fixed original baseline versus the current committed HEAD.
python3 scripts/performance/native-query/build.py

# An explicitly selected candidate revision.
python3 scripts/performance/native-query/build.py --candidate-ref HEAD

# Include current uncommitted source/resource changes in a frozen candidate.
python3 scripts/performance/native-query/build.py --working-tree

# Freeze inputs and provenance without compiling or launching anything.
python3 scripts/performance/native-query/build.py --prepare-only
```

The driver creates a new system temporary directory and prints its path. `--output-dir` selects a new, nonexistent directory; use a local location outside synchronized folders for app signing. `--arch arm64` or `--arch x86_64` selects the target, defaulting to the host architecture. The original measurements used arm64. `--baseline-ref` can select another baseline, but that makes a different comparison; the default is the exact commit above. That commit must be available locally; the driver does not fetch anything.

Both variants compile from frozen `inputs/`, never from files being edited in the checkout. Commit snapshots use the resolved Git objects. `--working-tree` copies tracked and nonignored files only from `Sources`, `Resources`, `Info.plist` and `VERSION`, rejects symlinks and recovered third-party resources, and checks for changes during capture. Ignored generated resources are omitted. It does not include arbitrary untracked files elsewhere or browser data.

`build-manifest.json` records resolved revisions, snapshot mode, every source/resource hash, harness/fixture hashes, compiler version, exact compiler commands, binary hashes, signature verification and build status. Build logs and failed partial builds remain in the output directory. Both apps receive distinct, build-specific bundle identifiers. They are signed locally; no installation, launch, network fetch, release or production app replacement is performed by the driver. Preserve the whole output directory with the results. Build paths can contain local account names, so inspect generated manifests before publishing them.

## Run one owned fixture at a time

Read the exact `binary` paths from the generated manifest. After builds and other CPU-intensive work stop, run a separately labeled pilot first. Example in a terminal, substituting the generated paths:

```sh
QUERY_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bam-native-query-results.XXXXXX")
env BAM_QUERY_OUTPUT="$QUERY_RUN_DIR/pilot-before.json" \
    BAM_QUERY_LABEL=before BAM_QUERY_BLOCK=pilot-01 \
    "/path/to/build/Bam Native Query before.app/Contents/MacOS/BamQuery" --extension-test
```

Use `after` and the other binary for the candidate. The command runs only the disposable compiled host. `--extension-test` retains Bam's normal fixture network restrictions; `App.swift` is excluded, so the original native-test entry point does not run.

Keep native output in the system temporary directory during the run, then copy completed evidence elsewhere. macOS privacy controls can interfere with automated access to Documents and other protected folders; do not change browser permissions or loosen the fixture gates to work around a denied path.

The fixture opens one clearly labeled window, prints its PID/title, and gives 45 seconds for its window and benchmark page to become active, key, visible, unoccluded and focused. macOS may refuse automatic foreground activation. Click **that fixture window's page** within the gate if needed. Do not manipulate ordinary browser windows. Keep the fixture visible; avoid builds, screenshots, UI inspection or samplers while it runs. Native main-thread work in a slow baseline can delay UI automation; a timeout is not a reason to remove the foreground gate.

Each process has an overall 360-second watchdog and exits with `PASS`/`FAIL`. Raw query attempts/results and partial stages are saved atomically outside the JavaScript timer. Retain failures, timeouts and slow observations under distinct output filenames; the harness overwrites its own destination during progress, so never reuse a destination for another run. If a run is invalid, repeat the whole before/after pair with a new ID and retain the failed pair.

For comparison, use independently launched process pairs in a preselected order, for example before/after, after/before, before/after after the pilots. Record OS, hardware, power mode, compiler/SDK, display state and competing workload conditions. Five queries in one process are nested samples, not five independent browser launches. Summarize each process first and compare the paired process summaries; do not select the fastest trials or merge pilot values into confirmatory pairs.

## Workload and checks

Every stage lists 100, 500 or 1,000 tabs in one profile, including two loaded original extension pages. All remaining same-profile tabs are unloaded metadata with URLs on that extension's own origin. Three additional unloaded tabs belong to a foreign profile. The harness uses nonpersistent website and extension stores, no vendor extension, background worker, external page or persistent session. It checks that exactly two `WKWebView` instances remain loaded. The owned extension package may be copied into a temporary runtime directory; it contains only these original files and is cleaned up by the host.

At each size, the first query after setup is retained separately, followed by five steady queries. Every steady query requires native foreground immediately before dispatch and unchanged page focus/visibility/foreground epoch afterward. The fixture validates profile-local count, unique native IDs, current title/URL/index/pinned/active fields, and that active tabs are highlighted. It records array return order but does not assume that order is an API guarantee.

Additional correctness checks select the already-loaded spare page through the native controller, query active state, move a metadata tab to a foreign profile and query before reconciliation, then restore it and publish title/order changes. The active-only correctness query intentionally executes from the now-background benchmark page; it is not a steady timing sample. Foreign-profile exclusion is checked against the actual current session, not the total tab count.

## What the timer means

The timer starts in the owned extension page immediately before `await browser.tabs.query({})` and ends when the promise resolves. It includes WebKit's extension API path and Bam's host callbacks. Setup, native dispatch, correctness validation, result serialization and native retrieval are outside this interval. It is not navigation, displayed frame rate, click-to-paint, startup, memory, general browser speed or a full vendor-extension workload.

The candidate build can contain multiple changes; timing one API does not attribute a whole-app improvement to one commit. Setup/reconciliation can already warm the candidate topology cache, so these steady queries do not measure cold reconstruction separately. WebKit clock quantization limits interpretation of small durations. First-after-setup, correctness-only and steady results remain distinct in the raw JSON. Compare the same harness hashes and conditions, keep every run, and report the measured API scope with any result.
