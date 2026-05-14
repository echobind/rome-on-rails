# Postman test plan — Railway API verification

> **Scratch file.** This is throwaway research used to verify Railway's API behavior in Postman before writing the frontend's provisioning + control-plane code. Delete once the relevant queries are wired into the application backend.

A phase-by-phase set of GraphQL queries/mutations that exercise every Railway API surface the eventual frontend will need: provisioning new agents from the published Hermes template, capturing their IDs, controlling per-service lifecycle (pause/resume/restart), and managing per-service env vars (the soft-pause-Slack lever).

Each item lists the exact GraphQL, the variables shape, what to verify, the doc citation, and any token-scope caveat.

---

## Heads-up: project token vs. workspace token

The Postman setup currently uses a **project token**, scoped to one project + environment ([Railway auth docs](https://docs.railway.com/integrations/api)).

- ✅ Phases 2–5 (read state, service control, variables) work with a project token against the existing project.
- ⚠️ Phase 6 (template-based provisioning of *new* projects) probably needs a **workspace token**, because creating a new project is out of scope for a project token. Test with the project token first; if it 401s, switch to a workspace token for that phase only.

Project token uses the `Project-Access-Token: <TOKEN>` header. Workspace tokens use `Authorization: Bearer <TOKEN>`.

---

## Postman collection variables

In the `Railway API` collection's **Variables** tab, define these (Current Value column only — leave Initial blank so they don't sync):

| Variable | Source | Notes |
|---|---|---|
| `RAILWAY_PROJECT_TOKEN` | already set | Step 1 of original setup |
| `RAILWAY_WORKSPACE_TOKEN` | Railway dashboard → Tokens | Only needed for Phase 6 |
| `projectId` | Railway dashboard URL | Existing test project |
| `environmentId` | from Phase 1.1 query | Auto-captured |
| `serviceId` | from Phase 1.1 query | Pick a non-critical agent to test against |
| `deploymentId` | from Phase 2.2 query | Captured fresh before each lifecycle test |
| `workflowId` | from Phase 6.2 mutation | Captured during template deploy |
| `templateCode` | published template's URL slug | e.g., the path piece from `railway.com/template/<code>` |

## Auto-capturing IDs between requests

For any request whose response feeds the next, paste this pattern into the request's **Tests** tab — Postman runs it after the response lands and writes into collection variables:

```javascript
const json = pm.response.json();
// example: capture first service id from a project query
pm.collectionVariables.set("serviceId", json.data.project.services.edges[0].node.id);
```

The per-request capture script is shown inline below where it matters.

---

## Phase 1: Sanity check (read-only, can't break anything)

### 1.1 — Resolve the project, environments, and services

```graphql
query GetProject($id: String!) {
  project(id: $id) {
    id
    name
    environments {
      edges { node { id name } }
    }
    services {
      edges {
        node {
          id
          name
          serviceInstances {
            edges {
              node {
                environmentId
                latestDeployment { id status }
              }
            }
          }
        }
      }
    }
  }
}
```

**Variables:**
```json
{ "id": "{{projectId}}" }
```

**Tests tab (capture for later phases):**
```javascript
const p = pm.response.json().data.project;
pm.collectionVariables.set("environmentId", p.environments.edges[0].node.id);
// pick whichever service name is your "throwaway" test agent:
const target = p.services.edges.find(e => e.node.name === "hermes-test");
pm.collectionVariables.set("serviceId", target.node.id);
```

**Verify:** the services you expect are listed; each healthy one has `latestDeployment.status === "SUCCESS"`.

**Cite:** [Manage Services with the Public API](https://docs.railway.com/integrations/api/manage-services).

---

## Phase 2: Read service state (powers UI status badges)

### 2.1 — Service instance details

```graphql
query ServiceInstance($serviceId: String!, $environmentId: String!) {
  serviceInstance(serviceId: $serviceId, environmentId: $environmentId) {
    serviceId
    environmentId
    startCommand
    numReplicas
    region
    restartPolicyType
    latestDeployment { id status createdAt }
  }
}
```

**Variables:**
```json
{ "serviceId": "{{serviceId}}", "environmentId": "{{environmentId}}" }
```

**Verify:** `startCommand` matches what you expect (e.g., `gateway run` for a Hermes service), `numReplicas` is 1, `restartPolicyType` is reasonable.

**Cite:** [Manage Services — `serviceInstance`](https://docs.railway.com/integrations/api/manage-services).

### 2.2 — Recent deployments (yields a `deploymentId` to act on)

```graphql
query Deployments($projectId: String!, $serviceId: String!, $environmentId: String!) {
  deployments(
    input: {
      projectId: $projectId,
      serviceId: $serviceId,
      environmentId: $environmentId
    }
    first: 5
  ) {
    edges {
      node {
        id
        status
        createdAt
        staticUrl
      }
    }
  }
}
```

**Variables:**
```json
{
  "projectId": "{{projectId}}",
  "serviceId": "{{serviceId}}",
  "environmentId": "{{environmentId}}"
}
```

**Tests tab (capture latest deployment id):**
```javascript
const edges = pm.response.json().data.deployments.edges;
pm.collectionVariables.set("deploymentId", edges[0].node.id);
```

**Verify:** newest deployment's status is `SUCCESS`. Its `id` feeds the lifecycle mutations.

**Cite:** [Manage Deployments with the Public API](https://docs.railway.com/guides/manage-deployments).

---

## Phase 3: Service lifecycle (Pause / Resume / Restart buttons)

> Run these against a **throwaway** service. Each takes the bot offline in Slack for the duration. Re-run Phase 2.2 between operations to refresh `deploymentId` — once stopped, redeploying creates a new deployment with a new id.

### 3.1 — Pause (the "Stop" button)

```graphql
mutation StopDeployment($id: String!) {
  deploymentStop(id: $id)
}
```

**Variables:**
```json
{ "id": "{{deploymentId}}" }
```

**Verify in Postman:** response is `{ "data": { "deploymentStop": true } }`.
**Verify out-of-band:** Railway dashboard shows the service stopped; Tailscale admin shows the node go offline within ~30s.

**Cite:** [Manage Deployments — `deploymentStop`](https://docs.railway.com/guides/manage-deployments).

### 3.2 — Resume (the "Start" button after a Stop)

```graphql
mutation RedeployDeployment($id: String!) {
  deploymentRedeploy(id: $id) {
    id
    status
  }
}
```

**Variables:**
```json
{ "id": "{{deploymentId}}" }
```

**Verify:** new `id` returned, `status` transitions through `BUILDING`/`DEPLOYING` to `SUCCESS`. The Tailscale node returns with the same MagicDNS hostname (because `/opt/data/.tailscale/` survived).

**Cite:** [Manage Deployments — `deploymentRedeploy`](https://docs.railway.com/guides/manage-deployments).

**Alternative** that doesn't require knowing a `deploymentId` (useful if a service has no successful deployment yet):

```graphql
mutation RedeployService($serviceId: String!, $environmentId: String!) {
  serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId)
}
```

**Cite:** [Manage Services — `serviceInstanceRedeploy`](https://docs.railway.com/integrations/api/manage-services).

### 3.3 — Restart in place (no rebuild)

```graphql
mutation RestartDeployment($id: String!) {
  deploymentRestart(id: $id)
}
```

**Verify:** container kicks; same image; faster than redeploy because the build is reused.

**Cite:** [Manage Deployments — `deploymentRestart`](https://docs.railway.com/guides/manage-deployments).

### 3.4 — Cancel (only valid for in-flight deploys)

```graphql
mutation CancelDeployment($id: String!) {
  deploymentCancel(id: $id)
}
```

Run against a deployment currently `BUILDING` or `DEPLOYING`. Powers the UI's "Abort deploy" button.

**Cite:** [Manage Deployments — `deploymentCancel`](https://docs.railway.com/guides/manage-deployments).

---

## Phase 4: Service-scoped env vars (per-agent Slack soft-pause + provisioning overrides)

### 4.1 — Read variables on one service

```graphql
query ServiceVars($projectId: String!, $environmentId: String!, $serviceId: String!) {
  variables(
    projectId: $projectId
    environmentId: $environmentId
    serviceId: $serviceId
  )
}
```

**Variables:** the three IDs already captured.

**Verify:** returns a JSON map of the per-service variables (the `SLACK_*` and `TS_HOSTNAME` ones), not the shared/environment-scoped ones. Confirms that scoping behaves as documented.

**Cite:** [Manage Variables with the Public API](https://docs.railway.com/guides/manage-variables).

### 4.2 — Soft-pause Slack on one agent (set empty allowlist)

```graphql
mutation SetVar($input: VariableUpsertInput!) {
  variableUpsert(input: $input)
}
```

**Variables:**
```json
{
  "input": {
    "projectId": "{{projectId}}",
    "environmentId": "{{environmentId}}",
    "serviceId": "{{serviceId}}",
    "name": "SLACK_ALLOWED_USERS",
    "value": ""
  }
}
```

**Verify:** mutation returns `true`. Default behavior triggers an auto-redeploy on that one service only — confirm in the Railway dashboard that other agents in the same project don't redeploy.

**Cite:** [Manage Variables — `variableUpsert` and service scoping](https://docs.railway.com/guides/manage-variables).

### 4.3 — Same as 4.2 but skip the auto-redeploy (batch updates during provisioning)

Add `"skipDeploys": true` to the input:

```json
{
  "input": {
    "projectId": "{{projectId}}",
    "environmentId": "{{environmentId}}",
    "serviceId": "{{serviceId}}",
    "name": "SLACK_ALLOWED_USERS",
    "value": "U12345,U67890",
    "skipDeploys": true
  }
}
```

**Verify:** no redeploy fires. Re-run Phase 4.1 to confirm the value is set, then explicitly trigger a deploy via Phase 3.2's `serviceInstanceRedeploy` to apply it.

**Cite:** [Railway help station — `skipDeploys` flag](https://station.railway.com/questions/unexpected-deploy-triggered-by-variable-u-099d33fa).

### 4.4 — Bulk set (provision a new agent's full env-var set)

```graphql
mutation BulkSetVars($input: VariableCollectionUpsertInput!) {
  variableCollectionUpsert(input: $input)
}
```

**Variables:**
```json
{
  "input": {
    "projectId": "{{projectId}}",
    "environmentId": "{{environmentId}}",
    "serviceId": "{{serviceId}}",
    "variables": {
      "TS_HOSTNAME": "tenant-acme-agent-2",
      "SLACK_BOT_TOKEN": "xoxb-...",
      "SLACK_APP_TOKEN": "xapp-...",
      "SLACK_ALLOWED_USERS": "U12345"
    },
    "skipDeploys": true
  }
}
```

**Verify:** all four variables show up in Phase 4.1. Then redeploy once.

**Cite:** [Manage Variables — `variableCollectionUpsert`](https://docs.railway.com/guides/manage-variables).

---

## Phase 5: Service deletion (cleanup)

### 5.1 — Delete the throwaway test service

```graphql
mutation DeleteService($id: String!) {
  serviceDelete(id: $id)
}
```

**Variables:**
```json
{ "id": "{{serviceId}}" }
```

**Verify:** Phase 1.1 query no longer lists it. Run *only* against the test agent — destructive; the volume goes with it.

**Cite:** [Manage Services — `serviceDelete`](https://docs.railway.com/integrations/api/manage-services).

---

## Phase 6: Tenant provisioning ("Create new agent" button)

The full provisioning sequence: create a named project, deploy the template into it as the first agent, optionally add subsequent agents to the same tenant project. Creating a new project requires the **workspace token** (`Authorization: Bearer {{RAILWAY_WORKSPACE_TOKEN}}`); adding to an existing project may work with either a workspace or project token.

### 6.1 — Fetch the published Hermes template's config

```graphql
query GetTemplate($code: String!) {
  template(code: $code) {
    id
    name
    serializedConfig
  }
}
```

**Variables:**
```json
{ "code": "{{templateCode}}" }
```

`templateCode` is the **slug from the template's deploy URL** (the path piece from `railway.com/template/<code>`), not the template's UUID. Easy to confuse — the *response* gives you the UUID as `id`, which is what the deploy mutation wants.

**Tests tab (capture for the deploy mutation):**
```javascript
const t = pm.response.json().data.template;
pm.collectionVariables.set("templateId", t.id);                                  // UUID
pm.collectionVariables.set("serializedConfig", JSON.stringify(t.serializedConfig));
```

**Verify:** `serializedConfig` is a JSON object containing the service definitions, env-var schema, and volume mount. Inspect it once — its shape is what per-tenant override code will modify.

**Cite:** schema-direct via Postman introspection (the `template(code:)` query and `Template` type are in the live schema).

### 6.2 — Create the named tenant project

Skips the auto-naming Railway does when `templateDeployV2` creates its own project, and gives the control plane control over project naming up front.

```graphql
mutation CreateProject($input: ProjectCreateInput!) {
  projectCreate(input: $input) {
    id
    name
    environments { edges { node { id name } } }
  }
}
```

**Variables:**
```json
{
  "input": {
    "name": "tenant-acme",
    "workspaceId": "{{workspaceId}}"
  }
}
```

**Tests tab:**
```javascript
const p = pm.response.json().data.projectCreate;
pm.collectionVariables.set("newProjectId", p.id);
pm.collectionVariables.set("newEnvironmentId", p.environments.edges[0].node.id);
```

**Verify:** named project exists in the Railway dashboard with the requested name and a default `production` environment.

**Cite:** [Manage Services — `projectCreate`](https://docs.railway.com/integrations/api/manage-services).

### 6.3 — Deploy the template into the new project

```graphql
mutation DeployTemplate($input: TemplateDeployV2Input!) {
  templateDeployV2(input: $input) {
    projectId
    workflowId
  }
}
```

**Variables** (paste the JSON object for `serializedConfig`, not a string):
```json
{
  "input": {
    "templateId": "{{templateId}}",
    "serializedConfig": { /* from 6.1's response, with required vars resolved to per-tenant values — see note below */ },
    "projectId": "{{newProjectId}}",
    "environmentId": "{{newEnvironmentId}}",
    "workspaceId": "{{workspaceId}}"
  }
}
```

**Important — required variables must be populated.** The template's `serializedConfig.services.<id>.variables` block declares `TS_AUTHKEY`, `TS_HOSTNAME`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, and `SLACK_ALLOWED_USERS` as `isOptional: false` with empty `defaultValue`. The mutation rejects deploys where required vars are blank with the generic `"Problem processing request"` error. Substitute real (or test) values into each `defaultValue` before sending.

**Tests tab:**
```javascript
const r = pm.response.json().data.templateDeployV2;
// projectId is guaranteed; workflowId may be null when deploying into an existing project
pm.collectionVariables.set("workflowId", r.workflowId);
```

**Verify:** Railway dashboard shows the new agent service inside the named project, transitioning through `BUILDING` → `DEPLOYING` → `SUCCESS`.

**Cite:** `TemplateDeployV2Input` schema verified via Postman introspection 2026-04-28; reference type definition in [crisog/railway-sdk graphql.ts](https://github.com/crisog/railway-sdk/blob/main/src/generated/graphql.ts) (third-party SDK with codegen against the live schema).

### 6.4 — Poll project for service readiness

There is no documented `workflowStatus` query (verified via introspection — no such field exists on Query). Instead, poll Phase 1.1's `project(id:)` query against `{{newProjectId}}` every 2–3 seconds until every service in `services.edges[].node.serviceInstances.edges[].node.latestDeployment.status` equals `SUCCESS`. That's the "agent is ready" signal.

For each service in the response, capture `id` — those are the `serviceId`s to insert into the control plane's `agents` table.

**Cite:** Phase 1.1 query; status enum values in [Railway Deployments reference](https://docs.railway.com/deployments/reference).

### 6.5 — Add another agent to an existing tenant project

Same `templateDeployV2` mutation as 6.3, but pass the **existing** tenant's `projectId` (and `environmentId`) instead of the freshly-created ones. Substitute *unique* per-agent values for `TS_HOSTNAME` and `SLACK_BOT_TOKEN`/`SLACK_APP_TOKEN` to avoid the collisions documented in `HANDOFF.md` Risk 10:

```json
{
  "input": {
    "templateId": "{{templateId}}",
    "serializedConfig": { /* from 6.1, with fresh per-agent values */ },
    "projectId": "{{projectId}}",
    "environmentId": "{{environmentId}}"
  }
}
```

The service-key UUID inside `serializedConfig` (the `services["..."]` and `volumeMounts["..."]` keys) should also be regenerated per agent. Pre-request script to do this in Postman:

```javascript
pm.collectionVariables.set("serviceKey", crypto.randomUUID());
```

…then reference `{{serviceKey}}` as the key in your `serializedConfig`.

**Verify:** the existing project gains a new service; original services untouched.

**Cite:** same as 6.3.

---

## Phase 7: Webhook setup helpers (control-plane integration)

The control plane uses Railway webhooks for deployment status updates (see `ARCHITECTURE.md` decision dated 2026-04-29 and `docs/webhook-setup.md`). Programmatic webhook *configuration* is **not** available in the API — `webhookCreate` / `webhookUpdate` / `webhookDelete` appear in `docs/railway_graphql_collection.json` but are not present in the live schema (verified 2026-04-29). Treat that collection as suggestive only; verify any mutation against introspection before relying on it.

What the API **does** expose is `webhookTest`, useful for end-to-end validation of the control plane's receiver during development.

### 7.1 — Verify which webhook operations exist in the live schema

Re-run periodically — when Railway adds programmatic webhook configuration, the manual setup step in `docs/webhook-setup.md` retires.

```graphql
query InspectWebhookOps {
  __schema {
    mutationType {
      fields { name }
    }
  }
}
```

In Postman → response body → Ctrl+F `webhook`. As of 2026-04-29 only `webhookTest` appears.

### 7.2 — Send a test payload to the control plane's receiver

```graphql
mutation TestWebhook($url: String!, $payload: String!) {
  webhookTest(url: $url, payload: $payload)
}
```

**Variables:**
```json
{
  "url": "https://<control-plane>/api/webhooks/railway/<test-token>",
  "payload": "{ \"type\": \"Deployment.success\", \"details\": { \"id\": \"test-deployment-id\", \"status\": \"SUCCESS\" }, \"resource\": { \"projectId\": \"...\", \"serviceId\": \"...\" }, \"severity\": \"info\", \"timestamp\": \"2026-04-29T00:00:00Z\" }"
}
```

`payload` is a string here (not a JSON object) — Railway forwards it verbatim to the receiver. The receiver should accept arbitrary JSON in the body, parse it itself, and not assume anything about the shape beyond what's documented at [Railway Webhooks](https://docs.railway.com/observability/webhooks).

**Verify:** the control plane's receiver logs an inbound POST with the test payload and routes it to the test tenant. If the receiver doesn't see it, check the URL (typo, trailing slash, wrong token) and re-fire.

**Cite:** `webhookTest(url, payload)` field schema visible via the Phase 7.1 introspection query.

---

## Recommended run order

1. **Phase 1.1** → confirm project + capture IDs.
2. **Phase 2** (both queries) → confirm read-state for status badges.
3. **Phase 4.1** → see current per-service variables.
4. **Phase 4.2** → soft-pause Slack on the throwaway agent; verify only that one redeploys.
5. **Phase 3.1 → 3.2** → full stop/resume cycle on the throwaway agent.
6. **Phase 3.3** → in-place restart.
7. **Phase 4.4** → bulk env-var update with `skipDeploys`, then **Phase 3.2** to apply.
8. **Phase 6.1** → fetch the template config; inspect `serializedConfig` shape.
9. **Phase 6.5** → add a second test agent to the existing project.
10. **Phase 6.2 → 6.3 → 6.4** → full new-tenant flow: create named project, deploy template, poll until ready (workspace token).
11. **Phase 7.1** → confirm only `webhookTest` is in the live schema (re-run periodically).
12. **Phase 7.2** → fire a test webhook at the control plane receiver (once it's deployed).
13. **Phase 5.1** → clean up the throwaway services.

By the end every API surface the control-plane frontend needs has been exercised end-to-end.

---

## A note on the Postman collection in this folder

`docs/railway_graphql_collection.json` is a useful starting point for discovering Railway's API surface, but **it is not authoritative**. At least three of its mutations (`webhookCreate`, `webhookUpdate`, `webhookDelete`) do not exist in the live schema — the collection appears to have been generated against an older or aspirational schema. Always verify a mutation via introspection (see Phase 7.1 for the pattern) before relying on it in code.

---

## Sources

- [Railway Public API authentication](https://docs.railway.com/integrations/api)
- [Manage Services with the Public API](https://docs.railway.com/integrations/api/manage-services) — `projectCreate`, `serviceCreate`, `serviceInstance*`, `serviceDelete`
- [Manage Deployments with the Public API](https://docs.railway.com/guides/manage-deployments) — `deployments`, `deploymentStop`, `deploymentRedeploy`, `deploymentRestart`, `deploymentCancel`
- [Manage Variables with the Public API](https://docs.railway.com/guides/manage-variables) — `variableUpsert`, `variableCollectionUpsert`, service-scope semantics
- [Railway Deployments reference](https://docs.railway.com/deployments/reference) — deployment status enum values
- [Railway Webhooks](https://docs.railway.com/observability/webhooks) — payload shape, event categories
- [Railway GraphQL overview & introspection](https://docs.railway.com/integrations/api/graphql-overview)
- [crisog/railway-sdk graphql.ts](https://github.com/crisog/railway-sdk/blob/main/src/generated/graphql.ts) — third-party SDK with the `TemplateDeployV2Input` and other type definitions generated from the live schema
- [Help station: variableUpsert and skipDeploys](https://station.railway.com/questions/unexpected-deploy-triggered-by-variable-u-099d33fa)
