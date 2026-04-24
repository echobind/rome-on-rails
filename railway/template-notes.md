# railway/template-notes.md

> **Status: as-built reference (published 2026-04-24).**
> The Railway template is live at [railway.com/deploy/NBsSYG](https://railway.com/deploy/NBsSYG?utm_medium=integration&utm_source=template&utm_campaign=generic).
> This document records its intended configuration — the source of truth for what the published template contains. Any deviation between this file and the live Railway UI should be either corrected in Railway or reflected back into this file with a note explaining why. If the template is ever deleted or needs to be rebuilt, the [rebuild checklist](#template-rebuild-checklist) at the bottom is the reconstitution procedure.

---

## Why this file exists

Railway's template configuration (service definitions, environment-variable prompts, volume mounts, default commands) lives inside Railway's platform. There is no way to check it into this repository as code. If the template is deleted or needs to be recreated, the only way to reconstitute it correctly is from written notes — this file.

Treat this document as the **source of truth for the template's intended configuration**. Any deviation in the live Railway template should be either corrected in Railway or reflected back into this file (with a note explaining why we diverged).

---

## Template overview

The rome-on-rails Railway template provisions **one project with one service**:

| Service | Purpose | Deploy source |
|---|---|---|
| `hermes` | Runs the Hermes agent gateway (Slack via outbound Socket Mode) with Tailscale installed for maintainer SSH access | This GitHub repo, `main` branch, Dockerfile build |

The single-service design is deliberate — it's what makes multi-agent deployments on a shared tailnet work. The Tailscale daemon runs inside the Hermes container, not as a separate service. See `ARCHITECTURE.md` for the full rationale.

### Single-service by design — multi-agent is via duplication

The template ships a **single** Hermes service even for clients who will run multiple agents. We do not publish a 2-service, 3-service, etc. variant. Reasons:

- Railway templates fix service count at publish time; a fixed-N template can't serve clients whose N differs.
- "Duplicate service" is a first-class Railway UI feature, not a workaround.
- One template means one code path to test and ship.

When a client needs a second (or Nth) agent, the operator duplicates the Hermes service inside the Railway UI and overrides the per-agent env vars (`TS_HOSTNAME`, Slack tokens, allowed-users list). Shared-across-project vars (LLM key, `TS_AUTHKEY`) are copied by duplication and left as-is. The full workflow is in `docs/multi-agent.md`.

If a future template maintainer is tempted to publish multiple N-service variants: don't. Maintain the single template and improve the duplication docs.

---

## Service: `hermes`

### Source

- **Build method:** Dockerfile in this repo
- **Repository:** `echobind/rome-on-rails` (public; required so the Railway deploy button works)
- **Tracked branch:** `main`
- **Dockerfile path:** leave **blank** (auto-detect). Railway finds `Dockerfile` at repo root automatically. If you want to be explicit, set it to `Dockerfile` — no `./` prefix. Railway rejects `./Dockerfile` as "not found" (discovered 2026-04-24 during initial publish).

### Service type

**Worker.** This is the single most important configuration property in the template — it is what prevents Railway from assigning a public HTTPS URL.

If you ever recreate this template and Railway prompts to generate a public domain: **decline**. If the template UI asks what service type to deploy as: **worker**.

### Start command

None set in Railway. The `CMD ["gateway", "run"]` baked into the `Dockerfile` is authoritative. Overriding it in the Railway UI bypasses intended start behavior and should be treated as a misconfiguration.

### Port

None exposed. Our Dockerfile has no `EXPOSE` directive — Slack uses outbound Socket Mode, Tailscale SSH uses the tailnet, neither needs inbound ports. If Railway's template UI asks for a port, leave it blank.

### Persistent volume

| Property | Value |
|---|---|
| Mount path | `/opt/data` |
| Minimum size | 1 GB (Hermes + skills + Tailscale state is well under this; grow as needed) |
| Name | `hermes-data` (or whatever Railway's default is — any name works) |

The mount path **must** be `/opt/data`. The upstream Hermes image declares `VOLUME ["/opt/data"]` and expects `HERMES_HOME=/opt/data`. Our entrypoint also writes Tailscale state to `/opt/data/.tailscale/` so that machine identity persists across restarts. Mounting elsewhere breaks the bootstrap.

### Environment variable prompts

These are the prompts the template presents to the engineer at deploy time. Grouped by purpose.

#### Tailscale (required for maintainer access)

| Variable | Prompt copy | Required? | Secret? |
|---|---|---|---|
| `TS_AUTHKEY` | "Reusable Tailscale auth key from login.tailscale.com/admin/settings/keys. Required for maintainer SSH access to the agent. Without this, the agent runs (Slack still works) but you cannot `tailscale ssh` into it. Must be a reusable key." | Yes | Yes |
| `TS_HOSTNAME` | "Tailnet hostname for this agent — the name you'll `tailscale ssh` to. Keep it short, lowercase, dashes OK. Match the Slack bot's purpose for readability (e.g., `acme-sales`, `acme-support`). Leave blank on the first service to auto-derive from `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}`. **If you duplicate this service to add a second agent in the same project, you MUST set an explicit `TS_HOSTNAME` on the duplicate** — the auto-derive produces the same name on every service in the project and will collide in Tailscale. See `docs/multi-agent.md`." | No (but required on duplicated services) | No |
| `TS_EXTRA_ARGS` | "Additional flags passed to `tailscale up`. Example: `--advertise-tags=tag:hermes-agent` for ACL tagging. Do NOT include `--authkey`, `--hostname`, or `--ssh` — the entrypoint sets those." | No | No |

#### LLM provider (required — at least one)

| Variable | Prompt copy | Required? | Secret? |
|---|---|---|---|
| `OPENROUTER_API_KEY` | "OpenRouter API key. Recommended for first deploy — one key gives access to 200+ models. Leave blank if using another provider." | One of these four | Yes |
| `ANTHROPIC_API_KEY` | "Anthropic API key. Use for direct Claude access." | ↑ | Yes |
| `OPENAI_API_KEY` | "OpenAI API key. Use for direct GPT access." | ↑ | Yes |
| `GOOGLE_API_KEY` | "Google Generative AI API key. Use for direct Gemini access." | ↑ | Yes |
| `HERMES_INFERENCE_PROVIDER` | "Provider name (`openrouter`, `anthropic`, `openai`, `google`). Defaults to auto-detect based on which key is set." | No | No |

The template does not enforce the "at least one provider key" rule at the UI layer — `entrypoint.sh` warns at startup if none are set.

#### Slack (required for Slack usage — most deployments want all three)

| Variable | Prompt copy | Required? | Secret? |
|---|---|---|---|
| `SLACK_BOT_TOKEN` | "Slack bot token (`xoxb-...`). Required for the Slack gateway. Create a Slack app at api.slack.com/apps and install it to your workspace." | Yes, for Slack | Yes |
| `SLACK_APP_TOKEN` | "Slack app-level token (`xapp-...`). Required for Socket Mode. Generate from the Slack app's Basic Information page." | Yes, for Slack | Yes |
| `SLACK_ALLOWED_USERS` | "Comma-separated Slack member IDs permitted to interact with the bot (e.g., `U01234ABCDE,U05678FGHIJ`). **Required for Slack to function.** If unset, the Hermes gateway denies all messages and the bot appears online but silent. See HANDOFF.md Risk 7." | Yes, for Slack | No (IDs aren't secret, but treat as project-private) |

The `SLACK_ALLOWED_USERS` prompt copy must explicitly call out the fail-closed behavior — operators who skip it typically see a non-responsive bot and assume the gateway is broken.

#### Must-not-set (deliberately excluded from template prompts)

These variables exist in the Hermes ecosystem but must never be set in a rome-on-rails deployment.

| Variable | Why the template must not prompt for it |
|---|---|
| `HERMES_HOME` | Upstream sets this to `/opt/data`; overriding from Railway desyncs the container from the volume. |
| `HOME` | Same reason — overriding breaks upstream entrypoint's assumptions about `$HOME`. |
| `GATEWAY_ALLOW_ALL_USERS` | Disables all per-platform allowlists simultaneously and turns the bot into open access. Hermes surfaces it in a warning as an escape hatch, but it's the opposite of our access model. If a future template maintainer is tempted to expose this as a "make the bot accept everyone" toggle: don't. |

If a future template maintainer is tempted to "expose these as optional overrides", resist.

---

## Post-deploy manual steps (required, cannot be automated by the template)

After the template deploy, the operator must do two things to actually reach their agent:

1. **Generate a reusable Tailscale auth key** and paste it into `TS_AUTHKEY`. Even if you set this during template deploy, it's worth confirming the key is marked **reusable** in Tailscale admin. If the deploy used a non-reusable key, the container won't be able to re-register on its next restart.
2. **SSH in to confirm access:** `tailscale ssh hermes@<hostname>` from any device on the tailnet. If this works, the deploy succeeded.

These are documented in the README and `docs/tailscale-setup.md` — the template's deploy-button description should link there.

For operators who need a second or Nth agent in the same project, point them to `docs/multi-agent.md` (duplication workflow) and `docs/dashboard-access.md` (per-agent dashboard access via SSH local-forward with unique local ports).

---

## Template rebuild checklist

If the template is lost and must be rebuilt from scratch, use this checklist:

- [ ] Create a new Railway project
- [ ] Add a single service: deploy from `echobind/rome-on-rails` on `main`, Dockerfile build, **worker type**
- [ ] Leave the **Dockerfile Path** field blank (auto-detect) — do NOT set `./Dockerfile`, Railway rejects that value
- [ ] Attach a volume at `/opt/data` on that service
- [ ] Add all env-var prompts from the tables above; when publishing, mark every variable as a deploy-time prompt (not baked-in) so deployers enter their own values
- [ ] Verify the service has no public domain generated (Railway settings → Networking)
- [ ] Verify no `EXPOSE` port is being respected (Dockerfile intentionally has none)
- [ ] In the publish dialog: toggle "Add my referral code" **OFF** (this is a company template, not a personal one); leave "Add UTM parameters" ON
- [ ] Publish the project as a Railway template
- [ ] Copy the resulting template URL into this repo's README, replacing the current deploy-button URL
- [ ] Test the deploy button end-to-end with a throwaway fork before announcing
- [ ] Update the status banner at the top of this file with the new publish date and template URL

---

## Related docs

- `README.md` — end-user deploy instructions
- `ARCHITECTURE.md` — authoritative technical reference, including all decision rationale
- `HANDOFF.md` — known risks (Risks 1, 2, 3, 5, 6, 7, 8 all matter for operators)
- `docs/tailscale-setup.md` — Tailscale operational details (auth keys, ACLs, troubleshooting)
- `docs/secrets-guide.md` — full environment variable reference
- `docs/multi-agent.md` — running multiple agents in one Railway project via service duplication
- `docs/dashboard-access.md` — ad-hoc Hermes dashboard access over SSH local-forward
