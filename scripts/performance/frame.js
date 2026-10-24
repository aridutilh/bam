"use strict";
(() => {
  const query = new URLSearchParams(location.search);
  const requested = query.get("workload") || "renderer";
  if (!["renderer", "cadence"].includes(requested)) {
    document.getElementById("frame-status").textContent = "This wrapper supports renderer or cadence only. Use a top-level fixture for native tab/Space handoff and memory workloads.";
    document.getElementById("renderer-frame").remove();
    return;
  }
  query.set("workload", requested);
  query.set("condition", "fixed-frame");
  if (!query.has("phase")) query.set("phase", requested);
  if (!query.has("auto")) query.set("auto", "1");
  // Native CUA input provides focus; this wrapper never synthesizes input or focuses its child.
  document.getElementById("renderer-frame").src = "/fixture?" + query;
  document.title = `Fixed frame ${query.get("browser") || "unspecified"} ${query.get("block") || "pilot"}`;
})();
