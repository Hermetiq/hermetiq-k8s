# MCP Server Authentication — Auth0 Tenant Runbook

This runbook walks through configuring an Auth0 tenant so that MCP clients such as Claude can authenticate to the Hermetiq MCP server (`https://mcp.<your-domain>`) via OAuth **Dynamic Client Registration (DCR)**. The Hermetiq chart side is covered in the main guide under [MCP Server Authentication](../README.md#mcp-server-authentication); this document is only the IdP side.

Configure the tenant once so that *any* dynamically-registered client is authorized. The commands below use the Auth0 CLI's Management API passthrough (run `auth0 login` first).

**Step 1 — Enable Dynamic Client Registration:**
```bash
auth0 api patch tenants/settings --data '{"flags":{"enable_dynamic_client_registration":true}}'
```

**Step 2 — Register the MCP server as an API** whose identifier is the resource
URL, exactly as the client requests it. This runbook standardizes on the
trailing-slash form:
```bash
auth0 api post resource-servers --data '{
  "name":"Hermetiq MCP","identifier":"https://mcp.<your-domain>/",
  "signing_alg":"RS256","allow_offline_access":true }'
```

**Step 3 — Authorize all DCR clients for that API** with a default grant. DCR
mints a new third-party client per registration, so per-client grants don't
scale; `default_for` applies to every dynamically-registered client:
```bash
auth0 api post client-grants --data '{
  "default_for":"third_party_clients","subject_type":"user",
  "audience":"https://mcp.<your-domain>/","scope":[] }'
```

**Important: the MCP resource URL must match byte-for-byte.** Auth0 treats
`https://mcp.<your-domain>` and `https://mcp.<your-domain>/` as different API
identifiers. Pick one form and use it everywhere; for Claude, use the
trailing-slash form:

- MCP client/server URL in Claude: `https://mcp.<your-domain>/`
- Auth0 API identifier: `https://mcp.<your-domain>/`
- Auth0 default client-grant audience: `https://mcp.<your-domain>/`
- Hermetiq values, when you need to force the advertised resource URL:

  ```yaml
  api:
    mcpResourceUrl: "https://mcp.<your-domain>/"
  ```

Do not put the dashboard SSO application's client ID or secret into Helm for
Claude MCP auth. With DCR, Claude creates its own temporary third-party Auth0
client; the Helm chart only needs to advertise the authorization server and
validate JWTs for the MCP resource URL.

After deploying the Helm values, verify that Hermetiq advertises the same URL:

```bash
curl -fsS https://mcp.<your-domain>/.well-known/oauth-protected-resource | jq .resource
```

The output should be exactly:

```text
"https://mcp.<your-domain>/"
```

**Step 4 — Promote your login connection to domain level** so third-party (DCR)
clients can authenticate users:
```bash
auth0 api patch "connections/<connection-id>" --data '{"is_domain_connection":true}'
```

Then connect from the MCP client and watch `auth0 logs tail` to confirm the
flow. Common failures and fixes:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `dynamic client registration is disabled` (on `/oidc/register`) | DCR not enabled | Step 1 |
| `Service not found: https://mcp.<your-domain>` or `Service not found: https://mcp.<your-domain>/` (at `/authorize`) | Auth0 could not find an API whose identifier exactly matches the `resource` value requested by the client. The most common cause is a trailing-slash mismatch between Claude, Auth0, and `api.mcpResourceUrl`. | Standardize on `https://mcp.<your-domain>/` everywhere: Claude MCP URL, Auth0 API identifier, Auth0 client-grant `audience`, and `api.mcpResourceUrl`. Remove/re-add the Claude connector after changing the URL so it performs a fresh DCR flow. |
| `Grant type 'client_credentials' not allowed for the client.` | Claude registered a DCR third-party client (`client_id` starts with `tpc_...`) and Auth0 rejected a machine-to-machine token request for that client. This often appears while the client is retrying after a bad resource/audience setup. | Fix the exact resource URL mismatch first, delete stale `Claude` DCR apps if necessary, then reconnect Claude. Do not reuse the dashboard SSO client secret for MCP DCR auth. |
| `You reached the limit of entities of this type` (`too_many_entities`) | Each connect mints a new client and the tenant client cap is hit | Delete stale third-party `Claude` apps (`auth0 apps list` / `auth0 apps delete`); don't repeatedly run the `/oidc/register` probe |
| `Client … is not authorized to access resource server …` (at `/authorize`) | The DCR client isn't authorized for the API | Step 3 (default grant) |
| `JWT verification requires JWKS auth in claims-based auth mode` (MCP server log) | The MCP server isn't in JWKS mode | Set `api.jwt.enabled=true` (audience/issuer derive automatically) |
| Browser shows "Couldn't connect" with **no Auth0 log activity** at all | The MCP client cached a DCR `client_id` that no longer exists (e.g. one deleted during a `too_many_entities` cleanup), so it never starts the OAuth flow | Remove and re-add the connector in the MCP client to force a fresh DCR registration |

Useful inspection commands:

```bash
# Auth0 APIs. Confirm the MCP API identifier has the same trailing slash.
auth0 api get resource-servers \
  | jq '.. | objects | select(has("identifier")) | {name, identifier}'

# Auth0 default grants. Confirm the audience matches the API identifier exactly.
auth0 api get client-grants \
  | jq '.. | objects
        | select((.default_for // empty | tostring | contains("third_party_clients"))
                 or (.client_id? // "" | startswith("tpc_")))
        | {audience, default_for, client_id, subject_type, scope}'

# Live Hermetiq MCP metadata. Confirm .resource matches the Auth0 identifier.
curl -fsS https://mcp.<your-domain>/.well-known/oauth-protected-resource | jq .
```

Other IdPs (Okta, Entra, Keycloak) expose equivalent concepts — DCR, an
API/audience definition, and a way to grant all dynamically-registered clients
access to that audience. The chart side is identical regardless of IdP: set
`oidc.issuerUrl` and `hosts.domainBase` and enable `api.jwt` — the MCP resource,
token audience, and advertised authorization server all derive from those.
