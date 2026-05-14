# CLAUDE.md — rome-on-rails

## What This Project Is

rome-on-rails is a Railway deployment template for Hermes (NousResearch/hermes-agent), an AI agent tool. The goal is a one-click Railway deploy that results in a private, Tailscale-only Hermes instance — Hermes is never exposed to the public internet, and maintainers reach it via `tailscale ssh` from their tailnet.

**Naming:** `rome-on-rails` = this repo and project. `Hermes` = the third-party agent being deployed. Do not conflate them.

## Developer Context

- Early-career developer transitioning from electrical engineering
- Proficient in Node.js, TypeScript, PostgreSQL, REST APIs, and webhooks
- Limited experience with Linux server administration, Docker, Tailscale, and Railway
- Working in VSCode on Windows with a WSL2 terminal
- Prefers clean, readable code over clever solutions
- Expects explanations of unfamiliar concepts — don't just issue commands

## Core Rules

**Before every decision involving a tradeoff:**
1. Explain the options
2. State which is best and why
3. Then implement

**Before recommending any library, package, or tool:** web-search to confirm it is actively maintained and compatible with current versions.

**When debugging:** ask for the error message and relevant code before suggesting fixes. Do not guess.

**Never:**
- Commit secrets or API keys
- Generate a public Railway domain for the Hermes service (even though the container exposes no ports, don't add surface)
- Run `hermes update` in any script (this bypasses version pinning)
- Set `GATEWAY_ALLOW_ALL_USERS=true` anywhere (this disables all allowlists and defeats the access model)
- Add unrelated features — scope is defined in the project description

## Living Documents — Always Update

These three files are required deliverables. Update them as part of every response that makes a decision or changes the architecture. Do not wait to be asked.

| File | What changes trigger an update |
|---|---|
| `ARCHITECTURE.md` | Any structural decision, new component, or change to data flow |
| `README.md` | Any change to setup steps, env vars, or security model |
| `HANDOFF.md` | Any new risk identified, decision rationale worth preserving |

## Project Structure

```
rome-on-rails/
├── CLAUDE.md              ← this file
├── README.md              ← setup and security guide
├── ARCHITECTURE.md        ← authoritative technical reference
├── HANDOFF.md             ← risks and maintainer notes
├── Dockerfile             ← builds the Hermes container (with Tailscale); pins version
├── entrypoint.sh          ← startup script; starts tailscaled + control sidecar, then execs upstream entrypoint
├── roster-control-sidecar.py ← optional FastAPI service for remote LLM-model control by Roster
├── railway/
│   └── template-notes.md  ← documents Railway UI config (can't be in-repo)
└── docs/
    ├── tailscale-setup.md ← Tailscale operational guide
    ├── secrets-guide.md   ← environment variable reference
    └── hermes-control-sidecar-contract.md ← shared interface contract for the control sidecar (co-owned with Roster)
```

## Key Technical Decisions (do not revisit without good reason)

- **One Railway service per deployment:** a single `hermes` service. No separate Tailscale service. Tailscale runs inside the Hermes container.
- **Access pattern:** `tailscale ssh hermes@<agent-hostname>` from any device on the tailnet. No public URL, no inbound ports, no SSH keys to manage.
- **Multi-agent support:** each rome-on-rails deployment is a separate Railway project with its own `TS_AUTHKEY`. Each registers as a unique tailnet node — no CIDR conflicts, no hostname collisions.
- **Version pinning:** `FROM nousresearch/hermes-agent:<version>` in Dockerfile (official Docker Hub image, date-based tags like `v2026.4.16`). Tailscale installed from the apt repo, unpinned.
- **Volume:** Railway volume mounts at `/opt/data` (upstream default — no env overrides). Tailscale state lives at `/opt/data/.tailscale/` for identity persistence.
- **Entrypoint:** `entrypoint.sh` starts `tailscaled` (userspace networking mode) in the background, runs `tailscale up --ssh`, then `exec`s into upstream `/opt/hermes/docker/entrypoint.sh`. Upstream handles privilege drop + Hermes startup.
- **Process supervision:** bash backgrounding (no s6-overlay). Primary (Hermes) / secondary (tailscaled) asymmetry suits this pattern — if tailscaled dies, Hermes keeps running; if Hermes dies, container exits and Railway restarts everything.
- **Start command:** `hermes gateway run` — connects outbound to Slack via Socket Mode. No dashboard in v1 (it's a separate upstream command that would need its own service).
- **Secrets:** Railway environment variables only — never in the volume or repo.
- **No public URL, no inbound ports:** Hermes deployed as worker type; Dockerfile has no `EXPOSE` directive.
- **`hermes` CLI symlink:** `/usr/local/bin/hermes` → `/opt/hermes/.venv/bin/hermes` so the CLI is reachable from any interactive shell on `tailscale ssh`.
- **Roster control sidecar (optional):** a tiny FastAPI service (`roster-control-sidecar.py`) that lets Roster read/change the agent's LLM model over the tailnet. Backgrounded by `entrypoint.sh` as the `hermes` user via `gosu`, **only** when `ROSTER_CONTROL_TOKEN` is set (fail-closed — no token, or no `gosu`, means it doesn't run; never falls back to root). Binds `127.0.0.1`, exposed to the tailnet via `tailscale serve --tcp`. No new pip deps (FastAPI/uvicorn/PyYAML already in the venv). The interface is governed by `docs/hermes-control-sidecar-contract.md`, a contract co-owned with the Roster repo — change that file first if the interface must move.

Full rationale in `ARCHITECTURE.md`.

## Commands

Local build and smoke-test (runs the image; exits cleanly without TS_AUTHKEY, warns about missing env vars):
```bash
docker build -t rome-on-rails:dev .
docker run --rm rome-on-rails:dev
```

Full local test with Tailscale (registers a test node on your tailnet; clean up in admin after):
```bash
export TS_AUTHKEY="$(cat /path/to/reusable-key)"
docker run --rm -e TS_AUTHKEY -e TS_HOSTNAME=rome-on-rails-local-test rome-on-rails:dev
# From another terminal:
tailscale ssh hermes@rome-on-rails-local-test
```

On Railway the Dockerfile is built and deployed automatically on push to the tracked branch. No manual deploy command.
