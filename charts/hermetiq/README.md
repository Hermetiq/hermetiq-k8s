# Hermetiq Helm Chart

**Try it in the cloud:**
[Sign up for Hermetiq Cloud](https://dashboard.hermetiq.io/) to explore
Hermetiq and Managed Buildbarn before setting up a Kubernetes deployment.

This README is the operator reference packaged with the Hermetiq chart. It
covers the services the chart depends on, its values, the installation, and
day-2 operations. The repository's
[installation guide](https://github.com/Hermetiq/hermetiq-k8s#installation)
gives the full-stack order (routing, identity provider, metrics stack, worker
operator, Buildbarn) and sends you here for its "Install Hermetiq" step.

How this README is organized:

- **Install** is a linear path. Read it top to bottom.
- **Configure** follows the blocks of the starter
  [`hermetiq-values.yaml`](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/hermetiq-values.yaml),
  in the same order as the file.
- The remaining parts are reference for optional features, production
  hardening, and operations.

## Contents

**Install**

- [What the chart installs](#what-the-chart-installs)
- [Install prerequisites](#install-prerequisites): checklist, PostgreSQL, NATS
  JetStream, DragonflyDB, Secrets
- [Configure your values file](#configure-your-values-file): what to set,
  block by block
- [Install](#install): pre-flight checks, the command, verification

**Configure** (same order as `hermetiq-values.yaml`)

- [Licensing and trials](#licensing-and-trials)
- [Hosts](#hosts)
- [PostgreSQL and schema management](#postgresql-and-schema-management)
- [Routing](#routing): providers, what the public routes forward, TLS,
  Envoy Gateway policies, timeouts
- [Redis-compatible cache](#redis-compatible-cache)
- [NATS ingest and stream configuration](#nats-ingest-and-stream-configuration)
- [Observability](#observability): OpenTelemetry, VictoriaMetrics, dashboards
- [Workload identity](#workload-identity)
- [Application settings](#application-settings)
- [Authentication and SSO](#authentication-and-sso): OIDC, gRPC and MCP
  authentication, project access, CAL trust, sign-in
- [Workload sizing, scheduling, and availability](#workload-sizing-scheduling-and-availability)
- [Dashboard](#dashboard): feature flags, Quickstart
- [ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac)
- [External configuration ConfigMaps](#external-configuration-configmaps)

**Optional features**

- [Progress log storage](#progress-log-storage)
- [Cache-event analytics](#cache-event-analytics)
- [RBE Infrastructure](#rbe-infrastructure)
- [Barn Owl AI assistant](#barn-owl-ai-assistant)
- [Cost reporting](#cost-reporting)

**Production readiness**

- [Large-scale deployments and high-throughput ingest](#large-scale-deployments-and-high-throughput-ingest)
- [Security hardening](#security-hardening): pod security, network policies

**Operate**

- [Operations](#operations): logs, subscribers, partitions, NATS, Secret
  rotation, upgrades
- [Troubleshooting](#troubleshooting)

**Project**

- [Local chart development](#local-chart-development)
- [License](#license)

## What the chart installs

| Workload | Kind | Role | Service ports |
|---|---|---|---|
| `grpc-api` | Deployment | Hermetiq API: gRPC and gRPC-web, REST, and the MCP server. Runs the optional Barn Owl prompt-runtime sidecar. | 50091 (gRPC), 80 (REST), 5150 (MCP) |
| `bep-nats-pub` | Deployment, optional HPA | Publisher: authenticates Bazel Build Event Protocol (BEP) streams and Buildbarn completed-action logs, then publishes them to NATS JetStream. | 50091 (gRPC) |
| `bep-nats-sub-<i>` | One Deployment per stream partition | Subscribers: each consumes one partition in order and writes to PostgreSQL. | none |
| `web-ui` | Deployment | Dashboard, behind an oauth2-proxy sidecar. | 80 |
| `grafana-oauth2-proxy` | Deployment | Single sign-on proxy in front of an existing Grafana. | 80 |
| `database-schema-bootstrap` | Job (Helm hook) | Creates and migrates the database schema on install and upgrade. | none |
| `partition-maintenance`, `progresses-partition-maintenance`, `target-trends-refresh-short`, `target-trends-refresh-long` | CronJobs | Partition maintenance and trend refreshes. | none |

The chart also renders the `bep-nats` ServiceAccount and its Roles, ConfigMaps
for shared settings and Grafana dashboards, PodDisruptionBudgets, two
`VMPodScrape` objects for NATS and DragonflyDB metrics, and the routing
resources for the provider you select: Gateway API `GRPCRoute` and
`HTTPRoute`, an HTTPRoute-only GKE Gateway, Contour `HTTPProxy`, or classic
`Ingress`. NetworkPolicies are optional.

Bazel streams build events to the publisher, which authenticates the caller
and publishes to partitioned JetStream streams. One subscriber Deployment per
partition writes those events to PostgreSQL. The API serves the dashboard,
gRPC clients, and MCP clients from PostgreSQL, with the Redis-compatible store
as its application cache. The repository README has the
[architecture diagrams](https://github.com/Hermetiq/hermetiq-k8s#architecture).

The chart does not install PostgreSQL, a Redis-compatible cache, NATS,
VictoriaMetrics, Grafana, an OpenTelemetry Collector, KEDA, a Gateway or
ingress controller, cert-manager, or an identity provider. Many organizations
already run these; the prerequisites below and the repository guide cover the
rest.

## Install prerequisites

Everything in this section must exist before `helm` runs. Start with the
namespace, if the repository guide has not already created it:

```bash
kubectl create namespace hermetiq
```

Commands in this README use the `hermetiq` namespace; substitute your own if
it differs. They also assume your shell is in the copied values directory from
the repository's
[prepare custom values](https://github.com/Hermetiq/hermetiq-k8s#prepare-custom-values)
step. The chart renders into the release namespace unless `namespaceOverride`
names another.

### Checklist

Required for every install:

- [ ] Kubernetes 1.32 or newer and Helm 3.8 or newer, with capacity for the
  chart's workloads; see [Replicas and resources](#replicas-and-resources).
- [ ] A Gateway API, Contour, or Ingress controller, with DNS and TLS for the
  chart's [hosts](#hosts).
- [ ] An OIDC identity provider.
  [Authentication and SSO](#authentication-and-sso) lists what to register.
- [ ] Project grants for the Bazel and CI identities that publish builds; see
  [Project access policy](#project-access-policy).
- [ ] [PostgreSQL](#postgresql) 16 or newer with `pg_partman`.
- [ ] [NATS JetStream](#nats-jetstream) with at least three servers, or a
  one-replica stream configuration for a single-server test cluster.
- [ ] [DragonflyDB or another Redis-compatible cache](#dragonflydb-or-redis).
- [ ] An OTLP endpoint for the required `otel.endpoint` value; see
  [OpenTelemetry](#opentelemetry).
- [ ] The VictoriaMetrics operator CRDs, or the chart's two pod scrapes turned
  off; see [Dashboards and scrape objects](#dashboards-and-scrape-objects).
- [ ] A work email address and outbound HTTPS to the license services, or an
  air-gapped license; see [Licensing and trials](#licensing-and-trials).
- [ ] The [Secrets](#secrets) that the values file references.

Required for some installs:

- [ ] With Buildbarn in the cluster: its workers' pod CIDR and the
  VictoriaMetrics query URL; see
  [Co-installing with Buildbarn](#co-installing-with-buildbarn).
- [ ] At high build volume: an object-storage bucket and workload identity for
  build logs; see [Progress log storage](#progress-log-storage).

### Shared services and routing

The repository guide covers the pieces this chart shares with the Buildbarn
and worker operator charts. If you arrived from it, they are already in
place. Otherwise complete them first:

- [Routing, DNS, and TLS](https://github.com/Hermetiq/hermetiq-k8s#prepare-routing-dns-and-tls):
  the Gateway, Contour, or Ingress controller that `routing.provider` will
  use. Chart-managed TLS with Contour or Ingress also needs cert-manager and
  an issuer; see [TLS certificates](#tls-certificates).
- [Identity provider](https://github.com/Hermetiq/hermetiq-k8s#identity-provider):
  the OIDC applications and the `oauth2-proxy-client` Secret.
- [VictoriaMetrics and OpenTelemetry](https://github.com/Hermetiq/hermetiq-k8s#victoriametrics-and-opentelemetry):
  the VictoriaMetrics stack, which supplies the operator CRDs, the query
  endpoint, and Grafana, and the OpenTelemetry Collector, which is the OTLP
  endpoint the starter values point at.
- [KEDA](https://github.com/Hermetiq/hermetiq-k8s#keda): needed later for
  operator-managed worker pools, not by this chart.

### PostgreSQL

PostgreSQL is Hermetiq's system of record; NATS is an ingest buffer and
DragonflyDB is a rebuildable cache. Provision:

- PostgreSQL 16 or newer, with the `pg_partman` extension installed on the
  server.
- A UTF-8 database owned by a dedicated Hermetiq user. The owner must be able
  to create and alter tables, indexes, functions, materialized views, and
  partitions.
- Encrypted connections, and network access from the Hermetiq namespace.
- Backups with tested restores, and storage, I/O, and WAL capacity for your
  BEP ingest volume and retention.

For a new database, run the equivalent of the following as a PostgreSQL
administrator, using the database and user names from your values file:

```sql
CREATE ROLE hermetiq_helm LOGIN PASSWORD '<db-password>';
CREATE DATABASE hermetiq_helm OWNER hermetiq_helm ENCODING 'UTF8' TEMPLATE template0;
\connect hermetiq_helm
CREATE EXTENSION IF NOT EXISTS pg_partman;
```

Store the same password in the Secret the starter values reference. It must
exist before the install, because the schema bootstrap hook runs before Helm
creates any chart-managed Secret:

```bash
kubectl -n hermetiq create secret generic postgres-db \
  --from-literal=password='<db-password>'
```

The matching values are under
[PostgreSQL and schema management](#postgresql-and-schema-management). Choose
the partition interval and retention there before the first install.

### NATS JetStream

The
[NATS starter values](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/nats-values.yaml)
enable JetStream and create a three-server NATS StatefulSet with one JetStream
volume per Pod. Review two settings before installing:

- `config.jetstream.fileStore.pvc.storageClassName` is `premium-rwo`, from the
  GKE example. Replace it with a StorageClass available in your cluster; on
  EKS, use `gp3` if that class is installed. An unavailable class leaves the
  JetStream PVCs unbound and the Pods Pending.
- The volume size and resource requests. For high partition counts, see
  [Large-scale deployments](#large-scale-deployments-and-high-throughput-ingest).

```bash
kubectl get storageclass
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
helm upgrade --install --namespace hermetiq nats nats/nats \
  --values nats-values.yaml
```

> **Warning:** Hermetiq's packaged stream configuration places the
> `BEP_BUILD_TOOL` stream on three replicas, which JetStream can only do on a
> cluster of three or more NATS servers. Against a single server, stream
> creation fails when the subscribers start and no build events are ingested.
> For a single-server test setup, supply a stream configuration with
> `"replicas": 1`; see [Stream configuration](#stream-configuration).

If you run NATS another way, match the starter: clustering with three servers,
JetStream enabled with both file and memory storage, and `max_payload` raised
to 16MB. Hermetiq creates its own streams; set `nats.url` to the NATS client
Service.

### DragonflyDB or Redis

Hermetiq needs a Redis-compatible cache. The starter values use DragonflyDB,
run with `--cache_mode=true --dbnum=4`. Create its password Secret first:

```bash
kubectl -n hermetiq create secret generic dragonfly-auth \
  --from-literal=password="$(openssl rand -base64 24)"
```

If the DragonflyDB operator is already installed, review and apply the
[example instance](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/dragonflydb-operator-crd-instance.yaml):

```bash
kubectl explain dragonflies.dragonflydb.io
kubectl -n hermetiq apply \
  -f dragonflydb-operator-crd-instance.yaml
```

Otherwise, install the standalone chart with the
[starter values](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/dragonflydb-values.yaml):

```bash
helm upgrade --install --namespace hermetiq dragonfly \
  oci://ghcr.io/dragonflydb/dragonfly/helm/dragonfly \
  --version v1.40.0 \
  --values dragonflydb-values.yaml
```

To use an existing Redis-compatible service instead, skip the install and
point `redis.host` and its password Secret at that service; see
[Redis-compatible cache](#redis-compatible-cache).

### Secrets

The chart reads credentials from Secrets that you create in the release
namespace.

| Secret | Keys | Read by | Needed |
|---|---|---|---|
| `postgres-db` | `password` | bootstrap Job, API, publisher, subscribers, maintenance CronJobs | Always. Create it before the install. |
| `dragonfly-auth` | `password` | DragonflyDB and the Hermetiq workloads | Always, with the starter values. |
| `oauth2-proxy-client` | `OAUTH2_PROXY_CLIENT_ID`, `OAUTH2_PROXY_CLIENT_SECRET`, `OAUTH2_PROXY_COOKIE_SECRET` | dashboard, Grafana proxy, API, and the optional Buildbarn Browser proxy | When dashboard or Grafana sign-in is enabled, which is the default. |
| `hermetiq-license` | `license.key`, plus `license.lic` when air-gapped | API, publisher | Paid and air-gapped licenses only; see [Paid license keys](#paid-license-keys). |
| `anthropic-api` | `ANTHROPIC_API_KEY` | API and its prompt-runtime sidecar | Only with [Barn Owl](#barn-owl-ai-assistant). |
| `jev-api-key` | `JEV_API_KEY` | API | Only with [JEV model routing](#jev-model-routing). |

These are the names used by the starter values and by the examples in this
README. If you choose other names, change the matching `existingSecret` value.
The key names inside `oauth2-proxy-client` are fixed. The application creates
and maintains `hermetiq-license-state` itself; do not create or edit it.

The repository guide creates `oauth2-proxy-client` during identity-provider
setup. If you have not created it yet:

```bash
kubectl -n hermetiq create secret generic oauth2-proxy-client \
  --from-literal=OAUTH2_PROXY_CLIENT_ID='<client-id>' \
  --from-literal=OAUTH2_PROXY_CLIENT_SECRET='<client-secret>' \
  --from-literal=OAUTH2_PROXY_COOKIE_SECRET="$(openssl rand -base64 32 | tr -- '+/' '-_')"
```

[Rotate Secrets](#rotate-secrets) lists the workloads to restart when one of
these changes.

## Configure your values file

Start from the
[starter values](https://github.com/Hermetiq/hermetiq-k8s/blob/main/custom-values/hermetiq-values.yaml)
and edit your copied `hermetiq-values.yaml`. The starter holds the main
inputs; the chart's
[`values.yaml`](https://github.com/Hermetiq/hermetiq-k8s/blob/main/charts/hermetiq/values.yaml)
documents every setting.

Work through the file top to bottom. Each row names what to set in one block
and what happens if you leave the starter's example in place. The last column
links to the section that explains the block.

| Block | Set | If you skip it | Details |
|---|---|---|---|
| `license` | `contactEmail` to a real work address; keep `agreement.accepted: true` | Rendering fails without both. The application rejects `example.com` addresses at startup. | [Licensing and trials](#licensing-and-trials) |
| `hosts` | `domainBase` | Rendering fails. Your DNS, TLS, and OIDC callbacks must cover the hosts derived from it. | [Hosts](#hosts) |
| `bootstrap` | `retentionDays`, `partitionInterval` | The starter's 30 days and 6-hour partitions are seeded at first install and cannot be changed through values later. The chart creates a default project either way. | [Partition policy](#partition-policy), [Default project](#default-project) |
| `postgres` | `host`, `database`, `user`, `password.existingSecret` | Rendering fails, or the bootstrap hook fails when the Secret is missing. | [PostgreSQL and schema management](#postgresql-and-schema-management) |
| `routing`, `gateway` | `routing.provider`; `gateway.name` and, if needed, `gateway.namespace` | Rendering fails without `gateway.name`. On a controller other than Envoy Gateway, the starter's Envoy policy kinds fail to install. | [Routing](#routing) |
| `redis` | `host`, `password.existingSecret` | Rendering fails. | [Redis-compatible cache](#redis-compatible-cache) |
| `nats` | `url` | Rendering fails. Against a single-server NATS, no builds are ingested. | [NATS ingest and stream configuration](#nats-ingest-and-stream-configuration) |
| `otel` | `endpoint`, with scheme and port | Rendering fails. | [OpenTelemetry](#opentelemetry) |
| `victoriaMetrics` | `baseUrl` to your vmselect read endpoint | Metrics-backed MCP tools and the RBE Infrastructure page have no data. | [Observability](#observability) |
| `gcpWorkloadIdentity` | On GKE with an object-storage feature, the Google service account. Otherwise remove the block; the chart default is off. | Rendering fails when it is enabled without a service account. | [Workload identity](#workload-identity) |
| `app` | `streamPartitionCount` | The chart partition count applies. | [Stream partitions](#stream-partitions), [Application settings](#application-settings) |
| `authorization` | Trusted administrator groups and project grants for users and CI | Authenticated humans receive Viewer access by default; publishing requires Builder or Admin access. Email allowlists do not grant installation administration. | [Project access policy](#project-access-policy), [Admin access](#admin-access) |
| `oidc` | `issuerUrl`, exactly as it appears in your tokens; keep a trailing slash only if the tokens have one | Rendering fails. | [OIDC provider](#oidc-provider) |
| `api` | `replicas`, `resources` | The starter's small sizing applies. | [Replicas and resources](#replicas-and-resources) |
| `publisher` | `trustedCalCidrs` when Buildbarn workers report here; `replicas`, `resources` | Every completed-action call is rejected with `UNAUTHENTICATED` and remote-execution action telemetry stops arriving. | [Completed Action Logger trust](#completed-action-logger-trust) |
| `dashboard` | `oauth2Proxy.client.existingSecret`; optionally `oauth2Proxy.backendLogoutUrl` | Rendering fails without client credentials. Without the logout URL, signing out clears only the local cookie. | [Dashboard sign-in](#dashboard-sign-in) |
| `rbe`, `assistant` | Leave commented out unless you want the feature | The RBE Infrastructure page and Barn Owl stay hidden. | [RBE Infrastructure](#rbe-infrastructure), [Barn Owl AI assistant](#barn-owl-ai-assistant) |
| `rbac` | Keep `mode: namespace`; add `rules.rbeFleet: true` with `rbe` | The RBE Infrastructure page lacks fleet data. | [ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac) |

Replace every placeholder, including the example domain `helm.hermetiq.dev`
wherever it appears, and confirm that each Secret and Service the file names
exists.

### Decide before the first install

Settle these before running the install. The first three are hard to change
afterwards, and the fourth fails without an error:

- The partition interval and retention under `bootstrap` seed `pg_partman`
  once; see [Partition policy](#partition-policy).
- `app.streamPartitionCount` fixes the stream and subscriber topology; see
  [Stream partitions](#stream-partitions).
- The license is bound to the UID of the release Namespace, which changes if
  the namespace is deleted and recreated; see
  [License identity and state](#license-identity-and-state).
- An empty `publisher.trustedCalCidrs` drops Buildbarn's action telemetry; see
  [Completed Action Logger trust](#completed-action-logger-trust).

The starter values and chart defaults also assume a particular platform.
Change whichever of these does not match your cluster:

- `routing.provider: gateway` on Envoy Gateway, with its policy kinds and
  `gateway.clientTrafficPolicy` enabled; see [Routing](#routing).
- `gcpWorkloadIdentity` for GKE; see [Workload identity](#workload-identity).
- Services named `nats`, `dragonfly`, `otel-collector`, and `vmselect-vmks` in
  the `hermetiq` namespace.
- A Grafana Service named `vm-grafana`. The chart renders a Grafana route and
  a sign-in proxy in front of it by default; see [Grafana SSO](#grafana-sso).
- amd64 Linux nodes, which the chart's default node selector requires; see
  [Node scheduling](#node-scheduling).

### Co-installing with Buildbarn

When the Buildbarn chart runs in the same cluster:

- Set `publisher.trustedCalCidrs` to the pod range its workers run in, which
  must not contain gateway or ingress proxy pods; see
  [Completed Action Logger trust](#completed-action-logger-trust).
- Keep `app.streamPartitionCount` equal to Buildbarn's
  `frontend.grpcCacheProxy.cacheEvents.numShards`.
- Keep the starter's `victoriaMetrics` settings, with `baseUrl` at your
  vmselect endpoint; see
  [Metrics-backed infrastructure tools](#metrics-backed-infrastructure-tools).
- Enable `gateway.clientTrafficPolicy` in only one of the two charts when
  they share a Gateway.
- If Buildbarn runs in another namespace, set `bootstrap.projectNamespace` to
  it and grant the `bep-nats` ServiceAccount read access there; see
  [ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac).
- If FUSE-based workers share the Hermetiq namespace, that namespace needs the
  `privileged` Pod Security level; see
  [Pod and container security context](#pod-and-container-security-context).
- Run Hermetiq with the Buildbarn chart from the same
  [supported chart bundle](https://github.com/Hermetiq/hermetiq-k8s#supported-chart-bundle).
  Hermetiq reads and validates the Buildbarn configuration that chart
  renders, and the two are upgraded together.

### Inspect the packaged defaults

Read the exact defaults and README of the version you are installing before
writing advanced overrides:

```bash
helm show values oci://ghcr.io/hermetiq/hermetiq --version 1.0.0
helm show readme oci://ghcr.io/hermetiq/hermetiq --version 1.0.0
```

## Install

### Pre-flight checks

Run these before installing. Use the namespace and Service names from your own
values where they differ from the starter.

1. Look for placeholders left in the values file. Matches inside comments are
   harmless:

   ```bash
   grep -nE '<[A-Za-z-]+>|example\.com|helm\.hermetiq\.dev' hermetiq-values.yaml
   ```

2. Confirm that the Secrets and Service endpoints the starter values reference
   exist. Every endpoint should have at least one ready address:

   ```bash
   kubectl -n hermetiq get secret postgres-db dragonfly-auth oauth2-proxy-client
   kubectl -n hermetiq get endpoints nats dragonfly otel-collector vmselect-vmks vminsert-vmks
   kubectl -n hermetiq rollout status deployment/otel-collector --timeout=5m
   ```

3. Confirm that NATS is ready and JetStream is enabled:

   ```bash
   kubectl -n hermetiq rollout status statefulset/nats --timeout=5m
   kubectl -n hermetiq exec -it \
     "$(kubectl -n hermetiq get pods -l app.kubernetes.io/component=nats-box \
       -o jsonpath='{.items[0].metadata.name}')" \
     -- nats server check jetstream
   ```

4. Confirm that the CRDs your values rely on are installed. The first command
   should list `vmpodscrapes`; if it prints nothing, install the metrics stack
   or disable the [pod scrapes](#dashboards-and-scrape-objects). The second
   matters for `routing.provider: gateway` and should list
   `backendtrafficpolicies`, `securitypolicies`, `clienttrafficpolicies`, and
   `envoypatchpolicies`;
   if it prints nothing, your controller is not Envoy Gateway, so disable the
   [Envoy Gateway policies](#envoy-gateway-policies):

   ```bash
   kubectl api-resources --api-group=operator.victoriametrics.com
   kubectl api-resources --api-group=gateway.envoyproxy.io
   ```

   Envoy Gateway must also enable its patch-policy extension and use the
   configured dashboard listener names; see
   [Dashboard gRPC-web forwarding](#dashboard-grpc-web-forwarding).

5. Confirm the external pieces: the OIDC issuer's discovery document is
   reachable, the dashboard callback URL and BEP audience are registered, and
   the Gateway or Ingress controller has a ready address. For chart-managed
   Contour or Ingress certificates, cert-manager and the issuer must be ready
   too. KEDA is only needed later, for operator-managed worker pools.

6. Render the chart with your values. Validation is strict, and the error
   names the first missing or conflicting value:

   ```bash
   helm template hmq oci://ghcr.io/hermetiq/hermetiq \
     --version 1.0.0 \
     --namespace hermetiq \
     --values hermetiq-values.yaml > /dev/null
   ```

### Run the install

Install the pinned OCI release:

```bash
helm upgrade --install --namespace hermetiq hmq \
  oci://ghcr.io/hermetiq/hermetiq \
  --version 1.0.0 \
  --values hermetiq-values.yaml
```

If the command fails before creating resources, rerun the `helm template`
step with `--debug` and read the validation error before changing a value.

### Verify the installation

Wait for the bootstrap hook and the core Deployments:

```bash
helm status hmq -n hermetiq
kubectl -n hermetiq get jobs
kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/part-of=hermetiq
kubectl -n hermetiq rollout status deployment/grpc-api --timeout=5m
kubectl -n hermetiq rollout status deployment/bep-nats-pub --timeout=5m
kubectl -n hermetiq rollout status deployment/web-ui --timeout=5m
```

The number of `bep-nats-sub-*` Deployments should equal
`app.streamPartitionCount`. List them, then every Pod with its readiness and
image:

```bash
kubectl -n hermetiq get deploy -l app.kubernetes.io/component=subscriber
kubectl -n hermetiq get pods \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGE:.spec.containers[*].image'
```

With the starter values, expect `bep-nats-pub-*`, `bep-nats-sub-*`,
`grpc-api-*`, `web-ui-*`, and `grafana-oauth2-proxy-*` Pods to be `Running`
with every container ready.
Pods of completed Jobs, such as `database-schema-bootstrap-*` and a scheduled
`progresses-partition-maintenance-*` run, show `Completed`; that is healthy.
If the shared services live in the same namespace, their Pods appear too:
DragonflyDB, KEDA, three NATS servers, the OpenTelemetry Collector, and
VictoriaMetrics, including `vmstorage-*` and `vmselect-*`. Pod suffixes,
replica counts, and the services present depend on your values.

Check the Services and their endpoints, then the routing resources. Run only
the lines for your `routing.provider`: kubectl fails the whole command when
any kind in the list is not installed in the cluster.

```bash
kubectl -n hermetiq get svc,endpoints grpc-api web-ui bep-nats-pub

# routing.provider: gateway
kubectl -n hermetiq get grpcroute,httproute
kubectl -n hermetiq get backendtrafficpolicy   # Envoy Gateway only
# routing.provider: gateway-httproute-only
kubectl -n hermetiq get httproute,healthcheckpolicy,gcpbackendpolicy
# routing.provider: contour
kubectl -n hermetiq get httpproxy
# routing.provider: ingress
kubectl -n hermetiq get ingress
```

Check that the streams exist and that the application stored its license
state:

```bash
kubectl -n hermetiq exec -it \
  "$(kubectl -n hermetiq get pods -l app.kubernetes.io/component=nats-box \
    -o jsonpath='{.items[0].metadata.name}')" \
  -- nats stream report

kubectl -n hermetiq get secret hermetiq-license-state
```

Then query the license endpoint as described under
[Status and expiry](#status-and-expiry). The install notes that Helm prints
list the external endpoints and the licensing mode in effect.

### Next steps

Resolve Pods stuck in `Pending` or `CrashLoopBackOff`, containers that are not
ready, and failed Jobs before continuing;
[Troubleshooting](#troubleshooting) lists the common causes. When the
installation is healthy:

1. [Install the BB Worker Operator](https://github.com/Hermetiq/hermetiq-k8s#install-the-worker-operator).
2. [Install Buildbarn and its worker pools](https://github.com/Hermetiq/hermetiq-k8s#install-buildbarn-and-worker-pools).
3. Sign in to the dashboard as an administrator and review Project Settings;
   see
   [post-installation configuration](https://github.com/Hermetiq/hermetiq-k8s#post-installation-configuration).
4. After the first builds arrive, confirm that the default partitions stay
   empty; see [Inspect database partitions](#inspect-database-partitions).

Come back to the reference sections below when your environment needs them.

## Licensing and trials

**Values:** `license`. The starter sets `contactEmail` and
`agreement.accepted`.

The Hermetiq container images are proprietary software and need a license to
run. A new install can start on an automatic 30-day trial.

### Agreement and contact email

`license.agreement.accepted` must be `true`. The images are distributed under
the Hermetiq Software License Agreement, packaged with this chart as
`SOFTWARE-LICENSE-AGREEMENT.md` and published at `license.agreement.url`.
Rendering fails until acceptance is confirmed, and the install notes repeat
the URL.

`license.contactEmail` is required: rendering fails without a syntactically
valid address. Use a real work address. The application refuses to start with
an `example.com` address such as the starter's `build-team@example.com`
placeholder.

### Trial licenses

With no license key configured, the application issues itself a 30-day trial
against `license.contactEmail` on first start and stores the key in the
`hermetiq-license-state` Secret. Trials are bound to the release Namespace;
see [License identity and state](#license-identity-and-state).

Trial issuance needs outbound HTTPS to `license.saasUrl` (default
`https://api.cloud-usc1.hermetiq.io`), and periodic validation needs
`https://api.keygen.sh`. `HTTPS_PROXY` is honored. Validation runs off the
request path and is cached, so a transient outage of the licensing service
does not interrupt requests.

To convert a trial to a paid license, contact support@hermetiq.com. The
existing license is upgraded in place under the same key, and the Pods pick
it up at their next scheduled validation: normally within 4 hours, or up to
24 hours if the install has already lapsed. No cluster change is needed.

Setting `license.trial.enabled: false` without a key leaves the install
unlicensed, and its Pods go unready once the unlicensed tolerance lapses.

### Paid license keys

A key Secret is needed only for a license issued directly, without a trial,
and for air-gapped installs. Put the key in a Secret named `hermetiq-license`
under the data key `license.key`:

```bash
kubectl -n hermetiq create secret generic hermetiq-license \
  --from-literal=license.key='<key>'
```

Unless `license.key.existingSecret` names a different Secret, the chart mounts
`hermetiq-license` as an optional volume. Creating the Secret after the
install therefore loads the key with no values change and no rollout.

To use a Secret with other names, set `license.key.existingSecret` and
`license.key.existingSecretKey`. That is a values change, so it takes a
`helm upgrade` and a rollout. `license.key.value` is the inline alternative:
the chart then creates the `hermetiq-license` Secret itself.

### Air-gapped licenses

Set `license.airGapped: true` and `license.trial.enabled: false`, and name
the license Secret in `license.key.existingSecret`. That Secret must carry
both the license key and a checked-out license file, under the data keys
`license.key` and `license.lic` by default (`license.key.existingSecretKey`
and `license.licenseFileSecretKey`). Trials are online-only, so the chart
refuses to render with trials enabled. No network calls are made in this
mode.

Renew by replacing the Secret with a freshly checked-out license file. The
Pods reload it within about a minute, without a restart.

### License identity and state

Trial and paid licenses are identified by a hash of the release Namespace's
UID. The chart's runtime RBAC therefore always grants the `bep-nats`
ServiceAccount `get` on that one Namespace object, in either `rbac.mode`. The
default `rbac.mode: namespace` creates no ClusterRole or ClusterRoleBinding
for it.

`rbac.rules.licenseState` (default `true`) adds a namespaced Role for the
`hermetiq-license-state` Secret, where the application keeps the auto-issued
trial key and the signed validation cache used for offline grace. The Role
can read and update only that Secret. It also grants `create` on Secrets,
which Kubernetes RBAC cannot restrict by name. With the rule disabled, trials
do not persist across Pod restarts and the offline validation cache is lost.

Both grants are used from inside the API and publisher Pods, so those Pods
need a mounted ServiceAccount token. They inherit
`serviceAccount.automountServiceAccountToken: true` by default; read
[ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac) before
turning that off.

### Status and expiry

The status endpoint and the `hermetiq_license_*` metrics expose expiry and
grace state for alerting. You can check the status at any time, even while
Pods are unready. `kubectl port-forward` blocks, so run it in one terminal:

```bash
kubectl -n hermetiq port-forward deploy/grpc-api 8008
```

Then query the endpoint from another:

```bash
curl -fsS localhost:8008/api/v1/license/status
```

When a license lapses past its grace window, the `grpc-api` and
`bep-nats-pub` Pods report 0/N ready on the `license` readiness check, and
restarted Pods enter `CrashLoopBackOff` until a valid license is installed.
`kubectl describe pod` and the Pod logs name the expiry, the end of the grace
window, and the fix. Subscribers and the dashboard keep running, no data is
deleted, and ingest and API access resume where they left off. Note that
`helm upgrade --wait` blocks while Pods are unready.

## Hosts

**Values:** `hosts`. The starter sets `domainBase`.

External hostnames derive from `hosts.domainBase`. Override any of them
individually when your naming scheme differs. Do not use template expressions
in `hosts.*`; several templates read these values verbatim.

| Default host | Value | Serves |
|---|---|---|
| `dashboard.<domainBase>` | `hosts.dashboard` | Hermetiq dashboard (`web-ui`) |
| `bep.<domainBase>` | `hosts.bepGrpc` | BEP ingest gRPC endpoint that Bazel streams build events to |
| `api.<domainBase>` | `hosts.apiGrpc` | Hermetiq gRPC API |
| `api-web.<domainBase>` | `hosts.api` | Hermetiq web and REST API |
| `mcp.<domainBase>` | `hosts.mcp` | Hermetiq MCP server |
| `grafana.<domainBase>` | `hosts.grafana` | Grafana behind the SSO proxy; rendered while `gateway.routes.grafanaEnabled: true`, the default |
| `bbcal.<domainBase>` | `hosts.bbcalGrpc` | Optional Bazel remote-cache endpoint served by the publisher; rendered when `gateway.routes.bbcalGrpcEnabled: true` |

Register DNS records, TLS certificates, and OIDC callback URLs for these hosts
before installing; a wildcard for `*.<domainBase>` covers the defaults.
[Routing](#routing) configures the routes that expose them.

Several other defaults derive from `domainBase`. Set the value in the right
column only when your deployment uses a different address:

| Derived default | Override with |
|---|---|
| Buildbarn Browser link, `https://browser.<domainBase>` | `bootstrap.namespaceBrowserUrl` |
| Grafana overview dashboard, `https://grafana.<domainBase>/d/hermetiq-demo` | `bootstrap.namespaceDashboardUrl` and `victoriaMetrics.dashboardUrl`; `hosts.grafana` changes the host for both |
| BEP token audience, `https://bep.<domainBase>` | `publisher.jwks.audience` |
| MCP resource, `https://mcp.<domainBase>` | `api.mcpResourceUrl` |
| Quickstart remote-cache URL, `grpcs://bb.<domainBase>`, or the `bbcal` host when that route is enabled | `dashboard.remoteCacheUrl` |
| oauth2-proxy redirect allowlist, `.<domainBase>` | add entries to `dashboard.oauth2Proxy.whitelistDomains` |

## PostgreSQL and schema management

**Values:** `bootstrap`, `postgres`, `partitionMaintenance`,
`progressesPartitionMaintenance`, `targetTrendsRefresh`. The starter sets the
connection, the retention, and the partition interval.

[PostgreSQL](#postgresql) under the prerequisites covers what the database
server must provide. This section covers what the chart does with it.

### Connection

```yaml
postgres:
  host: <db-host>
  database: hermetiq_helm
  user: hermetiq_helm
  password:
    existingSecret: postgres-db
    existingSecretKey: password
```

| Value | Default | Purpose |
|---|---|---|
| `postgres.port` | `5432` | Port of the primary |
| `postgres.sslMode` | `require` | TLS mode for connections |
| `postgres.password.existingSecret` | `postgres-db` | Secret that holds the password, under `existingSecretKey` |
| `postgres.readReplica.host`, `postgres.readReplica.port` | empty | Optional read replica. Dashboard Trends and MCP analytics queries go to it, so they do not compete with subscriber inserts on the primary. |

### Bootstrap job

The schema bootstrap Job is a Helm `pre-install` and `pre-upgrade` hook by
default, so schema migrations are applied before the workloads roll forward.
That has three consequences:

- Keep `postgres.password.existingSecret` set. Hooks run before Helm creates
  chart-managed Secrets, so the Secret must already exist.
- A successful hook Job stays in the namespace for log inspection. Helm
  deletes it just before the next install or upgrade creates a new one.
- On the first install the hook also runs before the chart's ServiceAccount
  exists, so that one run uses the namespace's `default` ServiceAccount, with
  no token mounted. Set `serviceAccount.create: false` with a pre-created
  ServiceAccount to bind it on the first install as well.

Setting `bootstrap.hook.enabled: false` turns the Job into an ordinary release
resource named `database-schema-bootstrap-<revision>`, removed
`bootstrap.ttlSecondsAfterFinished` seconds after it finishes. Helm then no
longer completes the migrations before it rolls the Deployments. In that mode
the chart can create the database Secret for you: set
`postgres.password.existingSecret: ""` and `postgres.password.value`, and it
creates a Secret named `postgres`.

### Default project

With `bootstrap.projectName` set, the bootstrap Job creates the first project
and its managed Buildbarn namespace entry. The chart defaults already do this;
the commented block in the starter only shows where to change them. To skip
project creation, clear both `bootstrap.projectName` and
`bootstrap.projectId`.

| Value | Default | Purpose |
|---|---|---|
| `bootstrap.projectName` | `build-analytics` | Name of the project to create |
| `bootstrap.projectId` | `"0"` | ID of that project. Buildbarn configuration and the RBE access policy refer to it, so change it there too. Leave it empty to have a UUID generated. Rendering fails if it is set without `projectName`. |
| `bootstrap.projectNamespace` | release namespace | Namespace Buildbarn runs in. Set it when Buildbarn is installed elsewhere. The bundled Grafana dashboards use it for their initial Buildbarn metrics filter. |
| `bootstrap.namespaceBrowserUrl`, `bootstrap.namespaceDashboardUrl` | derived from `hosts.domainBase` | Buildbarn Browser and Grafana links stored with the namespace; see [Hosts](#hosts) |

### Partition policy

The first successful bootstrap creates time-based partitions for the analytics
tables from three values:

| Value | Default | Meaning |
|---|---|---|
| `bootstrap.partitionInterval` | `6 hour` | Time covered by each partition. `12 hour` and `1 day` are common with longer retention. |
| `bootstrap.retentionDays` | `30` | Days of analytics data to keep |
| `bootstrap.premake` | `30` | Number of future partitions maintenance keeps created |

`public.progresses`, which holds build log output, has its own policy: hourly
partitions kept for two days. See
[Progress log storage](#progress-log-storage).

These values only seed `pg_partman`. After the first bootstrap,
`public.part_config` is authoritative: later bootstrap runs do not overwrite
an operator's changes, and the maintenance jobs read retention from that
table, not from `bootstrap.retentionDays`. To change retention or premake
later, update `public.part_config`. Do not change `partition_interval` in
place, because a different interval requires rebuilding the affected
partition set.

Size these for your expected ingest before the first install.
[Large-scale deployments](#large-scale-deployments-and-high-throughput-ingest)
has the partition arithmetic for long retention windows.

### Maintenance CronJobs

| CronJob | Values block | Default schedule | Does |
|---|---|---|---|
| `partition-maintenance` | `partitionMaintenance` | `0 1 * * *` | `pg_partman` maintenance for the analytics tables |
| `progresses-partition-maintenance` | `progressesPartitionMaintenance` | `15 * * * *` | The same for `public.progresses` |
| `target-trends-refresh-short` | `targetTrendsRefresh` (`shortSchedule`) | `5 * * * *` | Refreshes target trends for the 3- and 7-day windows |
| `target-trends-refresh-long` | `targetTrendsRefresh` (`longSchedule`) | `20 0 * * *` | Refreshes target trends for the 15- and 30-day windows |

Watch their most recent Jobs. Default partitions must stay empty: rows
accumulating in a `*_default` table mean a partition is missing or maintenance
is failing. [Inspect database partitions](#inspect-database-partitions) has
the queries and the commands to run maintenance by hand.

## Routing

**Values:** `routing`, `gateway`, `tls`, `contour`, `ingress`. The starter
selects `routing.provider: gateway` and names the Gateway.

### Providers

`routing.provider` chooses the resources that expose the chart's hosts:

| `routing.provider` | Use with | Renders |
|---|---|---|
| `gateway` | Envoy Gateway, or another Gateway API controller that supports `GRPCRoute` | `GRPCRoute` for BEP and the gRPC API; `HTTPRoute` for the web API, dashboard, MCP, and Grafana; the [Envoy Gateway policies](#envoy-gateway-policies) |
| `gateway-httproute-only` | GKE Gateway, which supports `HTTPRoute` but not `GRPCRoute` | `HTTPRoute` for every host; a GKE `HealthCheckPolicy` and `GCPBackendPolicy` |
| `contour` | Contour | `HTTPProxy` for every host |
| `ingress` | ingress-nginx | `Ingress` for every host, with the class from `ingress.className` (default `nginx`) |
| `none` | Your own Gateway, Ingress, HTTPProxy, or service-mesh routes | Internal Services only |

Set the provider explicitly. Left empty, the chart falls back to the older
`gateway.enabled` and `contour.enabled` flags, which select `gateway` by
default. `routing.enabled: false` is equivalent to `none`; both also skip the
route TLS Certificates and the Envoy Gateway and GKE policies.

For the Gateway providers, the chart attaches its routes to a Gateway that you
create. It never creates one. Create the Gateway, its listeners, DNS, and TLS
first, then name it:

```yaml
routing:
  provider: gateway
gateway:
  name: hermetiq-gateway
  # namespace: <gateway-namespace>   # when it differs from the release namespace
```

Routes attach by Gateway name and namespace only; there is no per-route
listener (`sectionName`) setting. Gateway providers expect TLS to be
terminated on the Gateway's listeners, with a certificate that covers the
chart's [hosts](#hosts). When the Gateway is in another namespace, its
listeners must allow routes from the release namespace (`allowedRoutes`), and
whoever runs Helm needs permission to create the CORS and client traffic
policies in the Gateway's namespace; see
[Envoy Gateway policies](#envoy-gateway-policies).

With `gateway-httproute-only`, the GKE `HealthCheckPolicy` for the API Service,
which mixes gRPC and HTTP ports, checks `GET /ready` on container port `8008`.

### What the public routes forward

Upgrades using `--reuse-values` get the new BEP service and identity-header
restrictions even when those keys are absent from the previous release's
values. Explicit service lists and empty header-removal lists keep their
configured meaning.

The public BEP route forwards only the gRPC services in
`gateway.routes.bepGrpcServices`, by default Bazel's Build Event Service
(`google.devtools.build.v1.PublishBuildEvent`). It is a method match on the
`gateway` GRPCRoute and a `/<service>/` path prefix on the other providers. The
publisher also serves Buildbarn's CompletedActionLogger, which it admits by
source address (`publisher.trustedCalCidrs`); relayed by a gateway or ingress
proxy, an internet caller would present the proxy's pod IP. Workers reach CAL
in-cluster and need no route. Add a service to the list only if clients outside
the cluster need it.

The public api-web route removes the request headers in
`gateway.routes.apiWebRemoveRequestHeaders` (`X-Forwarded-User`,
`X-Forwarded-Email`, `X-Forwarded-Groups`, `X-Forwarded-Preferred-Username`,
and `X-Hermetiq-Project-Id`), because several `/api/v1` handlers take the
caller's identity from `X-Forwarded-User`. Gateway modes use a
`RequestHeaderModifier` filter and Contour a `requestHeadersPolicy`. Ingress
needs an nginx `configuration-snippet`, which ingress-nginx rejects unless the
controller sets `allow-snippet-annotations: "true"` and
`annotations-risk-level: Critical`, so it is opt-in:
`ingress.apiWeb.stripIdentityHeaders=true`. Otherwise clear these headers in
the controller's `proxy-set-headers` ConfigMap or in a proxy in front of it. Set
the list to `[]` only when a trusted proxy in front of the route sets these
headers. If `ingress.apiWeb.annotations` or `commonAnnotations` already supplies
a `configuration-snippet`, combine the header-removal directives into that
snippet and leave `stripIdentityHeaders=false` to avoid duplicate annotations.

> ⚠ Header removal is defence in depth. Authentication of the on-prem REST API
> (`/api/v1` on `api-web`) depends on bep-nats itself rejecting unauthenticated
> requests; until your bep-nats release does, keep the `api-web` host on a
> network you trust.

### TLS certificates

Gateway providers use the certificate on the Gateway. For Contour and Ingress,
choose one of three approaches:

1. An existing wildcard Secret. Set `tls.secretName`; every route uses it and
   no Certificate is rendered.
2. One shared cert-manager Certificate. Set `tls.certificate.enabled: true`
   and `tls.certificate.issuerRef.name` to an existing issuer, a
   `ClusterIssuer` unless you change `issuerRef.kind`. The chart refuses to
   render without the issuer name. The Certificate and its Secret are named
   `hermetiq-wildcard-tls` and cover `*.<domainBase>` unless you set
   `tls.certificate.dnsNames`.
3. Per-route certificates. For Contour, `contour.certManager.enabled: true`
   (the default) renders a `Certificate` for each route; set
   `contour.certManager.clusterIssuer` to an existing `ClusterIssuer`. For
   Ingress, `ingress.certManager.enabled: true` (off by default) adds
   cert-manager issuer annotations so that its ingress-shim creates them; set
   `ingress.certManager.clusterIssuer`.

Options 2 and 3 need cert-manager in the cluster, and `tls.secretName` cannot
be combined with `tls.certificate.enabled`. Without cert-manager, provide the
TLS Secrets that the routes reference yourself.

### Envoy Gateway policies

With `routing.provider: gateway`, the chart renders Envoy Gateway
(`gateway.envoyproxy.io`) resources next to the standard routes:

| Kind | Purpose | Toggle |
|---|---|---|
| `BackendTrafficPolicy` | Active health checks and route timeouts for the BEP, gRPC API, `bbcal`, web API, and MCP routes; timeouts for the dashboard BFF | `gateway.healthChecks.enabled`, `gateway.timeouts.enabled` |
| `SecurityPolicy` | CORS for the Gateway and for the MCP route | `gateway.cors.enabled` |
| `ClientTrafficPolicy` | [Client connection tuning](#client-connection-tuning-for-high-rtt-clients) | `gateway.clientTrafficPolicy.enabled`, off by default |
| `EnvoyPatchPolicy` | Preserve gRPC-web on the dashboard's same-origin API path | `gateway.dashboardGrpcWeb.enabled`, on by default |

Health checks probe gRPC routes over TCP and HTTP routes on unauthenticated
readiness or metadata endpoints. The dashboard gets a timeout-only policy,
`<dashboard-route>-timeouts`, without active health checks. Grafana gets no
`BackendTrafficPolicy`. The Gateway-wide CORS policy (`gateway-cors-policy`)
and the `ClientTrafficPolicy` and `EnvoyPatchPolicy` are created in the Gateway's namespace, because
a policy must live beside the Gateway it targets.

Health checks and timeouts for a route share one `BackendTrafficPolicy`, named
`<route>-health-check`. Envoy Gateway does not merge policies of the same kind
that target the same route at the same level: it applies the oldest and marks
the rest `Overridden=True`. Keep that in mind before adding policies of your
own.

On a `GRPCRoute`-capable controller that is not Envoy Gateway, these kinds do
not exist and the install fails on unknown kinds. Disable them:

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
  dashboardGrpcWeb:
    enabled: false
```

Two caveats apply. With `assistant.enabled: true` the chart still renders the
API gRPC and dashboard routes' `BackendTrafficPolicy` resources, because they
carry the assistant's streaming timeout. And without the timeout policies, whatever default route
timeout your controller applies governs long-lived gRPC streams; check that it
does not truncate BES uploads.

### Dashboard gRPC-web forwarding

The dashboard's `/grpc/` calls pass through oauth2-proxy and nginx before reaching
the API's gRPC-web adapter. They must keep their gRPC-web framing along this
HTTP/1.1 path. Envoy Gateway's shared gRPC-web filter otherwise translates them
to native gRPC too early, producing HTTP 505 even though `/auth/me` succeeds.

With `routing.provider: gateway`, the chart's `EnvoyPatchPolicy` disables that
translation only for the configured dashboard hostname. The API and Buildbarn
hosts keep their existing translation, and other virtual-host filters are
preserved. The policy is not rendered for Contour, ingress-nginx, or GKE's
`gateway-httproute-only` provider.

> **Contour is not verified for the dashboard in this release.** Contour's
> Envoy enables the same gRPC-web translation on every route and has no
> per-route setting to turn it off, so dashboard queries under
> `routing.provider: contour` are expected to return HTTP 505 while sign-in
> works. The API, MCP and BEP hosts are not affected. The install notes repeat
> this warning. Verify a dashboard query after installing, or use
> `routing.provider: gateway` with Envoy Gateway, or `ingress`. ingress-nginx
> and GKE's load balancer do not translate gRPC-web and need no exception.

Enable patch policies in the Envoy Gateway controller before installing Hermetiq.
For the controller's Helm chart, merge this into its existing values:

```yaml
config:
  envoyGateway:
    extensionApis:
      enableEnvoyPatchPolicy: true
```

Restart the controller after updating its configuration. See the
[Envoy Gateway patch-policy guide](https://gateway.envoyproxy.io/v1.7/tasks/extensibility/envoy-patch-policy/)
for the controller setup. This controller setting is separate from the Hermetiq
chart's values:

```yaml
gateway:
  dashboardGrpcWeb:
    enabled: true
    listenerNames: [https]
```

Set `listenerNames` to every HTTPS listener serving the dashboard. The default
is `https`; the chart supports per-Gateway HTTPS listeners and derives each
route-configuration name as `<Gateway namespace>/<Gateway name>/<listener>`.
This HTTPS format is unchanged by Envoy Gateway's `XDSNameSchemeV2`; the policy
has been verified with v1.7.2. See the
[xDS naming reference](https://gateway.envoyproxy.io/v1.8/tasks/extensibility/envoy-patch-policy/#xds-name-scheme-v2).

For plaintext HTTP listeners with `XDSNameSchemeV2`, route-configuration names
use `http-<port>`. With `mergeGateways`, Envoy Gateway requires the patch policy
to target the GatewayClass. For either layout, install an operator-managed
dashboard exception using the actual xDS names and target, then set
`gateway.dashboardGrpcWeb.enabled: false` to avoid rendering this chart's
per-Gateway policy. The exception must preserve gRPC-web on the dashboard host;
disabling the chart policy alone does not correct the transport.

Confirm the applicable `EnvoyPatchPolicy` reports `Programmed=True` after the
upgrade, and verify a dashboard gRPC call as well as sign-in. A policy that
names a missing listener cannot protect that route. For another Gateway
implementation, disable `gateway.dashboardGrpcWeb.enabled` with the other
Envoy-specific policies above.

### Route timeouts

`gateway.timeouts` sets Envoy Gateway timeouts on the chart's gRPC, web API,
dashboard, and MCP routes. It applies to `routing.provider: gateway` only and is on by
default. Without it, Envoy applies its 15-second default route timeout. The
other providers bound the gRPC routes and the dashboard route with one
setting each, 300 seconds by default: Contour through
`contour.httpProxy.responseTimeout`, nginx Ingress through
`ingress.grpc.proxyReadTimeoutSeconds` and `proxySendTimeoutSeconds`, and GKE
through `gateway.gke.backendPolicy.timeoutSec`. The dashboard route is
included because the dashboard's own API calls arrive on it. With the
assistant enabled, the API and dashboard bounds are raised to at least
`assistant.streamTimeoutSeconds` on every provider.

| Route | `requestTimeout` | `maxStreamDuration` |
|---|---|---|
| `bepGrpc` | `0s` | `0s` |
| `apiGrpc` | `300s` | not set |
| `bbcalGrpc` | `0s` | `0s` |
| `apiWeb` | `300s` | not set |
| `dashboard` | `300s` | not set |
| `mcp` | `300s` | `0s` |

`"0s"` disables a timeout; it does not mean "immediate". A value that is not
set is omitted, which leaves Envoy's own default in place. Each of these
routes also sets `connectionIdleTimeout: 1h`. Grafana has no chart-managed
timeouts.

Envoy measures a route timeout from the end of the downstream request (the
client's half-close) to the completed upstream response. It therefore does not
cap the upload phase of a bidirectional stream. It does cap everything after
the half-close, and it caps a server-streaming response in full, because those
clients half-close immediately. That explains the defaults:

- `bepGrpc`: Bazel's BES `PublishBuildToolEventStream` is bidirectional and
  lives for the whole build, so the upload phase is not exposed, but the drain
  after Bazel half-closes is. Under the default
  `--bes_upload_mode=wait_for_upload_complete`, Bazel blocks there until the
  publisher acknowledges the remaining events. A publisher under NATS
  backpressure or in the middle of a rollout can exceed 15 seconds, which
  surfaces as a BES upload failure at the end of an otherwise successful
  build. `PublishLifecycleEvent` on the same route is unary and capped
  outright. Bound this route with Bazel's `--bes_timeout` instead.
- `apiGrpc`: unary analytics queries from the dashboard, MCP, and the CLI.
  Fifteen seconds is a plausible p99 for a wide-time-range Build History or
  trends query, and an Envoy reset surfaces as a generic gRPC error, not as a
  query timeout. The route is bounded, not disabled, and 300 seconds matches
  the Contour and GKE providers.
- `bbcalGrpc`: rendered only when `gateway.routes.bbcalGrpcEnabled: true`.
  Users are given this route as their Bazel `--remote_cache` endpoint, so it
  carries server-streaming `ByteStream/Read`, client-streaming
  `ByteStream/Write`, and unary CAS and AC calls. `ByteStream/Read` is the
  worst case: the client half-closes immediately, so a 15-second cap covers
  the entire blob download. The defaults mirror the Buildbarn chart's frontend
  timeouts.
- `apiWeb`: REST and gRPC-web traffic on the external API hostname. Analytics
  queries receive the same bound as `apiGrpc`.
- `dashboard`: same-origin browser REST and gRPC-web calls through the
  authenticated dashboard BFF, with the same bound as the external API.
  Assistant streams also use this route, so enabling the assistant raises its
  request and stream limits to at least `assistant.streamTimeoutSeconds`.
- `mcp`: streamable-HTTP MCP traffic. A tool call can run a wide-time-range
  analytics query while the response stream stays open, so it needs the same
  headroom as `apiGrpc`.

Set `gateway.timeouts.enabled: false` to drop the chart-managed timeouts and
keep the health checks. With `assistant.enabled: true`, the API gRPC and
dashboard routes retain timeout policies even when ordinary timeouts are
disabled, and their request and stream limits are raised to at least
`assistant.streamTimeoutSeconds`; see [Streaming timeout](#streaming-timeout).

### Client connection tuning for high-RTT clients

`gateway.clientTrafficPolicy.enabled: true` renders an Envoy Gateway
`ClientTrafficPolicy` for the client-to-Envoy leg. It applies to
`routing.provider: gateway` only. The chart default is off and the starter
values turn it on; enable it when Bazel clients are far from the cluster.

Envoy Gateway's own defaults are conservative for build traffic. The chart's
values replace them:

| Setting under `gateway.clientTrafficPolicy` | Envoy Gateway default (v1.7.2) | Chart value |
|---|---|---|
| `bufferLimit`, the per-connection buffer | 32Ki | `8Mi` |
| `http2.initialStreamWindowSize` | 64Ki | `16Mi` |
| `http2.initialConnectionWindowSize` | 1Mi | `24Mi` |
| `http2.maxConcurrentStreams` | 100 | `1024` |
| `timeout.http.idleTimeout` | 1h | `7200s` |
| `tcpKeepalive` | | 60s idle, 15s interval, 5 probes |

The buffer limit matters most. At 32Ki, large BEP uploads and CAS blob
transfers hit watermark backpressure almost immediately, and every drain and
refill costs a full client round trip. The HTTP/2 windows are a second,
independent cap, so raising only `bufferLimit` can still produce
`413 request_payload_too_large`. The idle timeout is what prevents connection
churn: Envoy's HTTP idle timeout is request-based, and neither HTTP/2 PINGs
nor TCP keepalives reset it.

The policy is Gateway-scoped, so one policy covers every route on the target
listener: this chart's BEP, API, dashboard, and MCP routes and, on a shared
Gateway, the Buildbarn chart's CAS and AC routes. The Buildbarn chart ships
the same settings under the same key for standalone installs. Enable the
policy in exactly one chart. `ClientTrafficPolicy` resources do not merge:
with two on one Gateway, the oldest by creation time wins and the other
reports `Overridden=True`. The charts use different default policy names
(`hmq-gateway-client-traffic` and `bb-gateway-client-traffic`), so an
accidental double enable shows up in policy status, not as a Helm ownership
conflict.

Watch two things after enabling it. `bufferLimit` is per-connection memory on
the Envoy proxy, which often runs as a single replica, so check its memory
use. And without `gateway.clientTrafficPolicy.sectionName` the policy applies
to every listener on the Gateway; a listener-scoped policy fully overrides a
Gateway-scoped one instead of combining with it.

On TLS listeners the policy also advertises `h2` for gRPC and `http/1.1` for
browser traffic through `spec.tls.alpnProtocols`.

## Redis-compatible cache

**Values:** `redis`. The starter points at the DragonflyDB Service and its
password Secret.

```yaml
redis:
  host: dragonfly.hermetiq.svc.cluster.local
  password:
    existingSecret: dragonfly-auth
```

`redis.host` is required. The password is read from the Secret named by
`redis.password.existingSecret`, under `redis.password.existingSecretKey`
(default `password`). `redis.password.value` is the inline alternative. A
host and a password are all the chart passes to the application.

This is a rebuildable cache, not a system of record. With
[cache-event analytics](#cache-event-analytics) enabled it also holds digest
metadata, so size its memory for your Buildbarn shard count; see
[Large-scale deployments](#large-scale-deployments-and-high-throughput-ingest).
[DragonflyDB or Redis](#dragonflydb-or-redis) under the prerequisites covers
installing the cache itself.

## NATS ingest and stream configuration

**Values:** `nats`, `app.streamPartitionCount`. The starter sets `nats.url`
and a partition count of 4.

`nats.url` is the NATS client endpoint and is required. Hermetiq creates its
own streams there. [NATS JetStream](#nats-jetstream) under the prerequisites
covers the server.

### Stream partitions

`app.streamPartitionCount` sets the number of ingest partitions, N. For each
partition `i` from 0 to N-1 there is:

- one subscriber Deployment, `bep-nats-sub-<i>`, and
- one set of JetStream streams: `BEP_BUILD_TOOL_<i>`, `CACHE_EVENTS_<i>`,
  `CACHE_ENRICH_<i>`, and `ACTION_STREAM_<i>`.

An invocation is assigned to a partition by `fnv32a(invocation_id) % N`, and
that partition's subscriber processes its events in order. Keep
`subscriber.replicas: 1`, because one consumer per partition is what preserves
per-build ordering. Subscriber Deployments roll with `maxSurge: 0` and
`maxUnavailable: 1`, so two consumers never run on one partition.

When choosing N:

- The chart default is `9`. The starter values set `4`.
- When Buildbarn's grpc-cache-proxy sidecar is enabled, its
  `frontend.grpcCacheProxy.cacheEvents.numShards` must equal
  `app.streamPartitionCount`. Shards above the partition count have no stream
  or subscriber, and their events are dropped. The Buildbarn chart's own
  default is `1`, so set it explicitly; the starter `buildbarn-values.yaml`
  suggests `4` to match.
- Choose N before production traffic starts. Changing it alters the stream and
  Deployment topology, and reducing it leaves unconsumed messages on the
  higher-numbered streams.
  [Large-scale deployments](#large-scale-deployments-and-high-throughput-ingest)
  has a sizing table.

### Stream configuration

The chart renders its packaged `files/config/nats_streams.json` into the
`bep-nats-stream-config` ConfigMap. The file defines these streams:

| Stream | Storage | Replicas | Retention |
|---|---|---|---|
| `BEP_BUILD_TOOL_<i>` | file | 3 | 30 minutes |
| `ACTION_STREAM_<i>` | file | 1 | 30 minutes |
| `CACHE_EVENTS_<i>` | memory, 128 MiB per partition | 1 | 5 minutes |
| `CACHE_ENRICH_<i>` | file | 1 | 1 hour |
| `FWD_STREAM` | file | 1 | 10 minutes |

Each of the first four has a dead-letter stream (`BEP_DLQ_STREAM`,
`ACTION_DLQ_STREAM`, `CACHE_DLQ_STREAM`, `CACHE_ENRICH_DLQ_STREAM`), kept for
24 hours, or 6 hours for actions.

Only the build-tool stream is replicated, because the whole ingest path
depends on it; that is why [NATS needs three servers](#nats-jetstream). An
existing stream keeps the settings it was created with. To change the
configuration, copy the packaged file, edit it, and point
`nats.streamConfig.existingConfigMap` at your own ConfigMap:

```yaml
nats:
  streamConfig:
    existingConfigMap: hermetiq-nats-stream-config
    configMapKey: nats_streams.json
    rolloutChecksum: "sha256-or-version-of-the-config"
```

Two edits are common:

- For a single-server test NATS, set `"replicas": 1` on
  `bep.buildToolStream`.
- For resilience to NATS node loss on the action and cache-enrich streams in
  production, raise `action.stream.replicas` and
  `cacheEnrich.stream.replicas` to `3`.

The selected key is mounted at `/config/nats-streams/nats_streams.json` in
the publisher and subscriber Pods. Change `rolloutChecksum` whenever the
external content changes; see
[External configuration ConfigMaps](#external-configuration-configmaps).

The same file tunes the subscribers. Per consumer, `workerQueueCapacity`,
`pipelineMaxQueuedMessages`, and `pipelineMaxQueuedBytes` control fetch-ahead;
keep `maxAckPending` at or above `pipelineMaxQueuedMessages` so that the
server does not cap the pipeline first. `storeBatchMaxEvents`,
`storeBatchMaxWait`, and `storeBatchParallelism` control how database calls
are coalesced. These are advanced settings. Start with the packaged file and
change them only with ingest, NATS, and database telemetry in view.

## Observability

**Values:** `otel`, `victoriaMetrics`, `promqlQueries`,
`app.victoriaLogsEnabled`. The starter sets the OTLP endpoint and the
VictoriaMetrics query URL, and enables the metrics-backed tools.

### OpenTelemetry

```yaml
otel:
  endpoint: http://otel-collector.hermetiq.svc.cluster.local:4317
```

`otel.endpoint` is required. The Hermetiq workloads send their metrics and
traces to this OTLP receiver. Give the full URL, with scheme and port; the
Buildbarn chart's `hosts.otel`, by contrast, takes a bare hostname.

| Value | Default | Purpose |
|---|---|---|
| `otel.protocol` | `grpc` | OTLP transport |
| `otel.serviceName` | `hermetiq` | Service name attached to the telemetry; required |
| `otel.mtls.enabled`, `otel.mtls.secretName` | `false`, empty | Mounts the named Secret at `otel.mtls.mountPath` (default `/config/mtls`) for mutual TLS to the collector |

### Metrics-backed infrastructure tools

```yaml
victoriaMetrics:
  metricsEnabled: true
  projectLabelEnabled: true
  projectLabel: namespace
  baseUrl: http://vmselect-vmks.hermetiq.svc.cluster.local:8481/select/0/prometheus
```

`victoriaMetrics.metricsEnabled` (chart default `false`) registers the MCP
server's five PromQL-backed Buildbarn health tools. The two
VictoriaLogs-backed tools share the same client, so they are registered only
while it is on. The remaining MCP tools are unaffected. Enable it only when
the API can reach the read endpoint.

`victoriaMetrics.baseUrl` must be the VictoriaMetrics Prometheus-compatible
read endpoint: vmselect, including its `/select/<tenant>/prometheus` path. It
is not the vminsert endpoint. Left empty, the application falls back to a URL
that only suits a stack installed as `vm` in an `obs` namespace, so set it.

`victoriaMetrics.projectLabelEnabled` scopes the packaged PromQL selectors to
the project, and `victoriaMetrics.projectLabel` (default `namespace`) names
the label. With `namespace`, queries match the project's Buildbarn namespace
setting, which must name the namespace Buildbarn runs in; the Buildbarn
chart's recording rules keep that label. The RBE Infrastructure page and
Barn Owl's namespace evidence need this scoping. Leave it `false` only for a
self-managed, single-tenant Buildbarn whose metrics do not follow those rules.

### PromQL query configuration

The MCP infrastructure tools read their query templates from
`/config/promql/promql.json`. The packaged templates target the recording
rules shipped with the Hermetiq Buildbarn chart. A self-managed Buildbarn with
different recording-rule names can supply a replacement ConfigMap:

```yaml
promqlQueries:
  existingConfigMap: hermetiq-promql-config
  configMapKey: promql.json
  rolloutChecksum: "sha256-or-version-of-the-config"
```

Partial overrides are supported. Unknown template placeholders and blank
required queries fail API startup, so that an incomplete file cannot silently
return incomplete diagnostics.

Scheduler queue assessments join measurements on
`(instance_name_prefix, platform, size_class)`. Overrides for executing peaks,
saturated minutes, and completed actions must preserve all three labels.
Aggregating the prefix away combines shared and private queues and prevents
private-pool capacity diagnosis.

Worker-pool CPU and memory request charts use `rbePoolPods` to select pods
through their ReplicaSet and Deployment owners, excluding pods created before
the current Deployment. The ownership selection is fixed at the requested
window end; query length does not grow with pod churn. Custom overrides of
`rbeContainerCpuRequestPercent` and `rbeContainerMemoryRequestPercent` must
use the `${poolPods}` expression in both usage and request sums. Override
`rbePoolPods` too if your installation renames the Kubernetes ownership
metrics or labels.

The templates load at API startup. After changing an external ConfigMap,
change `promqlQueries.rolloutChecksum` or restart the API; see
[External configuration ConfigMaps](#external-configuration-configmaps).

### Dashboards and scrape objects

The chart renders two kinds of objects for the metrics stack.

The first is Grafana dashboards. Each packaged dashboard becomes a ConfigMap
named `hermetiq-grafana-dashboard-<name>` with the label
`grafana_dashboard: "1"`, which the metrics stack from the repository guide
loads into Grafana. They cover BEP ingest, query and SQL performance, NATS and
JetStream, DragonflyDB, an overview (`hermetiq-demo`), and six Buildbarn
dashboards. The dashboard JSON is rendered with the default project ID, the
Buildbarn namespace, and two datasource UIDs. Override
`victoriaMetrics.metricsDatasourceUid` (default `VictoriaMetrics`) and
`victoriaMetrics.logsDatasourceUid` (default `VictoriaLogs`) when Grafana
provisions the datasources under other UIDs.

The second is pod scrapes. `victoriaMetrics.natsPodScrape` and
`victoriaMetrics.dragonflyPodScrape` render `VMPodScrape` objects that scrape
the NATS and DragonflyDB Pods. Both are enabled by default. Each has a
`selectorLabels` map and a `port`; check that they match the labels and
metrics port of your NATS and DragonflyDB Pods.

> **Warning:** `VMPodScrape` is a VictoriaMetrics operator kind. On a cluster
> without the operator's CRDs, the install fails with
> `no matches for kind "VMPodScrape"`. Install the metrics stack first, or turn
> both scrapes off as shown below.

```yaml
victoriaMetrics:
  natsPodScrape:
    enabled: false
  dragonflyPodScrape:
    enabled: false
```

### VictoriaLogs

Set `app.victoriaLogsEnabled: true` only when VictoriaLogs is deployed and
reachable. Set `api.env.VL_BASE_URL` to its HTTP API endpoint, and keep
`victoriaMetrics.metricsEnabled: true` for the shared metrics and logs client.
This example enables event history and leaves cost reporting off:

```yaml
app:
  victoriaLogsEnabled: true
  costReportTickerEnabled: false
api:
  env:
    VL_BASE_URL: http://victorialogs.observability.svc.cluster.local:9428
victoriaMetrics:
  metricsEnabled: true
  baseUrl: http://vmselect.observability.svc.cluster.local:8481/select/0/prometheus
```

This chart does not install VictoriaLogs. Without it, Barn Owl still has core
metrics and Kubernetes evidence, and reports event history as unavailable. If
an enabled source fails, Barn Owl reports incomplete coverage. Read that as
missing data, not as evidence that nothing happened.

## Workload identity

**Values:** `gcpWorkloadIdentity`, `azureWorkloadIdentity`,
`serviceAccount.annotations`. The starter enables `gcpWorkloadIdentity`; the
chart default is off.

Workload identity gives the Hermetiq Pods a cloud identity without stored
keys. Only the features that read or write object storage need it:
[progress log storage](#progress-log-storage), trace profiles, and output
files. Those features support Google Cloud Storage and Azure Blob Storage.
Remove the starter's block outside GKE, and on GKE if you use none of them.

```yaml
gcpWorkloadIdentity:
  enabled: true
  serviceAccount: hermetiq-bep@<gcp-project>.iam.gserviceaccount.com

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
ServiceAccount and to the API, publisher, subscriber, bootstrap, and
maintenance Pods, but not to the dashboard or the Grafana proxy, and it adds
the `azure.workload.identity/client-id` annotation to the ServiceAccount.

For another identity mechanism, set `serviceAccount.annotations`. Grant the
resulting identity only the object-storage permissions that the enabled
features need: progress-log storage needs read and write access for the
subscribers, and trace and output-file features may need additional read
access.

## Application settings

**Values:** `app`. The starter sets the partition count, cache-event queries,
and repository URL normalization. Configure administrator groups under
`authorization`; see [Admin access](#admin-access).

| Value | Chart default | Starter | Purpose |
|---|---|---|---|
| `app.streamPartitionCount` | `9` | `4` | Number of ingest partitions; see [Stream partitions](#stream-partitions) |
| `app.cacheEventsEnabled` | `false` | `true` | Cache-event queries and MCP tools; see [Cache-event analytics](#cache-event-analytics) |
| `app.normalizeRepoUrls` | `false` | `true` | Stores the SSH, HTTPS, and scp-style forms of one git remote under a single host/owner/repo key, so per-repository analytics group together |
| `app.grpcAuthUserProvider` | `jwks` | | Identity provider type for the API and publisher; see [gRPC authentication](#grpc-authentication) |
| `app.invocationStartEvent` | `build_tool` | | How invocation rows are created. Keep the default; `lifecycle` is a legacy mode. Set it here, never in a workload `env` map. |
| `app.victoriaLogsEnabled` | `false` | | VictoriaLogs-backed tools and RBE Kubernetes events; see [VictoriaLogs](#victorialogs) |
| `app.costReportTickerEnabled`, `app.openCostUrl` | `false`, empty | | OpenCost-backed cost reporting; see [Cost reporting](#cost-reporting) |
| `app.rawBepExportEnabled`, `app.rawBepExportBucket` | `false`, empty | | A separate archive of raw build events in a GCS bucket or Azure container, given as a bare name. It is unrelated to [progress log storage](#progress-log-storage). |
| `app.terminationGracePeriodSeconds` | `90` | | Termination grace for the API, publisher, and subscriber Pods. Keep it above the application's 80-second shutdown timeout, which in turn exceeds its 45-second endpoint drain. |

The remaining `app` values (`environment`, `otelInterval`, `buildIdMode`,
`buildIdRegex`, `taskQueueName`, `ghEnvDir`, `mcpProtoIntelToolsEnabled`) keep
their chart defaults in the starter.

## Authentication and SSO

**Values:** `oidc`, `api.jwt`, `publisher.jwks`, `publisher.trustedCalCidrs`,
`authorization`, `api.scim`, `dashboard.oauth2Proxy`,
`grafana.oauth2Proxy`. The starter sets the issuer and the OAuth client Secret;
configure project grants and administrator groups for your installation.

These controls answer different questions:

| Control | What it decides |
|---|---|
| `dashboard.oauth2Proxy.emailDomains` and `allowedGroups` | Who may sign in through the shared UI proxies. Passing this gate grants no Hermetiq or Grafana role. |
| `api.jwt.groupsClaim`, `publisher.jwks.groupsClaim` | Which verified JWT claim contains group names. These fields name a claim; they do not grant a role. |
| `authorization.administratorGroups` or the default verified admin group | Who administers the Hermetiq installation. See [Admin access](#admin-access). |
| `authorization.defaultAccess`, project memberships, `groupBindings`, and `serviceAccounts` | Which projects a principal may access and whether they have Viewer, Builder, or project Admin permissions. |
| Grafana's own organization roles | What a signed-in user may do in Grafana. Hermetiq project and installation roles do not assign Grafana roles. |

The [dashboard BFF](#browser-authorization-and-independent-jwt-profiles) transports
the signed-in user's token to the API; the API makes the permission decisions.

Three kinds of caller reach Hermetiq: browsers, which sign in through
oauth2-proxy; clients of the gRPC API, BEP ingest, and MCP endpoints, which
present bearer tokens; and Buildbarn workers, which present no credential and
are admitted by network position. Register the following with your identity
provider (IdP) before installing. The repository guide's
[identity provider](https://github.com/Hermetiq/hermetiq-k8s#identity-provider)
step covers the IdP side.

| IdP object | Register | Used by |
|---|---|---|
| Web application, Authorization Code flow | Callback `https://dashboard.<domainBase>/oauth2/callback`, plus `https://grafana.<domainBase>/oauth2/callback` and `https://browser.<domainBase>/oauth2/callback` for the UIs you enable | Dashboard, Grafana, and Buildbarn Browser sign-in |
| Machine-to-machine client | Audience `https://bep.<domainBase>`, with the client authorized for it | Bazel's BEP token (`--bes_backend`) |
| MCP resource | Identifier `https://mcp.<domainBase>/mcp`, with Dynamic Client Registration | MCP clients such as Claude Code, Cursor, and Codex |

### OIDC provider

Set the issuer once and the chart wires it into every consumer:

```yaml
oidc:
  issuerUrl: https://<tenant>.auth0.com/
```

The value feeds `api.jwt.issuer`, `api.jwt.jwksUrl`, `publisher.jwks.issuer`,
`publisher.jwks.url`, and `dashboard.oauth2Proxy.oidcIssuerUrl`. The JWKS URL
defaults to `/.well-known/jwks.json` under the issuer; set `oidc.jwksUrl` if
your provider publishes its keys elsewhere. An issuer or URL set on an individual
component still wins. Select an explicit `publisher.jwks.source` to use independent
publisher keys, as described below. Use the exact issuer string that appears in your tokens,
including a trailing slash if there is one.

The issuer cannot supply the token audiences or the Buildbarn trust boundary.
The next two sections cover those.

### gRPC authentication

The API and the publisher run the same application process, `bep-nats`, and
that process verifies bearer tokens itself: for the gRPC API and the MCP
endpoint in the API Pods, and for BEP ingest in the publisher Pods. It is
configured through `GRPC_AUTH_*` environment variables; `JWKS_*` variables
are not recognized. The API Pods keep a `grpc-auth-proxy` sidecar only for
gRPC-web framing and CORS. The process strips caller-supplied identity
headers, including `X-Forwarded-User`, before it authenticates.

`app.grpcAuthUserProvider` (default `jwks`) selects the verifier and is
required; the process refuses to start without it. There is no "off" setting:
selecting the provider is what turns verification on. For the API and for the
publisher, choose one configuration mode each.

1. Chart-managed, the default. Keep `api.jwt.enabled: true` and
   `publisher.jwks.enabled: true`. The issuer and JWKS URL derive from
   `oidc.issuerUrl`, and the audiences default as follows:

   | Workload | Audience value | Default |
   |---|---|---|
   | Publisher | `publisher.jwks.audience` | `https://bep.<hosts.domainBase>`, or `https://<hosts.bepGrpc>` when that host is overridden. Register it with the IdP and configure Bazel's BEP token to match. |
   | API | `api.jwt.audience` | The dashboard's oauth2-proxy client ID, read from the client Secret. The chart always adds the MCP resource URLs to it. If the dashboard oauth2-proxy is disabled, set this value; the chart refuses to render otherwise. |

   Group membership is read from the claim named by `api.jwt.groupsClaim` and
   `publisher.jwks.groupsClaim`, both `hermetiq/roles` by default. For example,
   `groupsClaim: hermetiq/roles` reads the array in `"hermetiq/roles":
   ["engineering"]`; it does not assign the engineering group any project role.
   Assign that group's permissions through the policy below.

2. Custom environment. Set the component's `enabled: false` and put a
   complete contract in `api.env` or `publisher.env`: exactly one non-empty
   `GRPC_AUTH_JWKS_URL`, `GRPC_AUTH_JWKS_FILE`, or `GRPC_AUTH_JWKS_INLINE`,
   plus non-empty `GRPC_AUTH_ISSUER` and `GRPC_AUTH_AUDIENCE`. The values may
   be literal scalars or Helm `tpl` expressions, which are the only forms the
   validation can inspect.

The chart validates both modes and refuses to render an incomplete
configuration. It also rejects those variables in `*.env` while the
chart-managed mode is on,
because that would produce duplicate or conflicting entries.
`GRPC_AUTH_USER_PROVIDER` is never set through `*.env`; use
`app.grpcAuthUserProvider`.

Buildbarn's completed-action calls carry no token. They are admitted only
through `publisher.trustedCalCidrs`, described next.

### Independent publisher signing keys and rotation

`publisher.jwks.source` selects the publisher's public key source while leaving
dashboard/API OIDC configuration intact:

| Source | Required publisher value | Behavior |
|---|---|---|
| `auto` (default) | Any of the values below | Use the publisher URL, then the inherited OIDC URL, then the Secret or inline JSON. Helm notes identify local keys shadowed by the inherited URL. |
| `url` | `publisher.jwks.url` | Fetch only this URL; do not inherit the global OIDC URL. |
| `inline` | `publisher.jwks.json` | Render a Secret containing this public JWK set and mount it as a file. A keyset change rolls the publisher Pods. |
| `secret` | `publisher.jwks.existingSecret` | Mount this Secret, which must contain `jwks.json`, as a projected directory without `subPath`. |

Explicit modes require `publisher.jwks.enabled=true` and reject other nonempty
publisher key-source values. Global `oidc` values may remain set. In `auto`, a
local keyset shadowed by a URL is not trusted; select `inline` or `secret` to
use it. `enabled=false` still means the custom-environment configuration
mode above, not disabled token validation.

For CI signing its own RS256 JWTs while dashboard users log in through Okta:

```yaml
publisher:
  jwks:
    source: inline
    issuer: https://ci.example.com/hermetiq
    audience: hermetiq-bep
    # Use service only when this entire trusted profile represents machines.
    principalKind: service
    json: |
      {"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"ci-1","n":"REPLACE_WITH_PUBLIC_MODULUS","e":"AQAB"}]}
```

Keep the private signing key with the issuer. Match `iss`, `aud` and the JWT header's
`kid`; use a stable `sub` such as `buildkite-ci`. This configures BEP authentication;
configure Buildbarn's issuer/audience/keys separately for cache or execution traffic.

Both `publisher.jwks` and `api.jwt` expose `refreshInterval` (default `1h`),
`refreshRateLimit` (`5m`), `refreshTimeout` (`10s`) and `fileReloadInterval` (`10s`).
They render the corresponding `GRPC_AUTH_JWKS_*` durations. The verifier validates
positive durations and limits the file reload interval to ten seconds. URL-backed
verification also refreshes on an unknown `kid`, subject to the refresh rate limit.
Mounted file reload starts once Kubernetes projects the update; projection latency
is additional. Inline updates roll Pods; existing-Secret updates do not require a
chart upgrade.

With single-issuer authentication, `api.env` and `publisher.env` can also set
`GRPC_AUTH_PRINCIPAL_KIND` and the four `GRPC_AUTH_JWKS_*` refresh/reload
settings. Each explicit environment override takes precedence over the
corresponding `api.jwt` or `publisher.jwks` field and is rendered once.
Independent JWT profiles require these settings inside each profile instead.

Publish overlapping old/new keys before switching signing keys, then replace
credentials and retire the old key deliberately. Multi-key overlap requires JWTs
to carry `kid`. Removing a key invalidates new requests using it, including requests
with still-unexpired long-lived JWTs. A credential helper forwards the JWT and does
not perform key rotation itself.

`principalKind` defaults to `human` and can be `service` for a
machine-only credential profile. It renders `GRPC_AUTH_PRINCIPAL_KIND`; the verifier
does not assume a provider's optional `idtyp` claim is present. Explicit service
registrations in the project policy identify registered machines even when they
share a profile with humans.

### Project access policy

The chart always enforces project authorization for the API, publisher, and
dashboard. The API and publisher share the `authorization` policy through
`PROJECT_AUTHORIZATION_CONFIG`, and the publisher requires `write:bep` permission
for the selected project. JWT verification and signed project restrictions also
apply. Configure grants and access defaults through the typed `authorization`
values; workload environment maps cannot disable or replace the chart's policy.

Before installing, prepare memberships and issuer-qualified group and
service-account grants. For example:

```yaml
authorization:
  defaultAccess: viewer
  groupBindings:
    - projectId: my-project
      issuer: https://idp.example.com/
      group: engineering
      roles: [builder]
  serviceAccounts:
    - issuer: https://ci.example.com/hermetiq
      subject: buildkite-ci
      projectRoles:
        my-project: [builder]
  instanceBindings:
    - namespace: my-buildbarn-namespace
      instancePrefix: my-instance
      projectId: my-project
```

`defaultAccess: viewer` is the default and grants automatic Viewer access to all
projects for authenticated humans. Select `none` when access must come from
explicit membership or group grants. Service accounts receive their explicit
project roles instead of the human baseline. Roles are `viewer` (read builds and
the cache, run remote execution), `builder` (also publish builds, write the cache, edit ConfigSets and
issue build credentials) and `admin` (everything, including project
administration); each includes the one before it. The API and publisher cache
access decisions for 30 seconds, so membership changes and
suspensions take effect within that window.

In the dashboard, **Users** shows direct project memberships in a table. Project
administrators can use **Manage** to change a member's role or remove their direct
membership, and **Add member** to assign a role to an existing principal.
**Project Settings → Access** contains group bindings, effective access details,
and the role-permission reference. Installation-managed grants remain in the
Helm `authorization` values. A person admitted through a group or the default
Viewer policy does not automatically appear as a direct member; removing a
direct membership does not revoke access from those other sources.

Issuing Hermetiq build credentials requires direct membership or SCIM-backed
grants. A Builder role obtained only through JWT groups can publish builds with
an issuer-provided credential helper, but cannot issue Hermetiq build credentials.

Use the project's actual saved managed namespace and instance mapping; an empty
`instancePrefix` is an explicit mapping choice, not an inferred default. Defining
these mappings does not automatically configure Buildbarn's listeners or trust.
With `api.mcpAuthDisabled=true`, MCP callers share its synthetic administrator
identity and cannot receive individual user revocation semantics.

### Application images

The API, publisher, schema bootstrap job, dashboard, and `grpc-auth-proxy`
enforce the policy together, so their images must come from the same
application release. The chart's default images are the `v1.0.0` release.

| Workload | Tag setting | Digest setting |
|---|---|---|
| API | `images.bepNats.apiTag` | `images.bepNats.apiDigest` |
| Publisher | `images.bepNats.pubTag` | `images.bepNats.pubDigest` |
| Subscribers | `images.bepNats.subTag` | `images.bepNats.subDigest` |
| Schema bootstrap and maintenance | `images.bepNats.bootstrapTag` | `images.bepNats.bootstrapDigest` |
| Dashboard and its init container | `images.dashboard.tag` | `images.dashboard.digest` |
| API auth proxy | `images.authProxy.tag` | `images.authProxy.digest` |

A nonempty digest takes precedence over the tag. When selecting another tag,
set its matching digest from that release or explicitly clear the digest with
`""`; changing only the tag keeps running the pinned image. JWT profile mode
needs an auth-proxy image that supports `GRPC_AUTH_PROXY_FORWARD_ONLY`, so
override the auth proxy together with the API and dashboard.

The chart refuses to render with images older than `v1.0.0`, which cannot
enforce the authorization policy or the browser flow. Custom tags and digests
are not recognised by that check; verify them against the same application
release before a staged rollout.

### External Auth0 credential helpers

An Auth0 helper using `grant_type: client_credentials` authenticates the
application named by the token's `sub`, commonly `<client-id>@clients`. It does
not inherit the user identity or installation-admin groups of the person who
created the application, owns its secret, or is signed in to the dashboard.
Browser email-domain admission does not apply to the BEP endpoint.

Grant the helper's exact verified `iss` and `sub` Builder access to each
required project.
For a token with issuer `https://idp.example.com/` and subject
`example-build-client@clients`:

```yaml
authorization:
  serviceAccounts:
    - issuer: https://idp.example.com/
      subject: example-build-client@clients
      projectRoles:
        my-project: [builder]
```

Replace these example values with the token's issuer and subject and the project
selected by Bazel's `--bes_instance_name`. Preserve the issuer's trailing slash
and quote numeric project IDs as YAML keys, for example `"0": [builder]`.
Merge the entry with existing grants, then apply the values with
`helm upgrade` and wait for the API and publisher rollouts. This registers that application as a service
principal even when humans share the same JWT trust profile; changing the whole
profile to `principalKind: service` is unnecessary in that case.

Verify the helper sends its JWT in `Authorization: Bearer <token>` for the
BEP hostname, with the audience accepted by `publisher.jwks.audience`, then run
a build with the matching project selected. Auth0 token scopes alone do not
create a Hermetiq project grant.

For diagnosis, gRPC `Unauthenticated` (code 16) means authentication failed;
check the credential, signature, issuer, audience, and expiry. A verified token
that lacks `write:bep` receives `PermissionDenied` (code 7); check the exact
principal's project grants. Successful token exchange or browser admin access
does not by itself establish permission for the helper's application token.

### Browser authorization and independent JWT profiles

The chart requires the dashboard's backend-for-frontend (BFF): an nginx reverse
proxy that sends browser API requests through the dashboard's own origin and
authenticated session. Browser calls to `/grpc/` and `/api/v1/` reach the API
through this proxy; `/auth/me` reads the API's authoritative identity and access
decision. The BFF forwards the ID token provided by oauth2-proxy, so the IdP must
include the configured groups claim in that ID token when using group grants.
Putting groups only in an access token does not supply them to this browser flow.

The BFF carries credentials; it does not grant permissions. API and publisher
authorization, the BFF, and dashboard oauth2-proxy are required by this chart.
Shared cookies and `authorization.defaultAccess` remain configurable. In Gateway
mode the browser uses the existing dashboard `HTTPRoute`; no dashboard
`GRPCRoute` is added. Envoy must preserve gRPC-web through the HTTP/1.1 proxy
chain; see [Dashboard gRPC-web forwarding](#dashboard-grpc-web-forwarding).
HTTP 505 on `/grpc/` while `/auth/me` succeeds indicates the transport problem
described there, not evidence that an administrator lost their group grant.

Use API, publisher, dashboard, and auth-proxy images from one release, as
described in [Application images](#application-images).

Grafana uses its own oauth2-proxy with the shared login-admission settings, then
applies its own organization roles. It does not use Hermetiq project
authorization; see [Grafana SSO](#grafana-sso).

`api.jwt.profiles` and `publisher.jwks.profiles` optionally replace the
single-issuer settings. Each entry supplies `name`, `issuer`, `audiences`,
`principalKind: human|service`, `credentialUse: browser|build`, and exactly one
of `jwksUrl`, `jwksInline` (JSON string), or `existingSecret` with optional
`existingSecretKey` (default `jwks.json`). Optional `userIdClaim`, `userIdPrefix`,
`groupsClaim`, `allowedAlgs` and refresh durations apply independently. Preserve
existing IDs; reserve separate nonempty prefixes for distinct issuers. Project
and groups claims are optional for CI credentials; current project grants still
control authorization. The API sidecar delegates verification to the core in
profile mode and strips asserted identity/XFCC. Secret directory mounts permit
key rotation; inline keys require a rollout. See `ci-values/ci.yaml` for a
render-only fixture; its image tags and credentials are not for deployment.

### Optional SCIM provisioning

SCIM is disabled by default. Configure provisioning only on the API workload.
Setting a SCIM user `active: false`, or deleting it, suspends that person in
every project:

```yaml
api:
  scim:
    enabled: true
    issuer: https://idp.example.com/
    userIdPrefix: "" # Must match this issuer's verified JWT identity mapping.
    existingSecret: hermetiq-scim
    existingSecretKey: token
    rolloutVersion: "1"
    groups:
      - {id: engineering, displayName: Engineering}
authorization:
  groupBindings:
    - projectId: my-project
      issuer: https://idp.example.com/
      group: engineering
      source: scim
      roles: [builder]
```

Create `hermetiq-scim` separately in the release namespace with a `token` key
containing a random provisioning credential (32–4096 non-whitespace bytes).
The chart mounts the Secret read-only into the API container; the token is never
placed in values, policy JSON, environment variables, or publisher/subscriber pods.
Point the IdP at `https://<API host>/api/v1/scim/v2`, using that bearer token.
The SCIM `userName` must equal the issuer's stable JWT subject (or configured stable
ID claim), never an email alias; `userIdPrefix` must match the JWT trust profile.
Only the configured immutable group IDs are accepted. Each principal is limited to 128 SCIM group IDs and 6 KiB of serialized group IDs; an oversized mutation fails atomically with HTTP 413. `source: scim` bindings use
current directory membership, while JWT bindings continue to use signed claims.
Removing a group grant cannot remove access still provided by `defaultAccess: viewer`.

The API reads its provisioning token at startup. To rotate it, update the Secret,
change the nonsecret `api.scim.rolloutVersion` marker, complete the API rollout,
and update the IdP's provisioning credential. Plan for provisioning retries during
that transition. Normal user JWT/JWKS rotation is independent of this token.

### Completed Action Logger trust

Buildbarn workers stream completed actions to `bep-nats-pub:50091` directly.
This is the Completed Action Logger (CAL). The workers present no user
credential, so network position is the only thing that can admit them.
`publisher.trustedCalCidrs` is a comma-separated list of CIDRs (bare IPs are
allowed) whose peers may call it. The chart renders it as
`GRPC_AUTH_TRUSTED_CAL_CIDRS` on the publisher only.

> **Warning:** Leaving `publisher.trustedCalCidrs` empty disables CAL ingest.
> The exemption fails closed: with no trusted peers, every CAL call is
> rejected with `UNAUTHENTICATED` and remote-execution action telemetry
> silently stops arriving. The chart cannot guess a safe default, so the value
> ships empty.

Set it to the range the Buildbarn worker pods run in, such as the pod range of
a dedicated worker node pool:

```yaml
publisher:
  trustedCalCidrs: "10.244.8.0/21"
```

The range must not contain gateway or ingress proxy pods (Envoy Gateway,
Contour Envoy, ingress-nginx). The core checks the immediate TCP peer, so a
request one of them relays from the internet arrives from the proxy's pod IP.
The public BEP route forwards only `gateway.routes.bepGrpcServices` (see
[What the public routes forward](#what-the-public-routes-forward)), but
`gateway.routes.bbcalGrpcEnabled=true` publishes every publisher method, CAL
included. If the workers cannot get a range of their own, the whole pod CIDR is
acceptable only while no route forwards CAL.

`GRPC_AUTH_TRUSTED_XFCC_CIDRS`, which would let peers assert
`x-forwarded-client-cert`, is deliberately never set. Nothing in this chart
terminates mTLS in front of the publisher, so client-certificate identities
stay fail-closed.

### MCP authentication

The MCP server runs in the API Deployment and uses the same verifier as the
gRPC API. With `oidc.issuerUrl` set and `api.jwt.enabled: true`, the chart
derives the protected MCP resource URLs from the MCP host. Clients connect to
`https://mcp.<domainBase>/mcp` and need a token issued for that exact
resource.

Leave `api.mcpResourceUrl` unset unless the public MCP origin differs from
`https://mcp.<domainBase>`. It is the origin only; the chart refuses a value
with a path. The related values are `api.mcpAuthorizationServer`,
`api.mcpAuthDisabled`, and `api.mcpExposeUserIdentities`.

The
[MCP authentication guide](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/mcp-authentication.md)
covers those values, the audience rules, Dynamic Client Registration, and the
identity settings. The
[Auth0 runbook](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/mcp-auth0-runbook.md)
is a worked IdP example.

### Admin access

Installation administrators manage access across Hermetiq. With the default
single-issuer configuration and no `authorization.administratorGroups` override,
the verified `hermetiq-admin` group grants this access. For example, the browser's
verified ID token would include:

```json
{
  "iss": "https://idp.example.com/",
  "hermetiq/roles": ["hermetiq-admin"]
}
```

Here `api.jwt.groupsClaim: hermetiq/roles` selects the claim, while
`publisher.hermetiqAdminGroup: hermetiq-admin` selects the administrator group
for both the API and publisher. These are the chart defaults. The token must
also satisfy the configured issuer, audience, signature, and lifetime checks.

To explicitly restrict administrator trust to an issuer and group, configure:

```yaml
authorization:
  administratorGroups:
    - issuer: https://idp.example.com/
      group: hermetiq-admin
      source: jwt
```

The issuer and group must match verified token claims. `api.jwt.groupsClaim` and
`publisher.jwks.groupsClaim` default to `hermetiq/roles`; independent JWT profiles
set their own `groupsClaim`. Use `source: scim` for an authoritative provisioned
group when SCIM is enabled. Explicit `administratorGroups` replace the default
verified admin-group trust. When omitted, the verified admin group remains
available (`publisher.hermetiqAdminGroup`, default `hermetiq-admin` for the
single-issuer configuration).

`app.adminEmails` has no effect on installation administration; grant it
through a trusted group as above. Direct project Admin memberships grant
administration of those projects, not installation-wide administration.

### Dashboard sign-in

The dashboard runs behind an oauth2-proxy sidecar
(`dashboard.oauth2Proxy.enabled`, default `true`). It reads its client
credentials from the Secret named by
`dashboard.oauth2Proxy.client.existingSecret`:

```yaml
dashboard:
  oauth2Proxy:
    client:
      existingSecret: oauth2-proxy-client
```

The Secret's keys must be `OAUTH2_PROXY_CLIENT_ID`,
`OAUTH2_PROXY_CLIENT_SECRET`, and `OAUTH2_PROXY_COOKIE_SECRET`; see
[Secrets](#secrets). `client.clientId`, `client.clientSecret`, and
`client.cookieSecret` are the inline alternative.

The chart renders the provider and session settings into a reusable ConfigMap,
`oauth2-proxy-config-web-ui`. Values specific to one deployment, such as
`OAUTH2_PROXY_REDIRECT_URL` and `OAUTH2_PROXY_UPSTREAMS`, are set on the
dashboard sidecar itself, so the Grafana proxy and the Buildbarn Browser proxy
can reuse the ConfigMap and the Secret and share one sign-in session.

| Value under `dashboard.oauth2Proxy` | Default | Purpose |
|---|---|---|
| `scope` | `openid email profile offline_access` | Scopes requested from the IdP |
| `emailDomains` | `[]` (required) | Email domains permitted to sign in to all proxies sharing the ConfigMap. `['*']` requires nonempty `allowedGroups`. |
| `allowedGroups` | `[]` | Additional admission restriction: membership in at least one listed IdP group is required. Does not grant application roles. |
| `oidcGroupsClaim` | empty | Claim oauth2-proxy reads groups from; falls back to `api.jwt.groupsClaim`, then `groups`. Set it explicitly with multiple JWT profiles. |
| `whitelistDomains` | `[]` | Extra domains allowed as redirect targets (`OAUTH2_PROXY_WHITELIST_DOMAINS`). `.<hosts.domainBase>` is added automatically, so redirects to the dashboard, Browser, and Grafana work without configuration. |
| `backendLogoutUrl` | empty | IdP logout URL to chain after oauth2-proxy clears its cookie |
| `cookieExpire`, `cookieRefresh` | oauth2-proxy defaults | Session lifetime and refresh interval. Keep the refresh below the IdP's access-token lifetime for silent refresh. |
| `cookieDomains` | `[]` | Share a session across subdomains, for example `[".example.com"]` |
| `env` | `{}` | Any other oauth2-proxy variable |

Configure admission explicitly. For one organization, set
`dashboard.oauth2Proxy.emailDomains: [example.com]` to your permitted email
domains. For an identity provider serving multiple organizations, use an
explicit group gate:

```yaml
dashboard:
  oauth2Proxy:
    emailDomains: ["*"]
    allowedGroups: [hermetiq-users]
    oidcGroupsClaim: hermetiq/roles
```

With both domain and group restrictions, users must satisfy both. The settings
are shared by the dashboard, Grafana and Buildbarn Browser; overriding
`OAUTH2_PROXY_EMAIL_DOMAINS`, `OAUTH2_PROXY_ALLOWED_GROUPS` or
`OAUTH2_PROXY_OIDC_GROUPS_CLAIM` in a workload's `env` is rejected; set them
through these shared values. Keep email verification enabled. Hermetiq
project roles and installation administrator groups remain separate from this
sign-in gate, as do Grafana roles.

Manage account registration at the identity provider. For Auth0 database
connections, configure whether signup is allowed on the connection; this chart
does not change tenant or connection settings. Directory-managed identities or
an intentionally shared tenant may need registration enabled, with admission
restricted by verified email domains or groups as above.

Without `dashboard.oauth2Proxy.backendLogoutUrl`, signing out clears only the
local cookie and the still-active IdP session silently signs the user back in.
This example, for Auth0, also sets explicit session lifetimes and a distinct
cookie name, which keeps sessions apart when another oauth2-proxy shares the
parent domain:

```yaml
dashboard:
  oauth2Proxy:
    cookieRefresh: 23h
    cookieExpire: 24h
    whitelistDomains:
      - <tenant>.auth0.com
    backendLogoutUrl: https://<tenant>.auth0.com/v2/logout?client_id=<client-id>&returnTo=https://dashboard.<domainBase>
    env:
      OAUTH2_PROXY_COOKIE_NAME: __Host-hermetiq
```

Add the `returnTo` host to Auth0's "Allowed Logout URLs" application setting
first. Because the Buildbarn Browser proxy reuses the ConfigMap, logout chains
through the same IdP for both UIs. A `__Host-` cookie name cannot be combined
with `cookieDomains`.

### Grafana SSO

By default the chart puts an oauth2-proxy in front of Grafana.
`grafana.oauth2Proxy.enabled: true` renders a standalone
`grafana-oauth2-proxy` Deployment and Service and points the Grafana route at
that proxy. It reuses `oauth2-proxy-config-web-ui` and the
`oauth2-proxy-client` Secret, so it shares the dashboard session. The chart
renders the shared ConfigMap whenever the Grafana proxy uses it, even with
dashboard sign-in disabled.

The proxy and the route render only while `gateway.routes.grafanaEnabled` is
`true`, which is the default. The proxy forwards to the Grafana Service named
by `gateway.routes.grafanaService` (default `vm-grafana`) on
`gateway.routes.grafanaServicePort`. The starter VictoriaMetrics values set
`grafana.fullnameOverride: vm-grafana` to match; change both together if you
rename the Grafana release.

If no Grafana runs beside this release, set
`gateway.routes.grafanaEnabled: false` to drop both the route and the proxy.
To expose Grafana without the proxy, set `grafana.oauth2Proxy.enabled: false`;
the route then targets the Grafana Service directly. First configure Grafana
to authenticate callers itself and adjust its backend policy; a direct route
must not trust caller-supplied authentication headers.

Register `https://grafana.<domainBase>/oauth2/callback` with the IdP, and
configure Grafana to trust the proxy headers in the VictoriaMetrics values:

```yaml
grafana:
  grafana.ini:
    users:
      allow_sign_up: false
      auto_assign_org: true
      auto_assign_org_role: Viewer
    auth.proxy:
      enabled: true
      header_name: X-Forwarded-User
      header_property: username
      headers: "Email:X-Forwarded-Email Groups:X-Forwarded-Groups"
      auto_sign_up: true
      enable_login_token: true
```

Grafana then logs in whatever user `X-Forwarded-User` names, for any caller
that can reach it, so the chart renders a `grafana-from-oauth2-proxy`
NetworkPolicy while
`grafana.oauth2Proxy.enabled=true`, including upgrades that reuse older values
without a `grafana.networkPolicy` block. Disabling only the public Grafana route
keeps this policy: Grafana is installed separately and still trusts proxy
headers after the route and proxy are removed. It selects the
Grafana pods (`grafana.networkPolicy.podSelector`, default
`app.kubernetes.io/name: grafana`; a selector you set replaces the default) and
admits only `grafana-oauth2-proxy` and
`grafana.networkPolicy.scrapersFrom` (default: the VictoriaMetrics `vmagent`)
on port `grafana.networkPolicy.port` (`3000`). It renders independently of
`networkPolicy.enabled`, in the release namespace, so Grafana must run there.
Add any other in-cluster Grafana client to `scrapersFrom`. For a scraper in
another namespace, put its `namespaceSelector` and `podSelector` in the same
entry: a `namespaceSelector` on its own admits every pod in that namespace.
Set `grafana.networkPolicy.enabled=false` only if something else restricts who
can reach Grafana. Turning off `grafana.oauth2Proxy.enabled` omits the policy
and routes directly to Grafana; configure Grafana's own authentication before
switching to that mode.

These settings belong to the **VictoriaMetrics/Grafana release**, not the
Hermetiq release. Apply them by upgrading that release with its complete values
and waiting for Grafana's rollout; upgrading Hermetiq alone does not change
Grafana's configuration. Before rolling Grafana, verify that its database uses
persistent storage or an external database. Restarting a pod whose database is
on `emptyDir` discards its users, role assignments, and locally saved dashboards;
preserve that data before applying configuration changes.

The [starter VictoriaMetrics values](../../custom-values/victoriametrics-values.yaml)
also create a Grafana backend NetworkPolicy through the Grafana chart's
`extraObjects`. It permits only the same-namespace Hermetiq Grafana proxy and
the VictoriaMetrics agent belonging to that metrics release. The metrics agent
is also trusted: Grafana serves `/metrics` on the same port as header-based
authentication, and a NetworkPolicy cannot restrict URL paths. Keep permission
to create or relabel pods in that namespace limited to trusted operators.

Use a CNI that enforces NetworkPolicy and check that other policies do not
grant broader access to the Grafana pod. A ClusterIP Service alone does not
isolate Grafana, and Hermetiq's `networkPolicy.enabled` protects its proxy, not
this external backend. If the proxy or metrics agent runs in another namespace,
adjust the policy selectors deliberately. `auth.proxy.whitelist` can provide
additional protection when proxy source addresses are stable; a whole-cluster
pod CIDR does not distinguish the proxy from other pods.

`users.auto_assign_org_role: Viewer` applies to newly created users; it does not
demote existing administrators. Review existing Grafana memberships separately.
Passing `X-Forwarded-Groups` does not map groups to Grafana Admin, and Hermetiq's
API administrator group does not grant Grafana privileges. Manage Grafana roles
explicitly or configure a supported role mapping in Grafana's identity provider
integration. See [Grafana's auth proxy configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/auth-proxy/).

## Workload sizing, scheduling, and availability

**Values:** `api`, `publisher`, `subscriber`, `dashboard`, `autoscaling`,
`k8sNodeScheduling`. The starter reduces API and publisher replicas and
requests for a small install.

### Replicas and resources

The starter sizes the API and the publisher for a small install:

```yaml
api:
  replicas: 2
  resources:
    api:
      requests:
        cpu: 500m
        memory: 1000Mi
publisher:
  replicas: 2
  resources:
    requests:
      cpu: 600m
      memory: 1200Mi
```

| Workload | Values | Replicas | Requests (CPU, memory) | Limits |
|---|---|---|---|---|
| API | `api.replicas`, `api.resources.api` | 4; starter 2 | 1500m, 2000Mi; starter 500m, 1000Mi | 1900m, 4000Mi |
| Publisher | `publisher.replicas`, `publisher.resources` | 4; starter 2 | 1500m, 2000Mi; starter 600m, 1200Mi | 1900m, 4000Mi |
| Subscriber | `subscriber.replicas`, `subscriber.resources` | 1 per partition | 500m, 900Mi | 1000m, 1900Mi |
| Dashboard | `dashboard.replicas`, `dashboard.resources` | 1 | 250m, 512Mi | 1000m, 1024Mi |

The figures are chart defaults; the starter overrides only where noted.
`api.resources` is keyed by container (`api`, `authProxy`), while the other
`resources` blocks are flat. Size requests and replica counts to your load.
Other settings to know:

- `autoscaling.publisher.enabled: true` adds a HorizontalPodAutoscaler for the
  publisher (defaults: 3 to 10 replicas, 80% CPU and memory targets). The
  publisher is the only workload with one.
- Keep `subscriber.replicas: 1`; see [Stream partitions](#stream-partitions).
- `api.downloadDirSizeLimit` (default `10Gi`) bounds the `emptyDir` where the
  API assembles a target's output files into an archive for download.
  Concurrent downloads share it, and exceeding it evicts the API Pod, so keep
  it above the largest expected target output.

[Large-scale deployments](#large-scale-deployments-and-high-throughput-ingest)
has sizing for high-volume installs.

### Node scheduling

`k8sNodeScheduling` sets the node selector and tolerations for every workload.
Its default pins all Pods to amd64 Linux nodes:

```yaml
k8sNodeScheduling:
  nodeSelector:
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
  tolerations: []
```

To run Hermetiq on a dedicated node pool, add the pool's label and
toleration:

```yaml
k8sNodeScheduling:
  nodeSelector:
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
    node-type: <pool-label>
  tolerations:
    - key: <taint-key>
      operator: Exists
      effect: NoSchedule
```

Set `nodeSelector` or `tolerations` under an individual workload to override
the top-level values. The workload keys are `api`, `publisher`, `subscriber`,
`dashboard`, `grafana.oauth2Proxy`, `bootstrap`, `partitionMaintenance`,
`progressesPartitionMaintenance`, and `targetTrendsRefresh`.

### Pod disruption budgets and anti-affinity

API and publisher Pods use preferred hostname anti-affinity
(`api.podAntiAffinity`, `publisher.podAntiAffinity`) and have
PodDisruptionBudgets with `maxUnavailable: 1` enabled by default
(`api.podDisruptionBudget`, `publisher.podDisruptionBudget`). Keep at least
two replicas while a budget is enabled.

The subscriber, dashboard, and Grafana proxy budgets
(`subscriber.podDisruptionBudget`, `dashboard.podDisruptionBudget`,
`grafana.oauth2Proxy.podDisruptionBudget`) are disabled by default, because
those workloads commonly start with one replica. Enable them only after
choosing a replica count and disruption policy that still permits node
drains.

Every rendered budget sets `unhealthyPodEvictionPolicy: AlwaysAllow`, so a
node drain can evict an unready Pod even when the healthy Pod budget is
exhausted. Healthy Pods still follow `maxUnavailable`.

### Additional environment variables

Use the workload `env` maps for application flags that are not modeled as
chart values: `api.env`, `api.authProxy.env`, `publisher.env`,
`publisher.authProxy.env`, `subscriber.env`, `dashboard.env`,
`dashboard.oauth2Proxy.env`, `dashboard.prepareDashboardHtml.env`,
`grafana.oauth2Proxy.env`, `assistant.promptRuntime.env`, `bootstrap.env`,
`partitionMaintenance.env`, `progressesPartitionMaintenance.env`, and
`targetTrendsRefresh.env`.

Do not set `INVOCATION_START_EVENT` in a workload map. Use
`app.invocationStartEvent`, which the chart puts in the shared environment so
that the publisher and subscribers cannot drift into different ingest modes.
The chart does not reject a workload-level entry, and one would override the
shared value for that workload only.

Values in these maps are rendered with Helm's `tpl`, so they may contain
template expressions.

## Dashboard

**Values:** `dashboard`. The starter sets the oauth2-proxy client Secret; see
[Dashboard sign-in](#dashboard-sign-in) for those values.

### Feature flags

The chart sets the dashboard's feature flags from the values that enable each
feature, so the UI and the backend cannot disagree:

| Feature | Chart setting | Default | Dashboard variable |
|---|---|---|---|
| [Barn Owl](#barn-owl-ai-assistant) | `assistant.enabled` | off | `REACT_APP_ENABLE_ASSISTANT` |
| [RBE Infrastructure](#rbe-infrastructure) | `rbe.enabled`, plus a project access policy | off | `REACT_APP_ENABLE_RBE_UI` |
| [Cost reporting](#cost-reporting) | `app.costReportTickerEnabled` | off | `REACT_APP_COST_INTEGRATION_ENABLED` |
| Kubernetes events ([VictoriaLogs](#victorialogs)) | `app.victoriaLogsEnabled` | off | `REACT_APP_ENABLE_VICTORIA_LOGS` |
| BB Config Editor | not available in this chart | always off | `REACT_APP_ENABLE_BB_CONFIG` |

Do not set these variables in `dashboard.env`; Helm rejects conflicting
entries. Other dashboard environment settings remain available through that
map.

A disabled integration makes no cost or event requests and hides its RBE
tabs, links, and allocation and pricing columns. The current Kubernetes
fleet, scheduler, Pod, and node snapshots and the core metrics remain
available without OpenCost or VictoriaLogs.

BB Config Editor's Git-backed bbconfig service and isolated Jsonnet evaluator
are not part of this chart, and enabling Barn Owl or RBE Infrastructure does
not install them.

The dashboard image reads these flags at runtime. An image older than the
chart's default does not honor them, so keep `images.dashboard` on the
application release that matches the chart.

### Quickstart customization

The dashboard's Quickstart page shows Bazel remote-cache instructions built
from `dashboard.remoteCacheUrl`. Left empty, it is the on-prem Buildbarn
frontend convention, `grpcs://bb.<hosts.domainBase>`, or the `bbcal` host when
that route is enabled. Set it when Buildbarn uses a separate domain or an
overridden frontend gRPC host:

```yaml
dashboard:
  remoteCacheUrl: grpcs://bb.example.com
```

The page also reads optional static customization from
`/quickstart-config/quickstart-config.json`. Only Step 1 is customizable. Use
`dashboard.quickstartConfig.data` for JSON managed by the chart:

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

Or mount a ConfigMap that you manage:

```yaml
dashboard:
  quickstartConfig:
    existingConfigMap: web-ui-quickstart-config
    configMapKey: quickstart-config.json
```

`existingConfigMap` and `data` are mutually exclusive. The dashboard ignores
unknown fields and never renders raw HTML from this file.

## ServiceAccount tokens and RBAC

**Values:** `serviceAccount`, `rbac`. The starter keeps
`rbac.mode: namespace`.

All workloads share one ServiceAccount, `bep-nats`.

### Token mounting

The ServiceAccount mounts a token by default
(`serviceAccount.automountServiceAccountToken: true`), and each workload's own
value, such as `api.automountServiceAccountToken`, overrides it:

| Workload | Default | Uses the Kubernetes API for |
|---|---|---|
| API, publisher | inherit the shared value | License identity and state; workload and worker-pool discovery |
| Subscribers | inherit the shared value | Lease-based coordination only |
| Dashboard, Grafana proxy, bootstrap Job, maintenance CronJobs | `false` | Nothing |

For a hardened installation, turn the shared default off and keep tokens only
where they are needed:

```yaml
serviceAccount:
  automountServiceAccountToken: false

api:
  automountServiceAccountToken: true
publisher:
  automountServiceAccountToken: true
```

Subscribers run without a token in that configuration. They need one only
when lease-based coordination is in use, which is the case for BEP
forwarding; add `subscriber.automountServiceAccountToken: true` then. For any
other workload, set its value to `true`, or to `null` to inherit the shared
setting, if an environment-specific integration such as a Vault agent sidecar
uses the Kubernetes API.

### RBAC rules

The chart defaults to `rbac.mode: namespace` and creates only Roles and
RoleBindings. Set `rbac.mode: cluster` only when the application's
permissions must come from a ClusterRole; licensing still uses the release
Namespace UID. Switching an existing release from `cluster` to `namespace`
removes its former ClusterRole, so that upgrade needs an installer allowed to
delete it.

Review each rule under `rbac.rules`. Every grant is bound in the release
namespace only.

| Rule | Default | Grants | Needed for |
|---|---|---|---|
| (always) | on | `get` on the release Namespace | [License identity](#license-identity-and-state) |
| `licenseState` | `true` | Read and update the `hermetiq-license-state` Secret; `create` on Secrets | Trial persistence and offline validation grace |
| `deployments` | `true` | `get`, `list` on Deployments and StatefulSets | Buildbarn diagnostics: installed components and worker images |
| `configMaps` | `true` | `get`, `list` on ConfigMaps | Buildbarn configuration context in MCP diagnostics |
| `pods` | `true` | `get`, `list` on Pods | Node placement for the storage diagnostics |
| `rbeWorkers` | `true` | `get`, `list` on `rbeworkers.bb.hermetiq.com` | Worker-pool tools and cost reporting |
| `leases` | `true` | `get`, `create`, `update` on Leases | Subscriber leader election, used only for BEP forwarding |
| `rbeFleet` | `false` | `get`, `list` on ReplicaSets, KEDA ScaledObjects, and HorizontalPodAutoscalers | [RBE Infrastructure](#rbe-infrastructure) fleet ownership and scaler state |
| `secrets` | `false` | `get` on Secrets in the namespace | Application-managed client certificates |
| `certManager` | `false` | Read and write cert-manager Certificates | Application-managed client certificates |

The read-only discovery rules cannot read another namespace, read Secrets, or
modify resources. Disabling `deployments` and `configMaps` leaves metrics
queries available but removes the installed-component inventory and Buildbarn
configuration context from MCP diagnostics. Tools that depend on a disabled
rule report it as unavailable or not permitted instead of failing. If
Buildbarn runs in another namespace, these grants do not reach it: grant the
`bep-nats` ServiceAccount equivalent reads there.

`certManager` and `secrets` control the application's optional
client-certificate management, not route TLS. If you enable them, set
`api.env.DEFAULT_CERT_NAMESPACE` to the release namespace (the application
otherwise defaults to `mtls-client-certs`) and `api.env.CLUSTER_ISSUER` to
the client-certificate issuer. Route Certificates created by Helm need none
of these grants.

Test RBAC and security overrides with a server-side dry run against the target
cluster's admission policies.

## External configuration ConfigMaps

**Values:** `nats.streamConfig`, `cacheTtl`, `promqlQueries`,
`assistant.policy`, `rbe.accessPolicy`, `dashboard.quickstartConfig`.

Several JSON configuration files can come from a ConfigMap that you own
outside the Helm release. The selected key is mounted at the same container
path as the packaged default, so the application sees no difference.

| Values prefix | Packaged default | Mount path | Read by |
|---|---|---|---|
| `nats.streamConfig` | `files/config/nats_streams.json` | `/config/nats-streams/nats_streams.json` | publisher, subscribers |
| `cacheTtl` | `files/config/cache_ttl.json` | `/config/cache-ttl/cache_ttl.json` | API |
| `promqlQueries` | `files/config/promql.json` | `/config/promql/promql.json` | API (MCP tools) |
| `assistant.policy` | embedded in the application | `/etc/hermetiq/aichat/policy.json` | API |
| `rbe.accessPolicy` | none | `/etc/hermetiq/rbe-access/policy.json` | API |
| `dashboard.quickstartConfig` | dashboard defaults | `/usr/share/nginx/html/quickstart-config/quickstart-config.json` | dashboard |

Each takes `existingConfigMap` and `configMapKey`. Helm cannot read or hash
the data of an external ConfigMap, so it cannot tell when the content changes.
Set `rolloutChecksum` to a hash or version of the content and change it with
every edit; that is the signal that rolls the consuming Pods. Inline and
packaged configuration roll the Pods automatically.

The Quickstart ConfigMap has no `rolloutChecksum`. For
`dashboard.quickstartConfig.existingConfigMap`, change a `commonAnnotations`
value on the next upgrade to roll the dashboard Pod.

The sections on [stream configuration](#stream-configuration),
[PromQL queries](#promql-query-configuration),
[Barn Owl policy](#policy-and-budgets),
[RBE access policy](#rbe-infrastructure), and
[Quickstart customization](#quickstart-customization) describe each file.

### Cache TTL configuration

The API reads its cache TTL settings from `/config/cache-ttl/cache_ttl.json`.
By default the chart renders `files/config/cache_ttl.json` into the
`bep-cache-ttl-config` ConfigMap. To override it:

```yaml
cacheTtl:
  existingConfigMap: hermetiq-cache-ttl-config
  configMapKey: cache_ttl.json
  rolloutChecksum: "sha256-or-version-of-the-config"
```

## Progress log storage

Build stdout and stderr (BEP progress events) are stored in one of two places.
The choice is made per project in Project Settings, not by a chart value.

| Mode | Where the logs live | How long a completed build's logs stay readable |
|---|---|---|
| PostgreSQL, the default | The partitioned `public.progresses` table: hourly partitions, maintained by `progressesPartitionMaintenance` | 2 days |
| Cloud object storage | Compressed chunk objects in a Google Cloud Storage bucket or an Azure Blob container | Whatever age your bucket lifecycle rule sets |

The default needs no configuration. To use object storage, enable *Store
compressed invocation logs in cloud object storage* on the project and set its
bucket or container there. Subscribers then write progress logs directly to
the bucket and skip PostgreSQL, which keeps `public.progresses` small on
high-volume installs.

Object storage has two requirements on the cluster side:

1. Bucket access for the subscriber Pods. Subscribers use the shared chart
   ServiceAccount, so enabling [workload identity](#workload-identity) and
   granting that identity read and write access to the bucket is all the
   wiring needed. The subscriber Pods also need network egress to the storage
   endpoint, which the PostgreSQL mode does not.
2. A lifecycle rule on the `progress/` prefix. Hermetiq never deletes these
   objects, so without a rule they accumulate indefinitely. Scope the rule to
   `<prefix>/progress/` in the bucket's own infrastructure code and choose the
   retention you want for build logs. Keep it scoped to that prefix so that it
   does not also expire trace profiles, which are stored under
   `<prefix>/<project>/<invocation>/`.

Retention is then the bucket's lifecycle age, not a database window. Once
objects expire, log requests for those completed builds return empty logs,
the same way they do after a `progresses` partition ages out.

Reads prefer object storage for these projects and fall back to `progresses`
rows for invocations that have no objects, so invocations from before the
setting was enabled stay readable. If the bucket is unreachable, subscribers
keep ingesting by writing progress rows to PostgreSQL instead of dropping
events. Watch `hermetiq_progress_chunk_flush_total{outcome="spilled"}` and
treat a sustained rate as a storage problem to fix.

### Retention and sizing

For log retention beyond two days, either use object storage with the
lifecycle age you want, or raise the `public.progresses` retention in
`pg_partman` and size PostgreSQL for the additional rows:

```sql
UPDATE public.part_config
SET retention = '5 days'
WHERE parent_table = 'public.progresses';
```

Progress rows are the highest-volume rows Hermetiq writes. Before increasing
database retention, check database size, I/O, WAL, autovacuum, partition
maintenance, and the default partitions.

Three optional `subscriber.env` variables tune chunk sizing. Their defaults
suit typical CI volumes and rarely need changing:
`PROGRESS_BLOB_CHUNK_FLUSH_INTERVAL` (default `20s`, which is also the delay
before a running build's newest output appears in live log tailing),
`PROGRESS_BLOB_CHUNK_MAX_BYTES` (default `262144`), and
`PROGRESS_BLOB_CHUNK_MAX_EVENTS` (default `1000`).

## Cache-event analytics

Cache events come from the Buildbarn chart's grpc-cache-proxy sidecar, which
publishes Action Cache hits and misses to the NATS that this chart uses. For
them to be stored and shown, four things must line up:

- The sidecar's `cacheEvents.numShards` equals `app.streamPartitionCount`; see
  [Stream partitions](#stream-partitions).
- The sidecar's `cacheEvents.subjectPrefix` equals `cache.subjectPrefix` in
  the stream configuration, which is `cache` in the packaged file. Events
  published to subjects that nothing consumes are discarded.
- Action Cache Hit Tracker is on in the project's settings. It decides whether
  the project's events are stored at all. New projects start with it on.
- `app.cacheEventsEnabled` is `true`. It turns on the cache-event queries and
  MCP tools by setting `CACHE_EVENTS_ENABLED` on the API. The chart default is
  `false` and the starter sets `true`. It does not affect ingestion, which
  follows `cache.enabled` in the stream configuration (`true` in the packaged
  file).

The publisher keeps each project's Action Cache Hit Tracker setting in a
JetStream KV bucket named `<cache.subjectPrefix>_tracking_policy`, so that the
sidecar can stop sending a disabled project's events before they reach NATS.
The publisher creates the bucket on first start with file storage and the
cache stream's replica count, `1` in the packaged file. To change either, add
a `policyBucket` block to `cache` in your
[stream configuration](#stream-configuration):

```json
"cache": {
  "policyBucket": { "storage": "file", "replicas": 3 }
}
```

As with the streams, an existing bucket keeps its settings, and more than one
replica needs a clustered NATS. The sidecar's own configuration, including
per-invocation opt-in, is in the
[Buildbarn chart reference](https://github.com/Hermetiq/hermetiq-k8s/blob/main/charts/buildbarn/README.md#hermetiq-grpc-cache-proxy-sidecar).

## RBE Infrastructure

**Values:** `rbe`, `rbac.rules.rbeFleet`. Commented out in the starter.

The RBE Infrastructure page shows a project's remote-execution fleet. It is
opt-in, separate from Barn Owl, and can run without paid assistant calls.
Enable it for explicit project IDs. The policy keys are Hermetiq project IDs,
not Kubernetes namespace names:

```yaml
rbe:
  enabled: true
  accessPolicy:
    projects:
      "0":
        enabled: true
        minimum_role: viewer
rbac:
  rules:
    rbeFleet: true
victoriaMetrics:
  metricsEnabled: true
  projectLabelEnabled: true
  projectLabel: namespace
```

The example uses the default `bootstrap.projectId: "0"`. These settings are
independent of one another:

- `rbe.enabled` shows the page and requires a project access policy. It grants
  no Kubernetes permissions.
- `rbac.rules.rbeFleet` grants the API the read access it needs for fleet
  ownership and scaler state; see
  [RBAC rules](#rbac-rules). On its own it leaves the page hidden, and it
  cannot bypass the access policy. The default workload, Pod, ConfigMap, and
  RbeWorker reads remain necessary. No node, `pods/exec`, or write grants are
  added.
- The `victoriaMetrics` settings supply namespace-scoped metrics; see
  [Metrics-backed infrastructure tools](#metrics-backed-infrastructure-tools).
  Unscoped metrics are reported as unavailable.

Every project still passes the server's access policy and role checks.
`minimum_role` accepts `viewer`, `builder`, or `admin`. Authenticated on-prem
readers without stored membership have viewer access. An administrator cannot
bypass a disabled project rule. The page and all live assistant and MCP
infrastructure reads share this policy.

The policy can instead come from an external ConfigMap, selected with
`rbe.accessPolicy.existingConfigMap`, `configMapKey`, and `rolloutChecksum`.
Its JSON is
`{"version":1,"projects":{"0":{"enabled":true,"minimum_role":"viewer"}}}`. Do
not also set inline `projects`. The policy can be mounted without the
assistant, and a change to a chart-managed policy rolls the API Pods
automatically.

Metrics and Kubernetes reads are scoped to the project's saved Buildbarn
namespace. A new install saves the release namespace
(`bootstrap.projectNamespace`); for a database that already has projects,
check the project settings. Missing grants are reported as unavailable or
not permitted. VictoriaLogs and OpenCost remain optional.

To verify, confirm that an allowed project shows RBE Infrastructure and its
fleet data, then that a disabled project or an insufficient role is denied.
With `assistant.enabled` as well, Barn Owl is available from the page and
from its worker-pool views.

## Barn Owl AI assistant

**Values:** `assistant`. Commented out in the starter.

Barn Owl is Hermetiq's AI agent for investigating and optimizing Bazel and
Buildbarn builds. It is optional. Enabling it adds an Anthropic-backed
assistant to the API and a DSPy prompt-runtime sidecar to the API Pod, and
shows Barn Owl in the dashboard.

### Enable Barn Owl

The API and the runtime need outbound HTTPS access to Anthropic or to an
Anthropic-compatible gateway. Create the Secret that both will read, in the
release namespace, from a file that contains only the API key:

```bash
kubectl -n hermetiq create secret generic anthropic-api \
  --from-file=ANTHROPIC_API_KEY=/secure/path/anthropic-api-key
```

Then add this to your values file:

```yaml
assistant:
  enabled: true
  anthropic:
    model: claude-opus-5
    apiKey:
      existingSecret: anthropic-api
      existingSecretKey: ANTHROPIC_API_KEY
  streamTimeoutSeconds: 660
```

`assistant.enabled` (default `false`) controls both the dashboard's Barn Owl
entry and the backend and runtime configuration. Ordinary API chat and
runtime-backed prompts use the same Anthropic model and Secret. Credentials
stay in the API Pod; they are never sent to the browser. BB Config Editor is
not required for build, invocation, or RBE investigations.

The runtime sidecar listens on `127.0.0.1:50097` inside the API Pod and has no
Service or external route. It delegates tool execution to the API, which keeps
the caller's project authorization. Its defaults are:

- Resources: requests of 100m CPU and 400Mi memory, and limits of one CPU and
  1Gi. Change them under `assistant.promptRuntime.resources`. Additional
  scalar environment settings go under `assistant.promptRuntime.env`.
- Security: the chart's security context, with a writable `/tmp` for import
  caches.
- Probes: they execute `bbp health`, because a kubelet network probe cannot
  reach a loopback listener. The startup probe allows up to 10 minutes for
  initialization before restarting the sidecar, and readiness and liveness
  begin after it succeeds. Each probe allows 30 seconds for the health
  command, including its Python imports.

Keep the API Pod's termination grace at 90 seconds or more for its shutdown
drain; that is the default `app.terminationGracePeriodSeconds`.

### Anthropic-compatible gateways

To route both ordinary chat and runtime-backed prompts through an
Anthropic-compatible gateway, set the same base URL in both containers:

```yaml
api:
  env:
    ANTHROPIC_BASE_URL: https://gateway.example.com
assistant:
  promptRuntime:
    env:
      ANTHROPIC_BASE_URL: https://gateway.example.com
```

Use the gateway's base URL without a trailing slash. The gateway must support
the Anthropic Messages API, the configured models, streaming, and API-key
authentication. The Secret above is still required. Verify the gateway
against your configuration before relying on it.

### Policy and budgets

The assistant's embedded limits, pricing, and policy defaults stay in effect.
In particular, enforcement starts in `shadow` mode. To enforce budgets, supply
an overlay:

```yaml
assistant:
  policy:
    data:
      enforcement:
        mode: enforce
        clientOverrides: reject
```

Alternatively, use `assistant.policy.existingConfigMap` with
`configMapKey: policy.json` and a `rolloutChecksum`. Inline `data` and an
existing ConfigMap are mutually exclusive. A chart-managed policy change rolls
the API Pods automatically; for an external policy, change `rolloutChecksum`.

### Streaming timeout

`assistant.streamTimeoutSeconds` (default 660) allows the default ten-minute
turn deadline plus headroom. It applies to the API gRPC route for Envoy
Gateway, Contour, and ingress-nginx, and to the API Service's GKE backend
policy. GKE shares that Service policy across the API ports, including REST
and MCP. Envoy Gateway also applies it to the dashboard route carrying
same-origin browser gRPC-web streams. Publisher timeouts are unchanged.

Raise the streaming timeout whenever you raise the assistant's turn deadline,
and check the total response timeout of any external load balancer.

### JEV model routing

JEV can classify a freeform turn and select a model tier. It is optional and
disabled by default; the setup above needs only the Anthropic credential. The
API handles classification. The prompt runtime, the browser, the publisher,
and the subscribers never receive the JEV key.

Create the Secret in the release namespace:

```bash
kubectl -n hermetiq create secret generic jev-api-key \
  --from-file=JEV_API_KEY=/secure/path/jev-api-key
```

Add these settings alongside the Anthropic configuration. This example
observes routing decisions for RBE chat while keeping its usual model:

```yaml
assistant:
  jev:
    enabled: true
    baseUrl: https://api.typesafe.ai
    apiKey:
      existingSecret: jev-api-key
      existingSecretKey: JEV_API_KEY
    rolloutChecksum: "key-version-1"
  policy:
    data:
      agents:
        rbe:
          modelRouting:
            mode: shadow
            router: jev
            jevModel: jev-1.13.0
            timeout: 800ms
            minConfidence: 0.5
            fallbackTier: complex
            tiers:
              simple:
                model: claude-haiku-4-5
              complex:
                model: claude-opus-5
                effort: high
```

`assistant.enabled` and the Anthropic Secret must be configured as well. The
`assistant.jev` values supply only the credentials and the endpoint.
Classifier calls happen when the assistant policy contains an active
`modelRouting` block. Use `mode: enforce` to apply the selected tier, or
`shadow` to record
the classification while keeping the usual model. Routing can be configured
independently for the `rbe`, `invocation`, `project`, and `configset` agents.
The model tiers and pricing must be supported by the application version you
deploy.

The same routing policy can be supplied through
`assistant.policy.existingConfigMap` instead of inline `data`. A policy that
enables routing needs the JEV credential at API startup. No routing policy is
active unless you supply one.

Allow API egress to the configured JEV endpoint. Keep `baseUrl` at the API
root; the client appends `/v1/systemone`. Classification receives the redacted
latest user message. It does not receive conversation history, server
instructions, tool results, or injected page context. Selected catalog
prompts and DSPy program turns keep their existing execution path and bypass
JEV.

When routing is enforced, classifier errors, timeouts, low confidence, and an
open circuit all fall back to `fallbackTier`. Change
`assistant.jev.rolloutChecksum` after rotating the Secret so that the API Pods
restart with the new key. Changes to the Secret reference or the endpoint also
roll the API Pods, and inline policy changes use the assistant policy's own
checksum.

### Verify Barn Owl

After enabling it, check the rollout, the runtime, and both containers' logs:

```bash
kubectl -n hermetiq rollout status deployment/grpc-api
kubectl -n hermetiq exec deployment/grpc-api -c prompt-runtime -- bbp health
kubectl -n hermetiq logs deployment/grpc-api -c prompt-runtime --tail=100
kubectl -n hermetiq logs deployment/grpc-api -c api --tail=100
```

Then sign in to the dashboard, ask Barn Owl a build question, and run a
catalog prompt with real prerequisites. A healthy runtime proves process
connectivity; a completed model-backed turn verifies the credential and the
provider. If something fails:

- For a missing Secret, check its namespace and key.
- For image pull failures, check the release or mirror tag and the
  architecture.
- For turns cut off near five minutes, inspect the effective route timeout and
  any external load balancer's timeout.

To rotate the API key, update the Secret and restart the API Deployment so
that both containers read it again.

## Cost reporting

`app.costReportTickerEnabled` is the single switch for OpenCost-backed cost
reporting. The default, `false`, disables OpenCost reads and the API's cost
report ticker, and hides Cost Reporting, pricing cards, cost columns, and cost
datasets in the dashboard. Remote execution timing and action analytics stay
enabled. Set it to `true` only when the backend can reach the OpenCost API
named by `app.openCostUrl`, which is then required. The chart passes the same
value to both the API and the dashboard.

Worker-pool cost and behavior reporting also discovers the namespaced
`RbeWorker` objects (`bb.hermetiq.com/v1`) managed by bb-worker-operator,
through the `rbac.rules.rbeWorkers` grant. Like the other grants it covers
the release namespace only, and the API needs its ServiceAccount token to use
it; see [ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac).

## Large-scale deployments and high-throughput ingest

For high-concurrency Bazel and RBE environments (thousands of builds per day,
5 to 10 or more Buildbarn storage shards, and large worker fleets), size the
ingest path, NATS JetStream, and PostgreSQL across six areas before go-live.

1. **Progress logs.** By default, build stdout and stderr chunks are written
   as `BYTEA` rows into `public.progresses`. Under heavy CI concurrency,
   progress rows account for 80–90% of PostgreSQL write throughput, WAL
   volume, and disk I/O. Move them to object storage; see
   [Progress log storage](#progress-log-storage).

2. **Partition count.** Choose `app.streamPartitionCount` before production
   traffic starts and give Buildbarn's
   `frontend.grpcCacheProxy.cacheEvents.numShards` the same value; see
   [Stream partitions](#stream-partitions).

   | Deployment tier | Typical build volume | Buildbarn shards | `app.streamPartitionCount` |
   |---|---|---|---|
   | Starter or small | up to 500 builds/day | 1–3 | `4`, the starter value |
   | Medium production | 500–5,000 builds/day | 3–5 | `8`–`9`; the chart default is `9` |
   | Large scale (10 TiB+ RBE) | 5,000–25,000+ builds/day | 5–10 | `12`–`16` |

   Raise `subscriber.resources` to 1–2 CPU and 2Gi–4Gi of memory when enabling
   large batch coalescing.

3. **NATS memory and disk.** Each `CACHE_EVENTS_<i>` partition reserves
   128 MiB of JetStream memory storage; the other streams use file storage. At
   12–16 partitions the cache-event streams alone can reserve 1.5–2.0 GiB,
   more than the `1Gi` `memoryStore.maxSize` and the `2Gi` container limit in
   the starter `nats-values.yaml`. For 8–16 partitions, raise:

   - `config.jetstream.memoryStore.maxSize` to `4Gi`, or `8Gi` at 16
     partitions
   - `container.resources` requests and limits to 2000m–4000m CPU and
     8Gi–16Gi of memory
   - `config.jetstream.fileStore.pvc.size` to 100Gi–250Gi on low-latency SSD
     (`premium-rwo` or `gp3`), so that NATS can buffer 30 minutes of BEP and
     CAL streams during PostgreSQL maintenance windows

4. **PostgreSQL.**

   - Partitions. With 15 time-partitioned analytics tables, a `6 hour`
     interval creates 60 child partitions per day, or 1,800 child tables over
     30 days, which keeps active B-tree indexes compact in memory for
     high-write clusters. For retention windows of 60 to 90 days or more,
     either choose `bootstrap.partitionInterval: 12 hour` or `1 day` before
     the first install, or raise PostgreSQL's `max_locks_per_transaction` to
     256–512 or more. The interval cannot be changed through values later;
     see [Partition policy](#partition-policy).
   - Connections. Every `bep-nats-sub-<i>`, `bep-nats-pub`, and `grpc-api` Pod
     opens a PostgreSQL connection pool. With 12–16 subscribers, 4–10
     publishers, and 4–8 API Pods, total active connections exceed
     PostgreSQL's stock `max_connections = 100`. Configure `max_connections`
     of 300–500 or more, with 8–16 vCPU, 32–64 GiB of memory, and SSD storage
     with 10,000 or more write IOPS.
   - Read replica. Point `postgres.readReplica.host` at a replica so that
     dashboard Trends aggregations and MCP and Barn Owl analytical queries do
     not contend with subscriber batch inserts on the primary.

5. **Publisher and API.** Enable `autoscaling.publisher.enabled: true`, for
   example with `minReplicas: 4` and `maxReplicas: 12`, so that bursty CI BEP
   streams and Buildbarn worker CAL streams scale horizontally. Keep
   `api.downloadDirSizeLimit` above the largest concurrent target-output
   download; see [Replicas and resources](#replicas-and-resources).

6. **Cache.** With `app.cacheEventsEnabled: true`, cache-event enrichment
   (`CACHE_ENRICH`) caches digest metadata in the Redis-compatible cache. For
   5–10 Buildbarn shards, raise DragonflyDB's memory in
   `dragonflydb-values.yaml` or the `Dragonfly` resource from `2000Mi` to
   4Gi–8Gi.

## Security hardening

**Values:** `security`, `dashboard.security`, `networkPolicy`. See also
[ServiceAccount tokens and RBAC](#serviceaccount-tokens-and-rbac) for token
and permission hardening.

### Pod and container security context

Every Pod and container sets the Pod Security Standards `restricted` fields
explicitly, which also covers the securityContext recommendations of the CIS
Kubernetes Benchmark v2.0.1:

- non-root UID and GID 65532
- `seccompProfile: RuntimeDefault`
- `allowPrivilegeEscalation: false` and `privileged: false`
- `readOnlyRootFilesystem: true`
- all capabilities dropped

Workloads that need writable paths get `emptyDir` volumes for them. Every Pod
this chart renders therefore satisfies
`pod-security.kubernetes.io/enforce: restricted`.

> **Warning:** Buildbarn workloads need more. Worker pools that use FUSE build
> directories or Docker-in-Docker run `privileged` containers, and so does
> Buildbarn storage on `hostPath` block devices. If any of these share the
> Hermetiq namespace, label that namespace
> `pod-security.kubernetes.io/enforce: privileged`. Otherwise deploy Buildbarn
> and its workers in a separate namespace, referenced through
> `bootstrap.projectNamespace`, so that the Hermetiq namespace can enforce
> `restricted`. The Buildbarn and worker operator READMEs describe which
> configurations need which level.

On OpenShift, let the `restricted-v2` SCC assign IDs from the namespace range:

```yaml
security:
  pod:
    runAsUser: null
    runAsGroup: null
    fsGroup: null
dashboard:
  security:
    runAsUser: null
    runAsGroup: null
```

### Network policies

Apart from the Grafana policy described in [Grafana SSO](#grafana-sso), the
chart renders no NetworkPolicy by default. `networkPolicy.enabled: true`
adds ingress-only policies that admit each component's Service target ports
and nothing else:

| Component | Ports admitted |
|---|---|
| `grpc-api` | `50081` (gRPC and gRPC-web), `8008` (REST and metrics), `5150` (MCP) |
| `bep-nats-pub` | `50091`, or `50081` when it runs behind a grpc-auth-proxy sidecar; `8008` (metrics) |
| `bep-nats-sub-*` | `8008` (metrics) |
| `web-ui` | `8888` behind oauth2-proxy, or the application port without it |
| `grafana-oauth2-proxy` | `8888` |
| Bootstrap and maintenance Jobs | none |

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: envoy-gateway-system
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: buildbarn
  metricsFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
```

An empty `ingressFrom` admits any source on those ports. When you restrict it,
include every caller:

- your ingress controller or Gateway, which reaches the API, publisher,
  dashboard, and Grafana proxy
- Buildbarn worker Pods, which send completed-action logs to the publisher's
  gRPC Service port, `50091`

`metricsFrom` restricts port `8008` on the publisher and subscribers; leave it
empty to admit any source. The API also serves its REST API on `8008`, so
there the port admits `ingressFrom` plus `metricsFrom`, and any source while
`ingressFrom` is empty.

For egress rules or other selectors, add policies through `extraObjects` or
alongside the release. Select Pods by `app.kubernetes.io/component`: `api`,
`publisher`, `subscriber`, `dashboard`, `grafana-auth-proxy`, `maintenance`,
or `bootstrap`.

Egress must reach:

- PostgreSQL, the Redis-compatible cache, NATS, and the OTLP collector
- your OIDC provider
- VictoriaMetrics (`victoriaMetrics.baseUrl`)
- the Kubernetes API server
- the license services: `license.saasUrl` and `https://api.keygen.sh`
- for the optional features you enable: object storage, Anthropic or your
  gateway, the JEV endpoint, VictoriaLogs, and OpenCost

## Operations

Commands in this section pass `-n hermetiq`, so they do not depend on the
current kubectl namespace.

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

Resume with the configured per-partition replica count, which is one by
default:

```bash
SUBSCRIBER_REPLICAS=1 # set to subscriber.replicas from your values

for deployment in $(kubectl -n hermetiq get deploy \
  -l app.kubernetes.io/component=subscriber -o name); do
  kubectl -n hermetiq scale "$deployment" --replicas="$SUBSCRIBER_REPLICAS"
done
```

A later `helm upgrade` restores the replica count from values.

### Inspect database partitions

In `psql`, inspect table sizes and the `pg_partman` state:

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

Run maintenance immediately, with unique Job names:

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

Purge the dead-letter queue only after recording why its messages were
rejected and confirming that they do not need to be replayed:

```bash
kubectl -n hermetiq exec -it "$NATS_BOX" \
  -- nats stream purge BEP_DLQ_STREAM --force
```

### Rotate Secrets

Secrets injected as environment variables take effect only after the workload
restarts. How the restart happens depends on who manages the Secret:

- A Secret value managed by the chart changes the consuming Deployments' Pod
  checksums, so `helm upgrade` rolls them.
- A Secret managed outside the chart is invisible to Helm; an upgrade with
  unchanged values cannot detect the new content. Change a value under
  `commonAnnotations` before upgrading, or restart the affected Deployments
  directly for an immediate rotation.

```yaml
commonAnnotations:
  hermetiq.com/external-secret-revision: "2026-09-30-1"
```

Changing that value rolls the chart's Deployments. Do the same in the
Buildbarn values file when the Browser or another Buildbarn workload uses the
rotated Secret.

[Secrets](#secrets) lists what reads each Secret. After rotating one, restart:

| Secret | Restart after rotation |
|---|---|
| `postgres-db` | `grpc-api`, `bep-nats-pub`, and all `bep-nats-sub-*` Deployments |
| `dragonfly-auth` | DragonflyDB first, then all core Deployments |
| `oauth2-proxy-client` | `web-ui`, `grafana-oauth2-proxy`, `grpc-api` (which derives its audience from the client ID), and the Buildbarn Browser proxy |
| `hermetiq-license` | Nothing for an externally managed key, which is reloaded in place; changing an inline Helm key rolls the Pods |
| `anthropic-api` | `grpc-api` |
| `jev-api-key` | `grpc-api`, by changing `assistant.jev.rolloutChecksum` |

Update a Secret without writing its value to disk:

```bash
kubectl -n hermetiq create secret generic postgres-db \
  --from-literal=password='<new-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Coordinate database and cache credential changes with the corresponding
external service. Rotating `OAUTH2_PROXY_COOKIE_SECRET` invalidates active UI
sessions.

### Temporary image overrides

For short-lived diagnosis, patch the running Deployments with
`kubectl set image`:

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

These changes drift from Helm state and the next upgrade reverts them. Put
long-lived image changes under `images.*` in values. The repository's
[shared chart conventions](https://github.com/Hermetiq/hermetiq-k8s#shared-chart-conventions)
cover private registries, digest pinning, and the other settings this chart
shares with the Buildbarn chart, such as `global.imageRegistry`,
`imagePullSecrets`, `commonLabels`, and `extraObjects`.

### Upgrade and uninstall

An upgrade is the [install command](#run-the-install) with the new chart
version. The repository guide's
[Upgrading](https://github.com/Hermetiq/hermetiq-k8s#upgrading) section gives
the order across charts and shows how to compare defaults between versions,
and [Uninstalling](https://github.com/Hermetiq/hermetiq-k8s#uninstalling)
lists what Helm leaves behind. An installation on a chart older than `1.0.0`
follows the
[Hermetiq migration guide](https://github.com/Hermetiq/hermetiq-k8s/blob/main/docs/migrate-to-1.0.0-hermetiq.md)
instead. Two points are specific to this chart:

- The schema bootstrap hook runs on every upgrade and applies migrations
  before the workloads roll. Back up PostgreSQL first.
- `helm upgrade --wait` blocks while Pods are unready, which includes a
  lapsed license; see [Status and expiry](#status-and-expiry).

## Troubleshooting

Start with the Pod status and logs; see
[Inspect Pods and logs](#inspect-pods-and-logs). The table lists failures this
README describes, by symptom.

| Symptom | Likely cause | See |
|---|---|---|
| `helm template` or the install stops with a validation message | A required value is missing, or two settings conflict. The message names the value. | [Configure your values file](#configure-your-values-file) |
| Install fails with `no matches for kind "VMPodScrape"` | The VictoriaMetrics operator CRDs are not installed | [Dashboards and scrape objects](#dashboards-and-scrape-objects) |
| Install fails on unknown kinds such as `BackendTrafficPolicy` or `SecurityPolicy` | `routing.provider: gateway` on a controller that is not Envoy Gateway | [Envoy Gateway policies](#envoy-gateway-policies) |
| The schema bootstrap hook fails | The `postgres-db` Secret did not exist before the install, or the database prerequisites are not met | [PostgreSQL](#postgresql), [Bootstrap job](#bootstrap-job) |
| Hermetiq Pods stay `Pending` | The default node selector requires amd64 Linux nodes | [Node scheduling](#node-scheduling) |
| NATS Pods stay `Pending` | The JetStream PVCs are unbound because the StorageClass does not exist | [NATS JetStream](#nats-jetstream) |
| Subscribers fail at startup and no builds appear | A single-server NATS cannot place the three-replica build stream | [Stream configuration](#stream-configuration) |
| Builds appear, but remote-execution action data is missing | `publisher.trustedCalCidrs` is empty or does not cover the workers, so their calls are rejected with `UNAUTHENTICATED` | [Completed Action Logger trust](#completed-action-logger-trust) |
| The application exits at startup over the contact email | `license.contactEmail` is still an `example.com` address | [Agreement and contact email](#agreement-and-contact-email) |
| `grpc-api` and `bep-nats-pub` report 0/N ready on the `license` check, and restarted Pods crash-loop | The license lapsed, or the Pods cannot reach the license services | [Status and expiry](#status-and-expiry) |
| `helm upgrade --wait` never returns | Pods are unready, often for the license reason above | [Status and expiry](#status-and-expiry) |
| A BES upload fails at the end of an otherwise successful build | A route timeout shorter than the publisher's drain | [Route timeouts](#route-timeouts) |
| `413 request_payload_too_large` through Envoy Gateway | Buffer limit or HTTP/2 windows too small for the upload | [Client connection tuning](#client-connection-tuning-for-high-rtt-clients) |
| MCP clients are refused, for example with Auth0's `Service not found` | The IdP's resource identifier does not match `https://mcp.<domainBase>/mcp` exactly | [MCP authentication](#mcp-authentication) |
| Signing out of the dashboard signs the user straight back in | `backendLogoutUrl` is not set | [Dashboard sign-in](#dashboard-sign-in) |
| Dashboard API calls return HTTP 505 while `/auth/me` succeeds | Envoy translated gRPC-web before the dashboard's HTTP/1.1 BFF | [Dashboard gRPC-web forwarding](#dashboard-grpc-web-forwarding); verify the patch-policy extension, listener names, and `Programmed` status |
| Rows accumulate in `*_default` tables | A partition is missing or maintenance is failing | [Inspect database partitions](#inspect-database-partitions) |
| Cache views are empty | Shard counts differ, Action Cache Hit Tracker is off, or `app.cacheEventsEnabled` is `false` | [Cache-event analytics](#cache-event-analytics) |
| A completed build's logs are empty | The build is older than its project's log retention | [Progress log storage](#progress-log-storage) |
| The RBE Infrastructure page is missing or has no fleet data | No access policy for the project, `rbac.rules.rbeFleet` is off, or metrics are not namespace-scoped | [RBE Infrastructure](#rbe-infrastructure) |
| Barn Owl turns stop near five minutes | A route or load-balancer timeout below the streaming timeout | [Streaming timeout](#streaming-timeout) |

To report a problem, see
[Getting help](https://github.com/Hermetiq/hermetiq-k8s#getting-help) for what
to include and what to redact.

## Local chart development

OCI releases are the supported installation path for customers. Contributors
can render and install the checked-out chart from the copied values
directory:

```bash
helm lint ../charts/hermetiq \
  --values ../charts/hermetiq/ci-values/ci.yaml

helm template hmq ../charts/hermetiq \
  --namespace hermetiq \
  --values ../charts/hermetiq/ci-values/ci.yaml > /tmp/hermetiq-render.yaml

helm upgrade --install --namespace hermetiq hmq ../charts/hermetiq \
  --values hermetiq-values.yaml
```

Before installing locally, read the repository's
[shared chart conventions](https://github.com/Hermetiq/hermetiq-k8s#shared-chart-conventions)
for private registries, digest pinning, common metadata, `extraObjects`, and
templated pass-through values.

### Synchronize PromQL and dashboards

The companion `cloud-native` repository owns the PromQL defaults and the
shared Grafana dashboards. With the repositories checked out as siblings, run
its sync script from any working directory:

```bash
/path/to/cloud-native/scripts/sync-helm-assets.sh --dry-run
/path/to/cloud-native/scripts/sync-helm-assets.sh
/path/to/cloud-native/scripts/sync-helm-assets.sh --check
```

Use `--chart-dir /path/to/hermetiq-k8s/charts/hermetiq` for a different
layout. `--dry-run` shows pending changes without changing chart files, and
`--check` returns a nonzero status when managed assets differ. The script
requires Python 3 and rsync. It validates and stages the source JSON and
copies with checksum comparison, so repeated runs leave unchanged files
untouched.

The managed set is `bep-nats/config/promql_default.json` and the twelve shared
dashboards: BEP ingest, Hermetiq Demo, JetStream, NATS, query performance, SQL
performance, and six Buildbarn dashboards. The script preserves Helm's
datasource, namespace, and project substitutions and repairs undeclared
datasource references. Adding another dashboard requires an explicit manifest
and a portability review. Helm's DragonflyDB dashboard, the NATS stream
settings, the cache TTL settings, and other unmanaged files are preserved.

## License

The chart source in this package is licensed under the Apache License 2.0; see
the packaged `LICENSE` file. The Hermetiq container images it deploys are
proprietary software distributed under the
[Hermetiq Software License Agreement](https://github.com/Hermetiq/hermetiq-k8s/blob/main/charts/hermetiq/SOFTWARE-LICENSE-AGREEMENT.md),
packaged with this chart as `SOFTWARE-LICENSE-AGREEMENT.md`. Setting
`license.agreement.accepted: true` confirms acceptance, and running Hermetiq
requires a trial or purchased license key, as described in
[Licensing and trials](#licensing-and-trials).
