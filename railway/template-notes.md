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

The rome-on-rails Railway template provisions **one project with two services**:

| Service | Purpose | Deploy source |
|---|---|---|
| `hermes` | Runs the Hermes agent gateway (Slack + dashboard on port 9119) | This GitHub repo, `main` branch, Dockerfile build |
| `tailscale` | Subnet router bridging the tailnet into Railway's private network | Railway's official Tailscale Subnet Router template |

Both services belong to the **same Railway project** so they share the internal `*.railway.internal` DNS namespace.

---

## Service 1: `hermes`

### Source

- **Build method:** Dockerfile in this repo
- **Repository:** `echobind/rome-on-rails` (public; required so the Railway deploy button works)
- **Tracked branch:** `main`
- **Dockerfile path:** `./Dockerfile`

### Service type

**Worker.** This is the single most important configuration property in the whole template — it is what prevents Railway from assigning a public HTTPS URL.

If you ever recreate this template and Railway prompts to generate a public domain: **decline**. If the template UI asks what service type to deploy as: **worker**.

### Start command

None set in Railway. The `CMD ["gateway", "run"]` baked into the `Dockerfile` is authoritative. Overriding it in the Railway UI would bypass our intended start behavior and should be treated as a misconfiguration.

### Port

Internal-only. The Hermes dashboard listens on `9119`. Because this is a worker service, no public port is exposed.

### Persistent volume

| Property | Value |
|---|---|
| Mount path | `/opt/data` |
| Minimum size | 1 GB (Hermes with a handful of skills + sessions is well under this; grow as needed) |
| Name | `hermes-data` (or whatever Railway's default is — any name is fine) |

The mount path **must** be `/opt/data`. The upstream Hermes image declares `VOLUME ["/opt/data"]` and expects `HERMES_HOME=/opt/data`. Mounting elsewhere breaks the bootstrap.

### Environment variable prompts

These are the prompts the template presents to the engineer at deploy time. Grouped by purpose.

#### LLM provider (required — at least one)

| Variable | Prompt copy | Required? | Secret? |
|---|---|---|---|
| `OPENROUTER_API_KEY` | "OpenRouter API key. Recommended for first deploy — one key gives access to 200+ models. Leave blank if using another provider." | One of these four is required | Yes |
| `ANTHROPIC_API_KEY` | "Anthropic API key. Use this if calling Claude models directly." | ↑ | Yes |
| `OPENAI_API_KEY` | "OpenAI API key. Use this if calling GPT models directly." | ↑ | Yes |
| `GOOGLE_API_KEY` | "Google Generative AI API key. Use this if calling Gemini models directly." | ↑ | Yes |
| `HERMES_INFERENCE_PROVIDER` | "Provider name (`openrouter`, `anthropic`, `openai`, `google`). Defaults to auto-detect based on which key is set." | No | No |

The template does not enforce the "at least one provider key" rule at the UI layer — `entrypoint.sh` warns at startup if none are set.

#### Slack (required for Slack use — most deployments want all three)

| Variable | Prompt copy | Required? | Secret? |
|---|---|---|---|
| `SLACK_BOT_TOKEN` | "Slack bot token (`xoxb-...`). Required for the Slack gateway." | Yes, for Slack | Yes |
| `SLACK_APP_TOKEN` | "Slack app-level token (`xapp-...`). Required for Socket Mode. Generate from the Slack app's Basic Information page." | Yes, for Slack | Yes |
| `SLACK_ALLOWED_USERS` | "Comma-separated Slack member IDs permitted to interact with the bot (e.g., `U01234ABCDE,U05678FGHIJ`). **Required for the Slack gateway to function.** Leaving this blank may cause the bot to silently refuse all messages. See HANDOFF.md, Risk 7." | Yes, for Slack | No (IDs are not secret, but treat as project-private) |

The `SLACK_ALLOWED_USERS` prompt copy must explicitly call out the footgun — operators who skip it typically see a silent, non-responsive bot and assume the gateway is broken.

#### Must-not-set (deliberately excluded from template prompts)

| Variable | Why the template must not prompt for it |
|---|---|
| `HERMES_HOME` | Upstream image sets this to `/opt/data`; overriding it from Railway desyncs the container from the volume. |
| `HOME` | Same reason — overriding breaks the upstream entrypoint's assumptions about `$HOME`. |

If a future template maintainer is tempted to "expose these as optional overrides", don't — resist the urge.

---

## Service 2: `tailscale`

### Source

Railway's official Tailscale Subnet Router template. Do **not** fork or copy this into our repo — consume it as-is.

Railway maintains this template and will ship upstream fixes through it. If we maintained our own copy, we would be on the hook for tracking Tailscale version bumps and Railway-side build changes.

### Service type

Worker. (Tailscale's subnet router has no inbound ports the public internet should see; it only makes outbound connections to Tailscale's coordination servers.)

### Environment variable prompts

| Variable | Prompt copy | Required? | Secret? |
|---|---|---|---|
| `TS_AUTHKEY` | "Tailscale auth key. Generate at login.tailscale.com/admin/settings/keys. **Use a reusable key** so the node can rejoin after restarts. If you use an expiring key, the Tailscale service will drop off your tailnet when the key expires and Hermes will become unreachable." | Yes | Yes |

Any additional `TS_*` variables exposed by Railway's template (advertised routes, hostname, etc.) should be accepted as-is from the upstream template — we do not override them.

### Persistent volume

Railway's Tailscale Subnet Router template provides a small volume by default for the Tailscale node identity. Accept the default. Without this volume, the subnet router generates a new Tailscale node on every restart, which accumulates orphaned machines in the Tailscale admin console.

---

## Post-deploy manual steps (required, cannot be automated by the template)

After the template deploys both services, the engineer must complete two Tailscale-side steps before Hermes becomes reachable:

1. Approve the `fd12::/16` subnet route for the Tailscale service in the Tailscale admin console.
2. Add `fd12::10` as a custom nameserver in Tailscale's split-DNS settings.

These cannot be performed by Railway's template — they live in Tailscale. The template deploy button description and this repo's README both document them. See `docs/tailscale-setup.md` for a step-by-step walkthrough.

---

## Template rebuild checklist

If the template is lost and must be rebuilt from scratch, use this checklist:

- [ ] Create a new Railway project
- [ ] Add service 1: deploy from `echobind/rome-on-rails` on `main`, Dockerfile build, **worker type**
- [ ] Attach a volume at `/opt/data` on service 1
- [ ] Add all Hermes env-var prompts from the table above
- [ ] Verify service 1 has no public domain generated (Railway settings → Networking)
- [ ] Add service 2: deploy from Railway's Tailscale Subnet Router template, worker type
- [ ] Add the `TS_AUTHKEY` prompt on service 2
- [ ] Publish the project as a Railway template
- [ ] Copy the resulting template URL into this repo's README, replacing `TEMPLATE_ID_PLACEHOLDER` in the deploy button
- [ ] Test the deploy button end-to-end with a throwaway fork before announcing
- [ ] Update this file: change the status banner at the top from "blueprint" to "as-built reference" and record the template URL here

---

## Related docs

- `README.md` — end-user deploy instructions, post-deploy Tailscale setup, troubleshooting
- `ARCHITECTURE.md` — authoritative technical reference, including all decision rationale
- `HANDOFF.md` — known risks (especially Risk 3 — public domain, Risk 7 — `SLACK_ALLOWED_USERS`)
- `docs/tailscale-setup.md` — Tailscale-specific details beyond the README
- `docs/secrets-guide.md` — full environment variable reference
