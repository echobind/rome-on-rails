# rome-on-rails — Railway deployment wrapper for Hermes (NousResearch/hermes-agent)
#
# Version is pinned via the image tag below. To upgrade:
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

# Hermes dashboard port. Railway's worker service type never assigns this a
# public domain, so "exposing" it here only makes it reachable on Railway's
# private network — which is exactly what the Tailscale subnet router bridges.
EXPOSE 9119

# Our thin Railway-specific wrapper: validates env vars, logs a startup banner,
# then execs the upstream entrypoint which handles privilege drop, volume
# bootstrap, and starting Hermes.
COPY entrypoint.sh /usr/local/bin/rome-entrypoint.sh
RUN chmod +x /usr/local/bin/rome-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/rome-entrypoint.sh"]
CMD ["gateway", "run"]
