#!/usr/bin/env python3
"""Deterministic collector/report checks. No browser, renderer workload or process sampling."""
import copy
import http.client
import json
import pathlib
import tempfile
import threading
import unittest
from collections import Counter

from plan import make_plan
from report import CPU_ITERATIONS, REVISION, make_report
from server import FixtureServer, ROOT, manifest


def sample(browser="Bam", event="renderer_complete", event_id=None):
    document = browser + "-document"
    state = {"document_id": document, "row_count": 400, "allocation_bytes": 4 * 1024 * 1024}
    trial = {"cpu_iterations": CPU_ITERATIONS, "cpu_checksum": 123, "cpu_ms": 30,
             "dom_mutation_and_forced_layout_ms": 3, "work_end_to_first_raf_ms": 4,
             "raf_interval_ms": 16.67, "layout_height_css_px": 30000, "layout_width_css_px": 760}
    metrics = {"batch_id": "batch-" + browser, "state": state,
               "clock_probe": {"observed_min_positive_step_ms": 1}, "article_width_css_px": 760}
    if event == "renderer_complete":
        metrics["repetitions"] = [{"repetition": index, "warmups_excluded": 2,
                                  "trials": [{**trial, "trial": number} for number in range(10)]} for index in range(3)]
    elif event == "cadence_complete":
        metrics["intervals"] = [{"index": index, "raf_timestamp_interval_ms": 8.33, "callback_interval_ms": 8.33} for index in range(120)]
    elif event == "page_handoff":
        metrics.update({"visibility_to_second_raf_ms": 18, "state_retained_since_arm": True})
    return {"client": {"run_id": "test", "block_id": "B01", "browser": browser, "phase": "renderer",
                       "condition": "default", "workload": "renderer", "page_id": "01", "event": event,
                       "event_id": event_id or browser + ":" + event, "document_id": document, "revision": REVISION,
                       "visibility": "visible", "focused": True, "viewport_css_px": {"width": 900, "height": 600},
                       "device_pixel_ratio": 2, "metrics": metrics}}


class ReportingTests(unittest.TestCase):
    def test_matched_block_and_quantization(self):
        report = make_report([sample(browser) for browser in ("Bam", "Arc", "Yab")])
        result = report["matched_blocks"][0]["comparisons"]["renderer_batches"]
        self.assertTrue(result["eligible"])
        self.assertEqual(result["browser_batches"]["Bam"]["trial_summaries_ms"]["cpu_ms"]["n"], 30)
        self.assertIn("dom_median_under_20_observed_clock_steps_no_precise_ratio", result["browser_batches"]["Bam"]["warnings"])

    def test_all_batches_and_aborts_retained(self):
        rows = [sample(browser) for browser in ("Bam", "Arc", "Yab")]
        rows.append(sample("Bam", "renderer_complete", "Bam:second-batch"))
        rows.append(sample("Bam", "renderer_aborted"))
        report = make_report(rows)
        bam = next(group for group in report["groups"] if group["browser"] == "Bam")
        self.assertEqual(len(bam["renderer_batches"]), 2)
        self.assertEqual(len(bam["errors"]), 1)
        comparison = report["matched_blocks"][0]["comparisons"]["renderer_batches"]
        self.assertFalse(comparison["eligible"])
        self.assertTrue(any("aborted" in reason for reason in comparison["exclusion_reasons"]))

    def test_geometry_mismatch_is_not_silently_pooled(self):
        rows = [sample(browser) for browser in ("Bam", "Arc", "Yab")]
        rows[1]["client"]["viewport_css_px"]["width"] += 1
        comparison = make_report(rows)["matched_blocks"][0]["comparisons"]["renderer_batches"]
        self.assertFalse(comparison["eligible"])
        self.assertIn("viewport_or_dpr_mismatch", comparison["exclusion_reasons"])

    def test_wrong_width_work_count_and_background_are_invalid(self):
        for kind in ("width", "count", "foreground"):
            row = sample()
            value = row["client"]
            if kind == "width": value["metrics"]["repetitions"][0]["trials"][0]["layout_width_css_px"] = 759
            elif kind == "count": value["metrics"]["repetitions"][0]["trials"][0]["cpu_iterations"] = 500000
            else: value["focused"] = False
            batch = make_report([row])["groups"][0]["renderer_batches"][0]
            self.assertFalse(batch["valid"], kind)

    def test_cadence_count_and_handoff_retention(self):
        row = sample(event="cadence_complete")
        group = make_report([row])["groups"][0]
        self.assertTrue(group["cadence_batches"][0]["valid"])
        self.assertEqual(group["cadence_batches"][0]["raf_timestamp_interval_ms"]["n"], 120)
        row["client"]["metrics"]["intervals"].pop()
        self.assertFalse(make_report([row])["groups"][0]["cadence_batches"][0]["valid"])
        valid = sample(event="page_handoff")
        lost = copy.deepcopy(valid)
        lost["client"]["event_id"] = "Bam:lost"
        lost["client"]["metrics"]["state_retained_since_arm"] = False
        group = make_report([valid, lost])["groups"][0]
        self.assertEqual(len(group["handoffs"]), 2)
        self.assertEqual(group["valid_handoff_second_raf_ms"]["n"], 1)
        self.assertEqual(group["excluded_handoff_count"], 1)

    def test_handoff_chrome_focus_is_recorded_not_excluded(self):
        row = sample(event="page_handoff")
        row["client"]["focused"] = False
        group = make_report([row])["groups"][0]
        self.assertTrue(group["handoffs"][0]["valid"])
        self.assertEqual(group["handoffs_by_document_focus"]["false"]["n"], 1)
        row["client"]["visibility"] = "hidden"
        self.assertFalse(make_report([row])["groups"][0]["handoffs"][0]["valid"])

    def test_document_replacement_and_slow_trials_remain(self):
        original = sample()
        slow = original["client"]["metrics"]["repetitions"][0]["trials"][0]
        slow["cpu_ms"] = 3000
        replacement = sample(event="ready")
        replacement["client"]["document_id"] = "reloaded-document"
        group = make_report([original, replacement])["groups"][0]
        self.assertEqual(group["pages_with_document_replacement"], ["01"])
        self.assertEqual(group["renderer_batches"][0]["trial_summaries_ms"]["cpu_ms"]["max"], 3000)

    def test_balanced_reproducible_plan(self):
        plan = make_plan("test", 123, "http://127.0.0.1:8767")
        self.assertEqual(plan, make_plan("test", 123, "http://127.0.0.1:8767"))
        self.assertEqual(len({tuple(block["order"]) for block in plan["blocks"]}), 6)
        for position in range(3):
            self.assertEqual(Counter(block["order"][position] for block in plan["blocks"]), {"Bam": 2, "Arc": 2, "Yab": 2})
        for block in plan["blocks"]:
            routes = [session["tab_destination_route"] for session in block["sessions"]]
            self.assertEqual(routes[0], routes[1])
            self.assertEqual(routes[1], routes[2])
            self.assertEqual(len(routes[0]), 19)
            self.assertEqual(set(routes[0]), set(range(1, 11)))


class CollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="selfcheck-", dir=ROOT)
        cls.server = FixtureServer(0, pathlib.Path(cls.temp.name))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(); cls.temp.cleanup()

    def request(self, method, path, data=None, **headers):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        body = json.dumps(data) if data is not None else None
        connection.request(method, path, body=body, headers={"Content-Type": "application/json", **headers})
        response = connection.getresponse()
        status = response.status
        raw = response.read()
        connection.close()
        return status, raw

    def test_assets_manifest_and_origin_boundary(self):
        status, raw = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["revision"], REVISION)
        self.assertEqual(manifest()["workload"]["cpu_iterations_per_trial"], CPU_ITERATIONS)
        self.assertFalse(manifest()["transport"]["keepalive"])
        self.assertTrue(manifest()["transport"]["response_body_consumed"])
        self.assertIn("selfcheck-transport.cjs", manifest()["source_sha256"])
        for asset in ("/fixture", "/fixture.js", "/style.css"):
            self.assertEqual(self.request("GET", asset)[0], 200)
        self.assertEqual(self.request("GET", "/../PROTOCOL.md")[0], 404)
        self.assertEqual(self.request("GET", "/health", Host="example.com")[0], 403)
        self.assertEqual(self.request("POST", "/results", sample()["client"], Origin="https://example.com")[0], 403)

    def test_output_directory_refuses_old_revision_without_rewriting(self):
        folder = pathlib.Path(self.temp.name) / "old-revision"
        folder.mkdir()
        old = sample(event="ready")["client"]; old["revision"] = "perf-round2-v1"
        original = json.dumps({"client": old}) + "\n"
        path = folder / "results.jsonl"; path.write_text(original)
        with self.assertRaisesRegex(ValueError, "different fixture revision"):
            FixtureServer(0, folder)
        self.assertEqual(path.read_text(), original)

    def test_long_persistent_transport_and_acknowledgments(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        transferred = 0
        try:
            for index in range(128):
                value = sample(event="page_handoff", event_id=f"transport:{index}")["client"]
                value["run_id"] = "transport-sequence"
                value["metrics"]["padding"] = "x" * 2048
                body = json.dumps(value); transferred += len(body.encode())
                connection.request("POST", "/results", body=body, headers={"Content-Type": "application/json"})
                response = connection.getresponse()
                acknowledgment = json.loads(response.read())
                self.assertEqual(response.status, 200)
                self.assertEqual(acknowledgment, {"ok": True, "duplicate": False, "event_id": value["event_id"]})
            self.assertGreater(transferred, 65536)
        finally:
            connection.close()
        status, raw = self.request("GET", "/results?run=transport-sequence")
        self.assertEqual(status, 200)
        values = json.loads(raw)["records"]
        self.assertEqual(len(values), 128)
        self.assertEqual([row["client"]["event_id"] for row in values], [f"transport:{index}" for index in range(128)])
        stale = sample(event="ready", event_id="stale-v1")["client"]
        stale["revision"] = "perf-round2-v1"
        self.assertEqual(self.request("POST", "/results", stale)[0], 400)

    def test_append_dedup_filter_and_bad_payload(self):
        value = sample()["client"]
        self.assertEqual(self.request("POST", "/results", value)[0], 200)
        status, raw = self.request("POST", "/results", value)
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(raw)["duplicate"])
        status, raw = self.request("GET", "/results?block=B01&browser=Bam")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)["count"], 1)
        self.assertEqual(self.request("GET", "/report")[0], 200)
        bad = copy.deepcopy(value); bad["revision"] = "perf-match-v2"
        self.assertEqual(self.request("POST", "/results", bad)[0], 400)
        bad = copy.deepcopy(value); bad["metrics"]["repetitions"][0]["trials"].pop()
        self.assertEqual(self.request("POST", "/results", bad)[0], 400)
        bad = sample(event="cadence_complete")["client"]; bad["metrics"]["intervals"].pop()
        self.assertEqual(self.request("POST", "/results", bad)[0], 400)
        self.assertEqual(len(self.server.path.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
