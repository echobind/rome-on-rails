# HANDOFF.md — rome-on-rails

## Last updated: 2026-05-15

This document is for engineers taking over maintenance of rome-on-rails, or returning to it after an extended absence. It summarizes the architecture, flags known risks, and records recommendations that didn't fit neatly into the README or ARCHITECTURE docs.

---

## What This Is, In Plain Terms

rome-on-rails is a deployment template. It is not a fork of Hermes, and it contains no Hermes source code. It is a thin Docker wrapper that:

1. Pulls the official Hermes image at a pinned version
2. Adds Tailscale (installed via apt) so the container is itself a tailnet node with SSH enabled
3. Provides an entrypoint that starts `tailscaled`, brings the Tailscale node up, then hands off to the upstream Hermes entrypoint
4. Documents how to deploy it on Railway with a Tailscale auth key
5. Optionally runs a tiny "control sidecar" HTTP service (`roster-control-sidecar.py`) that lets Echobind's control plane (Roster) read and change the agent's LLM model over the tailnet — off unless `ROSTER_CONTROL_TOKEN` is set. See `docs/hermes-control-sidecar-contract.md` and ARCHITECTURE.md's "The Roster Control Sidecar" section.

Hermes runs in outbound-only mode (Slack via Socket Mode, LLM via outbound HTTPS). Maintainers reach the container via `tailscale ssh hermes@<agent-hostname>` on the tailnet. Everything Hermes-specific (skills, memory, sessions, Tailscale state) lives in the persistent volume at `/opt/data`.

---

## Architecture Summary

**One Railway service per rome-on-rails deployment.** The service runs our Dockerfile, which builds on top of the official Hermes image and adds Tailscale. The container has:

- No inbound ports exposed
- An outbound WebSocket to Slack (Socket Mode)
- An outbound connection to the Tailscale control plane
- Tailscale SSH enabled, letting maintainers reach an interactive shell via `tailscale ssh hermes@<agent-hostname>`
- Optionally, the Roster control sidecar — a `127.0.0.1`-bound HTTP service exposed onto the tailnet via `tailscale serve`, for remote LLM-model control (only when `ROSTER_CONTROL_TOKEN` is set)

Multi-agent is supported two ways:

- **Separate Railway projects** — one per client or billing owner. Each project has its own `TS_AUTHKEY`, its own LLM key, its own Slack apps. Used when agents belong to genuinely different owners.
- **Multiple services in one Railway project** — one service per agent within a single client's fleet. Added after the initial template deploy via Railway's "Duplicate Service" UI action. Each duplicated service needs `TS_HOSTNAME` + Slack tokens overridden before first deploy (see `docs/multi-agent.md` and Risk 10 below). Shared across services: `TS_AUTHKEY` and the LLM provider key.

Each agent — regardless of which pattern — registers as a unique tailnet node with its own MagicDNS hostname.

Full details: [ARCHITECTURE.md](./ARCHITECTURE.md)

---

## Known Risks

### Risk 1 — Hermes is a fast-moving project with date-based versioning
Hermes was first released in early 2026. As of the initial rome-on-rails build (2026-04-22), the pinned version is **v2026.4.16**. Hermes uses **date-based versioning** (`vYYYY.M.D`) rather than semver, so you cannot infer "major/minor/patch" from the version string — any two releases may contain breaking changes. The project moves fast (multiple releases per week), and the upstream changelog is the only reliable signal of what changed between pinned versions. **Review the changelog for every version between your current pin and the target before upgrading.**

Mitigation: Version is pinned via the base-image tag in the `Dockerfile` (`FROM nousresearch/hermes-agent:v2026.4.16`). Upgrades require a deliberate edit and redeploy. After each upgrade, re-verify the `SLACK_ALLOWED_USERS` fail-closed behavior (Risk 7) — upstream could change it between releases.

### Risk 2 — The Tailscale auth key expires or is invalidated
If `TS_AUTHKEY` is an expiring key (not reusable), revoked, or removed from the tailnet's auth-key list, the next container restart cannot re-register with the tailnet. The container keeps running — **Slack keeps working, because Slack connectivity is independent of Tailscale** — but `tailscale ssh` access for maintainers stops working at the next redeploy or restart.

In practice this manifests as "I can't SSH in anymore" even though the agent is still serving Slack. Existing `tailscaled` sessions keep running until the process or container is restarted; once restarted, it can't re-auth.

