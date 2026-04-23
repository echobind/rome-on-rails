# HANDOFF.md — rome-on-rails

## Last updated: 2026-04-23

This document is for engineers taking over maintenance of rome-on-rails, or returning to it after an extended absence. It summarizes the architecture, flags known risks, and records recommendations that didn't fit neatly into the README or ARCHITECTURE docs.

---

## What This Is, In Plain Terms

rome-on-rails is a deployment template. It is not a fork of Hermes, and it contains no Hermes source code. It is a thin wrapper that:

1. Packages Hermes at a pinned version into a Docker container
2. Provides an entrypoint script that configures Hermes from environment variables
3. Documents how to deploy it on Railway with Tailscale in front of it

The actual Hermes agent is a dependency — it is installed during the Docker build. Everything Hermes-specific (skills, memory, sessions) lives in the persistent volume at `/data`.

---

## Architecture Summary

Two Railway services in one project:

- **Hermes service** — runs the agent gateway and dashboard on port 9119. Worker type (no public URL). Persistent volume at `/data`.
- **Tailscale service** — subnet router that bridges your tailnet into Railway's private network. Enables access to `hermes.railway.internal:9119` from any device on the tailnet.

No traffic from the public internet can reach Hermes. The only access path goes through Tailscale authentication first.

Full details: [ARCHITECTURE.md](./ARCHITECTURE.md)

---

## Known Risks

### Risk 1 — Hermes is a fast-moving project with date-based versioning
Hermes was first released in early 2026. As of the initial rome-on-rails build (2026-04-22), the pinned version is **v2026.4.16**. Hermes uses **date-based versioning** (`vYYYY.M.D`) rather than semver, so you cannot infer "major/minor/patch" from the version string — any two releases may contain breaking changes. The project moves fast (multiple releases per week), and the upstream changelog is the only reliable signal of what changed between pinned versions. **Review the changelog for every version between your current pin and the target before upgrading.**

Mitigation: Version is pinned via the base-image tag in the `Dockerfile` (`FROM nousresearch/hermes-agent:v2026.4.16`). Upgrades require a deliberate edit and redeploy.

### Risk 2 — The Tailscale auth key expires
If the `TS_AUTHKEY` environment variable holds an expiring auth key (not a reusable one), the Tailscale service will fail to rejoin the tailnet after the key expires. When that happens, Hermes becomes unreachable even though it is still running.

Mitigation: Use a reusable auth key. Document the key's expiration date. Consider an ephemeral key only if you want the node to disappear from the tailnet automatically if the Railway service is deleted.

### Risk 3 — Someone generates a public Railway domain for Hermes
Railway allows changing a service's configuration after deployment, including generating a public domain. If someone does this for the Hermes service (intentionally or by accident), Hermes becomes publicly accessible on that domain.

Mitigation: Document this risk in the README (done). Consider adding a Railway team access policy that restricts who can modify service settings if the Echobind Railway team grows.

### Risk 4 — Volume data is not encrypted at rest beyond Railway's default
The persistent volume contains session history, agent memory, and skill data. Railway volumes are encrypted at rest at the infrastructure level, but Hermes does not add an additional application-level encryption layer. If Railway's infrastructure were compromised, this data could be read.

Mitigation: This is acceptable for Echobind's current threat model. If this becomes a concern, the volume contents can be encrypted with a key stored as a Railway environment variable — but this adds significant complexity to the entrypoint script and is not implemented in v1.

### Risk 5 — Secrets in Railway env vars are visible to anyone with Railway project access
Anyone with Railway access to the rome-on-rails project can view the environment variables, including `OPENROUTER_API_KEY`, `SLACK_BOT_TOKEN`, etc.

Mitigation: Limit Railway project access to engineers who need it. Use Railway's team roles to enforce this.

### Risk 6 — Supply-chain dependency on `nousresearch/hermes-agent` on Docker Hub
The Hermes service builds `FROM nousresearch/hermes-agent:<version>` — the official Nous Research image on Docker Hub. We rely on that image and tag remaining available, unmodified, and trustworthy.

Failure modes this exposes us to:
- **Tag yanked or removed:** A pinned version could become unpullable, blocking future Railway redeploys of the same version.
- **Namespace compromise:** If the `nousresearch` Docker Hub account were compromised and a malicious image pushed under a tag we rely on, a redeploy could pull the malicious image. (Pulled images are cached by Railway per build; existing deploys are not retroactively swapped.)
- **Silent rebuilds of an immutable-looking tag:** Docker Hub tags are mutable unless pinned by digest. We pin by tag, not digest.

