# Hermes Control Sidecar — Interface Contract

**Status:** Draft v1 · 2026-05-15
**Owners:** Roster (`echobind/agent-org-chart`) ↔ rome-on-rails (`echobind/rome-on-rails`)

This document is the **shared source of truth** for the "control sidecar" — a tiny
HTTP service that runs alongside the Hermes gateway in every rome-on-rails
container and lets Roster read and change the agent's LLM model over the tailnet.

Both repos build against this contract:

- **rome-on-rails** implements the sidecar (the server) + exposes it on the tailnet.
- **Roster** implements the client (a tRPC procedure that calls it).

If either side needs to deviate, change *this file first* and flag it to the other repo.

---

## 1. Why this exists

The Hermes gateway reads its LLM model **only** from `config.yaml` (`model.default` /
`model.provider`) — it does not honor `HERMES_INFERENCE_MODEL` env vars in gateway
mode (verified against upstream `gateway/run.py:_resolve_gateway_model`). Roster has
no write path to that file: no exec into the container, no Railway filesystem API,
and the agents sit behind Tailscale.

The control sidecar closes that gap with the **minimum possible surface**: two
endpoints, bearer-token auth, reachable only from the tailnet. It deliberately does
**not** reuse the full Hermes dashboard (which exposes API-key reveal, a PTY shell,
session data, etc.).

---

## 2. Topology

```
┌─────────────────────────┐         tailnet (WireGuard)        ┌──────────────────────────────┐
│ Roster (Railway service)│  ───────────────────────────────▶ │ rome-on-rails container        │
│                         │   http://<tsHostname>:<port>/model │                                │
│ tailscaled (userspace)  │                                    │  hermes gateway run  (PID-ish) │
│ Next.js server          │                                    │  tailscaled (userspace)        │
│ control-sidecar client  │                                    │  control sidecar  ◀── this doc │
└─────────────────────────┘                                    │    127.0.0.1:<port>            │
                                                                │  tailscale serve → tailnet     │
                                                                └──────────────────────────────┘
```

- The sidecar listens on **`127.0.0.1` inside the container** (never `0.0.0.0` —
  userspace-mode tailscaled does not plumb the tailnet into the kernel, so binding
  wide gains nothing and only widens exposure).
- rome-on-rails is responsible for **exposing it on the tailnet** (see §8) so other
  tailnet nodes can reach it as `http://<tsHostname>:<port>`.
- Transport is **plain HTTP** — exposed via `tailscale serve --http`, not `--tcp`
  (which terminates TLS at the tailnet edge using the MagicDNS cert and forces
  clients into `.ts.net` FQDNs or cert-verification opt-outs). The tailnet
  already encrypts everything end-to-end (WireGuard); the bearer token is the
  authorization layer. No TLS cert wrangling, no client-side workarounds.

---

## 3. HTTP API

Base URL, as seen by Roster: `http://<tsHostname>:<ROSTER_CONTROL_PORT>`
where `<tsHostname>` is the agent's Tailscale hostname (Roster already stores this
as `agents.tsHostname`).

All responses are `application/json`. All error bodies are `{"error": "<message>"}`.

### `GET /healthz` — liveness (no auth)

Used by Roster to check the sidecar is reachable before/independently of an auth'd call.

```
200 OK
{ "ok": true, "service": "roster-control-sidecar", "contract": 1 }
```

### `GET /model` — read current model (auth required)

Reads `config.yaml` and returns the gateway's main model slot.

```
200 OK
{ "provider": "openrouter", "model": "anthropic/claude-opus-4.7" }
```

- If `config.yaml` has no model configured, return empty strings, not null:
  `{ "provider": "", "model": "" }`.
- `provider` is `model.provider`; `model` is `model.default` (fall back to
  `model.model`, then a bare-string `model:` value — mirror Hermes'
  `_resolve_gateway_model` precedence).

### `POST /model` — set the model (auth required)

```
POST /model
Content-Type: application/json
{ "provider": "openrouter", "model": "anthropic/claude-opus-4.7", "restart": true }
```

| Field      | Type    | Required | Notes |
|------------|---------|----------|-------|
| `provider` | string  | yes      | Non-empty. Written verbatim to `model.provider`. |
| `model`    | string  | yes      | Non-empty. Written verbatim to `model.default`. |
| `restart`  | boolean | no       | Default **`true`**. If true, restart the gateway after writing (see §6). |

Success:

```
200 OK
{ "ok": true, "provider": "openrouter", "model": "anthropic/claude-opus-4.7", "restarted": true }
```

The sidecar does **not** validate that the model exists or is valid for the provider
— that is Roster's job (via the model picker) and OpenRouter's job (at call time).
Keep the sidecar dumb: it writes what it's told.

### Status codes

