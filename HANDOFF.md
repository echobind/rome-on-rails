# HANDOFF.md — rome-on-rails

## Last updated: 2026-04-24

This document is for engineers taking over maintenance of rome-on-rails, or returning to it after an extended absence. It summarizes the architecture, flags known risks, and records recommendations that didn't fit neatly into the README or ARCHITECTURE docs.

---

## What This Is, In Plain Terms

rome-on-rails is a deployment template. It is not a fork of Hermes, and it contains no Hermes source code. It is a thin Docker wrapper that:

1. Pulls the official Hermes image at a pinned version
2. Adds Tailscale (installed via apt) so the container is itself a tailnet node with SSH enabled
3. Provides an entrypoint that starts `tailscaled`, brings the Tailscale node up, then hands off to the upstream Hermes entrypoint
4. Documents how to deploy it on Railway with a Tailscale auth key

Hermes runs in outbound-only mode (Slack via Socket Mode, LLM via outbound HTTPS). Maintainers reach the container via `tailscale ssh hermes@<agent-hostname>` on the tailnet. Everything Hermes-specific (skills, memory, sessions, Tailscale state) lives in the persistent volume at `/opt/data`.

---

## Architecture Summary

**One Railway service per rome-on-rails deployment.** The service runs our Dockerfile, which builds on top of the official Hermes image and adds Tailscale. The container has:

- No inbound ports exposed
- An outbound WebSocket to Slack (Socket Mode)
- An outbound connection to the Tailscale control plane
- Tailscale SSH enabled, letting maintainers reach an interactive shell via `tailscale ssh hermes@<agent-hostname>`

Multi-agent: each rome-on-rails deployment is its own Railway project with its own Tailscale auth key. Each agent registers as a unique tailnet node with its own MagicDNS hostname — no conflicts between agents.

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

---

## What v1 Intentionally Does Not Include

Per the current project scope, the following were explicitly deferred:

- **The Hermes web dashboard.** Upstream `hermes dashboard` is a separate command; running it alongside the gateway would require either a second service (breaks multi-agent) or in-container process management complexity. Out of scope for v1; maintainers use `tailscale ssh` + `hermes` CLI instead.
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
