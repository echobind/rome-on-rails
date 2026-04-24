#!/usr/bin/env bash
#
# rome-on-rails entrypoint — Railway wrapper around Hermes + Tailscale.
#
# This container runs two long-lived processes:
#   1. tailscaled  — Tailscale daemon in userspace-networking mode; enables
#                    `tailscale ssh` for maintainer access to this agent.
#   2. hermes      — started via the upstream entrypoint; connects outbound
#                    to Slack via Socket Mode.
#
# Startup sequence (we run as root throughout this script):
#   1. Log banner and check required env vars (warn, don't fail, for most)
#   2. Start tailscaled in the background, then `tailscale up` with TS_AUTHKEY
#   3. Exec into the upstream Hermes entrypoint, which will:
#        - chown /opt/data to the hermes user (UID 10000)
#        - drop privileges via gosu
#        - bootstrap config and skills
#        - start `hermes gateway run`
#
# Supervision model:
#   - tailscaled is a background process. If it dies, Hermes keeps running
#     (Slack continues via outbound Socket Mode) but `tailscale ssh` access
#     is lost until the next container restart. The Tailscale admin console
#     showing the machine offline is the signal to investigate.
#   - If Hermes dies, the container exits, Railway restarts it, and
#     tailscaled comes back up with the persisted machine identity from
#     /opt/data/.tailscale/.

set -e

UPSTREAM_ENTRYPOINT="/opt/hermes/docker/entrypoint.sh"
HERMES_HOME_DEFAULT="/opt/data"
TS_STATE_DIR="${HERMES_HOME:-$HERMES_HOME_DEFAULT}/.tailscale"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"

log()  { echo "[rome-on-rails] $*"; }
warn() { echo "[rome-on-rails][warn] $*" >&2; }

log "Starting Hermes on Railway"
log "  Image version:  ${HERMES_VERSION:-unknown}"
log "  HERMES_HOME:    ${HERMES_HOME:-$HERMES_HOME_DEFAULT}"
log "  Command:        $*"

# ==================================================================
# LLM provider env check
# ==================================================================
# Heuristic — provider-specific keys for less-common providers (Bedrock,
# Cohere, xAI, etc.) are still supported but not covered by this check.
if [ -z "${OPENROUTER_API_KEY:-}" ] \
  && [ -z "${ANTHROPIC_API_KEY:-}" ] \
  && [ -z "${OPENAI_API_KEY:-}" ] \
  && [ -z "${GOOGLE_API_KEY:-}" ]; then
  warn "No common LLM provider API key is set."
  warn "  Expected one of: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY."
  warn "  Hermes will fail to call the model unless a provider-specific key is set in Railway env vars."
fi

# ==================================================================
# Slack env checks — only relevant when starting the gateway
# ==================================================================
if [ "${1:-}" = "gateway" ]; then
  if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_APP_TOKEN:-}" ]; then
    warn "Starting in gateway mode but Slack tokens are incomplete."
    warn "  Need both SLACK_BOT_TOKEN (xoxb-...) and SLACK_APP_TOKEN (xapp-...) for Slack Socket Mode."
    warn "  Hermes will start but the Slack integration will not connect."
  fi
  if [ -z "${SLACK_ALLOWED_USERS:-}" ]; then
    warn "SLACK_ALLOWED_USERS is not set."
    warn "  Hermes's Slack gateway fails-closed on an unset allowlist and will deny all messages."
    warn "  Set SLACK_ALLOWED_USERS to a comma-separated list of Slack member IDs in Railway."
    warn "  See HANDOFF.md Risk 7."
  fi
fi

# ==================================================================
# Tailscale — start tailscaled, bring the node up, enable SSH
# ==================================================================
if [ -z "${TS_AUTHKEY:-}" ]; then
  warn "TS_AUTHKEY is not set."
  warn "  Tailscale will not connect. Hermes will still run (Slack works via outbound Socket Mode),"
  warn "  but maintainers will NOT be able to 'tailscale ssh' into this container."
  warn "  Set TS_AUTHKEY in Railway to a reusable Tailscale auth key to enable maintainer access."