| Code | When |
|------|------|
| 200  | Success |
| 400  | Malformed JSON, or missing/empty `provider`/`model` |
| 401  | Missing or invalid bearer token (on any auth'd route) |
| 404  | Unknown route |
| 500  | `config.yaml` write failed, or gateway restart could not be spawned |

---

## 4. Authentication

- Every route **except `GET /healthz`** requires:
  `Authorization: Bearer <ROSTER_CONTROL_TOKEN>`
- Compare with a **constant-time** comparison (`hmac.compare_digest`), not `==`.
- The token is a per-agent secret. Roster generates it, stores it encrypted, and
  injects it as a Railway env var at provisioning time (see §5). Roster sends it on
  every call.
- **Fail closed:** if `ROSTER_CONTROL_TOKEN` is unset/empty in the environment, the
  sidecar must **not start** (log a clear warning and exit the sidecar process
  only — the Hermes gateway must keep running regardless). An agent with no control
  token is simply not remotely controllable; that's acceptable, a half-open sidecar
  is not.

---

## 5. Environment variables (consumed by rome-on-rails / the sidecar)

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `ROSTER_CONTROL_TOKEN` | yes (to enable the sidecar) | — | Bearer token. Set per-agent by Roster as a Railway template variable. Absent ⇒ sidecar disabled. |
| `ROSTER_CONTROL_PORT`  | no | `8765` | Local port the sidecar binds on `127.0.0.1`. |
| `HERMES_HOME`          | (already set) | `/opt/data` | The sidecar reads/writes `$HERMES_HOME/config.yaml`. Already set by the upstream Hermes image. |

rome-on-rails must add `ROSTER_CONTROL_TOKEN` (and optionally `ROSTER_CONTROL_PORT`)
to the **Railway template variable list** so Roster can populate it at deploy time —
same way `OPENROUTER_API_KEY`, `SLACK_BOT_TOKEN`, etc. are declared today. Document
it in `railway/template-notes.md`.

---

## 6. `config.yaml` write behavior

The sidecar runs **inside the rome-on-rails container**, which has the Hermes Python
venv at `/opt/hermes/.venv`. Strongly recommended: **reuse Hermes' own config
primitives** rather than hand-parsing YAML —

```python
from hermes_cli.config import load_config, save_config
```

`POST /model` must mirror the Hermes dashboard's `set_model_assignment` logic for the
**main** slot (see upstream `hermes_cli/web_server.py`):

1. `cfg = load_config()`
2. `cfg["model"]` → ensure dict; set `["provider"] = provider`, `["default"] = model`
3. **Clear `model.base_url`** if set (stale base URL would override the new provider)
4. **Drop `model.context_length`** if present (the new model may have a different
   context window; let Hermes auto-detect)
5. `save_config(cfg)`

This guarantees the sidecar writes the exact same file, in the exact same shape, that
Hermes itself would — no drift.

The sidecar process runs as the **`hermes` user** (UID 10000) — `entrypoint.sh`
starts it via `gosu`. So `config.yaml` is written by the same user that owns it and
that the gateway / dashboard / a maintainer's `hermes config set` all write it as:
no ownership drift, no root-owned files left in `/opt/data`. (rome-on-rails
implementation detail, recorded so Roster knows the write is indistinguishable from
Hermes' own.)

Concurrency: single-writer assumption is fine for v1 (Roster is the only automated
caller; a human running `hermes config set` over SSH is rare and self-inflicted). No
file locking required for v1.

---

## 7. Gateway restart behavior

Writing `config.yaml` alone **applies to new Hermes sessions only** — an in-flight
conversation keeps the old model (confirmed: the dashboard's `/api/model/set` has the
same caveat). For Roster's UX, an operator who changes the model expects it to
actually take effect.

- When `restart` is `true` (the default), the sidecar restarts the gateway after a
  successful config write. Use the supported path: spawn `hermes gateway restart`
  (this is exactly what the dashboard's `/api/gateway/restart` does —
  `_spawn_hermes_action(["gateway", "restart"])`).
- Spawn it **detached / non-blocking** — do not make the HTTP response wait on the
  gateway coming back up. Return `200` once the config is written and the restart is
  *spawned*. `"restarted": true` in the response means "restart was triggered", not
  "gateway is back up".
- If `restart` is `false`, write config only and return `"restarted": false`. (Roster
  may use this for a future "stage the change, apply later" flow; not used in v1.)
- If the restart spawn itself fails, the config write has already succeeded — return
  `500` with a body that makes clear the model **was** written but the restart
  failed, so Roster can surface an accurate message.

---

## 8. rome-on-rails responsibilities (summary)

1. **Ship the sidecar** as a small HTTP service. Recommended: a ~60-line FastAPI app
   — FastAPI + uvicorn are already in the Hermes venv (the dashboard uses them), so
   no new runtime dependencies.
2. **Start it from `entrypoint.sh`**, backgrounded, the same way `tailscaled` is
   backgrounded today — before the `exec` into the upstream Hermes entrypoint. Only
   start it if `ROSTER_CONTROL_TOKEN` is set.
3. **Expose it on the tailnet.** Userspace-mode `tailscaled` does not route inbound
   tailnet traffic to local sockets, so `tailscale serve` (or equivalent) is
   **required** to bridge `tailnet:<port>` → `127.0.0.1:<ROSTER_CONTROL_PORT>`. The
   end state Roster depends on: other tailnet nodes can reach the sidecar at
   `http://<tsHostname>:<ROSTER_CONTROL_PORT>`.
   *(Open decision — see §10.)*
4. **Declare `ROSTER_CONTROL_TOKEN` / `ROSTER_CONTROL_PORT`** as Railway template
   variables and document them in `railway/template-notes.md`.
5. **Do not expose any public port.** No `EXPOSE`, no Railway domain — same posture
   as today. The sidecar is tailnet-only.

## 9. Roster responsibilities (summary — for context, specced elsewhere)

- Roster's own Railway service joins the tailnet (userspace `tailscaled`) and routes
  server-side fetches through the tailscaled proxy.
- At `agents.createFromTemplate`, Roster mints `ROSTER_CONTROL_TOKEN`, injects it via
  the template variables, and stores it encrypted on the agent row (AAD = `agent.id`).
- `agents.getModel` / `agents.setModel` tRPC procedures call this API.
- The model picker only renders for OpenRouter agents in v1; the sidecar itself is
  provider-agnostic.

---

## 10. Open decisions for the rome-on-rails implementer

**Resolved by rome-on-rails on 2026-05-14** (against pinned Hermes
`nousresearch/hermes-agent:v2026.4.16`). Recorded here so Roster builds against
the same choices.

1. **Tailnet exposure mechanism — `tailscale serve --bg --http`, same port both
   sides.** `entrypoint.sh` runs:

   ```
   tailscale serve --bg --http=<ROSTER_CONTROL_PORT> http://127.0.0.1:<ROSTER_CONTROL_PORT>
   ```

   Plain HTTP forwarding: the tailnet-facing port equals the local bind port, so
   the sidecar is reachable at exactly `http://<tsHostname>:<ROSTER_CONTROL_PORT>`
   with no port translation for Roster to track. **Roster: keep using one port
   number for both the local bind and the tailnet address.**

   **Revised 2026-05-15** (was `--tcp`, see issue #6): `--tcp` is documented as
   "raw TCP" but in practice `tailscale serve --tcp=<port>` terminates TLS at the
   tailnet edge using the node's MagicDNS certificate. Clients connecting to
   `http://<tsHostname>:<port>` get a TLS handshake instead, and the only way to
   reach the sidecar is either the `.ts.net` FQDN with cert verification, or
   disabling cert verification client-side — both of which contradict §2's "plain
   HTTP over the already-encrypted tailnet" promise and force Roster into
   per-environment URL/verify workarounds. `--http` is the correct knob: it
   exposes the backend as actual HTTP on the tailnet, no TLS termination, no cert
   provisioning. WireGuard still encrypts the tailnet hop end-to-end, and the
   bearer token still authenticates the caller. Also rejected: `tailscale serve
   --https` (would require cert provisioning and re-introduces the same FQDN
   constraint we are trying to escape).

2. **Sidecar framework — FastAPI + uvicorn.** Both are already in the Hermes venv
   (`/opt/hermes/.venv` — verified: FastAPI 0.136.0, uvicorn 0.44.0, PyYAML
   6.0.3), so the sidecar adds no new pip dependencies. It runs on the venv's
   Python so it can also `import hermes_cli.config`. No contract impact.

3. **Restart command — `hermes gateway restart`** (no flags), spawned
   detached/non-blocking via `subprocess.Popen([...], start_new_session=True)`.
   Verified against the pinned image by tracing `hermes_cli/gateway.py`:

   - The bare invocation targets the **running foreground gateway**, located via
     `$HERMES_HOME/gateway.pid` (`gateway.status.get_running_pid()`). The
     `--system` flag is the opt-in for the systemd/launchd unit, which
     rome-on-rails does **not** use — so the bare form is correct here.
   - It calls `_request_gateway_self_restart(pid)`, which signals the gateway to
     **re-exec itself in place** (same PID). Because `hermes gateway run` is PID 1
     in the container, the container does not exit and the sidecar — a sibling
     process — survives the restart. The call is asynchronous, matching §7.

   The `hermes` CLI is on `PATH` in the container (symlinked to
   `/usr/local/bin/hermes`).

**Implementation note (not an open decision, recorded for Roster's awareness):**
the sidecar process runs as the **`hermes` user** (UID 10000), started via `gosu`
from `entrypoint.sh`. This keeps `config.yaml` ownership identical to every other
writer of that file (the gateway, the dashboard, a maintainer's `hermes config
set` over SSH) — see §6.

---

## 11. Out of scope for v1

- Auxiliary model slots (vision/compression/etc.) — `model.auxiliary.*`. Only the
  **main** model slot is in scope.
- Any endpoint beyond `/healthz` and `/model` — no logs, no status, no config dump.
  (Those may come later as separate, separately-reviewed additions.)
- Model validation, model listing — Roster owns the picker; OpenRouter validates at
  call time.
- Multi-writer coordination / config.yaml locking.
