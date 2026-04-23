# docs/tailscale-setup.md

Detailed Tailscale configuration for rome-on-rails. The [README](../README.md) covers the minimum path ("do these three things to reach Hermes"). This document covers the reasoning, edge cases, and ongoing operational concerns.

**If you just want to reach Hermes for the first time, go back to the README** — it is shorter and sufficient. This document is for maintainers, for debugging, and for understanding why we configured things the way we did.

---

## Why Tailscale at all?

The core requirement for rome-on-rails is that **Hermes must not be reachable from the public internet**. Hermes holds API keys, can execute shell commands, and connects to internal systems — a public login page, even a well-protected one, is more exposure than we want.

Options for private access:

| Option | Why we didn't pick it |
|---|---|
| Public URL + basic auth | Still public. Credential stuffing, leaked password, forgotten auth config — all realistic. |
| Railway's built-in private networking only | Solves service-to-service, but not "engineer on a laptop needs to reach the dashboard." |
| VPN (WireGuard / OpenVPN self-hosted) | Works, but we'd run and secure the VPN ourselves. Key rotation and client distribution become our problem. |
| Cloudflare Zero Trust / Tailscale | Managed mesh VPN, strong identity integration, zero config on the laptop beyond installing the client. |

Tailscale wins on the operational axis — it is effectively "VPN as a service, managed by somebody else, with our identity provider as the source of truth for who can connect." Cloudflare Zero Trust is comparable; Tailscale is what Echobind already runs.

---

## How the pieces fit together

```
 ┌──────────────────┐         ┌──────────────────────────────┐
 │  Your laptop      │         │       Railway Project         │
 │  ─────────        │         │                              │
 │  Tailscale client │         │  ┌────────────────────────┐ │
 │  running,         │◄────────┼──┤ tailscale service      │ │
 │  signed in        │ mesh    │  │ (subnet router)        │ │
 │                   │         │  │                        │ │
 │                   │         │  │ advertises fd12::/16   │ │
 │                   │         │  └──────────┬─────────────┘ │
 │                   │         │             │               │
 │                   │         │             │ Railway       │
 │                   │         │             │ internal      │
 │                   │         │             ▼               │
 │                   │         │  ┌────────────────────────┐ │
 │                   │         │  │ hermes service         │ │
 │                   │         │  │ hermes.railway.internal│ │
 │                   │         │  │ :9119                   │ │
 │                   │         │  └────────────────────────┘ │
 └──────────────────┘         └──────────────────────────────┘
```

- **Your laptop runs the Tailscale client**, which gets you into Echobind's tailnet.
- **The Tailscale service in Railway runs a subnet router**, which joins the same tailnet and advertises Railway's internal IPv6 range (`fd12::/16`) as reachable routes.
- **The Hermes service in Railway** lives on the Railway internal network. It does not know or care about Tailscale — it just listens on port 9119.
- When you hit `hermes.railway.internal:9119` from your laptop, traffic goes laptop → Tailscale mesh → subnet router in Railway → Railway internal network → Hermes.

No step in that chain exposes Hermes publicly.

---

## One-time setup (after first deploy)

### 1 — Generate a reusable auth key

