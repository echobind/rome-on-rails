# ARCHITECTURE.md — rome-on-rails

## Last updated: 2026-04-24

---

## What This Document Is

This is the authoritative technical reference for how rome-on-rails is built. It describes every component, how they connect, where data lives, and the reasoning behind key decisions. When there is a conflict between this document and any other document in the repo, this one wins — update it first.

---

## The Core Problem This Solves

Hermes is an AI agent that holds API keys, can execute terminal commands, and connects to internal systems like Slack. Deployed on Railway with defaults, it would get a public HTTPS URL reachable by anyone who finds it. That's more exposure than Echobind wants.

rome-on-rails gives each Hermes deployment:

- **No inbound public network surface.** Slack works via outbound Socket Mode (the container connects out to Slack; Slack never connects in). Administrative access goes through Tailscale. No Railway domain is ever generated.
- **Tailnet-only maintainer access.** The container is itself a Tailscale node. Maintainers reach it via `tailscale ssh hermes@<agent-hostname>` from any laptop on their tailnet. Authentication is the operator's tailnet identity, not an SSH keypair that has to be managed.
- **Support for multiple agents on one tailnet.** Each agent is a separate Railway project with its own Tailscale identity. No CIDR or hostname conflicts — each gets a unique MagicDNS name.

The private-by-default posture is not a setting you remember to turn on — it is the only way this template deploys.

---

## Component Overview

Per rome-on-rails deployment, the topology is one Railway project containing one Railway service:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Tailnet                             │
│                                                                 │
│   ┌──────────────┐          ┌────────────────────────────────┐  │
│   │  Your laptop │          │   Railway Project              │  │
│   │  (Tailscale) │          │                                │  │
│   │              │ tailnet  │   ┌──────────────────────────┐ │  │
│   │    $ tailsca-│◄────────►│   │  Hermes Service          │ │  │
│   │    le ssh ...│ mesh     │   │                          │ │  │
│   └──────────────┘          │   │  ┌────────────────────┐  │ │  │
│                             │   │  │ tailscaled         │  │ │  │
│   ┌──────────────┐          │   │  │ (userspace mode)   │  │ │  │
│   │   Your phone │◄────────►│   │  │ agent → tailnet    │  │ │  │
│   │  (Tailscale) │          │   │  │ node, SSH enabled  │  │ │  │
│   └──────────────┘          │   │  └─────────┬──────────┘  │ │  │
│                             │   │            │             │ │  │
│                             │   │  ┌─────────▼──────────┐  │ │  │
│                             │   │  │ hermes gateway run │  │ │  │
│   Slack users ─────────►    │   │  │                    │  │ │  │
│                             │◄──┼──┤ outbound WebSocket │  │ │  │
│   (outbound Socket Mode;    │   │  │ to Slack           │  │ │  │
│    no inbound ports)        │   │  └────────────────────┘  │ │  │
│                             │   │                          │ │  │
│                             │   │  Volume: /opt/data       │ │  │
│                             │   │  sessions, memory,       │ │  │
│                             │   │  skills, .tailscale/,    │ │  │
│                             │   │  state.db                │ │  │
│                             │   └──────────────────────────┘ │  │
│                             └────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

             ╳  Public internet cannot reach Hermes
             ╳  No inbound ports exposed from the container
