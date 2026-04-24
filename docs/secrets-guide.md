# docs/secrets-guide.md

Complete reference for environment variables in rome-on-rails. The [README](../README.md) covers what you need at first deploy; this document covers everything else — optional variables, rotation guidance, common mistakes, and pointers into the upstream Hermes reference.

---

## Where secrets live

| Location | What lives there | Why |
|---|---|---|
| Railway environment variables | All API keys, bot tokens, auth keys | Injected into the container at runtime; never written to the volume, never in the repo |
| `/opt/data/config.yaml` on the volume | Non-secret Hermes configuration (which model, which tools, which platforms enabled) | Written by Hermes itself on first boot; survives redeploys |
| `/opt/data/.tailscale/` on the volume | Tailscale machine identity (node key, SSH host keys) | Written by tailscaled; survives redeploys. Not strictly a "secret" but compromise would let an attacker impersonate the agent on your tailnet — revoke the machine in Tailscale admin if the volume is ever exposed. |
| The git repo | Nothing secret. Ever. | Public repository; required for the Railway deploy button |

**Rule:** if you can regenerate it from an external system (API key dashboard, Tailscale admin, Slack app config), it belongs in Railway env vars. If it is configuration state that is expensive to re-derive (sessions, memory, skills, tailnet identity), it belongs in the volume.

---

## Variables (the Hermes service is the only service)

### Tailscale (maintainer access)

| Variable | Required | Description |
|---|---|---|
| `TS_AUTHKEY` | Yes (for maintainer access) | Reusable Tailscale auth key from [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys). Without this, the agent won't register with your tailnet and you can't `tailscale ssh` in. Slack still works — it's independent of Tailscale. See `docs/tailscale-setup.md` for full key guidance. |
| `TS_HOSTNAME` | No | Tailnet hostname for this agent. Defaults to `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}` so each (project, environment) gets a unique name in multi-agent setups. |
| `TS_EXTRA_ARGS` | No | Additional flags passed verbatim to `tailscale up`. Example: `--advertise-tags=tag:hermes-agent` for ACL tagging. Do not include `--authkey`, `--hostname`, or `--ssh` here — the entrypoint sets those. |

### LLM provider

