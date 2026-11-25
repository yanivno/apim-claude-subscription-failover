# Claude Code gateway: Team subscription first, Foundry overflow

Azure API Management (Standard v2) in front of Claude Code, so that:

1. Requests use the developer's **Claude Team seat** (subscription OAuth token, passed through untouched).
2. When the seat hits its usage limit (Anthropic returns **HTTP 429**), the same request is resent to **Claude on Microsoft Foundry**, billed to Azure.
3. The user stays on Foundry until Anthropic's limit resets, under **per-user token limits**, and then returns to the Team seat automatically.

No client-side switching. Each developer has one APIM subscription key and their normal `/login`.

---

## Architecture

![Architecture: Claude Code → APIM Standard v2 → Anthropic (Team seat) with 429 failover to Microsoft Foundry](docs/architecture.svg)

<sub>Source: [`docs/architecture.svg`](docs/architecture.svg) (editable). PNG export: [`docs/architecture.png`](docs/architecture.png).</sub>

### Request flow

```mermaid
sequenceDiagram
    autonumber
    participant CC as Claude Code
    participant G as APIM
    participant A as Anthropic API
    participant F as Foundry (Claude)

    CC->>G: POST /claude/v1/messages<br/>Authorization: OAuth (Team seat) + subscription key
    G->>G: cache lookup claude-fallback-{sub}
    alt Not in fallback mode
        G->>A: forward as-is (OAuth token, anthropic-beta)
        alt Seat has capacity
            A-->>G: 200 (SSE stream)
            G-->>CC: 200, x-claude-route: anthropic
        else Seat limit reached
            A-->>G: 429 (+ retry-after / reset header)
            G->>G: cache fallback until reset (60 s to 5 h)
            G->>F: same request, Bearer = APIM MI token,<br/>model mapped, oauth-* beta removed
            F-->>G: 200 (SSE stream)
            G-->>CC: 200, x-claude-route: foundry
        end
    else In fallback mode
        G->>G: llm-token-limit (per user)
        G->>F: request with MI token, model mapped
        F-->>G: 200
        G-->>CC: 200, x-claude-route: foundry
    end
```

The switch to Foundry happens before any response bytes reach Claude Code, so a stream is never interrupted halfway.

---

## Repository layout

| Path | Purpose |
|---|---|
| `docs/architecture.svg` / `.png` | Architecture diagram |
| `policies/api-policy.xml` | API-level policy: caller identity, strip gateway key, default backend, metrics, `x-claude-route` header |
| `policies/messages-operation-policy.xml` | `POST /v1/messages`: 429 failover, fallback cache, model mapping, per-user limits |
| `infra/main.bicep` | APIM Standard v2, backends, named values, API + operations, product, App Insights, diagnostics |
| `infra/modules/foundry-role.bicep` | Grants APIM's managed identity *Cognitive Services User* on the Foundry account |
| `infra/main.bicepparam` | Parameters to edit before you deploy |
| `scripts/add-user.sh` | Creates a user's APIM subscription and prints their Claude Code settings |
| `client/settings.example.json` | Claude Code `~/.claude/settings.json` example |

---

## Configuration steps

### 1. Prerequisites

- Azure subscription with a **Microsoft Foundry** account and Claude deployments (for example `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`).
- Claude **Team** plan, with members using Claude Code.
- Azure CLI 2.60+ with Bicep, and rights to assign roles on the Foundry account (Owner or User Access Administrator).

### 2. Configure the Team plan

In **Claude → Organization settings → Usage**, turn **usage credits off** for the users who will route through this gateway (or for the whole org).
If usage credits are on, Anthropic keeps serving those users and bills the overage itself, so the 429 that triggers the Foundry fallback never comes back.

### 3. Edit parameters

In `infra/main.bicepparam`, set:

- `apimName`, `publisherEmail`, `publisherName`
- `foundryAccountName`, `foundryResourceGroup`
- `foundryModelMap`: `prefix=deployment;...;*=default`. Claude Code sends Anthropic model IDs, and the first matching prefix decides which Foundry deployment gets the request. List more specific prefixes first.
- Per-user Foundry limits: `foundryTpmPerUser`, `foundryMonthlyTokenQuotaPerUser`

### 4. Deploy

```bash
az group create -n rg-claude-gw -l westeurope
az deployment group create \
  -g rg-claude-gw \
  -f infra/main.bicep \
  -p infra/main.bicepparam
```

Provisioning Standard v2 typically takes a few minutes. The output `gatewayUrl` is the `ANTHROPIC_BASE_URL` value for clients.

What the deployment creates:

