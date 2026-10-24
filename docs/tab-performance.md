# Local tab performance work

Bam 0.8.0 is an unshipped local draft. These measurements compare the same isolated synthetic fixture before and after the sidebar/session/resource changes. They are not Arc/Yab head-to-head measurements, real-site memory budgets, or input-to-visible-frame timings.

The baseline is local commit d20a719. The fixture lists 100, 500 or 1,000 tabs, loads a controlled subset, alternates two live pages, and checks that their JavaScript state survives. Each loaded page contains 400 article nodes and a touched 4 MiB allocation. The timed selection call is synchronous controller work; a separate JavaScript acknowledgement measures a roundtrip after selection. Cold readiness uses polling and is not first paint. No external network or ordinary browser profile is used.

Memory is the summed kernel physical footprint of the fixture app and its validated WebKit helper coalition, corroborated with macOS `footprint`. It is not RSS and may include shared allocations. The unload checkpoint uses retained saved-tab close semantics, so it demonstrates releasing live views, not automatic sleep eligibility for the scripted fixture.

## Measured comparison

Baseline: local draft d20a719, run `20261024-040335`. Final draft: run `20261024-050404`. Timing uses 30 samples in each 100-tab stage and 20 at 500/1,000. p95 uses nearest rank.

| Listed / live tabs | Median selection ms, before → after | p95 ms, before → after | Sidebar views, before → after | Footprint MiB, before → after |
|---|---:|---:|---:|---:|
| 100 / 1 (reselect) | 1.195 → 1.475 | 2.209 → 2.168 | 823 → 163 | 163.8 → 156.9 |
| 100 / 10 | 6.960 → 1.447 | 12.272 → 5.272 | 823 → 163 | 348.7 → 344.9 |
| 100 / 30 | 7.039 → 1.244 | 8.703 → 2.804 | 823 → 163 | 745.7 → 725.6 |
| 100 / 1 after unload (reselect) | 2.158 → 1.603 | 2.672 → 2.269 | 823 → 171 | 173.4 → 176.5 |
| 500 / 2 | 26.621 → 1.576 | 27.407 → 2.245 | 4,023 → 171 | 247.6 → 206.1 |
| 1,000 / 2 | 55.219 → 2.011 | 56.169 → 4.844 | 8,023 → 171 | 288.1 → 201.5 |

At 1,000 listed tabs with two live pages, median synchronous selection work is about 27× lower, and the measured process-group footprint is about 30% lower. The separate JavaScript roundtrip median is 115.95 → 5.27 ms. Cold readiness median is 90.79 → 75.07 ms; its polling/IPC overhead and synthetic local content prevent interpreting this as website-load or first-paint latency.

Small same-page reselections and the post-unload memory checkpoint did not uniformly improve. Ten seconds after unloading 29 of 30 views, the final run measured 167.5 MiB (baseline 164.3 MiB). There is no universal per-tab memory cap, and these are single-run memory samples with cache/system variability.

The separate busy-writer microbenchmark handed off 1,000 snapshots in each of three bursts (100/500/1,000 listed tabs), coalesced each burst into two off-main atomic writes, flushed and verified the final saved metadata. Median/p95 enqueue times were below 0.001 ms and near clock resolution. Previous synchronous encoding+write medians were 0.584/0.813/1.472 ms. Those are different operations: enqueue timing excludes snapshot construction, encoding and disk completion; it is not a disk-throughput or whole-app speedup.

## Design changes

- Native table cells bound sidebar view creation to visible rows. Data for all rows remains available; row actions use the currently represented identity after reuse. Per-Space scroll containers stay alive. Selection avoids reconfiguring unchanged symbols and labels.
- Session snapshots are value copies handed to one serial background writer. Pending writes coalesce, while an in-flight write completes before the next one. Encoding and atomic replacement no longer block selection. Quit waits asynchronously for the latest snapshot, including newly debounced edits, and allows retry/cancel on failure.
- Critical-pressure sleeping requires a page to be idle at least ten minutes, outside the three most recently used loaded pages, and to pass a fresh document-specific probe. All saved tabs, Split members, PiP, history, navigation/errors, retained previews, non-GET responses and exact keep-awake hostnames are protected. Downloads or modal sheets pause releases.
- The activity observer is installed before HTTP(S) navigation, not for fresh bundled pages that cannot be eligible. It is passive and isolated from page JavaScript. It protects scripts, frames, forms/editable content, custom/shadow content it can identify, service workers, trusted interaction, native media and capture. Once a sticky protection is found it stops observing. Missing, timed-out, stale or malformed evidence cannot authorize sleep.
- Sleeping saves the current URL and bounded scroll offsets, then releases the view; selecting loads it again. It does not serialize arbitrary JavaScript, forms, back/forward history, or media state. Those pages stay alive under this first policy. Closed shadow roots cannot be fully inspected through ordinary DOM traversal; document-level trusted interactions and native media checks provide additional protection, not universal state detection.

## Verification boundaries

The resource runtime suite uses real WebKit pages and an injected pressure signal; it never forces macOS into memory pressure. It checks static eligibility, form/script/history/saved/recent/site exclusions, pressure recovery, release/wake identity and scroll, explicit-navigation cancellation of stale restoration, non-GET crash handling, and the pending-save quit race. Policy/probe tests cover the wider combinations and stale evidence.

An intermediate run that unnecessarily installed the tracker on every bundled fixture page measured 784.3 MiB for 30 live pages, against 745.7 MiB in the baseline. The final draft avoids creating that extra activity world for fresh bundled pages. This synthetic file-page benchmark therefore does not measure the tracker overhead on 30 HTTP(S) pages; real-site memory and pressure-soak measurements remain necessary.

The automatic policy is intentionally limited to static pages. There is no reliable public per-tab physical-memory measurement here, so eligible pages are selected oldest first. Heaviest-tab ranking, general web-app suspension, long-duration pressure soak testing, first-frame latency and physical trackpad feel remain unmeasured.