At least one provider key must be set. Hermes's `HERMES_INFERENCE_PROVIDER` defaults to `auto`, which picks a provider based on which key is present.

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | If using OpenRouter | Key from [openrouter.ai/keys](https://openrouter.ai/keys). Recommended for first deploy — one key gives access to 200+ models across providers. |
| `ANTHROPIC_API_KEY` | If using Anthropic directly | Key from the Anthropic Console. Use for direct Claude access without OpenRouter in the middle. |
| `OPENAI_API_KEY` | If using OpenAI directly | Key from the OpenAI dashboard. |
| `GOOGLE_API_KEY` | If using Google Gemini directly | Key from Google AI Studio. |
| `HERMES_INFERENCE_PROVIDER` | No (defaults to `auto`) | Explicit provider selection. Values: `openrouter`, `anthropic`, `openai`, `google`. Set this if you have multiple keys set and want to force a specific provider. |

**Note on model selection:** Which model Hermes uses (e.g., `claude-opus-4-7`, `gpt-4o`) is **not** an env var. It's configured inside the container via `hermes model` or `hermes config edit`, accessed over `tailscale ssh`. Hermes writes the chosen model to `/opt/data/config.yaml` on the volume, where it survives redeploys. The env var controls which *provider* Hermes calls; the config file controls which *model* at that provider.

### Slack gateway

| Variable | Required | Description |
|---|---|---|
| `SLACK_BOT_TOKEN` | Yes, for Slack | Bot token in the format `xoxb-...`. Generated from the Slack app's OAuth & Permissions page after installing the app to your workspace. |
| `SLACK_APP_TOKEN` | Yes, for Slack | App-level token in the format `xapp-...`. Generated from the Slack app's Basic Information page. Socket Mode (which Hermes uses) requires this. |
| `SLACK_ALLOWED_USERS` | **Yes, for Slack to function** | Comma-separated Slack member IDs, e.g., `U01234ABCDE,U05678FGHIJ`. This is the **only** per-user allowlist for the Slack gateway. If the bot appears online but does not respond to messages, this variable is the most likely cause. See `HANDOFF.md` Risk 7. |
| `SLACK_HOME_CHANNEL` | No | Channel ID where the agent delivers cron jobs and proactive notifications. Leave unset if you don't use Hermes's proactive features. |
| `SLACK_HOME_CHANNEL_NAME` | No | Human-readable channel name used by Hermes internally. Cosmetic; only set alongside `SLACK_HOME_CHANNEL`. |

**Getting a Slack member ID:** in Slack, click a user's profile → three-dot menu → "Copy member ID". The format is `U` followed by 10 alphanumeric characters. Member IDs are stable; they don't change if the user renames themselves.

**Bot display name:** The bot's name and icon in Slack come from the Slack app's configuration, not from any env var here. If you want multiple agents with different names in the same Slack workspace, create a Slack app per agent (separate name, icon, and tokens).

### Other gateways (optional)

Hermes supports several messaging platforms beyond Slack. Echobind's v1 deployment uses Slack only, so these are listed for completeness rather than tested. Verify syntax against the upstream docs before relying on them.

| Variable family | Platform | Reference |
|---|---|---|
| `TELEGRAM_*` | Telegram bot integration | Upstream env vars doc |
| `DISCORD_*` | Discord bot integration | Upstream env vars doc |
| `WHATSAPP_*` | WhatsApp integration | Upstream env vars doc |
| `SIGNAL_*` | Signal integration | Upstream env vars doc |

See the [upstream environment variables reference](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md) for the authoritative list. Each platform typically needs a bot token plus a per-user allowlist analogous to `SLACK_ALLOWED_USERS`.

### Advanced / rarely needed

These are exposed by upstream Hermes and rarely need adjustment.

| Variable | Purpose | When to set |
|---|---|---|
| `HERMES_INFERENCE_TIMEOUT` | Override the default LLM-call timeout | If you're using slow reasoning models and hitting timeouts |
| `HERMES_BASE_URL` | Override the base URL for the default provider | Rare — mostly for proxies / self-hosted LLM endpoints |
| Various `*_BASE_URL` overrides | Redirect a specific provider's requests | Same as above |

For the full authoritative list, check the [upstream reference](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md) — it is updated with each Hermes release.

---

## Variables you should **NOT** set

| Variable | Why not |
|---|---|
| `HERMES_HOME` | Upstream sets this to `/opt/data`. Overriding desyncs the container from the mounted Railway volume — the agent reads/writes in one place while the volume is mounted in another. |
| `HOME` | Same reason — the upstream entrypoint uses `$HOME` in several places. Overriding from Railway can put Hermes state outside the volume, making it vanish on redeploy. |
| `HERMES_VERSION` | Set automatically by the `Dockerfile` `ARG` → `ENV`. Setting it at runtime doesn't change the installed version; it just makes the startup banner lie. |
| `GATEWAY_ALLOW_ALL_USERS` | Disables every per-platform allowlist at once (Slack, Telegram, Discord, etc.) and turns the agent into an open-access bot. Hermes surfaces this as the "enable open access" escape hatch in a startup warning, but setting it directly contradicts the access-control model in `ARCHITECTURE.md` and `HANDOFF.md` Risk 7. If you are tempted to set this because the bot is not responding, the correct fix is almost certainly to add specific user IDs to `SLACK_ALLOWED_USERS`. Verified to exist on pinned version v2026.4.16 during the 2026-04-23 smoke test. |
| `PORT` | Railway auto-sets this to `8080` for every container. It's harmless (nothing in rome-on-rails listens on any port), but setting a different value here would be a no-op. If you're tempted to set it because of some diagnostic output, don't — we don't use it. |

If you find yourself wanting to override one of these, the right answer is almost always to change the `Dockerfile` or the volume mount path, not to add a Railway env var.

---

## Rotation

### Who rotates what, and when

| Secret | Rotate on | Notes |
|---|---|---|
| `TS_AUTHKEY` | Key expiration (Tailscale default is 90 days), engineer offboarding, suspected leak | Reusable keys don't need rotation just because a node restarted — only at expiration or compromise. |
| `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` | App compromise, team member who had admin access to the Slack app leaves | Rotated via the Slack app's admin UI. |
| LLM provider keys | Suspected leak, engineer offboarding if the engineer had Railway access to this project | Most providers (OpenRouter, Anthropic, OpenAI) let you revoke and replace a key without downtime. |
| `SLACK_ALLOWED_USERS` | Every time team membership changes | Not a secret, but this is the access-control surface. Treat updates as a standard onboarding/offboarding step. |

### Rotation procedure (generic)

1. Generate the new value in the upstream system (Tailscale admin, Slack app, OpenRouter dashboard, etc.)
2. Update the env var in Railway
3. Railway triggers a redeploy of the service
4. Verify the service is healthy (check logs + `tailscale ssh` if this was a Tailscale rotation)
5. Revoke the old credential in the upstream system

Do step 5 *after* verifying step 4 — otherwise a malformed new credential locks you out.

---

## Common mistakes

### Mistake: leaving `SLACK_ALLOWED_USERS` blank
The Slack bot appears online but doesn't respond. Looks broken; is actually a missing allowlist. See `HANDOFF.md` Risk 7.

### Mistake: setting `HERMES_HOME` or `HOME` "to be explicit"
Breaks the volume layout. See "Variables you should NOT set" above.

### Mistake: committing an `.env` file with real values
The repo's `.gitignore` blocks common `.env` patterns, but always double-check `git status` before `git add -A`. If a secret lands in the repo history, consider it leaked — rotate immediately.

### Mistake: using an expiring (non-reusable) Tailscale auth key
The container can't re-register with the tailnet after the key expires. `tailscale ssh` access breaks at the next container restart. Slack keeps working. Fix: generate a new reusable key, update `TS_AUTHKEY` in Railway, redeploy. See `HANDOFF.md` Risk 2.

### Mistake: assuming Railway env vars are encrypted in a way that protects them from teammates
Anyone with Railway project access can view every env var in the dashboard. Limit project membership to engineers who need it. See `HANDOFF.md` Risk 5.

### Mistake: setting `TS_AUTHKEY` in `TS_EXTRA_ARGS`
The entrypoint already passes `--authkey=$TS_AUTHKEY` to `tailscale up`. Setting it again in `TS_EXTRA_ARGS` causes a duplicate-flag error. `TS_EXTRA_ARGS` is for *additional* flags — things like `--advertise-tags=...`.

---

## See also

- `README.md` — minimum env vars to deploy
- `ARCHITECTURE.md` — Secrets Management section, Access Control section, Decision Log entries
- `docs/tailscale-setup.md` — full Tailscale operational guide
- `HANDOFF.md` — Risks 2, 5, 7, 8 all touch on secrets / access control
- [Upstream Hermes environment variables reference](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
