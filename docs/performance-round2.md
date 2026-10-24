# Performance round 2 — Bam 0.15.1

The measurements below start from Bam 0.14.0 (`8dec99c`). Bam 0.15.1 combines these performance changes with the published 0.15.0 Settings and palette commands; this integration does not change the historical benchmark results below.

## What the comparison establishes

Six balanced browser-order blocks compared Bam 0.14.0, Arc 1.170.0 (89123), and Yab 0.37.11 (202610232317) on the same 14-inch MacBook Pro. Each browser occupied each order position twice. The fixture ran in an untransformed same-origin 800 × 640 CSS-pixel frame at DPR 2, with an identical 760-pixel article. All 18 renderer batches completed; no batch or slow observation was removed. Each batch contains 30 CPU/layout trials and 120 idle animation callback intervals. Blocks, rather than individual trials, are the comparison units.

| Embedded-page operation | Bam block medians | Arc block medians | Yab block medians |
| --- | ---: | ---: | ---: |
| Fixed 20-million-iteration integer kernel | 23.5–24 ms | 23.6–24.3 ms | 24 ms |
| 400 row changes and forced layout | 2 ms | 4.6–5.15 ms | 3 ms |
| Idle `requestAnimationFrame` interval | 17 ms | 8.3–8.35 ms | 17 ms |

There is no clear CPU winner in this kernel. The DOM workload favors Bam and Yab, but WebKit's observed 1 ms clock step is too coarse for precise percentage claims at these durations. Arc's finer observed step was 0.1 ms. Arc consistently provides more frequent page animation callbacks. This is a scheduling result, **not a measurement of displayed frame rate**. Across 720 intervals per browser, intervals above 25 ms numbered 8 in Bam, 0 in Arc, and 1 in Yab; maxima were 38, 12.2 and 26 ms respectively.

Outer windows, profiles, extensions and existing background user sessions were not identical. The fixed frame controls embedded content geometry; it does not equalize native chrome or compositor behavior. Existing OS swap and background application work remain confounds. The initial unmatched-viewport pilots were retained separately and excluded by the declared fixed-frame protocol. No cache purge, induced memory pressure, or termination of the user's ordinary apps was used.

The original fixtures and reporting checks are in [scripts/performance](../scripts/performance/README.md). They retain aborted batches, document replacements, slow observations, viewport mismatches and focus state. CUA tool duration is never treated as millisecond input latency. Cross-browser input-to-displayed-pixel latency remains unmeasured.

## Changes with measured host costs

### Tab-search preprocessing

Each results view now reuses normalized search fields while validating the exact source title and current/saved URLs. Cache entries disappear with tabs and clear in site-search mode. Empty queries avoid a full sort. Nonempty ranking and returned tab metadata retain the existing behavior.

An optimized method harness compared the original matcher, a new empty cache, and a reused cache. Nine calls per query and size followed warmup. At 1,000 tabs, nonempty matching took 9.26–10.31 ms originally, 6.70–7.36 ms with a fresh cache, and 2.20–2.66 ms with reuse. At 5,000 tabs the ranges were 46.94–51.65, 35.52–37.43, and 12.73–14.63 ms. These are matcher times, excluding native row rendering, input delivery and network suggestions. Empty-query tests started with an unpopulated cache and do not measure pruning an already populated cache.

The old and new implementations agreed in 312 additional equivalence cases. Integrated tab-search tests cover edits, navigation, saved metadata, removal/reinsertion, ordering, Unicode, limits, and fresh returned state.

### History loading and visit persistence

Normal version-1 library files take a single typed decoding path, then explicit validation and deduplication loops. Malformed legacy records still use the salvage path; future versions are preserved. A separate warm-filesystem load-only harness measured 0.58 → 0.21 ms for 100 entries, 6.09 → 2.02 ms for 1,000, and 28.81 → 9.36 ms for 5,000. Six alternating blocks each contained nine reads after warmup. These numbers describe library read/decode/validation, not whole-app startup or the later integrated writer initialization.

Recording a visit now updates memory and hands a value snapshot to a serial utility-queue writer. Only the newest pending snapshot is retained behind an in-flight write. Encoding and atomic file replacement happen off the main thread. Three alternating before/after blocks measured main-thread visit calls at 0.94 → 0.010 ms for 100 entries, 2.35 → 0.024 ms for 1,000, and 7.87 → 0.079 ms for 5,000. Disk completion still took approximately 0.9, 2.3 and 7.9 ms: this removes blocking, not disk work.

Quit waits for both session and profile-history writers, including changes or newly created profile libraries during an awaited save. Failure leaves the latest accepted visit dirty for retry. Explicit history clear/archive mutations still wait for a durable result and can block; rejected mutations restore the prior snapshot before invoking error callbacks. Tests cover write order, coalescing, failure, retry, timeout, reentrant callbacks and quit races.

