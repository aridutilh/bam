#!/usr/bin/env python3
"""Loopback-only, dependency-free common browser fixture and result collector."""
import argparse
import hashlib
import json
import math
import pathlib
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = pathlib.Path(__file__).resolve().parent
from report import REVISION, CPU_ITERATIONS, make_report

ASSETS = {"/": "fixture.html", "/launcher": "fixture.html", "/fixture": "fixture.html",
          "/fixture.js": "fixture.js", "/style.css": "style.css", "/frame": "frame.html", "/frame.js": "frame.js"}
NOTES = {
    "initialization_ms": "Page-script duration to build the fixture, including allocation; not navigation or paint.",
    "navigation": "Navigation Timing clocks for loopback HTTP and DOM/load events; never first paint.",
    "cpu_ms": "Fixed 20000000-iteration integer loop in the renderer, measured with performance.now().",
    "dom_mutation_and_forced_layout_ms": "400 row mutations and synchronous article-host height/width reads; fixed 760 CSS-pixel article width.",
    "raf": "JavaScript requestAnimationFrame callback scheduling; does not establish displayed pixels.",
    "page_handoff": "Visibility event to second rAF callback, with state checks; excludes input dispatch, browser selection and compositor/presentation.",
    "memory": "Fixture allocations are workload definitions, not measured browser memory. Sample attributed processes externally.",
}


def manifest():
    return {"revision": REVISION, "fixture_sha256": {
        name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        for name in ("fixture.html", "fixture.js", "style.css")},
        "wrapper_sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                           for name in ("frame.html", "frame.js")},
        "wrapper_condition": {"name": "fixed-frame", "width_css_px": 800, "height_css_px": 640,
                              "scope": "Same-origin embedded renderer/cadence only; not native tab handoff or top-level page performance."},
        "workload": {"article_rows": 400, "article_width_css_px": 760, "allocation_bytes": 4 * 1024 * 1024,
                     "allocation_pattern": "(index * 17 + 31) % 251, every byte written",
                     "renderer_repetitions": 3, "trials_per_repetition": 10,
                     "warmups_per_repetition": 2, "cpu_iterations_per_trial": CPU_ITERATIONS, "cadence_intervals": 120, "maximum_live_pages": 10},
        "transport": {"keepalive": False, "response_body_consumed": True,
                      "acknowledgment": "HTTP success plus matching accepted event_id; no automatic retry"},
        "source_sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                          for name in ("fixture.js", "server.py", "report.py", "plan.py", "selfcheck.py",
                                       "selfcheck-auto.cjs", "selfcheck-transport.cjs")},
        "metric_notes": NOTES}



