# ARCHITECTURE.md — rome-on-rails

## Last updated: 2026-04-23

---

## What This Document Is

This is the authoritative technical reference for how rome-on-rails is built. It describes every component, how they connect, where data lives, and the reasoning behind key decisions. When there is a conflict between this document and any other document in the repo, this one wins — update it first.

---

## The Core Problem This Solves

Hermes's admin dashboard is a web application. Left to its own defaults, Railway will assign it a public HTTPS URL, and anyone who finds that URL can attempt to log in. Even with a strong password, this is more exposure than Echobind wants for a tool that holds API keys, can execute terminal commands, and connects to internal systems like Slack.

The goal of rome-on-rails is to make the private-by-default configuration the *only* configuration — not a hardening option you have to remember to turn on.

---

## Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Tailnet                             │
│                                                                 │
│   ┌──────────────┐         ┌──────────────────────────────┐    │
│   │  Your laptop  │         │   Railway Project             │    │
│   │  (Tailscale) │◄───────►│                              │    │
│   └──────────────┘Tailscale│  ┌──────────────────────┐   │    │
│                   mesh net │  │  Tailscale Service    │   │    │
│   ┌──────────────┐         │  │  (Subnet Router)      │   │    │
│   │  Your phone  │◄───────►│  │                       │   │    │
│   │  (Tailscale) │         │  │  Joins Railway's      │   │    │
│   └──────────────┘         │  │  private network and  │   │    │
│                             │  │  bridges it to your   │   │    │
│                             │  │  tailnet              │   │    │
│                             │  └──────────┬───────────┘   │    │
│                             │             │ Railway        │    │
│                             │             │ internal       │    │
│                             │             │ network        │    │
│                             │  ┌──────────▼───────────┐   │    │
│                             │  │  Hermes Service       │   │    │
│                             │  │                       │   │    │
│                             │  │  Port 9119 (dashboard)│   │    │
│                             │  │  No public URL        │   │    │
│                             │  │                       │   │    │
│                             │  │  /opt/data (volume)   │   │    │
│                             │  │  sessions, memory,    │   │    │
│                             │  │  skills, logs         │   │    │
│                             │  └───────────────────────┘   │    │
│                             └──────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘

                    ╳  Public internet cannot reach Hermes
```

---

## Services

### Service 1: Hermes

| Property | Value |
|---|---|
| Source | `echobind/rome-on-rails` (the repo cloned during Railway template deploy) |
| Base image | `nousresearch/hermes-agent:<version>` from Docker Hub (upstream official image) |
| Service type | Worker (no public domain generated) |
| Port | `9119` (Hermes dashboard, internal only) |
| Persistent volume | Mounted at `/opt/data` (upstream default — `HERMES_HOME`) |
| Config stored at | `/opt/data/config.yaml` |
| Secrets stored at | Railway environment variables (never in the volume) |
| Start command | `hermes gateway run` (set as `CMD` in our `Dockerfile`) |

**What it runs:** The Hermes gateway process, which both connects to messaging platforms (Slack, Telegram, etc.) and serves the Hermes web dashboard on port 9119. The container starts via `entrypoint.sh` (our thin Railway-specific wrapper) which execs the upstream `/opt/hermes/docker/entrypoint.sh` to handle privilege dropping, volume bootstrap, and launching Hermes.

**What it does NOT have:** A public Railway domain. The service is deployed as a worker type, which means Railway never assigns it a public HTTPS URL. The only way to reach port 9119 is through the Railway internal network.

**Version:** Pinned in the `Dockerfile` via the base-image tag — `FROM nousresearch/hermes-agent:<version>`. See [Version Pinning](#version-pinning) below.

---

### Service 2: Tailscale Subnet Router

| Property | Value |
|---|---|
| Source | Railway's official Tailscale Subnet Router template |
| Service type | Worker |
| Purpose | Bridges your tailnet into Railway's private network |
| Auth | `TS_AUTHKEY` environment variable |

**What it does:** Registers as a machine in your Tailscale tailnet and advertises Railway's private network CIDR range (`fd12::/16`). Once you approve the subnet in the Tailscale admin console, any device on your tailnet can resolve and reach `hermes.railway.internal:9119` as if it were a local service.

**What it does NOT do:** Expose anything to the public internet. The subnet router only bridges *inward* — tailnet devices reach Railway's private network; the public internet gets nothing.

**Persistent state:** The Tailscale subnet router needs a small persistent volume to store its Tailscale node identity. Without this, the node generates a new identity on every restart and creates orphaned entries in your Tailscale admin console.

---

## Network Flow

### How a request reaches Hermes

```
Developer's laptop (Tailscale running)
  │
  │  WireGuard encrypted tunnel
  ▼
