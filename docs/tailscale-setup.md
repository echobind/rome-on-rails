# docs/tailscale-setup.md

Detailed Tailscale configuration for rome-on-rails. The [README](../README.md) covers the minimum path — generate an auth key, paste it into Railway, `tailscale ssh` in. This doc covers the reasoning, deeper configuration, and operational concerns for maintaining a fleet of agents.

**If you just want to reach your first agent, use the README.** This document is for maintainers, multi-agent setups, and debugging.

---

## Why Tailscale, and why in-container?

Hermes holds API keys and can execute terminal commands. A public login endpoint — even a well-protected one — is more exposure than Echobind wants. Slack is bidirectional but uses an outbound WebSocket (the bot initiates the connection), so Slack doesn't need inbound network access. That leaves **maintainer access for CLI operations** as the only thing we need a private access path for.

Design space considered:

| Option | Verdict |
|---|---|
| Public URL with Basic Auth | Too much public surface; one leaked password is a full breach |
| VPN (self-hosted WireGuard / OpenVPN) | We'd run and secure the VPN ourselves; key distribution is manual |
| Railway's built-in private networking only | Doesn't reach from outside Railway (can't get to it from a laptop) |
| Tailscale Subnet Router | Can't support multiple rome-on-rails agents on one tailnet — Tailscale treats multi-router same-CIDR advertisements as failover |
| Tailscale Forwarder service | Forwards TCP ports, not shells; would require us to add our own SSH server to Hermes |
| **Tailscale inside the Hermes container** | ✓ Our choice — no extra service, unique tailnet identity per agent, uses Tailscale SSH for shell access with no key management |

The container itself becomes a tailnet node. Each agent has a unique MagicDNS hostname. Maintainers use `tailscale ssh hermes@<hostname>`; authentication is via tailnet identity (what you signed in to Tailscale as), not an SSH keypair you carry around.

---

## How it works at runtime

On each container start, our `entrypoint.sh`:

1. Starts `tailscaled` in **userspace networking mode** (no TUN device, no `NET_ADMIN` capability required — works on Railway without privilege escalation)
2. Waits for the control socket to appear at `/var/run/tailscale/tailscaled.sock`
3. Derives a hostname:
   - If `TS_HOSTNAME` is set, uses that
   - Otherwise uses `${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}` (unique per project, environment)
4. Runs `tailscale up --authkey=$TS_AUTHKEY --hostname=<derived> --ssh`
5. Hands off to the upstream Hermes entrypoint, which drops to the hermes user and starts the gateway

State (machine identity, SSH host keys, Taildrop/TKA state) is persisted to `/opt/data/.tailscale/` on the Railway volume, so the agent keeps the same tailnet identity across restarts and redeploys.

---

## Setup (one-time per agent)

### 1 — Generate a reusable auth key

Go to the [Tailscale admin keys page](https://login.tailscale.com/admin/settings/keys) and generate a new auth key with:

| Option | Value | Why |
|---|---|---|
| Reusable | ✅ Enabled | The agent container can re-register after restarts and redeploys without a human regenerating a key |
| Ephemeral | ❌ Disabled | Ephemeral nodes get auto-deleted when offline; we want our agents to persist in the admin console |
| Pre-approved | ✅ Enabled — **but only if you actually see this toggle**. It only appears when your tailnet has **device approval** turned on in admin settings. If you don't see it, your tailnet doesn't require device approval and you can skip this row entirely — machines will auto-join. | Prevents the agent from sitting in "pending approval" state on first boot |
| Tags | `tag:hermes-agent` recommended | Lets Tailscale ACLs target agent nodes specifically (see ACL section below) |
| Expiration | 90 days (default) or your org's standard | Key expiration means the key can't create *new* machines; existing registered nodes keep working until their own node key expires (separate timer) |

Paste the generated key into the `TS_AUTHKEY` env var on the Hermes service in Railway.

> **Never commit the auth key.** It goes into Railway env vars only. If leaked, revoke it in Tailscale admin and generate a new one.

### 2 — Confirm the agent registers

After Railway picks up your env var change and redeploys, watch the Railway logs. You should see our entrypoint log:

```
[rome-on-rails] Starting tailscaled in userspace networking mode...
[rome-on-rails]   Bringing up Tailscale as hostname: <your-hostname>
[rome-on-rails]   Tailscale connected; SSH enabled
```

Then check the [Tailscale admin console](https://login.tailscale.com/admin/machines). A new machine should appear with the hostname you set (or the Railway-derived default). SSH should show as **enabled** for that machine.

### 3 — Reach the agent

From any device on your tailnet with Tailscale running and you signed in:

```bash
tailscale ssh hermes@<hostname>
```

You land as the `hermes` user inside the container, with `hermes` CLI on PATH.

---

## ACL guidance (multi-agent setups)

By default, all tailnet members can SSH to all tailnet-tagged machines. For a single-engineer setup this is fine. For multi-agent Echobind deployments where different engineers own different agents, you probably want an ACL like:

```json
{
  "tagOwners": {
    "tag:hermes-agent": ["group:hermes-maintainers"]
  },
  "ssh": [
    {
      "action": "accept",
      "src":    ["group:hermes-maintainers"],
      "dst":    ["tag:hermes-agent"],
      "users":  ["hermes", "root"]
    }
  ]
}
```

This says:
- Only users in `group:hermes-maintainers` can own / register machines tagged `tag:hermes-agent`
- Only those users can SSH to those machines
- They can SSH as the local user `hermes` or `root`

For this to work, each agent must register with `tag:hermes-agent`:
- Via auth key (recommended): generate the key with tag `tag:hermes-agent` in the admin UI
- Via `TS_EXTRA_ARGS=--advertise-tags=tag:hermes-agent` in Railway env vars, which gets passed through to `tailscale up`

Tune group definitions to your team. Tailscale's admin console has a policy simulator — use it before saving.

---

## Things to not do

### Do not enable Tailscale Funnel on agent nodes
[Funnel](https://tailscale.com/kb/1223/funnel) exposes a tailnet service to the public internet. That would defeat the entire point. Keep `AllowFunnel` set to `false` (default).

### Do not set `TS_EXTRA_ARGS=--advertise-exit-node`
Turning an agent into an exit node means tailnet members can route their public-internet traffic through the Hermes container. Almost never what you want; adds traffic and visibility you don't need.

### Do not share auth keys across agents
Each agent gets its own `TS_AUTHKEY`. Reasoning: rotation granularity. When an engineer leaves and keys need rotation, you want a clean "one agent per key" mapping so you know what you're rotating.

### Do not SSH as `root@<hostname>` for routine maintenance
Use `hermes@<hostname>`. The hermes user owns the volume; running `hermes config edit` as root writes files with root ownership and confuses the running gateway process.

---

## Troubleshooting

### Agent doesn't appear in Tailscale admin after deploy
- Check Railway logs — did `tailscaled` start? Is there a `Tailscale 'up' failed` warning from our entrypoint?
- Verify `TS_AUTHKEY` is set in Railway env vars and hasn't expired
- Verify the auth key is **reusable** (non-reusable keys can only register once; if used in a previous test, it's spent)

### Agent appears in admin but `tailscale ssh` from laptop says "connection refused"
- Confirm your laptop is connected to the tailnet (`tailscale status`)
- Confirm your ACL allows your user to SSH to the agent machine
- Try the fully-qualified MagicDNS name: `<hostname>.<tailnet>.ts.net`

### Agent was working yesterday, not today
In order of likelihood:
1. Did Railway redeploy and lose access? Check recent deploys in Railway dashboard
2. Did `TS_AUTHKEY` expire? Check in Tailscale admin
3. Is the agent's node key itself expired? Nodes have their own expiration (typically 180 days); check the machine's details in admin and re-authenticate if needed (you may need to revoke + redeploy)
4. Was the Tailscale ACL changed? Check the ACL version history in admin

### SSH connects but `hermes` returns command not found
- SSH as `hermes@<hostname>`, not `root@<hostname>`. If the symlink at `/usr/local/bin/hermes` was built correctly, it should work for either user. If it doesn't, the Dockerfile's symlink step failed — check Railway build logs.

### Many stale / offline machines accumulating in Tailscale admin
Each rebuild that loses state registers a new identity. Over time this accumulates in admin. Delete the offline ones periodically — they don't affect functionality, just add noise. If you're seeing a new machine on every redeploy, confirm the Railway volume is mounted at `/opt/data` (Tailscale state lives at `/opt/data/.tailscale/` and should persist across restarts).

---

## See also

- [Tailscale SSH documentation](https://tailscale.com/kb/1193/tailscale-ssh)
- [Tailscale in Docker containers](https://tailscale.com/kb/1282/docker)
- [Tailscale ACL reference](https://tailscale.com/kb/1018/acls)
- `ARCHITECTURE.md` — the full rationale for Tailscale-in-container
- `HANDOFF.md` Risk 2 — what happens when auth keys expire
- `HANDOFF.md` Risk 8 — Tailscale supply-chain dependency
