# docs/webhook-setup.md

How to wire a rome-on-rails tenant project to the control-plane frontend so deployment status updates flow back to the UI.

This is a one-time per-tenant manual step. It exists because Railway's GraphQL API does not (as of 2026-04-29) expose mutations to create, update, or delete webhooks — only to test them. The control plane generates a unique receiver URL for each tenant; an operator pastes that URL into Railway's dashboard once. After that, every deployment status change for any service in the project flows automatically to the control plane.

If skipped, the agent still works (Slack, Tailscale SSH, lifecycle controls all function), but the tenant's status indicators in the control plane will not update. See `HANDOFF.md` Risk 11.

---

## When to do this

After you have:

1. Created the tenant in the control plane (which generates a unique webhook URL).
2. Provisioned the tenant's first Hermes agent — the Railway project now exists.
3. Verified the agent reached `SUCCESS` status (so the Railway dashboard shows a working deployment to test against).

Before:

- Skipping this step and assuming "the deploy worked" — without webhooks, the control plane UI never observes status changes.

---

## Prerequisites

- Railway dashboard access to the tenant's project
- The tenant's webhook URL from the control plane — surfaces on the tenant detail page after creation; shape:
  ```
  https://<your-control-plane>/api/webhooks/railway/<token>
  ```
  The `<token>` is opaque, ~36 chars, generated server-side. Treat it as a credential — don't paste it into chat threads or screenshots.

---

## Setup

1. Open Railway → select the tenant's project.
2. Click **Settings** in the project's left nav.
3. Scroll to **Webhooks**.
4. Click **Add Webhook**.
5. Paste the webhook URL from the control plane into the URL field.
6. Select event filters. At minimum enable **deployment status changes**. Volume usage and CPU/RAM alerts can be enabled too if the control plane handles them; safe to leave off for v1.
7. Click **Save**.

That's it for the Railway side.

---

## Verify it worked

Two ways:

**Option A — Railway's "Test Webhook" button.** On the saved webhook entry in Railway, there should be a test affordance. Use it. The control plane's receiver should log an inbound POST. If it does, you're done.

**Option B — Trigger a real deploy.** From the control plane, redeploy the tenant's agent. Watch the tenant detail page in the control plane — the "webhook configured?" indicator should turn green within a few seconds, and the agent's status should update through `BUILDING` → `DEPLOYING` → `SUCCESS` in real time. If the indicator stays gray after a deploy completes, the webhook isn't reaching the receiver — see Troubleshooting.

---

## Rotation

Treat the webhook URL like any other credential — rotate it if you have any reason to suspect it leaked (logs shared with a third party, access-control change in your team, etc.).

To rotate:

1. In the control plane's tenant detail page, click **Regenerate webhook URL**. The control plane creates a new token and starts treating the old one as 404.
2. Copy the new URL.
3. Open Railway → tenant project → Settings → Webhooks.
4. Edit the existing webhook entry and replace the URL. (Or delete it and add a fresh one — same effect.)
5. Save. Verify with the Test button.

The brief window between steps 1 and 4 is one where Railway is still sending events to the old URL, which now 404s. The control plane will log these as orphan events, no harm done — they'd retry but the new URL won't be in Railway yet. Try not to leave that gap open for long.

---

## What the control plane does on its end

For context, so you understand what to expect:

- **Receiver URL is unique per tenant.** Two tenants never share a URL. A token leaked for tenant A is useless for tenant B (and the receiver verifies `resource.projectId` against the tenant's expected project on every event — defense in depth).
- **Receiver is idempotent.** Railway may retry deliveries. The control plane handles duplicate events without breaking — safe to retrigger from Railway's Test button as many times as you like.
- **Receiver returns 200 fast.** Railway treats non-2xx responses as delivery failures and retries. The control plane processes the payload async and acks immediately.
- **Receiver persists raw payloads** for ~30 days for audit and replay. If something looks wrong in the UI, the raw events are queryable from the control plane's admin tools.

---

## Troubleshooting

### Indicator stays gray after a successful deploy

- **URL typo.** Re-copy from the control plane. Whitespace at the start or end of the URL field in Railway is a common culprit.
- **Wrong event filters.** Make sure deployment status changes are enabled. If only volume/CPU alerts are checked, deployment events don't fire.
- **Receiver not deployed.** Check that the control plane is reachable at the domain in the URL. Hit the URL in a browser — it should return 404 (not "connection refused"). 404 is correct: the receiver returns 404 for any GET, since webhooks are POST-only.
- **Token rotated but Railway not updated.** If you rotated in the control plane and forgot to update Railway, Railway's still calling the dead URL. Check the timestamp on the webhook entry in Railway against your rotation time.

### Test webhook button shows "delivery failed" but real deploys work fine

This is a known Railway quirk — the Test button sends from the frontend client and may hit CORS restrictions even when the actual webhook delivery (from Railway's backend) works fine. Trust real deploys over the Test button if they disagree.

### Two tenants both show updates from one deploy

Almost certainly a webhook URL crosswiring — the same URL got pasted into two different Railway projects' webhook settings. Open both projects' Webhooks panels and confirm each has its tenant's correct URL. The control plane's receiver also rejects events whose `resource.projectId` doesn't match the tenant on file (so the data won't be wrong on the misconfigured tenant — it'll just be dropped), but the indicator on the wrongly-receiving tenant will go green incorrectly. Fix by repasting the right URL into each project.

### "I deleted the webhook in Railway and now no events arrive"

Expected. Add it back via Setup steps above. The control plane doesn't know Railway-side deletions happened — it'll keep waiting.

---

## Why this is manual

For reference if you're wondering whether to script it: Railway's API exposes `webhookTest(url, payload)` for sending sample webhook deliveries, but no `webhookCreate` / `webhookUpdate` / `webhookDelete` mutations. The Postman collection at `docs/railway_graphql_collection.json` lists those mutation names but they do not exist in the live schema (verified 2026-04-29 — `Cannot query field "webhookCreate" on type "Mutation"`). Track this — if Railway ever adds programmatic webhook configuration, this whole document becomes obsolete and the step folds into provisioning automation. The introspection query that detects that change is in `POSTMAN-API-TESTS.md` Phase 7.1.

---

## See also

- `ARCHITECTURE.md` — Decisions Log entry dated 2026-04-29 captures the architectural rationale
- `HANDOFF.md` Risk 11 — operational consequences if this step is skipped
- `docs/POSTMAN-API-TESTS.md` Phase 7 — the `webhookTest` mutation, useful for control-plane receiver development
- [Railway Webhooks docs](https://docs.railway.com/observability/webhooks) — payload shape and event categories
