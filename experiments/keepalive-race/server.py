"""Stand-in model server: FastAPI on uvicorn, started the way vLLM v0.34.0
starts its API server (uvicorn.Config with timeout_keep_alive from
VLLM_HTTP_TIMEOUT_KEEP_ALIVE, default 5 s; loop and HTTP parser on "auto").
Only the HTTP layer matters here: the race is between uvicorn closing an idle
connection and Envoy reusing it. POST /v1/completions waits SERVE_MS and
returns a small JSON body."""
import asyncio
import os

import uvicorn
from fastapi import FastAPI

app = FastAPI()
SERVE_MS = float(os.environ.get("SERVE_MS", "20"))


@app.post("/v1/completions")
async def completions():
    await asyncio.sleep(SERVE_MS / 1000)
    return {"choices": [{"text": "ok"}]}


if __name__ == "__main__":
    keep_alive = int(os.environ.get("VLLM_HTTP_TIMEOUT_KEEP_ALIVE", "5"))
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")),
                timeout_keep_alive=keep_alive, access_log=False, log_level="warning")
