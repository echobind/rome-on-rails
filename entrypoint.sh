#!/usr/bin/env bash
#
# rome-on-rails entrypoint — thin Railway-specific wrapper around Hermes.
#
# Responsibilities:
#   1. Log a clear startup banner (Railway logs are noisy; this helps humans)
#   2. Warn early on missing env vars that Hermes would otherwise fail on
#      later with a less obvious error
#   3. Hand off to the upstream Hermes entrypoint, which handles gosu
#      privilege dropping, volume permission fixes, config bootstrap, and
#      skill sync before starting the `hermes` process.
#
# This script runs as root. The upstream entrypoint drops to the hermes user.

set -e

UPSTREAM_ENTRYPOINT="/opt/hermes/docker/entrypoint.sh"

log()  { echo "[rome-on-rails] $*"; }
warn() { echo "[rome-on-rails][warn] $*" >&2; }

log "Starting Hermes on Railway"
log "  Image version: ${HERMES_VERSION:-unknown}"
log "  HERMES_HOME:   ${HERMES_HOME:-/opt/data}"
log "  Command:       $*"

# LLM provider — if no common provider key is set, Hermes will fail to call
# the model. We don't know which provider the user configured via
# HERMES_INFERENCE_PROVIDER, so we check the common ones and warn if none
# are present. (Provider-specific keys for less-common providers are still
# supported — this is a heuristic, not a hard check.)
if [ -z "${OPENROUTER_API_KEY:-}" ] \
  && [ -z "${ANTHROPIC_API_KEY:-}" ] \
  && [ -z "${OPENAI_API_KEY:-}" ] \
  && [ -z "${GOOGLE_API_KEY:-}" ]; then
  warn "No common LLM provider API key is set."
  warn "  Expected one of: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY."
  warn "  Hermes will fail to call the model unless a provider-specific key is set in Railway env vars."
fi

# Slack tokens — only warn if we're starting the gateway (not dashboard-only).
if [ "${1:-}" = "gateway" ]; then
  if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_APP_TOKEN:-}" ]; then
    warn "Starting in gateway mode but Slack tokens are incomplete."
    warn "  Need both SLACK_BOT_TOKEN (xoxb-...) and SLACK_APP_TOKEN (xapp-...) for Slack Socket Mode."
    warn "  Hermes will start but the Slack integration will not connect."
  fi
fi

if [ ! -x "$UPSTREAM_ENTRYPOINT" ]; then
  warn "Upstream entrypoint not found at $UPSTREAM_ENTRYPOINT — this image may have changed."
  warn "  Falling back to running 'hermes $*' directly."
  exec hermes "$@"
fi

log "Handing off to upstream Hermes entrypoint..."
exec "$UPSTREAM_ENTRYPOINT" "$@"