Mitigation: This is an accepted risk for v1 because the alternative (building from source, tracking upstream's multi-stage Dockerfile ourselves) adds significantly more maintenance surface. If this becomes a concern, we can upgrade the pin to `FROM nousresearch/hermes-agent@sha256:<digest>` — which is immutable — and bump the digest alongside the tag on each upgrade. We should also subscribe to Nous Research's release channel for security advisories.

### Risk 7 — Slack user access is gated entirely by `SLACK_ALLOWED_USERS`
Hermes exposes exactly one per-user allowlist for the Slack gateway: the `SLACK_ALLOWED_USERS` environment variable. It is a comma-separated list of Slack member IDs, set in Railway. This is the *only* Slack user-level access control in the stack — there is no Hermes-side role system, no dashboard UI for managing allowed users, and no second-factor check. Whoever is listed there can interact with the bot in any channel the bot is invited to.

Three specific concerns this creates:

- **First-deploy confusion (fail-closed, verified 2026-04-23).** When no per-platform allowlist is set, Hermes's gateway startup logs an explicit warning and denies all unauthorized users. The exact warning emitted on pinned version v2026.4.16: `No user allowlists configured. All unauthorized users will be denied. Set GATEWAY_ALLOW_ALL_USERS=true in ~/.hermes/.env to allow open access, or configure platform allowlists (e.g., TELEGRAM_ALLOWED_USERS=your_id).` In practice this means an operator who skips `SLACK_ALLOWED_USERS` on first deploy sees a bot that appears online in Slack but silently refuses to respond. The fix is to set the variable; the first-look confusion is real.
- **`GATEWAY_ALLOW_ALL_USERS` is an unsafe master override.** The warning above advertises `GATEWAY_ALLOW_ALL_USERS=true` as the way to enable "open access." This is a gateway-wide switch that disables all per-platform allowlists at once across every messaging platform Hermes supports. It must **never** be set in a rome-on-rails deployment — it is the literal opposite of the access model we care about. Listed in `docs/secrets-guide.md` under variables you must not set.
- **Membership drift on offboarding.** When an engineer leaves the team, their Slack member ID must be removed from `SLACK_ALLOWED_USERS` in Railway. There is no automatic sync with the Slack workspace or with Echobind's identity provider. Leaving a departed user in the list keeps them authorized to invoke the agent from any workspace they still belong to.

Mitigation: Make `SLACK_ALLOWED_USERS` a required field in the Railway template prompts (to be documented in `railway/template-notes.md` when written). Treat updates to the allowlist as a standard step in Echobind's offboarding checklist. Add a note to the README's troubleshooting section stating that "bot online in Slack but does not respond" is most likely a missing or incorrect `SLACK_ALLOWED_USERS`. Re-verify the unset-behavior against any new pinned Hermes version during upgrade smoke tests — upstream could change this default between releases.

---

## Recommendations for Future Maintainers

### On upgrading Hermes
Before upgrading the pinned version, always read the full changelog for every version between the current pin and the target. Hermes has a history of making breaking changes to config format and gateway behavior between minor versions. Test the upgrade in a Railway preview environment before deploying to production.

### On the Tailscale setup
The subnet router approach gives tailnet access to the entire Railway private network for the project — not just Hermes. If you add additional services to the Railway project (e.g., a database), they also become reachable from the tailnet. This is probably fine for Echobind's use, but be aware of it.

An alternative with narrower scope is the Tailscale Forwarder pattern, which proxies only specific ports rather than advertising the whole subnet. If Echobind's Railway projects grow and include services that should not be reachable via tailnet, consider migrating to the Forwarder pattern.

### On the Railway template
The Railway template configuration (service definitions, env var prompts, volume mounts) lives inside Railway's platform — it cannot be stored in this repository. The file `railway/template-notes.md` documents what is configured there so it can be recreated if the template is lost or needs to be rebuilt.

### On the repo being public
The repo must remain public for the Railway deploy button to work. This means the `Dockerfile`, `entrypoint.sh`, and all documentation are publicly readable. This is fine — none of them contain secrets. If Echobind ever needs to make the repo private, the Railway template will need to be rebuilt using Railway's private repo template feature, which requires a Pro plan.

---

## What v1 Intentionally Does Not Include

Per the project scope, the following were explicitly deferred:

- Custom UI or branding on the Hermes dashboard
- Enterprise SSO or SAML in front of the dashboard
- Advanced observability dashboards (Grafana, etc.)
- Multi-region Railway deployments
- Any changes to Hermes source code

If these are needed in the future, they should be treated as separate projects that extend rome-on-rails rather than modifications to the core template.

---

## Contacts and Context

- **Project owner:** Echobind engineering team
- **Hermes upstream:** [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- **Railway docs:** [docs.railway.com](https://docs.railway.com)
- **Tailscale subnet router guide:** [docs.railway.com/guides/set-up-a-tailscale-subnet-router](https://docs.railway.com/guides/set-up-a-tailscale-subnet-router)

---
