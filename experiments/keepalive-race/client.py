"""Requests through Envoy with an idle gap before each one.

Every request goes to the upstream named in DEST, sent as
x-gateway-destination-endpoint (what the EPP sets in the chart); with DEST
empty (on kind, through the EPP) the EPP picks it. One client connection to Envoy, so the
same Envoy worker and, while it lives, the same pooled upstream connection
serve every request. Before request i the client waits gap_i, drawn
uniformly from [GAP_MIN, GAP_MAX] seconds, so the idle time of the pooled
connection sweeps across the server's keep-alive timeout.
Prints one JSON line per request: gap, status, body head, e2e seconds."""
import asyncio
import json
import os
import random
import sys
import time

import aiohttp

URL = os.environ.get("URL", "http://127.0.0.1:8081/v1/completions")
DEST = os.environ.get("DEST", "")
MODEL = os.environ.get("MODEL", "stand-in")
PROMPT = os.environ.get("PROMPT", "x")
N = int(os.environ.get("N", "200"))
GAP_MIN = float(os.environ.get("GAP_MIN", "4.9"))
GAP_MAX = float(os.environ.get("GAP_MAX", "5.1"))
SEED = int(os.environ.get("SEED", "20261126"))


async def main():
    rnd = random.Random(SEED)
    conn = aiohttp.TCPConnector(limit=1, keepalive_timeout=3600)
    async with aiohttp.ClientSession(connector=conn) as s:
        for i in range(N):
            gap = rnd.uniform(GAP_MIN, GAP_MAX) if i else 0.0
            await asyncio.sleep(gap)
            t0 = time.perf_counter()
            try:
                hdr = {"x-gateway-destination-endpoint": DEST} if DEST else {}
                async with s.post(URL, json={"model": MODEL, "prompt": PROMPT, "max_tokens": 1},
                                  headers=hdr) as r:
                    body = await r.text()
                    code = r.status
            except Exception as e:  # noqa: BLE001 - any client error is recorded
                code, body = -1, repr(e)
            print(json.dumps({"i": i, "gap": round(gap, 4), "code": code,
                              "body": body[:120], "e2e": round(time.perf_counter() - t0, 4)}),
                  flush=True)


asyncio.run(main())
