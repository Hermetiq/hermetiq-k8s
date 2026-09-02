# Hermetiq Helm Chart

This README is the operator reference packaged with the Hermetiq `0.9.0`
chart. Use the repository's
[installation guide](https://github.com/Hermetiq/hermetiq-k8s#readme) for the
full-stack deployment order and external dependency installation.

## Contents

- [Chart scope](#chart-scope)
- [Install](#install)
- [Required external inputs](#required-external-inputs)
- [Routing](#routing)
  - [Providers](#providers)
  - [Hosts](#hosts)
  - [Envoy Gateway policies](#envoy-gateway-policies)
  - [gRPC route timeouts](#grpc-route-timeouts)
  - [Tuning the downstream leg for high-RTT clients](#tuning-the-downstream-leg-for-high-rtt-clients)
- [Integrations and workload discovery](#integrations-and-workload-discovery)
  - [Cost integration](#cost-integration)
  - [Cache-event analytics](#cache-event-analytics)
  - [Metrics-backed infrastructure tools](#metrics-backed-infrastructure-tools)
  - [Kubernetes workload discovery](#kubernetes-workload-discovery)
- [Licensing and trials](#licensing-and-trials)
  - [Required contact and online trial](#required-contact-and-online-trial)
  - [Paid license keys](#paid-license-keys)
  - [Air-gapped licenses](#air-gapped-licenses)
  - [Licensing RBAC](#licensing-rbac)
  - [Status and expiry](#status-and-expiry)
- [NATS ingest and stream configuration](#nats-ingest-and-stream-configuration)
  - [Stream configuration](#stream-configuration)
- [Progress log storage](#progress-log-storage)
  - [Retention and sizing](#retention-and-sizing)
- [Authentication and SSO](#authentication-and-sso)
  - [OIDC provider](#oidc-provider)
  - [gRPC authentication](#grpc-authentication)
  - [MCP Authentication](#mcp-authentication)
  - [Unsupported static publisher identity](#unsupported-static-publisher-identity)
  - [Admin Emails](#admin-emails)
  - [oauth2-proxy](#oauth2-proxy)
  - [Grafana SSO](#grafana-sso)
- [Dashboard configuration](#dashboard-configuration)
  - [Quickstart customization](#quickstart-customization)
- [External configuration ConfigMaps](#external-configuration-configmaps)
  - [Cache TTL configuration](#cache-ttl-configuration)
  - [PromQL query configuration](#promql-query-configuration)
- [PostgreSQL and schema management](#postgresql-and-schema-management)
  - [Bootstrap job](#bootstrap-job)
  - [Partition policy and maintenance](#partition-policy-and-maintenance)
- [Scheduling, availability, and hardening](#scheduling-availability-and-hardening)
  - [Node scheduling](#node-scheduling)
  - [Pod disruption budgets and anti-affinity](#pod-disruption-budgets-and-anti-affinity)
  - [ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac)
  - [Workload identity](#workload-identity)
  - [Additional environment variables](#additional-environment-variables)
- [Verification](#verification)
- [Operations](#operations)
  - [Inspect Pods and logs](#inspect-pods-and-logs)
  - [Pause and resume subscribers](#pause-and-resume-subscribers)
  - [Inspect database partitions](#inspect-database-partitions)
  - [Inspect NATS and the dead-letter queue](#inspect-nats-and-the-dead-letter-queue)
  - [Temporary image overrides](#temporary-image-overrides)
  - [Rotate Secrets](#rotate-secrets)
- [Local chart development](#local-chart-development)

## Chart scope

This chart installs Hermetiq core application resources only:

- API and BEP publisher Deployments
- one subscriber Deployment per NATS stream partition
- dashboard Deployment with optional oauth2-proxy sidecar
- schema bootstrap Job and maintenance CronJobs
- Services, HPA, ServiceAccount/RBAC, ConfigMaps, Secrets
- optional Gateway API `GRPCRoute`/`HTTPRoute`, GKE HTTPRoute-only Gateway, Contour `HTTPProxy`, or classic `Ingress` resources

It does not install Postgres, Redis/Dragonfly, NATS, VictoriaMetrics, OTEL Collector, or KEDA.

## Install

Customer installations should use the pinned OCI release:

```bash
helm upgrade --install --namespace hermetiq hmq \
  oci://ghcr.io/hermetiq/hermetiq \
  --version 0.9.0 \
  --values hermetiq-values.yaml
```

Use a customer-managed Secret for Postgres, Redis, OAuth2, Slack, license, and
static JWKS material in production. Inline secret values are useful for local
rendering but put sensitive data into Helm release state.

Inspect the exact packaged defaults and schema before creating overrides:

```bash
helm show values oci://ghcr.io/hermetiq/hermetiq --version 0.9.0
helm show readme oci://ghcr.io/hermetiq/hermetiq --version 0.9.0
```

## Required external inputs

Provide a custom values file with:

- the PostgreSQL endpoint, database, user, and password Secret under `postgres.*`
- the Redis/Dragonfly endpoint and password Secret under `redis.*`
- `nats.url`
- the OpenTelemetry endpoint under `otel.*`
- `license.contactEmail` (see [Licensing and trials](#licensing-and-trials))
- `gateway.name` when the active routing provider is `gateway` or `gateway-httproute-only`
- `hosts.domainBase` or explicit hostnames
- `oidc.issuerUrl` plus `publisher.jwks.audience` for chart-managed JWKS
- dashboard OAuth2 secret or values when `dashboard.oauth2Proxy.enabled=true`
- `publisher.trustedCalCidrs` when Buildbarn sends completed actions to
  `bep-nats-pub` (see [gRPC Authentication](#grpc-authentication)) — leaving it
  empty disables CAL ingest

## Routing

### Providers

Set `routing.provider` to `gateway`, `gateway-httproute-only`, `contour`, or `ingress` to choose the external routing resources. Use `gateway-httproute-only` for GKE Gateway, which supports HTTPRoute but not GRPCRoute. Use `gateway` for Envoy Gateway and other controllers that support GRPCRoute. Gateway modes expect TLS on the referenced Gateway. Contour and Ingress modes can share one wildcard TLS Secret via `tls.secretName`, or render one wildcard cert-manager `Certificate` with `tls.certificate.enabled=true`. Set `tls.certificate.issuerRef.name` to an existing `ClusterIssuer` when enabling the Certificate; the chart refuses to render without it.

When `routing.provider=gateway`, `gateway.healthChecks.enabled=true` renders Envoy Gateway `BackendTrafficPolicy` resources that health-check gRPC routes with TCP and HTTP routes with unauthenticated readiness/metadata endpoints. When `routing.provider=gateway-httproute-only`, the GKE `HealthCheckPolicy` for the mixed API Service checks `GET /ready` on container port `8008`.

Set `routing.enabled=false` or `routing.provider=none` when you want the chart to render only internal Services and application resources while you supply your own Gateway, Ingress, HTTPProxy, service mesh route, or other external routing implementation. Route TLS Certificates, Envoy Gateway policies, and GKE Gateway policies are also skipped in this mode.

The chart does not create the Gateway itself. Create the Gateway/listener, DNS,
and TLS infrastructure before installing this release. Set `gateway.name` and,
when needed, `gateway.namespace` and listener `sectionName` values to the
Gateway that should accept the chart's routes.

### Hosts

External hostnames derive from `hosts.domainBase`. Override any of them
individually when your naming scheme differs, and do not use template
expressions in `hosts.*`.

| Default host | Value | Purpose |
|---|---|---|
| `dashboard.<domainBase>` | `hosts.dashboard` | Hermetiq dashboard (`web-ui`) |
| `bep.<domainBase>` | `hosts.bepGrpc` | BEP ingest gRPC endpoint that Bazel streams build events to |
| `api.<domainBase>` | `hosts.apiGrpc` | Hermetiq gRPC API |
| `api-web.<domainBase>` | `hosts.api` | Hermetiq web/REST API |
| `mcp.<domainBase>` | `hosts.mcp` | Hermetiq MCP server |
| `grafana.<domainBase>` | `hosts.grafana` | Grafana behind the SSO proxy; rendered when `gateway.routes.grafanaEnabled=true` |
| `bbcal.<domainBase>` | `hosts.bbcalGrpc` | Optional Bazel remote-cache endpoint served by the Hermetiq API; rendered when `gateway.routes.bbcalGrpcEnabled=true` |

Register OIDC callback URLs, DNS records, and TLS certificates for these hosts
before installing.

### Envoy Gateway policies

`routing.provider=gateway` renders Envoy Gateway `gateway.envoyproxy.io`
resources alongside the standard routes: `BackendTrafficPolicy` for health
checks and timeouts, `SecurityPolicy` for CORS, and the optional
`ClientTrafficPolicy`. On a `GRPCRoute`-capable controller that is not Envoy
Gateway those kinds do not exist and the install fails on unknown kinds.
Disable them:

```yaml
gateway:
  cors:
    enabled: false
  timeouts:
    enabled: false
  healthChecks:
    enabled: false
  clientTrafficPolicy:
    enabled: false
```

Without the timeout policies, whatever default route timeout your controller
applies governs long-lived gRPC streams; check that it does not truncate BES
uploads.

### gRPC route timeouts

`gateway.timeouts` sets Envoy Gateway stream timeouts on the BEP, API, and optional bbcal gRPC routes (`routing.provider=gateway` only). It is enabled by default. Without it Envoy applies its **15s default route timeout**, which made `gateway` the only routing provider this chart supports that left these routes capped by omission — Contour already applies `contour.httpProxy.responseTimeout` and GKE applies `gateway.gke.backendPolicy.timeoutSec` (both 300s) to the same backends.

The value that matters is Envoy's route-timeout semantics: it measures from **downstream end-of-stream** — the client's half-close — to the completed upstream response. So it does not cap a bidirectional stream's upload phase, but it does cap everything after the half-close, and it caps a server-streaming response in full, because those clients half-close immediately.

| Route | Default | Why |
| --- | --- | --- |
| `bepGrpc` | `requestTimeout: 0s`, `maxStreamDuration: 0s` | Bazel's BES `PublishBuildToolEventStream` is bidirectional and lives for the whole build, so the upload phase is not exposed — but the drain after Bazel half-closes is. Under the default `--bes_upload_mode=wait_for_upload_complete` Bazel blocks there waiting for the publisher to ack remaining events, and a publisher under NATS backpressure or mid-rollout can exceed 15s, surfacing as a BES upload failure at the end of an otherwise-successful build. `PublishLifecycleEvent` on the same route is unary and capped outright. Bound this with Bazel's `--bes_timeout` instead. |
| `apiGrpc` | `requestTimeout: 300s` | Unary analytics queries from the dashboard, MCP, and CLI. 15s is a plausible p99 for a wide-time-range Build History or trends query, and an Envoy reset surfaces as a generic gRPC error rather than a query timeout. Bounded rather than disabled, and 300s matches the Contour and GKE providers. |
| `bbcalGrpc` | `requestTimeout: 0s`, `maxStreamDuration: 0s` | Only rendered when `gateway.routes.bbcalGrpcEnabled=true`. This route is handed to users as their Bazel `--remote_cache` endpoint, so it carries server-streaming `ByteStream/Read`, client-streaming `ByteStream/Write`, and unary CAS/AC calls. `ByteStream/Read` is the worst case — the client half-closes immediately, so a 15s cap covers the entire blob download. Mirrors the buildbarn chart's frontend timeouts. |

`"0s"` **disables** a timeout; it does not mean "immediate". An empty string omits the field entirely, leaving Envoy's own default in place — that is how `apiGrpc.maxStreamDuration` ships.

These render into each route's existing `BackendTrafficPolicy` (the
`<route>-health-check` resources) rather than new ones. Envoy Gateway does not
merge policies of the same kind targeting the same route at the same level: it
applies the oldest and marks the rest `Overridden=True`. Set
`gateway.timeouts.enabled=false` to omit chart-managed timeout policy while
leaving health checks enabled.

### Tuning the downstream leg for high-RTT clients

`gateway.clientTrafficPolicy.enabled=true` renders an Envoy Gateway `ClientTrafficPolicy` (`routing.provider=gateway` only) covering the client → Envoy leg. It is disabled by default; enable it when clients are far from the cluster. Envoy Gateway's own defaults are conservative for build traffic — measured against v1.7.2 it programs a 32Ki per-connection buffer limit, a 64Ki HTTP/2 stream window, a 1Mi connection window, 100 concurrent streams, and a 1h idle timeout. The per-connection buffer limit matters most: at 32Ki, large BEP uploads and CAS blob transfer hit watermark backpressure almost immediately and every drain/refill cycle costs a full client round trip. The HTTP/2 windows are a second, independent cap, so raising only `bufferLimit` can still produce `413 request_payload_too_large`. Raising the idle timeout is what actually prevents connection churn, since Envoy's HTTP idle timeout is request-based and neither HTTP/2 PINGs nor TCP keepalives reset it.

**This is the preferred place to enable the policy.** It is Gateway-scoped rather than route-scoped, so a single policy covers every route on the target listener — this chart's BEP, API, dashboard, and MCP routes plus the buildbarn chart's CAS/AC gRPC routes when both share a Gateway. The buildbarn chart ships the same knobs under the same key for standalone Buildbarn installs; enable it in exactly **one** chart. `ClientTrafficPolicy` resources do not merge: with two targeting the same Gateway, the oldest by creation timestamp wins and the other reports `Overridden=True`. The two charts default to different policy names (`hmq-gateway-client-traffic` and `bb-gateway-client-traffic`) so an accidental double-enable is visible in policy status rather than a Helm ownership conflict.

Two caveats. `bufferLimit` is per-connection memory on the Envoy proxy, which
frequently runs a single replica, so watch its RSS after enabling. And without
`sectionName` the policy applies to every listener on the Gateway; scoping to
one listener fully overrides a Gateway-scoped policy rather than combining
with it.

## Integrations and workload discovery

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

### Cache-event analytics

`app.cacheEventsEnabled` sets `CACHE_EVENTS_ENABLED` on the API and defaults
to `false`. Set it to `true` only when the Buildbarn frontend runs the Hermetiq
grpc-cache-proxy sidecar and that sidecar publishes Action Cache hit and miss
events to the NATS this chart uses. The sidecar's `cacheEvents.numShards` must
equal `app.streamPartitionCount`, because events published to a shard subject
nothing consumes are discarded. Then enable **Action Cache Hit Tracker** in the
project's settings. Sidecar configuration lives in the Buildbarn chart
reference.

### Metrics-backed infrastructure tools

`victoriaMetrics.metricsEnabled` defaults to `false`. Enable it only when the
API can reach the configured VictoriaMetrics read endpoint. When disabled, the
five PromQL-backed Buildbarn health tools and the two VictoriaLogs-backed tools
are not registered; the remaining MCP tools are unaffected.

Set `app.victoriaLogsEnabled=true` only when VictoriaLogs is deployed and
reachable. `victoriaMetrics.projectLabelEnabled` controls whether the packaged
PromQL selectors include `hermetiq_project_id`. Keep it `false` for a
self-managed, single-tenant Buildbarn that does not emit that label; enable it
for Hermetiq-managed Buildbarn metrics that are scoped by project.

### Kubernetes workload discovery

The API's Buildbarn diagnostics inspect namespaced Deployments, StatefulSets,
and ConfigMaps. The default `rbac.rules.deployments=true` and
`rbac.rules.configMaps=true` grants are read-only (`get` and `list`) and are
bound with a namespaced RoleBinding. They cannot read another namespace,
Secrets, or modify resources.

Disabling these grants leaves metrics queries available but removes the
installed-component inventory and Buildbarn configuration context from MCP
diagnostics. The API needs a mounted ServiceAccount token to use workload and
`RbeWorker` discovery.

## Licensing and trials

### Required contact and online trial

`license.contactEmail` is **required** — templating fails without a
syntactically valid email address. With no license key configured, a 30-day
trial is auto-issued against that email on first boot. Trial issuance and
online key validation need egress to `license.saasUrl` (default
`https://api.cloud-usc1.hermetiq.io`) and `https://api.keygen.sh`;
`HTTPS_PROXY` is honored.

Trial licenses are issued per cluster fingerprint. Deleting the release or
namespace does not create a fresh trial for the same cluster. Validation is
off the request path and cached so transient licensing-service outages do not
interrupt requests.

### Paid license keys

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

### Air-gapped licenses

**Air-gapped installs** set `license.airGapped=true` and must provide
`license.key.existingSecret` carrying **both** the license key and a
checked-out license file — data keys `license.key` and `license.lic` by
default (`license.key.existingSecretKey` / `license.licenseFileSecretKey`).
Trials are online-only, so `license.trial.enabled` must be `false`; the chart
refuses to render otherwise. No network calls are made in this mode.

### Licensing RBAC

Two RBAC grants back licensing; both default to `true`:

| Value | Grant | If disabled |
| --- | --- | --- |
| `rbac.rules.clusterFingerprint` | ClusterRole + ClusterRoleBinding with `get` on the `kube-system` Namespace **object** only (`resourceNames: [kube-system]`) — its metadata UID is the stable cluster fingerprint for license identity. It cannot list namespaces and reads nothing *inside* kube-system. | Falls back to the weaker own-namespace UID as the license identity; licensing still works. |
| `rbac.rules.licenseState` | Namespaced Role writing only the `hermetiq-license-state` Secret (the auto-issued trial key and the signed validation cache used for offline grace). | Trials do not persist across pod restarts and the offline validation cache is lost. |

Both are exercised in-pod, so hardened installs must keep
`api.automountServiceAccountToken: true` and
`publisher.automountServiceAccountToken: true`.

### Status and expiry

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

## NATS ingest and stream configuration

`app.streamPartitionCount` controls the number of subscriber Deployments and
partitioned build-tool streams. Each subscriber replica owns one partition and
preserves per-build ordering within that partition. Size the count before a
large production rollout; changing it changes the stream and Deployment
topology.

`app.invocationStartEvent` defaults to `build_tool`. This mode creates
invocations from build-tool events and provisions no `BEP_LIFECYCLE_*` streams.
The `lifecycle` value remains exposed for compatibility with non-chart
deployments but should not be selected for a new chart installation.

### Stream configuration

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

Per-consumer `workerQueueCapacity`, `pipelineMaxQueuedMessages`, and
`pipelineMaxQueuedBytes` tune fetch-ahead. Keep `maxAckPending` at or above
`pipelineMaxQueuedMessages` so the server does not cap the pipeline first.
`storeBatchMaxEvents`, `storeBatchMaxWait`, and `storeBatchParallelism` tune
database-call coalescing. These are advanced settings; start with the packaged
file and change them only with ingest, NATS, and database telemetry in view.

## Progress log storage

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

### Retention and sizing

Progress logs are now served from exactly these two places, so **how long users
can open a completed build's logs is set by whichever mode the project uses**:

| Mode | Log retention |
|------|---------------|
| Postgres (default) | 2 days — the `public.progresses` partition window |
| Cloud object storage | Whatever age your bucket lifecycle rule uses |

For retention beyond two days, use object storage with the desired lifecycle
age or raise the `public.progresses` retention in `pg_partman` and size
PostgreSQL for the additional rows:

```sql
UPDATE public.part_config
SET retention = '5 days'
WHERE parent_table = 'public.progresses';
```

Progress rows are the highest-volume rows Hermetiq writes. Monitor database
size, I/O, WAL, autovacuum, partition maintenance, and the default partitions
before increasing database retention.

Chunk sizing is tuned by three optional `subscriber.env` variables — defaults
suit typical CI volumes and rarely need changing:
`PROGRESS_BLOB_CHUNK_FLUSH_INTERVAL` (default `20s`; also the delay before a
running build's newest output appears in live log tailing),
`PROGRESS_BLOB_CHUNK_MAX_BYTES` (default `262144`), and
`PROGRESS_BLOB_CHUNK_MAX_EVENTS` (default `1000`).

## Authentication and SSO

### OIDC provider

Set the OIDC issuer URL once at the top level and the chart wires it through `api.jwt.issuer`, `api.jwt.jwksUrl`, `publisher.jwks.issuer`, `publisher.jwks.url`, and `dashboard.oauth2Proxy.oidcIssuerUrl`. JWKS URLs default to `<issuerUrl>.well-known/jwks.json`. Per-component values still win when set, so anything can be overridden individually.

```yaml
oidc:
  issuerUrl: https://<tenant>.auth0.com/
```

This feeds the core's `GRPC_AUTH_*` settings — see
[gRPC Authentication](#grpc-authentication) for what the core now requires, and
for the audiences and CAL CIDRs the issuer cannot supply.

### gRPC authentication

Authentication runs in the `bep-nats` core process. It verifies bearer tokens
for the gRPC API, BEP ingest, and MCP endpoint using the `GRPC_AUTH_*`
environment contract. API pods retain `grpc-auth-proxy` only for gRPC-web
framing and CORS. The core strips caller-supplied identity headers, including
`X-Forwarded-User`, before authenticating.

The application does not read the old `JWKS_*` names and provides no aliases.
`GRPC_AUTH_ISSUER` and `GRPC_AUTH_AUDIENCE` are mandatory for the `jwks`
provider, and Buildbarn CAL calls are admitted only through
`publisher.trustedCalCidrs`.

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

Custom environment values may be literal scalars or Helm `tpl`
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

### Unsupported static publisher identity

`publisher.authProxy.staticForwardedUser` remains in the values schema for
configuration compatibility but is not an authentication mechanism. The core
strips the `X-Forwarded-User` header injected by that sidecar and rejects the
request. Do not configure new installations this way. Use chart-managed
`publisher.jwks` or supply the complete `GRPC_AUTH_*` contract through
`publisher.env`.

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

### Grafana SSO

When `grafana.oauth2Proxy.enabled=true`, the chart renders a standalone
`grafana-oauth2-proxy` Deployment and Service, then targets the Grafana route at
that proxy. It reuses `oauth2-proxy-config-web-ui` and the
`oauth2-proxy-client` Secret, so it can share the dashboard session.

Both the proxy and the route render only when `gateway.routes.grafanaEnabled`
is `true`, the default. The proxy forwards to the Grafana Service named by
`gateway.routes.grafanaService` (default `vm-grafana`) on
`gateway.routes.grafanaServicePort`. The starter VictoriaMetrics values set
`grafana.fullnameOverride: vm-grafana` to match; change both together if you
rename the Grafana release.

Register `https://grafana.<domainBase>/oauth2/callback` with the IdP and
configure Grafana to trust the proxy headers in the VictoriaMetrics values:

```yaml
grafana:
  grafana.ini:
    auth.proxy:
      enabled: true
      header_name: X-Forwarded-User
      header_property: username
      headers: "Email:X-Forwarded-Email Groups:X-Forwarded-Groups"
      auto_sign_up: true
      enable_login_token: true
```

If dashboard OAuth is disabled, the shared proxy ConfigMap is still rendered
when the Grafana proxy consumes it. The Buildbarn Browser proxy can reuse the
same Secret and ConfigMap after the Hermetiq release is installed.

## Dashboard configuration

### Quickstart customization

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

## External configuration ConfigMaps

Several JSON configuration files can be supplied by a ConfigMap owned outside
the Helm release. The selected key is mounted at the same container path as the
packaged default.

| Values prefix | Packaged file | Mount path | Consumer |
|---|---|---|---|
| `nats.streamConfig` | `files/config/nats_streams.json` | `/config/nats-streams/nats_streams.json` | publisher and subscribers |
| `cacheTtl` | `files/config/cache_ttl.json` | `/config/cache-ttl/cache_ttl.json` | API |
| `promqlQueries` | `files/config/promql.json` | `/config/promql/promql.json` | API/MCP tools |
| `dashboard.quickstartConfig` | rendered from values | `/quickstart-config/quickstart-config.json` | dashboard |

For NATS, cache TTL, and PromQL ConfigMaps, set `rolloutChecksum` whenever the
external content changes. Helm cannot read or hash external ConfigMap data, so
the checksum is the signal that rolls consuming pods.

### Cache TTL configuration

The API reads cache TTL settings from `/config/cache-ttl/cache_ttl.json`. By default, the chart renders `files/config/cache_ttl.json` into the `bep-cache-ttl-config` ConfigMap. To override it with an externally managed ConfigMap, provide the ConfigMap name and key:

```yaml
cacheTtl:
  existingConfigMap: hermetiq-cache-ttl-config
  configMapKey: cache_ttl.json
  rolloutChecksum: "sha256-or-version-of-the-config"
```

The selected key is always mounted to `/config/cache-ttl/cache_ttl.json`, so the API container path does not change. Helm cannot hash data from an external ConfigMap; update `rolloutChecksum` when the ConfigMap contents change and the API pods need a rollout.

### PromQL query configuration

The MCP infrastructure tools read query templates from
`/config/promql/promql.json`. The packaged templates target the recording rules
shipped with the Hermetiq Buildbarn chart. A self-managed Buildbarn with
different recording-rule names can provide a replacement ConfigMap:

```yaml
promqlQueries:
  existingConfigMap: hermetiq-promql-config
  configMapKey: promql.json
  rolloutChecksum: "sha256-or-version-of-the-config"
```

Partial query overrides are supported. Unknown template placeholders and blank
required queries fail API startup instead of silently returning incomplete
diagnostics.

## PostgreSQL and schema management

The chart expects PostgreSQL 16 or newer, an application-owned UTF-8 database,
and the `pg_partman` extension. Configure the primary endpoint under
`postgres.*`; `postgres.readReplica` is optional. `postgres.sslMode` defaults
to `require`.

### Bootstrap job

The schema bootstrap Job is a Helm hook by default. It runs on both install and upgrade so schema migrations are applied before workloads roll forward. Keep `postgres.password.existingSecret` set in hook mode, because pre-install hooks run before normal chart-managed Secrets are created. Successful hook Jobs are kept by default for log inspection and are deleted before the next install or upgrade hook creates a fresh Job. If you want the chart to create the Postgres Secret from `postgres.password.value`, set `bootstrap.hook.enabled=false`.

When `bootstrap.projectName` is set, the bootstrap job creates the default project and managed Buildbarn namespace entry. Set `bootstrap.projectId` to pin the default project ID; leave it empty to let dbadmin generate a UUID. `bootstrap.projectNamespace` defaults to the Helm release namespace, which fits installs where Buildbarn is deployed alongside Hermetiq; set it explicitly when Buildbarn lives in a different namespace. Provide `bootstrap.namespaceBrowserUrl` and `bootstrap.namespaceDashboardUrl` with the user-facing Buildbarn Browser and dashboard URLs to store on that managed namespace.

### Partition policy and maintenance

The first successful bootstrap creates time-based partitions with
`bootstrap.partitionInterval`, `bootstrap.retentionDays`, and
`bootstrap.premake`. The defaults are six-hour partitions, 30 days of
retention, and 30 premade partitions for the general analytics tables.
`public.progresses` uses its own hourly/two-day policy.

After bootstrap, `public.part_config` is authoritative. Later bootstrap runs
do not overwrite an operator's retention or premake changes, and the
maintenance command does not use `bootstrap.retentionDays` as a runtime
override. Update retention or premake in `public.part_config`; do not change
`partition_interval` in place because changing an interval requires rebuilding
the affected partition set.

The chart renders `partitionMaintenance` and
`progressesPartitionMaintenance` CronJobs. Watch their most recent Jobs and
keep default partitions empty. Rows accumulating in a `*_default` table mean a
partition is missing or maintenance is failing.

## Scheduling, availability, and hardening

### Node scheduling

Set top-level defaults with `k8sNodeScheduling`:

```yaml
k8sNodeScheduling:
  nodeSelector:
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
  tolerations: []
```

Set `nodeSelector` or `tolerations` under an individual workload to override the top-level values. Supported workload keys include `api`, `publisher`, `subscriber`, `dashboard`, `bootstrap`, `partitionMaintenance`, `progressesPartitionMaintenance`, and `targetTrendsRefresh`.

### Pod disruption budgets and anti-affinity

API and publisher Pods use preferred hostname anti-affinity and have
`maxUnavailable: 1` PodDisruptionBudgets enabled by default. Keep at least two
replicas when a PDB is enabled. Subscriber, dashboard, and Grafana proxy PDBs
are disabled by default because those workloads commonly start with one
replica; enable them only after choosing a replica count and disruption policy
that permits node drains.

### ServiceAccount tokens and RBAC

The shared `bep-nats` ServiceAccount mounts a token by default. Per-workload
`automountServiceAccountToken` values override the shared setting.

For a hardened installation, begin with:

```yaml
serviceAccount:
  automountServiceAccountToken: false

api:
  automountServiceAccountToken: true
publisher:
  automountServiceAccountToken: true
```

API and publisher token access is required for licensing and the optional
workload-discovery features. Subscribers need a token only when lease-based
coordination is enabled. Maintenance jobs and dashboard-related workloads do
not need a token unless an environment-specific integration uses the
Kubernetes API.

Review every rule under `rbac.rules`:

- keep `clusterFingerprint` and `licenseState` enabled for stable licensing,
  trial persistence, and offline validation grace
- keep `deployments`, `configMaps`, and `rbeWorkers` only when the API should
  discover Buildbarn workloads and worker pools
- keep `leases` only for subscriber lease coordination
- keep `secrets` and `certManager` only for the application features that read
  those resources

The default container security context runs as a non-root user, drops all
capabilities, disables privilege escalation, uses a read-only root filesystem,
and applies `RuntimeDefault` seccomp. Test overrides with server-side dry-run
and the target cluster's admission policies.

### Workload identity

The chart annotates the shared ServiceAccount for GKE or labels/annotates Pods
for Azure workload identity:

```yaml
gcpWorkloadIdentity:
  enabled: true
  serviceAccount: hermetiq@project-id.iam.gserviceaccount.com

# Or on AKS:
azureWorkloadIdentity:
  enabled: true
  clientId: <azure-client-id>
```

On GKE, create the Google service account, grant it the object-storage roles
the enabled features need, and allow the chart's Kubernetes ServiceAccount
(`bep-nats` in the release namespace by default) to impersonate it before
enabling the value:

```bash
gcloud iam service-accounts create hermetiq-bep \
  --display-name="Hermetiq BEP NATS" \
  --project=<gcp-project>

gcloud iam service-accounts add-iam-policy-binding \
  hermetiq-bep@<gcp-project>.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:<gcp-project>.svc.id.goog[hermetiq/bep-nats]"
```

The chart then adds the `iam.gke.io/gcp-service-account` annotation to the
ServiceAccount. On AKS it adds the `azure.workload.identity/use` label to the
ServiceAccount and Pods and the `azure.workload.identity/client-id` annotation
to the ServiceAccount.

For AWS IRSA or another provider, use `serviceAccount.annotations`. Grant the
resulting identity only the object-storage permissions required by enabled
features. Progress-log object storage needs subscriber read/write access;
trace and output-file features may need additional read access.

### Additional environment variables

Use workload-specific `env` maps for application flags that are not modeled as
first-class chart values. Supported maps include `api.env`,
`api.authProxy.env`, `publisher.env`, `publisher.authProxy.env`,
`subscriber.env`, `dashboard.env`, `dashboard.oauth2Proxy.env`,
`dashboard.prepareDashboardHtml.env`, `grafana.oauth2Proxy.env`,
`bootstrap.env`, `partitionMaintenance.env`,
`progressesPartitionMaintenance.env`, and `targetTrendsRefresh.env`.

Do not set `INVOCATION_START_EVENT` in a workload map. Use
`app.invocationStartEvent`; the chart puts it in the shared environment so the
publisher and subscribers cannot drift into different ingest modes.

Only the pass-through maps documented as templated accept Helm expressions.
Do not use expressions in `hosts.*`, which several templates consume verbatim.

## Verification

Wait for the bootstrap hook and core Deployments:

```bash
helm status hmq -n hermetiq
kubectl -n hermetiq get jobs
kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/part-of=hermetiq
kubectl -n hermetiq rollout status deployment/grpc-api --timeout=5m
kubectl -n hermetiq rollout status deployment/bep-nats-pub --timeout=5m
kubectl -n hermetiq rollout status deployment/web-ui --timeout=5m
```

The number of `bep-nats-sub-*` Deployments should match
`app.streamPartitionCount`. Verify each one without relying on hard-coded image
versions:

```bash
kubectl -n hermetiq get deploy -l app.kubernetes.io/component=subscriber
kubectl -n hermetiq get pods \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGE:.spec.containers[*].image'
```

Check Services, endpoints, and routing resources:

```bash
kubectl -n hermetiq get svc,endpoints grpc-api web-ui bep-nats-pub
kubectl -n hermetiq get httproute,grpcroute,httpproxy,ingress 2>/dev/null
kubectl -n hermetiq get backendtrafficpolicy,healthcheckpolicy,gcpbackendpolicy 2>/dev/null
```

Check NATS and the license endpoint:

```bash
kubectl -n hermetiq exec -it \
  "$(kubectl -n hermetiq get pods -l app.kubernetes.io/component=nats-box \
    -o jsonpath='{.items[0].metadata.name}')" \
  -- nats stream report

kubectl -n hermetiq port-forward deployment/grpc-api 8008
curl -fsS localhost:8008/api/v1/license/status
```

Render-time validation is intentionally strict. If installation fails before
creating resources, run the same values through `helm template --debug` and
read the validation error before changing a value.

## Operations

Commands below specify `-n hermetiq` so they do not depend on the current
kubectl namespace.

### Inspect Pods and logs

```bash
kubectl -n hermetiq get pods
kubectl -n hermetiq describe pod <pod-name>
kubectl -n hermetiq logs --all-containers --prefix --tail=2000 <pod-name>
```

Collect the core workload logs into one file:

```bash
LOG="hermetiq-logs-$(date +%Y%m%d-%H%M%S).log"

for selector in app=bep-nats-pub app=grpc-api app=web-ui; do
  kubectl -n hermetiq logs -l "$selector" \
    --all-containers --prefix --tail=2000 >> "$LOG" 2>&1
done

for deployment in $(kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/component=subscriber -o name); do
  kubectl -n hermetiq logs "$deployment" \
    --all-containers --prefix --tail=2000 >> "$LOG" 2>&1
done

gzip "$LOG"
```

### Pause and resume subscribers

Pausing subscribers leaves new events queued in JetStream, subject to each
stream's retention limits:

```bash
for deployment in $(kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/component=subscriber -o name); do
  kubectl -n hermetiq scale "$deployment" --replicas=0
done
```

Resume with the configured per-partition replica count (the default is one):

```bash
SUBSCRIBER_REPLICAS=1 # set to subscriber.replicas from your values

for deployment in $(kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/component=subscriber -o name); do
  kubectl -n hermetiq scale "$deployment" --replicas="$SUBSCRIBER_REPLICAS"
done
```

A later `helm upgrade` restores the replica count from values.

### Inspect database partitions

In `psql`, inspect table size and `pg_partman` state:

```sql
SELECT relname AS table_name,
       reltuples::bigint AS approximate_rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
ORDER BY pg_total_relation_size(c.oid) DESC;

SELECT parent_table, control, partition_interval, retention,
       retention_keep_table, premake, maintenance_last_run
FROM public.part_config
ORDER BY parent_table;
```

Default partitions should remain empty. If a `*_default` table grows, inspect
the maintenance CronJobs immediately:

```bash
kubectl -n hermetiq get cronjob,job | grep -E 'partition|target-trends'
kubectl -n hermetiq get pods | grep partition-maintenance
```

Run maintenance immediately with unique Job names:

```bash
kubectl -n hermetiq create job \
  "partition-maintenance-$(date +%s)" \
  --from=cronjob/partition-maintenance
kubectl -n hermetiq create job \
  "progresses-partition-maintenance-$(date +%s)" \
  --from=cronjob/progresses-partition-maintenance
```

### Inspect NATS and the dead-letter queue

```bash
NATS_BOX=$(kubectl -n hermetiq get pods \
  -l app.kubernetes.io/component=nats-box \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream report
kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream info BEP_BUILD_TOOL_0
kubectl -n hermetiq exec -it "$NATS_BOX" -- nats stream info BEP_DLQ_STREAM
```

Purge the DLQ only after recording why messages were rejected and confirming
they do not need to be replayed:

```bash
kubectl -n hermetiq exec -it "$NATS_BOX" \
  -- nats stream purge BEP_DLQ_STREAM --force
```

### Temporary image overrides

For short-lived diagnosis, patch running Deployments with `kubectl set image`:

```bash
CORE_IMAGE=us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/bep-nats:<tag>
WEB_IMAGE=us-docker.pkg.dev/hermetiq-cloud/hermetiq-public/hermetiq-web-ui:<tag>

kubectl -n hermetiq set image deployment/grpc-api api="$CORE_IMAGE"
kubectl -n hermetiq set image deployment/bep-nats-pub bep-nats="$CORE_IMAGE"
kubectl -n hermetiq set image deployment/web-ui web-ui="$WEB_IMAGE"

for deployment in $(kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/component=subscriber -o name); do
  kubectl -n hermetiq set image "$deployment" bep-nats-sub="$CORE_IMAGE"
done
```

These changes drift from Helm state and are reverted by the next upgrade. Put
long-lived image changes under `images.*` in values.

### Rotate Secrets

Secrets injected as environment variables require a workload restart after
their contents change.

| Secret | Main consumers | Restart after rotation |
|---|---|---|
| `postgres-db` | API, publisher, subscribers, maintenance jobs | `grpc-api`, `bep-nats-pub`, and all `bep-nats-sub-*` Deployments |
| `dragonfly-auth` | Dragonfly and Hermetiq core workloads | Dragonfly first, then all core Deployments |
| `oauth2-proxy-client` | dashboard, Grafana proxy, API audience derivation, optional Buildbarn Browser | `web-ui`, `grafana-oauth2-proxy`, `grpc-api`, and the Buildbarn Browser proxy |
| `hermetiq-license` | API and publisher | normally hot-reloaded; restart only when directed by support |

Update a Secret without putting its value on disk:

```bash
kubectl -n hermetiq create secret generic postgres-db \
  --from-literal=password='<new-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Coordinate database and cache credential changes with the corresponding
external service. Rotating `OAUTH2_PROXY_COOKIE_SECRET` invalidates active UI
sessions.

## Local chart development

OCI releases are the supported customer installation path. Contributors can
render and install the checked-out chart directly:

```bash
helm lint ./charts/hermetiq \
  --values ./charts/hermetiq/ci-values/ci.yaml

helm template hmq ./charts/hermetiq \
  --namespace hermetiq \
  --values ./charts/hermetiq/ci-values/ci.yaml > /tmp/hermetiq-render.yaml

helm upgrade --install --namespace hermetiq hmq ./charts/hermetiq \
  --values ./custom-values/hermetiq-values.yaml
```

Before installing locally, review the repository's
[shared chart conventions](https://github.com/Hermetiq/hermetiq-k8s#shared-chart-conventions)
for private registries, digest pinning, common metadata, `extraObjects`, and
templated pass-through values.