```

For multi-agent setups, replicate the entire right-hand side per agent — each Railway project runs its own Hermes service, each registers as a separate tailnet node with a unique hostname. Your laptop on the tailnet reaches each one independently.

---

## Services

### Service 1: Hermes (the only service)

| Property | Value |
|---|---|
| Source | `echobind/rome-on-rails` (the repo cloned during Railway template deploy) |
| Base image | `nousresearch/hermes-agent:<version>` from Docker Hub (upstream official image) |
| Added by our Dockerfile | Tailscale (installed from official apt repo), `hermes` symlink to `/usr/local/bin`, our entrypoint wrapper |
| Service type | Worker (no public domain generated) |
| Exposed ports | None — no `EXPOSE` directive |
| Persistent volume | Mounted at `/opt/data` (upstream default — `HERMES_HOME`) |
| Config stored at | `/opt/data/config.yaml` |
| Secrets stored at | Railway environment variables (never in the volume) |
| Start command | `hermes gateway run` (set as `CMD` in our `Dockerfile`) |

**What runs in this container (as separate processes):**

1. **tailscaled** — Tailscale daemon in userspace networking mode. Brought up by our `entrypoint.sh` before the upstream handoff. Registers the container as a tailnet node, accepts `tailscale ssh` inbound.
2. **Hermes gateway** — Started by the upstream entrypoint (after privilege drop to hermes user). Connects outbound to Slack via Socket Mode. Runs cron scheduler. No HTTP server.

**What the container does NOT have:**

- A public Railway domain (worker service type prevents this)
- An always-on web dashboard server (the `hermes dashboard` command exists upstream but is not run at container start — see ad-hoc dashboard note below)
- Any exposed inbound ports

**Ad-hoc dashboard access:** When a maintainer wants the Hermes web dashboard, they open an SSH session with local-port forwarding (`ssh -L 9119:localhost:9119 hermes@<host>`) and run `hermes dashboard` inside. The dashboard binds only to the container's `localhost`, so it's unreachable from the tailnet unless the maintainer is actively tunneling to it. Closing the SSH session ends dashboard reachability. See `docs/dashboard-access.md`.

**Version:** Pinned in the `Dockerfile` via the base-image tag — `FROM nousresearch/hermes-agent:<version>`. See [Version Pinning](#version-pinning) below.

---

## Network Flow

### Admin access (CLI maintenance)

```
Maintainer's laptop (Tailscale running)
  │
  │  $ tailscale ssh hermes@<agent-hostname>
  │  WireGuard-encrypted tunnel via tailnet mesh
  ▼
Tailscale control plane (routing + identity check)
  │
  │  Matches hostname to the Railway container's tailnet node
  ▼
Hermes container's tailscaled (inside Railway)
  │
  │  Tailscale SSH accepts the connection; authenticates
  │  operator via tailnet identity (no SSH keys)
  ▼
Interactive shell as the `hermes` user
  │  $ hermes status
  │  $ hermes config edit
  │  $ hermes skills list
  ▼
CLI commands execute against /opt/data state
```

### Slack user traffic (outbound-initiated, bidirectional)

```
Slack user @mentions bot
  │
  ▼
Slack's servers
  │
  │  Delivers event via Socket Mode tunnel
  │  (the bidirectional tunnel was established outbound by the bot
  │  on container startup; Slack never opens a new connection)
  ▼
Hermes container's outbound WebSocket connection
  │
  ▼
