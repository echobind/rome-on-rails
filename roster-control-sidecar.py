#!/opt/hermes/.venv/bin/python
"""
Roster control sidecar — a tiny HTTP service for remote LLM-model control.

Runs alongside the Hermes gateway in every rome-on-rails container so Roster
can read and change the agent's LLM model over the tailnet. The Hermes gateway
reads its model only from $HERMES_HOME/config.yaml; this service is Roster's
write path to that file.

Built to docs/hermes-control-sidecar-contract.md (contract version 1).
  GET  /healthz  - liveness, no auth
  GET  /model    - read model.provider / model.default       (bearer auth)
  POST /model    - write them, optionally restart the gateway (bearer auth)

Started backgrounded by entrypoint.sh, and only when ROSTER_CONTROL_TOKEN is
set. Runs as the `hermes` user (via gosu) so config.yaml stays hermes-owned —
identical to every other writer of that file. Binds 127.0.0.1 only; entrypoint.sh
bridges it onto the tailnet with `tailscale serve`.

STARTUP MUST NOT TOUCH /opt/data. entrypoint.sh launches this process before
the upstream entrypoint chowns /opt/data to the hermes user. Startup only reads
env vars and binds a TCP port; config.yaml is touched on request only, long
after the container has finished booting. Do not add a "validate config on
boot" step here — it would race the chown.
"""
import hmac
import os
import subprocess
import sys

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from hermes_cli.config import load_config, save_config

CONTRACT_VERSION = 1
SERVICE_NAME = "roster-control-sidecar"

# Fail closed (contract §4): with no token the sidecar must not run at all — a
# half-open control surface is worse than no control surface. entrypoint.sh
# also guards on this; exiting here is the backstop. The Hermes gateway is a
# separate process and is unaffected.
CONTROL_TOKEN = os.environ.get("ROSTER_CONTROL_TOKEN", "")
if not CONTROL_TOKEN:
    sys.exit("[roster-control-sidecar] ROSTER_CONTROL_TOKEN is unset — refusing to start.")

app = FastAPI()


def _error(status, message):
    """Every error body is {"error": "<message>"} (contract §3)."""
    return JSONResponse(status_code=status, content={"error": message})


def _authorized(request):
    """Constant-time bearer-token check (contract §4). Compares bytes so a
    non-ASCII Authorization header can't raise instead of cleanly failing."""
    expected = f"Bearer {CONTROL_TOKEN}".encode()
    provided = request.headers.get("authorization", "").encode()
    return hmac.compare_digest(provided, expected)


@app.exception_handler(StarletteHTTPException)
async def _normalize_errors(request, exc):
    # Keep framework-raised errors (e.g. 404 on an unknown route) in the
    # contract's {"error": ...} body shape.
    return JSONResponse(status_code=exc.status_code, content={"error": str(exc.detail)})


@app.get("/healthz")
def healthz():
    return {"ok": True, "service": SERVICE_NAME, "contract": CONTRACT_VERSION}


@app.get("/model")
def get_model(request: Request):
    if not _authorized(request):
        return _error(401, "missing or invalid bearer token")
    try:
        model_cfg = load_config().get("model")
    except Exception as exc:
        return _error(500, f"failed to read config.yaml: {exc}")
    # Mirror Hermes' _resolve_gateway_model precedence; empty strings, not null.
    if isinstance(model_cfg, dict):
        provider = model_cfg.get("provider") or ""
        model = model_cfg.get("default") or model_cfg.get("model") or ""
    elif isinstance(model_cfg, str):
        provider, model = "", model_cfg
    else:
        provider, model = "", ""
    return {"provider": provider, "model": model}


@app.post("/model")
async def set_model(request: Request):
    if not _authorized(request):
        return _error(401, "missing or invalid bearer token")
    try:
        body = await request.json()
    except Exception:
        return _error(400, "malformed JSON body")
    if not isinstance(body, dict):
        return _error(400, "request body must be a JSON object")

    provider, model = body.get("provider"), body.get("model")
    if not isinstance(provider, str) or not provider.strip():
        return _error(400, "'provider' is required and must be a non-empty string")
    if not isinstance(model, str) or not model.strip():
        return _error(400, "'model' is required and must be a non-empty string")
    restart = body.get("restart", True)
    if not isinstance(restart, bool):
        return _error(400, "'restart' must be a boolean")

    # Write config.yaml exactly the way the Hermes dashboard writes the main
    # model slot (contract §6) so the file never drifts from Hermes' own shape.
    try:
        cfg = load_config()
        model_cfg = cfg.get("model")
        if not isinstance(model_cfg, dict):
            model_cfg = {}
        model_cfg["provider"] = provider
        model_cfg["default"] = model
        model_cfg.pop("base_url", None)        # stale base_url would shadow the new provider
        model_cfg.pop("context_length", None)  # let Hermes re-detect the context window
        cfg["model"] = model_cfg
        save_config(cfg)
    except Exception as exc:
        return _error(500, f"failed to write config.yaml: {exc}")

    print(f"[roster-control-sidecar] model set: provider={provider!r} "
          f"model={model!r} restart={restart}", flush=True)

    if not restart:
        return {"ok": True, "provider": provider, "model": model, "restarted": False}

    # Restart the gateway so the change takes effect on the next session.
    # `hermes gateway restart` signals the running gateway (via /opt/data/
    # gateway.pid) to re-exec itself in place — non-blocking. We return as soon
    # as the restart is *spawned*, not when the gateway is back up (contract §7).
    # start_new_session=True fully detaches it from this request's lifecycle.
    try:
        subprocess.Popen(
            ["hermes", "gateway", "restart"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as exc:
        # The config write already succeeded — be explicit so Roster can say so.
        return _error(500, f"model was written to config.yaml, but the gateway "
                           f"restart could not be spawned: {exc}")

    return {"ok": True, "provider": provider, "model": model, "restarted": True}


if __name__ == "__main__":
    try:
        port = int(os.environ.get("ROSTER_CONTROL_PORT", "8765"))
    except ValueError:
        sys.exit("[roster-control-sidecar] ROSTER_CONTROL_PORT must be an integer.")
    # 127.0.0.1 only (contract §2) — entrypoint.sh bridges this onto the tailnet.
    print(f"[roster-control-sidecar] starting on 127.0.0.1:{port} "
          f"(contract v{CONTRACT_VERSION})", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")