### Extension tab enumeration

Repeated tab-property callbacks now share revision-bound scalar window topology: IDs, indices and active membership. Live ownership, profile, controller and website-data-store checks remain on every access. Model changes, selection, renderer membership and Split focus invalidate the revision synchronously. Any Peek or Little Bam window uses uncached enumeration. Cached topology never authorizes access or owns a WebView.

An optimized harness exercised the actual adapter callbacks with an original inert extension and unloaded tab metadata. At 1,000 tabs, one full batch of index queries measured 802.16 → 1.75 ms; a title/URL/selected batch measured 830.64 → 3.09 ms. Cache construction is inside the measured batch. Five samples followed warmup; the baseline preceded the candidate rather than alternating. This is adapter work, not a complete JavaScript `browser.tabs.query()` measurement. Cold single-last-tab lookup did not improve (0.79 → 0.86 ms at 1,000 tabs); the tradeoff benefits repeated/bulk reads. Unowned accesses enumerate no surfaces.

A subsequent original-extension test measured the actual JavaScript `browser.tabs.query({})` promise inside the production controller. Three process pairs ran in before/after, after/before, before/after order. Each process retained exactly two private extension pages, with 100, 500 and 1,000 profile-local listed tabs plus three foreign-profile sentinels. All six processes passed 103 correctness checks, including selection and profile reassignment before reconciliation. Five steady queries at each size followed a separately retained setup query.

| Listed tabs | Before process-block medians | Candidate process-block medians |
| --- | ---: | ---: |
| 100 | 90, 92, 91 ms | 6, 7, 6 ms |
| 500 | 2,071, 2,092, 2,059 ms | 68, 75, 70 ms |
| 1,000 | 8,203, 8,272, 8,208 ms | 252, 237, 242 ms |

Timed queries required the page to remain visible and focused at a 756 × 684 CSS-pixel viewport. Result validation, serialization after the page timer, native retrieval and paint are excluded. The first process needed native focus setup near its initial 100-tab queries; the later 500/1,000-tab stages and other five processes had no UI inspection during timing. Separate failed setup attempts and pilots remain excluded from this complete comparison. This is an original API workload, not a password-manager or whole-browser speedup. The candidate in this table is commit `a24c845`, including the first four changes in this round; its remaining query cost still grows faster than tab count.

A separate instrumented copy passed the same 103 correctness checks. At each steady query size N, WebKit called both window-tab enumeration and active-tab lookup 2N+1 times; Bam consequently constructed adapter arrays from N(2N+1) inputs. At 1,000 tabs that is 2,001,000 adapter inputs despite no topology rebuild, refresh, or invalidation during the query. The tab-index selector was present and called 2N times. Diagnostic timings are excluded from the table.