Mitigation: Use a **reusable** auth key. Document its expiration date. Rotate the key in Railway env vars before expiration and redeploy. If locked out, Railway's own service logs and `railway shell` (via Railway CLI) are the out-of-band path.

### Risk 3 — Someone generates a public Railway domain for the service
Railway allows adding a public domain to a service after deployment. For rome-on-rails, the Dockerfile has no `EXPOSE` directive and no process listens on the would-be public port, so generating a domain is effectively a no-op — Railway would route traffic to a port nothing is listening on. But:

- A future change might add an `EXPOSE` directive or start an HTTP server inside the container; if a public domain exists at that point, the thing you added is suddenly public
- Someone adding a domain + also changing service config is a foreseeable compound mistake

Mitigation: The README and `railway/template-notes.md` both instruct operators not to add a public domain. If the Echobind Railway team grows, consider a workspace-level policy restricting who can modify service settings. As long as no inbound ports are exposed and no HTTP server runs in the container, the blast radius of accidentally adding a domain is zero — preserve that property deliberately when evolving the Dockerfile.

### Risk 4 — Volume data is not encrypted at rest beyond Railway's default
The persistent volume contains session history, agent memory, skills data, and **Tailscale machine identity** (including SSH host keys at `/opt/data/.tailscale/`). Railway volumes are encrypted at rest at the infrastructure level, but rome-on-rails does not add an application-level encryption layer. If Railway's infrastructure were compromised, this data could be read.

Additional note on Tailscale state: if the `/opt/data/.tailscale/` directory is exfiltrated, an attacker has the agent's tailnet machine identity and could in theory impersonate the agent on the tailnet. Tailscale-side mitigation: revoke the compromised machine in Tailscale admin, which invalidates its session server-side.

Mitigation: Acceptable for Echobind's current threat model. If it becomes a concern, encrypting the volume at the application layer (keyed by a Railway env var) can be added, but it adds significant complexity to the entrypoint and is not implemented in v1.

### Risk 5 — Secrets in Railway env vars are visible to anyone with Railway project access
Anyone with Railway access to a rome-on-rails project can view the environment variables, including `OPENROUTER_API_KEY`, `SLACK_BOT_TOKEN`, `TS_AUTHKEY`, etc.

Mitigation: Limit Railway project access to engineers who need it. Use Railway's team roles to enforce this. `TS_AUTHKEY` in particular: if an engineer leaves the team and had Railway access, rotate it (revoke the old key even if they were the reusable-key holder).

### Risk 6 — Supply-chain dependency on `nousresearch/hermes-agent` on Docker Hub
The Hermes service builds `FROM nousresearch/hermes-agent:<version>` — the official Nous Research image on Docker Hub. We rely on that image and tag remaining available, unmodified, and trustworthy.


Failure modes this exposes us to:

- **Tag yanked or removed:** A pinned version could become unpullable, blocking future Railway redeploys.
- **Namespace compromise:** If the `nousresearch` Docker Hub account were compromised and a malicious image pushed under a tag we rely on, a redeploy could pull the malicious image.
- **Silent rebuilds of an immutable-looking tag:** Docker Hub tags are mutable unless pinned by digest. We pin by tag, not digest.

Mitigation: Accepted risk for v1. If concerns escalate, upgrade the pin to `FROM nousresearch/hermes-agent@sha256:<digest>` — immutable — and bump the digest alongside the tag on each upgrade. Subscribe to Nous Research's release channel for security advisories.

### Risk 7 — Slack user access is gated entirely by `SLACK_ALLOWED_USERS`
Hermes exposes exactly one per-user allowlist for the Slack gateway: the `SLACK_ALLOWED_USERS` environment variable. It is a comma-separated list of Slack member IDs, set in Railway. This is the *only* Slack user-level access control in the stack — there is no Hermes-side role system, no dashboard UI for managing allowed users, and no second-factor check. Whoever is listed there can interact with the bot in any channel the bot is invited to.

Three specific concerns this creates:

