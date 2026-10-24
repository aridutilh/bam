# Local browser performance fixture

An original, loopback-only fixture for comparing fixed renderer work and page callback scheduling. It does not read browser profiles or drive the UI. Use disposable test windows and preserve ordinary sessions.

Requires Python 3.9 or later and Node.js for the transport checks.

```sh
cd scripts/performance
python3 selfcheck.py
node selfcheck-auto.cjs
node selfcheck-transport.cjs
python3 plan.py --run baseline > plan.json
python3 server.py --port 8767 --output-dir runs/baseline
```

Open this address in each browser, changing the browser label and block ID:

```text
http://127.0.0.1:8767/frame?run=baseline&block=B01&browser=Bam&phase=renderer&workload=renderer&page=01&auto=1
```

Click the fixture heading inside the frame to focus it. Wait for “Renderer complete” before switching away. Keep the full 800 × 640 CSS-pixel frame visible, use matching DPR, and do not build, sample processes or capture screenshots during a batch. The generated plan uses all six browser-order permutations; for its renderer URLs, use `/frame` instead of `/fixture`. The wrapper adds the `fixed-frame` condition and preserves the child workload.

The page runs 120 idle requestAnimationFrame intervals, then three repetitions of ten measured CPU/DOM trials with two warmups per repetition. CPU work is 20 million integer iterations; DOM work changes 400 fixed-width article rows and forces layout. It touches a 4 MiB allocation and records document state. Results are posted only to the local collector. Each browser/block is the comparison unit; nested trials are not independent browser runs.

```sh
python3 report.py runs/baseline/results.jsonl --run baseline > runs/baseline/report.json
```

Retain all aborted and slow batches. If a started batch loses focus, resizes or fails, repeat the entire three-browser block with a new explicit ID. Never replace only a slow observation. The report checks geometry, workload, focus, checksums, duplicate batches and retained page state; its validation cannot detect unrelated background CPU work.

For warm-tab diagnostics, use top-level `/fixture` with `workload=switch&phase=tabs2&arm=1&page=01` and a second page `02`, with the same run/block/browser fields. Switch normally between the two loaded tabs. The page measures **visibility event to callback**, excluding input dispatch, browser selection and compositor presentation. Do not report it as click-to-paint. Document focus is reported separately for these handoffs: browser chrome can retain focus while the page is visible. Foreground renderer batches still require document focus. Use the same native selection method across browsers. Avoid conflating differing native viewports/profile configurations with the fixed-frame renderer condition.

The generic plan also includes a separate ten-tab diagnostic with 18 switches. It is not the two-tab protocol described above. The report's handoff summary validates individual events only; it does not enforce an expected route, switch count, unique event per selection, or whole-session rejection after an abort. A confirmatory two-tab comparison needs a separate session ledger that checks those conditions, preserves document identities, and distinguishes settling switches from measured switches. Do not treat the generic handoff summary as that validation.

The collector binds only 127.0.0.1, rejects unexpected Host/Origin values, and appends raw records plus a hashed server-session manifest. No external scripts/resources, cookies or browser credentials are collected. A supplied browser label is not version verification: record the installed/running executable version independently, together with power, profile mode, background sessions, extensions and viewport. Never publish user session data as benchmark evidence.

Limitations: requestAnimationFrame measures scheduling, not displayed FPS; DOM timings are not paint completion; clock quantization can make small ratios meaningless. This is a bounded synthetic workload, not a general browser score, real-world navigation test, memory sampler or startup benchmark. See [the performance notes](../../docs/tab-performance.md) for measured scope and remaining gaps.

## Transport revision v2

`perf-round2-v2` removes fetch keepalive from these persistent fixture pages, consumes every collector response body, and checks the accepted event ID. HTTP, body-read and acknowledgment failures remain visible and are never retried automatically. This changes result transport only; the CPU, DOM, allocation, cadence and handoff work is unchanged. The deterministic checks include 128 sequential posts totaling more than 64 KiB, plus response/error handling. They do not reproduce a browser's internal quota or prove the cause of the earlier failures.

Restart the collector and load new fixture documents under a new run/output directory. V1 clients are rejected by the v2 collector; an output directory containing another revision is refused. Preserve all v1 raw results and use its frozen report implementation for historical analysis. Failed warm-tab sessions remain failures; do not splice v2 events into an earlier session. `transport-v2-manifest.json` records the new source hashes and unchanged workload evidence.

For the separate actual extension JavaScript query experiment, see [the native query harness](native-query/README.md). It uses its own packaged extension fixture and build provenance; the loopback transport revision does not apply to it.
