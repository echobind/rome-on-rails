# rome-on-rails Dockerfile
#
# Builds on top of Nous Research's official Hermes image and adds:
#   1. Tailscale (apt-installed from pkgs.tailscale.com) so the container
#      registers as a tailnet node with Tailscale SSH enabled
#   2. Our entrypoint wrapper (entrypoint.sh) which starts tailscaled
#      before handing off to the upstream Hermes entrypoint
#
# Architecture (see ARCHITECTURE.md for full rationale):
#   - One service per Railway project — Hermes + Tailscale share a container
#   - Hermes connects outbound to Slack (Socket Mode) for end-user traffic
#   - Maintainers access the agent via `tailscale ssh <hostname>` on the tailnet
#   - No inbound ports — no public URL, no Slack inbound, no HTTP server
#
# To upgrade Hermes:
#   1. Check https://github.com/NousResearch/hermes-agent/releases and review the changelog
#   2. Update HERMES_VERSION below to the new tag
#   3. Commit, push — Railway redeploys automatically
#
# Do NOT run `hermes update` anywhere in this image — pinning is enforced by the tag.

ARG HERMES_VERSION=v2026.4.16
FROM nousresearch/hermes-agent:${HERMES_VERSION}

# Re-declare after FROM so it's available in ENV (Docker scoping rule).
ARG HERMES_VERSION
ENV HERMES_VERSION=${HERMES_VERSION}

# ==================================================================
# Install Tailscale from the official apt repo
# ==================================================================
# Base image is Debian 13 (trixie). We add Tailscale's apt source, import
# their signing key, and install the `tailscale` package which provides both
# the `tailscaled` daemon and the `tailscale` CLI, plus the Tailscale SSH
# integration. We run apt as root (base image has us there at this point);
# the upstream entrypoint drops to the hermes user later.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
      | tee /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# ==================================================================
# Make the `hermes` CLI reachable from any interactive shell
# ==================================================================
# The upstream image installs hermes inside a Python venv at
# /opt/hermes/.venv/bin/hermes. The running gateway process finds it
# because the upstream entrypoint exports the venv on PATH — but
# interactive shells (what you get when you `tailscale ssh` in for
# maintenance) don't inherit that PATH, so `hermes <cmd>` returns
# "command not found."
#
# A symlink into /usr/local/bin makes the CLI callable regardless of
# which user you SSH in as (root or hermes), and regardless of which
# shell their login uses (bash / sh / whatever).
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes

# ==================================================================
# Our entrypoint wrapper
# ==================================================================
COPY entrypoint.sh /usr/local/bin/rome-entrypoint.sh
RUN chmod +x /usr/local/bin/rome-entrypoint.sh

# ==================================================================
# Roster control sidecar
# ==================================================================
# A tiny FastAPI service (see docs/hermes-control-sidecar-contract.md) that
# lets Roster read and change this agent's LLM model over the tailnet. It runs
# on the Hermes venv's Python — FastAPI, uvicorn, and PyYAML are already
# installed there and it imports `hermes_cli.config` — so it adds no new pip
# dependencies. entrypoint.sh starts it backgrounded (as the hermes user, only
# when ROSTER_CONTROL_TOKEN is set) and exposes it on the tailnet via
# `tailscale serve`.
COPY roster-control-sidecar.py /usr/local/bin/roster-control-sidecar.py
RUN chmod +x /usr/local/bin/roster-control-sidecar.py

# No EXPOSE — this image serves no inbound connections.
#   - Slack uses outbound-only Socket Mode
#   - Tailscale SSH is reached via the tailnet, not a published port
#   - The Roster control sidecar binds 127.0.0.1 only and is reached over the
#     tailnet via `tailscale serve`, never via a published container port

ENTRYPOINT ["/usr/local/bin/rome-entrypoint.sh"]
CMD ["gateway", "run"]
