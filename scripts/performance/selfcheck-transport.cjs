/* Exercise the actual publish function without a browser, UI or timed workload. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(`${__dirname}/fixture.js`, "utf8");
const start = source.indexOf("  const publish = async (event, metrics) => {");
const end = source.indexOf("  const fire = ", start);
assert(start >= 0 && end > start);
const revision = source.match(/const REVISION = "([^"]+)"/)[1];
function setup(fetch) {
  let now = 0;
  const context = {fetch, identity: {run_id: "transport", page_id: "01"}, REVISION: revision,
    documentID: "transport-document", eventSequence: 0, foregroundEpoch: 4,
    performance: {timeOrigin: 1000, now: () => ++now},
    document: {visibilityState: "visible", hasFocus: () => true},
    navigator: {userAgent: "deterministic-test"}, innerWidth: 800, innerHeight: 640, devicePixelRatio: 2};
  vm.runInNewContext(source.slice(start, end) + "\nglobalThis.publish = publish;", context);
  return context.publish;
}
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
(async () => {
  let requests = 0, drains = 0, cumulativeBytes = 0;
  const publish = setup(async (url, options) => {
    assert.equal(url, "/results"); assert.equal(options.method, "POST");
    assert.notEqual(options.keepalive, true, "Persistent documents must not use keepalive quota");
    assert.equal(options.cache, "no-store");
    const sent = JSON.parse(options.body); requests++; cumulativeBytes += Buffer.byteLength(options.body);
    assert.equal(sent.revision, "perf-round2-v2");
    return {ok: true, status: 200, text: async () => {
      drains++; return JSON.stringify({ok: true, duplicate: false, event_id: sent.event_id});
    }};
  });
  for (let i = 1; i <= 128; i++) {
    const payload = await publish("page_handoff", {visibility_to_second_raf_ms: 17, marker: "x".repeat(2048)});
    assert.equal(payload.event_id, `transport-document:${i}`);
    assert.equal(payload.metrics.visibility_to_second_raf_ms, 17);
  }
  assert.equal(requests, 128); assert.equal(drains, 128); assert(cumulativeBytes > 65536);

  let finishBody, sentID, settled = false;
  const waiting = setup(async (_url, options) => {
    sentID = JSON.parse(options.body).event_id;
    return {ok: true, status: 200, text: () => new Promise(resolve => { finishBody = resolve; })};
  })("checkpoint", {});
  void waiting.then(() => { settled = true; });
  await flush(); assert.equal(settled, false, "Publication waits for response body consumption");
  finishBody(JSON.stringify({ok: true, event_id: sentID})); await waiting; assert.equal(settled, true);

  let errorBodyRead = 0;
  await assert.rejects(setup(async () => ({ok: false, status: 503, text: async () => {
    errorBodyRead++; return "unavailable";
  }}))("checkpoint", {}), /Collector HTTP 503/);
  assert.equal(errorBodyRead, 1, "Error responses are consumed too");
  await assert.rejects(setup(async () => ({ok: true, status: 200, text: async () => "not-json"}))("ready", {}), /not JSON/);
  for (const body of ["null", '{"ok":false,"event_id":"transport-document:1"}', '{"ok":true,"event_id":"different-event"}']) {
    await assert.rejects(setup(async () => ({ok: true, status: 200, text: async () => body}))("ready", {}), /mismatch/);
  }
  let attempts = 0;
  await assert.rejects(setup(async () => { attempts++; throw new Error("network failed"); })("ready", {}), /network failed/);
  assert.equal(attempts, 1, "Transport errors never retry and duplicate an unknown accepted event");
  await assert.rejects(setup(async () => ({ok: true, status: 200, text: async () => { throw new Error("body failed"); }}))("ready", {}), /body failed/);
  console.log("PASS: 128 persistent posts exceed 64 KiB cumulatively without keepalive; bodies drain before resolution; HTTP, malformed/mismatched acknowledgement, network and body errors surface without retry. No browser or timed workload executed.");
})().catch(error => { console.error(error); process.exitCode = 1; });
