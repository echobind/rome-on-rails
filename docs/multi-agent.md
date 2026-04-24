# docs/multi-agent.md

How to run multiple Hermes agents in a single Railway project — each with its own Slack app, its own tailnet hostname, and its own persistent state.

The rome-on-rails template provisions one Hermes service per Railway project. To add more agents, **duplicate the service inside Railway's UI** and override the per-agent configuration. There is no separate "multi-agent" template.

---

## When you need this

- A single client has two or more Slack workspaces, or two or more bot apps in one workspace, each needing its own Hermes agent
- An Echobind project needs distinct agents for different channels (e.g., `acme-sales`, `acme-support`) without paying for a second Railway project

If each agent is genuinely independent (different client, different LLM key, different maintainers), put them in **separate Railway projects** instead. One project = one client's fleet.

---

## Why duplication and not a multi-service template

- Railway templates fix the service count at publish time. A 3-service template is useless for a client who needs 2 or 4 agents, and publishing a different template per agent count would mean maintaining several nearly-identical templates.
- "Duplicate service" is a first-class Railway UI feature — not a workaround. It copies env vars, the Dockerfile reference, and service config; you just override the per-agent values.
- This pattern scales to any N, keeps one template to test and ship, and leaves the door open for a pre-configured multi-agent template later if usage patterns justify it.

See `ARCHITECTURE.md` for the full rationale in the Decisions Log.

---

## What's shared vs. per-agent

**Shared across every agent in the project** (set once on the first service; duplicated services inherit these correctly):

| Variable | Notes |
|---|---|
| `OPENROUTER_API_KEY` (or `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY`) | One provider key is fine for the whole project. Each agent makes its own outbound calls but they can share a key. |
| `HERMES_INFERENCE_PROVIDER` | If set explicitly, keep it the same across services unless you deliberately want different agents on different providers. |
| `TS_AUTHKEY` | Reuse the same reusable auth key across services in one project. "One key per Railway project" is our recommended rotation granularity. |

**Per-agent — must differ on each duplicated service:**

| Variable | Why it must differ | Failure mode if shared |
|---|---|---|
| `TS_HOSTNAME` | Each agent is a distinct tailnet node and needs a distinct MagicDNS name. | Tailscale admin shows two machines fighting for the same hostname; only one wins, the other is unreachable. |
| `SLACK_BOT_TOKEN` | Each agent connects to its own Slack app. | **Both containers connect to the same Slack app — every user message gets two bot responses.** See below. |
| `SLACK_APP_TOKEN` | Socket Mode token is per-Slack-app. | Same as above. |
| `SLACK_ALLOWED_USERS` | The allowlist may differ per agent (different teams, different access scopes). | Usually benign but defeats the purpose of per-agent access scoping. |
| `SLACK_HOME_CHANNEL` / `SLACK_HOME_CHANNEL_NAME` | If used, the proactive-notification channel is per-agent. | Proactive notifications land in the wrong channel. |

---

## The duplication flow

**Before you start:** have the first agent fully deployed and working. Confirm you can `tailscale ssh` into it and that it responds in its Slack workspace.

### 1. Prepare the second Slack app

