# CLAUDE.md — rome-on-rails

## What This Project Is

rome-on-rails is a Railway deployment template for Hermes (NousResearch/hermes-agent), an AI agent tool. The goal is a one-click Railway deploy that results in a private, Tailscale-only Hermes instance — Hermes is never exposed to the public internet.

**Naming:** `rome-on-rails` = this repo and project. `Hermes` = the third-party agent being deployed. Do not conflate them.

## Developer Context

- Early-career developer transitioning from electrical engineering
- Proficient in Node.js, TypeScript, PostgreSQL, REST APIs, and webhooks
- Limited experience with Linux server administration, Docker, Tailscale, and Railway
- Working in VSCode on Windows with a WSL2 terminal
- Prefers clean, readable code over clever solutions
- Expects explanations of unfamiliar concepts — don't just issue commands

## Core Rules

**Before every decision involving a tradeoff:**
1. Explain the options
2. State which is best and why
3. Then implement

**Before recommending any library, package, or tool:** web-search to confirm it is actively maintained and compatible with current versions.

**When debugging:** ask for the error message and relevant code before suggesting fixes. Do not guess.

**Never:**
- Commit secrets or API keys
- Generate a public Railway domain for the Hermes service
- Run `hermes update` in any script (this bypasses version pinning)
- Add unrelated features — scope is defined in the project description

## Living Documents — Always Update

These three files are required deliverables. Update them as part of every response that makes a decision or changes the architecture. Do not wait to be asked.

| File | What changes trigger an update |
|---|---|
| `ARCHITECTURE.md` | Any structural decision, new component, or change to data flow |
| `README.md` | Any change to setup steps, env vars, or security model |
| `HANDOFF.md` | Any new risk identified, decision rationale worth preserving |

## Project Structure

```
rome-on-rails/
├── CLAUDE.md              ← this file
├── README.md              ← setup and security guide
├── ARCHITECTURE.md        ← authoritative technical reference
├── HANDOFF.md             ← risks and maintainer notes
├── Dockerfile             ← builds the Hermes container; pins version
├── entrypoint.sh          ← startup script; reads env vars, starts gateway
├── railway/
│   └── template-notes.md  ← documents Railway UI config (can't be in-repo)
└── docs/
    ├── tailscale-setup.md
    └── secrets-guide.md
```

## Key Technical Decisions (do not revisit without good reason)

- **Two Railway services:** Hermes (worker, no public domain) + Tailscale (subnet router)
- **Access pattern:** Tailscale subnet router bridges tailnet to Railway private network
- **Version pinning:** `pip install "hermes-agent==<version>"` in Dockerfile
- **Secrets:** Railway environment variables only — never in the volume or repo
- **No public URL:** Hermes deployed as worker type; Railway never assigns it a domain

Full rationale in `ARCHITECTURE.md`.

## Commands

None yet — will be added when Dockerfile and entrypoint.sh exist and are testable.