Hermes gateway handles event → LLM inference → responds on the same tunnel
```

### What the public internet sees

Nothing. The container has no inbound ports, no public domain, and no Railway-assigned URL. Slack uses Socket Mode (bot-initiated WebSocket) so there is no inbound webhook endpoint. The tailnet is not publicly accessible.

---

## Persistent Storage

All persistent data lives on a Railway volume mounted at `/opt/data` on the Hermes service. This is the upstream Hermes default (`HERMES_HOME=/opt/data`) — we deliberately do not override it, so the path inside the container matches what the upstream image expects.

| Path | Contents | Notes |
|---|---|---|
| `/opt/data/config.yaml` | Hermes configuration (model, tools, platform settings) | Written by Hermes on first boot from `cli-config.yaml.example` |
| `/opt/data/.env` | Hermes env file | Written on first boot. We don't use it on Railway — env vars come from the Railway dashboard. |
| `/opt/data/sessions/` | Conversation history and session data | Survives redeploys |
| `/opt/data/memories/` | Agent long-term memory | Survives redeploys |
| `/opt/data/skills/` | Installed skills (79 bundled in v2026.4.16) | Synced by upstream entrypoint on boot |
| `/opt/data/logs/` | Gateway logs | Rotated by Hermes |
| `/opt/data/workspace/` | Working directory for agent terminal operations | Survives redeploys |
| `/opt/data/state.db`, `state.db-wal`, `state.db-shm` | Hermes's main SQLite state store (WAL + shared memory files) | Survives redeploys |
| `/opt/data/cron/`, `hooks/`, `plans/`, `platforms/`, `skins/`, `bin/`, `home/` | Hermes runtime infrastructure directories | Managed by Hermes; not user-configured |
| `/opt/data/SOUL.md`, `channel_directory.json`, `gateway_state.json`, `gateway.pid` | Hermes runtime state files | Managed by Hermes |
| `/opt/data/.tailscale/` | **Tailscale state:** machine identity, SSH host keys, taildrop/TKA state | Persisting this across restarts preserves the agent's tailnet identity — same MagicDNS hostname survives redeploys |

**What is NOT stored on the volume:** API keys, bot tokens, Tailscale auth keys, or any secrets. These live exclusively in Railway environment variables and are injected into the container at runtime. The volume contains state that is safe to lose (it degrades UX but doesn't expose credentials) and expensive to regenerate (memory, skills, session history, tailnet identity).

---

## Secrets Management

Secrets are defined as Railway environment variables in the project dashboard. They are never:

- Committed to the repository
- Written to the volume
- Logged by the entrypoint script

The `entrypoint.sh` script reads them from the environment at startup and uses them to configure Hermes's and Tailscale's runtime behavior. See `docs/secrets-guide.md` for the full list of expected variables.

---

## Access Control

rome-on-rails serves two distinct user types, each gated by a different mechanism.

### Maintainers (admin / CLI access)

Reach the Hermes container via `tailscale ssh hermes@<agent-hostname>` over the tailnet. This is a small, known group of engineers who also have Railway project access. Maintainer access is bounded by:

- **Tailscale tailnet membership** — defined in the Tailscale ACL. Only devices on the tailnet can resolve or reach the agent's tailnet hostname.
- **Tailscale SSH ACL** — specifies which tailnet users can SSH as which local users on which machines. Default (no custom ACL) grants all tailnet users full SSH access to all tagged machines.
- **Railway project access** — controls who can read/write env vars, view logs, redeploy.

### Slack users (end users of the bot)

Interact with Hermes by mentioning the bot or DMing it in Slack. They never touch Railway or Tailscale — all traffic flows through Slack's own infrastructure, and the Hermes container makes outbound WebSocket connections to Slack (Socket Mode). Slack-user access is bounded by:

- **Slack workspace membership** — the outer ring. Anyone outside the workspace cannot reach the bot at all.
- **`SLACK_ALLOWED_USERS`** — the inner ring. A comma-separated list of Slack member IDs, set as a Railway environment variable. This is the *only* per-user allowlist Hermes exposes for Slack; when unset, the gateway denies all messages (verified 2026-04-23 against pinned version v2026.4.16 — see `HANDOFF.md` Risk 7). A deploy where the bot appears online but does not respond is almost always a missing or incorrect `SLACK_ALLOWED_USERS`. An unsafe master override exists (`GATEWAY_ALLOW_ALL_USERS=true`) that disables all allowlists gateway-wide; **do not set it** — listed in `docs/secrets-guide.md` under variables you must not set.

**Implication for operators:** `SLACK_ALLOWED_USERS` must be set during first deploy and updated whenever team membership changes (e.g., offboarding). There is no Hermes-side UI for managing it.

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
5. After redeploy, re-verify the `SLACK_ALLOWED_USERS` fail-closed behavior (upstream could change this default between releases)

**What we never do:** Run `hermes update` in the entrypoint script or any automated context. That command pulls the latest Hermes unconditionally and would silently upgrade the running agent. Pinning is enforced by the image tag, which is immutable once built.

**Tailscale is pinned separately** — we install from the Debian trixie apt repo (`pkgs.tailscale.com`), which gives us the current stable at build time. Tailscale's release cadence and backwards-compat policy are benign enough that we don't version-pin explicitly; if that changes, we can pin via `apt-get install tailscale=<version>` in the Dockerfile.

**Supply-chain note:** We depend on `nousresearch/hermes-agent` on Docker Hub and on Tailscale's apt repo. See Risks 6 and 8 in `HANDOFF.md`.

---

## What Is Public vs. Private

| Item | Public? | Notes |
|---|---|---|
| `echobind/rome-on-rails` repo | Yes | The template is public so Railway's deploy button works |
| Dockerfile | Yes | Contains no secrets; only the pinned Hermes version |
| `entrypoint.sh` | Yes | Contains no secrets; reads from env at runtime |
| Railway environment variables | No | Set in Railway dashboard, never in the repo |
| Hermes agent (Slack endpoint) | No | No public domain; only reachable via Slack's own infrastructure (outbound-only connection from the bot) |
| Hermes CLI / shell access | No | Only reachable via `tailscale ssh` through the tailnet |
| Volume contents (sessions, memory, tailnet identity) | No | Stored in Railway's infrastructure |
| Tailscale auth key (`TS_AUTHKEY`) | No | Railway environment variable |
| LLM provider keys, Slack tokens | No | Railway environment variables |

---

## Decisions Log

This section records significant architecture decisions, when they were made, and why. New decisions are added at the top.

---

### 2026-04-24 — Multi-agent-per-project via service duplication, not via N-service templates

**Decision:** The rome-on-rails Railway template ships a single Hermes service. Operators who need multiple agents in the same Railway project use Railway's "Duplicate Service" UI action to clone the Hermes service as many times as needed, overriding per-agent env vars (`TS_HOSTNAME`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`) on each duplicate. Shared-across-project env vars (LLM provider key, `TS_AUTHKEY`, `HERMES_INFERENCE_PROVIDER`) are copied by the duplication action and left as-is. We do not publish a 2-service, 3-service, etc. template variant.

