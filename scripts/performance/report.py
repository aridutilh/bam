#!/usr/bin/env python3
"""Summarize every recorded round-2 batch, with explicit validity and block matching."""
import argparse
import json
import math
import pathlib
import statistics
from collections import defaultdict

REVISION = "perf-round2-v2"
CPU_ITERATIONS = 20_000_000
RENDERER_FIELDS = ("cpu_ms", "dom_mutation_and_forced_layout_ms", "work_end_to_first_raf_ms", "raf_interval_ms")
GROUP_FIELDS = ("run_id", "block_id", "browser", "condition", "phase", "workload")


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def summary(values):
    ordered = sorted(float(value) for value in values if numeric(value))
    if not ordered:
        return {"n": 0}
    return {"n": len(ordered), "min": ordered[0], "median": statistics.median(ordered),
            "p95_nearest_rank": ordered[math.ceil(.95 * len(ordered)) - 1], "max": ordered[-1]}


def geometry_signature(value):
    viewport = value.get("viewport_css_px", {})
    return (viewport.get("width"), viewport.get("height"), value.get("device_pixel_ratio"))


def base_reasons(value, require_focus=True):
    reasons = []
    if value.get("revision") != REVISION:
        reasons.append("fixture_revision_mismatch")
    if value.get("visibility") != "visible" or (require_focus and value.get("focused") is not True):
        reasons.append("completion_not_foreground")
    if any(not numeric(number) or number <= 0 for number in geometry_signature(value)):
        reasons.append("missing_or_invalid_viewport")
    if value.get("condition") == "fixed-frame" and geometry_signature(value)[:2] != (800, 640):
        reasons.append("fixed_frame_requires_800_by_640_child_viewport")
    return reasons


def state_reasons(value):
    if value.get("workload") == "light":
        return []
    state = value["metrics"].get("state", {})
    reasons = []
    if state.get("row_count") != 400 or state.get("allocation_bytes") != 4 * 1024 * 1024:
        reasons.append("workload_state_mismatch")
    if state.get("document_id") != value.get("document_id"):
        reasons.append("state_document_mismatch")
    return reasons


def renderer_batch(value):
    metrics = value["metrics"]
    reasons = base_reasons(value) + state_reasons(value)
    repetitions = metrics.get("repetitions", [])
    trials = [trial for repetition in repetitions for trial in repetition.get("trials", [])]
    if len(repetitions) != 3 or any(len(rep.get("trials", [])) != 10 or rep.get("warmups_excluded") != 2 for rep in repetitions):
        reasons.append("incomplete_repetition_structure")
    if any(trial.get("cpu_iterations") != CPU_ITERATIONS for trial in trials):
        reasons.append("cpu_workload_mismatch")
    if any(trial.get("layout_width_css_px") != 760 for trial in trials):
        reasons.append("article_width_mismatch")
    if any(not numeric(trial.get(field)) or trial[field] < 0 for trial in trials for field in RENDERER_FIELDS):
        reasons.append("invalid_trial_duration")
    checksums = {trial.get("cpu_checksum") for trial in trials}
    if len(checksums) != 1 or any(not isinstance(checksum, int) or isinstance(checksum, bool) for checksum in checksums):
        reasons.append("inconsistent_cpu_checksum")
    summaries = {field: summary(trial.get(field) for trial in trials) for field in RENDERER_FIELDS}
    step = (metrics.get("clock_probe") or {}).get("observed_min_positive_step_ms")
    cpu_median = summaries["cpu_ms"].get("median")
    warnings = []
    if not numeric(step) or step <= 0:
        warnings.append("clock_step_not_observed")
    elif numeric(cpu_median) and cpu_median < 20 * step:
        warnings.append("cpu_median_under_20_observed_clock_steps_no_precise_ratio")
    # DOM timings may still be quantized even though the integer workload is longer.
    dom_median = summaries["dom_mutation_and_forced_layout_ms"].get("median")
    if numeric(step) and step > 0 and numeric(dom_median) and dom_median < 20 * step:
        warnings.append("dom_median_under_20_observed_clock_steps_no_precise_ratio")
    return {"event_id": value["event_id"], "batch_id": metrics.get("batch_id"), "page_id": value["page_id"],
            "document_id": value["document_id"], "valid": not reasons, "exclusion_reasons": reasons,
            "warnings": warnings, "viewport_css_px_and_dpr": geometry_signature(value),
            "clock_probe": metrics.get("clock_probe"), "cpu_checksum": next(iter(checksums), None),
            "trial_summaries_ms": summaries,
            "repetition_medians_ms": [{field: summary(trial.get(field) for trial in repetition.get("trials", [])).get("median")
                                        for field in RENDERER_FIELDS} for repetition in repetitions]}


