# Railway Template Configuration Notes

## Last updated: 2026-04-22

The Railway template configuration (service definitions, volume mounts, env var prompts) lives inside Railway's platform and cannot be stored in this repository. This file documents everything that is configured there so the template can be recreated if needed.

---

## Template Overview

**Template name:** rome-on-rails  
**Published by:** Echobind  
**Visibility:** Public (required for deploy button to work)  
**Services:** 2 (Hermes, Tailscale)

---

## Service 1: Hermes

**Source:** This repository (`echobind/rome-on-rails`), cloned into the deploying user's GitHub account  
**Build:** Dockerfile at repo root  
**Service type:** Worker (no public domain)  
**Start command:** Defined in Dockerfile `CMD`

### Volume

| Mount path | Size |
|---|---|
| `/data` | 5 GB (adjust as needed; sessions and memory grow over time) |

### Environment Variables (as configured in Railway template UI)

| Name | Required | Default | Description shown to user |
|---|---|---|---|
| `HERMES_HOME` | Yes | `/data/.hermes` | Where Hermes stores its state. Do not change this. |
| `HOME` | Yes | `/data` | Required for Hermes path resolution. Do not change this. |
| `LLM_PROVIDER_API_KEY` | Yes | _(none)_ | API key for your LLM provider (OpenRouter, Anthropic, OpenAI, etc.) |
| `LLM_MODEL` | Yes | _(none)_ | Model identifier, e.g. `openai/gpt-4o` for OpenRouter or `claude-opus-4-6` for Anthropic |
| `SLACK_BOT_TOKEN` | No | _(none)_ | Slack bot token — only needed if using Hermes with Slack |
| `SLACK_APP_TOKEN` | No | _(none)_ | Slack app token — only needed if using Hermes with Slack |
| `TELEGRAM_BOT_TOKEN` | No | _(none)_ | Telegram bot token — only needed if using Hermes with Telegram |

> ℹ️ Additional messaging platform tokens can be added after deployment through Railway's environment variable settings.

---

## Service 2: Tailscale Subnet Router

**Source:** Railway's official Tailscale Subnet Router template  
**Service type:** Worker

### Volume

| Mount path | Notes |
|---|---|
| `/var/lib/tailscale` | Persists Tailscale node identity across restarts. Without this, the node creates a new identity every restart. |

### Environment Variables

| Name | Required | Default | Description shown to user |
|---|---|---|---|
| `TS_AUTHKEY` | Yes | _(none)_ | Tailscale auth key. Generate a **reusable** key at login.tailscale.com/admin/settings/keys |

---

## Steps to Recreate This Template in Railway

If the template is ever lost or needs to be rebuilt from scratch:

1. Go to railway.com → Your workspace → Templates → New Template
2. Add Service 1 (Hermes):
   - Source: GitHub repo (`echobind/rome-on-rails`)
   - Set service type to Worker (disable public networking)
   - Add volume at `/data`
   - Add all environment variables listed above with their descriptions
3. Add Service 2 (Tailscale):
   - Use Railway's existing Tailscale Subnet Router template as the source
   - Add volume at `/var/lib/tailscale`
   - Add `TS_AUTHKEY` variable
4. Publish the template
5. Copy the template URL and update the deploy button in README.md

---

## Deploy Button Markdown

Once the template is published, replace `TEMPLATE_ID_PLACEHOLDER` in README.md with the actual template ID:

```markdown
[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/YOUR_TEMPLATE_ID)
```