Go to the [Tailscale admin keys page](https://login.tailscale.com/admin/settings/keys) and generate a new auth key with these settings:

| Option | Value | Why |
|---|---|---|
| Reusable | ✅ Enabled | So the subnet router can rejoin after restarts and redeploys without a human regenerating a key |
| Ephemeral | ❌ Disabled | Ephemeral nodes are cleaned up automatically when offline — not what we want for an always-on service |
| Pre-approved | ✅ Enabled (if your tailnet uses device approval) | Otherwise you need to manually approve the Railway node on first boot |
| Tags | `tag:railway` (recommended) | Makes it possible to write Tailscale ACLs that target Railway nodes specifically |
| Expiration | 90 days (default) or your org's standard | The key expiring just means you can't *re-create* nodes with it — existing nodes keep working. But rotate on schedule. |

Paste the generated key into the `TS_AUTHKEY` environment variable on the Tailscale service in Railway.

> **Never commit the auth key to the repo.** It goes into Railway env vars only. If it leaks, revoke it immediately in the Tailscale admin and generate a new one.

### 2 — Approve the subnet route

After first deploy, the Tailscale service shows up in your [Machines dashboard](https://login.tailscale.com/admin/machines) with an "awaiting approval" badge on its advertised route.

1. Find the machine (named something like `rome-on-rails-production-tailscale`)
2. Click the three-dot menu → **Edit route settings**
3. Enable the `fd12::/16` route
4. Save

Without this step, the tailnet does not route traffic to Railway's internal network and `hermes.railway.internal` resolves but never connects.

### 3 — Configure split DNS

Railway's internal DNS (which resolves `*.railway.internal`) lives at `fd12::10` on Railway's private network. To make this reachable from your laptop:

1. Go to [Tailscale DNS settings](https://login.tailscale.com/admin/dns)
2. **Add Nameserver → Custom**
3. Enter `fd12::10`
4. Restrict it to the domain `railway.internal` (Tailscale's split-DNS feature) so it only catches Railway lookups
5. Save

Why split DNS: if you set `fd12::10` as a *global* nameserver, every DNS query from every tailnet device goes through it — unnecessary load on the subnet router and a DNS outage if Railway is flaky. Restricting it to `railway.internal` scopes the dependency.

### 4 — Verify you can reach Hermes

From a laptop with Tailscale running:

```bash
curl -v http://hermes.railway.internal:9119
```

Expected: an HTTP response (likely a redirect or login page). If you get DNS resolution failure, the split-DNS step didn't stick. If you get connection refused or timeout, the subnet route wasn't approved. See the troubleshooting section below.

---

## Access control — the Tailscale ACL

Just because something is on your tailnet does not mean every device should reach Hermes. Tailscale ACLs let you restrict who-can-reach-what. A reasonable baseline policy:

```json
{
  "acls": [
    {
      "action": "accept",
      "src":    ["group:admins"],
      "dst":    ["tag:railway:9119"]
    }
  ],
  "tagOwners": {
    "tag:railway": ["group:admins"]
  }
}
```

This says: only devices owned by users in `group:admins` can reach port 9119 on machines tagged `tag:railway`. If a non-admin's laptop joins the tailnet, they cannot reach Hermes.

Tune the group definitions to your team. Tailscale's admin console has a policy simulator — use it to test your ACL before saving.

---

## Things to not do

### Do not enable Tailscale Funnel

[Funnel](https://tailscale.com/kb/1223/funnel) is a Tailscale feature that exposes a tailnet service to the public internet via Tailscale's edge. This would defeat the entire point of rome-on-rails. Keep `AllowFunnel` set to `false` (the default).

### Do not set `TS_EXTRA_ARGS` unless you know what you're doing

Railway's Tailscale template exposes `TS_EXTRA_ARGS` for advanced configuration. Mis-setting it (e.g., adding `--advertise-exit-node`) can turn the Railway service into an exit node for your tailnet — every tailnet device routes its public-internet traffic through Railway. Almost always not what you want.

### Do not share the auth key

Reusable auth keys are powerful — anyone with the key can register a new machine as part of your tailnet. Treat the key as a credential. Rotate on offboarding.

---

## Subnet router vs. forwarder — why we picked subnet router

Tailscale has two patterns for bridging a remote network into a tailnet:

| Pattern | Scope | How it works |
|---|---|---|
| **Subnet router** (what we use) | Entire subnet (e.g., all of Railway's `fd12::/16`) | One Tailscale node advertises the whole network |
| **Forwarder** | Specific ports on specific hosts | A Tailscale node proxies individual TCP/UDP ports |

**We use subnet router because the Railway project only contains services we're comfortable exposing to the tailnet.** If a day comes when Echobind's Railway project adds a service that should *not* be tailnet-accessible (e.g., a database that should stay service-to-service only), we should migrate to the forwarder pattern, which gives finer-grained scoping.

Marker for future-you: if the Railway project grows beyond Hermes + Tailscale, revisit this choice.

---

## Troubleshooting

### `hermes.railway.internal` does not resolve on the laptop

Split DNS isn't set up. Check:
- Tailscale DNS settings has `fd12::10` as a custom nameserver for `railway.internal`
- The laptop's Tailscale client is actually connected (`tailscale status`)
- Tailscale's MagicDNS is not disabled at the tailnet level

### Resolves but times out / connection refused

Subnet route not approved. Go to the Tailscale Machines page, find the Railway node, check "Edit route settings", and enable the `fd12::/16` route.

### Was working yesterday, not working today

Check, in order:
1. Is the Tailscale auth key expired? (Admin → Keys → see expiration.) If so, the Railway service cannot reconnect on restart. Generate a new reusable key and update `TS_AUTHKEY`.
2. Did someone re-deploy the Tailscale service and get a different machine name / identity? Re-approve the subnet route.
3. Is the Hermes service healthy? (Check Railway logs.) Tailscale can be fine while Hermes is crashlooping.
4. Did anyone modify the Tailscale ACL? Check the policy simulator.

### Tailscale admin console is cluttered with old `rome-on-rails-*` machines

This happens if the Tailscale service restarted without a persistent volume — each restart registers a new node. Confirm the service has a volume attached in Railway. Manually delete the orphan machines from the admin console.

---

## See also

- [Railway's official guide: set up a Tailscale subnet router](https://docs.railway.com/guides/set-up-a-tailscale-subnet-router)
- [Tailscale subnet routers documentation](https://tailscale.com/kb/1019/subnets)
- [Tailscale ACL reference](https://tailscale.com/kb/1018/acls)
- `ARCHITECTURE.md` — how Tailscale fits into the overall rome-on-rails design
- `HANDOFF.md`, Risk 2 — what happens when the auth key expires