class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, output):
        super().__init__(("127.0.0.1", port), Handler)
        self.output = pathlib.Path(output).resolve()
        if not self.output.is_relative_to(ROOT):
            self.server_close()
            raise ValueError("Output must be inside the performance fixture directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.rows = []
        self.ids = set()
        self.path = self.output / "results.jsonl"
        if self.path.exists():
            for line in self.path.read_text().splitlines():
                record = json.loads(line)
                if record.get("client", {}).get("revision") != REVISION:
                    self.server_close()
                    raise ValueError("Existing results use a different fixture revision; choose a new output directory")
                self.rows.append(record)
                self.ids.add(record["client"]["event_id"])
        self.origin = "http://127.0.0.1:" + str(self.server_port)
        self.session_id = uuid.uuid4().hex
        (self.output / ("server-" + self.session_id + ".json")).write_text(json.dumps({
            **manifest(), "server_session_id": self.session_id, "origin": self.origin,
            "started_unix_ms": time.time_ns() / 1e6}, indent=2) + "\n")


class Handler(BaseHTTPRequestHandler):
    server_version = "PerfRound2/2"

    def log_message(self, _format, *_args):
        pass

    def allowed(self):
        return self.headers.get("Host") == self.server.origin.removeprefix("http://") and self.headers.get("Origin", self.server.origin) == self.server.origin

    def send(self, status, body, content_type="application/json", embeddable=False):
        data = body if isinstance(body, bytes) else json.dumps(body, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        ancestors = "'self'" if embeddable else "'none'"
        self.send_header("Content-Security-Policy", "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-src 'self'; frame-ancestors " + ancestors)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.allowed():
            return self.send(403, {"error": "Loopback origin required"})
        request = urlsplit(self.path)
        if request.path in ASSETS:
            name = ASSETS[request.path]
            content_type = "text/css" if name.endswith(".css") else "text/javascript" if name.endswith(".js") else "text/html"
            embeddable = request.path == "/fixture" and parse_qs(request.query).get("condition") == ["fixed-frame"]
            return self.send(200, (ROOT / name).read_bytes(), content_type, embeddable=embeddable)
        if request.path == "/health":
            return self.send(200, {"ok": True, "revision": REVISION, "origin": self.server.origin})
        if request.path == "/manifest.json":
            return self.send(200, manifest())
        if request.path in ("/results", "/report"):
            query = parse_qs(request.query)
            with self.server.lock:
                rows = list(self.server.rows)
            for parameter, field in (("run", "run_id"), ("browser", "browser"), ("workload", "workload"), ("page", "page_id"), ("block", "block_id"), ("condition", "condition"), ("phase", "phase")):
                if parameter in query:
                    rows = [row for row in rows if row["client"][field] == query[parameter][0]]
            return self.send(200, make_report(rows) if request.path == "/report" else {"count": len(rows), "records": rows})
        self.send(404, {"error": "Not found"})

    def do_POST(self):
        if not self.allowed():
            return self.send(403, {"error": "Loopback origin required"})
        if urlsplit(self.path).path != "/results":
            return self.send(404, {"error": "Not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 1024 * 1024:
                raise ValueError("Body must be 1 byte to 1 MiB")
            value = json.loads(self.rfile.read(length), parse_constant=lambda _v: (_ for _ in ()).throw(ValueError("Nonfinite JSON")))
            for field in ("run_id", "block_id", "browser", "condition", "phase", "workload", "page_id", "event", "event_id", "document_id"):
                if not isinstance(value.get(field), str) or not 1 <= len(value[field]) <= 200:
                    raise ValueError("Invalid " + field)
            if value["workload"] not in ("light", "article", "renderer", "cadence", "switch") or not isinstance(value.get("metrics"), dict):
                raise ValueError("Invalid workload or metrics")
            if value.get("revision") != REVISION:
                raise ValueError("Fixture revision mismatch")
            json.dumps(value, allow_nan=False)
            def duration(number):
                return isinstance(number, (int, float)) and not isinstance(number, bool) and math.isfinite(number) and number >= 0
            if value["event"] == "renderer_complete":
                repetitions = value["metrics"].get("repetitions")
                if not isinstance(repetitions, list) or len(repetitions) != 3:
                    raise ValueError("Completed renderer batch requires three repetitions")
                for repetition in repetitions:
                    trials = repetition.get("trials") if isinstance(repetition, dict) else None
                    if not isinstance(trials, list) or len(trials) != 10:
                        raise ValueError("Renderer repetition requires ten trials")
                    for trial in trials:
                        if not isinstance(trial, dict) or not all(duration(trial.get(field)) for field in
                            ("cpu_ms", "dom_mutation_and_forced_layout_ms", "work_end_to_first_raf_ms", "raf_interval_ms")):
                            raise ValueError("Invalid renderer duration")
            if value["event"] == "cadence_complete":
                intervals = value["metrics"].get("intervals")
                if not isinstance(intervals, list) or len(intervals) != 120:
                    raise ValueError("Completed cadence batch requires120 intervals")
                if any(not isinstance(interval, dict) or not all(duration(interval.get(field)) for field in
                       ("raf_timestamp_interval_ms", "callback_interval_ms")) for interval in intervals):
                    raise ValueError("Invalid cadence duration")
            if value["event"] == "page_handoff" and not duration(value["metrics"].get("visibility_to_second_raf_ms")):
                raise ValueError("Invalid handoff duration")
        except (ValueError, TypeError, AttributeError) as error:
            return self.send(400, {"error": str(error)})
        record = {"server_session_id": self.server.session_id, "received_unix_ms": time.time_ns() / 1e6,
                  "received_monotonic_ns": time.monotonic_ns(), "client": value}
        with self.server.lock:
            duplicate = value["event_id"] in self.server.ids
            if not duplicate:
                with self.server.path.open("a") as output:
                    output.write(json.dumps(record, allow_nan=False, separators=(",", ":")) + "\n")
                self.server.rows.append(record)
                self.server.ids.add(value["event_id"])
        self.send(200, {"ok": True, "duplicate": duplicate, "event_id": value["event_id"]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--output-dir", type=pathlib.Path,
                        default=ROOT / "runs" / (time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + uuid.uuid4().hex[:6]))
    args = parser.parse_args()
    with FixtureServer(args.port, args.output_dir) as server:
        print(json.dumps({"origin": server.origin, "output_dir": str(server.output),
                          "launcher": server.origin + "/launcher?run=round2-pilot&block=pilot&browser=Bam&workload=article&tabs=10&arm=1"}), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
