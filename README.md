# rome-on-rails

A Railway deployment template for [Hermes](https://github.com/NousResearch/hermes-agent) — the self-improving AI agent by Nous Research — built for Echobind's internal use. Private by default. Tailscale-gated. One-click deploy.

> **Security model in one sentence:** Hermes is deployed with no public internet URL. The only way to reach it is through your Tailscale tailnet. This is not a setting you have to turn on — it is the only way this template deploys.

---

## Prerequisites

Before you deploy, you need:

- A [Railway](https://railway.com) account
- A [Tailscale](https://tailscale.com) account with at least one device connected (your laptop or workstation)
- A Tailscale auth key (generated from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys))
- An API key for your chosen LLM provider (OpenRouter is the easiest starting point — free to sign up)
- Tailscale installed and running on any device you want to access Hermes from

---

## Deploy

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/TEMPLATE_ID_PLACEHOLDER)

Clicking this button will:
1. Ask you to connect your GitHub account if you haven't already
2. Clone this repo into your specified GitHub account or organization
3. Prompt you to fill in the required environment variables (see below)
4. Deploy two services into a new Railway project: Hermes and a Tailscale Subnet Router

> ⚠️ **Do not generate a public domain for the Hermes service.** The template deploys Hermes as a worker with no public URL by default. If Railway ever prompts you to generate a domain for it, decline.

---

## Required Environment Variables

These are set in Railway during and after deployment. They are never stored in this repository.

### Tailscale service

| Variable | Description |
|---|---|
| `TS_AUTHKEY` | Auth key from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys). Use a **reusable** key so the node can rejoin the tailnet after restarts. |

### Hermes service — LLM provider

Set the API key for whichever provider you want Hermes to use. OpenRouter is recommended for a first deploy because one key gives you access to 200+ models.

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | If using OpenRouter | Key from [openrouter.ai/keys](https://openrouter.ai/keys) |
| `ANTHROPIC_API_KEY` | If using Anthropic directly | Key from the Anthropic Console |
| `OPENAI_API_KEY` | If using OpenAI directly | Key from the OpenAI dashboard |
| `HERMES_INFERENCE_PROVIDER` | Optional | Explicitly selects the provider (e.g., `openrouter`, `anthropic`, `openai`). Defaults to `auto`, which picks based on which key(s) are present. |

The specific model to use is set from the Hermes dashboard after first boot, **not** via an env var. Hermes writes your choice to `config.yaml` in the persistent volume.

### Hermes service — Slack gateway (required for Slack use)

| Variable | Description |
|---|---|
| `SLACK_BOT_TOKEN` | Bot token, format `xoxb-...` |
| `SLACK_APP_TOKEN` | App-level token for Socket Mode, format `xapp-...` |

If both are absent the container still starts, but the Slack integration will not connect and `entrypoint.sh` will log a warning.

### Other env vars you should *not* need to set

The upstream Hermes image already sets `HERMES_HOME=/opt/data` and declares the volume at that path. **Do not set `HERMES_HOME` or `HOME` in Railway** — doing so will desync the container from the volume.

Additional optional variables (Telegram, Discord, WhatsApp tokens, custom base URLs, timeout overrides) are documented in `docs/secrets-guide.md` and in the [upstream environment variables reference](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md).

---

## Post-Deploy: Connecting to Hermes via Tailscale

After deployment, you need to approve the Tailscale subnet in your admin console before you can reach Hermes. This is a one-time step.

### Step 1 — Approve the subnet route

1. Go to the [Tailscale Machines dashboard](https://login.tailscale.com/admin/machines)
2. Find the machine named something like `rome-on-rails-production-tailscale`
3. Click the three-dot menu → **Edit route settings**
4. Enable the `fd12::/16` route
5. Click **Save**

### Step 2 — Configure split DNS (so Railway internal hostnames resolve)

1. Go to the [Tailscale DNS settings](https://login.tailscale.com/admin/dns)
2. Under **Nameservers**, click **Add Nameserver → Custom**
3. Enter `fd12::10` as the nameserver
4. Click **Save**

### Step 3 — Access Hermes

With Tailscale running on your device, open your browser and navigate to:

```
http://hermes.railway.internal:9119
```

You should see the Hermes dashboard. If you cannot reach it, see the troubleshooting section below.

> **Note:** This URL only works when Tailscale is running on your device and you are connected to your tailnet. It is not accessible from the public internet regardless of network conditions.

---

## Updating Hermes

Hermes is pinned to a specific version in the `Dockerfile`. It will not auto-update.

To upgrade:
1. Check the [Hermes releases page](https://github.com/NousResearch/hermes-agent/releases) and review the changelog
2. Update the version number in your repo's `Dockerfile`
3. Push the change — Railway will automatically redeploy

Do not run `hermes update` inside the container. That command upgrades Hermes unconditionally and bypasses the pinned version.

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
| `Dockerfile` | Public | No secrets — only the pinned version |
| `entrypoint.sh` | Public | Reads secrets from env at runtime |
| Railway environment variables | Private | Set in Railway dashboard only |
| Hermes dashboard | Private | No public URL; tailnet only |
| Volume contents | Private | Stored in Railway infrastructure |

---

## How to Avoid Accidentally Exposing Hermes

The template is designed to make accidental exposure structurally difficult, but here are the things to watch:

1. **Never generate a public Railway domain for the Hermes service.** The template deploys it as a worker, but if you change the service type to "web" in Railway settings, Railway will assign it a public URL.
2. **Never commit API keys or bot tokens.** All secrets live in Railway environment variables. The `.gitignore` in this repo blocks common secret file patterns, but always double-check before pushing.
3. **Don't enable Tailscale Funnel.** Funnel is a Tailscale feature that exposes a tailnet service to the public internet. Keep `AllowFunnel` set to `false` (the default in this template).
4. **Review the Tailscale ACL before adding team members.** Your Tailscale ACL controls who on your tailnet can reach which services. Ensure only authorized engineers have access to the Railway subnet.

---

## Troubleshooting

**Can't reach `hermes.railway.internal:9119`**
- Confirm Tailscale is running on your device
- Confirm you approved the `fd12::/16` subnet route in the Tailscale admin console
- Confirm the Tailscale Subnet Router service in Railway shows as deployed and healthy
- Confirm the split DNS nameserver (`fd12::10`) is configured in Tailscale DNS settings

**Hermes service crashes on startup**
- Check the Railway service logs for the Hermes service
- Confirm all required environment variables are set
- Check that the volume is mounted at `/data`

**Tailscale service shows as "needs approval"**
- Go to Tailscale Machines dashboard and approve the subnet route as described in Step 1 above

---

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for a detailed breakdown of how the components connect, where data lives, and the reasoning behind key decisions.

---

## Handoff Notes

See [HANDOFF.md](./HANDOFF.md) for a summary of known risks and recommendations for future maintainers.

---

*Built and maintained by Echobind. Hermes is developed by [Nous Research](https://nousresearch.com) under the MIT license.*