| Resource | Setting |
|---|---|
| APIM Standard v2 | System-assigned managed identity |
| Backend `anthropic-direct` | `https://api.anthropic.com` |
| Backend `foundry-claude` | `https://<foundry>.services.ai.azure.com/anthropic` |
| API `claude` (path `/claude`) | Operations: `POST /v1/messages` (failover), `POST /v1/messages/count_tokens`, `GET /*`, `POST /*` (passthrough) |
| Product `claude-code` | Subscription required, no approval |
| Named values | Model map, token audience, fallback TTL, per-user limits |
| App Insights + logger | Metrics on, **no body logging** (keeps SSE streaming intact and prompts out of logs) |
| Role assignment | *Cognitive Services User* for the APIM identity on the Foundry account |

### 5. Onboard users

```bash
./scripts/add-user.sh rg-claude-gw <apim-name> dana@contoso.com
```

This creates subscription `cc-dana-contoso-com` on the `claude-code` product and prints the user's settings. The subscription's display name is the user's email, which is what appears in the metrics.

### 6. Configure Claude Code (each developer)

`~/.claude/settings.json` (or deploy as managed settings):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<apim-name>.azure-api.net/claude",
    "ANTHROPIC_CUSTOM_HEADERS": "Ocp-Apim-Subscription-Key: <per-user-key>"
  }
}
```

Then run `claude`, followed by `/login` with the Team account.

> **Do not** set `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or `apiKeyHelper`. Claude Code sends any of those in place of the subscription OAuth token, so requests would stop using the Team seat.

### 7. Verify

1. **Anthropic route**: make a normal request. The response header `x-claude-route` should be `anthropic`, and the usage should count against the user's seat (check under Settings → Usage).
2. **Foundry route (forced)**: send one request with the header `x-claude-force-route: foundry`:
   ```bash
   curl -sS -D - "https://<apim>.azure-api.net/claude/v1/messages" \
     -H "Ocp-Apim-Subscription-Key: <key>" \
     -H "x-claude-force-route: foundry" \
     -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
     -d '{"model":"claude-sonnet-5-5","max_tokens":64,"messages":[{"role":"user","content":"ping"}]}'
   ```
   Expect `x-claude-route: foundry` and `x-foundry-remaining-tokens` headers. The header doesn't create a cache entry, so the next request goes back to Anthropic.
3. **Real failover**: when a seat hits its limit, the first 429 should switch that user to Foundry. Use APIM **Test → Trace** to check the `retry` iteration and the `cache-store-value` duration.
4. **Monitoring**: in App Insights → Metrics, under the custom namespace `claude-gateway`, `claude-requests` can be split by `Route` and `User`. Token counts by user come from `llm-emit-token-metric`.

---

## Design decisions

- **APIM subscription key for identity, not Entra JWT.** Claude Code's `Authorization` header holds the Team OAuth token, and `ANTHROPIC_CUSTOM_HEADERS` is static, so it can't carry an Entra token that expires every hour. A per-user subscription key is static and maps cleanly to `counter-key` for limits.
- **Fallback cached per user.** Without it, every request during an exhausted window would first make a wasted round trip to Anthropic. The cache TTL comes from `anthropic-ratelimit-unified-reset` or `retry-after` when present, otherwise from `claude-fallback-default-ttl-seconds`, and is clamped to 60 s–5 h.
- **Token limits only on the Foundry route.** Anthropic seat usage is already capped by the Team plan. Only Azure-billed traffic needs a budget.
- **Only `POST /v1/messages` fails over.** Other Anthropic endpoints Claude Code calls pass through unchanged, since they're cheap and some have no Foundry equivalent.

## Caveats and things to validate in your environment

- **429 signal.** Any 429 from Anthropic triggers fallback, including short per-minute rate limits. Those normally come with a short `retry-after`, so the user returns quickly. The reset header name `anthropic-ratelimit-unified-reset` is what the policy expects for subscription limits. Check it with an APIM trace on a real limited seat and adjust the policy if your responses differ.
- **First fallback request isn't token-limited.** `llm-token-limit` runs in inbound, before the 429 is known. Every request after the first is limited.
- **Beta headers.** Only `oauth-*` flags are removed on the Foundry route. If Foundry rejects other beta flags Claude Code sends, add them to the filter in `betaForFoundry`.
- **Cache.** `caching-type="prefer-external"` uses an external Redis cache if you configure one, otherwise APIM's built-in cache. With more than one APIM unit, the built-in cache isn't shared between units, so add an external Azure Managed Redis cache.
- **Foundry token audience.** The default is `https://cognitiveservices.azure.com`. If Foundry returns 401 on the fallback route, check the audience your Foundry account expects and update the `foundry-token-audience` named value.
- **Scope.** This covers **Claude Code** (CLI and the Code tab in Claude Desktop). Claude Desktop **chat** on a Team login talks to Anthropic directly and doesn't go through any gateway.
- **Policy format.** Both policy files are well-formed XML with escaped expressions, deployed as `format: 'xml'`. If you paste them into the portal editor, they appear unescaped, which is expected.