This callback pattern matches the repeated active-tab membership validation in upstream WebKit before [its October 21, 2026 fix](https://github.com/WebKit/WebKit/commit/43cddb77a4fffc920189c8351fd4fb230ad4d0ab). That upstream fix is not evidence that the installed OS includes it.

A second Bam change caches the lightweight adapter array under the same stable topology revision, while retaining live authorization. Adapter insertion, removal, replacement, order changes and reentrant host mutations invalidate it; a missing revision always rebuilds. A second uninstrumented comparison isolated this source change against `a24c845`, using the same harness, geometry, private stores, sample counts and AB/BA/AB process order. All six processes passed 103 checks; compilation, other tests and sampling were stopped throughout.

| Listed tabs | a24 process medians | Adapter-array cache process medians |
| --- | ---: | ---: |
| 100 | 6, 5, 6 ms | 5, 5, 5 ms |
| 500 | 70, 72, 69 ms | 50, 52, 51 ms |
| 1,000 | 250, 246, 243 ms | 166, 166, 167 ms |

At 1,000 tabs, the median of process medians fell from 246 to 166 ms. The 100-tab durations have 1 ms quantization, so precise ratios there are not useful. The prior pilot is excluded. This removes repeated Swift array construction, but framework conversion and membership scans remain; query scaling is still superlinear. These two successive comparisons must not be mistaken for one directly paired original-versus-final run.

### Repeated presentation of the current page

Refreshing an already attached active page no longer removes and reattaches its native view. The host still replaces different views, including a new renderer under the same tab ID, and preserves Split, PiP, focus and lifecycle handling. The native regression verifies 30 repeated single-page presentations and ten repeated Split presentations cause no window-detachment callbacks, while DOM state, input values and renderer identity remain intact. This eliminates a known redundant operation; it does not by itself establish a screen-latency gain.

## Arc findings and remaining limits

Read-only investigation of the installed Arc build found discard completion guards, shared in-flight discard work, and native row reuse/change-only layout invalidation. A native display-link implementation exists, but its specific consumers were not established. These observations do not establish Arc's discard threshold, hidden-page retention policy, memory budget, or the cause of its callback advantage. No proprietary source or recovered assets are included here.

Bam's own native animation callback probe already ran near 8.33 ms on the 120 Hz display. That is separate from WebKit page callbacks. There is no verified public setting in this work that makes page callbacks run at 120 Hz. Automatic tab sleeping retains its existing conservative eligibility rules.

Upstream WebKit distinguishes foreground animation cadence from inactive-view scheduling. Its [animation controller](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/dom/ScriptedAnimationController.cpp) and [frame-rate calculation](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/AnimationFrameRate.cpp) account for throttling and a preference for page updates near 60 Hz. Apple's public [inactive scheduling policy](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.enum) applies to inactive views; it is not documented as a foreground high-refresh control. This is a plausible explanation to investigate, not proof of the policy used by the installed WebKit build.

## Foreground experiments and remaining work

The Mac locked after the full candidate regression run, temporarily preventing foreground experiments. Work resumed after the user reopened it. Failed setup attempts are retained separately; active, visible, key-window gates were not weakened to obtain numbers.

- A two-WebView experiment compared detach/default, attached-but-hidden/default, and detach with WebKit's public inactive `.throttle` policy. After failed setup attempts and a separate pilot, six balanced blocks produced 180 valid samples. Median-of-block selection-to-two-animation-callback acknowledgment was 27.24 ms detached, 16.27 ms attached/hidden, and 27.93 ms detached/throttled. Hidden attachment had a lower block median in all six orders and preserved document/input state and hidden-page visibility. This includes native attachment, focus, IPC and callback scheduling; it does not measure paint. The standalone probe omits the production controller and automatic PiP. Idle CPU and memory costs remain unmeasured, so production background hosting and scheduling policy are unchanged.
- The actual-controller harness covers 100, 500 and 1,000 listed tabs with two live pages, plus separately paused 1 → 10 → 1 physical-footprint checkpoints. Earlier incomplete attempts are retained, including a baseline compound state assertion whose failing field was not captured. A fresh protocol compares pinned baseline `8dec99c` with final candidate `948eb74`, requiring the seeded random marker, form, tab ID and native view identity to survive; wall-clock `performance.timeOrigin` is recorded separately rather than used as document identity. Its first baseline completed all six stages and 200 warm selections. The candidate then timed out at the unchanged 120-second foreground gate while the computer-control call stalled, before any candidate checkpoint or timing sample. Both disposable apps exited. The strict report rejects the incomplete six-process comparison; no candidate memory saving, controller-latency gain or regression can be inferred. The earlier compound failure remains unresolved. Further native runs are deferred to keep this round bounded.
- The six-block Arc/Bam/Yab warm-tab collection completed all 18 native-sidebar sessions, with 576 retained switches and 540 measured after two settling switches per session; the 80-switch transport pilot is excluded. **The original strict analysis rejected exact `performance.timeOrigin` changes.** Upstream [WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/Performance.cpp) recomputes that epoch using a [current wall/monotonic clock mapping](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/GenericTimeMixin.h); observed Bam/Yab drift tracked the collector's independent mapping within 1 ms. A separately reviewed **post-hoc exploratory** analysis treats origin drift as diagnostic metadata while retaining all document UUID, arm UUID, typed-state, lifecycle, route, geometry and raw-event gates. Median-of-six-block visibility→second-animation-callback times were approximately **Arc 3.125 ms** (block medians 2.70–3.40), **Bam 13.25 ms** (13.00–14.00), and **Yab 13.00 ms** (12.50–13.00). All 180 measured Arc callbacks reported page focus=false, versus 179/180 focus=true for Bam and 180/180 for Yab; outer viewports also differed. Two long between-batch pauses (27.46 and 88.61 seconds) and all following samples remain included. These are repeated blocks with the same documents, not independent launches or confirmatory results. The metric excludes native input dispatch, browser selection and paint/presentation.
- The actual JavaScript extension-query comparison and separate callback diagnostic are complete, as reported above. Instrumented timings are excluded from the uninstrumented comparison.

The remaining measurements are a complete many-tab before/after comparison, idle CPU and memory costs of hidden attachment, and native input-to-display latency. Faster search/history work does not prove that Bam has caught Arc's visible switching or page-animation behavior. A policy that retains more background work must demonstrate acceptable idle costs before adoption. Installed-app cold startup cannot be compared fairly while preserving existing Arc/Yab sessions, so the load-only numbers above must not be presented as cross-browser startup results.

## Practical recommendation

The verified search, history and extension-query gains justify a local trial of the candidate. All eighteen component suites and nine native suites passed against the final build. Keep the current conservative background-page policy, and evaluate normal browsing before adding more performance work. Arc still leads in the measured page-callback cadence; a full memory comparison and input-to-displayed-pixel measurement remain open. Bam 0.15.1 ships the measured improvements with the existing background-page policy; the remaining comparative benchmarks are follow-up work.