Tailscale control plane
  │
  │  Routes to tailnet node: rome-on-rails-production-tailscale
  ▼
Tailscale Subnet Router (Railway service)
  │
  │  Forwards via Railway internal network
  ▼
hermes.railway.internal:9119
  │
  ▼
Hermes dashboard
```

### What the public internet sees

Nothing. Railway never generates a public domain for the Hermes service. The Tailscale subnet router has no inbound ports open to the public internet either — it only makes outbound connections to Tailscale's coordination servers to establish the mesh.

---

## Persistent Storage

All persistent data lives on a Railway volume mounted at `/opt/data` on the Hermes service. This is the upstream Hermes default (`HERMES_HOME=/opt/data`) — we deliberately do not override it, so the path inside the container matches what the upstream image expects.

| Path | Contents | Notes |
|---|---|---|
| `/opt/data/config.yaml` | Hermes configuration (model, tools, platform settings) | Copied from `cli-config.yaml.example` by the upstream entrypoint on first boot |
| `/opt/data/.env` | Hermes env file | Copied from `.env.example` by the upstream entrypoint on first boot. We do not use this on Railway — env vars come from the Railway dashboard and are injected into the container directly. |
| `/opt/data/sessions/` | Conversation history and session data | Survives redeploys |
| `/opt/data/memories/` | Agent memory (skills, learned facts) | Survives redeploys |
| `/opt/data/skills/` | Installed skills | Synced by upstream entrypoint on boot |
| `/opt/data/logs/` | Gateway logs | Rotated by Hermes |
| `/opt/data/workspace/` | Working directory for agent terminal operations | Survives redeploys |

**What is NOT stored on the volume:** API keys, bot tokens, or any secrets. These live exclusively in Railway environment variables and are injected into the container at runtime. The volume contains state that is safe to lose (it degrades UX but doesn't expose credentials) and expensive to regenerate (memory, skills, session history).

---

## Secrets Management

Secrets are defined as Railway environment variables in the project dashboard. They are never:
- Committed to the repository
- Written to the volume
- Logged by the entrypoint script

The `entrypoint.sh` script reads them from the environment at startup and uses them to configure Hermes's runtime behavior. See `docs/secrets-guide.md` for the full list of expected variables.

---

## Access Control

rome-on-rails serves two distinct user types, each gated by a different mechanism.

### Admins (instance owner + maintainers)

Reach the Hermes web dashboard and CLI over Tailscale. This is a small, known group of engineers who already have Railway access. Admin access is bounded by:

- **Tailscale tailnet membership** — defined in Tailscale ACL. Only devices on the tailnet can resolve `hermes.railway.internal:9119`.
- **Railway project access** — controls who can read/write env vars, view logs, and redeploy.

### Slack users (end users of the bot)

Interact with Hermes by mentioning the bot or DMing it in Slack. They never touch Railway or Tailscale — all traffic flows through Slack's own infrastructure, and the Hermes container makes outbound WebSocket connections to Slack (Socket Mode). Slack-user access is bounded by:

- **Slack workspace membership** — the outer ring. Anyone outside the workspace cannot reach the bot at all.
- **`SLACK_ALLOWED_USERS`** — the inner ring. A comma-separated list of Slack member IDs, set as a Railway environment variable. This is the *only* per-user allowlist Hermes exposes for Slack, and it is **required**. A deploy where the bot appears online but does not respond is almost always a missing or incorrect `SLACK_ALLOWED_USERS`.

**Implication for operators:** `SLACK_ALLOWED_USERS` must be set during first deploy and updated whenever team membership changes (e.g., offboarding). There is no Hermes-side UI for managing it. See Risk 7 in `HANDOFF.md`.

---

## Version Pinning

Hermes is a fast-moving project that releases multiple times per week and uses **date-based versioning** (`vYYYY.M.D`, not semver). Auto-updating is explicitly not safe for a production deployment.

**How we pin:**

In the `Dockerfile`, via the base-image tag:
```dockerfile
ARG HERMES_VERSION=v2026.4.16
FROM nousresearch/hermes-agent:${HERMES_VERSION}
```

The current pinned version is the literal tag in the `Dockerfile`. To upgrade:
1. Check the [Hermes releases page](https://github.com/NousResearch/hermes-agent/releases)
2. Review the changelog for breaking changes
3. Update the `HERMES_VERSION` value in the `Dockerfile`
4. Commit and push — Railway redeploys automatically

**What we never do:** Run `hermes update` in the entrypoint script or any automated context. That command pulls the latest Hermes unconditionally and would silently upgrade the running agent. Pinning is enforced by the image tag, which is immutable once built.

**Supply-chain note:** We depend on `nousresearch/hermes-agent` on Docker Hub. If that image is ever yanked, retagged, or compromised, our deploys are affected. See Risk 6 in `HANDOFF.md`.

---

## What Is Public vs. Private

| Item | Public? | Notes |
|---|---|---|
| `echobind/rome-on-rails` repo | Yes | The template is public so Railway's deploy button works |
| Dockerfile | Yes | Contains no secrets; only the pinned version number |
| `entrypoint.sh` | Yes | Contains no secrets; reads from env at runtime |
| Railway environment variables | No | Set in Railway dashboard, never in the repo |
| Hermes dashboard URL | No | No public domain is generated |
| Hermes port 9119 | No | Only reachable via tailnet |
| Volume contents (sessions, memory) | No | Stored in Railway's infrastructure |
| Tailscale auth key (`TS_AUTHKEY`) | No | Railway environment variable |

---

## Decisions Log

This section records significant architecture decisions, when they were made, and why. New decisions are added at the top.

---

### 2026-04-23 — `SLACK_ALLOWED_USERS` is the sole Slack user-level access control

**Decision:** Treat `SLACK_ALLOWED_USERS` (a Railway environment variable holding a comma-separated list of Slack member IDs) as the authoritative per-user allowlist for the Slack gateway. Do not add a second access layer (e.g., a Hermes skill that filters users) on top of it.

**Rationale:** Hermes ships a built-in allowlist for Slack; duplicating that logic in our template would create two sources of truth for "who can use the bot" and invites drift. Slack workspace membership is the outer ring; `SLACK_ALLOWED_USERS` is the inner ring. No extra ring is required for Echobind's threat model.

**Known uncertainty:** The exact semantics of an unset or empty `SLACK_ALLOWED_USERS` are not independently verified for our pinned Hermes version — upstream Slack docs describe a fail-closed default ("deny all messages"), while feature requests on adjacent gateways (Telegram) suggest some gateways default open. We document the variable as "required for Slack to function at all" — a statement that stays correct under either default — and will verify empirically against our live instance during rollout. See Risk 7 in `HANDOFF.md`.

---

### 2026-04-22 — Base image: official `nousresearch/hermes-agent` from Docker Hub

**Decision:** The Hermes service builds `FROM nousresearch/hermes-agent:v2026.4.16` — the official Nous Research Docker Hub image — rather than building from source (e.g., cloning the repo and running `pip install`/`uv pip install`).

**Rationale:** The upstream image is a non-trivial multi-stage build involving Node.js 22, Playwright browsers, a Python venv via `uv`, and several runtime assets (web dashboard bundle, SOUL.md, skill manifests). Rebuilding this ourselves means replicating — and then maintaining — Nous's build pipeline. Using the official image keeps rome-on-rails thin (its value is the Railway + Tailscale wrapping, not re-packaging Hermes), and version pinning is enforced by the immutable image tag.

**Alternatives considered:**
- `FROM python:3.12-slim` + `pip install hermes-agent==<version>` from PyPI — unverified whether Nous publishes a PyPI package for the whole runtime, and would drop Playwright/Node tools.
- `FROM ghcr.io/astral-sh/uv:...` + source install at tag — what some community Railway templates do; requires us to track upstream build changes.

**Tradeoff accepted:** We take on a supply-chain dependency on Docker Hub and the `nousresearch/hermes-agent` namespace. See Risk 6 in `HANDOFF.md`.

---

### 2026-04-22 — `entrypoint.sh` is a thin wrapper over the upstream entrypoint

**Decision:** Our `entrypoint.sh` validates Railway-specific env vars, logs a startup banner, and then `exec`s the upstream entrypoint at `/opt/hermes/docker/entrypoint.sh`. It does not re-implement the upstream's responsibilities (privilege drop, volume permission fix, config bootstrap from templates, skill sync).

**Rationale:** The upstream entrypoint does real work that we would otherwise need to copy — and that we would need to update every time Nous changes it. A thin wrapper gives us a visible Railway-specific layer (helpful for engineers reading the repo, and for logging clarity in Railway's log UI) without the cost of maintaining a fork of Nous's bootstrap logic.

**Alternative considered:** No custom entrypoint — set `CMD` only, let the upstream entrypoint run as-is. Rejected because we wanted explicit fail-fast warnings for missing required env vars (`SLACK_BOT_TOKEN`, LLM provider keys) and a clear `[rome-on-rails]`-prefixed startup banner in Railway logs, both of which are valuable given the target audience (engineers deploying this for the first time).

---

### 2026-04-22 — Volume mount path is `/opt/data` (upstream default), not `/data`

**Decision:** The Railway persistent volume for the Hermes service mounts at `/opt/data`, matching the upstream Hermes image's built-in `HERMES_HOME` default and `VOLUME` directive. We do not override `HERMES_HOME`, and we do not set `HOME`.

**Rationale:** The upstream image already declares `ENV HERMES_HOME=/opt/data` and `VOLUME ["/opt/data"]`. Mounting Railway's volume at the same path means no env overrides are required, and any path assumptions inside the upstream image (including the bootstrap logic in `/opt/hermes/docker/entrypoint.sh`) work without modification. The earlier draft of this document specified `/data` plus `HOME=/data` plus `HERMES_HOME=/data/.hermes` — this was unnecessary complexity that accumulated before we checked upstream defaults.

**Tradeoff:** `/data` is the more conventional Railway volume path. `/opt/data` is slightly less idiomatic for Railway but avoids any deviation from upstream's assumptions, which is the more important property here.

---

### 2026-04-22 — Start command is `hermes gateway run`, not `hermes dashboard`

**Decision:** The container's `CMD` is `["gateway", "run"]`, which starts the Hermes messaging gateway. The gateway process also serves the web dashboard on port 9119 — we get both in one process.

**Rationale:** Echobind's primary access pattern is Slack (engineers mention the bot in a channel). The gateway is the mode that connects to Slack; the dashboard alone does not. Running `hermes dashboard` would give us the UI but no messaging integration. The gateway gives us both.

---

**Decision:** Deploy Hermes and Tailscale as two separate Railway services in the same project, rather than running both inside a single container with a process supervisor.

**Rationale:** Separation of concerns. If Tailscale has a restart or auth issue, Hermes keeps running and retains its state. If Hermes crashes, the Tailscale tunnel stays up. Each service can be restarted, monitored, and debugged independently. Railway's internal network connects them without any additional configuration.

**Alternative considered:** Single container with `supervisord` managing both Tailscale daemon and Hermes. Rejected because it complicates the Dockerfile significantly and couples two unrelated failure modes.

---

### 2026-04-22 — No public Railway domain on the Hermes service

**Decision:** Deploy Hermes as a Railway worker service type, which prevents Railway from assigning any public HTTPS URL.

**Rationale:** This is the core security requirement. A public URL, even with Basic Auth, is an attack surface. Making it structurally impossible to reach Hermes without being on the tailnet is safer than relying on remembering to disable the public URL after deployment.

**Tradeoff:** First-time setup is slightly more complex — engineers must have Tailscale installed and be on the tailnet to access the Hermes dashboard at all. This is intentional and documented in the README.

---

### 2026-04-22 — Template deploy clones repo into user's own GitHub account

**Decision:** The Railway deploy button is configured so that deploying the template creates a copy of the repo in the deploying engineer's GitHub account (or the Echobind org), rather than deploying directly from `echobind/rome-on-rails`.

**Rationale:** Each engineer owns their deployment. They can customize their instance, update their pinned version independently, and the canonical template repo is not coupled to any live deployment.

**Implication:** Engineers are responsible for pulling upstream changes from `echobind/rome-on-rails` if they want to benefit from future improvements. This should be documented in the README.

---

### 2026-04-22 — Secrets live in Railway environment variables, not in the volume

**Decision:** All API keys, bot tokens, and auth secrets are stored as Railway environment variables only. The `entrypoint.sh` script writes them into Hermes's runtime config from the environment — they are never persisted to the volume or committed to the repo.

**Rationale:** The volume is backed up by Railway and contains data we want to survive redeploys (sessions, memory, skills). If the volume were compromised or accidentally shared, it should contain no credentials. Railway environment variables have their own access controls and are not included in volume exports.

---