**Rationale:** Railway templates fix service count at publish time. A template configured for N services cannot serve clients whose required N differs. Publishing multiple templates (one per N) would multiply the surface area we maintain and test, without giving operators anything they can't already get by duplicating a service. Duplication is a first-class Railway UI feature — it copies the Dockerfile reference, all env vars, and all service config — which makes "one template, scale by duplication" straightforward to document and scale to arbitrary N.

This became a V1 requirement (not future work) when the Echobind team confirmed that a single client may need multiple Hermes agents — each with its own Slack app — inside a single Railway project. Separate Railway projects remain the right pattern when agents belong to genuinely separate clients or billing owners (see the README's Multi-Agent section); duplicated services are the pattern within one client's fleet.

**Hostname collision risk addressed:** The entrypoint's default `TS_HOSTNAME` derivation — `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}` — is identical across every service in the same project. Duplicated services that inherit this default would all try to claim the same tailnet hostname and collide. Mitigation: `docs/multi-agent.md` and the `railway/template-notes.md` prompt copy explicitly instruct operators to set a unique `TS_HOSTNAME` on every duplicated service. The auto-derive stays as a sensible default for the first (and only) service in a solo deployment.

**Slack-app crosswiring risk addressed:** A duplicated service inherits the original's `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN`. If the operator doesn't override these before the new service finishes its first deploy, two containers end up connected to the same Slack app and both respond to every message. Captured as a risk in `HANDOFF.md`.

**Alternatives considered:**

- **Publish multiple templates (2-agent, 3-agent, …).** Rejected: template count explodes, each variant needs its own testing, and still doesn't serve clients whose N falls outside the published set.
- **Multiple Hermes processes inside a single container.** Rejected: would require a real supervisor (s6-overlay, supervisord) instead of the current bash-backgrounding pattern, and re-introduces the two-Slack-apps-per-container coordination problem we'd be trying to avoid.
- **Separate Railway projects for every agent, even within one client.** Rejected as mandatory, preserved as optional (Pattern A in the README). Creates per-project billing overhead, multiplies Railway access-control surface, and forces clients with a fleet of agents to click the deploy button N times.

**Validated:** Not yet. Next step is to publish the single-service template and run through the duplication flow end-to-end with a throwaway second agent.

---

### 2026-04-24 — Propagate runtime env vars to interactive shells via `/etc/profile.d/`

**Decision:** On every container start, `entrypoint.sh` writes `/etc/profile.d/hermes-env.sh` with re-exports of the Railway-injected env vars the admin UX cares about (LLM provider keys, `HERMES_INFERENCE_PROVIDER` and related, Slack tokens, `SLACK_ALLOWED_USERS`, etc.). The file lives on the container filesystem (not the volume), is regenerated from the live env on each container start, and has mode 644.

**Rationale:** Tailscale SSH spawns login shells via `tailscaled be-child ssh --login-shell=/bin/sh`, which does not inherit the environment of PID 1. Without this step, `hermes status` from a `tailscale ssh` session reported API keys as unset even when the gateway process (PID 1) had them, and `hermes model` / `hermes config edit` couldn't see the provider key they needed to configure a model. Our deliberate choice to keep secrets in Railway env vars only (not as `/opt/data/.env`) was creating a functional gap in the maintainer UX.

**Alternative considered:** Run `hermes setup` once per deployment to let Hermes persist keys to `/opt/data/.env`. Rejected because it would duplicate secrets (Railway env vars + volume file), deviate from the "single source of truth" principle documented in `docs/secrets-guide.md`, and require rotation in two places. Writing to `/etc/profile.d/` keeps Railway env vars as the single source of truth; the file regenerates on every restart from the live environment, so there's no persistence concern and no manual sync required.

**Security note:** Any process already running in the container can read the env vars of processes it owns via `/proc/<pid>/environ`. Exposing those same values through `/etc/profile.d/hermes-env.sh` (world-readable within the container) doesn't expand the attack surface — the file lives on the container filesystem, has the same lifetime as the container, and never touches the persistent volume.

---

### 2026-04-24 — Pivot from two-service (subnet-router) to single-service (Tailscale-in-container) architecture

**Decision:** Each Hermes deployment runs as a single Railway service. The Tailscale daemon is installed inside the Hermes container and runs alongside the Hermes gateway process. There is no separate Tailscale service, no subnet router, no forwarder service.

**What replaced what:**

- Removed: Tailscale Subnet Router service (advertising `fd12::/16` into the tailnet)
- Removed: Tailscale Forwarder service (TCP proxy on a separate tailnet node)
- Added: Tailscale installed in our Dockerfile; `tailscaled` started by our entrypoint in userspace networking mode; `tailscale up --ssh` during boot; the container is itself a tailnet node

**Rationale:** The two-service subnet-router model is broken for multi-agent deployments. Multiple rome-on-rails projects in the same tailnet would each advertise `fd12::/16` — per Tailscale's documentation, when multiple subnet routers advertise the same CIDR, traffic goes to *one* primary (selected by date added, oldest first) with the rest as passive standbys. In practice this means only one rome-on-rails agent per tailnet is reachable.

The Forwarder pattern (TCP proxy on a separate tailnet node) was considered, but it only proxies network protocols — our maintenance requirement is **interactive shell access to run `hermes` CLI commands**, which the forwarder can't provide without adding an SSH server inside the Hermes container and all the key-management surface that entails. Tailscale SSH, when `tailscaled` runs inside the container, uses tailnet identity as the auth mechanism — no SSH keys to distribute, no sshd to maintain.

Finally, Railway does not support shared network namespace between services (unlike Docker Compose's `network_mode: service:tailscale`), which rules out the classic Tailscale "sidecar" pattern entirely.

**Validated:** Built locally, deployed to `rome-on-rails-test` on Railway, verified `tailscale ssh hermes@rome-on-rails-test-production` from an operator laptop gives a shell where `hermes status` runs correctly.

**Tradeoffs:**

- Larger Dockerfile and entrypoint (adds Tailscale install, two-process management in one container) vs. smaller services but broken multi-agent support
- Tighter coupling of Hermes and Tailscale upgrades (same image rebuild) vs. simpler multi-agent story
- Smaller blast radius for each Tailscale node (only exposes SSH, no subnet route advertisement) vs. losing the generic "access any Railway service over the tailnet" capability the subnet router provided

---

### 2026-04-24 — Tailscale install method: apt repo on Debian 13 trixie

**Decision:** Install Tailscale via the official `pkgs.tailscale.com` apt repo, imported with GPG verification in the `Dockerfile`.

**Rationale:** The base Hermes image is Debian 13 (`/etc/os-release` confirmed). The apt repo install is the standard, officially-supported path for Debian-based systems. It provides the `tailscaled` daemon, the `tailscale` CLI, and the Tailscale SSH integration as one package, with GPG signature verification, and gets security updates via apt.

**Alternative considered:** Direct binary download from `pkgs.tailscale.com/stable/` with explicit version pinning. Rejected for v1 because the apt path is simpler and the tradeoff (explicit version control vs. convenience + security updates) favors convenience at this stage. We can switch to direct binary + version pin later if supply-chain concerns change.

---

### 2026-04-24 — Tailscale runtime mode: userspace networking

**Decision:** Run `tailscaled --tun=userspace-networking` — no TUN device, no `NET_ADMIN` capability, no privilege escalation beyond normal container root.

**Rationale:** Railway containers don't reliably have TUN/TAP devices or elevated capabilities exposed. Userspace networking is Tailscale's mode designed exactly for this — it runs the whole network stack in userspace using Go's networking primitives, with a small throughput penalty relative to kernel TUN mode.

For our usage pattern (SSH sessions + occasional CLI traffic), throughput is not a concern. If Hermes ever needed to move a lot of data over the tailnet (unlikely given the architecture), we would re-examine.

---

### 2026-04-24 — Tailscale state persisted at `/opt/data/.tailscale/` on the Hermes volume

**Decision:** `tailscaled --statedir=/opt/data/.tailscale`. Machine identity, SSH host keys, Taildrop files, and network-lock state all live in that directory on the Hermes volume.

**Rationale:** We want the agent's tailnet identity to survive container restarts — same MagicDNS hostname, no orphaned machines in Tailscale admin from every redeploy. The Hermes volume is the only persistent storage we have, so Tailscale state goes there.

Using `--statedir` (directory) rather than `--state` (single file) is critical — with `--state`, Tailscale defaults the other state files (especially SSH host keys) to `/var/lib/tailscale`, which doesn't exist in the container. Symptom of getting this wrong: `warning: unable to get SSH host keys, SSH will appear as disabled for this node`. We found this during local testing on 2026-04-23.

---

### 2026-04-24 — Process supervision: bash backgrounding, not s6-overlay

**Decision:** `entrypoint.sh` starts `tailscaled` as a background process with `&`, then `exec`s into the upstream Hermes entrypoint. No formal supervisor.

**Rationale:** The container has exactly two long-running processes with an asymmetric relationship:

- **Hermes** (primary) — if it dies, the container should exit so Railway restarts everything
- **tailscaled** (secondary) — if it dies, Hermes should keep running (Slack still works); the operator notices via Tailscale admin showing the machine offline

s6-overlay or supervisord would provide symmetric supervision (restart each process independently, fine-grained log routing), but that asymmetric relationship is well-served by the simpler pattern. Reconsider if we ever need more processes, or if tailscaled-silently-dying becomes a recurring operational issue.

**Known limitations accepted for v1:**

- No zombie reaping if tailscaled dies after upstream `exec` (Hermes becomes PID 1, doesn't reap children). Bounded impact — one zombie slot in the process table.
- No automatic restart of tailscaled.

---

### 2026-04-24 — Symlink `hermes` binary to `/usr/local/bin/hermes`

**Decision:** In the Dockerfile, `ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes`.

**Rationale:** The Hermes binary lives inside a Python venv at `/opt/hermes/.venv/bin/hermes`. The upstream image's gateway-startup path exports the venv on PATH for the running process, but interactive shells (what `tailscale ssh` gives you) don't inherit that PATH. Without a symlink, `hermes status` returns "command not found" from any SSH session, regardless of which user or shell. The symlink makes the CLI resolvable everywhere.

**Alternative considered:** Export the venv on PATH via `/etc/profile.d/` or a shell rc file. Rejected because different shells (sh, bash) source different files, and login-vs-interactive shell semantics get fiddly. The symlink is shell-independent.

---

### 2026-04-22 — Base image: official `nousresearch/hermes-agent` from Docker Hub

**Decision:** The Hermes service builds `FROM nousresearch/hermes-agent:v2026.4.16` — the official Nous Research Docker Hub image — rather than building from source.

**Rationale:** The upstream image is a non-trivial multi-stage build involving Node.js 22, Playwright browsers, a Python venv via `uv`, and several runtime assets. Rebuilding this ourselves means replicating — and maintaining — Nous's build pipeline. Using the official image keeps rome-on-rails thin (its value is the Railway + Tailscale wrapping, not re-packaging Hermes), and version pinning is enforced by the immutable image tag.

**Tradeoff accepted:** Supply-chain dependency on Docker Hub and the `nousresearch/hermes-agent` namespace. See Risk 6 in `HANDOFF.md`.

---

### 2026-04-22 — Volume mount path is `/opt/data` (upstream default), not `/data`

**Decision:** The Railway persistent volume mounts at `/opt/data`, matching the upstream image's built-in `HERMES_HOME` default and `VOLUME` directive. No env overrides.

**Rationale:** The upstream image already declares `ENV HERMES_HOME=/opt/data` and `VOLUME ["/opt/data"]`. Mounting Railway's volume at the same path means no env overrides are required, and any path assumptions inside the upstream image work without modification.

**Tradeoff:** `/data` is the more conventional Railway volume path. `/opt/data` is slightly less idiomatic for Railway but avoids any deviation from upstream's assumptions.

---

### 2026-04-22 — Start command is `hermes gateway run`

**Decision:** The container's `CMD` is `["gateway", "run"]`, which starts the Hermes messaging gateway (Slack + cron scheduler).

**Rationale:** Echobind's primary user-facing access pattern is Slack. The gateway is the mode that connects to Slack.

**Note (updated 2026-04-24):** We previously believed `hermes gateway run` also served the web dashboard on port 9119. It does not — the dashboard is a separate `hermes dashboard` command, and an *always-on* dashboard remains out of scope for v1 (it would require a second long-running process in the container and formal supervision). Ad-hoc dashboard access is supported: maintainers start the dashboard by hand from inside an SSH session and tunnel it over `ssh -L` to their laptop. See `docs/dashboard-access.md`. Routine maintenance still goes through `tailscale ssh` + the `hermes` CLI.

---

### 2026-04-22 — No public Railway domain on the Hermes service

**Decision:** Deploy Hermes as a Railway worker service type. No inbound ports exposed (`Dockerfile` has no `EXPOSE`), no Railway-assigned public URL.

**Rationale:** Core security requirement. With no `EXPOSE` directive and worker service type, accidental public exposure becomes architecturally difficult, not just "don't do it." The Slack integration uses Socket Mode (outbound), so no inbound path is needed for normal operation.

---

### 2026-04-22 — Template deploy clones repo into user's own GitHub account

**Decision:** The Railway deploy button is configured so that deploying the template creates a copy of the repo in the deploying engineer's GitHub account (or the Echobind org), rather than deploying directly from `echobind/rome-on-rails`.

**Rationale:** Each engineer owns their deployment. They can customize their instance, update their pinned version independently, and the canonical template repo is not coupled to any live deployment.

**Implication:** Engineers are responsible for pulling upstream changes from `echobind/rome-on-rails` if they want future improvements.

---

### 2026-04-22 — Secrets live in Railway environment variables, not in the volume

**Decision:** All API keys, bot tokens, and auth secrets (including `TS_AUTHKEY`) are stored as Railway environment variables only. The `entrypoint.sh` script reads them from the environment at runtime — they are never persisted to the volume or committed to the repo.

**Rationale:** The volume is backed up by Railway and contains data we want to survive redeploys (sessions, memory, skills, tailnet identity). If the volume were compromised or accidentally shared, it should contain no credentials. Railway environment variables have their own access controls and are not included in volume exports.

---