- **First-deploy confusion (fail-closed, verified 2026-04-23).** When no per-platform allowlist is set, Hermes's gateway startup logs an explicit warning and denies all unauthorized users. The exact warning emitted on pinned version v2026.4.16: `No user allowlists configured. All unauthorized users will be denied. Set GATEWAY_ALLOW_ALL_USERS=true in ~/.hermes/.env to allow open access, or configure platform allowlists (e.g., TELEGRAM_ALLOWED_USERS=your_id).` In practice this means an operator who skips `SLACK_ALLOWED_USERS` on first deploy sees a bot that appears online in Slack but silently refuses to respond.
- **`GATEWAY_ALLOW_ALL_USERS` is an unsafe master override.** The warning above advertises `GATEWAY_ALLOW_ALL_USERS=true` as the way to enable "open access." This is a gateway-wide switch that disables all per-platform allowlists at once across every messaging platform Hermes supports. It must **never** be set in a rome-on-rails deployment — it is the literal opposite of the access model we care about. Listed in `docs/secrets-guide.md` under variables you must not set.
- **Membership drift on offboarding.** When an engineer leaves the team, their Slack member ID must be removed from `SLACK_ALLOWED_USERS` in Railway. There is no automatic sync with the Slack workspace or with Echobind's identity provider. Leaving a departed user in the list keeps them authorized to invoke the agent from any workspace they still belong to.

Mitigation: Make `SLACK_ALLOWED_USERS` a required field in the Railway template prompts (documented in `railway/template-notes.md`). Treat updates to the allowlist as a standard step in Echobind's offboarding checklist. Add a note to the README's troubleshooting section stating that "bot online in Slack but does not respond" is most likely a missing or incorrect `SLACK_ALLOWED_USERS`. Re-verify the unset-behavior against any new pinned Hermes version during upgrade smoke tests.

### Risk 8 — Tailscale installed via apt — supply-chain dependency on pkgs.tailscale.com
Our Dockerfile installs Tailscale via its official apt repo (`pkgs.tailscale.com/stable/debian/trixie`), imported with GPG verification. We trust:

- The apt repo URL staying live
- The signing key at `pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg` remaining valid
- Tailscale's release tooling not pushing a compromised package

Failure modes:

- **Repo outage during build:** A Railway rebuild at a bad time could fail to install Tailscale. Builds retry, so usually self-heals.
- **Signing-key rotation:** If Tailscale rotates their GPG key and we don't update our Dockerfile, future builds fail signature verification until we bump the key URL.
- **Namespace / key compromise at Tailscale:** Unlikely but consequential — a malicious package pushed through the apt repo would land in our next build.

Mitigation: Accepted risk for v1 (Tailscale is a well-resourced, well-monitored vendor). If security posture increases: pin Tailscale to a specific version (`apt-get install tailscale=<version>`) and/or download the `tailscaled` binary directly from `pkgs.tailscale.com/stable/` with a published SHA256 check.

### Risk 9 — Tailscale's userspace networking mode has lower throughput than kernel TUN
We run `tailscaled --tun=userspace-networking` because Railway containers don't reliably have TUN devices or `NET_ADMIN`. Userspace mode is slower than kernel TUN — Tailscale documents this but doesn't give specific numbers.

For our usage (SSH sessions + CLI traffic, not bulk data transfer), the throughput penalty is not observable in practice. If a future use case needs high-throughput tailnet traffic (e.g., file copies, tunneled HTTP to a self-hosted LLM), this assumption will need to be re-examined.

### Risk 10 — Slack-app crosswiring on service duplication in a multi-agent project
When an operator adds a second agent to an existing Railway project using Railway's "Duplicate Service" action (the Pattern B multi-agent flow — see `docs/multi-agent.md`), the duplicated service inherits every env var from the original. If Railway auto-deploys the duplicate before the operator overrides `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`, **two containers end up connected to the same Slack app and both respond to every message in that workspace.** The symptom is a bot that appears to be stuttering or double-posting, and debug is confusing because both containers' logs look normal — each thinks it's the only agent serving the workspace.

A related variant: if `TS_HOSTNAME` isn't overridden, the duplicated service registers with the same hostname as the original (both fall back to the `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}` default). Tailscale admin shows two machines fighting over the same name; the most recent registrant wins and the other is unreachable via MagicDNS. Less dangerous than the Slack crosswiring, but also less obvious to detect.

Mitigation:

- `docs/multi-agent.md` explicitly instructs operators to override `TS_HOSTNAME`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, and `SLACK_ALLOWED_USERS` on the duplicate **before first deploy**, and recommends pausing auto-deploy on the duplicated service if Railway's UI permits it.
- The `TS_HOSTNAME` prompt copy in `railway/template-notes.md` flags the hostname-collision case explicitly.
- No platform-layer enforcement is possible — Railway doesn't offer a hook for "reject deploy if these vars are unchanged since duplication." Operator discipline is the only mitigation. If this risk materializes often enough to be painful, consider adding an entrypoint check that refuses to start the Slack gateway if the bot token matches a known fingerprint from a sibling service in the same project (complex; defer unless needed).

