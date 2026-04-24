# docs/dashboard-access.md

How to reach the Hermes web dashboard from your laptop, ad-hoc, through the tailnet.

The dashboard is not run automatically by this template. There is no always-on HTTP server in the container, no public URL, and no persistent `tailscale serve` configuration. When you need the dashboard, you start it by hand inside an SSH session; when you disconnect, it goes away. This keeps our "no exposed surface" posture intact and requires no extra process supervision in the container.

---

## What "the dashboard" actually is

`hermes dashboard` is a separate upstream command (distinct from `hermes gateway run`, which is what the container starts as PID 1). When you run it inside the container it listens on `localhost:9119` — **not** on any tailnet address, and **not** on any externally reachable interface. Only processes inside that same container can reach it directly.

To get to it from your laptop, you tunnel your laptop's local port to the container's `localhost:9119` through the SSH session. The dashboard is reachable only while that SSH session is alive.

---

## Prerequisites

- Tailscale running on your laptop, signed in to the same tailnet as the agent
- You can already `tailscale ssh hermes@<agent-hostname>` into the agent
- An OpenSSH client on your laptop (Windows 10/11 and macOS/Linux ship with one)

---

## One-agent walkthrough

The `tailscale ssh` wrapper does **not** accept `-L` (local-forward). Use your system's OpenSSH client directly — Tailscale's SSH server authenticates any SSH client using tailnet identity, and MagicDNS still resolves the hostname as long as Tailscale is running.

**From your laptop:**

```bash
ssh -L 9119:localhost:9119 hermes@<agent-hostname>
```

If MagicDNS doesn't resolve the short hostname (varies by Tailscale DNS setup), use the fully-qualified MagicDNS name from the Tailscale admin console:

```bash
ssh -L 9119:localhost:9119 hermes@<agent-hostname>.<your-tailnet>.ts.net
```

**First-time trust-on-first-use prompt.** OpenSSH (unlike the `tailscale ssh` wrapper) doesn't know to check the host key against Tailscale's coordination server, so it asks once:

```
The authenticity of host '... (...)' can't be established.
This key is not known by any other names.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

It's safe to type `yes` here — the connection is already routed over your tailnet, so any MITM would need tailnet access to that specific host. The fingerprint gets saved to your `known_hosts` and you won't be asked again.

**Inside the container:**

```bash
hermes dashboard &
```

The `&` backgrounds the dashboard so you can run other commands in the same shell. (If you'd rather keep it in the foreground, open a second SSH session without `-L` in another terminal.)

**From your laptop browser:**

```
http://localhost:9119
```

**When you're done:**

```bash
fg           # bring the dashboard back to the foreground
Ctrl+C       # stop it
exit         # close the SSH session
```

Closing the SSH session also tears down the port forward. Nothing persists in the container.

---

## Multi-agent: one local port per agent

If you're maintaining multiple agents in the same Railway project (see [multi-agent.md](./multi-agent.md)), the collision isn't in the tailnet — each agent is its own tailnet node with its own hostname. The collision is on your laptop: only one SSH session can bind `localhost:9119` at a time.

Use a different local port per agent. The convention we suggest: start at 9119 for the first, increment by one for each additional.

| Agent | SSH command | Browse |
|---|---|---|
| `acme-sales` | `ssh -L 9119:localhost:9119 hermes@acme-sales` | `http://localhost:9119` |
| `acme-support` | `ssh -L 9120:localhost:9119 hermes@acme-support` | `http://localhost:9120` |
| `acme-ops` | `ssh -L 9121:localhost:9119 hermes@acme-ops` | `http://localhost:9121` |

Note the pattern: **the left-hand port changes per agent; the right-hand `localhost:9119` never does** (that's the port the dashboard binds to inside each container, which is the same everywhere).

Run each SSH session in its own terminal window. Browse all three dashboards in separate browser tabs. Close any window to stop reaching that agent's dashboard.

---

## Security framing

- The dashboard binds to `localhost` inside the container. It is not reachable from the tailnet directly, so other tailnet members cannot hit it unless they also SSH into the same container.
- The SSH session **is** the auth boundary. Whoever can `tailscale ssh hermes@<agent-hostname>` can get a port forward and view the dashboard for as long as they hold the session. If you need tighter controls, that's a Tailscale ACL problem, not a dashboard problem — see [tailscale-setup.md](./tailscale-setup.md).
- When the SSH session ends (explicit `exit`, laptop suspend, network drop), the port forward dies and the dashboard becomes unreachable from your laptop. The `hermes dashboard` process inside the container may keep running if you backgrounded it — stop it with `fg` + `Ctrl+C` before exiting if you want cleanup to be deterministic.

---

## Troubleshooting

### `tailscale ssh` says `flag provided but not defined: -L`
The Tailscale CLI wrapper doesn't accept `-L`. Use plain `ssh` — see the walkthrough above. This is expected behavior, not a misconfiguration.

### `ssh` can't resolve the hostname
Use the fully-qualified MagicDNS name: `<hostname>.<tailnet>.ts.net`. You can copy it from the Tailscale admin console or `tailscale status` on your laptop. If that still fails, confirm Tailscale is actually running on your laptop (`tailscale status` should list the agent machine).

### Browser shows "connection refused" on `localhost:9119`
- Is `hermes dashboard` still running inside the container? Re-run it: `hermes dashboard &`
- Is the SSH session still alive? If the terminal window is dead or says "connection closed," the tunnel is gone — reconnect.
- Did you bind the local port to a different number (multi-agent setup)? Browse the port you actually forwarded.

### "Address already in use" when starting the SSH session
Another SSH session on your laptop is already holding `localhost:9119`. Either reuse it or pick a different local port: `ssh -L 9199:localhost:9119 hermes@<host>` and browse `http://localhost:9199`.

### Dashboard keeps running in the container after I disconnect
Backgrounded processes (the `hermes dashboard &` case) keep running even if the SSH session ends. This is harmless — it only listens on `localhost:9119` so nothing external can reach it — but over time you may accumulate stale dashboard processes. To clean up: SSH back in, `pkill -f 'hermes dashboard'`.

---

## See also

- [tailscale-setup.md](./tailscale-setup.md) — Tailscale operational guide
- [multi-agent.md](./multi-agent.md) — running multiple agents in one Railway project
- Upstream [Hermes dashboard docs](https://github.com/NousResearch/hermes-agent) (check the repo for current command reference)
