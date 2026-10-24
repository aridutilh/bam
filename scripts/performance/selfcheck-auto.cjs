/* Actual fixture auto-gate under deterministic fake frames; no browser or renderer workload. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(`${__dirname}/fixture.js`, "utf8");
const start = source.indexOf("  function installAutoGate(run) {");
const end = source.indexOf("  const afterReady", start);
assert(start >= 0 && end > start);
const gate = source.slice(start, end) + "\ninstallAutoGate(run);";
const flush = async () => { for (let index = 0; index < 8; index++) await Promise.resolve(); };
function setup() {
  const handlers = {focus: new Set(), visibilitychange: new Set()};
  const frames = [], calls = [], errors = [];
  let focused = true;
  const context = {
    foregroundEpoch: 0,
    document: {visibilityState: "visible", hasFocus: () => focused,
      addEventListener: (name, fn) => handlers[name].add(fn), removeEventListener: (name, fn) => handlers[name].delete(fn)},
    window: {addEventListener: (name, fn) => handlers[name].add(fn), removeEventListener: (name, fn) => handlers[name].delete(fn)},
    setStatus: () => {}, fire: (...args) => errors.push(args),
    nextFrame: () => new Promise((resolve, reject) => frames.push({resolve, reject})),
    run: async () => { calls.push("measurement"); throw new Error("Simulated actual-run abort"); }
  };
  vm.runInNewContext(gate, context);
  return {frames, calls, errors,
    change: async value => {
      focused = value; context.document.visibilityState = value ? "visible" : "hidden"; context.foregroundEpoch++;
      for (const name of ["visibilitychange", "focus"]) for (const fn of [...handlers[name]]) void fn(); await flush();
    },
    frame: async () => { assert(frames.length); frames.shift().resolve({}); await flush(); },
    timeout: async () => { assert(frames.length); frames.shift().reject(new Error("Frame timeout")); await flush(); }
  };
}
(async () => {
  const hidden = setup();
  await hidden.frame(); await hidden.change(false); await hidden.frame();
  assert.equal(hidden.calls.length, 0);
  await hidden.change(true); await hidden.frame(); assert.equal(hidden.calls.length, 0); await hidden.frame();
  assert.equal(hidden.calls.length, 1);
  assert.equal(hidden.errors.length, 1, "Actual measurement abort is reported");
  await hidden.change(false); await hidden.change(true);
  assert.equal(hidden.frames.length, 0); assert.equal(hidden.calls.length, 1, "No retry after actual run aborts");
  const transient = setup();
  await transient.frame(); await transient.change(false); await transient.change(true); await transient.frame();
  assert.equal(transient.calls.length, 0); await transient.frame(); await transient.frame(); assert.equal(transient.calls.length, 1);
  const timeout = setup();
  await timeout.change(false); await timeout.timeout(); assert.equal(timeout.calls.length, 0);
  await timeout.change(true); await timeout.frame(); await timeout.frame(); assert.equal(timeout.calls.length, 1);
  console.log("PASS: focus-loss, transient-return, timeout recovery and no automatic retry after actual abort. No benchmark workload executed.");
})().catch(error => { console.error(error); process.exitCode = 1; });
