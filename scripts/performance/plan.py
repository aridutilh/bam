#!/usr/bin/env python3
"""Print a reproducible balanced run plan. Does not open tabs, inspect apps, or sample processes."""
import argparse
import itertools
import json
import random
from urllib.parse import urlencode


def make_plan(run, seed, origin):
    randomizer = random.Random(seed)
    orders = list(itertools.permutations(("Bam", "Arc", "Yab")))
    randomizer.shuffle(orders)
    blocks = []
    for ordinal, order in enumerate(orders, 1):
        block_id = f"B{ordinal:02}"
        sessions = []
        # Same route in each browser within a block; 18 switches visit each non-anchor tab once and return to the anchor.
        destinations = list(range(2, 11))
        randomizer.shuffle(destinations)
        route = [1]
        for destination in destinations:
            route.extend((destination, 1))
        for browser in order:
            identity = {"run": run, "block": block_id, "browser": browser, "condition": "default"}
            sessions.append({"browser": browser,
                "renderer_url": origin + "/fixture?" + urlencode({**identity, "phase": "renderer", "workload": "renderer", "page": "01", "auto": 1}),
                "cadence_only_url": origin + "/fixture?" + urlencode({**identity, "phase": "cadence", "workload": "cadence", "page": "01", "auto": 1}),
                "switch_launcher_url": origin + "/launcher?" + urlencode({**identity, "phase": "tabs", "workload": "switch", "tabs": 10, "arm": 1}),
                "tab_destination_route": route,
                "configuration_to_record": {"running_version": None, "running_executable_sha256": None,
                    "profile_mode": None, "existing_ordinary_windows": None, "extensions_and_settings": None,
                    "viewport_css_px": None, "device_pixel_ratio": None, "automatic_pip": None,
                    "capture_active": False, "power_and_memory_state_before": None, "power_and_memory_state_after": None}})
        blocks.append({"block_id": block_id, "order": order, "sessions": sessions})
    return {"schema": 1, "fixture_revision": "perf-round2-v2", "run_id": run, "seed": seed,
        "origin": origin, "blocks": blocks,
        "rules": ["This plan is data only and never initiates UI or samples a process.",
                  "Each browser occupies each order position twice across the six blocks.",
                  "Run one phase across the complete balanced blocks before a different phase; avoid mixing memory loading with renderer work.",
                  "Pilot uses a different run ID. Freeze constants/hashes before confirmatory blocks.",
                  "Each measured session has one planned completed batch. Abort retains evidence; repeat a complete three-browser block under a new block ID.",
                  "Use disposable test windows, preserve existing sessions, and do not induce memory pressure.",
                  "Maximum live fixture pages is 10. Listed but unloaded metadata tests are a separate Bam-only workload."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", default="round2-baseline")
    parser.add_argument("--seed", type=int, default=20261024)
    parser.add_argument("--origin", default="http://127.0.0.1:8767")
    args = parser.parse_args()
    if not args.origin.startswith("http://127.0.0.1:") or "/" in args.origin.removeprefix("http://"):
        parser.error("Use a loopback origin of the form http://127.0.0.1:PORT")
    print(json.dumps(make_plan(args.run, args.seed, args.origin), indent=2))


if __name__ == "__main__":
    main()
