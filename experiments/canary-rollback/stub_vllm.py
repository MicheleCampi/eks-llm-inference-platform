#!/usr/bin/env python3
"""Stand-in for vLLM in the CI smoke test of this experiment only (no model,
no numbers worth reading): streaming /v1/completions, /health, and /metrics
with a `vllm:time_to_first_token_seconds` histogram, so that Prometheus, the
AnalysisTemplate, the Rollout, the watcher and the report run end to end.
With MAX_NUM_SEQS=1 (the bad version) requests are served one at a time, as
vLLM's --max-num-seqs 1 does. Standard library only."""
import json
import os
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BUCKETS = [0.001, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]
counts, total, lock = [0] * len(BUCKETS), [0, 0.0], threading.Lock()
slots = threading.Semaphore(int(os.environ.get("MAX_NUM_SEQS", "256")))


def observe(v):
    with lock:
        for i, b in enumerate(BUCKETS):
            if v <= b:
                counts[i] += 1
        total[0] += 1
        total[1] += v


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/health":
            body = b""
        elif self.path == "/metrics":
            with lock:
                lines = [f'vllm:time_to_first_token_seconds_bucket{{le="{b}",model_name="stub"}} {c}'
                         for b, c in zip(BUCKETS, counts)]
                lines += [f'vllm:time_to_first_token_seconds_bucket{{le="+Inf",model_name="stub"}} {total[0]}',
                          f'vllm:time_to_first_token_seconds_count{{model_name="stub"}} {total[0]}',
                          f'vllm:time_to_first_token_seconds_sum{{model_name="stub"}} {total[1]}']
            body = ("# TYPE vllm:time_to_first_token_seconds histogram\n" + "\n".join(lines) + "\n").encode()
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        # Prometheus 3 refuses a scrape without a Content-Type (vLLM sends this one).
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8"); self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        t0 = time.perf_counter()
        if self.path != "/v1/completions":  # /reset_prefix_cache: nothing to reset
            self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers(); return
        b = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        n, p = b["max_tokens"], len(b["prompt"].split())
        with slots:
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close"); self.end_headers()
            time.sleep(0.001 * p)  # the good version stays well inside T = 1 s (smoke only)
            observe(time.perf_counter() - t0)
            for _ in range(n):
                self.wfile.write(b'data: {"choices":[{"text":"x"}]}\n\n'); self.wfile.flush(); time.sleep(0.03)
            self.wfile.write(("data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": p, "completion_tokens": n}}) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()


ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
