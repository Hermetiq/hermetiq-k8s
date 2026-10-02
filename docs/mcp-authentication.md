# MCP authentication for Hermetiq

This guide covers the Hermetiq chart's MCP authentication settings and the IdP
configuration MCP clients need. Return to the [chart installation guide](../charts/hermetiq/README.md#authentication-and-sso)
for the rest of the authentication setup.

## Chart configuration

The MCP server runs inside the `api` container and is authenticated by the same
core verifier as the gRPC API. Turn it on with `api.jwt.enabled=true`; the chart
then derives everything else from `oidc.issuerUrl` and the MCP host:

- `GRPC_AUTH_JWKS_URL` / `GRPC_AUTH_ISSUER` ← `oidc.issuerUrl` (or `api.jwt.*` overrides)
- `GRPC_AUTH_AUDIENCE` ← the MCP server's two protected resources, the origin
  (`mcpResourceUrl`, default `https://mcp.<domainBase>`) and `<origin>/mcp` —
  under RFC 8707 the resource *is* the token audience — **plus** the gRPC API
  audience, joined with commas. One process now authenticates both callers and
  they carry different audiences, so a token matching any entry is accepted
- `MCP_AUTHORIZATION_SERVER` ← the OIDC issuer (trailing slash stripped)
- `GRPC_AUTH_GROUPS_CLAIM` ← `api.jwt.groupsClaim`

The gRPC API half of that audience list is `api.jwt.audience` when set, and
otherwise the dashboard oauth2-proxy client ID. That client ID lives in a Secret,
so the chart injects it as `GRPC_AUTH_AUDIENCE_CLIENT_ID` and interpolates it
into the list with the kubelet's `$(VAR)` expansion — the rendered value reads
`https://mcp.<domainBase>,https://mcp.<domainBase>/mcp,$(GRPC_AUTH_AUDIENCE_CLIENT_ID)`.
If you disable the dashboard oauth2-proxy, set `api.jwt.audience` explicitly;
the chart refuses to render otherwise, because the list would carry only the MCP
audiences and every gRPC API token would be rejected.

Without these the MCP server falls back to claims-based auth mode and rejects
every bearer token with `JWT verification requires JWKS auth in claims-based
auth mode`. The minimal configuration is just the issuer, the host, and the
toggle:

```yaml
oidc:
  issuerUrl: https://<tenant>.auth0.com/
hosts:
  domainBase: example.com            # MCP clients connect to https://mcp.example.com/mcp
api:
  jwt:
    enabled: true
    groupsClaim: hermetiq/roles
```

You do **not** set the MCP audience: it derives from the MCP host. The verifier
ignores trailing-slash differences in a token's audience, but your IdP does not
when it matches the resource a client requests (see below). `api.jwt.audience`
sets the **gRPC API** audience (dashboard/web traffic) and is added alongside the
MCP ones — leave it unset to reuse the dashboard oauth2-proxy client ID, or set it
when the gRPC API needs a specific audience. Override the derived MCP defaults
only when needed: `api.mcpResourceUrl` when the public MCP origin differs from
`https://mcp.<domainBase>`, and `api.mcpAuthorizationServer` for the advertised
authorization server.

Point MCP clients and your IdP's API identifier at `https://mcp.<domainBase>/mcp`.
Every MCP client sends that resource URL identically, while a bare origin goes
out with or without a trailing slash depending on the client — and IdPs such as
Auth0 match the requested resource exactly. `api.mcpResourceUrl` stays the
origin: the chart refuses a value with a path such as `/mcp`, because the server
derives the `/mcp` resource from it. See the
[Auth0 runbook](mcp-auth0-runbook.md).

MCP is served only by the API Deployment; the publisher does not run an MCP
server. MCP identity metadata is opaque by default. Set
`api.mcpExposeUserIdentities: true` to expose developer identity metadata for an
installation that requires it. This sets `MCP_EXPOSE_USER_IDENTITIES` on the API
Deployment. An explicit `api.env.MCP_EXPOSE_USER_IDENTITIES` value overrides it
without creating a duplicate environment entry. This setting does not change
project authorization.

Build links in MCP responses (`buildDetailsUrl`, and the links in MCP prompts)
point at this install's dashboard: the chart sets `MCP_BUILD_DETAILS_URL` to
`https://<dashboard host>/build`, and the server appends the invocation ID. Set
`api.env.MCP_BUILD_DETAILS_URL` to override it.

Admin access is granted when the token's groups claim (`api.jwt.groupsClaim`,
default `hermetiq/roles`) contains `publisher.hermetiqAdminGroup` (default
`hermetiq-admin`), or via `app.adminEmails`.

## IdP setup for MCP clients (Dynamic Client Registration)

MCP clients such as Claude register themselves via OAuth Dynamic Client
Registration (DCR), then request a token whose audience is the MCP resource URL.
Configure your IdP once so any DCR client is authorized automatically. Using
Auth0 as a worked example (the [Auth0 runbook](mcp-auth0-runbook.md)
has the full commands):

1. **Enable Dynamic Client Registration** on the tenant
   (`PATCH /api/v2/tenants/settings` → `flags.enable_dynamic_client_registration=true`).
2. **Register the MCP server as an API / resource server** whose identifier is
   the MCP endpoint URL, `https://mcp.<domainBase>/mcp`, and point MCP clients
   at that same URL (the install notes and the dashboard Quickstart print it).
   Auth0 matches the requested resource exactly; a mismatch yields its
   `Service not found` error.
3. **Authorize all DCR clients for that API** with a default client grant, so
   each newly registered client is authorized without a per-client step
   (DCR apps are third-party and otherwise get `Client … is not authorized to
   access resource server …`):

   ```
   POST /api/v2/client-grants
   { "default_for": "third_party_clients",
     "subject_type": "user",
     "audience": "https://mcp.<domainBase>/mcp",
     "scope": [] }
   ```

4. **Promote a login connection to domain-level**
   (`PATCH /api/v2/connections/{id}` → `is_domain_connection=true`) so
   third-party (DCR) clients can authenticate users.

Other IdPs expose equivalent concepts (DCR, an API/audience definition, and a
way to grant all dynamically-registered clients access to that audience); the
chart side is identical — point `api.jwt.*` at the issuer, and the MCP
audiences derive from the MCP host.
