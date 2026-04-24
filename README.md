# rome-on-rails

A Railway deployment template for [Hermes](https://github.com/NousResearch/hermes-agent) — the self-improving AI agent by Nous Research — built for Echobind's internal use. Private by default. Tailscale-gated. One-click deploy.

> **Security model in one sentence:** Each Hermes deployment is itself a Tailscale node with SSH enabled but no public URL. For maintenance, reach it via `tailscale ssh` from any device on your tailnet. For end users, it shows up in Slack — outbound-initiated Socket Mode, no inbound ports.

---

## Prerequisites

Before you deploy, you need:

- A [Railway](https://railway.com) account
- A [Tailscale](https://tailscale.com) account with at least one device connected (your laptop or workstation)
- A **reusable** Tailscale auth key (from [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys))
- An API key for your chosen LLM provider (OpenRouter is the easiest starting point)
- A Slack app installed to your workspace (see `docs/secrets-guide.md` for what tokens you'll need)
- Tailscale installed and running on any device you want to maintain the agent from

---

## Deploy

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/TEMPLATE_ID_PLACEHOLDER)

Clicking this button will:
1. Ask you to connect your GitHub account if you haven't already
2. Clone this repo into your specified GitHub account or organization
3. Prompt you to fill in the required environment variables (see below)
4. Deploy a single Hermes service into a new Railway project

> ⚠️ **Do not generate a public domain for the service.** The template deploys Hermes as a worker with no public URL. Hermes doesn't listen on any inbound port; adding a domain today is a no-op, but preserving that property protects you against future Dockerfile changes accidentally exposing surface.

---

## Required Environment Variables

These are set in Railway during and after deployment. They are never stored in this repository.

### Tailscale (required for maintainer access)

| Variable | Required | Description |
|---|---|---|
| `TS_AUTHKEY` | Yes | Reusable Tailscale auth key from [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys). Without this, the container can't register with your tailnet and you won't be able to SSH in. Slack will still work. |
| `TS_HOSTNAME` | No | Custom tailnet hostname. Defaults to `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}` — unique per (project, environment) for multi-agent setups. |
| `TS_EXTRA_ARGS` | No | Extra flags passed verbatim to `tailscale up` (e.g., `--advertise-tags=tag:hermes-agent` if you use ACL tags). Do not include `--authkey`, `--hostname`, or `--ssh` — the entrypoint sets those. |

### LLM provider (at least one required)

Set the API key for whichever provider you want Hermes to use. OpenRouter is recommended for a first deploy — one key gives access to 200+ models.

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | If using OpenRouter | Key from [openrouter.ai/keys](https://openrouter.ai/keys) |
| `ANTHROPIC_API_KEY` | If using Anthropic directly | Key from the Anthropic Console |
| `OPENAI_API_KEY` | If using OpenAI directly | Key from the OpenAI dashboard |
| `GOOGLE_API_KEY` | If using Google Gemini directly | Key from Google AI Studio |
| `HERMES_INFERENCE_PROVIDER` | Optional | Explicitly selects the provider (`openrouter`, `anthropic`, `openai`, `google`). Defaults to `auto`. |

The specific model to use is set from inside the container after first boot, via `tailscale ssh hermes@<hostname>` → `hermes model` (or `hermes config edit`). Hermes writes your choice to `/opt/data/config.yaml` on the persistent volume.

### Slack gateway (required for Slack)

| Variable | Required | Description |
|---|---|---|
| `SLACK_BOT_TOKEN` | Yes, for Slack | Bot token, format `xoxb-...` |
| `SLACK_APP_TOKEN` | Yes, for Slack | App-level token for Socket Mode, format `xapp-...` |
| `SLACK_ALLOWED_USERS` | **Yes, for Slack to function** | Comma-separated Slack member IDs, e.g., `U01234ABCDE,U05678FGHIJ`. If unset, the Hermes gateway denies all messages and the bot appears online but silent. See `HANDOFF.md` Risk 7. |

If Slack tokens are absent, the container still starts (Slack just doesn't connect) and the entrypoint logs a warning. If `SLACK_ALLOWED_USERS` is absent, Hermes itself emits a warning and rejects all messages — the bot appears online but unresponsive.

### Other env vars you should *not* need to set

The upstream Hermes image already sets `HERMES_HOME=/opt/data` and declares the volume at that path. **Do not set `HERMES_HOME`, `HOME`, or `GATEWAY_ALLOW_ALL_USERS`** — see `docs/secrets-guide.md` for details on why.

Additional optional variables (Telegram, Discord, WhatsApp tokens, custom base URLs, timeout overrides) are documented in `docs/secrets-guide.md` and in the [upstream environment variables reference](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md).

---

## Post-Deploy: Connecting to your agent

After the deploy succeeds, the container boots, `tailscaled` starts, and the agent registers with your tailnet. Within a minute, you should see a new machine in your [Tailscale admin console](https://login.tailscale.com/admin/machines) named `<project-name>-<environment-name>` (or whatever you set `TS_HOSTNAME` to).

From any device on your tailnet with Tailscale running:

```bash
tailscale ssh hermes@<agent-hostname>
```

You're inside the container as the `hermes` user. Try:

```bash
hermes status      # overall state
hermes model       # configure which LLM model to use
hermes config      # view / edit configuration
hermes skills      # list installed skills
hermes logs        # tail gateway logs
```

> **Tip:** Always SSH as `hermes@...` rather than `root@...`. The hermes user's environment owns the files Hermes manages; running CLI commands as root writes files with root ownership and confuses the gateway process later.

That's it — no subnet route approval, no split DNS configuration, no port forwarding. Tailscale SSH authenticates you by your tailnet identity; no keys to manage.

See [docs/tailscale-setup.md](./docs/tailscale-setup.md) for deeper Tailscale topics (ACLs, hostname customization, troubleshooting).

---

## Updating Hermes

Hermes is pinned to a specific version in the `Dockerfile`. It will not auto-update.

To upgrade:
1. Check the [Hermes releases page](https://github.com/NousResearch/hermes-agent/releases) and review the changelog for breaking changes
2. Update the `HERMES_VERSION` value in your repo's `Dockerfile`
3. Push the change — Railway will automatically redeploy
4. After redeploy, SSH in and verify — particularly that Slack still behaves correctly under the same `SLACK_ALLOWED_USERS` (Hermes has been known to change allowlist behavior between versions)

Do not run `hermes update` inside the container. That command upgrades Hermes unconditionally and bypasses the pinned version.

---

## Multi-Agent: running several Hermes instances on one tailnet

The whole point of the single-service-per-project architecture is that you can deploy rome-on-rails multiple times on the same tailnet without conflicts. Each deployment:

- Is its own Railway project
- Has its own Tailscale auth key (set per project in Railway env vars)
- Registers as a separate tailnet node with a unique hostname (derived from the Railway project name, or set via `TS_HOSTNAME`)
- Has its own Slack app and tokens — the bot's display name in Slack comes from the Slack app's config, not from any rome-on-rails setting

So "Agent A" and "Agent B" can coexist on the same tailnet and in the same Slack workspace, with zero shared config between them.

---

## Keeping Up With Template Changes

Because you deployed this template into your own repo, your copy is independent of `echobind/rome-on-rails`. To pull in future improvements:

```bash
git remote add upstream https://github.com/echobind/rome-on-rails.git
git fetch upstream
git merge upstream/main
```

Review any changes before merging — particularly changes to the `Dockerfile` (version bumps) and `entrypoint.sh`.

---

## What Is Public vs. Private

| Item | Visibility | Notes |
|---|---|---|
| This repository | Public | Required for Railway deploy button |
| `Dockerfile` | Public | No secrets — only the pinned Hermes version |
| `entrypoint.sh` | Public | Reads secrets from env at runtime |
| Railway environment variables | Private | Set in Railway dashboard only |
| The Hermes container itself | Private | No public URL; only reachable via `tailscale ssh` or outbound Slack WebSocket |
| Volume contents | Private | Stored in Railway infrastructure |

---

## How to Avoid Accidentally Exposing Hermes

The template is designed to make accidental exposure structurally difficult, but here are the things to watch:

1. **Never generate a public Railway domain for the service.** The Dockerfile has no `EXPOSE` directive, so generating a domain today is a no-op. Don't rely on that — adding an HTTP server in the future would change the equation.
2. **Never commit API keys or bot tokens.** All secrets live in Railway environment variables. The `.gitignore` in this repo blocks common secret file patterns, but always double-check before pushing.
3. **Don't enable Tailscale Funnel** on your agent's tailnet node. Funnel is a Tailscale feature that exposes a tailnet service to the public internet. This template deploys without Funnel and you should keep it that way.
4. **Review the Tailscale ACL before adding team members.** Your Tailscale ACL controls who on your tailnet can `tailscale ssh` where. Ensure only authorized engineers can reach agent nodes.
5. **Don't set `GATEWAY_ALLOW_ALL_USERS=true`.** This Hermes env var disables all per-platform allowlists and turns the bot into open-access. See `docs/secrets-guide.md` and `HANDOFF.md` Risk 7.

---

## Troubleshooting

**Deploy completes but the agent doesn't appear in Tailscale admin**
- Check the Railway service logs — is `TS_AUTHKEY` set? If the entrypoint prints `TS_AUTHKEY is not set`, you forgot to add it
- Check the tailscaled logs in Railway output for auth errors (expired key, revoked key, non-reusable key already consumed)

**`tailscale ssh hermes@<hostname>` says "connection refused" or "no such host"**
- Confirm Tailscale is running on your laptop (`tailscale status`)
- Confirm the machine shows up in the [admin console](https://login.tailscale.com/admin/machines)
- Check that your Tailscale ACL allows you to reach it
- Try the fully-qualified MagicDNS name: `<hostname>.<tailnet-name>.ts.net`

**Bot is online in Slack but doesn't respond to messages**
- Most likely cause: `SLACK_ALLOWED_USERS` is missing or doesn't contain your Slack member ID. See `HANDOFF.md` Risk 7.

**`hermes` command not found from an SSH session**
- SSH as `hermes@<hostname>`, not `root@<hostname>` — though the symlink at `/usr/local/bin/hermes` should make it work for either. If you SSHed as hermes and still see this, the Dockerfile's symlink step failed during build — check the Railway build logs.

**Service crashes on startup with a volume-related error**
- Check `HERMES_HOME` and `HOME` env vars — they should NOT be set in Railway. If either is set, remove them and redeploy.

---

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for a detailed breakdown of how the components connect, where data lives, and the reasoning behind key decisions.

---

## Handoff Notes

See [HANDOFF.md](./HANDOFF.md) for a summary of known risks and recommendations for future maintainers.

---

*Built and maintained by Echobind. Hermes is developed by [Nous Research](https://nousresearch.com) under the MIT license.*
