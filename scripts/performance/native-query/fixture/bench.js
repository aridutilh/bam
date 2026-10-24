"use strict";
window.bamQueryReady = typeof globalThis.browser?.tabs?.query === "function";
let foregroundEpoch = 0;
for (const name of ["blur", "resize"]) window.addEventListener(name, () => { foregroundEpoch++; });
document.addEventListener("visibilitychange", () => { foregroundEpoch++; });
window.bamQuery = async function(expected, activeOnly, includeRows) {
  const epoch = foregroundEpoch;
  const before = performance.now();
  const tabs = await browser.tabs.query(activeOnly ? {active: true} : {});
  const elapsed = performance.now() - before;
  // All correctness work and result serialization are outside the query timer.
  const actual = tabs.map(tab => ({id: tab.id, index: tab.index, title: tab.title, url: tab.url,
    active: tab.active, highlighted: tab.highlighted, pinned: tab.pinned, windowId: tab.windowId}));
  const wanted = activeOnly ? expected.filter(tab => tab.active) : expected;
  const errors = [];
  if (actual.length !== wanted.length) errors.push(`count ${actual.length} != ${wanted.length}`);
  if (new Set(actual.map(tab => tab.id)).size !== actual.length) errors.push("duplicate IDs");
  const wantedByURL = new Map(wanted.map(tab => [tab.url, tab]));
  for (const tab of actual) {
    const want = wantedByURL.get(tab.url);
    if (!want) { errors.push(`unexpected URL ${tab.url}`); continue; }
    for (const key of ["index", "title", "url", "active", "pinned"]) {
      if (tab[key] !== want[key]) errors.push(`${key} at ${want.index}: ${String(tab[key])} != ${String(want[key])}`);
    }
    if (tab.active && !tab.highlighted) errors.push(`active tab not highlighted at ${tab.index}`);
    if (!Number.isInteger(tab.id) || !Number.isInteger(tab.windowId)) errors.push("invalid native ID");
  }
  return JSON.stringify({elapsed_ms: elapsed, count: actual.length,
    active_indices: actual.filter(tab => tab.active).map(tab => tab.index),
    selected_indices: actual.filter(tab => tab.highlighted).map(tab => tab.index),
    errors: errors.slice(0, 12), rows: includeRows ? actual : undefined,
    foreground_epoch_changed: epoch !== foregroundEpoch, focused: document.hasFocus(), visibility: document.visibilityState, viewport_css_px: {width: innerWidth, height: innerHeight},
    native_indices_in_return_order: actual.map(tab => tab.index)});
};
