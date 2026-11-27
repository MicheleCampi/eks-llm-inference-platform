#!/usr/bin/env python3
"""Stand-in for vLLM's streaming /v1/completions, for the CI smoke test of
replay.py and report.py only (no model, no numbers worth reading): sleeps in
proportion to the prompt, streams max_tokens chunks, then a usage chunk."""
import json, time, random
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def do_POST(self):
        b=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        n=b['max_tokens']; p=len(b['prompt'].split())
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Connection','close'); self.end_headers()
        time.sleep(0.0005*p)
        for i in range(n):
            self.wfile.write(b'data: {"choices":[{"text":"x"}]}\n\n'); self.wfile.flush(); time.sleep(0.002)
        self.wfile.write(('data: '+json.dumps({"choices":[],"usage":{"prompt_tokens":int(p*1.2),"completion_tokens":n}})+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
import sys
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 18000), H).serve_forever()