Known-good operator behavior: duplicate the service, immediately open Railway's Variables panel on the duplicate, change the four per-agent vars, save. Then let Railway deploy.

### Risk 11 — Webhook URL setup is a manual per-tenant step
Railway's GraphQL API exposes `webhookTest` (for sending sample payloads) but does **not** expose mutations to create, update, or delete webhooks programmatically — verified 2026-04-29 against the live schema with a workspace token. The control-plane frontend that operates rome-on-rails deployments relies on webhooks for deployment status updates; an operator must paste the per-tenant receiver URL into Railway's Project Settings → Webhooks panel once per tenant.

If skipped, the tenant's status indicators in the control plane stop updating: deployment lifecycle events (success, failed, crashed) won't reach the UI. The agent itself still works fine — Slack continues to function, `tailscale ssh` access still works, and lifecycle mutations from the control plane (stop/restart/redeploy) still execute correctly. The only thing that breaks is the asynchronous "did my deploy succeed?" feedback loop, so an operator may not realize the webhook is missing until they redeploy and the UI hangs in `BUILDING` forever.

A related foot-gun: the Postman collection at `docs/railway_graphql_collection.json` lists `webhookCreate`/`webhookUpdate`/`webhookDelete` request templates that look like they should work, but those mutations are **not** in Railway's live schema. A future maintainer who finds those entries and assumes they're functional will hit `Cannot query field "webhookCreate" on type "Mutation"`. Treat that collection as a stale hint, not a contract — verify mutations against introspection before relying on them.

Mitigation:

- The operator runbook lives in `docs/webhook-setup.md` and is referenced from the control-plane's tenant-onboarding UI.
- The control plane's tenant detail page shows a "webhook configured?" indicator that stays gray until the first webhook arrives, turning green permanently after.
- A scheduled check alerts when any tenant has had >0 deployments but never received a webhook event (catches "operator pasted the wrong URL" too).
- The relevant introspection query is in `docs/POSTMAN-API-TESTS.md` Phase 7.1 — re-run periodically to detect when programmatic webhook configuration becomes available; if it ever does, this manual step retires.

### Risk 12 — The Roster control sidecar adds a (small, optional, tailnet-only) write surface

When `ROSTER_CONTROL_TOKEN` is set, the container runs the Roster control sidecar — an HTTP service that can **write `config.yaml` and restart the gateway**. It is deliberately minimal (binds `127.0.0.1`, exposed to the tailnet only via `tailscale serve`, bearer-token auth, two functional endpoints) and the agent runs fine without it. But it is the first thing in this template that accepts inbound requests and changes agent state, so it carries real risks:

