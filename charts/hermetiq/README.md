# hermetiq

This chart installs Hermetiq core application resources only:

- API and BEP publisher Deployments
- one subscriber Deployment per NATS stream partition
- dashboard Deployment with optional oauth2-proxy sidecar
- schema bootstrap Job and maintenance CronJobs
- Services, HPA, ServiceAccount/RBAC, ConfigMaps, Secrets
- optional Gateway API `GRPCRoute`/`HTTPRoute`, GKE HTTPRoute-only Gateway, Contour `HTTPProxy`, or classic `Ingress` resources

It does not install Postgres, Redis/Dragonfly, NATS, VictoriaMetrics, OTEL Collector, KEDA, or Temporal.

## Required External Inputs

Provide a custom values file with:

- `postgres.*`
- `redis.*`
- `nats.url`
- `otel.*`
- `license.contactEmail` (see [Licensing](#licensing))
- `gateway.name` when the active routing provider is `gateway` or `gateway-httproute-only`
- `hosts.domainBase` or explicit hostnames
- image tags under `images.*`
- dashboard OAuth2 secret or values when `dashboard.oauth2Proxy.enabled=true`
- `publisher.trustedCalCidrs` when Buildbarn sends completed actions to
  `bep-nats-pub` (see [gRPC Authentication](#grpc-authentication)) — leaving it
  empty disables CAL ingest

Set `routing.provider` to `gateway`, `gateway-httproute-only`, `contour`, or `ingress` to choose the external routing resources. Use `gateway-httproute-only` for GKE Gateway, which supports HTTPRoute but not GRPCRoute. Use `gateway` for Envoy Gateway and other controllers that support GRPCRoute. Gateway modes expect TLS on the referenced Gateway. Contour and Ingress modes can share one wildcard TLS Secret via `tls.secretName`, or render one wildcard cert-manager `Certificate` with `tls.certificate.enabled=true`.

When `routing.provider=gateway`, `gateway.healthChecks.enabled=true` renders Envoy Gateway `BackendTrafficPolicy` resources that health-check gRPC routes with TCP and HTTP routes with unauthenticated readiness/metadata endpoints. When `routing.provider=gateway-httproute-only`, the GKE `HealthCheckPolicy` for the mixed API Service checks `GET /ready` on container port `8008`.

Set `routing.enabled=false` or `routing.provider=none` when you want the chart to render only internal Services and application resources while you supply your own Gateway, Ingress, HTTPProxy, service mesh route, or other external routing implementation. Route TLS Certificates, Envoy Gateway policies, and GKE Gateway policies are also skipped in this mode.

### gRPC route timeouts

`gateway.timeouts` sets Envoy Gateway stream timeouts on the BEP, API, and optional bbcal gRPC routes (`routing.provider=gateway` only). It is enabled by default. Without it Envoy applies its **15s default route timeout**, which made `gateway` the only routing provider this chart supports that left these routes capped by omission — Contour already applies `contour.httpProxy.responseTimeout` and GKE applies `gateway.gke.backendPolicy.timeoutSec` (both 300s) to the same backends.

The value that matters is Envoy's route-timeout semantics: it measures from **downstream end-of-stream** — the client's half-close — to the completed upstream response. So it does not cap a bidirectional stream's upload phase, but it does cap everything after the half-close, and it caps a server-streaming response in full, because those clients half-close immediately.

| Route | Default | Why |
| --- | --- | --- |
| `bepGrpc` | `requestTimeout: 0s`, `maxStreamDuration: 0s` | Bazel's BES `PublishBuildToolEventStream` is bidirectional and lives for the whole build, so the upload phase is not exposed — but the drain after Bazel half-closes is. Under the default `--bes_upload_mode=wait_for_upload_complete` Bazel blocks there waiting for the publisher to ack remaining events, and a publisher under NATS backpressure or mid-rollout can exceed 15s, surfacing as a BES upload failure at the end of an otherwise-successful build. `PublishLifecycleEvent` on the same route is unary and capped outright. Bound this with Bazel's `--bes_timeout` instead. |
| `apiGrpc` | `requestTimeout: 300s` | Unary analytics queries from the dashboard, MCP, and CLI. 15s is a plausible p99 for a wide-time-range Build History or trends query, and an Envoy reset surfaces as a generic gRPC error rather than a query timeout. Bounded rather than disabled, and 300s matches the Contour and GKE providers. |
| `bbcalGrpc` | `requestTimeout: 0s`, `maxStreamDuration: 0s` | Only rendered when `gateway.routes.bbcalGrpcEnabled=true`. This route is handed to users as their Bazel `--remote_cache` endpoint, so it carries server-streaming `ByteStream/Read`, client-streaming `ByteStream/Write`, and unary CAS/AC calls. `ByteStream/Read` is the worst case — the client half-closes immediately, so a 15s cap covers the entire blob download. Mirrors the buildbarn chart's frontend timeouts. |

`"0s"` **disables** a timeout; it does not mean "immediate". An empty string omits the field entirely, leaving Envoy's own default in place — that is how `apiGrpc.maxStreamDuration` ships.

These render into each route's existing `BackendTrafficPolicy` (the `<route>-health-check` resources) rather than new ones. That is deliberate: Envoy Gateway does not merge policies of the same kind targeting the same route at the same level — it applies the oldest by creation timestamp and marks the rest `Overridden=True` — so a separate timeouts policy would be silently dropped alongside the health check. The resource name predates the timeouts and is kept so upgrades update the policies in place. Set `gateway.timeouts.enabled=false` to restore the previous behavior; the health checks are unaffected either way.

### Tuning the downstream leg for high-RTT clients

`gateway.clientTrafficPolicy.enabled=true` renders an Envoy Gateway `ClientTrafficPolicy` (`routing.provider=gateway` only) covering the client → Envoy leg. It is disabled by default; enable it when clients are far from the cluster. Envoy Gateway's own defaults are conservative for build traffic — measured against v1.7.2 it programs a 32Ki per-connection buffer limit, a 64Ki HTTP/2 stream window, a 1Mi connection window, 100 concurrent streams, and a 1h idle timeout. The per-connection buffer limit matters most: at 32Ki, large BEP uploads and CAS blob transfer hit watermark backpressure almost immediately and every drain/refill cycle costs a full client round trip. The HTTP/2 windows are a second, independent cap, so raising only `bufferLimit` can still produce `413 request_payload_too_large`. Raising the idle timeout is what actually prevents connection churn, since Envoy's HTTP idle timeout is request-based and neither HTTP/2 PINGs nor TCP keepalives reset it.

**This is the preferred place to enable the policy.** It is Gateway-scoped rather than route-scoped, so a single policy covers every route on the target listener — this chart's BEP, API, dashboard, and MCP routes plus the buildbarn chart's CAS/AC gRPC routes when both share a Gateway. The buildbarn chart ships the same knobs under the same key for standalone Buildbarn installs; enable it in exactly **one** chart. `ClientTrafficPolicy` resources do not merge: with two targeting the same Gateway, the oldest by creation timestamp wins and the other reports `Overridden=True`. The two charts default to different policy names (`hmq-gateway-client-traffic` and `bb-gateway-client-traffic`) so an accidental double-enable is visible in policy status rather than a Helm ownership conflict.

Two caveats. `bufferLimit` is per-connection memory on the Envoy proxy, which frequently runs a single replica, so watch its RSS after enabling. And without `sectionName` the policy applies to every listener on the Gateway; scoping to one listener fully overrides a Gateway-scoped policy rather than combining with it.

Example:

```sh
helm upgrade --install hermetiq ./charts/hermetiq \
  --namespace hermetiq \
  --create-namespace \
  -f ./charts/hermetiq/examples/custom-values.yaml
```

For production installs, prefer `existingSecret` values for Postgres, Redis, OAuth2, Slack, and static JWKS material.

### Cost integration

`app.costReportTickerEnabled` is the single switch for OpenCost-backed cost
reporting. It defaults to `false`, which disables the API cost report ticker
and hides Cost Reporting, pricing cards, cost columns, and cost datasets in the
dashboard while leaving remote execution timing and action analytics enabled.
Set it to `true` only when the backend can reach the OpenCost API configured by
`app.openCostUrl`; the chart propagates the same value to both the API and
dashboard Deployments.

Worker-pool cost and behavior reporting also discovers the namespaced
`bb.hermetiq.com/v1` `RbeWorker` objects managed by bb-worker-operator. The
default `rbac.rules.rbeWorkers=true` grants the chart ServiceAccount only
`get` and `list` on `rbeworkers`. The existing RoleBinding limits that access
to the Hermetiq release namespace; worker pools in other namespaces are not
visible. Keep API token mounting enabled (the default: the API inherits
`serviceAccount.automountServiceAccountToken=true`) so grpc-api can use the
grant, or disable this rule if RbeWorker discovery is not needed.

### Licensing

`license.contactEmail` is **required** — templating fails without a
syntactically valid email address. With no license key configured, a 30-day
trial is auto-issued against that email on first boot. Trial issuance and
online key validation need egress to `license.saasUrl` (default
`https://api.cloud-usc1.hermetiq.io`) and `https://api.keygen.sh`;
`HTTPS_PROXY` is honored.

**Paid keys** go in a Secret named `hermetiq-license` under the data key
`license.key`. The chart always mounts that Secret name as an optional volume,
so creating the default-named Secret after install hot-loads the key with no
values change and no rollout:

```sh
kubectl -n hermetiq create secret generic hermetiq-license \
  --from-literal=license.key=<key>
```

For a customer-managed Secret with different names, set
`license.key.existingSecret` and `license.key.existingSecretKey` (a values
change, so it takes a `helm upgrade` and a rollout). `license.key.value` is the
inline alternative — the chart then creates the `hermetiq-license` Secret
itself. Converting a trial to a paid license happens server-side against the
same key; no cluster changes are needed.

**Air-gapped installs** set `license.airGapped=true` and must provide
`license.key.existingSecret` carrying **both** the license key and a
checked-out license file — data keys `license.key` and `license.lic` by
default (`license.key.existingSecretKey` / `license.licenseFileSecretKey`).
Trials are online-only, so `license.trial.enabled` must be `false`; the chart
refuses to render otherwise. No network calls are made in this mode.

Two RBAC grants back licensing; both default to `true`:

| Value | Grant | If disabled |
| --- | --- | --- |
| `rbac.rules.clusterFingerprint` | ClusterRole + ClusterRoleBinding with `get` on the `kube-system` Namespace **object** only (`resourceNames: [kube-system]`) — its metadata UID is the stable cluster fingerprint for license identity. It cannot list namespaces and reads nothing *inside* kube-system. | Falls back to the weaker own-namespace UID as the license identity; licensing still works. |
| `rbac.rules.licenseState` | Namespaced Role writing only the `hermetiq-license-state` Secret (the auto-issued trial key and the signed validation cache used for offline grace). | Trials do not persist across pod restarts and the offline validation cache is lost. |

Both are exercised in-pod, so hardened installs must keep
`api.automountServiceAccountToken: true` and
`publisher.automountServiceAccountToken: true`.

The status endpoint and `hermetiq_license_*` metrics expose expiry and grace
state for operator alerting. Past the grace window, `grpc-api` and
`bep-nats-pub` pods report 0/N READY on the `license` readiness check, and
restarted pods CrashLoopBackOff until a valid license is installed. No data is
deleted — ingest and API access resume where they left off. Note
`helm upgrade --wait` blocks while pods are unready. Check license status at
any time (works even while pods are unready):

```sh
kubectl -n hermetiq port-forward deploy/grpc-api 8008
curl localhost:8008/api/v1/license/status
```

### NATS Stream Configuration

The chart renders `files/config/nats_streams.json` into the
`bep-nats-stream-config` ConfigMap by default. To use an externally managed
stream and consumer config, create a ConfigMap with your JSON and point the
chart at it:

```yaml
nats:
  streamConfig:
    existingConfigMap: hermetiq-nats-stream-config
    configMapKey: nats_streams.json
    rolloutChecksum: "sha256-or-version-of-the-config"
```

The selected key is mounted to `/config/nats-streams/nats_streams.json` for
publisher and subscriber pods, so the container path stays fixed. Helm cannot
hash external ConfigMap data; update `rolloutChecksum` when the external
ConfigMap changes and the publisher/subscriber pods need a rollout.

Existing installs upgrading from the legacy single BEP stream layout need no
manual migration and no build-freeze window: subscribers adopt the legacy
`BEP_STREAM_<n>` streams and drain their remaining build-tool/progress backlog,
publishers hold ingest (returning `UNAVAILABLE`) until the subscribers have the
new topology in place, and the drained legacy streams can be retired at your
convenience with `nats stream rm BEP_STREAM_<n>` once `nats stream report`
shows them empty. Running pods notice the deletion within seconds and stop the
legacy consumer cleanly; nothing recreates it.

### Progress Log Storage

Build stdout/stderr (BEP progress events) is stored one of two ways, chosen per
project in **Project Settings**, not by a chart value:

- **Postgres (default)** — progress rows land in the partitioned
  `public.progresses` table and age out with its retention window: **hourly
  partitions kept for 2 days** (maintained by `progressesPartitionMaintenance`).
  Nothing extra to configure.
- **Cloud object storage** — enable *Store compressed invocation logs in cloud
  object storage* on the project and set its bucket/container. Subscribers then
  write progress logs directly to the bucket as compressed chunk objects and
  skip Postgres entirely, which keeps the `progresses` table small on
  high-volume installs.

Object-storage mode has three operator-side requirements:

1. **Bucket access for subscriber pods.** Subscribers use the shared chart
   ServiceAccount, so enabling `azureWorkloadIdentity` or `gcpWorkloadIdentity`
   (or otherwise granting that identity read/write on the bucket) is all the
   wiring needed. Also confirm subscriber pods have network egress to the
   storage endpoint; the Postgres-only path does not need it.
2. **A lifecycle/TTL rule on the `progress/` prefix — required.** Hermetiq never
   deletes these objects. Scope a lifecycle rule to
   `<prefix>/progress/` in the bucket's own IaC and pick the retention you want
   for build logs. Without one, objects accumulate indefinitely. Keep the rule
   scoped to that prefix so it does not also expire trace profiles stored under
   `<prefix>/<project>/<invocation>/`.
3. **Retention is now the bucket's TTL, not a database window.** Once objects
   expire, completed-build log requests return empty logs for those
   invocations, the same way they do after a `progresses` partition ages out.

Reads prefer object storage for these projects and fall back to `progresses`
rows for invocations that have no objects, so invocations from before the
setting was enabled stay readable. If the bucket is unreachable, subscribers
keep ingesting by writing progress rows to Postgres rather than dropping
events; watch `hermetiq_progress_chunk_flush_total{outcome="spilled"}` and treat
a sustained rate as a storage problem to fix.

#### How long build logs stay available

Progress logs are now served from exactly these two places, so **how long users
can open a completed build's logs is set by whichever mode the project uses**:

| Mode | Log retention |
|------|---------------|
| Postgres (default) | 2 days — the `public.progresses` partition window |
| Cloud object storage | Whatever age your bucket lifecycle rule uses |

Two consequences worth planning for before upgrading:

- Earlier versions also kept a separate 30-day compressed copy of each build's
  logs in the `public.logs` table, written by a background compression ticker.
  That ticker is gone and the table is no longer read or written, so after the
  upgrade logs for builds older than the windows above return empty. New builds
  are unaffected. The table itself is left in place — you can drop it once you
  no longer need its historical contents. The schema bootstrap Job raises
  `public.progresses` retention from the previous 8 hours to 2 days as part of
  this upgrade, so plan for roughly 6x the progress-row volume on disk.
- If you want log retention beyond 2 days, enable cloud object storage for the
  project and set the bucket lifecycle rule accordingly. To instead keep logs in
  Postgres for longer, raise the retention on the `public.progresses` parent in
  pg_partman (`UPDATE public.part_config SET retention = '<interval>' WHERE
  parent_table = 'public.progresses';`) and size the database for it — progress
  rows are the highest-volume table Hermetiq writes.

Chunk sizing is tuned by three optional `subscriber.env` variables — defaults
suit typical CI volumes and rarely need changing:
`PROGRESS_BLOB_CHUNK_FLUSH_INTERVAL` (default `20s`; also the delay before a
running build's newest output appears in live log tailing),
`PROGRESS_BLOB_CHUNK_MAX_BYTES` (default `262144`), and
`PROGRESS_BLOB_CHUNK_MAX_EVENTS` (default `1000`).

### Invocation Start Event Mode

`app.invocationStartEvent` defaults to **`build_tool`**: invocations are
created from BEP build-tool events (with the lifecycle start rerouted onto the
build-tool stream as an early-creation signal) and **no `BEP_LIFECYCLE_*`
streams are provisioned or required** — the packaged `nats_streams.json`
deliberately contains no lifecycle configuration.

The `"lifecycle"` value is a legacy mode retained for existing non-chart
deployments and is slated for removal; chart deployments should not use it.
If you believe you need it, it additionally requires lifecycle stream
configuration via an externally managed stream config — contact Hermetiq
first.

The value is rendered into the shared env ConfigMap so the publisher and
subscriber always agree — running the two sides in different modes is
unsupported. When changing the mode on a live deployment, upgrade during a
quiet period: invocations that start while the rollout is mixing modes can
otherwise end up with duplicate rows until retention clears them.

### OIDC Provider

Set the OIDC issuer URL once at the top level and the chart wires it through `api.jwt.issuer`, `api.jwt.jwksUrl`, `publisher.jwks.issuer`, `publisher.jwks.url`, and `dashboard.oauth2Proxy.oidcIssuerUrl`. JWKS URLs default to `<issuerUrl>.well-known/jwks.json`. Per-component values still win when set, so anything can be overridden individually.

```yaml
oidc:
  issuerUrl: https://<tenant>.auth0.com/
```

This feeds the core's `GRPC_AUTH_*` settings — see
[gRPC Authentication](#grpc-authentication) for what the core now requires, and
for the audiences and CAL CIDRs the issuer cannot supply.

### gRPC Authentication

**Authentication now happens in the bep-nats core process, not in the
`grpc-auth-proxy` sidecar.** The core reads a `GRPC_AUTH_*` environment family
and verifies bearer tokens itself for the gRPC API, the BEP/CAL ingest
endpoints, and the MCP endpoint. The legacy `JWKS_*` variables were removed
from the application outright — there are **no aliases**, so a pod that still
receives only the old names authenticates nothing and fails closed.

Three consequences shape how this chart is configured now:

| Was | Is |
| --- | --- |
| The sidecar verified the JWT and injected `X-Forwarded-User`; the core trusted it. | The core strips `X-Forwarded-User` and every other caller-supplied identity header **before** authenticating. The api pods keep the sidecar, but only for gRPC-web framing and CORS. |
| An unset issuer or audience meant "accept any". | `GRPC_AUTH_ISSUER` and `GRPC_AUTH_AUDIENCE` are **mandatory** for the `jwks` provider. The chart fails at template time rather than letting a pod CrashLoopBackOff. |
| Buildbarn CAL calls arrived unauthenticated. | CAL is admitted only by network position, via `publisher.trustedCalCidrs`. **Empty disables CAL ingest** — see below. |

`app.grpcAuthUserProvider` (default `jwks`, the on-prem value) is required on every
core that serves gRPC; the process refuses to start without it. There is no
"off" setting — selecting the provider is what turns verification on. For each
core, choose exactly one configuration mode:

1. **Chart-managed (default):** keep `api.jwt.enabled=true` and
   `publisher.jwks.enabled=true`, then configure their issuer/JWKS/audience
   values (the issuer and JWKS URL can derive from `oidc.issuerUrl`).
2. **Custom environment:** set the component's `enabled=false` and put a
   complete contract in `api.env` or `publisher.env`: exactly one non-empty
   `GRPC_AUTH_JWKS_URL`, `GRPC_AUTH_JWKS_FILE`, or `GRPC_AUTH_JWKS_INLINE`, plus
   non-empty `GRPC_AUTH_ISSUER` and `GRPC_AUTH_AUDIENCE`.

The chart validates both modes and refuses to render an incomplete core. It
also rejects mixing those required variables into `*.env` while chart-managed
mode is enabled, because that would create duplicate or multiple-source env
entries. `GRPC_AUTH_USER_PROVIDER` is never a custom-env override; set it only
through `app.grpcAuthUserProvider`.

A deployment that previously ran with JWT auth disabled must now use one of
these two modes. Custom env values may be literal scalars or Helm `tpl`
expressions; those are the only overrides validation can reliably inspect.

#### Buildbarn Completed Action Logger — required for CAL ingest

Buildbarn workers stream completed actions to `bep-nats-pub:50091` directly and
present no user credential, so network position is the only thing that can admit
them. `publisher.trustedCalCidrs` is a comma-separated CIDR list (bare IPs
allowed) of the peers permitted to do so, rendered as
`GRPC_AUTH_TRUSTED_CAL_CIDRS` on the publisher core only.

> ⚠ **Leaving `publisher.trustedCalCidrs` empty disables CAL ingest.** The
> exemption fails closed: with no trusted peers, every CAL call is rejected with
> `UNAUTHENTICATED` and remote-execution action telemetry silently stops
> arriving. There is no default the chart can guess, so it ships empty.

Set it to the cluster's pod CIDR, or the narrower range the Buildbarn workers
run in:

```yaml
publisher:
  trustedCalCidrs: "10.244.0.0/16"
```

`GRPC_AUTH_TRUSTED_XFCC_CIDRS` (peers allowed to assert
`x-forwarded-client-cert`) is deliberately never set: nothing in this chart
terminates mTLS in front of bep-nats, so client-cert identities stay fail-closed.

#### Legacy environment mapping

| Removed | Replacement | Notes |
| --- | --- | --- |
| `JWKS_AUTH_ENABLED` | *(none)* | `GRPC_AUTH_USER_PROVIDER=jwks` is what turns JWKS on. |
| `JWKS_URL` | `GRPC_AUTH_JWKS_URL` | Exactly one JWKS source must be set. |
| `JWKS_KEY_FILE` | `GRPC_AUTH_JWKS_FILE` | Used by the publisher when no JWKS URL resolves. |
| `JWKS_KEYS` | `GRPC_AUTH_JWKS_INLINE` | |
| `JWKS_ISSUER` | `GRPC_AUTH_ISSUER` | Now **required**; unset used to mean no issuer check. |
| `JWKS_AUDIENCE` | `GRPC_AUTH_AUDIENCE` | Now **required**, and now a **comma-separated list**. |
| `JWKS_GROUPS_CLAIM` | `GRPC_AUTH_GROUPS_CLAIM` | Still read as `JWKS_GROUPS_CLAIM` by the sidecar. |
| *(new)* | `GRPC_AUTH_USER_PROVIDER` | Required. `jwks` on-prem. |
| *(new)* | `GRPC_AUTH_TRUSTED_CAL_CIDRS` | Empty disables CAL ingest. |

The sidecar's own `JWT_*` variables are unchanged — that binary was not modified.

### MCP Authentication

The MCP server runs inside the `api` container and is authenticated by the same
core verifier as the gRPC API. Turn it on with `api.jwt.enabled=true`; the chart
then derives everything else from `oidc.issuerUrl` and the MCP host:

- `GRPC_AUTH_JWKS_URL` / `GRPC_AUTH_ISSUER` ← `oidc.issuerUrl` (or `api.jwt.*` overrides)
- `GRPC_AUTH_AUDIENCE` ← **both** the MCP resource URL (`mcpResourceUrl`, default
  `https://mcp.<domainBase>`) — under RFC 8707 the resource *is* the token
  audience — **and** the gRPC API audience, joined with a comma. One process now
  authenticates both callers and they carry different audiences, so a token
  matching either entry is accepted
- `MCP_AUTHORIZATION_SERVER` ← the OIDC issuer (trailing slash stripped)
- `GRPC_AUTH_GROUPS_CLAIM` ← `api.jwt.groupsClaim`

The gRPC API half of that audience list is `api.jwt.audience` when set, and
otherwise the dashboard oauth2-proxy client ID. That client ID lives in a Secret,
so the chart injects it as `GRPC_AUTH_AUDIENCE_CLIENT_ID` and interpolates it
into the list with the kubelet's `$(VAR)` expansion — the rendered value reads
`https://mcp.<domainBase>,$(GRPC_AUTH_AUDIENCE_CLIENT_ID)`. If you disable the
dashboard oauth2-proxy, set `api.jwt.audience` explicitly; the chart refuses to
render otherwise, because the list would carry only the MCP audience and every
gRPC API token would be rejected.

Without these the MCP server falls back to claims-based auth mode and rejects
every bearer token with `JWT verification requires JWKS auth in claims-based
auth mode`. The minimal configuration is just the issuer, the host, and the
toggle:

```yaml
oidc:
  issuerUrl: https://<tenant>.auth0.com/
hosts:
  domainBase: example.com            # MCP server is mcp.example.com
api:
  jwt:
    enabled: true
    groupsClaim: hermetiq/roles
```

You do **not** set the MCP audience: it derives from the MCP host, and the
verifier compares audiences with trailing slashes normalized, so it matches
whether or not the client appends a slash to the resource. `api.jwt.audience`
sets the **gRPC API** audience (dashboard/web traffic) and is added alongside the
MCP one — leave it unset to reuse the dashboard oauth2-proxy client ID, or set it
when the gRPC API needs a specific audience. Override the derived MCP defaults
only when needed, via `api.mcpResourceUrl` (resource/audience) and
`api.mcpAuthorizationServer` (advertised authorization server).

Admin access is granted when the token's groups claim (`api.jwt.groupsClaim`,
default `hermetiq/roles`) contains `publisher.hermetiqAdminGroup` (default
`hermetiq-admin`), or via `app.adminEmails`.

#### IdP setup for MCP clients (Dynamic Client Registration)

MCP clients such as Claude register themselves via OAuth Dynamic Client
Registration (DCR), then request a token whose audience is the MCP resource URL.
Configure your IdP once so any DCR client is authorized automatically. Using
Auth0 as a worked example:

1. **Enable Dynamic Client Registration** on the tenant
   (`PATCH /api/v2/tenants/settings` → `flags.enable_dynamic_client_registration=true`).
2. **Register the MCP server as an API / resource server** whose identifier is
   the MCP resource URL — exactly as the client requests it, including the
   trailing slash (e.g. `https://mcp.<domainBase>/`). A mismatch yields Auth0's
   `Service not found` error.
3. **Authorize all DCR clients for that API** with a default client grant, so
   each newly registered client is authorized without a per-client step
   (DCR apps are third-party and otherwise get `Client … is not authorized to
   access resource server …`):

   ```
   POST /api/v2/client-grants
   { "default_for": "third_party_clients",
     "subject_type": "user",
     "audience": "https://mcp.<domainBase>/",
     "scope": [] }
   ```

4. **Promote a login connection to domain-level**
   (`PATCH /api/v2/connections/{id}` → `is_domain_connection=true`) so
   third-party (DCR) clients can authenticate users.

Other IdPs expose equivalent concepts (DCR, an API/audience definition, and a
way to grant all dynamically-registered clients access to that audience); the
chart side is identical — point `api.jwt.*` at the issuer and set the audience
to the MCP resource URL.

### Publisher Static Auth-Proxy User Fallback

> ⚠ **This fallback no longer authenticates anything.** The core strips
> `X-Forwarded-User` — along with every other caller-supplied identity header —
> before it authenticates, so the static user the sidecar injects is discarded
> and the request reaches the authenticator with no credential. Publisher pods
> configured this way reject BEP ingest. Move to `publisher.jwks` against a real
> IdP, or supply the `GRPC_AUTH_*` variables through `publisher.env`. The values
> are retained only so existing installs can upgrade without a values rewrite.

For on-prem publisher deployments that cannot provide a JWT/OIDC auth mechanism, leave `publisher.jwks.enabled=false` and set `publisher.authProxy.staticForwardedUser` in your custom values file. The chart adds a `grpc-auth-proxy` sidecar in front of `bep-nats-pub`, routes the publisher Service to the sidecar, and the proxy uses this value as `X-Forwarded-User` only for requests without a user JWT.

```yaml
publisher:
  replicas: 1
  resources:
    requests:
      cpu: 500m
      memory: 1000Mi
    limits:
      cpu: 1900m
      memory: 4000Mi
  authProxy:
    staticForwardedUser: "some-on-prem-user-id"
  jwks:
    enabled: false
```

### Admin Emails

Set `app.adminEmails` to grant the Hermetiq admin role to users by email. The chart joins the YAML list into the comma-delimited `ADMIN_EMAIL_ALLOWLIST` env var used by the app.

```yaml
app:
  adminEmails:
    - admin@example.com
    - ops@example.com
```

### oauth2-proxy

When dashboard OAuth is enabled, the chart renders `oauth2-proxy-config-web-ui` as reusable provider/session configuration. Deployment-specific oauth2-proxy values such as `OAUTH2_PROXY_REDIRECT_URL` and `OAUTH2_PROXY_UPSTREAMS` are set directly on the dashboard sidecar so other web UI sidecars can reuse the ConfigMap.

`OAUTH2_PROXY_WHITELIST_DOMAINS` is auto-populated with `.<hosts.domainBase>` so `rd` redirects to chart-rendered services (dashboard, browser, grafana, ...) work without extra config. Add external domains via `dashboard.oauth2Proxy.whitelistDomains`.

Set `dashboard.oauth2Proxy.backendLogoutUrl` to chain a redirect to the IdP's logout endpoint after oauth2-proxy clears its cookie. Without it, signing out only clears the local cookie and the still-active IdP session silently re-authenticates the user. Auth0 example:

```yaml
dashboard:
  oauth2Proxy:
    backendLogoutUrl: https://<tenant>.auth0.com/v2/logout?client_id=<clientId>&returnTo=https://dashboard.<domainBase>
```

The `returnTo` host must be added to Auth0's "Allowed Logout URLs" application setting. The buildbarn browser oauth2-proxy reuses this ConfigMap, so logout chains through the same IdP for both UIs.

### Dashboard Quickstart Customization

The dashboard Quickstart page renders Bazel remote caching instructions from
`dashboard.remoteCacheUrl`. Leave it empty for the default on-prem Buildbarn
frontend convention, `grpcs://bb.<hosts.domainBase>`, or set it explicitly when
Buildbarn uses a separate domain or an overridden frontend gRPC host:

```yaml
dashboard:
  remoteCacheUrl: grpcs://bb.example.com
```

The dashboard reads optional static Quickstart customization from `/quickstart-config/quickstart-config.json`. Only Step 1 is customizable. Use `dashboard.quickstartConfig.data` for inline chart-managed JSON:

```yaml
dashboard:
  quickstartConfig:
    data:
      step1:
        title: Install Your Company Credential Helper
        bullets:
          - Obtain the credential helper script from your platform administrator.
          - - text: "Save it under "
            - code: "%workspace%/tools"
        downloads:
          bash: false
          python: false
        actions:
          - label: Open Internal Helper Docs
            href: https://docs.example.com/hermetiq/credential-helper
        warning:
          title: Security Warning
          paragraphs:
            - Do not commit credential helper scripts or generated credentials.
```

Or mount an externally managed ConfigMap:

```yaml
dashboard:
  quickstartConfig:
    existingConfigMap: web-ui-quickstart-config
    configMapKey: quickstart-config.json
```

`existingConfigMap` and `data` are mutually exclusive. The dashboard ignores unknown fields and never renders raw HTML from this file.

### Cache TTL Configuration

The API reads cache TTL settings from `/config/cache-ttl/cache_ttl.json`. By default, the chart renders `files/config/cache_ttl.json` into the `bep-cache-ttl-config` ConfigMap. To override it with an externally managed ConfigMap, provide the ConfigMap name and key:

```yaml
cacheTtl:
  existingConfigMap: hermetiq-cache-ttl-config
  configMapKey: cache_ttl.json
  rolloutChecksum: "sha256-or-version-of-the-config"
```

The selected key is always mounted to `/config/cache-ttl/cache_ttl.json`, so the API container path does not change. Helm cannot hash data from an external ConfigMap; update `rolloutChecksum` when the ConfigMap contents change and the API pods need a rollout.

#### Grafana

Grafana is installed by the VictoriaMetrics chart before Hermetiq, so it can't take an oauth2-proxy sidecar. Instead, when `grafana.oauth2Proxy.enabled=true` (default), the chart renders a standalone `grafana-oauth2-proxy` Deployment + Service that proxies to the upstream Grafana service (`gateway.routes.grafanaService`, default `vm-grafana`), and re-targets the Grafana route at it. The proxy reuses the shared `oauth2-proxy-config-web-ui` ConfigMap and `oauth2-proxy-client` Secret, so it shares an SSO session with the dashboard and buildbarn browser.

Two things to configure outside this chart:

1. Register `https://grafana.<domainBase>/oauth2/callback` as an allowed callback URL with your IdP.
2. Configure Grafana to trust the proxy headers. In the VictoriaMetrics chart's grafana values:

   ```yaml
   grafana:
     grafana.ini:
       auth.proxy:
         enabled: true
         header_name: X-Auth-Request-Email
         header_property: email
         auto_sign_up: true
   ```

The schema bootstrap Job is a Helm hook by default. It runs on both install and upgrade so schema migrations are applied before workloads roll forward. Keep `postgres.password.existingSecret` set in hook mode, because pre-install hooks run before normal chart-managed Secrets are created. Successful hook Jobs are kept by default for log inspection and are deleted before the next install or upgrade hook creates a fresh Job. If you want the chart to create the Postgres Secret from `postgres.password.value`, set `bootstrap.hook.enabled=false`.

When `bootstrap.projectName` is set, the bootstrap job creates the default project and managed Buildbarn namespace entry. Set `bootstrap.projectId` to pin the default project ID; leave it empty to let dbadmin generate a UUID. `bootstrap.projectNamespace` defaults to the Helm release namespace, which fits installs where Buildbarn is deployed alongside Hermetiq; set it explicitly when Buildbarn lives in a different namespace. Provide `bootstrap.namespaceBrowserUrl` and `bootstrap.namespaceDashboardUrl` with the user-facing Buildbarn Browser and dashboard URLs to store on that managed namespace.

## Kubernetes Node Scheduling

Set top-level defaults with `k8sNodeScheduling`:

```yaml
k8sNodeScheduling:
  nodeSelector:
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
  tolerations: []
```

Set `nodeSelector` or `tolerations` under an individual workload to override the top-level values. Supported workload keys include `api`, `publisher`, `subscriber`, `dashboard`, `bootstrap`, `partitionMaintenance`, `progressesPartitionMaintenance`, and `targetTrendsRefresh`.
