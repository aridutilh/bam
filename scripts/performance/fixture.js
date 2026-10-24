"use strict";
(() => {
  const REVISION = "perf-round2-v2";
  const CPU_ITERATIONS = 20000000;
  const CADENCE_INTERVALS = 120;
  const parameters = new URLSearchParams(location.search);
  const bounded = (value, fallback) => (value || fallback).slice(0, 200);
  const workloads = ["light", "article", "renderer", "cadence", "switch"];
  const identity = {
    run_id: bounded(parameters.get("run"), "round2-pilot"),
    block_id: bounded(parameters.get("block"), "pilot"),
    browser: bounded(parameters.get("browser"), "unspecified"),
    condition: bounded(parameters.get("condition"), "default"),
    phase: bounded(parameters.get("phase"), parameters.get("workload") || "article"),
    workload: workloads.includes(parameters.get("workload")) ? parameters.get("workload") : "article",
    page_id: bounded(parameters.get("page"), "01")
  };
  const byID = id => document.getElementById(id);
  const freshID = () => typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const documentID = freshID();
  let eventSequence = 0;
  let stateCounter = 0;
  let running = false;
  let armed = null;
  let hiddenAt = null;
  let foregroundEpoch = 0;
  let handoffSequence = 0;
  let clockProbe = null;
  const rows = [];
  const rowText = index => `Article ${index} — ${"Synthetic local tab benchmark content. ".repeat(4)}`;
  const geometry = () => ({article_width_css_px: byID("article").getBoundingClientRect().width,
    article_height_css_px: byID("article").offsetHeight});
  const state = () => ({document_id: documentID, sentinel: byID("sentinel").value, counter: stateCounter,
    row_count: rows.length, allocation_bytes: window.fixtureMemory ? window.fixtureMemory.length : 0,
    allocation_marker: window.fixtureMemory ? [window.fixtureMemory[0], window.fixtureMemory[4096], window.fixtureMemory[window.fixtureMemory.length - 1]] : []});
  const setStatus = value => { byID("status").textContent = value; };
  const publish = async (event, metrics) => {
    const payload = {...identity, revision: REVISION, event, event_id: `${documentID}:${++eventSequence}`,
      document_id: documentID, client_time_origin_ms: performance.timeOrigin,
      client_now_ms: performance.now(), visibility: document.visibilityState, focused: document.hasFocus(),
      foreground_epoch: foregroundEpoch, user_agent: navigator.userAgent,
      viewport_css_px: {width: innerWidth, height: innerHeight}, device_pixel_ratio: devicePixelRatio, metrics};
    const response = await fetch("/results", {method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify(payload), cache: "no-store"});
    // Measurement documents remain alive; unload delivery is unnecessary.
    // Consume the reply before acknowledging collection.
    const body = await response.text();
    if (!response.ok) throw new Error(`Collector HTTP ${response.status}`);
    let acknowledgment;
    try { acknowledgment = JSON.parse(body); }
    catch { throw new Error("Collector acknowledgement is not JSON"); }
    if (acknowledgment?.ok !== true || acknowledgment.event_id !== payload.event_id)
      throw new Error("Collector acknowledgement mismatch");
    return payload;
  };
  const fire = (event, metrics) => { void publish(event, metrics).catch(error => setStatus(`Collector error: ${error.message}`)); };
  const nextFrame = () => new Promise((resolve, reject) => {
    let frame;
    const timeout = setTimeout(() => { cancelAnimationFrame(frame); reject(new Error("Animation-frame callback exceeded 2000 ms")); }, 2000);
    frame = requestAnimationFrame(timestamp => { clearTimeout(timeout); resolve({timestamp, callback_now_ms: performance.now()}); });
  });

  if (location.pathname !== "/fixture") {
    byID("launcher").hidden = false;
    for (const field of ["run", "block"]) byID(field).value = identity[`${field}_id`];
    for (const field of ["phase", "condition"]) byID(field).value = identity[field];
    byID("browser").value = ["Bam", "Arc", "Yab"].includes(identity.browser) ? identity.browser : "Bam";
    byID("workload").value = identity.workload;
    byID("tabs").value = Math.max(1, Math.min(10, Number(parameters.get("tabs")) || 10));
    byID("auto").checked = parameters.get("auto") === "1";
    byID("arm").checked = parameters.get("arm") === "1";
    byID("configuration").action = "/launcher";
    for (let index = 1; index <= Number(byID("tabs").value); index++) {
      const query = new URLSearchParams({run: identity.run_id, block: identity.block_id, browser: byID("browser").value,
        condition: identity.condition, phase: identity.phase, workload: identity.workload, page: String(index).padStart(2, "0")});
      for (const flag of ["auto", "arm"]) if (byID(flag).checked) query.set(flag, "1");
      const link = document.createElement("a");
      link.href = `/fixture?${query}`; link.target = "_blank"; link.rel = "noopener";
      link.textContent = `Open ${identity.workload} tab ${String(index).padStart(2, "0")}`;
      byID("links").appendChild(link);
    }
    return;
  }

  const initializationStart = performance.now();
  byID("fixture").hidden = false;
  byID("title").textContent = `Fixture ${identity.page_id}: ${identity.workload}`;
  document.title = `Perf2 ${identity.page_id} ${identity.workload} ${identity.browser}`;
  byID("identity").textContent = `Run ${identity.run_id} · block ${identity.block_id} · ${identity.browser} · ${REVISION}`;
  byID("sentinel").value = `retained-${identity.run_id}-${identity.block_id}-${identity.page_id}`;
  // Static marker exists before a switch; visibility events never change its pixels.
  // Its 8 bits identify the numeric page modulo256; the first two cells are fixed orientation colors.
  const markerCode = Number(identity.page_id) & 255;
  for (let cell = 0; cell < 10; cell++) {
    const part = document.createElement("span");
    part.style.backgroundColor = cell === 0 ? "#ff00ff" : cell === 1 ? "#00ffff" : (markerCode >> (9 - cell)) & 1 ? "#ffffff" : "#000000";
    byID("capture-marker").appendChild(part);
  }
  if (identity.workload !== "light") {
    window.fixtureMemory = new Uint8Array(4 * 1024 * 1024);
    for (let index = 0; index < window.fixtureMemory.length; index++) window.fixtureMemory[index] = (index * 17 + 31) % 251;
    const fragment = document.createDocumentFragment();
    for (let index = 0; index < 400; index++) {
      const row = document.createElement("article"); row.textContent = rowText(index);
      rows.push(row); fragment.appendChild(row);
    }
    byID("article").appendChild(fragment);
  } else {
    const paragraph = document.createElement("p");
    paragraph.textContent = "Small static local page without article allocation, images, video or external resources.";
    byID("article").appendChild(paragraph);
  }
  const initializationMS = performance.now() - initializationStart;
  window.fixtureReady = true;
  window.fixtureDocumentID = documentID;
  window.fixtureState = state;

  function probeClock() {
    const start = performance.now();
    let previous = start;
    let reads = 0;
    const changes = [];
    while (reads++ < 200000 && changes.length < 32) {
      const now = performance.now();
      if (now > previous) { changes.push(now - previous); previous = now; }
      if (now - start >= 40) break;
    }
    return {observed_min_positive_step_ms: changes.length ? Math.min(...changes) : null,
      positive_steps_ms: changes, reads, elapsed_ms: performance.now() - start,
      scope: "Bounded readiness-only clock-step probe; observed step is not a guaranteed timer resolution."};
  }
  const navigation = () => {
    const entry = performance.getEntriesByType("navigation")[0];
    if (!entry) return null;
    return {type: entry.type, request_start_to_response_start_ms: entry.responseStart - entry.requestStart,
      response_body_ms: entry.responseEnd - entry.responseStart, navigation_start_to_dom_interactive_ms: entry.domInteractive,
      navigation_start_to_dom_content_loaded_end_ms: entry.domContentLoadedEventEnd,
      navigation_start_to_load_event_end_ms: entry.loadEventEnd, transfer_bytes: entry.transferSize};
  };
  byID("increment").addEventListener("click", () => { stateCounter++; byID("counter").textContent = `Counter: ${stateCounter}`; });
  byID("checkpoint").addEventListener("click", async () => {
    try { await publish("checkpoint", {state: state(), navigation: navigation(), ...geometry()}); setStatus(`Checkpoint saved for page ${identity.page_id}`); }
    catch (error) { setStatus(error.message); }
  });
  async function armSwitch() {
    armed = {snapshot: state(), armed_at_ms: performance.now(), arm_id: freshID()};
    hiddenAt = null;
    await publish("switch_armed", {arm_id: armed.arm_id, state: armed.snapshot, ...geometry()});
    setStatus(`Switch armed: page ${identity.page_id}`);
  }
  byID("switch-arm").addEventListener("click", () => { void armSwitch().catch(error => setStatus(error.message)); });
  const retained = snapshot => JSON.stringify(snapshot) === JSON.stringify(state());
  document.addEventListener("visibilitychange", () => {
    foregroundEpoch++;
    if (!armed) return;
    const visibilityEventAt = performance.now();
    const visibilityMetrics = {state: state(), arm_id: armed.arm_id, state_retained_since_arm: retained(armed.snapshot),
      event_at_client_now_ms: visibilityEventAt, event_visibility: document.visibilityState};
    if (document.visibilityState !== "visible") { hiddenAt = visibilityEventAt; fire("visibility", visibilityMetrics); return; }
    if (hiddenAt === null) { fire("visibility", visibilityMetrics); return; }
    const departureAt = hiddenAt; hiddenAt = null;
    const epoch = foregroundEpoch;
    const snapshot = armed.snapshot;
    const armID = armed.arm_id;
    const sequence = ++handoffSequence;
    void (async () => {
      try {
        const first = await nextFrame(); const second = await nextFrame();
        // Keep collector IO outside the measured foreground handoff interval.
        fire("visibility", visibilityMetrics);
        if (document.visibilityState !== "visible" || epoch !== foregroundEpoch) {
          fire("handoff_aborted", {arm_id: armID, handoff_sequence: sequence, reason: "Visibility/focus/viewport changed before second callback"}); return;
        }
        await publish("page_handoff", {arm_id: armID, handoff_sequence: sequence,
          hidden_duration_ms: visibilityEventAt - departureAt,
          visibility_to_first_raf_ms: first.callback_now_ms - visibilityEventAt,
          visibility_to_second_raf_ms: second.callback_now_ms - visibilityEventAt,
          raf_timestamp_interval_ms: second.timestamp - first.timestamp,
          state_retained_since_arm: retained(snapshot), state: state(), ...geometry(),
          scope: "Page visibility event to rAF callbacks; excludes native input dispatch, browser selection and compositor/presentation."});
      } catch (error) { fire("handoff_aborted", {arm_id: armID, handoff_sequence: sequence, reason: error.message}); }
    })();
  });
  window.addEventListener("focus", () => { if (armed) fire("focus", {state: state(), state_retained_since_arm: retained(armed.snapshot)}); });
  window.addEventListener("blur", () => { foregroundEpoch++; if (armed) fire("blur", {state: state(), state_retained_since_arm: retained(armed.snapshot)}); });
  window.addEventListener("resize", () => { foregroundEpoch++; fire("viewport_changed", {...geometry()}); });
  window.addEventListener("pageshow", event => { if (event.persisted) { foregroundEpoch++; fire("bfcache_restore", {state: state()}); } });

  function integerWork() {
    let value = 0x12345678;
    for (let index = 0; index < CPU_ITERATIONS; index++) value = (Math.imul(value ^ index, 1664525) + 1013904223) | 0;
    window.fixtureCPUSink = value; return value;
  }
  function mutateAndLayout(index) {
    for (let row = 0; row < rows.length; row++) {
      rows[row].textContent = rowText(row) + (index % 2 ? " • B" : " • A");
      rows[row].style.paddingLeft = `${12 + index % 2}px`;
    }
    return {height: byID("article").offsetHeight, width: byID("article").getBoundingClientRect().width};
  }
  const setRunning = value => {
    running = value;
    byID("renderer-start").disabled = value || identity.workload !== "renderer";
    byID("cadence-start").disabled = value;
  };
  function foregroundGuard() {
    const epoch = foregroundEpoch;
    return () => {
      if (epoch !== foregroundEpoch || document.visibilityState !== "visible" || !document.hasFocus()) throw new Error("Foreground or viewport conditions changed during measurement");
    };
  }
  async function runCadence(trigger) {
    if (running) return false;
    const batchID = freshID(); const requireForeground = foregroundGuard();
    setRunning(true); setStatus("Cadence: collecting 120 idle intervals; no CPU/DOM trials");
    try {
      requireForeground();
      const samples = [];
      // Five settling intervals are excluded. No fetch or DOM writes inside the measured loop.
      for (let index = 0; index < 6; index++) { await nextFrame(); requireForeground(); }
      let previous = await nextFrame();
      for (let index = 0; index < CADENCE_INTERVALS; index++) {
        const current = await nextFrame(); requireForeground();
        samples.push({index, raf_timestamp_interval_ms: current.timestamp - previous.timestamp,
          callback_interval_ms: current.callback_now_ms - previous.callback_now_ms}); previous = current;
      }
      await publish("cadence_complete", {batch_id: batchID, trigger, intervals: samples, clock_probe: clockProbe,
        ...geometry(), state: state(), scope: "Idle JavaScript rAF cadence; not presented frames or native input latency."});
      setStatus("Cadence complete: 120 intervals saved"); return true;
    } catch (error) { fire("cadence_aborted", {batch_id: batchID, reason: error.message}); setStatus(`Cadence aborted: ${error.message}`); return false; }
    finally { setRunning(false); }
  }
  async function runRenderer(trigger) {
    if (running || identity.workload !== "renderer") return;
    const batchID = freshID(); const requireForeground = foregroundGuard();
    const repetitions = []; const observedStart = performance.now();
    setRunning(true);
    try {
      requireForeground();
      for (let repetition = 0; repetition < 3; repetition++) {
        setStatus(`CPU/DOM repetition ${repetition + 1}/3: ten trials`);
        for (let warmup = 0; warmup < 2; warmup++) {
          requireForeground(); integerWork(); mutateAndLayout(warmup); await nextFrame(); requireForeground();
        }
        const trials = [];
        for (let trial = 0; trial < 10; trial++) {
          requireForeground();
          const cpuStart = performance.now(); const checksum = integerWork(); const cpuEnd = performance.now();
          const layout = mutateAndLayout(trial); const domEnd = performance.now();
          const first = await nextFrame(); const second = await nextFrame(); requireForeground();
          trials.push({trial, cpu_iterations: CPU_ITERATIONS, cpu_checksum: checksum, cpu_ms: cpuEnd - cpuStart,
            dom_mutation_and_forced_layout_ms: domEnd - cpuEnd, work_end_to_first_raf_ms: first.callback_now_ms - domEnd,
            raf_interval_ms: second.timestamp - first.timestamp, layout_height_css_px: layout.height, layout_width_css_px: layout.width});
        }
        repetitions.push({repetition, warmups_excluded: 2, trials});
      }
      requireForeground();
      const metrics = {batch_id: batchID, trigger, repetitions, clock_probe: clockProbe,
        observed_handler_to_completion_ms: performance.now() - observedStart, state: state(),
        units: "Milliseconds, CSS pixels, and explicit operation counts.",
        scope: "Fixed renderer kernel, DOM mutations/forced layout, and callbacks; no paint or native dispatch timing."};
      // One network post after all measured trials. No reporting IO between repetitions.
      await publish("renderer_complete", metrics);
      byID("last-result").textContent = JSON.stringify(metrics, null, 2);
      setStatus("Renderer complete: 30 measured trials saved");
    } catch (error) { fire("renderer_aborted", {batch_id: batchID, reason: error.message, completed_repetitions: repetitions}); setStatus(`Renderer aborted: ${error.message}`); }
    finally { setRunning(false); }
  }
  byID("renderer-start").addEventListener("click", () => { void runRenderer("button"); });
  byID("cadence-start").addEventListener("click", () => { void runCadence("button"); });
  setRunning(false);

  function installAutoGate(run) {
    setStatus("Auto-run waiting for two foreground frames");
    let settling = false; let measurementStarted = false;
    const startIfForeground = async () => {
      if (settling || measurementStarted || document.visibilityState !== "visible" || !document.hasFocus()) return;
      settling = true; const settlingEpoch = foregroundEpoch;
      try {
        await nextFrame(); await nextFrame();
        if (settlingEpoch !== foregroundEpoch || document.visibilityState !== "visible" || !document.hasFocus()) return;
        measurementStarted = true;
        document.removeEventListener("visibilitychange", startIfForeground);
        window.removeEventListener("focus", startIfForeground);
        await run();
      } catch (error) {
        if (measurementStarted) fire("fixture_error", {stage: "auto_foreground", reason: error.message});
        else setStatus("Auto-run waiting for foreground readiness");
      } finally {
        settling = false;
        if (!measurementStarted && document.visibilityState === "visible" && document.hasFocus()) void startIfForeground();
      }
    };
    document.addEventListener("visibilitychange", startIfForeground);
    window.addEventListener("focus", startIfForeground);
    void startIfForeground();
  }
  const afterReady = async () => {
    try {
      clockProbe = probeClock();
      await publish("ready", {initialization_ms: initializationMS, clock_probe: clockProbe, state: state(), navigation: navigation(),
        ...geometry(), marker_code: markerCode, total_dom_element_count: document.getElementsByTagName("*").length});
      setStatus(`Ready: page ${identity.page_id}, ${rows.length} article rows`);
      if (parameters.get("arm") === "1") await armSwitch();
      if (["renderer", "cadence"].includes(identity.workload) && parameters.get("auto") === "1") {
        installAutoGate(async () => {
          const cadenceValid = await runCadence("auto=1");
          if (cadenceValid && identity.workload === "renderer") await runRenderer("auto=1_after_cadence");
        });
      }
    } catch (error) { setStatus(`Readiness error: ${error.message}`); }
  };
  if (document.readyState === "complete") setTimeout(afterReady, 0);
  else window.addEventListener("load", () => { setTimeout(afterReady, 0); }, {once: true});
})();