def cadence_batch(value):
    metrics = value["metrics"]
    reasons = base_reasons(value) + state_reasons(value)
    intervals = metrics.get("intervals", [])
    if len(intervals) != 120:
        reasons.append("cadence_interval_count_mismatch")
    if metrics.get("article_width_css_px") != 760:
        reasons.append("article_width_mismatch")
    for interval in intervals:
        if any(not numeric(interval.get(field)) or interval[field] < 0 for field in ("raf_timestamp_interval_ms", "callback_interval_ms")):
            reasons.append("invalid_cadence_duration")
            break
    return {"event_id": value["event_id"], "batch_id": metrics.get("batch_id"), "page_id": value["page_id"],
            "document_id": value["document_id"], "valid": not reasons, "exclusion_reasons": reasons,
            "viewport_css_px_and_dpr": geometry_signature(value),
            "raf_timestamp_interval_ms": summary(interval.get("raf_timestamp_interval_ms") for interval in intervals),
            "callback_interval_ms": summary(interval.get("callback_interval_ms") for interval in intervals),
            "intervals_over_12_5_ms": sum(interval.get("raf_timestamp_interval_ms", 0) > 12.5 for interval in intervals),
            "intervals_over_25_ms": sum(interval.get("raf_timestamp_interval_ms", 0) > 25 for interval in intervals),
            "scope": "Callback cadence only. Threshold counts are descriptive; they do not count dropped displayed frames."}