Create a second Slack app (or use an existing one that isn't already wired to an agent), install it to the target workspace, and collect:
- `SLACK_BOT_TOKEN` (`xoxb-...`)
- `SLACK_APP_TOKEN` (`xapp-...`)
- The comma-separated list of Slack member IDs authorized to use this agent

If you skip this prep step, you'll have an agent that deploys without working Slack tokens, which is a recoverable but annoying state.

### 2. Duplicate the service in Railway

In the Railway dashboard:

1. Open the project
2. Click the existing `hermes` service
3. **Settings → Duplicate Service** (exact menu name varies by Railway UI version; look for a "duplicate" or "clone" action)
4. Railway creates a new service in the same project, copying the Dockerfile reference and all env vars from the original

Railway will likely begin deploying the new service automatically as soon as it's created. **Do not let it finish deploying until you've done step 3 below** — if it deploys with the copied env vars unchanged, it will connect to the first agent's Slack app using the first agent's tokens, and you will get duplicate bot responses on every message in that Slack workspace.

If Railway's UI offers "disable auto-deploy" or "pause service" on the duplicate before its first build finishes, use it. If not, proceed to step 3 immediately.

### 3. Override the per-agent env vars on the duplicate

On the newly-duplicated service, in Railway's Variables panel, change exactly these:

- `TS_HOSTNAME` — pick a unique, descriptive name (short, lowercase, dashes OK). Convention: match the Slack bot name or the workspace purpose, e.g., `acme-sales`, `acme-support`, `acme-ops`. Do **not** leave this unset — the entrypoint's auto-derive falls back to `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}`, which is identical across every service in the same project and will collide in Tailscale.
- `SLACK_BOT_TOKEN` — the `xoxb-...` from the second Slack app
- `SLACK_APP_TOKEN` — the `xapp-...` from the second Slack app
- `SLACK_ALLOWED_USERS` — the allowlist for this agent

Leave `TS_AUTHKEY`, `OPENROUTER_API_KEY` (or whichever provider key), and `HERMES_INFERENCE_PROVIDER` untouched — those are shared across the project.

### 4. Let it deploy and verify

Let Railway redeploy the duplicate with the new env vars. Within a minute:

- A new machine with your new `TS_HOSTNAME` appears in [Tailscale admin](https://login.tailscale.com/admin/machines)
- `tailscale ssh hermes@<new-hostname>` succeeds
- Inside the container, `hermes status` shows green
- The second Slack bot comes online in the target workspace

### 5. Repeat for each additional agent

Each additional agent is another duplicate from the original (or any existing one — the starting point doesn't matter as long as you override the right vars).

---

## Dashboard access in multi-agent setups

Each agent is its own tailnet node with its own MagicDNS name, reachable independently. The only coordination issue is on your laptop: only one SSH tunnel can bind `localhost:9119` at a time.

Use a different local port per agent. See [dashboard-access.md](./dashboard-access.md) for the walkthrough and suggested port convention.

---

## Volumes are per-service

Railway volumes are attached per-service, not shared. Each duplicated agent gets a fresh volume, which means each agent's:

- Tailscale machine identity (under `/opt/data/.tailscale/`) is its own — no collision, no impersonation risk
- Hermes session history, memory, skills, and `state.db` are isolated

There is no cross-agent shared state. If that's a concern for your use case, address it at the Hermes layer (shared skills repo, shared memory backend) rather than by collapsing services.

---

## Rollback / removal

To remove an agent:

1. Railway dashboard → open the service → **Settings → Delete Service**
2. Railway will also ask about the attached volume — delete it unless you want to keep the state for forensic reasons
3. In [Tailscale admin](https://login.tailscale.com/admin/machines), delete the orphaned machine entry
4. In Slack, uninstall the app from the workspace if you don't plan to reuse it

Deletion is scoped to the single service — the other agents and their volumes are unaffected.

---

## Common mistakes

### Mistake: Not overriding `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` before first deploy
Both agents connect to the same Slack app. Every message in that workspace gets two bot responses, and the bot appears to be "stuttering." Fix: override the tokens on the duplicate and redeploy. See `HANDOFF.md` for the risk entry.

### Mistake: Leaving `TS_HOSTNAME` unset on the duplicate
The entrypoint falls back to the default `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}`, which is identical on every service in the project. Tailscale admin shows two machines claiming the same hostname; only one wins (usually the most recent registrant) and the other is unreachable. Fix: set an explicit, unique `TS_HOSTNAME` on every duplicate.

### Mistake: Generating distinct `TS_AUTHKEY`s per service
Not wrong, but unnecessary. One reusable key per Railway project is the granularity we recommend — it keeps rotation simple (one key to rotate per project when an engineer leaves) without losing any security property.

### Mistake: Running different pinned Hermes versions across agents in one project
All services in a project build from the same repo, which means they share a `Dockerfile` and therefore share `HERMES_VERSION`. If you need different versions per agent, use separate Railway projects (or separate forks of this template).

---

## See also

- [dashboard-access.md](./dashboard-access.md) — ad-hoc dashboard workflow, multi-agent port conventions
- [tailscale-setup.md](./tailscale-setup.md) — Tailscale operational details, ACLs for multi-agent tenancy
- [secrets-guide.md](./secrets-guide.md) — full environment variable reference
- `railway/template-notes.md` — why the template is deliberately single-service
- `HANDOFF.md` — risks, including Slack-app crosswiring on duplicated services
