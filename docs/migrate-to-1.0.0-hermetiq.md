# Migrating the Hermetiq chart to 1.0.0

This guide is for a Hermetiq release on chart `0.9.8` or earlier. A new
installation needs none of it: follow the
[chart README](../charts/hermetiq/README.md#install-prerequisites) instead. The
Hermetiq upgrade is one part of the `1.0.0` bundle cut-over; read
[Migrating to 1.0.0](migrate-to-1.0.0.md) first for the order across the
Hermetiq, BB Worker Operator and Buildbarn charts.

## What changes in 1.0.0

- **Project authorization is always enforced.** The API, publisher, and
  dashboard apply the chart's `authorization` policy, and workload environment
  maps cannot disable or replace it. A valid JWT alone no longer permits BEP
  publication: the publisher requires `write:bep` on the selected project, and
  Viewer access cannot publish builds.
  Starting with chart `1.0.1`, operators can set
  `publisher.env.ENFORCE_PUB_AUTHZ: "false"` to allow authenticated BEP callers
  to publish without project-role or credential-scope grants. Authentication
  and signed project restrictions still apply, and API/dashboard authorization
  stays enforced. This requires a publisher image newer than `v1.0.0` that
  supports disabling publishing enforcement independently; see the [publisher override](../charts/hermetiq/README.md#project-access-policy).
- **The dashboard backend-for-frontend and oauth2-proxy are required.** Browser
  API requests go through the dashboard's own origin and session.
- **`app.adminEmails` no longer grants installation administration.**
  Administrators come from a trusted group.
- **Images from `v0.9.8` and earlier are refused.** They cannot enforce the
  authorization policy or the browser flow, and the chart does not render with
  them.
- **Buildbarn configuration is read in the CDC schema only.** Hermetiq `1.0.0`
  reads and validates Buildbarn configuration in the CDC (RepMaxCDC) schema.
  It has no mode for the pre-CDC schema that Buildbarn `0.9.9` and older use,
  so upgrade the two together.
- **Worker-pool PromQL templates select pods by owner.** Custom overrides need
  the new `${poolPods}` expression; see
  [PromQL query overrides](#promql-query-overrides).

## Prepare access and images

Prepare access and compatible images before upgrading an existing
installation:

1. Use application images that support project authorization, browser authorization,
   and, when configured, SCIM and JWT profiles. Update the API, publisher, schema
   bootstrap job, dashboard, and `grpc-auth-proxy` together; keep subscribers on
   the corresponding core release. The schema bootstrap image must apply the
   authorization migrations before the new API and publisher start.
2. Preserve existing stable user IDs, issuer strings, and identity prefixes.
   Grant existing Bazel and CI principals Builder or Admin access to their
   projects through direct memberships, group bindings, or `serviceAccounts`;
   see [Project access policy](../charts/hermetiq/README.md#project-access-policy).
   For external client-credentials helpers, follow
   [External credential helpers](#external-credential-helpers).
3. Move administrators who rely on `app.adminEmails` to a trusted administrator
   group; see [Admin access](../charts/hermetiq/README.md#admin-access).
   Existing direct project Admin memberships continue to grant administration
   of those projects; they do not grant installation-wide administration.
   Confirm an administrator can still sign in and manage access.
4. Classify machine-only JWT profiles with `principalKind: service`. When humans
   and machines share a profile, register machine issuer/subject pairs explicitly
   in `authorization.serviceAccounts`. The default `principalKind: human` does
   not infer machine identity from optional provider claims.
5. Choose `authorization.defaultAccess` deliberately: `viewer` retains read
   access across projects for authenticated humans; `none` requires explicit
   membership or group grants. Service accounts receive only explicit grants.
6. Configure sign-in admission explicitly before upgrading: set
   `dashboard.oauth2Proxy.emailDomains`, and `allowedGroups` where an identity
   provider serves several organizations; see
   [Dashboard sign-in](../charts/hermetiq/README.md#dashboard-sign-in). Move
   existing `OAUTH2_PROXY_EMAIL_DOMAINS`, `OAUTH2_PROXY_ALLOWED_GROUPS` and
   `OAUTH2_PROXY_OIDC_GROUPS_CLAIM` overrides from a workload's `env` into
   those shared values; the chart rejects them in `env`.

Keep the dashboard oauth2-proxy enabled and verify dashboard sign-in, API/MCP
access, and a build published by each CI identity after the rollout.

### Images

The image settings are listed under
[Application images](../charts/hermetiq/README.md#application-images). A
nonempty digest takes precedence over the tag. When selecting an updated tag,
set its matching digest from that release or explicitly clear the previous
digest with `""`; changing only the tag keeps running the old pinned image. In
particular, JWT profile mode needs an auth-proxy image that supports
`GRPC_AUTH_PROXY_FORWARD_ONLY`; updating only the API and dashboard is
insufficient.

The chart's default images are the `v1.0.0` release, which implements these
features. Images from `v0.9.8` and earlier do not, and the chart refuses to
render with them because they cannot enforce the authorization policy or the
browser flow. Custom tags and digests are not recognised by that check; verify
them against the same application release before a staged rollout. The JWKS
refresh and file-reload controls under `publisher.jwks` and `api.jwt` also need
a matching application version.

## Upgrade

Back up PostgreSQL first: the schema bootstrap hook runs on the upgrade and
applies the authorization migrations before the workloads roll.

Once images and grants are ready, upgrade using a complete copy of your
installation values:

```bash
helm upgrade hmq oci://ghcr.io/hermetiq/hermetiq --version 1.0.0 \
  --namespace hermetiq --reset-values -f installation-values.yaml
```

Use your own release name in place of `hmq`. `installation-values.yaml` must
contain all installation-specific settings you intend to retain.
`--reset-values` loads the new chart defaults before applying those files;
avoid `--reuse-values` with pre-authorization releases, whose saved defaults
omit the new configuration blocks.

## External credential helpers

An external helper that publishes with a client-credentials token, such as an
Auth0 `grant_type: client_credentials` application, authenticates the
application named by the token's `sub`. Before upgrading a helper that
previously published with a valid token alone, grant its exact verified `iss`
and `sub` Builder access to each required project, as shown under
[External Auth0 credential helpers](../charts/hermetiq/README.md#external-auth0-credential-helpers).
Merge the entry with existing grants, then upgrade the chart and wait for the
API and publisher rollouts. Verify the helper still sends its JWT in
`Authorization: Bearer <token>` for the BEP hostname, then run a build with
the matching project selected.

## Authentication settings carried over

These keep an existing configuration working and need no change for the
upgrade:

- `publisher.jwks.source` defaults to `auto`, which preserves previously
  accepted key-source combinations. Upgrading does not start trusting a
  formerly ignored keyset; the Helm notes identify local keys shadowed by an
  inherited URL.
- Existing `api.env` and `publisher.env` overrides for
  `GRPC_AUTH_PRINCIPAL_KIND` and the four `GRPC_AUTH_JWKS_*` refresh/reload
  settings remain supported with single-issuer authentication. Remove an
  override when moving that setting into the typed `api.jwt` or
  `publisher.jwks` values.
- `principalKind` defaults to `human` for compatibility.
- `api.mcpAuthDisabled: true` remains an explicit shared-administrator option;
  it does not provide individual user authorization or revocation.

## PromQL query overrides

The packaged worker-pool CPU and memory request templates select pods through
their ReplicaSet and Deployment owners. Custom overrides of
`rbeContainerCpuRequestPercent` and `rbeContainerMemoryRequestPercent` must use
the `${poolPods}` expression in both usage and request sums, replacing the
former `${pods}` name-list matcher. Exact prior packaged defaults are upgraded
automatically by the API; refresh customized legacy keys from the packaged
file when upgrading an external ConfigMap. See
[PromQL query configuration](../charts/hermetiq/README.md#promql-query-configuration).