def make_report(records):
    groups = {}
    for record in records:
        value = record["client"]
        key = tuple(value.get(field) for field in GROUP_FIELDS)
        group = groups.setdefault(key, {**dict(zip(GROUP_FIELDS, key)), "ready_events": [], "documents_by_page": {},
                                       "renderer_batches": [], "cadence_batches": [], "handoffs": [], "errors": [],
                                       "checkpoints": [], "record_count": 0})
        group["record_count"] += 1
        docs = group["documents_by_page"].setdefault(value["page_id"], [])
        if value["document_id"] not in docs:
            docs.append(value["document_id"])
        event = value["event"]
        if event == "ready":
            group["ready_events"].append(value)
        elif event == "renderer_complete":
            group["renderer_batches"].append(renderer_batch(value))
        elif event == "cadence_complete":
            group["cadence_batches"].append(cadence_batch(value))
        elif event == "page_handoff":
            # Chrome may retain focus while a selected page becomes visible.
            # Focus remains mandatory for CPU/DOM/cadence, and a handoff stratum.
            reasons = base_reasons(value, require_focus=False) + state_reasons(value)
            if value["metrics"].get("state_retained_since_arm") is not True:
                reasons.append("page_state_not_retained")
            if value["metrics"].get("article_width_css_px") != 760:
                reasons.append("article_width_mismatch")
            group["handoffs"].append({**value, "valid": not reasons, "exclusion_reasons": reasons})
        elif event == "checkpoint":
            group["checkpoints"].append(value)
        elif event.endswith("_aborted") or event == "fixture_error":
            group["errors"].append(value)
    for group in groups.values():
        group["measurement_scope"] = ("Embedded renderer/cadence in a same-origin 800 × 640 CSS-pixel iframe; not native page or tab-switch latency."
                                      if group["condition"] == "fixed-frame" else "Top-level fixture; native input and presented pixels are not measured.")
        group["ready_page_count"] = len({value["page_id"] for value in group["ready_events"]})
        group["pages_with_document_replacement"] = [page for page, ids in group["documents_by_page"].items() if len(ids) > 1]
        group["valid_handoff_second_raf_ms"] = summary(value["metrics"].get("visibility_to_second_raf_ms") for value in group["handoffs"] if value["valid"])
        group["excluded_handoff_count"] = sum(not value["valid"] for value in group["handoffs"])
        group["handoffs_by_document_focus"] = {str(focused).lower(): summary(value["metrics"].get("visibility_to_second_raf_ms") for value in group["handoffs"] if value["valid"] and value.get("focused") is focused) for focused in (True, False)}

    # Compare one completed batch per browser/block. Repeats or aborted attempts are never silently replaced.
    comparisons = defaultdict(list)
    for group in groups.values():
        key = tuple(group[field] for field in ("run_id", "block_id", "condition", "phase", "workload"))
        comparisons[key].append(group)
    comparison_rows = []
    for key, block in comparisons.items():
        if not any(group["renderer_batches"] or group["cadence_batches"] for group in block):
            continue
        entry = {**dict(zip(("run_id", "block_id", "condition", "phase", "workload"), key)), "comparisons": {}}
        for kind in ("renderer_batches", "cadence_batches"):
            reasons = []
            by_browser = {group["browser"]: group for group in block}
            if set(by_browser) != {"Bam", "Arc", "Yab"}:
                reasons.append("requires_Bam_Arc_Yab_in_same_block")
            selected = {}
            for browser, group in by_browser.items():
                if len(group[kind]) != 1:
                    reasons.append(f"{browser}:requires_exactly_one_{kind}")
                elif not group[kind][0]["valid"]:
                    reasons.append(f"{browser}:invalid_batch")
                else:
                    selected[browser] = group[kind][0]
                relevant = "renderer" if kind == "renderer_batches" else "cadence"
                if any(value["event"] in (f"{relevant}_aborted", "fixture_error") for value in group["errors"]):
                    reasons.append(f"{browser}:aborted_or_error_attempt_retained")
                if group["pages_with_document_replacement"]:
                    reasons.append(f"{browser}:document_replaced_within_block")
            if len({tuple(batch["viewport_css_px_and_dpr"]) for batch in selected.values()}) > 1:
                reasons.append("viewport_or_dpr_mismatch")
            if kind == "renderer_batches" and len({batch["cpu_checksum"] for batch in selected.values()}) > 1:
                reasons.append("cpu_checksum_mismatch_between_browsers")
            result = {"eligible": not reasons, "exclusion_reasons": reasons, "browser_batches": selected}
            # No percentage or winner inference: publish raw matched block medians for later independent-block analysis.
            entry["comparisons"][kind] = result
        comparison_rows.append(entry)
    return {"revision": REVISION, "record_count": len(records), "groups": list(groups.values()),
            "matched_blocks": comparison_rows,
            "aggregation": "Every batch and abort retained. Trial summaries are within-batch diagnostics. Independent browser-order blocks, not 30 nested trials, are the comparison unit. No automatic fastest/latest selection.",
            "limits": ["Equal viewport and fixture checks do not equalize profiles, extensions, prior sessions, power, memory pressure or thermal state; record these externally.",
                       "rAF is callback cadence, not presented frame rate. Page handoff excludes native input and compositor latency.",
                       "Ready-page count is not a live/resident-page count. Check document state again on reactivation."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=pathlib.Path)
    parser.add_argument("--run")
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.results.read_text().splitlines() if line.strip()]
    if args.run:
        rows = [row for row in rows if row["client"]["run_id"] == args.run]
    print(json.dumps(make_report(rows), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
