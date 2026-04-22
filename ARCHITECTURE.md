# ARCHITECTURE.md — rome-on-rails

## Last updated: 2026-04-22

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
│                             │  │  /data (volume)       │   │    │
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
| Service type | Worker (no public domain generated) |
| Port | `9119` (Hermes dashboard, internal only) |
| Persistent volume | Mounted at `/data` |
| Config stored at | `/data/.hermes/config.yaml` |
| Secrets stored at | Railway environment variables (never in the volume) |

**What it runs:** The Hermes agent gateway — the process that connects to messaging platforms (Slack, Telegram, etc.) and serves the Hermes web dashboard. The gateway is started by `entrypoint.sh` at container boot.

**What it does NOT have:** A public Railway domain. The service is deployed as a worker type, which means Railway never assigns it a public HTTPS URL. The only way to reach port 9119 is through the Railway internal network.

**Version:** Pinned in the `Dockerfile` via `pip install "hermes-agent==<version>"`. See [Version Pinning](#version-pinning) below.

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

All persistent data lives on a Railway volume mounted at `/data` on the Hermes service.

| Path | Contents | Notes |
|---|---|---|
| `/data/.hermes/config.yaml` | Hermes configuration (model, tools, platform settings) | Written by `entrypoint.sh` on first boot from env vars |
| `/data/.hermes/sessions/` | Conversation history and session data | Survives redeploys |
| `/data/.hermes/memory/` | Agent memory (skills, learned facts) | Survives redeploys |
| `/data/.hermes/logs/` | Gateway logs | Rotated by Hermes |
| `/data/workspace/` | Working directory for agent terminal operations | Survives redeploys |

**What is NOT stored on the volume:** API keys, bot tokens, or any secrets. These live exclusively in Railway environment variables and are injected into the container at runtime. The volume contains state that is safe to lose (it degrades UX but doesn't expose credentials) and expensive to regenerate (memory, skills, session history).

---

## Secrets Management

Secrets are defined as Railway environment variables in the project dashboard. They are never:
- Committed to the repository
- Written to the volume
- Logged by the entrypoint script

The `entrypoint.sh` script reads them from the environment at startup and uses them to configure Hermes's runtime behavior. See `docs/secrets-guide.md` for the full list of expected variables.

---

## Version Pinning

Hermes is a fast-moving v0.x project that releases multiple times per week. Auto-updating is explicitly not safe for a production deployment.

**How we pin:**

In the `Dockerfile`:
```dockerfile
RUN pip install "hermes-agent==<version>"
```

The current pinned version is documented in the Dockerfile itself. To upgrade:
1. Check the [Hermes releases page](https://github.com/NousResearch/hermes-agent/releases)
2. Review the changelog for breaking changes
3. Update the version string in the `Dockerfile`
4. Redeploy

**What we never do:** Run `hermes update` in the entrypoint script or any automated context. That command pulls the latest version unconditionally and would silently upgrade the running agent.

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

### 2026-04-22 — Two services (Hermes + Tailscale) rather than one combined container

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
