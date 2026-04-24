# railway/template-notes.md

> **Status: blueprint, not yet implemented.**
> The Railway template described in this document **does not exist yet**.
> This file is a spec for what the template must contain when we build it, and a reference for recreating it if the Railway template is ever lost, corrupted, or needs to be rebuilt from scratch.
>
> Once the template is created in Railway, this file should be updated from "blueprint" to "as-built reference" and kept in sync with the actual Railway UI configuration going forward.

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

---

## Service: `hermes`

### Source

- **Build method:** Dockerfile in this repo
- **Repository:** `echobind/rome-on-rails` (public; required so the Railway deploy button works)
- **Tracked branch:** `main`
- **Dockerfile path:** `./Dockerfile`

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
| `TS_HOSTNAME` | "Tailnet hostname for this agent. Leave blank to auto-derive from `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}`. Set explicitly if you want a shorter or more meaningful name." | No | No |
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

---

## Template rebuild checklist

If the template is lost and must be rebuilt from scratch, use this checklist:

- [ ] Create a new Railway project
- [ ] Add a single service: deploy from `echobind/rome-on-rails` on `main`, Dockerfile build, **worker type**
- [ ] Attach a volume at `/opt/data` on that service
- [ ] Add all env-var prompts from the tables above
- [ ] Verify the service has no public domain generated (Railway settings → Networking)
- [ ] Verify no `EXPOSE` port is being respected (Dockerfile intentionally has none)
- [ ] Publish the project as a Railway template
- [ ] Copy the resulting template URL into this repo's README, replacing `TEMPLATE_ID_PLACEHOLDER` in the deploy button
- [ ] Test the deploy button end-to-end with a throwaway fork before announcing
- [ ] Update this file: change the status banner at the top from "blueprint" to "as-built reference" and record the template URL here

---

## Related docs

- `README.md` — end-user deploy instructions
- `ARCHITECTURE.md` — authoritative technical reference, including all decision rationale
- `HANDOFF.md` — known risks (Risks 1, 2, 3, 5, 6, 7, 8 all matter for operators)
- `docs/tailscale-setup.md` — Tailscale operational details (auth keys, ACLs, troubleshooting)
- `docs/secrets-guide.md` — full environment variable reference