- **The bearer token is the whole authorization layer.** Transport is plain HTTP — exposed onto the tailnet via `tailscale serve --http` (no TLS termination, no cert dance). The tailnet's WireGuard encryption is what protects it in flight, and `ROSTER_CONTROL_TOKEN` is what authorizes the caller. Anyone on the tailnet who has the token can change the agent's model. Keep it per-agent, never commit it, rotate on leak or engineer offboarding (same discipline as the other secrets — add it to `docs/secrets-guide.md`'s rotation table mentally). On a Pattern B multi-agent project, each duplicated service needs its **own** token — a duplicated service inherits the original's, which must be overridden (same foot-gun shape as Risk 10's Slack tokens).
- **A model change restarts the gateway.** `POST /model` with the default `restart: true` spawns `hermes gateway restart`, which re-execs the running gateway. That interrupts any in-flight Hermes session. It is the intended behavior (an operator changing the model expects it to take effect), but be aware a Roster-initiated model change is not free of blast radius — it is a gateway bounce.
- **Silent disable if `gosu` disappears.** The sidecar runs as the `hermes` user via `gosu`. If a future upstream image drops `gosu`, `entrypoint.sh` **disables the sidecar** (with a warning in the startup logs) rather than running it as root. This is the correct fail-closed behavior, but the failure is only as visible as the startup logs are read — the symptom is "Roster can't reach the agent" with no other signal. If Roster reports an agent as uncontrollable, check the container's startup logs for the `gosu not found` warning. (Realistically `gosu` won't vanish — the upstream entrypoint depends on it too — but the dependency is worth knowing.)
- **`config.yaml` write is single-writer by design (contract §6).** No file locking. A Railway redeploy landing in the microsecond window of a `save_config()` could in theory corrupt `config.yaml`. Accepted for v1: Roster is the only automated caller, the window is tiny, and `save_config()` is Hermes' own primitive. If `config.yaml` corruption is ever observed, this is the first place to look.
- **`tailscale serve` config persists in tailnet state.** The serve mapping is stored in `tailscaled`'s state (on the volume at `/opt/data/.tailscale/`). `entrypoint.sh` re-asserts it on every boot, so it self-heals — but if an operator *changes* `ROSTER_CONTROL_PORT`, the serve mapping for the *old* port lingers until the volume's Tailscale state is reset. Low impact; note it if port changes ever cause confusion.

Mitigation: the sidecar is opt-in (no token ⇒ it never runs), the surface is genuinely tiny (it cannot read secrets, open a shell, or touch sessions — unlike the full Hermes dashboard), and it shares the tailnet's existing trust boundary rather than adding a new one. The interface contract `docs/hermes-control-sidecar-contract.md` is the source of truth and is co-owned with the Roster repo — change it there first if the interface ever needs to move.

---

## Recommendations for Future Maintainers

### On upgrading Hermes
Before upgrading the pinned version, read the full changelog for every version between the current pin and the target. Hermes has a history of breaking changes between minor versions. Test the upgrade in a Railway preview environment before deploying to production, and explicitly re-verify `SLACK_ALLOWED_USERS` behavior (Risk 7) against the new version.

### On Tailscale SSH ACLs
By default, any tailnet member can `tailscale ssh` to any machine tagged appropriately. For multi-agent deployments where different engineers maintain different agents, consider writing Tailscale ACLs that restrict which tailnet users can SSH to which agent hostnames. See `docs/tailscale-setup.md` for a starting template.

### On the Railway template
The Railway template configuration (service definitions, env var prompts, volume mounts) lives inside Railway's platform — it cannot be stored in this repository. The file `railway/template-notes.md` documents what is configured there so it can be recreated if the template is lost or needs to be rebuilt.

### On the repo being public
The repo must remain public for the Railway deploy button to work. This means the `Dockerfile`, `entrypoint.sh`, and all documentation are publicly readable. This is fine — none of them contain secrets. If Echobind ever needs to make the repo private, the Railway template will need to be rebuilt using Railway's private repo template feature, which requires a Pro plan.

### On adding a second process or service
Don't add services to the Railway project unless necessary. The current single-service design is a core property — it's what makes the multi-agent story work (each service is one tailnet node). Adding a second service per project would get us back into the subnet-router coordination problems we deliberately exited.

If Hermes itself grows a sub-process requirement (e.g., a separate worker), prefer running it inside the same container via the same bash-backgrounding pattern. Reconsider the supervision story only if we hit actual operational pain.

The Roster control sidecar (added 2026-05-14) is the first application of this guidance — it is a second backgrounded process inside the Hermes container, not a second Railway service, exactly as recommended above. That leaves us at two backgrounded secondaries (`tailscaled` + sidecar). A *third* would be the signal to revisit the "no s6-overlay" decision in ARCHITECTURE.md — not before.

---

## What v1 Intentionally Does Not Include

Per the current project scope, the following were explicitly deferred:

- **An always-on Hermes web dashboard.** Upstream `hermes dashboard` is a separate command; running it as a second long-running process alongside the gateway would require a real supervisor (s6-overlay, supervisord) instead of our bash-backgrounding pattern. Deferred. Ad-hoc dashboard access **is** supported and documented — maintainers start the dashboard by hand from inside an SSH session and tunnel it to their laptop via `ssh -L`. See `docs/dashboard-access.md`. If ad-hoc use becomes frequent enough that operators ask for a persistent dashboard, re-evaluate the supervisor upgrade at that point.
- **Enterprise SSO or SAML.** Not needed when the only human-facing surface is Slack (handled via Slack's own auth).
- **Advanced observability dashboards (Grafana, etc.).** Railway's log viewer + `hermes logs` via SSH is sufficient.
- **Multi-region Railway deployments.** Each rome-on-rails is a single-region Railway project.
- **Any changes to Hermes source code.** We are a wrapper, not a fork.

If these are needed in the future, they should be treated as separate projects that extend rome-on-rails rather than modifications to the core template.

---

## Contacts and Context

- **Project owner:** Echobind engineering team
- **Hermes upstream:** [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- **Railway docs:** [docs.railway.com](https://docs.railway.com)
- **Tailscale SSH docs:** [tailscale.com/kb/1193/tailscale-ssh](https://tailscale.com/kb/1193/tailscale-ssh)
- **Tailscale containers guide:** [tailscale.com/kb/1282/docker](https://tailscale.com/kb/1282/docker)

---