else
  log "Starting tailscaled in userspace networking mode..."
  mkdir -p "$TS_STATE_DIR"
  mkdir -p "$(dirname "$TS_SOCKET")"

  # Userspace networking: no TUN device or NET_ADMIN capability needed — works
  # on Railway without any privilege escalation. Throughput is lower than
  # kernel-TUN mode but fine for SSH + occasional CLI traffic.
  #
  # --statedir (not --state): Tailscale needs a full state *directory* to
  # persist SSH host keys, Taildrop files, TKA state, and the main state
  # file. Passing --state=<file> only locates the state file itself and
  # sends everything else to the default /var/lib/tailscale, which doesn't
  # exist in this container — the symptom is a "SSH host keys will appear
  # as disabled" warning and SSH silently not working.
  tailscaled \
    --tun=userspace-networking \
    --socket="$TS_SOCKET" \
    --statedir="$TS_STATE_DIR" \
    &
  TAILSCALED_PID=$!

  # Wait for tailscaled's control socket to appear before running `tailscale up`.
  for _ in $(seq 1 50); do
    if [ -S "$TS_SOCKET" ]; then
      break
    fi
    sleep 0.1
  done

  # Derive the tailnet hostname (priority order):
  #   1. TS_HOSTNAME env (explicit operator choice)
  #   2. ${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME} — unique per
  #      (project, environment) for multi-agent setups
  #   3. RAILWAY_PROJECT_NAME alone
  #   4. "hermes" — if neither Railway var is available (e.g., local testing)
  if [ -n "${TS_HOSTNAME:-}" ]; then
    TAILNET_HOSTNAME="$TS_HOSTNAME"
  elif [ -n "${RAILWAY_PROJECT_NAME:-}" ] && [ -n "${RAILWAY_ENVIRONMENT_NAME:-}" ]; then
    TAILNET_HOSTNAME="${RAILWAY_PROJECT_NAME}-${RAILWAY_ENVIRONMENT_NAME}"
  elif [ -n "${RAILWAY_PROJECT_NAME:-}" ]; then
    TAILNET_HOSTNAME="${RAILWAY_PROJECT_NAME}"
  else
    TAILNET_HOSTNAME="hermes"
  fi

  log "  Bringing up Tailscale as hostname: $TAILNET_HOSTNAME"

  # --ssh:      enable Tailscale SSH (auth via tailnet identity, no keys to manage)
  # --hostname: deterministic naming for multi-agent setups
  # --authkey:  reusable auth key supplied by operator via Railway env vars
  TS_UP_ARGS=(
    --authkey="$TS_AUTHKEY"
    --hostname="$TAILNET_HOSTNAME"
    --ssh
  )
  if [ -n "${TS_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    TS_UP_ARGS+=(${TS_EXTRA_ARGS})
  fi

  if tailscale --socket="$TS_SOCKET" up "${TS_UP_ARGS[@]}"; then
    log "  Tailscale connected; SSH enabled"
  else
    warn "  Tailscale 'up' failed. Container will continue without tailnet access."
    warn "  Common causes: TS_AUTHKEY expired, revoked, or not marked reusable. See docs/tailscale-setup.md."
  fi
fi

# ==================================================================
# Propagate runtime env vars to interactive SSH sessions
# ==================================================================
# PID 1 (the gateway) sees all Railway-injected env vars. But Tailscale
# SSH spawns a minimal-env login shell via `tailscaled be-child ssh
# --login-shell=/bin/sh`, which does NOT inherit PID 1's environment.
# Without this step, `hermes status` from an SSH maintenance session
# reports API keys as unset even when the gateway is fully configured,
# and `hermes model` / `hermes config edit` can't see the provider key
# they need to configure a model.
#
# We write an /etc/profile.d/ snippet at each container start that
# re-exports the env vars we care about. Debian's /etc/profile sources
# /etc/profile.d/*.sh for login shells, so Tailscale SSH sessions pick
# these up automatically. The file lives on the container filesystem
# (not /opt/data), so it regenerates on every start from the live
# Railway env — no stale values, no secrets persisted to the volume.
log "Writing runtime env vars to /etc/profile.d/ for SSH sessions..."
PROPAGATE_VARS=(
  OPENROUTER_API_KEY
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  GOOGLE_API_KEY
  HERMES_INFERENCE_PROVIDER
  HERMES_BASE_URL
  HERMES_INFERENCE_TIMEOUT
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  SLACK_ALLOWED_USERS
  SLACK_HOME_CHANNEL
  SLACK_HOME_CHANNEL_NAME
)
{
  echo "# Generated by rome-on-rails entrypoint.sh on container start."
  echo "# Re-exports Railway env vars so Tailscale SSH sessions see the"
  echo "# same configuration the gateway process runs with."
  for var in "${PROPAGATE_VARS[@]}"; do
    if [ -n "${!var:-}" ]; then
      # printf %q produces shell-safe quoting for any value
      printf 'export %s=%q\n' "$var" "${!var}"
    fi
  done
} > /etc/profile.d/hermes-env.sh
chmod 644 /etc/profile.d/hermes-env.sh

# ==================================================================
# Hand off to upstream Hermes entrypoint
# ==================================================================
# Upstream handles: chown of /opt/data, gosu privilege drop, config/skill
# bootstrap, and exec'ing into `hermes gateway run`. After this exec, our
# script is replaced; tailscaled (a background process) is reparented to
# the new PID 1.
if [ ! -x "$UPSTREAM_ENTRYPOINT" ]; then
  warn "Upstream entrypoint not found at $UPSTREAM_ENTRYPOINT — image may have changed."
  warn "  Falling back to running 'hermes $*' directly."
  exec hermes "$@"
fi

log "Handing off to upstream Hermes entrypoint..."
exec "$UPSTREAM_ENTRYPOINT" "$@"
